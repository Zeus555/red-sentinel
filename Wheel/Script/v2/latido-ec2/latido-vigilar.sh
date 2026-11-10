#!/bin/sh
# Sentinel - Vigia de FUERA de casa (cron cada 5 min en la EC2).
#
# Los avisos de la red salen de casa. Esto cubre lo que desde dentro no se puede
# ver, a partir de los latidos que mandan sentinel014 y sentinel016
# (Sentinel-Latido.sh -> latido-recibir.sh):
#   casa     - ningun latido en CASA_MAX: corte de luz o de internet, o los dos
#              mini-PC caidos a la vez;
#   avisos   - llegan latidos, pero la ultima pasada de avisos del Wheel es de hace
#              mas de AVISOS_MAX: el Wheel no esta vigilando (cron parado...) o no
#              puede apuntarlo (rqlite sin lider: lo dice el readyz del latido).
#              40 min porque un relevo normal de Wheel deja hasta ~30 min sin
#              pasadas (2 rondas de eleccion, 7 min de asentamiento y los cron);
#              con 20 avisaba en buena parte de los relevos;
#   telegram - el Wheel vigila, pero sus mensajes no llegan a Telegram.
# Avisa al pasar a mal, recuerda cada RECORDATORIO_H horas y avisa al volver. Si
# el envio falla, la transicion no se da por hecha y se reintenta en la pasada
# siguiente.
#
# Necesita telegram.conf (BOT_TOKEN= y CHAT_ID=, permisos 600) junto a este fichero.
# DRY=1 imprime en vez de enviar. SENTINEL_NOW=<epoch> fija el reloj (pruebas).
set -u
D=$(cd "$(dirname "$0")" && pwd)
STATE="$D/vigilar.state"
LOG="$D/vigilar.log"
DRY="${DRY:-0}"
num(){ case "${1:-}" in ""|*[!0-9]*) printf "%s" "$2" ;; *) printf "%s" "$1" ;; esac; }
CASA_MAX=$(num "${CASA_MAX:-}" 900)
AVISOS_MAX=$(num "${AVISOS_MAX:-}" 2400)
PEND_GRACIA=$(num "${PEND_GRACIA:-}" 600)
# RECORDATORIO_H=0 desactiva el recordatorio, como en Sentinel-Alert.sh.
RECORD=$(( $(num "${RECORDATORIO_H:-}" 24) * 3600 ))
TZV="${TZ_AVISOS:-America/Los_Angeles}"
NOW="${SENTINEL_NOW:-$(date +%s)}"

BOT_TOKEN=""; CHAT_ID=""
if [ -r "$D/telegram.conf" ]; then
  BOT_TOKEN=$(sed -n 's/^BOT_TOKEN=//p' "$D/telegram.conf" | tr -d '"'"'"' \r')
  CHAT_ID=$(sed -n 's/^CHAT_ID=//p' "$D/telegram.conf" | tr -d '"'"'"' \r')
fi

hora(){ TZ="$TZV" date -d "@$1" '+%d/%m %H:%M' 2>/dev/null || printf '%s' "$1"; }
dur(){ s=$1; [ "$s" -ge 0 ] 2>/dev/null || s=0
  if [ "$s" -lt 3600 ]; then echo "$((s / 60)) min"
  elif [ "$s" -lt 86400 ]; then echo "$((s / 3600)) h $(((s % 3600) / 60)) min"
  else echo "$((s / 86400)) d $(((s % 86400) / 3600)) h"; fi; }
registrar(){ printf '%s %s\n' "$(TZ="$TZV" date '+%m-%d %H:%M:%S')" "$1" >> "$LOG"; }

enviar(){ # $1 = texto; 0 solo si Telegram confirma
  if [ "$DRY" = "1" ]; then printf '[DRY] %s\n' "$1"; return 0; fi
  if [ -z "$BOT_TOKEN" ] || [ -z "$CHAT_ID" ]; then registrar "FALLO sin credenciales: $1"; return 1; fi
  # La URL lleva el token del bot: va por la entrada (-K -), no en argv.
  r=$(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$BOT_TOKEN" \
      | curl -s -m 20 -K - -w '\n%{http_code}' --data-urlencode "chat_id=$CHAT_ID" --data-urlencode "text=$1" 2>/dev/null)
  c=$(printf '%s' "$r" | tail -n 1)
  if [ "$c" = 200 ]; then case "$r" in *'"ok":true'*) registrar "ok: $(printf '%s' "$1" | head -n 1)"; return 0 ;; esac; fi
  registrar "FALLO http=${c:-000}: $(printf '%s' "$1" | head -n 1)"
  return 1
}

# --- Leer los latidos -----------------------------------------------------
ULT=0; ULT_NODO="-"; AV=0; AV_W="-"; PEND=0; RZ_MAL=""; RZ_LISTA=""
for f in "$D"/sentinel*.latido; do
  [ -f "$f" ] || continue
  read -r recv nodo ts wh pe rz < "$f" || continue
  case "$recv" in ''|*[!0-9]*|0?*) continue ;; esac
  case "$ts" in ''|*[!0-9]*|0?*) continue ;; esac
  case "$pe" in ''|*[!0-9]*|0?*) continue ;; esac
  if [ "$recv" -gt "$ULT" ]; then ULT=$recv; ULT_NODO=$nodo; fi
  [ $((NOW - recv)) -le "$CASA_MAX" ] || continue
  # La pasada de avisos mas reciente que cuente un latido FRESCO.
  if [ "$ts" -gt "$AV" ]; then AV=$ts; AV_W=$wh; PEND=$pe; fi
  case "${rz:-}" in [0-9][0-9][0-9]) ;; *) rz=200 ;; esac   # latido viejo de 4 campos
  RZ_LISTA="$RZ_LISTA $nodo=$rz"
  [ "$rz" = 200 ] || RZ_MAL="$RZ_MAL $nodo (readyz $rz)"
done

# --- Maquina de estados: clave estado desde ult_aviso ---------------------
NUEVO=""
evaluar(){ # $1=clave $2=ok|mal|- (no evaluado) $3=gracia $4=texto_mal $5=texto_bien
  l=$(grep "^$1 " "$STATE" 2>/dev/null | head -n 1)
  ant=$(printf '%s' "$l" | cut -d' ' -f2); de=$(printf '%s' "$l" | cut -d' ' -f3); ul=$(printf '%s' "$l" | cut -d' ' -f4)
  [ -n "$ant" ] || ant=ok
  case "$de" in ''|*[!0-9]*) de="" ;; esac
  case "$ul" in ''|*[!0-9]*) ul="" ;; esac
  if [ "$2" = "-" ]; then [ -n "$l" ] && NUEVO="$NUEVO$l
"; return 0; fi
  if [ "$2" = mal ]; then
    [ -n "$de" ] || de=$NOW
    if [ $((NOW - de)) -lt "$3" ]; then decl=$ant; else decl=mal; fi
  else decl=ok; fi
  if [ "$ant" = ok ] && [ "$decl" = mal ]; then
    if enviar "$4"; then nl="$1 mal $de $NOW"; else nl="$1 ok $de -"; fi
  elif [ "$ant" = mal ] && [ "$decl" = ok ]; then
    if enviar "$5${de:+ (tras $(dur $((NOW - de))))}"; then nl="$1 ok - -"; else nl="$1 mal ${de:-$NOW} ${ul:--}"; fi
  elif [ "$decl" = mal ]; then
    [ -n "$ul" ] || ul=$NOW
    if [ "$RECORD" -gt 0 ] && [ $((NOW - ul)) -ge "$RECORD" ] && enviar "Recordatorio: $4"; then ul=$NOW; fi
    nl="$1 mal $de $ul"
  else
    [ "$2" = ok ] && de=""
    nl="$1 ok ${de:--} -"
  fi
  NUEVO="$NUEVO$nl
"
}

P="Sentinel (desde la EC2):"
if [ "$ULT" -eq 0 ]; then
  evaluar casa mal "$CASA_MAX" "🔴 $P no ha llegado ningún latido de casa. Revisar Sentinel-Latido.sh en sentinel014 y sentinel016." "🟢 $P llegan los latidos de casa."
  evaluar avisos - 0 "" ""; evaluar telegram - 0 "" ""
elif [ $((NOW - ULT)) -gt "$CASA_MAX" ]; then
  evaluar casa mal 0 "🔴 $P la casa no da señales desde hace $(dur $((NOW - ULT))). Último latido: $ULT_NODO a las $(hora "$ULT"). Puede ser un corte de luz o de internet, o que sentinel014 y sentinel016 estén caídos a la vez." \
                     "🟢 $P la casa vuelve a dar señales"
  evaluar avisos - 0 "" ""; evaluar telegram - 0 "" ""
else
  evaluar casa ok 0 "" "🟢 $P la casa vuelve a dar señales"
  if [ "$AV" -eq 0 ]; then
    evaluar avisos mal "$AVISOS_MAX" "🔴 $P los avisos de la red no han registrado ninguna pasada (sentinel_vigia vacía). Mientras tanto nadie avisará de caídas." "🟢 $P los avisos de la red vuelven a correr"
    evaluar telegram - 0 "" ""
  elif [ $((NOW - AV)) -gt "$AVISOS_MAX" ]; then
    # La causa la decide el readyz del PROPIO Wheel, si es de los que laten: sin
    # lider (503) o con su rqlited caido (000) no puede apuntar sus pasadas aunque
    # este vigilando. Si el Wheel no late (un telefono), se dan las dos causas.
    RZW=$(printf '%s\n' $RZ_LISTA | sed -n "s/^$AV_W=//p" | head -n 1)
    case "$RZW" in
      200) CAUSA="No está pasando: mirar el cron o el timer de $AV_W. Mientras tanto nadie avisa de caídas."
           [ -n "$RZ_MAL" ] && CAUSA="$CAUSA (Además, readyz malo en:$RZ_MAL.)" ;;
      000) CAUSA="El rqlited de $AV_W no responde (readyz 000): no puede apuntar sus pasadas, aunque puede que siga vigilando." ;;
      ?*)  CAUSA="El rqlite de $AV_W no tiene líder (readyz $RZW): no puede apuntar sus pasadas ni se guarda la telemetría, aunque puede que siga vigilando." ;;
      *)   if [ -n "$RZ_MAL" ]; then
             CAUSA="Además rqlite no tiene líder visto desde:$RZ_MAL. Sin líder el Wheel no puede apuntar sus pasadas: puede que siga vigilando."
           else
             CAUSA="O no está pasando (mirar el cron o el timer de $AV_W) o no consigue escribir en su rqlite. Mientras tanto puede que nadie avise de caídas."
           fi ;;
    esac
    evaluar avisos mal 0 "🔴 $P la última pasada registrada de los avisos (Wheel $AV_W) es de las $(hora "$AV"), hace $(dur $((NOW - AV))). $CAUSA" \
                         "🟢 $P los avisos de la red vuelven a correr (Wheel $AV_W)"
    evaluar telegram - 0 "" ""
  else
    evaluar avisos ok 0 "" "🟢 $P los avisos de la red vuelven a correr (Wheel $AV_W)"
    if [ "$PEND" -gt 0 ]; then
      evaluar telegram mal "$PEND_GRACIA" "🟠 $P el Wheel ($AV_W) vigila, pero no consigue mandar sus avisos a Telegram ($PEND pendientes en la última pasada). Revisar ~/PRC_Thermal/thermal-guard.conf en $AV_W." \
                                         "🟢 $P los avisos del Wheel vuelven a llegar a Telegram"
    else
      evaluar telegram ok 0 "" "🟢 $P los avisos del Wheel vuelven a llegar a Telegram"
    fi
  fi
fi

printf '%s' "$NUEVO" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 1000 ]; then
  tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
exit 0
