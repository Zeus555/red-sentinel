#!/data/data/com.termux/files/usr/bin/sh
# Sentinel v2 - Terminador mTLS supervisado por runit (Android/Termux).
# La logica vive en el lanzador COMUN, que systemd usa igual en Ubuntu.
exec 2>&1
sleep 2                      # suelo entre reintentos
exec sh "$HOME/PRC_Sentinel/v2/sentinel-tls-start.sh"
