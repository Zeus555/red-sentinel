#!/usr/bin/env sh
# Sentinel v2 - Disparo periodico de la eleccion de Wheel.
#
# Se ejecuta por cron (Termux) o por timer de systemd (Ubuntu), NO desde dentro
# del aceptador. Lanzarlo con system() desde el propio bucle del servidor hacia
# que el aceptador muriera cada ciclo en los telefonos (reinicio cada ~5 min);
# desacoplarlo lo resuelve y ademas sigue el patron que ya usa thermal-guard.
set -u
BASE="${SENTINEL_BASE:-$HOME/PRC_Sentinel/v2}"
CONF="$BASE/sentinel.conf"
[ -r "$CONF" ] || exit 0
. "$CONF"
[ -r "$BASE/fleet.token" ] && TOKEN=$(cat "$BASE/fleet.token")
[ -n "${TOKEN:-}" ] || exit 0

# --- Reparto en el tiempo -------------------------------------------------
# Sin esto los 11 nodos disparan en el MISMO segundo :00 y cada equipo recibe una
# veintena de peticiones a la vez sobre un aceptador monohilo. Medido el 17/08:
# 148 de los 153 fallos de "no responde" cayeron exactamente en el segundo :00, y
# hubo nodos que en ese instante no se alcanzaban ni a si mismos por 127.0.0.1.
# El desfase es FIJO por nodo y por tarea (sale del nombre), no aleatorio: cada
# equipo tiene siempre su hueco, el reparto no cambia en cada arranque y se puede
# predecir al depurar. Comprobado que con los nombres reales no hay colisiones.
# SENTINEL_NOJITTER=1 lo salta, para probar a mano sin esperar.
if [ "${SENTINEL_NOJITTER:-0}" != "1" ]; then
  _j=$(printf '%s-elect' "${NAME:-x}" | cksum 2>/dev/null | cut -d' ' -f1)
  case "${_j:-}" in ''|*[!0-9]*) _j=0 ;; esac
  [ "$_j" -gt 0 ] && sleep $(( _j % 120 ))
fi

# Cerrojo: dos elecciones simultaneas podrian escribir wheel.state a la vez. Con
# cron cada 5 min y rondas de segundos casi nunca coinciden, pero el reintento de
# sondeo alarga las rondas cuando hay nodos caidos — y justo entonces es cuando
# mas importa no equivocarse. mkdir es atomico en cualquier sistema de ficheros.
LOCK="$BASE/.elect.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  lt=$(stat -c %Y "$LOCK" 2>/dev/null || echo 0)
  ahora=$(date +%s 2>/dev/null || echo 0)
  # Cerrojo huerfano de una ronda que murio a medias: liberarlo pasados 10 min.
  if [ "$lt" -gt 0 ] && [ "$ahora" -gt 0 ] && [ $((ahora - lt)) -gt 600 ]; then
    rmdir "$LOCK" 2>/dev/null
    mkdir "$LOCK" 2>/dev/null || exit 0
  else
    exit 0                # hay otra eleccion en curso: esta ronda se la cede
  fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM HUP

# Se deja rastro. Antes esto iba a /dev/null y, cuando la red acabo con dos
# coordinadores, hubo que reconstruir lo ocurrido a partir de fechas de ficheros.
# Una linea por ronda cuesta nada y responde sola a "¿por que cambio el Wheel?".
LOG="$BASE/elect.log"
# Cada linea con su marca. La eleccion escribe VARIAS por ronda (el diagnostico
# de quien no contesto va aparte del resultado) y con un printf unico solo quedaba
# fechada la primera — justo las marcas que hacen falta para analizar despues.
  gawk -v self="${NAME}" -v port="${PORT:-8181}" -v token="$TOKEN" \
       -v peers="$BASE/peers.tsv" -v state="$BASE/wheel.state" \
       -v rqlite="${RQLITE:-}" -v discover="$BASE/Sentinel-Discover.awk" \
       -v cidr="${CIDR:-}" -v spool="$BASE/jobs" \
  -f "$BASE/Sentinel-Wheel.awk" 2>&1 \
  | awk -v t="$(date '+%m-%d %H:%M:%S')" '{print t, $0}' >> "$LOG"

# La eleccion deja la lista de vecinos en .tmp; ponerla en su sitio es un mv, que
# es atomico: nadie puede leer un peers.tsv a medio escribir. Se exige -s (no
# vacio) para que una ronda fallida no deje al nodo sin plan B.
if [ -s "$BASE/peers.tsv.tmp" ]; then
  mv "$BASE/peers.tsv.tmp" "$BASE/peers.tsv"
else
  rm -f "$BASE/peers.tsv.tmp"
fi

# Recorte: en un telefono el espacio importa y esto escribe cada 5 minutos.
if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 600 ]; then
  tail -n 300 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
fi
exit 0
