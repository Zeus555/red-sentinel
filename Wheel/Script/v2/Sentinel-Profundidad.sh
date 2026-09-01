#!/usr/bin/env sh
# Sentinel v2 - Profundidad ejecutable del libro de Coinbase en la base de la red.
#
# TERCER HERMANO de Sentinel-Cripto.sh (un precio) y Sentinel-Libro.sh (tope del
# libro). Aquel dice a cuanto esta el mejor bid; este dice a cuanto ejecutas de
# verdad si mueves 2 mil, 10 mil, 50 mil o 250 mil dolares: camina el libro nivel
# a nivel y guarda el VWAP alcanzado. Comparte la rejilla de 10 s con los otros
# dos para que las tres series se crucen por `ts`.
#
# POR QUE HACE FALTA: `cripto_libro` guarda nivel 1 porque la API de AWS llama a
# book?level=1. El tope y su tamano no bastan para decidir: un spread de 0,1 bps
# sobre 0,017 BTC no es el precio al que mueves diez mil dolares. Medido el
# 2026-08-31 sobre BTC-USD: el ask a 2 mil y a 250 mil difieren en ~1,6 bps, y el
# lado bid ni siquiera cubria 250 mil con 50 niveles.
#
# FUENTE: api.coinbase.com/api/v3/brokerage/market/product_book (Advanced Trade),
# publica y sin autenticar. Se piden PROF_NIVELES niveles, ~9 KB con el default.
# NO se usa el book?level=2 de api.exchange.coinbase.com: ese devuelve el libro
# entero, 1,15 MB por llamada, que a 10 s serian 600 MB/hora por nodo.
#
# COBERTURA: si los niveles devueltos no alcanzan a cubrir el clip, se guarda
# NULL, no un cero. Un cero se promedia y contamina; un NULL se ve. Para que un
# NULL sea diagnosticable se guardan ademas `niveles_ask`/`niveles_bid` (cuantos
# niveles trajo la respuesta) y `prof_ask_usd`/`prof_bid_usd` (cuantos dolares
# suman). Con eso se distingue "el libro no da para tanto" de "la respuesta vino
# rara": el 2026-08-31 aparecieron 2 filas de 1.070 con todo el lado bid a NULL
# teniendo 50 niveles, y sin la profundidad total no hubo forma de decidir si el
# mercado estaba fino o si la API devolvio tamanos en cero.
#
# MISMA TRAMPA QUE LOS HERMANOS: si el producto no existe la API no da error.
# Por eso se comprueba que `product_id` sea el par pedido ANTES de guardar.
set -u
BASE="${SENTINEL_BASE:-$HOME/PRC_Sentinel/v2}"
CONF="$BASE/sentinel.conf"
[ -r "$CONF" ] || exit 0
. "$CONF"
RQ="${RQLITE:-http://127.0.0.1:4001}"
URL="${PROF_URL:-https://api.coinbase.com/api/v3/brokerage/market/product_book}"
PAR="${PROF_PAR:-BTC-USD}"
EXC="${PROF_EXCHANGE:-coinbase}"
# 100 y no 50: medido el 2026-08-31 sobre 1.070 muestras, con 50 niveles el lado
# ask no llegaba a cubrir el clip de 250k el 48,3 % de las veces y esa columna
# salia NULL. Cien niveles pesan ~9 KB en vez de 4,4, que sigue siendo nada.
NIV="${PROF_NIVELES:-100}"
PASO="${CRIPTO_SEGUNDOS:-10}"
DIAS="${CRIPTO_RETENCION_DIAS:-90}"

# Me toca? Los mismos nodos que recolectan precio y libro, mas el Wheel.
W=""; [ -r "$BASE/wheel.state" ] && W=$(tr -d '[:space:]' < "$BASE/wheel.state")
me=0
[ "$W" = "${NAME:-}" ] && me=1
for x in $(printf '%s' "${CRIPTO_NODOS:-}" | tr ', ' '\n\n'); do
  [ "$x" = "${NAME:-}" ] && me=1
done
[ "$me" = "1" ] || exit 0

LOCK="$BASE/.profundidad.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  lt=$(stat -c %Y "$LOCK" 2>/dev/null || echo 0); ahora=$(date +%s 2>/dev/null || echo 0)
  if [ "$lt" -gt 0 ] && [ $((ahora - lt)) -gt 300 ]; then rmdir "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || exit 0
  else exit 0; fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM HUP

sql(){ curl -s -m 10 -o /dev/null -H "Content-Type: application/json" -d "$1" "$RQ/db/execute"; }

# Los clips son fijos a proposito, uno por columna, para que quede UNA fila cada
# 10 s como en las tablas hermanas. Anadir un tamano es un cambio de esquema, y
# eso es preferible a multiplicar filas por clip.
sql '[["CREATE TABLE IF NOT EXISTS cripto_profundidad (par TEXT NOT NULL, exchange TEXT NOT NULL, ts INTEGER NOT NULL, ask_2k REAL, bid_2k REAL, ask_10k REAL, bid_10k REAL, ask_50k REAL, bid_50k REAL, ask_250k REAL, bid_250k REAL, niveles_ask INTEGER, niveles_bid INTEGER, ts_fuente INTEGER, edad_ms INTEGER, nodo TEXT, prof_ask_usd REAL, prof_bid_usd REAL, PRIMARY KEY (par, exchange, ts))"]]'
sql '[["CREATE INDEX IF NOT EXISTS ix_prof_ts ON cripto_profundidad(ts)"]]'

# Fin anclado a la rejilla del minuto, no "+57 desde que arranco": con el offset
# el proceso seguia vivo cuando cron disparaba el siguiente, este no conseguia el
# lock y se perdia un minuto entero de forma alterna. Es la correccion que ya
# lleva Sentinel-Libro.sh, medida el 2026-08-29.
ini=$(date +%s)
fin=$(( ini - ini % 60 + 57 ))
# Arranque tardio: mejor ceder el turno que solaparse con el siguiente cron.
[ $(( fin - ini )) -lt 5 ] && exit 0

while [ "$(date +%s)" -lt "$fin" ]; do
  t=$(date +%s); bucket=$(( t / PASO * PASO ))
  r=$(curl -s -m 8 "$URL?product_id=$PAR&limit=$NIV" 2>/dev/null)
  pid=$(printf '%s' "$r" | grep -oE '"product_id":"[A-Za-z0-9._-]+"' | head -1 | cut -d'"' -f4)

  if [ "$pid" = "$PAR" ]; then
    # gawk imprime: ts_fuente_iso na nb a2 b2 a10 b10 a50 b50 a250 b250
    # Un clip que el libro no cubre sale como la palabra null, que rqlite acepta
    # como argumento posicional y guarda como NULL. Nunca como cero.
    linea=$(printf '%s' "$r" | gawk '
      { raw = raw $0 }
      END {
        if (match(raw, /"time":"[0-9TZ:.\-]+"/)) { tf = substr(raw, RSTART + 8, RLENGTH - 9) } else { tf = "" }
        ib = index(raw, "\"bids\":["); ia = index(raw, "\"asks\":[")
        if (ib == 0 || ia == 0 || tf == "") { exit 1 }
        nb = recoge(substr(raw, ib, ia - ib), bp, bq)
        na = recoge(substr(raw, ia), ap, aq)
        if (na == 0 || nb == 0) { exit 1 }
        # Profundidad total en dolares de los niveles devueltos. Sin esto, un
        # NULL en un clip es ambiguo: no se distingue "el libro no da para
        # tanto" de "la respuesta vino rara". Con esto, un NULL con profundidad
        # holgada delante señala a la fuente, no al mercado.
        printf "%s %d %d %.2f %.2f", tf, na, nb, total(ap, aq, na), total(bp, bq, nb)
        split("2000 10000 50000 250000", C, " ")
        for (i = 1; i <= 4; i++) {
          printf " %s %s", fmt(vwap(ap, aq, na, C[i] + 0)), fmt(vwap(bp, bq, nb, C[i] + 0))
        }
        printf "\n"
      }
      function fmt(v) { return (v > 0) ? sprintf("%.8f", v) : "null" }
      function total(P, Q, n,   i, acc) { acc = 0; for (i = 1; i <= n; i++) acc += P[i] * Q[i]; return acc }
      function recoge(s, P, Q,   n, t, m, A) {
        n = 0
        while (match(s, /"price":"[0-9.]+", *"size":"[0-9.]+"/)) {
          t = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
          m = t; gsub(/[^0-9.]+/, " ", m); split(m, A, " ")
          n++; P[n] = A[1] + 0; Q[n] = A[2] + 0
        }
        return n
      }
      # Camina el lado hasta consumir el nocional. Devuelve 0 si no alcanza, que
      # fmt() convierte en null: "no cubre" no es un precio bajo.
      function vwap(P, Q, n, nocional,   i, rest, cost, qty, take) {
        rest = nocional; cost = 0; qty = 0
        for (i = 1; i <= n; i++) {
          take = rest / P[i]; if (take > Q[i]) take = Q[i]
          cost += take * P[i]; qty += take; rest -= take * P[i]
          if (rest <= 0.000000001) break
        }
        if (rest > 0.000000001 || qty <= 0) return 0
        return cost / qty
      }' 2>/dev/null)

    if [ -n "${linea:-}" ]; then
      # shellcheck disable=SC2086
      set -- $linea
      tf=$1; na=$2; nb=$3; pa=$4; pb=$5; a2=$6; b2=$7; a10=$8; b10=$9
      shift 9; a50=$1; b50=$2; a250=$3; b250=$4
      # ts_fuente y edad_ms se calculan EN SQLite, igual que en Sentinel-Libro.sh:
      # asi no se depende de que `date` sepa parsear ISO-8601 en cada nodo.
      #
      # DIFERENCIA CON EL HERMANO: alli la edad se mide contra `bucket` porque la
      # fuente es un proxy en AWS que puede ir 18 s por detras, y lo que interesa
      # es cuanto se ha quedado atras respecto del instante de la rejilla. Aqui se
      # consulta a Coinbase directamente, asi que el libro SIEMPRE es de dentro
      # del bucket y esa resta daria negativos sistematicos que no son vejez sino
      # "en que momento del bucket cayo la muestra". Medirla contra `t` —el
      # segundo en que se pidio— devuelve la columna a su significado: cuanto ha
      # tardado el dato en llegar. Con fuente directa sale ~0 casi siempre, y un
      # valor alto es señal de que la API esta respondiendo lenta.
      sql "[[\"INSERT OR IGNORE INTO cripto_profundidad(par,exchange,ts,ask_2k,bid_2k,ask_10k,bid_10k,ask_50k,bid_50k,ask_250k,bid_250k,niveles_ask,niveles_bid,prof_ask_usd,prof_bid_usd,ts_fuente,edad_ms,nodo) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,CAST(strftime('%s',?) AS INTEGER),($t-CAST(strftime('%s',?) AS INTEGER))*1000,?)\",\"$PAR\",\"$EXC\",$bucket,$a2,$b2,$a10,$b10,$a50,$b50,$a250,$b250,$na,$nb,$pa,$pb,\"$tf\",\"$tf\",\"${NAME}\"]]"
    fi
  fi

  ahora=$(date +%s); sig=$(( ahora / PASO * PASO + PASO ))
  d=$(( sig - ahora ))
  # No dormir mas alla del final, para no robarle el turno al siguiente cron.
  [ $(( ahora + d )) -gt "$fin" ] && d=$(( fin - ahora ))
  [ "$d" -gt 0 ] && sleep "$d"
done

MARCA="$BASE/.profundidad-podado"
HOY=$(date +%Y-%m-%d)
if [ "$(cat "$MARCA" 2>/dev/null)" != "$HOY" ]; then
  sql "[[\"DELETE FROM cripto_profundidad WHERE ts < strftime('%s','now')-${DIAS}*86400\"]]"
  printf '%s\n' "$HOY" > "$MARCA"
fi
exit 0
