#!/usr/bin/env sh
# Sentinel v2 - Libro de ordenes (nivel 1) de Coinbase en la base de la red.
#
# HERMANO de Sentinel-Cripto.sh, no sustituto. Aquel guarda UN precio (el del
# agente Jupiter); este guarda el TOPE DEL LIBRO de Coinbase: mejor oferta y
# mejor demanda, con su tamano y cuantas ordenes lo componen. Comparten la misma
# rejilla de 10 s a proposito, para que las dos series se puedan cruzar por `ts`
# y ver el mismo instante en ambos mercados (vista v_cripto_comparado).
#
# POR QUE numorders IMPORTA: saber que hay 0,6 BTC a la compra no dice lo mismo
# si son 1 orden o son 8. Cambia por completo lo que pasa si intentas barrer ese
# nivel. Es el dato que distingue mirar un grafico de poder ejecutar.
#
# FUENTE: la API propia en AWS (batchtoday.us), que a su vez consulta
# api.exchange.coinbase.com/products/<PAR>/book?level=1. La logica de hablar con
# Coinbase vive ALLI, no aqui; este script solo consume y persiste.
#
# OJO CON LA FRESCURA: el servicio de AWS barre ~464 productos en un ciclo y
# Coinbase le aplica rate limit, asi que un par concreto se refresca cada ~65 s,
# no cada 10. Por eso se guarda `edad_ms`: las filas repetidas quedan marcadas
# como viejas en vez de disimularse. Filtra con `WHERE edad_ms < 15000` si
# quieres solo observaciones genuinas. Si en AWS se activa una lista caliente
# para este par, `edad_ms` baja solo y no hay que tocar nada de aqui.
#
# MISMA TRAMPA QUE JUPITER: si el producto no existe la API NO da error, devuelve
# un texto de estado. Por eso se comprueba que `name` sea el par pedido ANTES de
# guardar.
set -u
BASE="${SENTINEL_BASE:-$HOME/PRC_Sentinel/v2}"
CONF="$BASE/sentinel.conf"
[ -r "$CONF" ] || exit 0
. "$CONF"
RQ="${RQLITE:-http://127.0.0.1:4001}"
URL="${LIBRO_URL:-https://batchtoday.us/price}"
PAR="${LIBRO_PAR:-BTC-USD}"
EXC="${LIBRO_EXCHANGE:-coinbase}"
PASO="${CRIPTO_SEGUNDOS:-10}"
DIAS="${CRIPTO_RETENCION_DIAS:-90}"

# Me toca? Los mismos nodos que recolectan precio, mas el Wheel.
W=""; [ -r "$BASE/wheel.state" ] && W=$(tr -d '[:space:]' < "$BASE/wheel.state")
me=0
[ "$W" = "${NAME:-}" ] && me=1
for x in $(printf '%s' "${CRIPTO_NODOS:-}" | tr ', ' '\n\n'); do
  [ "$x" = "${NAME:-}" ] && me=1
done
[ "$me" = "1" ] || exit 0

LOCK="$BASE/.libro.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  lt=$(stat -c %Y "$LOCK" 2>/dev/null || echo 0); ahora=$(date +%s 2>/dev/null || echo 0)
  if [ "$lt" -gt 0 ] && [ $((ahora - lt)) -gt 300 ]; then rmdir "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || exit 0
  else exit 0; fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM HUP

sql(){ curl -s -m 10 -o /dev/null -H "Content-Type: application/json" -d "$1" "$RQ/db/execute"; }

# num <json> <campo>  ->  el valor numerico, venga entrecomillado o no.
# La API devuelve los precios como texto ("ask":"78201.02") pero los contadores
# como numero ("ask_numorders":3). El "\":\"" del patron evita que `ask` case
# tambien con `ask_size` o `ask_numorders`.
num(){
  printf '%s' "$1" | grep -oE "\"$2\":\"?[0-9]+\.?[0-9]*\"?" | head -1 \
    | grep -oE '[0-9]+\.?[0-9]*' | head -1
}

# ts_fuente y edad_ms se calculan EN SQLite, no aqui: rqlite parsea el ISO-8601
# de Coinbase con nanosegundos y zona Z sin ayuda, y asi se evita depender de la
# implementacion de `date` en cada nodo (Termux, Fire OS y Ubuntu no coinciden).
sql '[["CREATE TABLE IF NOT EXISTS cripto_libro (par TEXT NOT NULL, exchange TEXT NOT NULL, ts INTEGER NOT NULL, ask REAL, ask_size REAL, ask_numorders INTEGER, bid REAL, bid_size REAL, bid_numorders INTEGER, ts_fuente INTEGER, edad_ms INTEGER, nodo TEXT, PRIMARY KEY (par, exchange, ts))"]]'
sql '[["CREATE INDEX IF NOT EXISTS ix_libro_ts ON cripto_libro(ts)"]]'

# El bucle termina 3 s ANTES del proximo minuto, no 57 s despues de arrancar.
# MEDIDO (2026-08-29): con "+57" el proceso seguia vivo en el segundo exacto en
# que cron disparaba el siguiente; este no conseguia el lock, se iba, y se perdia
# un minuto ENTERO de forma alterna (observado 16:36:59 proceso vivo →
# 16:37:01 lock libre y cero procesos). Anclar el final a la rejilla del minuto
# deja holgura y la serie queda continua.
ini=$(date +%s)
fin=$(( ini - ini % 60 + 57 ))
# Arranque tardio: mejor ceder el turno que solaparse con el siguiente cron.
[ $(( fin - ini )) -lt 5 ] && exit 0

while [ "$(date +%s)" -lt "$fin" ]; do
  t=$(date +%s); bucket=$(( t / PASO * PASO ))
  r=$(curl -s -m 8 "$URL/$PAR" 2>/dev/null)
  nom=$(printf '%s' "$r" | grep -oE '"name":"[A-Za-z0-9._-]+"' | head -1 | cut -d'"' -f4)

  if [ "$nom" = "$PAR" ]; then
    a=$(num  "$r" ask);   asz=$(num "$r" ask_size); ano=$(num "$r" ask_numorders)
    b=$(num  "$r" bid);   bsz=$(num "$r" bid_size); bno=$(num "$r" bid_numorders)
    du=$(printf '%s' "$r" | grep -oE '"dateupdate":"[^"]*"' | head -1 | cut -d'"' -f4)

    # ask/bid a 0 = el barrido de AWS aun no ha llegado a este par. No es dato.
    ok=0
    case "${a:-0}" in ''|0|0.0) : ;; *) case "${b:-0}" in ''|0|0.0) : ;; *) ok=1 ;; esac ;; esac

    if [ "$ok" = "1" ] && [ -n "$du" ]; then
      sql "[[\"INSERT OR IGNORE INTO cripto_libro(par,exchange,ts,ask,ask_size,ask_numorders,bid,bid_size,bid_numorders,ts_fuente,edad_ms,nodo) VALUES(?,?,?,?,?,?,?,?,?,CAST(strftime('%s',?) AS INTEGER),($bucket-CAST(strftime('%s',?) AS INTEGER))*1000,?)\",\"$PAR\",\"$EXC\",$bucket,$a,${asz:-0},${ano:-0},$b,${bsz:-0},${bno:-0},\"$du\",\"$du\",\"${NAME}\"]]"
    fi
  fi

  ahora=$(date +%s); sig=$(( ahora / PASO * PASO + PASO ))
  d=$(( sig - ahora ))
  # No dormir mas alla del final: si lo hiciera, el proceso despertaria justo
  # en el segundo del siguiente cron y volveria a robarle el turno.
  [ $(( ahora + d )) -gt "$fin" ] && d=$(( fin - ahora ))
  [ "$d" -gt 0 ] && sleep "$d"
done

MARCA="$BASE/.libro-podado"
HOY=$(date +%Y-%m-%d)
if [ "$(cat "$MARCA" 2>/dev/null)" != "$HOY" ]; then
  sql "[[\"DELETE FROM cripto_libro WHERE ts < strftime('%s','now')-${DIAS}*86400\"]]"
  printf '%s\n' "$HOY" > "$MARCA"
fi
exit 0
