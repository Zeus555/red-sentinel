# Sentinel BTC - calculo de velas a partir de las diarias de Coinbase.
#
# Entrada: una vela diaria por linea, en orden de tiempo y sin repetir:
#     ts apertura maximo minimo cierre volumen
# (ts = inicio de la vela en segundos UTC, siempre a las 00:00).
#
# Calcula, sin mirar nunca hacia delante:
#   - la Heikin Ashi diaria;
#   - la vela semanal, con semana de LUNES 00:00 UTC (la misma que TradingView):
#     apertura del primer dia, maximo y minimo de la semana, cierre del ultimo
#     dia y suma del volumen. Coinbase no da vela semanal en su API publica
#     documentada; se comprobo que esta regla reproduce su ONE_WEEK;
#   - la Heikin Ashi semanal, sobre la vela semanal REAL (no juntando HA diarias).
#
# Heikin Ashi (la convencion de TradingView):
#   cierre_ha   = (apertura + maximo + minimo + cierre) / 4
#   apertura_ha = (apertura + cierre) / 2 en la primera vela de la serie;
#                 despues (apertura_ha anterior + cierre_ha anterior) / 2
#   maximo_ha   = max(maximo, apertura_ha, cierre_ha)
#   minimo_ha   = min(minimo, apertura_ha, cierre_ha)
# Es recursiva, como una EMA: por eso se recalcula SIEMPRE desde la primera vela
# de la historia y nunca a trozos. Con la misma entrada da la misma salida.
#
# Variables (-v):
#   producto     id de Coinbase (BTC-USD, BIP-20DEC30-CDE...)
#   ahora        segundos UTC; una vela esta "cerrada" si termino antes de ahora
#   desde        solo se emiten velas diarias con ts >= desde, y las semanas que
#                contienen algun dia >= desde (0 = todo). El calculo usa
#                igualmente TODA la historia.
#   salida       "json" (sentencias para /db/execute de rqlite) o "tsv"
#   fuente       nombre del equipo que escribe (columna fuente)
#   actualizado  segundos UTC de esta pasada (columna actualizado)
#
# Por stderr deja un resumen de una linea que empieza por "RESUMEN" y una linea
# "HUECO desde hasta" por cada tramo de dias que falten. Un hueco NO se rellena:
# la semana que lo contiene sale con dias < 7.
#
# Sale con 2 si la entrada viene desordenada o repetida: eso es un fallo del
# script que la prepara, y es mejor no escribir nada que escribir velas mal.

function max3(a, b, c,   m) { m = a; if (b > m) m = b; if (c > m) m = c; return m }
function min3(a, b, c,   m) { m = a; if (b < m) m = b; if (c < m) m = c; return m }
# 15 cifras significativas: precision relativa, sin restos de coma flotante
# (un double tiene ~15,9). Con %.6f un producto de precio muy bajo perderia casi
# todo; con BTC da lo mismo. Puede salir con exponente (1.2e-05): es JSON valido.
function num(x) { return sprintf("%.15g", x) }

function emite(marco, t, o, h, l, c, v, ho, hh, hl, hc, cerrada, dias) {
  if (salida == "tsv") {
    printf "%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\n", \
      marco, t, o, h, l, c, v, num(ho), num(hh), num(hl), num(hc), cerrada, dias
    return
  }
  printf "[\"INSERT OR REPLACE INTO cripto_vela(producto,marco,ts,apertura,maximo,minimo,cierre,volumen,ha_apertura,ha_maximo,ha_minimo,ha_cierre,cerrada,dias,fuente,actualizado) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)\",\"%s\",\"%s\",%d,%s,%s,%s,%s,%s,%s,%s,%s,%s,%d,%s,\"%s\",%d]\n", \
    producto, marco, t, o, h, l, c, v, num(ho), num(hh), num(hl), num(hc), cerrada, dias, fuente, actualizado
  emitidas++
}

# Cierra la semana en curso: calcula su Heikin Ashi y la emite si toca.
function cierra_semana(   c_ha, o_ha, h_ha, l_ha, cerr) {
  c_ha = (w_o + w_h + w_l + w_c) / 4
  o_ha = (n_sem == 0) ? (w_o + w_c) / 2 : (w_ant_o + w_ant_c) / 2
  h_ha = max3(w_h, o_ha, c_ha)
  l_ha = min3(w_l, o_ha, c_ha)
  cerr = (w_ts + SEM <= ahora) ? 1 : 0
  if (w_ts + SEM > desde)
    emite("1w", w_ts, w_os, w_hs, w_ls, w_cs, sprintf("%.8f", w_v), o_ha, h_ha, l_ha, c_ha, cerr, w_n)
  w_ant_o = o_ha; w_ant_c = c_ha
  n_sem++
}

BEGIN {
  DIA = 86400; SEM = 7 * DIA
  if (salida == "") salida = "json"
  ahora += 0; desde += 0; actualizado += 0
  n_dia = 0; n_sem = 0; huecos = 0; tramos = 0; emitidas = 0; previo = -1; w_ts = -1
}

NF < 6 { next }

{
  t = $1 + 0
  o = $2 + 0; h = $3 + 0; l = $4 + 0; c = $5 + 0; v = $6 + 0
  if (previo >= 0 && t <= previo) {
    printf "ERROR entrada desordenada o repetida: %d despues de %d\n", t, previo > "/dev/stderr"
    fallo = 1; exit 2
  }
  if (previo >= 0 && t - previo > DIA) {
    huecos += (t - previo) / DIA - 1; tramos++
    printf "HUECO %d %d\n", previo + DIA, t - DIA > "/dev/stderr"
  }
  if (n_dia == 0) primera = t
  previo = t; ultima = t; ultimo_cierre = $5

  # --- Heikin Ashi diaria ---
  c_ha = (o + h + l + c) / 4
  o_ha = (n_dia == 0) ? (o + c) / 2 : (d_ant_o + d_ant_c) / 2
  h_ha = max3(h, o_ha, c_ha)
  l_ha = min3(l, o_ha, c_ha)
  d_ant_o = o_ha; d_ant_c = c_ha
  n_dia++
  if (t >= desde)
    emite("1d", t, $2, $3, $4, $5, $6, o_ha, h_ha, l_ha, c_ha, (t + DIA <= ahora) ? 1 : 0, "null")

  # --- Semana de lunes 00:00 UTC ---
  # El 01/01/1970 fue jueves: el lunes de la semana del dia d es d - ((d + 3) % 7).
  d = int(t / DIA)
  lunes = (d - ((d + 3) % 7)) * DIA
  if (lunes != w_ts) {
    if (w_ts >= 0) cierra_semana()
    w_ts = lunes; w_o = o; w_os = $2; w_h = h; w_hs = $3; w_l = l; w_ls = $4; w_v = 0; w_n = 0
  }
  if (h > w_h) { w_h = h; w_hs = $3 }
  if (l < w_l) { w_l = l; w_ls = $4 }
  w_c = c; w_cs = $5; w_v += v; w_n++
}

END {
  if (fallo) exit 2
  if (w_ts >= 0) cierra_semana()
  printf "RESUMEN producto=%s diarias=%d semanales=%d huecos=%d tramos=%d primera=%d ultima=%d cierre=%s emitidas=%d\n", \
    producto, n_dia, n_sem, huecos, tramos, (n_dia ? primera : 0), (n_dia ? ultima : 0), ultimo_cierre, emitidas > "/dev/stderr"
}
