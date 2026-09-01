#!/usr/bin/env sh
# Sentinel v2 - Lanzador comun del aceptador (runit en Termux, systemd en Ubuntu).
#
# Existe para que las dos plataformas arranquen EXACTAMENTE igual. Antes runit
# usaba un script (que leia fleet.token, comprobaba el token y frenaba por
# temperatura) y systemd llamaba a gawk directo con EnvironmentFile. Eso tenia
# dos fallos graves en Ubuntu:
#   - systemd NO leia fleet.token, asi que el servicio arrancaba con TOKEN vacio
#     y el nodo quedaba ABIERTO a toda la LAN.
#   - EnvironmentFile no entiende comentarios en linea: "ROLE=Nodo  # ..." dejaba
#     el comentario dentro del valor.
# Con un unico lanzador en sh, ambos comparten comportamiento y no hay que
# arreglar las cosas dos veces.

exec 2>&1

BASE="${SENTINEL_BASE:-$HOME/PRC_Sentinel/v2}"
CONF="$BASE/sentinel.conf"

[ -r "$CONF" ] || { echo "[sentinel-v2] falta $CONF"; sleep 30; exit 1; }
. "$CONF"

# El token de FLOTA vive en su propio fichero para poder repartirlo y rotarlo
# copiando uno solo. Si existe, manda sobre lo que diga sentinel.conf.
[ -r "$BASE/fleet.token" ] && TOKEN=$(cat "$BASE/fleet.token")

# --- Fail-fast de configuracion -------------------------------------------
# Arrancar sin token dejaria el backend abierto a toda la LAN: gawk solo sabe
# atar 0.0.0.0 y el token es la unica defensa del puerto en claro.
case "${TOKEN:-}" in
  ""|CAMBIAME)
    echo "[sentinel-v2] sin token de FLOTA: crealo con Sentinel-Token.sh create (primer nodo) o import (resto). No arranco."
    sleep 60; exit 1 ;;
esac

# --- Freno termico (solo donde hay sensor: telefonos) ----------------------
# thermal-guard mata la carga de Sentinel a CRIT para enfriar, pero fue escrito
# para el v1, que lo supervisaba cron (tardaba ~1 min en volver). Los
# supervisores relanzan AL INSTANTE, asi que sin esto la proteccion termica
# quedaria anulada. El servicio se aparta solo mientras haga calor, sin tocar
# thermal-guard (que es codigo en produccion en todos los nodos).
CRIT=50
[ -r "$HOME/PRC_Thermal/thermal-guard.conf" ] && \
  CRIT=$(gawk -F= '/^[ \t]*CRIT[ \t]*=/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$HOME/PRC_Thermal/thermal-guard.conf" 2>/dev/null || echo 50)
[ -n "$CRIT" ] || CRIT=50

TEMP=""
if command -v termux-battery-status >/dev/null 2>&1; then
  TEMP=$(termux-battery-status 2>/dev/null | gawk -F: '/temperature/{gsub(/[^0-9.]/,"",$2); print int($2); exit}')
fi
if [ -z "$TEMP" ] && [ -r /sys/class/thermal/thermal_zone0/temp ]; then
  TEMP=$(gawk '{print int($1/1000)}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
fi
if [ -n "$TEMP" ] && [ "$TEMP" -ge "$CRIT" ] 2>/dev/null; then
  echo "[sentinel-v2] ${TEMP}C >= CRIT ${CRIT}C: me aparto para dejar enfriar"
  sleep 120; exit 1
fi

mkdir -p "$BASE/jobs"

# --- Purga de arranque -----------------------------------------------------
# El reaper solo borra lo que registro EN MEMORIA, asi que los ficheros de
# ejecuciones anteriores al reinicio quedarian huerfanos para siempre.
find "$BASE/jobs" -type f \( -name '*.status' -o -name '*.sql' \) -mtime +1 -delete 2>/dev/null

# El token va por el ENTORNO y no por -v: la linea de comandos es visible en la
# lista de procesos (world-readable en /proc de Linux) y este token es la unica
# defensa del puerto en claro. El worker lo hereda de aqui, sin pasar por argv.
export SENTINEL_TOKEN="$TOKEN"

exec gawk \
  -v Port="${PORT:-8181}" \
  -v role="${ROLE:-Nodo}" \
  -v jobs="$BASE/jobs" \
  -v worker="$BASE/Sentinel-Worker.awk" \
  -v allow="$BASE/Sentinel-Allow.conf" \
  -v run="$HOME/PRC_Sentinel/Run" \
  -v peers="$BASE/peers.tsv" \
  -v dbhot="${DBHOT:-}" \
  -v dbsim="${DBSIM:-}" \
  -v maxjobs="${MAXJOBS:-4}" \
  -v maxqueue="${MAXQUEUE:-64}" \
  -v jobttl="${JOBTTL:-300}" \
  -v name="${NAME}" \
  -v wheelstate="$BASE/wheel.state" \
  -v elector="$BASE/Sentinel-Wheel.awk" \
  -v discoverer="$BASE/Sentinel-Discover.awk" \
  -v cidr="${CIDR:-}" \
  -v eligible="${WHEEL_ELIGIBLE:-yes}" \
  -v electsecs="${ELECTSECS:-300}" \
  -v spoolttl="${SPOOLTTL:-86400}" \
  -v locktries="${LOCKTRIES:-3}" \
  -v locksecs="${LOCKSECS:-30}" \
  -f "$BASE/Sentinel-Server2.awk"
