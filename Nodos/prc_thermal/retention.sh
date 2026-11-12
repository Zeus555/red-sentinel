#!/data/data/com.termux/files/usr/bin/sh
# Purga telemetria (sentinel_temp y sentinel_disk) con mas de RETENTION_DAYS dias.
# Corre UNA vez al dia en UN SOLO nodo (la BD es compartida por el cluster).
# NO toca indeed_jobs (datos del usuario).
#
# DONDE CORRE: solo en sentinel001, como ~/PRC_Thermal/retention.sh, con esta
# linea de cron:
#   30 3 * * * ~/PRC_Thermal/retention.sh >/dev/null 2>&1
# Es la copia de la que corria alli el 11/11/2026; el unico cambio es que lee
# RQLITE y RQLITE_CRED de thermal-guard.conf, como thermal-guard.sh.
CONF="$HOME/PRC_Thermal/thermal-guard.conf"
[ -f "$CONF" ] && . "$CONF"
: "${RQLITE:=http://localhost:4001}"

# Credenciales de rqlite: fichero 600 con una linea  user = "usuario:clave".
# Van por -K, asi no salen en ps. Sin fichero se pregunta sin credenciales, como
# siempre: un rqlited sin -auth las ignora de todos modos.
RQLITE_CRED="${RQLITE_CRED:-$HOME/.config/rqlite/sentinel.curlrc}"
rqcurl(){ if [ -r "$RQLITE_CRED" ]; then curl -K "$RQLITE_CRED" "$@"; else curl "$@"; fi; }

RETENTION_DAYS=90
rqcurl -s --max-time 30 -H "Content-Type: application/json" \
  -d "[[\"DELETE FROM sentinel_temp WHERE ts < strftime('%s','now','-${RETENTION_DAYS} days')\"],[\"DELETE FROM sentinel_disk WHERE ts < strftime('%s','now','-${RETENTION_DAYS} days')\"]]" \
  "$RQLITE/db/execute" >/dev/null 2>&1
