#!/usr/bin/env sh
# Sentinel v2 - Vigilante de instancia UNICA para el Wheel Windows (sentinel013).
#
# Lo llama sentinel-windows.cmd, que lanza el Programador de tareas cada 5 min.
#
# Por que existe: el .cmd de antes hacia un solo curl a /version (3 s y SIN token)
# y, si no contestaba, lanzaba OTRO agente sin mirar si ya habia uno. El viejo no
# estaba muerto, solo lento u ocupado, asi que seguia vivo. Y como gawk cierra y
# reabre el socket de escucha en cada peticion, las copias se turnaban el 8181: la
# que lo pillaba libre atendia. El 10/11/2026 habia 10 copias (del 19/10 al 09/11),
# cada una con su propio elector.
#
# Regla: NUNCA dos copias.
#   - Solo se lanza si no queda NINGUN agente vivo.
#   - Uno colgado se quita POR PID, nunca por patron: el de sentinel.pid (lo
#     escribe este script al lanzar) o el que tiene el puerto segun netstat.
#     Antes de matar se comprueba por /proc que ese PID es de verdad este agente.
#   - Si sigue vivo otro agente que no es ninguno de esos dos, NO se lanza: se
#     deja escrito en server.log para que una persona lo mate a mano por PID.
#
# SENTINEL_DRYRUN=1: recorre toda la decision como si /version no contestara,
# dice lo que haria y no mata ni lanza nada. Escribe en pantalla, no en el log.
set -u

BASE="${SENTINEL_BASE:-$HOME/PRC_Sentinel/v2}"
CONF="$BASE/sentinel.conf"
LOG="$BASE/server.log"
PIDF="$BASE/sentinel.pid"
LOCK="$BASE/.vigilante.lock"
DRY="${SENTINEL_DRYRUN:-0}"

log(){
  if [ "$DRY" = "1" ]; then echo "[vigilante] $*"
  else echo "[vigilante] $(date '+%F %T') $*" >> "$LOG"; fi
}

[ -r "$CONF" ] || { log "falta $CONF"; exit 0; }
. "$CONF"
[ -r "$BASE/fleet.token" ] && TOKEN=$(cat "$BASE/fleet.token")
TOKEN="${TOKEN:-}"
PORT="${PORT:-8181}"
SERVER="$BASE/Sentinel-Server2.awk"

# --- Una sola pasada a la vez ---------------------------------------------
# El .vbs no espera al .cmd, asi que dos pasadas podrian solaparse. mkdir es
# atomico. Una pasada dura menos de 1 min; un candado de mas de 10 es un resto.
if [ "$DRY" != "1" ]; then
  if ! mkdir "$LOCK" 2>/dev/null; then
    edad=$(( $(date +%s) - $(stat -c %Y "$LOCK" 2>/dev/null || echo 0) ))
    [ "$edad" -lt 600 ] && exit 0
    rmdir "$LOCK" 2>/dev/null
    mkdir "$LOCK" 2>/dev/null || exit 0
  fi
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT
fi

# --- Sondeo ------------------------------------------------------------------
# CON token y por stdin (-K -), no en la URL de argv: sin token cada sondeo
# contaba como intento fallido en la puerta del agente (3 seguidos = bloqueo de
# 30 s). Cualquier respuesta HTTP vale: lo que se busca es un aceptador vivo.
responde(){
  printf 'url = "http://127.0.0.1:%s/version?token=%s"\n' "$PORT" "$TOKEN" \
    | curl -s -m "${1:-5}" -o /dev/null -K - 2>/dev/null
}

# --- Identificar procesos ------------------------------------------------------
# Se trabaja con PIDs MSYS (los que entiende kill): se conservan a traves de los
# exec (sh -> sentinel-start.sh -> gawk) y el de Windows no. /proc/<pid>/winpid
# da el de Windows, para cruzarlo con netstat y para el log.
#
# agentes_en: de los /proc/<pid>/cmdline dados, los que son ESTE agente: gawk
# con el argumento exacto <BASE>/Sentinel-Server2.awk y el exacto Port=<PORT>.
# Un solo gawk para todos, porque en MSYS cada proceso cuesta decenas de ms.
agentes_en(){
  gawk -v srv="$SERVER" -v port="Port=$PORT" '
    BEGIN     { RS = "\0" }
    BEGINFILE { g = 0; s = 0; q = 0; if (ERRNO != "") nextfile }
    FNR == 1  { g = ($0 ~ /gawk(\.exe)?$/) }
    $0 == srv  { s = 1 }
    $0 == port { q = 1 }
    ENDFILE   { if (g && s && q) { f = FILENAME; gsub(/^\/proc\/|\/cmdline$/, "", f); print f } }
  ' "$@" 2>/dev/null
}
agentes(){ agentes_en /proc/[0-9]*/cmdline; }
es_agente(){ [ -n "$(agentes_en "/proc/$1/cmdline")" ]; }
arrancando(){  # el sh de sentinel-start.sh, antes de su exec a gawk
  tr '\0' '\n' < "/proc/$1/cmdline" 2>/dev/null | grep -qxF -- "$BASE/sentinel-start.sh"
}
winpid(){ cat "/proc/$1/winpid" 2>/dev/null; }
msys_de_win(){  # PID de Windows -> PID MSYS (vacio si no es un proceso MSYS)
  grep -lxF -- "$1" /proc/[0-9]*/winpid 2>/dev/null | head -n1 | sed 's#^/proc/##; s#/winpid$##'
}
# Quien escucha en el puerto, por PID de Windows. Se filtra por la direccion
# remota 0.0.0.0:0 y no por la palabra LISTENING, que cambia con el idioma.
dueno_puerto(){
  netstat -ano -p TCP 2>/dev/null | tr -d '\r' \
    | gawk -v p=":$PORT" '$1=="TCP" && substr($2, length($2)-length(p)+1)==p && $3=="0.0.0.0:0" {print $5; exit}'
}
matar(){  # $1 = PID MSYS ya comprobado con es_agente
  w=$(winpid "$1")
  if [ "$DRY" = "1" ]; then log "mataria el agente pid $1 (Windows $w)"; return 0; fi
  log "mato el agente pid $1 (Windows $w): no responde"
  kill -TERM "$1" 2>/dev/null
  for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$1" 2>/dev/null || return 0; sleep 1; done
  kill -KILL "$1" 2>/dev/null
  for i in 1 2 3 4 5; do kill -0 "$1" 2>/dev/null || return 0; sleep 1; done
  log "el pid $1 (Windows $w) no muere ni con KILL: no lanzo otro"
  return 1
}

# --- 1. Si contesta, no hay nada que hacer ------------------------------------
# Dos intentos con margen, como watchdog.sh: un fallo suelto suele ser el
# aceptador ocupado (es monohilo), no colgado.
if [ "$DRY" = "1" ]; then
  if responde 5; then log "/version contesta en :$PORT (sigo como si no: es un simulacro)"
  else log "/version NO contesta en :$PORT"; fi
else
  responde 5 && exit 0
  sleep 5
  responde 5 && exit 0
fi

# --- 2. El que lanzamos la ultima vez ----------------------------------------
PREV=""
[ -r "$PIDF" ] && PREV=$(tr -dc '0-9' < "$PIDF")
if [ -n "$PREV" ] && kill -0 "$PREV" 2>/dev/null; then
  if arrancando "$PREV"; then
    log "el pid $PREV sigue en sentinel-start.sh (arrancando o esperando a que enfrie): no lanzo otro"
    exit 0
  fi
  if es_agente "$PREV"; then matar "$PREV" || exit 0
  else PREV=""; fi    # PID reutilizado por otro proceso: no es nuestro
else
  PREV=""
fi

# --- 3. El que tiene el puerto -------------------------------------------------
MP=""
WP=$(dueno_puerto)
if [ -n "$WP" ]; then
  MP=$(msys_de_win "$WP")
  if [ -z "$MP" ] || ! es_agente "$MP"; then
    log "el puerto $PORT lo tiene el PID de Windows $WP, que no es este agente: no lanzo"
    exit 0
  fi
  # En simulacro el de sentinel.pid sigue vivo y puede ser este mismo.
  if [ "$MP" != "$PREV" ]; then matar "$MP" || exit 0; fi
fi

# --- 4. Ninguna otra copia viva ------------------------------------------------
QUEDAN=""
for p in $(agentes); do
  # En simulacro no se ha matado nada: se descuentan los que se habrian matado.
  if [ "$DRY" = "1" ] && { [ "$p" = "$PREV" ] || [ "$p" = "$MP" ]; }; then continue; fi
  QUEDAN="$QUEDAN $p(Windows $(winpid "$p"))"
done
if [ -n "$QUEDAN" ]; then
  log "quedan agentes vivos que no son ni el de sentinel.pid ni el dueno del puerto:$QUEDAN. No lanzo otro; matarlos a mano por PID"
  exit 0
fi

# --- 5. Lanzar -------------------------------------------------------------------
if [ "$DRY" = "1" ]; then log "lanzaria sentinel-start.sh y guardaria su pid en $PIDF"; exit 0; fi
sh "$BASE/sentinel-start.sh" >> "$LOG" 2>&1 < /dev/null &
NUEVO=$!
echo "$NUEVO" > "$PIDF"
# El candado sigue puesto hasta que el nuevo conteste: una pasada que llegara en
# medio vera el pid en sentinel.pid y no lanzaria una segunda copia.
for i in $(seq 1 20); do
  if responde 2; then log "agente lanzado: pid $NUEVO (Windows $(winpid "$NUEVO")), contesta a los ${i} s"; exit 0; fi
  kill -0 "$NUEVO" 2>/dev/null || { log "el agente lanzado (pid $NUEVO) termino sin contestar; ver las lineas de arriba"; exit 0; }
  sleep 1
done
log "agente lanzado: pid $NUEVO (Windows $(winpid "$NUEVO")), pero aun no contesta a los 20 s"
exit 0
