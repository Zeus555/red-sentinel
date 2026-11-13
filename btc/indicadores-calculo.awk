# Sentinel BTC - indicadores tecnicos sobre las velas de cripto_vela.
#
# Entrada: la salida tsv de velas-calculo.awk con desde=0 (TODA la historia de
# un producto), una vela por linea:
#   marco ts apertura maximo minimo cierre volumen ha_apertura ha_maximo
#   ha_minimo ha_cierre cerrada dias
# Diarias (1d) y semanales (1w) vienen intercaladas; cada marco, en orden.
#
# Calcula cada indicador por marco y por BASE, sin mirar nunca hacia delante:
#   base "real"  sobre el cierre real;
#   base "ha"    sobre el cierre Heikin Ashi, que es lo que dibuja TradingView
#                cuando el grafico esta en Heikin Ashi.
#
#   EMA 100 y EMA 200   alfa = 2/(n+1); la primera es la media simple de las n
#                       primeras velas (como TA-Lib). Antes de n velas, null.
#   Bollinger 20, 2σ    media simple de 20 ± 2 desviaciones tipicas POBLACIONALES
#                       (dividiendo por 20, como ta.stdev de TradingView).
#   Canal de regresion  recta de minimos cuadrados sobre las ultimas 100 velas
#   100, 2σ             (el "Linear Regression Channel" de TradingView):
#                         rl_centro     valor de la recta en esta vela
#                         rl_sup/inf    centro ± 2 desviaciones tipicas de los
#                                       residuos (dividiendo por n-1)
#                         rl_pendiente  cuanto sube o baja la recta por vela
#                         rl_r          correlacion de Pearson con el tiempo,
#                                       CON signo (+1 subida limpia, -1 bajada
#                                       limpia); TradingView muestra |rl_r|
#                         rl_ruptura    1 si el cierre quedo POR ENCIMA del canal
#                                       de las 100 velas anteriores prolongado a
#                                       esta; -1 si quedo por debajo; 0 dentro.
#                                       Hacen falta 101 velas.
#   Todo es causal: el valor de una vela solo depende de ella y de las
#   anteriores. Por eso la pasada solo reescribe las velas recientes.
#
# Variables (-v):
#   producto     id de Coinbase
#   desde        emite las diarias con ts >= desde y las semanas que acaban
#                despues de desde, la misma regla que velas-calculo.awk (0 = todo).
#                El calculo usa igualmente TODA la historia.
#   salida       "json" (sentencias para /db/execute de rqlite) o "tsv"
#   actualizado  segundos UTC de esta pasada
#   ema_a ema_b bb_n bb_k rl_n rl_k   largos y anchos; SOLO para las pruebas
#                (las columnas se llaman ema100 y ema200 igualmente)
#
# Por stderr: "RESUMEN_IND version=V emitidas=N previas=M ...", donde previas
# es cuantas filas NO se emitieron por quedar antes de desde (las dos bases).
# La pasada lo compara con lo guardado: si no cuadra, lo reescribe todo.
#
# VERSION sube cuando cambia lo que se calcula: las filas de otra version no
# cuentan como guardadas y la siguiente pasada lo reescribe todo. Empieza en 1:
# la pasada usa version=0 como marca de "fila por reescribir".
#
# Sale con 2 si la entrada no tiene la forma esperada o viene desordenada.

function num(x) { return sprintf("%.15g", x) }
function falla(msg) { printf "ERROR %s\n", msg > "/dev/stderr"; fallo = 1; exit 2 }

# EMA k (1 o 2) de largo L de la serie s, ya con la vela i (valor x) dentro.
function ema(s, k, L, x, i,   a) {
  if (i < L) { es[s, k] += x; return "null" }
  if (i == L) { es[s, k] = (es[s, k] + x) / L; return num(es[s, k]) }
  a = 2 / (L + 1)
  es[s, k] = a * x + (1 - a) * es[s, k]
  return num(es[s, k])
}

# Recta de minimos cuadrados sobre las rl_n velas que acaban en e (x = 0 la mas
# vieja). Deja f_c (valor de la recta en e), f_p (pendiente por vela), f_d
# (desviacion tipica de los residuos, n-1) y f_r (Pearson con signo). Con x
# centrada y los residuos sumados uno a uno: sin restas de numeros enormes.
function ajusta(s, e,   N, j, ym, xm, sxx, sxy, syy, d, sse) {
  N = rl_n; xm = (N - 1) / 2
  ym = 0; for (j = 0; j < N; j++) ym += y[s, e - N + 1 + j]; ym /= N
  sxy = 0; syy = 0
  for (j = 0; j < N; j++) { d = y[s, e - N + 1 + j] - ym; sxy += (j - xm) * d; syy += d * d }
  sxx = N * (N * N - 1) / 12
  f_p = sxy / sxx
  sse = 0
  for (j = 0; j < N; j++) { d = y[s, e - N + 1 + j] - ym - f_p * (j - xm); sse += d * d }
  f_c = ym + f_p * xm
  f_d = sqrt(sse / (N - 1))
  f_r = (syy > 0) ? sxy / sqrt(sxx * syy) : 0
  af_e[s] = e; af_c[s] = f_c; af_p[s] = f_p; af_d[s] = f_d; af_r[s] = f_r
}

# Una vela de la serie s (marco m, base b) con valor x.
function vela(m, b, x, t, cerr, emitir,   s, i, j, e1, e2, mm, d, v, bm, bs, bi, rc, rs, ri, rp, rr, ru, pc, pd) {
  s = m "|" b
  i = ++n[s]
  y[s, i] = x
  # Las EMA se llevan SIEMPRE: son recursivas.
  e1 = ema(s, 1, ema_a, x, i)
  e2 = ema(s, 2, ema_b, x, i)
  if (!emitir) { previas++; return }

  # Bollinger: dos vueltas (media y luego desviacion), sin sumar cuadrados grandes.
  if (i >= bb_n) {
    mm = 0; for (j = i - bb_n + 1; j <= i; j++) mm += y[s, j]; mm /= bb_n
    v = 0; for (j = i - bb_n + 1; j <= i; j++) { d = y[s, j] - mm; v += d * d }
    d = sqrt(v / bb_n)
    bm = num(mm); bs = num(mm + bb_k * d); bi = num(mm - bb_k * d)
  } else { bm = bs = bi = "null" }

  # Ruptura: el canal de las rl_n velas ANTERIORES, prolongado una vela.
  ru = "null"
  if (i >= rl_n + 1) {
    if (af_e[s] != i - 1) ajusta(s, i - 1)
    pc = af_c[s] + af_p[s]; pd = rl_k * af_d[s]
    ru = (x > pc + pd) ? 1 : ((x < pc - pd) ? -1 : 0)
  }
  # Canal de esta vela.
  if (i >= rl_n) {
    ajusta(s, i)
    rc = num(f_c); rs = num(f_c + rl_k * f_d); ri = num(f_c - rl_k * f_d); rp = num(f_p); rr = num(f_r)
  } else { rc = rs = ri = rp = rr = "null" }

  emitidas++
  if (salida == "tsv") {
    printf "%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\n", \
      m, b, t, e1, e2, bm, bs, bi, rc, rs, ri, rp, rr, ru, cerr
    return
  }
  printf "[\"INSERT OR REPLACE INTO cripto_indicador(producto,marco,base,ts,ema100,ema200,bb_media,bb_sup,bb_inf,rl_centro,rl_sup,rl_inf,rl_pendiente,rl_r,rl_ruptura,cerrada,version,actualizado) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)\",\"%s\",\"%s\",\"%s\",%d,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%d,%d,%d]\n", \
    producto, m, b, t, e1, e2, bm, bs, bi, rc, rs, ri, rp, rr, ru, cerr, VERSION, actualizado
}

BEGIN {
  VERSION = 1
  SEM = 7 * 86400
  if (salida == "") salida = "json"
  if (ema_a == "") ema_a = 100
  if (ema_b == "") ema_b = 200
  if (bb_n == "") bb_n = 20
  if (bb_k == "") bb_k = 2
  if (rl_n == "") rl_n = 100
  if (rl_k == "") rl_k = 2
  ema_a += 0; ema_b += 0; bb_n += 0; bb_k += 0; rl_n += 0; rl_k += 0
  desde += 0; actualizado += 0
  if (ema_a < 1 || ema_b < 1 || bb_n < 2 || rl_n < 3) falla("largos de indicador no validos")
  emitidas = 0; previas = 0
}

{
  if (NF != 13) falla("linea " NR " con " NF " campos (se esperan 13)")
  m = $1; t = $2 + 0
  if (m != "1d" && m != "1w") falla("marco desconocido en la linea " NR ": " m)
  if ((m in ult) && t <= ult[m]) falla("entrada desordenada o repetida: " m " " t " despues de " ult[m])
  ult[m] = t
  emitir = (m == "1d") ? (t >= desde) : (t + SEM > desde)
  vela(m, "real", $6 + 0, t, $12 + 0, emitir)
  vela(m, "ha", $11 + 0, t, $12 + 0, emitir)
}

END {
  if (fallo) exit 2
  printf "RESUMEN_IND version=%d emitidas=%d previas=%d diarias=%d semanales=%d\n", \
    VERSION, emitidas, previas, n["1d|real"] + 0, n["1w|real"] + 0 > "/dev/stderr"
}
