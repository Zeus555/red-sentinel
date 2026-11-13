# Sentinel BTC - señales de mercado al cierre de cada vela, para los avisos.
#
# Entrada: una sola corriente, con lo que la pasada ya calculo de cada producto,
# cada linea con el producto y su clase delante (separado por tabuladores):
#   <producto> V  <la salida tsv de velas-calculo.awk: 13 columnas>
#   <producto> I  <la salida tsv de indicadores-calculo.awk: 15 columnas>
#   <producto> F  <corte> <la salida tsv de fibonacci-calculo.awk: 7 columnas>
# Las velas (V) van enteras (desde=0); los indicadores (I), desde unas semanas
# antes de `desde`: bastan los de las velas candidatas y los de la anterior.
# Los niveles (F) van POR VELA CANDIDATA: <corte> es el ts de la vela y los
# niveles son los del ciclo con las velas diarias CERRADAS anteriores a ella (ts
# < corte): las lineas que habia en el grafico al abrirse esa vela (en la
# diaria, todo hasta ayer; en la semanal, hasta el domingo anterior). Un maximo
# nuevo durante el dia, o la propia vela, no cambian la señal de las velas que
# ya cerraron. Y por eso cerrar por encima del maximo del ciclo cruza el 0 %
# ("supera el maximo"). Una vela sin lineas F no tiene Fibonacci.
#
# QUE SEÑALES (solo con velas CERRADAS: la de ayer y la de antes):
#   canal   el cierre rompe el canal de regresion de las 100 velas anteriores
#           (rl_ruptura pasa a 1 o a -1 desde otro valor). Mientras sigue fuera
#           no se repite: una caida que sigue bajo el canal avisa una vez.
#   ema100  el cierre cruza la EMA 100: la anterior cerro a un lado y esta al otro
#   ema200  lo mismo con la EMA 200
#   emas    la EMA 100 cruza la EMA 200 (cruce dorado hacia arriba, cruce de la
#           muerte hacia abajo)
#   fib     el cierre cruza uno o mas niveles de Fibonacci del ciclo (los que
#           habia antes de esa vela; el 0 % es el maximo y el 100 % el minimo:
#           cerrar por encima del maximo "supera el maximo del ciclo")
#   ha      la vela Heikin Ashi cambia de color (verde: cierre HA > apertura HA;
#           roja: menor). Una vela sin color (iguales) no cambia nada: se compara
#           con la ultima que si tuvo color.
# "Por encima" es estrictamente mayor: cerrar justo en el nivel es estar debajo.
#
# DE QUE SERIE: `orden` dice que productos mirar y en que orden; el primero es
# el principal (el perpetuo). Para cada señal, cada marco y cada vela, se usa el
# PRIMER producto que tenga el dato en esa vela y en la anterior. Si lo tiene y
# no hay señal, no se mira el siguiente. Asi el perpetuo, con ~70 semanas, usa
# el spot para la EMA y el canal semanales y para Fibonacci (aun sin ciclo
# propio), y en cuanto tenga el dato pasa solo a usar el suyo.
#
# Variables (-v):
#   orden    productos separados por espacio, el principal primero
#   desde    instante (s UTC): son candidatas las velas cerradas que cierran
#            DESPUES de el (la diaria a las 24 h de su ts, la semanal a los 7 d)
#   salida   "json" (sentencias para rqlite) o "tsv" (para las pruebas)
#   creado   instante de esta pasada, para la columna creado
#   enviado  vacio = pendiente de enviar (null); "0" = no se envia (lo que
#            habia antes de crear la tabla)
#
# Salida json: un INSERT OR IGNORE por señal en cripto_aviso, con clave
# (marco, ts, tipo): la misma señal calculada otra vez en la pasada siguiente
# no se duplica, ni se vuelve a mandar. Salida tsv:
#   marco ts tipo producto sentido precio nivel texto
# Por stderr: "RESUMEN_AV senales=N candidatas=K".
# Error (exit 2 y "ERROR ..." por stderr): una linea que no cuadra, o una vela
# candidata sin su fila de indicadores (asi nunca se cae al spot por un fallo).

function num(x) { return sprintf("%.15g", x) }
function falla(msg) { printf "ERROR %s\n", msg > "/dev/stderr"; fallo = 1; exit 2 }
function nulo(x) { return x == "null" || x == "" }

# 69120.4 -> "69.120" (dolares enteros, punto de miles).
function miles(x,   s, r) {
  s = sprintf("%d", int(x + 0.5)); r = ""
  while (length(s) > 3) { r = "." substr(s, length(s) - 2) r; s = substr(s, 1, length(s) - 3) }
  return s r
}
# 0.618 -> "61,8 %"; 0.5 -> "50 %".
function pct(n,   s) { s = sprintf("%.1f", n * 100); sub(/\.0$/, "", s); sub(/\./, ",", s); return s " %" }
# ts -> "13/11"
function fecha(t,   z, era, doe, yoe, doy, mp, d, m) {
  z = int(t / 86400) + 719468; era = int(z / 146097); doe = z - era * 146097
  yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
  doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100)); mp = int((5 * doy + 2) / 153)
  d = doy - int((153 * mp + 2) / 5) + 1; m = (mp < 10) ? mp + 3 : mp - 9
  return sprintf("%02d/%02d", d, m)
}
# Un nivel cruzado, para el texto: los extremos con su nombre.
function nivel(n, precio) {
  if (n == 0) return "el máximo del ciclo (" miles(precio) ")"
  if (n == 1) return "el mínimo del ciclo (" miles(precio) ")"
  return "el " pct(n) " (" miles(precio) ")"
}
function nombre(p) { if (p ~ /^BIP-/) return "Perpetuo"; if (p == "BTC-USD") return "Spot"; return p }
function prefijo(p, m, t) { return nombre(p) ", " ((m == "1d") ? "diaria" : "semanal") " del " fecha(t) ": " }

# Guarda una señal. sentido: 1 arriba, -1 abajo.
function senal(m, t, tipo, p, sentido, precio, nivel, texto) {
  ns++; SM[ns] = m; ST[ns] = t; SK[ns] = tipo; SP[ns] = p; SS[ns] = sentido
  SPr[ns] = precio; SN[ns] = nivel; SX[ns] = texto
}

# ¿Tiene el producto p el dato de la señal f en la vela i (y la anterior)?
function tiene(f, p, m, i,   t, u) {
  if (i < 2) return 0
  t = VT[p, m, i]; u = VT[p, m, i - 1]
  if (f == "ha") return (LC[p, m, i - 1] != 0)
  if (f == "fib") return (NLV[p, t] > 0)
  if (!((p, m, t) in IE1) || !((p, m, u) in IE1)) falla("faltan los indicadores de " p " " m " " ((p, m, t) in IE1 ? u : t))
  if (f == "ema100") return !nulo(IE1[p, m, t]) && !nulo(IE1[p, m, u])
  if (f == "ema200") return !nulo(IE2[p, m, t]) && !nulo(IE2[p, m, u])
  if (f == "emas") return !nulo(IE1[p, m, t]) && !nulo(IE1[p, m, u]) && !nulo(IE2[p, m, t]) && !nulo(IE2[p, m, u])
  if (f == "canal") return !nulo(IRU[p, m, t]) && !nulo(IRU[p, m, u]) && !nulo(IRC[p, m, u]) && !nulo(IRS[p, m, u]) && !nulo(IRP[p, m, u])
  return 0
}

# Evalua la señal f del producto p en su vela i (ya sabiendo que tiene el dato).
function evalua(f, p, m, i,   t, u, c, cp, a, b, x, y, j, sent, lista, prim, n1, lv, m0) {
  t = VT[p, m, i]; u = VT[p, m, i - 1]; c = VC[p, m, i]; cp = VC[p, m, i - 1]
  if (f == "ema100" || f == "ema200") {
    x = (f == "ema100") ? IE1[p, m, t] + 0 : IE2[p, m, t] + 0
    y = (f == "ema100") ? IE1[p, m, u] + 0 : IE2[p, m, u] + 0
    a = (cp > y); b = (c > x)
    if (a == b) return
    sent = b ? 1 : -1
    senal(m, t, f, p, sent, c, x, ((sent > 0) ? "📈 " : "📉 ") prefijo(p, m, t) "cierra por " ((sent > 0) ? "encima" : "debajo") \
      " de la EMA " substr(f, 4) ": cierre " miles(c) ", EMA " miles(x))
    return
  }
  if (f == "emas") {
    a = (IE1[p, m, u] + 0 > IE2[p, m, u] + 0); b = (IE1[p, m, t] + 0 > IE2[p, m, t] + 0)
    if (a == b) return
    sent = b ? 1 : -1
    senal(m, t, f, p, sent, c, IE2[p, m, t] + 0, ((sent > 0) ? "📈 " : "📉 ") prefijo(p, m, t) "la EMA 100 cruza por " \
      ((sent > 0) ? "encima de la EMA 200 (cruce dorado)" : "debajo de la EMA 200 (cruce de la muerte)") \
      ": EMA 100 " miles(IE1[p, m, t]) ", EMA 200 " miles(IE2[p, m, t]))
    return
  }
  if (f == "canal") {
    a = IRU[p, m, u] + 0; b = IRU[p, m, t] + 0
    if (b == 0 || b == a) return
    # El borde que rompio: el canal de las velas anteriores prolongado una vela.
    x = IRC[p, m, u] + IRP[p, m, u] + b * (IRS[p, m, u] - IRC[p, m, u])
    senal(m, t, f, p, b, c, x, ((b > 0) ? "📈 " : "📉 ") prefijo(p, m, t) "rompe el canal de regresión hacia " \
      ((b > 0) ? "arriba: cierre " miles(c) ", borde superior " : "abajo: cierre " miles(c) ", borde inferior ") miles(x))
    return
  }
  if (f == "fib") {
    # Niveles cruzados, en el orden en que los cruza el precio.
    lista = ""; prim = ""; n1 = 0
    # Los niveles son los de esta vela (los de antes de que cerrara).
    if (c < cp) { for (j = 1; j <= NLV[p, t]; j++) { lv = FP[p, t, j] + 0; if ((cp > lv) != (c > lv)) {
        lista = lista ((n1++) ? " y " : "") nivel(FN[p, t, j], lv); if (prim == "") prim = lv } } }
    else { for (j = NLV[p, t]; j >= 1; j--) { lv = FP[p, t, j] + 0; if ((cp > lv) != (c > lv)) { if (FN[p, t, j] == 0) m0 = 1
        lista = lista ((n1++) ? " y " : "") nivel(FN[p, t, j], lv); if (prim == "") prim = lv } } }
    if (n1 == 0) return
    sent = (c > cp) ? 1 : -1
    senal(m, t, f, p, sent, c, prim, "📐 " prefijo(p, m, t) ((sent > 0) ? (m0 ? "supera " : "recupera ") : "pierde ") lista \
      " de Fibonacci (ciclo " miles(FB[p, t]) " → " miles(FA[p, t]) "); cierre " miles(c))
    return
  }
  if (f == "ha") {
    a = LC[p, m, i - 1]; b = COL[p, m, i]
    if (b == 0 || b == a) return
    senal(m, t, f, p, b, c, VHC[p, m, i], ((b > 0) ? "🟢 " : "🔴 ") prefijo(p, m, t) "la vela Heikin Ashi pasa a " ((b > 0) ? "verde" : "roja"))
    return
  }
}

BEGIN {
  FS = "\t"
  if (salida == "") salida = "json"
  if (salida != "json" && salida != "tsv") falla("salida debe ser json o tsv")
  if (enviado != "" && enviado != "0") falla("enviado solo puede ir vacio o a 0")
  NP = split(orden, P, " ")
  if (NP < 1) falla("falta orden (los productos)")
  for (k = 1; k <= NP; k++) { if (P[k] !~ /^[A-Z0-9-]+$/) falla("producto no valido: " P[k]); EsP[P[k]] = 1 }
  desde += 0; creado += 0
  if (desde <= 0) falla("falta desde")
  NFAM = split("canal ema100 ema200 emas fib ha", FAM, " ")
}

{
  p = $1; k = $2
  if (!(p in EsP)) falla("linea " NR ": producto que no esta en orden: " p)
  if (k == "V") {
    if (NF != 15) falla("linea " NR ": vela con " NF " campos (se esperan 15)")
    m = $3; t = $4 + 0
    if (m != "1d" && m != "1w") falla("linea " NR ": marco desconocido " m)
    if (((p, m) in UV) && t <= UV[p, m]) falla("linea " NR ": velas desordenadas o repetidas de " p " " m)
    UV[p, m] = t
    # Solo las cerradas: la abierta es la ultima, y no da señal.
    if ($14 + 0 != 1) next
    i = ++NV[p, m]; VT[p, m, i] = t; VC[p, m, i] = $8 + 0; VHC[p, m, i] = $13 + 0
    COL[p, m, i] = ($13 + 0 > $10 + 0) ? 1 : (($13 + 0 < $10 + 0) ? -1 : 0)
    LC[p, m, i] = (COL[p, m, i] != 0) ? COL[p, m, i] : ((i > 1) ? LC[p, m, i - 1] : 0)
    IX[p, m, t] = i
    next
  }
  if (k == "I") {
    if (NF != 17) falla("linea " NR ": indicador con " NF " campos (se esperan 17)")
    if ($4 != "real") next
    m = $3; t = $5 + 0
    IE1[p, m, t] = $6; IE2[p, m, t] = $7; IRC[p, m, t] = $11; IRS[p, m, t] = $12; IRP[p, m, t] = $14; IRU[p, m, t] = $16
    next
  }
  if (k == "F") {
    if (NF != 10) falla("linea " NR ": nivel de Fibonacci con " NF " campos (se esperan 10)")
    t = $3 + 0
    j = ++NLV[p, t]; FN[p, t, j] = $4 + 0; FP[p, t, j] = $5 + 0; FB[p, t] = $7 + 0; FA[p, t] = $9 + 0
    if (j > 1 && FN[p, t, j] <= FN[p, t, j - 1]) falla("linea " NR ": niveles de Fibonacci desordenados")
    next
  }
  falla("linea " NR ": clase desconocida " k)
}

END {
  if (fallo) exit 2
  ns = 0; cand = 0
  for (mi = 1; mi <= 2; mi++) {
    m = (mi == 1) ? "1d" : "1w"; dur = (m == "1d") ? 86400 : 604800
    # Velas candidatas: las cerradas de cualquiera de los productos que cierran
    # despues de desde, en orden.
    nc = 0; delete CT
    for (k = 1; k <= NP; k++) { p = P[k]
      for (i = NV[p, m]; i >= 1 && VT[p, m, i] + dur > desde; i--) if (!(VT[p, m, i] in CT)) { CT[VT[p, m, i]] = 1; nc++; CL[nc] = VT[p, m, i] } }
    # orden por ts (pocas: insercion)
    for (a = 2; a <= nc; a++) { x = CL[a]; for (b = a - 1; b >= 1 && CL[b] > x; b--) CL[b + 1] = CL[b]; CL[b + 1] = x }
    cand += nc
    for (a = 1; a <= nc; a++) { t = CL[a]
      for (fi = 1; fi <= NFAM; fi++) { f = FAM[fi]
        for (k = 1; k <= NP; k++) { p = P[k]
          if (!((p, m, t) in IX)) continue
          i = IX[p, m, t]
          if (!tiene(f, p, m, i)) continue
          evalua(f, p, m, i)
          break
        }
      }
    }
  }
  if (fallo) exit 2
  for (k = 1; k <= ns; k++) {
    if (salida == "tsv") {
      printf "%s\t%d\t%s\t%s\t%d\t%s\t%s\t%s\n", SM[k], ST[k], SK[k], SP[k], SS[k], num(SPr[k]), num(SN[k]), SX[k]
      continue
    }
    printf "[\"INSERT OR IGNORE INTO cripto_aviso(marco,ts,tipo,producto,sentido,precio,nivel,texto,creado,enviado) VALUES(?,?,?,?,?,?,?,?,?,?)\",\"%s\",%d,\"%s\",\"%s\",%d,%s,%s,\"%s\",%d,%s]\n", \
      SM[k], ST[k], SK[k], SP[k], SS[k], num(SPr[k]), num(SN[k]), SX[k], creado, (enviado == "") ? "null" : "0"
  }
  printf "RESUMEN_AV senales=%d candidatas=%d\n", ns, cand > "/dev/stderr"
}
