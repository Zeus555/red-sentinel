#!/data/data/com.termux/files/usr/bin/sh
# thermal-guard.sh — guardia térmico + de disco para la flota Sentinel (Android/Termux).
# Lee temperatura de batería y espacio en disco, los registra en rqlite, avisa por Telegram
# y, al cruzar el umbral térmico crítico, descarga la CPU para enfriar (sin root no hay poweroff).
# Cron cada minuto. Debe ser MUY ligero.

CONF="$HOME/PRC_Thermal/thermal-guard.conf"
[ -f "$CONF" ] && . "$CONF"

: "${WARN:=45}"      # alerta temprana
: "${CRIT:=50}"      # enfriar: matar carga Sentinel + wake-unlock + retener
: "${EMERG:=55}"     # emergencia: además bajar rqlited
: "${REARM:=42}"     # por debajo de esto: recuperar servicios
: "${DISK_WARN_PCT:=10}"   # alerta si el % libre baja de esto
: "${DISK_CRIT_PCT:=5}"    # alerta crítica de disco
: "${BOT_TOKEN:=}"
: "${CHAT_ID:=}"
: "${MINGAP:=900}"   # segundos mínimos entre alertas del mismo nivel
: "${RQLITE:=http://localhost:4001}"

STATE="$HOME/PRC_Thermal"
HOLD="$STATE/.thermal_hold"
LAST="$STATE/.last_alert"        # rate-limit de temperatura
LASTD="$STATE/.last_alert_disk"  # rate-limit de disco interno
LASTS="$STATE/.last_alert_sd"    # rate-limit de SD
mkdir -p "$STATE"

# Nombre SIEMPRE en minusculas: las tablas y el NODE_MAP del bot deben casar.
NAME="$( . "$HOME/.profile" 2>/dev/null; echo "${Name:-$(hostname 2>/dev/null || echo sentinel)}" | tr 'A-Z' 'a-z' )"

# --- id de Raft del nodo (cacheado: se extrae del cmdline de rqlited una sola vez) ---
RAFTF="$STATE/.raft_id"
if [ -s "$RAFTF" ]; then
    RAFT_ID=$(cat "$RAFTF")
else
    RAFT_ID=$(ps -fea 2>/dev/null | grep "[r]qlited" | grep -oE '\-node-id [a-zA-Z0-9]+' | head -1 | awk '{print $2}')
    [ -n "$RAFT_ID" ] && echo "$RAFT_ID" > "$RAFTF"
fi

now=$(date +%s)

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
SRC="battery"
raw="$( timeout 10 termux-battery-status 2>/dev/null | sed -n 's/.*"temperature":[ ]*\([0-9.]*\).*/\1/p' | head -1 )"
if [ -z "$raw" ]; then
    tz="$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)"
    if [ -n "$tz" ]; then raw=$(( tz / 1000 )); SRC="thermal_zone0"; fi
fi

if [ -n "$raw" ]; then
    TEMP=${raw%%.*}
    if   [ "$TEMP" -ge "$EMERG" ]; then LVL=EMERG
    elif [ "$TEMP" -ge "$CRIT"  ]; then LVL=CRIT
    elif [ "$TEMP" -ge "$WARN"  ]; then LVL=WARN
    else                                LVL=OK
    fi

    curl -s --max-time 8 -H "Content-Type: application/json" \
        -d "[[\"INSERT INTO sentinel_temp(node,ts,temp_c,source,level,raft_node_id) VALUES(?,?,?,?,?,?)\",\"$NAME\",$now,$raw,\"$SRC\",\"$LVL\",\"$RAFT_ID\"]]" \
        "$RQLITE/db/execute" >/dev/null 2>&1

    cooldown() {
        pkill -f "Sentinel-Server.awk" 2>/dev/null
        pkill -f "Sentinel-Clone"      2>/dev/null
        termux-wake-unlock 2>/dev/null
        touch "$HOLD"
    }

    case "$LVL" in
        EMERG)
            cooldown
            SVDIR="$PREFIX/var/service" sv down rqlited 2>/dev/null
            send "$LAST" EMERG "🔥🚨" "EMERGENCIA térmica: carga apagada y rqlited detenido para enfriar. (batería ${TEMP}°C)"
            ;;
        CRIT)
            cooldown
            send "$LAST" CRIT "🔥" "Crítico: descargando CPU (Sentinel detenido) para enfriar. (batería ${TEMP}°C)"
            ;;
        WARN)
            send "$LAST" WARN "⚠️" "Advertencia: temperatura de batería elevada. (batería ${TEMP}°C)"
            ;;
        OK)
            if [ -f "$HOLD" ] && [ "$TEMP" -lt "$REARM" ]; then
                rm -f "$HOLD"
                SVDIR="$PREFIX/var/service" sv up rqlited 2>/dev/null
                termux-wake-lock 2>/dev/null
                send "$LAST" OK "✅" "Recuperado: temperatura normal, servicios restaurados. (batería ${TEMP}°C)"
            fi
            ;;
    esac
fi

##############################  DISCO  ##############################
INT=$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2{print $2" "$4}')
SD_TOTAL=null; SD_FREE=null
sdp=$(readlink -f "$HOME/storage/external-1" 2>/dev/null)
if [ -n "$sdp" ] && [ -d "$sdp" ]; then
    SD=$(df -Pk "$sdp" 2>/dev/null | awk 'NR==2{print $2" "$4}')
    if [ -n "$SD" ]; then SD_TOTAL=${SD% *}; SD_FREE=${SD#* }; fi
fi

if [ -n "$INT" ]; then
    curl -s --max-time 8 -H "Content-Type: application/json" \
        -d "[[\"INSERT INTO sentinel_disk(node,raft_node_id,ts,int_total_kb,int_free_kb,sd_total_kb,sd_free_kb) VALUES(?,?,?,?,?,?,?)\",\"$NAME\",\"$RAFT_ID\",$now,${INT% *},${INT#* },$SD_TOTAL,$SD_FREE]]" \
        "$RQLITE/db/execute" >/dev/null 2>&1

    it=${INT% *}; ifr=${INT#* }
    if [ "$it" -gt 0 ] 2>/dev/null; then
        pct=$(( ifr * 100 / it )); gb=$(( ifr / 1048576 ))
        if   [ "$pct" -lt "$DISK_CRIT_PCT" ]; then
            send "$LASTD" DCRIT "💾🚨" "Espacio CRÍTICO en memoria interna: ${pct}% libre (~${gb} GB)."
        elif [ "$pct" -lt "$DISK_WARN_PCT" ]; then
            send "$LASTD" DWARN "💾" "Poco espacio en memoria interna: ${pct}% libre (~${gb} GB)."
        fi
    fi
fi

if [ "$SD_TOTAL" != "null" ] && [ "$SD_TOTAL" -gt 0 ] 2>/dev/null; then
    pcs=$(( SD_FREE * 100 / SD_TOTAL )); gbs=$(( SD_FREE / 1048576 ))
    if   [ "$pcs" -lt "$DISK_CRIT_PCT" ]; then
        send "$LASTS" SDCRIT "💾🚨" "Espacio CRÍTICO en tarjeta SD: ${pcs}% libre (~${gbs} GB)."
    elif [ "$pcs" -lt "$DISK_WARN_PCT" ]; then
        send "$LASTS" SDWARN "💾" "Poco espacio en tarjeta SD: ${pcs}% libre (~${gbs} GB)."
    fi
fi

exit 0
