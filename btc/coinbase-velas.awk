# Sentinel BTC - lee la respuesta de Coinbase Advanced Trade (endpoint publico
#   GET /api/v3/brokerage/market/products/<id>/candles?granularity=ONE_DAY)
# y la deja como una vela por linea:  ts apertura maximo minimo cierre volumen
#
# La respuesta es {"candles":[{"start":"1437350400","low":"277.37","high":"280",
# "open":"277.98","close":"280","volume":"782.88"},...]} (la mas nueva primero).
# Se leen los campos por NOMBRE, no por posicion, para no depender del orden.
#
# Se valida cada vela antes de dejarla pasar. Si una sola no cuadra, se sale con
# 3 y no se imprime nada de esa respuesta: una vela imposible (maximo por debajo
# del cierre, precio a cero, hora que no es medianoche) indica un cambio de la
# API o un dato roto, y es mejor no escribirla que contaminar la serie.
#
# Sale con 4 si la respuesta no trae la lista "candles" (error de la API).

function campo(reg, clave,   p, r) {
  p = "\"" clave "\":\"[^\"]*\""
  if (!match(reg, p)) return ""
  r = substr(reg, RSTART, RLENGTH)
  sub(/^"[^"]*":"/, "", r); sub(/"$/, "", r)
  return r
}
function es_num(x) { return x ~ /^[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$/ }

{ todo = todo $0 }

END {
  if (todo !~ /"candles"[ ]*:[ ]*\[/) { print "ERROR respuesta sin candles" > "/dev/stderr"; exit 4 }
  cuerpo = todo
  sub(/.*"candles"[ ]*:[ ]*\[/, "", cuerpo)
  sub(/\].*$/, "", cuerpo)
  n = 0
  if (cuerpo ~ /[^ ]/) {
    gsub(/\}[ ]*,[ ]*\{/, "}\n{", cuerpo)
    m = split(cuerpo, regs, "\n")
    for (i = 1; i <= m; i++) {
      t = campo(regs[i], "start"); o = campo(regs[i], "open"); h = campo(regs[i], "high")
      l = campo(regs[i], "low");   c = campo(regs[i], "close"); v = campo(regs[i], "volume")
      if (t !~ /^[0-9]+$/ || !es_num(o) || !es_num(h) || !es_num(l) || !es_num(c) || !es_num(v)) {
        printf "ERROR vela con campos invalidos: %s\n", regs[i] > "/dev/stderr"; exit 3
      }
      if ((t % 86400) != 0) { printf "ERROR vela que no empieza a medianoche UTC: %s\n", t > "/dev/stderr"; exit 3 }
      if (l + 0 <= 0 || l + 0 > o + 0 || l + 0 > c + 0 || h + 0 < o + 0 || h + 0 < c + 0) {
        printf "ERROR vela imposible: %s\n", regs[i] > "/dev/stderr"; exit 3
      }
      n++; lin[n] = t " " o " " h " " l " " c " " v
    }
  }
  for (i = 1; i <= n; i++) print lin[i]
}
