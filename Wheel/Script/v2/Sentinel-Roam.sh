#!/usr/bin/env sh
# Sentinel v2 - Conmutacion de red del nodo movil.
#
# POR QUE EXISTE: sentinel019 es el movil personal y cruza a diario entre la WiFi
# de casa y los datos moviles. Fuera de casa queda tras el CGNAT del operador, y
# como TODA la red Sentinel funciona por sondeo ENTRANTE (la eleccion pide
# /fitness, las alertas piden /fitness, Raft abre conexiones hacia el nodo), el
# telefono desaparecia de la red entera hasta volver. No hay ni un solo flujo de
# registro saliente que pudiera suplirlo.
#
# La malla WireGuard (ver ROAMING_sentinel019.md) resuelve la ALCANZABILIDAD: da
# al movil una IP fija que vale en las dos redes, asi que la identidad-por-IP que
# el proyecto tiene repartida por seis ficheros sigue siendo cierta. Lo que la
# malla NO resuelve es el COSTE: rqlite replica cada escritura a los 11 nodos
# —solo el muestreo de cripto son 8.640 filas al dia— y eso sobre LTE se come el
# plan de datos y la bateria de un telefono personal.
#
# Este script separa las dos capas:
#   - agente v2, sshd y telemetria  -> SIEMPRE. Van por la malla y son unos KB.
#   - rqlited (Raft)                -> SOLO en la WiFi de casa.
#
# Que el nodo salga del cluster al salir de casa NO es una regresion: es
# exactamente lo que ya pasa hoy cuando el movil se va. La diferencia es que
# ahora el agente v2 se queda en pie, que es lo que se buscaba.
#
# COMO DECIDE DONDE ESTA: no mira interfaces. En Android 10+ `ip addr`, `netstat`
# y `ps` devuelven respuestas falsas o vacias a las apps sin privilegios, y esta
# flota ya se quemo con eso. La prueba es FUNCIONAL: se intenta alcanzar el nodo
# semilla de la LAN por su IP domestica. Si contesta, se esta en casa; da igual
# como se llame la interfaz o que IP diga tener.
#
# Invocacion: por cron cada 5 min.
#   */5 * * * * ~/PRC_Sentinel/v2/Sentinel-Roam.sh >/dev/null 2>&1
set -u

BASE="${SENTINEL_BASE:-$HOME/PRC_Sentinel/v2}"
CONF="$BASE/sentinel.conf"
[ -r "$CONF" ] || exit 0
. "$CONF"

# Solo actua donde se ha pedido explicitamente. Sin ROAM_SEED en sentinel.conf
# este script no hace NADA, asi que se puede repartir a la flota entera sin
# riesgo: los nodos fijos salen aqui mismo.
SEED="${ROAM_SEED:-}"
[ -n "$SEED" ] || exit 0

SVC="${ROAM_SVC:-rqlited}"
STATE="$BASE/roam.state"
LOG="$BASE/roam.log"
# Cuantas pasadas seguidas hay que ver el mismo sitio antes de mover nada. A 5
# min por pasada, 2 son 10 min: cubre un cambio de piso o un ascensor sin parar
# y arrancar rqlited cada vez. El flapping de Raft es peor que llegar tarde.
CONFIRMA="${ROAM_CONFIRMA:-2}"

log(){ printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG"; }

# --- Donde estoy -----------------------------------------------------------
# Dos intentos: un fallo suelto sobre WiFi domestica es normal, y declarar
# "estoy fuera" de mas cuesta parar rqlited sin motivo.
en_casa(){
  i=1
  while [ "$i" -le 2 ]; do
    if curl -s -m 4 -o /dev/null "http://$SEED:4001/status?pretty" 2>/dev/null; then
      return 0
    fi
    i=$((i + 1))
    [ "$i" -le 2 ] && sleep 3
  done
  return 1
}

if en_casa; then AHORA=casa; else AHORA=fuera; fi

# --- Histeresis ------------------------------------------------------------
# roam.state:  sitio_declarado|sitio_visto|veces_seguidas
ANT=$(cat "$STATE" 2>/dev/null)
DECL=$(printf '%s' "$ANT" | cut -d'|' -f1)
VISTO=$(printf '%s' "$ANT" | cut -d'|' -f2)
VECES=$(printf '%s' "$ANT" | cut -d'|' -f3)
case "${VECES:-}" in ''|*[!0-9]*) VECES=0 ;; esac
# Primera ejecucion: se cree lo que se ve, sin esperar confirmacion. Si no, el
# nodo pasaria su primer cuarto de hora con el estado equivocado.
[ -n "${DECL:-}" ] || DECL="$AHORA"

if [ "$AHORA" = "$VISTO" ]; then VECES=$((VECES + 1)); else VECES=1; fi
printf '%s|%s|%s\n' "$DECL" "$AHORA" "$VECES" > "$STATE"

[ "$AHORA" = "$DECL" ] && exit 0            # nada que hacer
if [ "$VECES" -lt "$CONFIRMA" ]; then
  log "veo '$AHORA' pero declarado '$DECL' ($VECES de $CONFIRMA): espero a confirmar"
  exit 0
fi

# --- Conmutar --------------------------------------------------------------
# NUNCA por pkill: en estos telefonos `pkill -f` se lleva por delante la propia
# sesion SSH, y `sv status` miente sobre servicios que no supervisa runit. Se usa
# sv, que es quien manda sobre rqlited, y con SVDIR explicito porque en sesion
# SSH no viene puesto.
#
# OJO con `set -u`: PREFIX solo existe en Termux. Referenciarlo a pelo mataba el
# script en la pasada que tenia que conmutar —justo esa— y el nodo se quedaba
# para siempre con el estado viejo. Lo cazo el banco de pruebas; de ahi el
# rodeo de ${PREFIX:-}.
if [ -z "${SVDIR:-}" ]; then
  SVDIR="${PREFIX:-/data/data/com.termux/files/usr}/var/service"
fi
export SVDIR

hecho=1
if command -v sv >/dev/null 2>&1 && [ -d "$SVDIR/$SVC" ]; then
  if [ "$AHORA" = "casa" ]; then
    if sv up "$SVC" >/dev/null 2>&1; then
      log "de vuelta en la WiFi de casa: $SVC arriba, me reincorporo al cluster"
    else
      hecho=0; log "AVISO: 'sv up $SVC' fallo; lo reintento en la proxima pasada"
    fi
  else
    if sv down "$SVC" >/dev/null 2>&1; then
      log "fuera de casa: $SVC abajo para no replicar Raft sobre datos moviles"
    else
      hecho=0; log "AVISO: 'sv down $SVC' fallo; lo reintento en la proxima pasada"
    fi
  fi
else
  # No hay nada que supervisar aqui. Se anota el cambio igualmente: si no, el
  # aviso se repetiria cada cinco minutos para siempre.
  log "AVISO: no encuentro el servicio '$SVC' en $SVDIR; solo anoto el cambio a '$AHORA'"
fi

# Solo se declara el sitio nuevo si la conmutacion salio bien. Si fallo, el
# estado declarado no se toca y la proxima pasada vuelve a intentarlo.
if [ "$hecho" -eq 1 ]; then
  printf '%s|%s|%s\n' "$AHORA" "$AHORA" "$VECES" > "$STATE"
fi

# El log es un diario de viajes, no una auditoria: con las ultimas 200 lineas
# sobra para ver el patron de un mes.
if [ -f "$LOG" ]; then
  tail -n 200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
fi
exit 0
