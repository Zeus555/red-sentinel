#!/bin/sh
# thermal-guard-linux.sh — guardia térmico + de disco para los nodos Ubuntu de la flota Sentinel.
# Lee temperatura real del núcleo (coretemp/k10temp) y espacio en disco, los registra en rqlite,
# avisa por Telegram y, si escala, suelta rqlited y finalmente APAGA el equipo para protegerlo.
# Cron cada minuto. Umbrales x86 (aquí 40-70 C es normal, muy distinto a un teléfono).
#
# DESPLIEGUE: en los Ubuntu (sentinel014 y sentinel016) se instala como
# ~/PRC_Thermal/thermal-guard.sh, con el mismo nombre que la versión de Termux, y lo
# lanza cron cada minuto. Este fichero es la copia de la que corría allí el 11/11/2026
# con un único cambio funcional: las credenciales de rqlite en los dos INSERT.

CONF="$HOME/PRC_Thermal/thermal-guard.conf"
[ -f "$CONF" ] && . "$CONF"

: "${WARN:=75}"
: "${CRIT:=85}"
: "${EMERG:=92}"
: "${REARM:=70}"
: "${DISK_WARN_PCT:=10}"
: "${DISK_CRIT_PCT:=5}"
: "${BOT_TOKEN:=}"
: "${CHAT_ID:=}"
: "${MINGAP:=900}"
: "${RQLITE:=http://localhost:4001}"

# Credenciales de rqlite: fichero 600 con una linea  user = "usuario:clave".
# Van por -K, asi no salen en ps. Sin fichero se pregunta sin credenciales, como
# siempre: un rqlited sin -auth las ignora de todos modos.
RQLITE_CRED="${RQLITE_CRED:-$HOME/.config/rqlite/sentinel.curlrc}"
rqcurl(){ if [ -r "$RQLITE_CRED" ]; then curl -K "$RQLITE_CRED" "$@"; else curl "$@"; fi; }

STATE="$HOME/PRC_Thermal"
HOLD="$STATE/.thermal_hold"
LAST="$STATE/.last_alert"
LASTD="$STATE/.last_alert_disk"
mkdir -p "$STATE"

# Nombre SIEMPRE en minusculas: las tablas y el NODE_MAP del bot deben casar.
NAME="$(hostname 2>/dev/null || echo sentinel | tr 'A-Z' 'a-z')"
NAME="$(echo "$NAME" | tr 'A-Z' 'a-z')"

# --- id de Raft del nodo (cacheado) ---
RAFTF="$STATE/.raft_id"
if [ -s "$RAFTF" ]; then
    RAFT_ID=$(cat "$RAFTF")
else
    RAFT_ID=$(ps -eo args 2>/dev/null | grep "[r]qlited" | grep -oE '\-node-id [a-zA-Z0-9]+' | head -1 | awk '{print $2}')
    [ -n "$RAFT_ID" ] && echo "$RAFT_ID" > "$RAFTF"
fi

now=$(date +%s)

# sudo puede estar acotado a comandos concretos: probar el comando, no "true".
can_run() { sudo -n -l "$@" >/dev/null 2>&1; }

# send <archivo_estado> <nivel> <emoji> <texto completo>
send() {
    sf="$1"; lvl="$2"; emoji="$3"; msg="$4"
    if [ -f "$sf" ]; then
        pl=$(cut -d' ' -f1 "$sf"); pt=$(cut -d' ' -f2 "$sf")
        [ "$pl" = "$lvl" ] && [ $(( now - pt )) -lt "$MINGAP" ] && return 0
    fi
    echo "$lvl $now" > "$sf"
    [ -z "$BOT_TOKEN" ] || [ -z "$CHAT_ID" ] && return 0
    curl -s --max-time 12 \
        --data-urlencode "chat_id=${CHAT_ID}" \
        --data-urlencode "text=${emoji} [${NAME}] ${msg}" \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" >/dev/null 2>&1
}

##############################  TEMPERATURA  ##############################
best=0; SRC=""
for d in /sys/class/hwmon/hwmon*; do
    n=$(cat "$d/name" 2>/dev/null)
    case "$n" in
        coretemp|k10temp|zenpower|cpu_thermal)
            for f in "$d"/temp*_input; do
                [ -f "$f" ] || continue
                v=$(cat "$f" 2>/dev/null)
                [ -n "$v" ] || continue
                v=$((v / 1000))
                if [ "$v" -gt "$best" ]; then best=$v; SRC="$n"; fi
            done
            ;;
    esac
done
if [ "$best" -le 0 ]; then
    v=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
    if [ -n "$v" ]; then best=$((v / 1000)); SRC="acpitz"; fi
fi

if [ "$best" -gt 0 ]; then
    TEMP=$best
    if   [ "$TEMP" -ge "$EMERG" ]; then LVL=EMERG
    elif [ "$TEMP" -ge "$CRIT"  ]; then LVL=CRIT
    elif [ "$TEMP" -ge "$WARN"  ]; then LVL=WARN
    else                                LVL=OK
    fi

    rqcurl -s --max-time 8 -H "Content-Type: application/json" \
        -d "[[\"INSERT INTO sentinel_temp(node,ts,temp_c,source,level,raft_node_id) VALUES(?,?,?,?,?,?)\",\"$NAME\",$now,$TEMP,\"$SRC\",\"$LVL\",\"$RAFT_ID\"]]" \
        "$RQLITE/db/execute" >/dev/null 2>&1

    case "$LVL" in
        EMERG)
            if can_run /usr/sbin/shutdown; then
                send "$LAST" EMERG "🔥🚨" "EMERGENCIA térmica: APAGANDO el equipo para protegerlo. (CPU ${TEMP}°C)"
                sleep 3
                sudo -n /usr/sbin/shutdown -h now 2>/dev/null
            else
                send "$LAST" EMERG "🔥🚨" "EMERGENCIA térmica pero SIN permiso de apagado. Intervención manual YA. (CPU ${TEMP}°C)"
            fi
            ;;
        CRIT)
            # PROBLEMA CONOCIDO, sin arreglar: esto pide la unidad de SISTEMA rqlited,
            # que no existe (rqlited es una unidad de USUARIO, systemctl --user). Así que
            # rqlited NO se detiene aunque el aviso diga lo contrario, y el start de OK
            # tampoco hace nada.
            can_run /usr/bin/systemctl stop rqlited && sudo -n /usr/bin/systemctl stop rqlited 2>/dev/null
            touch "$HOLD"
            send "$LAST" CRIT "🔥" "Crítico: rqlited detenido para bajar la carga. (CPU ${TEMP}°C)"
            ;;
        WARN)
            send "$LAST" WARN "⚠️" "Advertencia: temperatura de CPU elevada. (CPU ${TEMP}°C)"
            ;;
        OK)
            if [ -f "$HOLD" ] && [ "$TEMP" -lt "$REARM" ]; then
                rm -f "$HOLD"
                can_run /usr/bin/systemctl start rqlited && sudo -n /usr/bin/systemctl start rqlited 2>/dev/null
                send "$LAST" OK "✅" "Recuperado: temperatura normal, rqlited restaurado. (CPU ${TEMP}°C)"
            fi
            ;;
    esac
fi

##############################  DISCO  ##############################
INT=$(df -Pk / 2>/dev/null | awk 'NR==2{print $2" "$4}')
if [ -n "$INT" ]; then
    rqcurl -s --max-time 8 -H "Content-Type: application/json" \
        -d "[[\"INSERT INTO sentinel_disk(node,raft_node_id,ts,int_total_kb,int_free_kb,sd_total_kb,sd_free_kb) VALUES(?,?,?,?,?,?,?)\",\"$NAME\",\"$RAFT_ID\",$now,${INT% *},${INT#* },null,null]]" \
        "$RQLITE/db/execute" >/dev/null 2>&1

    it=${INT% *}; ifr=${INT#* }
    if [ "$it" -gt 0 ] 2>/dev/null; then
        pct=$(( ifr * 100 / it )); gb=$(( ifr / 1048576 ))
        if   [ "$pct" -lt "$DISK_CRIT_PCT" ]; then
            send "$LASTD" DCRIT "💾🚨" "Espacio CRÍTICO en disco: ${pct}% libre (~${gb} GB)."
        elif [ "$pct" -lt "$DISK_WARN_PCT" ]; then
            send "$LASTD" DWARN "💾" "Poco espacio en disco: ${pct}% libre (~${gb} GB)."
        fi
    fi
fi

exit 0
