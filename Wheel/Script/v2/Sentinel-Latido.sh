#!/usr/bin/env sh
# Sentinel v2 - Latido hacia la EC2 (timer cada 5 min en sentinel014 y sentinel016).
#
# POR QUE: los avisos los da el Wheel desde DENTRO de casa. Si se va la luz o el
# internet, o si el propio Wheel tiene el cron parado, nadie de dentro puede
# avisar, y el silencio se confunde con "todo bien". Esto manda a la EC2 una linea
# cada 5 min con quien la manda y cuando fue la ultima pasada de avisos (la escribe
# Sentinel-Alert.sh en la tabla sentinel_vigia). La EC2 (latido-vigilar.sh) avisa
# por Telegram si los latidos dejan de llegar o si los avisos dejan de correr.
# Linea: <nodo> <ts_ultima_pasada> <wheel> <pendientes> <readyz_de_mi_rqlite>.
# El ultimo campo es el estado de MI rqlite visto desde aqui:
#   200 = ok;  503 = sin lider;  000 = mi rqlited no responde;
#   401 = rqlite rechaza mis credenciales. Sale de la consulta a sentinel_vigia y
#         manda aunque /readyz diga 200: /readyz queda abierto a todos (usuario
#         "*") y la consulta no, asi que solo ella delata una contrasena mala.
#
# Lo mandan los dos equipos fijos: si cae uno, el otro sigue latiendo y la EC2 no
# confunde "un mini-PC caido" (eso ya lo avisa el Wheel) con "la casa sin red".
#
# La llave solo sirve para esto: en la EC2 va con restrict y command= fijo, asi que
# no abre una shell ni reenvia puertos, y el nombre del nodo lo pone la EC2.
#
# Configuracion (sentinel.conf): LATIDO_DESTINO=usuario@host de la EC2. Vacio = no
# hace nada, asi que este fichero puede ir a toda la flota sin efecto.
# LATIDO_LLAVE (opcional): por defecto ~/.ssh/sentinel_latido.
set -u
BASE="${SENTINEL_BASE:-$HOME/PRC_Sentinel/v2}"
CONF="$BASE/sentinel.conf"
[ -r "$CONF" ] || exit 0
. "$CONF"
# Credenciales de rqlite: fichero 600 con una linea  user = "usuario:clave".
# Van por -K, asi no salen en ps. Sin fichero se pregunta sin credenciales, como
# siempre: un rqlited sin -auth las ignora de todos modos.
RQLITE_CRED="${RQLITE_CRED:-$HOME/.config/rqlite/sentinel.curlrc}"
rqcurl(){ if [ -r "$RQLITE_CRED" ]; then curl -K "$RQLITE_CRED" "$@"; else curl "$@"; fi; }
DEST="${LATIDO_DESTINO:-}"
[ -n "$DEST" ] || exit 0
KEY="${LATIDO_LLAVE:-$HOME/.ssh/sentinel_latido}"
[ -r "$KEY" ] || { echo "latido: falta la llave $KEY"; exit 1; }
RQ="${RQLITE:-http://127.0.0.1:4001}"

# Copia local (level=none): responde aunque el cluster no tenga lider, y el dato
# que interesa es justo si el Wheel sigue escribiendo.
# El codigo HTTP va en la ultima linea y se separa del cuerpo.
R=$(rqcurl -s -m 8 -G "$RQ/db/query" -w '\n%{http_code}' \
      --data-urlencode "q=SELECT ts, wheel, pendientes FROM sentinel_vigia WHERE clave='avisos'" \
      --data-urlencode "level=none" 2>/dev/null)
qc=$(printf '%s' "$R" | tail -n 1)
R=$(printf '%s\n' "$R" | sed '$d')
V=$(printf '%s' "$R" | grep -oE '"values":\[\[[^]]*' | sed 's/.*\[\[//' | tr -d '" ')
ts=$(printf '%s' "$V" | cut -d, -f1); wh=$(printf '%s' "$V" | cut -d, -f2); pe=$(printf '%s' "$V" | cut -d, -f3)
case "$ts" in ''|*[!0-9]*|0?*) ts=0 ;; esac
case "$pe" in ''|*[!0-9]*|0?*) pe=0 ;; ?????*) pe=9999 ;; esac   # la EC2 admite 4 cifras
case "$wh" in ''|*[!A-Za-z0-9_-]*|?????????????????????????????????*) wh=- ;; esac
# Como esta MI rqlite: si no tiene lider, el Wheel tampoco puede apuntar sus
# pasadas, y la EC2 debe decir eso y no "el Wheel no vigila".
rz=$(rqcurl -s -m 5 -o /dev/null -w '%{http_code}' "$RQ/readyz" 2>/dev/null)
case "$rz" in [0-9][0-9][0-9]) ;; *) rz=000 ;; esac
# Credenciales rechazadas: este nodo no puede leer sentinel_vigia (y, si es el
# Wheel, tampoco apuntar sus pasadas). Tiene prioridad sobre lo que diga /readyz.
[ "$qc" = 401 ] && rz=401

T=""; command -v timeout >/dev/null 2>&1 && T="timeout 40"
printf '%s %s %s %s %s\n' "${NAME:-?}" "$ts" "$wh" "$pe" "$rz" \
  | $T ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=5 \
        -o ServerAliveCountMax=3 -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes "$DEST" 2>&1 | tail -n 1
exit 0
