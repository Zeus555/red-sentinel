#!/usr/bin/env sh
# Sentinel v2 - Lanzador comun del terminador mTLS (runit y systemd).
# Toda la logica esta en Sentinel-TLS.sh: instalar stunnel (espaciado), generar
# la configuracion y ceder el proceso a stunnel. Aqui solo se lee la conf.
exec 2>&1
BASE="${SENTINEL_BASE:-$HOME/PRC_Sentinel/v2}"
CONF="$BASE/sentinel.conf"
[ -r "$CONF" ] || { echo "[sentinel-v2-tls] falta $CONF"; sleep 30; exit 1; }
. "$CONF"
export SENTINEL_CERTS="$BASE/Certs"
export SENTINEL_RUN="$BASE/_run"
exec sh "$BASE/Sentinel-TLS.sh" "${NAME}" "${TLS_PORT:-8443}" "${PORT:-8181}"
