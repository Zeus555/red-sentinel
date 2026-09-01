#!/usr/bin/env sh
# Sentinel v2 - Vigilante de salud (cron cada 5 min).
#
# runit y systemd solo reinician procesos MUERTOS. Un aceptador COLGADO —vivo
# pero sin aceptar conexiones— se les escapa: paso en sentinel003, con el proceso
# 12 h en pie y sin responder ni en localhost. El v1 ya cubria esto sondeando
# /sentinelversion y matando clones colgados; al pasar a un supervisor se perdio.
# Esto lo devuelve: si el nodo no contesta a si mismo, se reinicia el servicio.
set -u
BASE="${SENTINEL_BASE:-$HOME/PRC_Sentinel/v2}"
CONF="$BASE/sentinel.conf"
[ -r "$CONF" ] || exit 0
. "$CONF"
[ -r "$BASE/fleet.token" ] && TOKEN=$(cat "$BASE/fleet.token")
[ -n "${TOKEN:-}" ] || exit 0
PORT="${PORT:-8181}"

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
  _j=$(printf '%s-watchdog' "${NAME:-x}" | cksum 2>/dev/null | cut -d' ' -f1)
  case "${_j:-}" in ''|*[!0-9]*) _j=0 ;; esac
  [ "$_j" -gt 0 ] && sleep $(( _j % 120 ))
fi

# Dos intentos con margen: un fallo suelto puede ser el nodo ocupado, no colgado.
for i in 1 2; do
  if curl -s -m 5 -o /dev/null "http://127.0.0.1:$PORT/version?token=$TOKEN"; then exit 0; fi
  sleep 5
done

echo "[watchdog] $(date '+%F %T') el aceptador no responde en :$PORT; reiniciando"
if command -v sv >/dev/null 2>&1 && [ -d "${PREFIX:-}/var/service/sentinel-v2" ]; then
  SVDIR="$PREFIX/var/service" sv restart sentinel-v2
elif command -v systemctl >/dev/null 2>&1; then
  systemctl --user restart sentinel-v2
fi
