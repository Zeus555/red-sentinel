#!/usr/bin/env sh
# Sentinel v2 - Precio de criptomonedas en la base de la red.
#
# Primer trabajo REAL de la flota mas alla de vigilarse a si misma: guardar el
# precio de BTC cada 10 s. Sirve de prueba de carga controlada — por eso hay una
# foto de estabilidad antes y otra despues.
#
# QUIEN LO EJECUTA: solo el Wheel, con el mismo patron que las alertas. Corre por
# cron en todos, pero cada uno comprueba si le toca. Asi el trabajo sigue al
# coordinador cuando hay relevo, sin configurar nada en ningun sitio.
#
# CADA 10 s CON CRON DE 1 MINUTO: el cron no baja del minuto, asi que cada
# invocacion cubre su minuto muestreando en la rejilla de 10 s. El instante se
# REDONDEA a multiplos de 10 y es parte de la clave primaria, con INSERT OR
# IGNORE: si durante un relevo dos nodos muestrean a la vez, la fila se escribe
# una sola vez. Sin eso, un cambio de Wheel dejaria precios duplicados.
set -u
BASE="${SENTINEL_BASE:-$HOME/PRC_Sentinel/v2}"
CONF="$BASE/sentinel.conf"
[ -r "$CONF" ] || exit 0
. "$CONF"
RQ="${RQLITE:-http://127.0.0.1:4001}"
PARES="${CRIPTO_PARES:-BTC-USD}"
PASO="${CRIPTO_SEGUNDOS:-10}"
DIAS="${CRIPTO_RETENCION_DIAS:-90}"

# Solo el Wheel
W=""; [ -r "$BASE/wheel.state" ] && W=$(tr -d '[:space:]' < "$BASE/wheel.state")
[ "$W" = "${NAME:-}" ] || exit 0

# Cerrojo: si una vuelta se alarga, la siguiente cede en vez de acumularse.
LOCK="$BASE/.cripto.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  lt=$(stat -c %Y "$LOCK" 2>/dev/null || echo 0); ahora=$(date +%s 2>/dev/null || echo 0)
  if [ "$lt" -gt 0 ] && [ $((ahora - lt)) -gt 300 ]; then rmdir "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || exit 0
  else exit 0; fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM HUP

sql(){ curl -s -m 10 -o /dev/null -H "Content-Type: application/json" -d "$1" "$RQ/db/execute"; }

sql '[["CREATE TABLE IF NOT EXISTS cripto_precio (par TEXT NOT NULL, exchange TEXT NOT NULL, ts INTEGER NOT NULL, precio REAL NOT NULL, PRIMARY KEY (par, exchange, ts))"]]'
sql '[["CREATE INDEX IF NOT EXISTS ix_cripto_ts ON cripto_precio(ts)"]]'

fin=$(( $(date +%s) + 57 ))
while [ "$(date +%s)" -lt "$fin" ]; do
  t=$(date +%s); bucket=$(( t / PASO * PASO ))
  for par in $(printf '%s' "$PARES" | tr ', ' '\n\n' | grep -E '.'); do
    r=$(curl -s -m 6 "https://api.coinbase.com/v2/prices/$par/spot" 2>/dev/null)
    p=$(printf '%s' "$r" | grep -oE '"amount":"[0-9.]+"' | head -1 | grep -oE '[0-9.]+')
    case "${p:-}" in ''|*[!0-9.]*) continue ;; esac
    sql "[[\"INSERT OR IGNORE INTO cripto_precio(par,exchange,ts,precio) VALUES(?,?,?,?)\",\"$par\",\"coinbase\",$bucket,$p]]"
  done
  # Dormir hasta el siguiente punto de la rejilla; asi el muestreo no se desplaza
  # aunque la peticion tarde distinto cada vez.
  ahora=$(date +%s); sig=$(( ahora / PASO * PASO + PASO ))
  d=$(( sig - ahora )); [ "$d" -gt 0 ] && sleep "$d"
done

# Poda diaria. Sin esto, 8.640 filas al dia acaban con el disco del nodo mas
# pequeno, que es el limite real de la red: rqlite replica ENTERA la base en
# todos, asi que la capacidad util es la del equipo con menos espacio libre.
MARCA="$BASE/.cripto-podado"
HOY=$(date +%Y-%m-%d)
if [ "$(cat "$MARCA" 2>/dev/null)" != "$HOY" ]; then
  sql "[[\"DELETE FROM cripto_precio WHERE ts < strftime('%s','now')-${DIAS}*86400\"]]"
  printf '%s\n' "$HOY" > "$MARCA"
fi
exit 0
