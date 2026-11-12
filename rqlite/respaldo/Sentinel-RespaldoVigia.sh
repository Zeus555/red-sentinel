#!/usr/bin/env sh
# Sentinel v2 - Vigia del respaldo de rqlite (timer cada 6 h en sentinel014).
#
# POR QUE EXISTE: Sentinel-Respaldo.sh avisa cuando falla, pero si no llega a
# ejecutarse (sentinel020 apagado, tarea deshabilitada, Git desinstalado) no hay
# nadie que avise, y un respaldo que dejo de correr hace un mes solo se descubre
# el dia que hace falta. Cada copia buena deja una fila en sentinel_respaldo: aqui
# se mira la fecha de la ultima.
#
# POR QUE EN sentinel014: es el equipo fijo de la flota, ya tiene el bot de Telegram
# y no depende de sentinel020. Si el que cae es 014, eso ya lo avisa Sentinel-Alert.
#
# Lee con level=none, de su copia local, para seguir respondiendo sin quorum. Si ni
# asi contesta tambien avisa: no poder comprobarlo no es lo mismo que estar bien.
#
# Avisa al pasar a mal, recuerda cada 24 h mientras siga mal y avisa al recuperarse.
# DRY=1 imprime los mensajes en vez de enviarlos.

set -u
BASE="${SENTINEL_BASE:-$HOME/PRC_Sentinel/v2}"
CONF="$BASE/sentinel.conf"
[ -r "$CONF" ] || exit 0
. "$CONF"
RQ="${RQLITE:-http://127.0.0.1:4001}"

# Credenciales de rqlite: fichero 600 con una linea  user = "usuario:clave".
# Van por -K, asi no salen en ps. Sin fichero se pregunta sin credenciales, como
# siempre: un rqlited sin -auth las ignora de todos modos.
RQLITE_CRED="${RQLITE_CRED:-$HOME/.config/rqlite/sentinel.curlrc}"
rqcurl(){ if [ -r "$RQLITE_CRED" ]; then curl -K "$RQLITE_CRED" "$@"; else curl "$@"; fi; }

MAX_H="${RESPALDO_MAX_HORAS:-30}"
STATE="$BASE/respaldo-vigia.state"
DRY="${DRY:-0}"

TG_CONF="$HOME/PRC_Thermal/thermal-guard.conf"
BOT_TOKEN=""; CHAT_ID=""
if [ -r "$TG_CONF" ]; then
  BOT_TOKEN=$(sed -n 's/^BOT_TOKEN=//p' "$TG_CONF" | tr -d '"'"'"' \r')
  CHAT_ID=$(sed -n 's/^CHAT_ID=//p' "$TG_CONF" | tr -d '"'"'"' \r')
fi

avisar(){ # $1 = texto
  if [ "$DRY" = "1" ]; then printf '[DRY] %s\n' "$1"; return 0; fi
  [ -n "$BOT_TOKEN" ] && [ -n "$CHAT_ID" ] || { echo "sin credenciales de Telegram"; return 1; }
  curl -s -m 15 -o /dev/null \
    --data-urlencode "chat_id=$CHAT_ID" \
    --data-urlencode "text=$1" \
    "https://api.telegram.org/bot$BOT_TOKEN/sendMessage"
}

AHORA=$(date +%s)
# El codigo HTTP va en la ultima linea: un 401 (rqlite rechaza la clave) llega con
# el cuerpo vacio y sin el no se distinguiria de un rqlited que no contesta.
R=$(rqcurl -s -m 10 -w '\n%{http_code}' -G "$RQ/db/query" --data-urlencode "q=SELECT MAX(ts) FROM sentinel_respaldo" --data-urlencode "level=none" 2>/dev/null)
COD=$(printf '%s' "$R" | tail -n 1 | tr -d '\r ')
ULTIMA=$(printf '%s' "$R" | grep -oE '"values":\[\[[0-9]+' | grep -oE '[0-9]+$')
REVISAR="Revisar la tarea \"RED Respaldo - rqlite\" en sentinel020."

if [ -z "$ULTIMA" ] && [ "$COD" = "401" ]; then
  # No dice nada del respaldo, que puede estar al dia: falla la clave de este nodo.
  EST=mal; DET="rqlite rechaza la contraseña de sentinel (401)"
  REVISAR="Revisar el fichero de credenciales de rqlite en ${NAME:-sentinel014} (RQLITE_CRED); el respaldo en sí puede estar bien."
elif [ -z "$ULTIMA" ]; then
  EST=mal; DET="no se pudo leer la fecha del ultimo respaldo en rqlite"
elif [ $(( AHORA - ULTIMA )) -gt $(( MAX_H * 3600 )) ]; then
  EST=mal; DET="el ultimo respaldo es de hace $(( (AHORA - ULTIMA) / 3600 )) h (limite: $MAX_H h)"
else
  EST=ok; DET=""
fi

ANT=$(cut -d' ' -f1 "$STATE" 2>/dev/null)
ULT_AVISO=$(cut -d' ' -f2 "$STATE" 2>/dev/null)
case "${ULT_AVISO:-}" in ''|*[!0-9]*) ULT_AVISO=0 ;; esac

if [ "$EST" = "mal" ]; then
  if [ "$ANT" != "mal" ] || [ $(( AHORA - ULT_AVISO )) -ge 86400 ]; then
    avisar "🔴 Respaldo rqlite: $DET. $REVISAR Avisa ${NAME:-sentinel014}."
    ULT_AVISO=$AHORA
  fi
elif [ "$ANT" = "mal" ]; then
  avisar "🟢 Respaldo rqlite: vuelve a haber copia reciente. Avisa ${NAME:-sentinel014}."
fi

printf '%s %s\n' "$EST" "$ULT_AVISO" > "$STATE"
exit 0
