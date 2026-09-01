#!/usr/bin/env sh
# Sentinel v2 - Alertas de nodo caido (Fase 5).
#
# QUIEN AVISA: solo el WHEEL. Corre por cron en todos los nodos, pero cada uno
# comprueba antes si le toca; los demas salen sin hacer nada. Asi el aviso lo
# hereda solo el nuevo coordinador cuando hay relevo, sin configurar nada. Si el
# propio Wheel cae, el siguiente ciclo de eleccion (<=5 min) nombra otro y ese
# empieza a avisar — incluido el aviso de que el anterior se cayo.
#
# QUE AVISA: transiciones, no estados. Solo se manda mensaje cuando un nodo pasa
# de responder a no responder (y al reves), y cuando cambia el Wheel. Sin esto,
# un nodo caido generaria un mensaje cada 5 minutos para siempre.
#
# TOLERANCIA (GRACE_NODES): un nodo puede tener un plazo antes de darlo por caido.
# Sirve para equipos que se reinician de vez en cuando de forma legitima (la
# laptop, una vez por semana): el reinicio no genera aviso, pero una caida de
# verdad si, en cuanto pasa el plazo.
#
# POR DONDE: el mismo bot de Telegram que ya usa thermal-guard, para no abrir un
# canal nuevo ni duplicar secretos (~/PRC_Thermal/thermal-guard.conf).
#
# DRY=1 imprime los mensajes en vez de enviarlos.

set -u
BASE="${SENTINEL_BASE:-$HOME/PRC_Sentinel/v2}"
CONF="$BASE/sentinel.conf"
STATE="$BASE/alert.state"
DRY="${DRY:-0}"

[ -r "$CONF" ] || exit 0
. "$CONF"
[ -r "$BASE/fleet.token" ] && TOKEN=$(cat "$BASE/fleet.token")
[ -n "${TOKEN:-}" ] || exit 0
PORT="${PORT:-8181}"

# --- ¿Me toca a mi? -------------------------------------------------------
WHEEL=""
[ -r "$BASE/wheel.state" ] && WHEEL=$(tr -d '[:space:]' < "$BASE/wheel.state")
if [ "$WHEEL" != "${NAME:-}" ]; then
  exit 0            # no soy el Wheel: no me corresponde avisar
fi

# --- Reparto en el tiempo -------------------------------------------------
# Sin esto los 11 nodos disparan en el MISMO segundo :00 y cada equipo recibe una
# veintena de peticiones a la vez sobre un aceptador monohilo. Medido el 17/08:
# 148 de los 153 fallos de "no responde" cayeron exactamente en el segundo :00, y
# hubo nodos que en ese instante no se alcanzaban ni a si mismos por 127.0.0.1.
# El desfase es FIJO por nodo y por tarea (sale del nombre), no aleatorio: cada
# equipo tiene siempre su hueco, el reparto no cambia en cada arranque y se puede
# predecir al depurar. Comprobado que con los nombres reales no hay colisiones.
# SENTINEL_NOJITTER=1 lo salta, para probar a mano sin esperar.
if [ "${SENTINEL_NOJITTER:-0}" != "1" ]; then
  _j=$(printf '%s-alert' "${NAME:-x}" | cksum 2>/dev/null | cut -d' ' -f1)
  case "${_j:-}" in ''|*[!0-9]*) _j=0 ;; esac
  [ "$_j" -gt 0 ] && sleep $(( _j % 120 ))
fi

# Recien coronado: callar un ciclo. wheel.state SOLO se reescribe cuando el
# ganador cambia, asi que un Wheel asentado tiene un mtime viejo. Si acabo de
# proclamarme, lo mas probable es que haya perdido de vista al coordinador un
# momento y la eleccion se corrija sola en la ronda siguiente; hablar ahora es
# justo lo que producia dos avisos del mismo suceso.
SETTLE="${WHEEL_SETTLE:-420}"
case "$SETTLE" in *[!0-9]*|"") SETTLE=0 ;; esac
if [ "$SETTLE" -gt 0 ]; then
  wm=$(stat -c %Y "$BASE/wheel.state" 2>/dev/null || echo "")
  ahora=$(date +%s 2>/dev/null || echo "")
  if [ -n "$wm" ] && [ -n "$ahora" ] && [ $((ahora - wm)) -lt "$SETTLE" ]; then
    exit 0
  fi
fi

# Segunda comprobacion, contra la RED y no contra mi fichero: si otro nodo
# tambien se cree Wheel, callarse y dejar avisar solo al de nombre menor. Con
# una eleccion sana esto nunca se activa, pero durante una ventana de
# desacuerdo evita que lleguen cuatro avisos del mismo suceso (paso el
# 2026-08-15). El desempate por nombre es estable: todos eligen al mismo.
campo(){ printf '%s' "$1" | sed -n "s/.*\"$2\"[ ]*:[ ]*\"\{0,1\}\([^,\"}]*\).*/\1/p" | head -1; }
entero(){ case "${1:-}" in ''|*[!0-9]*) printf 0 ;; *) printf '%s' "$1" ;; esac; }

if [ -n "${RQLITE:-}" ]; then
  MIO=$(curl -s -m 4 "http://127.0.0.1:${PORT:-8181}/fitness?token=$TOKEN" 2>/dev/null)
  MI_EST=$(entero "$(campo "$MIO" estable)"); MI_UP=$(entero "$(campo "$MIO" uptime)")
  OTROS=$(curl -s -m 5 "$RQLITE/nodes?timeout=2s" 2>/dev/null \
          | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | sort -u)
  for ip in $OTROS; do
    v=$(curl -s -m 4 "http://$ip:${PORT:-8181}/version?token=$TOKEN" 2>/dev/null)
    case "$v" in *'"wheel":1'*)
      of=$(curl -s -m 4 "http://$ip:${PORT:-8181}/fitness?token=$TOKEN" 2>/dev/null)
      otro=$(campo "$of" nombre)
      [ -n "$otro" ] && [ "$otro" != "$NAME" ] || continue
      # Ceder al que sea MEJOR coordinador, no al de nombre menor. El desempate
      # alfabetico de antes estaba al reves: hacia que un telefono (sentinel001)
      # desplazara al mini-PC que de verdad es el Wheel, asi que el aviso lo
      # acababa dando el nodo menos fiable. Mismo criterio que la eleccion:
      # primero estar siempre encendido, luego llevar mas tiempo en pie.
      o_est=$(entero "$(campo "$of" estable)"); o_up=$(entero "$(campo "$of" uptime)")
      if [ "$o_est" -gt "$MI_EST" ]; then exit 0; fi
      if [ "$o_est" -eq "$MI_EST" ]; then
        if [ "$o_up" -gt "$MI_UP" ]; then exit 0; fi
        if [ "$o_up" -eq "$MI_UP" ] && [ "$otro" \< "$NAME" ]; then exit 0; fi
      fi ;;
    esac
  done
fi

# --- Credenciales de Telegram (las de thermal-guard) ----------------------
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

# --- Bateria: enchufado pero perdiendo carga ------------------------------
# El fallo que mato a sentinel017 el 18/08: estaba enchufado, pero Android habia
# cortado la carga por temperatura (~42 C) y el telefono tiro de bateria hasta
# agotarla. El aviso termico de thermal-guard salta a 45 C, POR ENCIMA del corte,
# asi que hay una franja donde un equipo deja de cargar sin que nadie se entere.
#
# Se mira la TENDENCIA, no el instante: un telefono en el limite alterna CHARGING
# y NOT_CHARGING cada pocos minutos (sentinel003 lo hizo dos veces en media hora)
# y avisar de cada cambio seria ruido puro. Lo que no admite discusion es perder
# porcentaje estando enchufado a la corriente.
BSTATE="$BASE/bat.state"
BCAIDA="${BAT_CAIDA_PCT:-5}"    # puntos perdidos en 2 h que disparan el aviso
BMIN="${BAT_MIN_PCT:-30}"       # suelo absoluto, estando enchufado
if [ -n "${RQLITE:-}" ]; then
  BQ="SELECT b.node,b.pct,b.estado,b.enchufe,ROUND(b.temp_c,1),IFNULL((SELECT pct FROM sentinel_bateria WHERE node=b.node AND ts<=b.ts-7200 ORDER BY ts DESC LIMIT 1),-1) FROM sentinel_bateria b JOIN (SELECT node n,MAX(ts) m FROM sentinel_bateria GROUP BY node) x ON b.node=x.n AND b.ts=x.m"
  BR=$(curl -s -m 12 -G "$RQLITE/db/query" --data-urlencode "q=$BQ" 2>/dev/null \
       | sed 's/.*"values":\[//; s/\]}.*//' | sed 's/\],\[/\n/g' | tr -d '[]"')
  BANT=""; [ -r "$BSTATE" ] && BANT=$(cat "$BSTATE")
  BNUEVO=""; BMAL=""; BBIEN=""
  IFS='
'
  for l in $BR; do
    nb=$(printf '%s' "$l" | cut -d, -f1); pb=$(printf '%s' "$l" | cut -d, -f2)
    eb=$(printf '%s' "$l" | cut -d, -f3); ub=$(printf '%s' "$l" | cut -d, -f4)
    tb=$(printf '%s' "$l" | cut -d, -f5); ab=$(printf '%s' "$l" | cut -d, -f6)
    [ -n "$nb" ] || continue
    case "$ub" in PLUGGED*) ;; *) continue ;; esac   # desenchufado: es lo normal
    stb=ok; det=""
    if [ "${pb:-100}" -le "$BMIN" ] 2>/dev/null; then stb=mal; det="por debajo del $BMIN%"; fi
    if [ "${ab:--1}" -ge 0 ] 2>/dev/null && [ $((ab - pb)) -ge "$BCAIDA" ] 2>/dev/null; then
      stb=mal; det="ha perdido $((ab - pb)) puntos en 2 h (estaba al $ab%)"
    fi
    antb=$(printf '%s\n' "$BANT" | sed -n "s/^$nb|//p")
    [ -n "$antb" ] || antb=ok
    [ "$stb" = mal ] && [ "$antb" = ok ] && BMAL="$BMAL
  • $nb $pb% — $det, $eb a $tb °C"
    [ "$stb" = ok ] && [ "$antb" = mal ] && BBIEN="$BBIEN
  • $nb $pb%"
    BNUEVO="$BNUEVO$nb|$stb
"
  done
  unset IFS
  [ -n "$BMAL" ] && avisar "🔋 Sentinel: enchufado pero perdiendo bateria:$BMAL
Android corta la carga por encima de unos 42 °C. Avisa $NAME (Wheel)."
  [ -n "$BBIEN" ] && avisar "🔌 Sentinel: bateria recuperada:$BBIEN
Avisa $NAME (Wheel)."
  [ -n "$BNUEVO" ] && printf '%s' "$BNUEVO" > "$BSTATE"
fi

# --- Lista de nodos: la misma fuente que usa la eleccion -------------------
IPS=""
if [ -n "${RQLITE:-}" ]; then
  # grep -o y no sed: con 'sed s/.*\(IP\).*/\1/' el '.*' inicial es CODICIOSO y se
  # come el primer octeto ("192.168.1.124" salia como "2.168.1.124"), con lo que
  # ningun nodo respondia y se habria avisado de una caida total falsa.
  IPS=$(curl -s -m 5 "$RQLITE/nodes?timeout=2s" 2>/dev/null \
        | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' \
        | sort -u)
fi
if [ -z "$IPS" ] && [ -r "$BASE/peers.tsv" ]; then
  IPS=$(cut -f1 "$BASE/peers.tsv" | sort -u)
fi

# Nodos que NO estan en el cluster rqlite y aun asi hay que vigilar (la laptop,
# por ejemplo, que pertenece a la red Sentinel pero no guarda la base de datos).
# Va en sentinel.conf y debe estar en TODOS los nodos: cualquiera puede acabar
# siendo el Wheel y, por tanto, el que vigila.
if [ -n "${EXTRA_NODES:-}" ]; then
  IPS=$(printf '%s\n%s\n' "$IPS" "$(printf '%s' "$EXTRA_NODES" | tr ', ' '\n\n')" | grep -E '^[0-9]' | sort -u)
fi

# Nodos que pertenecen a la red pero NO se vigilan. Un movil personal entra y sale
# de la WiFi a diario: avisar de cada desconexion seria ruido constante y acabaria
# ensenando a ignorar las alertas, que es lo peor que le puede pasar a un aviso.
if [ -n "${SKIP_NODES:-}" ]; then
  for skip in $(printf '%s' "$SKIP_NODES" | tr ', ' '\n\n'); do
    [ -n "$skip" ] && IPS=$(printf '%s\n' "$IPS" | grep -vxF "$skip")
  done
fi

[ -n "$IPS" ] || exit 0

# Tolerancia por nodo, en segundos: GRACE_NODES=ip:segundos[,ip:segundos...]
# 0 (o ausente) = comportamiento de siempre, avisar en cuanto falla el sondeo.
gracia_de(){
  g=0
  for par in $(printf '%s' "${GRACE_NODES:-}" | tr ', ' '\n\n'); do
    case "$par" in "$1":*) g=${par#*:} ;; esac
  done
  case "$g" in *[!0-9]*|"") g=0 ;; esac
  printf '%s' "$g"
}

# --- Sondear: dos intentos, para no avisar por un fallo suelto ------------
# Se pregunta a /fitness (no a /version) porque devuelve el NOMBRE del nodo, y se
# guarda: un nodo caido no puede decir como se llama, asi que el aviso usa el
# ultimo nombre conocido. Sin esto los mensajes solo podrian decir la IP.
#
# Formato de alert.state:  ip|nombre|estado_declarado|epoch_primer_fallo
# El 4o campo es nuevo; un fichero antiguo de 3 campos se lee igual (queda vacio
# y el reloj de la tolerancia empieza en el siguiente ciclo).
ANTES=""
[ -r "$STATE" ] && ANTES=$(cat "$STATE")
AHORA=$(date +%s 2>/dev/null || echo 0)

# Foto caducada: no sirve para comparar. Un nodo que no ha sido Wheel en dos dias
# guarda el retrato de una red que ya no existe; al tomar el relevo dispararia
# recuperaciones y caidas falsas de todo lo que haya cambiado desde entonces. El
# Wheel en activo reescribe esto cada 5 min, asi que esto solo salta en un relevo.
SMAX="${STATE_MAX:-1800}"
case "$SMAX" in *[!0-9]*|"") SMAX=0 ;; esac
if [ -n "$ANTES" ] && [ "$SMAX" -gt 0 ] && [ "$AHORA" -gt 0 ]; then
  sm=$(stat -c %Y "$STATE" 2>/dev/null || echo "")
  if [ -n "$sm" ] && [ $((AHORA - sm)) -gt "$SMAX" ]; then
    # Se tiran los ESTADOS (caducados) pero se conservan los NOMBRES aprendidos:
    # son lo unico del fichero que no caduca, y sin ellos un nodo que este caido
    # justo en el relevo saldria como IP pelada en el aviso.
    ANTES=$(printf '%s\n' "$ANTES" | awk -F'|' 'NF>=3 && $1!="" {printf "%s|%s|ok|\n",$1,$2}')
  fi
fi

NUEVO=""; CAIDOS=""; VUELTOS=""
for ip in $IPS; do
  st="caido"; nom=""
  for i in 1 2; do
    resp=$(curl -s -m 6 "http://$ip:$PORT/fitness?token=$TOKEN" 2>/dev/null)
    if [ -n "$resp" ]; then
      st="ok"
      nom=$(printf '%s' "$resp" | sed -n 's/.*"nombre"[ ]*:[ ]*"\([^"]*\)".*/\1/p')
      break
    fi
    sleep 3
  done

  ant_l=$(printf '%s\n' "$ANTES" | awk -F'|' -v ip="$ip" '$1==ip{print;exit}')
  ant_st=$(printf '%s' "$ant_l" | cut -d'|' -f3)
  desde=$(printf '%s' "$ant_l" | cut -d'|' -f4)
  [ -n "$ant_st" ] || ant_st="ok"     # nodo nuevo: se asume sano, no se avisa de golpe

  # Si esta caido, recuperar el nombre que se aprendio la ultima vez.
  [ -n "$nom" ] || nom=$(printf '%s' "$ant_l" | cut -d'|' -f2)
  [ -n "$nom" ] || nom="$ip"          # nunca visto: al menos la IP

  # Estado DECLARADO (el que dispara avisos), que no siempre es el sondeado: con
  # tolerancia, un nodo que acaba de dejar de responder sigue contando como sano
  # hasta que se cumple el plazo. Si vuelve antes, no se avisa de nada.
  gracia=$(gracia_de "$ip")
  [ "$AHORA" -gt 0 ] || gracia=0      # sin reloj fiable, mejor avisar de mas
  espera=0
  if [ "$st" = "caido" ]; then
    [ -n "$desde" ] || desde="$AHORA"
    espera=$((AHORA - desde))
    if [ "$gracia" -gt 0 ] && [ "$espera" -lt "$gracia" ]; then
      st="$ant_st"                    # dentro del plazo: aun no se declara caido
    else
      st="caido"
    fi
  else
    desde=""
  fi

  if [ "$st" = "caido" ] && [ "$ant_st" = "ok" ]; then
    detalle=""
    [ "$gracia" -gt 0 ] && detalle=" — sin responder desde hace $((espera / 60)) min"
    CAIDOS="$CAIDOS
  • $nom ($ip)$detalle"
  fi
  if [ "$st" = "ok" ] && [ "$ant_st" = "caido" ]; then VUELTOS="$VUELTOS
  • $nom ($ip)"; fi

  NUEVO="$NUEVO$ip|$nom|$st|$desde
"
done

[ -n "$CAIDOS" ]  && avisar "🔴 Sentinel: nodo sin responder:$CAIDOS
Dos sondeos fallidos al puerto $PORT. Avisa $NAME (Wheel)."
[ -n "$VUELTOS" ] && avisar "🟢 Sentinel: nodo recuperado:$VUELTOS
Avisa $NAME (Wheel)."

# --- Cambio de Wheel ------------------------------------------------------
WANT=$(printf '%s\n' "$ANTES" | sed -n 's/^__wheel__=//p')
if [ -n "$WANT" ] && [ "$WANT" != "$NAME" ]; then
  avisar "🔵 Sentinel: el coordinador (Wheel) pasa de $WANT a $NAME."
fi

printf '%s__wheel__=%s\n' "$NUEVO" "$NAME" > "$STATE"
exit 0
