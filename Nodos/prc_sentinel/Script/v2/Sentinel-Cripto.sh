#!/usr/bin/env sh
# Sentinel v2 - Precio de WBTC en la base de la red, desde el agente Jupiter.
#
# FUENTE UNICA: el agente `prc-agent-jupiter` que corre en sentinel016. Por
# diseno solo sostiene UNA moneda caliente a la vez, asi que se consulta solo
# WBTC: preguntando siempre lo mismo, el precio se mantiene fresco (medido: 18 de
# 18 muestras por debajo de 1 s de antiguedad). Al alternar simbolos, en cambio,
# el agente cambia de pagina y devuelve valores de 15-20 s.
#
# REDUNDANCIA: varios nodos muestrean el MISMO instante a proposito. Si uno se
# atasca —cosa que pasa en esta flota— otro ya tiene la muestra y no queda hueco
# en la grafica. No duplica filas porque la clave primaria es
# (par, exchange, instante redondeado) con INSERT OR IGNORE.
#
# OJO CON EL PARAMETRO: solo `symbol=` y `token=` funcionan. Con `a=`, `pair=` o
# `id=` el agente NO da error: devuelve SOL como si nada. Por eso se comprueba
# que el activo devuelto sea el pedido ANTES de guardar; si no, se descarta.
set -u
BASE="${SENTINEL_BASE:-$HOME/PRC_Sentinel/v2}"
CONF="$BASE/sentinel.conf"
[ -r "$CONF" ] || exit 0
. "$CONF"
RQ="${RQLITE:-http://127.0.0.1:4001}"
JUP="${JUPITER_URL:-http://192.168.1.91:3011}"
SIM="${CRIPTO_SIMBOLO:-WBTC}"
PAR="${CRIPTO_PAR:-WBTC-USD}"
PASO="${CRIPTO_SEGUNDOS:-10}"
DIAS="${CRIPTO_RETENCION_DIAS:-90}"

# ¿Me toca? Los nodos listados, mas el Wheel (para que nunca falte recolector).
W=""; [ -r "$BASE/wheel.state" ] && W=$(tr -d '[:space:]' < "$BASE/wheel.state")
me=0
[ "$W" = "${NAME:-}" ] && me=1
for x in $(printf '%s' "${CRIPTO_NODOS:-}" | tr ', ' '\n\n'); do
  [ "$x" = "${NAME:-}" ] && me=1
done
[ "$me" = "1" ] || exit 0

LOCK="$BASE/.cripto.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  lt=$(stat -c %Y "$LOCK" 2>/dev/null || echo 0); ahora=$(date +%s 2>/dev/null || echo 0)
  if [ "$lt" -gt 0 ] && [ $((ahora - lt)) -gt 300 ]; then rmdir "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || exit 0
  else exit 0; fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM HUP

sql(){ curl -s -m 10 -o /dev/null -H "Content-Type: application/json" -d "$1" "$RQ/db/execute"; }

# edad_ms se guarda a proposito: si alguna muestra llega vieja, queda constancia
# en el dato en vez de disimularse. nodo dice quien la escribio primero, que es
# la forma de ver si la redundancia esta trabajando.
sql '[["CREATE TABLE IF NOT EXISTS cripto_precio (par TEXT NOT NULL, exchange TEXT NOT NULL, ts INTEGER NOT NULL, precio REAL NOT NULL, edad_ms INTEGER, nodo TEXT, PRIMARY KEY (par, exchange, ts))"]]'
sql '[["CREATE INDEX IF NOT EXISTS ix_cripto_ts ON cripto_precio(ts)"]]'

fin=$(( $(date +%s) + 57 ))
while [ "$(date +%s)" -lt "$fin" ]; do
  t=$(date +%s); bucket=$(( t / PASO * PASO ))
  r=$(curl -s -m 5 "$JUP/price?symbol=$SIM" 2>/dev/null)
  act=$(printf '%s' "$r" | grep -oE '"asset":"[A-Za-z0-9]+"' | cut -d'"' -f4)
  p=$(printf '%s' "$r"   | grep -oE '"price":"\$[0-9.]+"' | grep -oE '[0-9]+\.?[0-9]*')
  e=$(printf '%s' "$r"   | grep -oE '"ageMs":[0-9]+' | grep -oE '[0-9]+$')
  if [ "$act" = "$SIM" ]; then
    case "${p:-}" in ''|*[!0-9.]*) : ;; *)
      sql "[[\"INSERT OR IGNORE INTO cripto_precio(par,exchange,ts,precio,edad_ms,nodo) VALUES(?,?,?,?,?,?)\",\"$PAR\",\"jupiter\",$bucket,$p,${e:-0},\"${NAME}\"]]" ;;
    esac
  fi
  ahora=$(date +%s); sig=$(( ahora / PASO * PASO + PASO ))
  d=$(( sig - ahora )); [ "$d" -gt 0 ] && sleep "$d"
done

MARCA="$BASE/.cripto-podado"
HOY=$(date +%Y-%m-%d)
if [ "$(cat "$MARCA" 2>/dev/null)" != "$HOY" ]; then
  sql "[[\"DELETE FROM cripto_precio WHERE ts < strftime('%s','now')-${DIAS}*86400\"]]"
  printf '%s\n' "$HOY" > "$MARCA"
fi
exit 0
