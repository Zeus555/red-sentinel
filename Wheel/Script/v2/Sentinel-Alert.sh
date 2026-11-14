#!/usr/bin/env sh
# Sentinel v2 - Avisos de la red (Fase 5; ampliado el 2026-11-09).
#
# QUIEN AVISA: solo el WHEEL. Corre por cron en todos los nodos, pero cada uno
# comprueba antes si le toca; los demas salen sin hacer nada. Asi el aviso lo
# hereda solo el nuevo coordinador cuando hay relevo, sin configurar nada. Si el
# propio Wheel cae, el siguiente ciclo de eleccion (<=5 min) nombra otro y ese
# empieza a avisar — incluido el aviso de que el anterior se cayo.
#
# QUE VIGILA (cada cosa con su clave en alert.state):
#   - nodos: responden al puerto del agente (lo de siempre);
#   - rqlite: que el cluster tenga lider visto desde aqui y que alcance al rqlited
#     de cada nodo cuyo agente si responde (un agente vivo con su rqlited muerto
#     pasaba por sano);
#   - datos: que la telemetria de cada nodo siga llegando. En Termux la
#     temperatura y la bateria las escribe el CRON: si cron muere, el agente sigue
#     respondiendo y tambien parecia sano (sentinel017, 16 h sin datos el 09/11);
#   - base (df:flota): que la base reciba datos de ALGUIEN. Si ningun nodo escribe
#     no se culpa a cada uno (eso seria media flota "sin datos"), pero se avisa una
#     vez de la base: contrasena rechazada en toda la flota, cron parado en todos o
#     mi replica atrasada. Antes ese caso no lo decia nadie;
#   - credenciales (au:<nodo>): que rqlite acepte la contrasena de ESTE nodo. Un
#     401 tiene su propio aviso: no es "sin lider" (503) ni "rqlited caido" (000);
#   - EXTRA_CHECKS: equipos sin agente Sentinel, como sentinel020;
#   - bateria: enchufado pero perdiendo carga (lo de siempre);
#   - BTC (bv:<producto>, bs:senales): que el monitoreo de BTC (btc/,
#     temporizador en sentinel014) siga escribiendo velas nuevas en rqlite, y
#     que sus señales salgan.
#
# QUE AVISA: transiciones, no estados. Mensaje al pasar a mal y al volver, mas un
# RECORDATORIO cada RECORDATORIO_H horas mientras siga mal: antes una caida de
# diez dias (017) se anunciaba una sola vez y luego silencio.
#
# SI TELEGRAM FALLA: la transicion NO se da por hecha. El estado se queda como
# estaba y la siguiente pasada vuelve a intentarlo. Antes se guardaba igual y ese
# aviso se perdia para siempre. Cada envio queda en alert.log.
#
# LATIDO: al terminar, el Wheel escribe la hora de la pasada en rqlite
# (sentinel_vigia). Sentinel-Latido.sh la lleva a la EC2, que avisa si deja de
# avanzar: un Wheel con el cron parado no puede avisar de que no avisa.
#
# TOLERANCIA (GRACE_NODES): un nodo puede tener un plazo antes de darlo por caido.
# Sirve para equipos que se reinician de vez en cuando de forma legitima (la
# laptop, una vez por semana): el reinicio no genera aviso, pero una caida de
# verdad si, en cuanto pasa el plazo.
#
# POR DONDE: el mismo bot de Telegram que ya usa thermal-guard, para no abrir un
# canal nuevo ni duplicar secretos (~/PRC_Thermal/thermal-guard.conf).
#
# DRY=1 imprime los mensajes en vez de enviarlos (y no escribe el latido).
# SENTINEL_NOW=<epoch> fija el reloj, para el banco de pruebas.

set -u
BASE="${SENTINEL_BASE:-$HOME/PRC_Sentinel/v2}"
CONF="$BASE/sentinel.conf"
STATE="$BASE/alert.state"
LOGF="$BASE/alert.log"
DRY="${DRY:-0}"

[ -r "$CONF" ] || exit 0
. "$CONF"
# Credenciales de rqlite: fichero 600 con una linea  user = "usuario:clave".
# Van por -K, asi no salen en ps. Sin fichero se pregunta sin credenciales, como
# siempre: un rqlited sin -auth las ignora de todos modos.
RQLITE_CRED="${RQLITE_CRED:-$HOME/.config/rqlite/sentinel.curlrc}"
rqcurl(){ if [ -r "$RQLITE_CRED" ]; then curl -K "$RQLITE_CRED" "$@"; else curl "$@"; fi; }
# Peticion a rqlite sabiendo el codigo HTTP: deja el cuerpo (el mismo que antes,
# sin la linea del codigo) en RQ_CUERPO y el codigo en RQ_HC (000 = no contesto).
# Se llama SIN $(...): tiene que dejar variables en esta shell. A lo largo de la
# pasada lleva RQ_401 (endpoints que rechazaron las credenciales, sin repetir) y
# RQ_OK=1 si alguna peticion con credenciales salio bien. /readyz no cuenta para
# RQ_OK: queda abierto a todos (usuario "*"), asi que su 200 no prueba la clave.
RQ_401=""; RQ_OK=0; RQ_HC=000; RQ_CUERPO=""
rqpide(){ # $1=endpoint (para el aviso) y despues los argumentos de curl
  _rqe="$1"; shift
  _rqr=$(rqcurl "$@" -w '\n%{http_code}' 2>/dev/null)
  RQ_HC=$(printf '%s' "$_rqr" | tail -n 1)
  RQ_CUERPO=$(printf '%s\n' "$_rqr" | sed '$d')
  case "$RQ_HC" in [0-9][0-9][0-9]) ;; *) RQ_HC=000 ;; esac
  case "$RQ_HC" in
    2??) [ "$_rqe" = /readyz ] || RQ_OK=1 ;;
    401) case ", $RQ_401, " in *", $_rqe, "*) ;; *) RQ_401="${RQ_401:+$RQ_401, }$_rqe" ;; esac ;;
  esac
}
[ -r "$BASE/fleet.token" ] && TOKEN=$(cat "$BASE/fleet.token")
[ -n "${TOKEN:-}" ] || exit 0
PORT="${PORT:-8181}"
AWK=$(command -v gawk 2>/dev/null || command -v awk)
TAB=$(printf '\t')

ahora(){
  if [ -n "${SENTINEL_NOW:-}" ]; then printf '%s' "$SENTINEL_NOW"; return; fi
  date +%s 2>/dev/null || printf 0
}
entero(){ case "${1:-}" in ''|*[!0-9]*) printf '%s' "${2:-0}" ;; *) printf '%s' "$1" ;; esac; }
# Salida sin hacer nada. En DRY dice por que: una prueba a mano que no imprime
# nada no distingue "todo bien" de "no me tocaba".
callar(){ [ "$DRY" = "1" ] && echo "[DRY] no paso: $1"; exit 0; }

# --- ¿Me toca a mi? -------------------------------------------------------
WHEEL=""
[ -r "$BASE/wheel.state" ] && WHEEL=$(tr -d '[:space:]' < "$BASE/wheel.state")
if [ "$WHEEL" != "${NAME:-}" ]; then
  callar "no soy el Wheel (wheel.state dice ${WHEEL:-nada})"
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
AHORA=$(entero "$(ahora)" 0)

# Recien coronado: callar un ciclo. wheel.state SOLO se reescribe cuando el
# ganador cambia, asi que un Wheel asentado tiene un mtime viejo. Si acabo de
# proclamarme, lo mas probable es que haya perdido de vista al coordinador un
# momento y la eleccion se corrija sola en la ronda siguiente; hablar ahora es
# justo lo que producia dos avisos del mismo suceso.
SETTLE=$(entero "${WHEEL_SETTLE:-420}" 0)
if [ "$SETTLE" -gt 0 ]; then
  wm=$(stat -c %Y "$BASE/wheel.state" 2>/dev/null || echo "")
  if [ -n "$wm" ] && [ "$AHORA" -gt 0 ] && [ $((AHORA - wm)) -lt "$SETTLE" ]; then
    callar "recien coronado (wheel.state de hace $((AHORA - wm)) s; WHEEL_SETTLE=0 para probar)"
  fi
fi

# Cerrojo: con muchos nodos caidos una pasada puede superar los 5 min del cron y
# dos pasadas a la vez se pisarian alert.state. mkdir es atomico.
LOCK="$BASE/.alert.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  lt=$(stat -c %Y "$LOCK" 2>/dev/null || echo 0)
  if [ "$lt" -gt 0 ] && [ "$AHORA" -gt 0 ] && [ $((AHORA - lt)) -gt 600 ]; then
    rmdir "$LOCK" 2>/dev/null
    mkdir "$LOCK" 2>/dev/null || callar "cerrojo ocupado"
  else
    callar "hay otra pasada en curso (cerrojo $LOCK)"
  fi
fi
OBS="$BASE/.alert.obs.$$"; OUT="$BASE/.alert.out.$$"; VACIO="$BASE/.alert.vacio.$$"
# La limpieza va en EXIT y las senales solo SALEN (y con eso disparan EXIT). En sh
# un trap de senal ejecuta su codigo y el script SIGUE: con la limpieza ahi, un
# Ctrl-C o un `systemctl stop` a mitad de pasada borraba los temporales y la pasada
# seguia hasta dejar alert.state solo con __wheel__.
limpiar(){ rm -f "$OBS" "$OUT" "$VACIO" "$VACIO.b" "$STATE.tmp.$$"; rmdir "$LOCK" 2>/dev/null; }
trap limpiar EXIT
trap 'exit 1' INT TERM HUP
: > "$OBS"; : > "$VACIO"

# La lista del cluster se pide UNA vez y se reutiliza: sirve para ver si hay otro
# Wheel, para saber a quien vigilar y para ver que rqlited alcanza el cluster.
# 'nonvoters' es obligatorio: sin el, /nodes solo lista los nodos con voto (3 desde
# el 2026-10-30) y el resto de la flota dejaria de vigilarse sin ningun aviso.
# Con 401 (credenciales rechazadas) la lista queda vacia y se tira de peers.tsv,
# como cuando rqlite no contesta.
NODOS_JSON=""
if [ -n "${RQLITE:-}" ]; then
  rqpide /nodes -s -m 5 "$RQLITE/nodes?nonvoters&timeout=2s"
  [ "$RQ_HC" = 401 ] || NODOS_JSON="$RQ_CUERPO"
fi

# Segunda comprobacion, contra la RED y no contra mi fichero: si otro nodo
# tambien se cree Wheel, callarse y dejar avisar solo a uno. Con una eleccion
# sana esto nunca se activa, pero durante una ventana de desacuerdo evita que
# lleguen cuatro avisos del mismo suceso (paso el 2026-08-15).
campo(){ printf '%s' "$1" | sed -n "s/.*\"$2\"[ ]*:[ ]*\"\{0,1\}\([^,\"}]*\).*/\1/p" | head -1; }

if [ -n "${RQLITE:-}" ]; then
  MIO=$(curl -s -m 4 "http://127.0.0.1:${PORT:-8181}/fitness?token=$TOKEN" 2>/dev/null)
  MI_EST=$(entero "$(campo "$MIO" estable)"); MI_UP=$(entero "$(campo "$MIO" uptime)")
  OTROS=$(printf '%s' "$NODOS_JSON" | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | sort -u)
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
      if [ "$o_est" -gt "$MI_EST" ]; then callar "$otro tambien se cree Wheel y es estable"; fi
      if [ "$o_est" -eq "$MI_EST" ]; then
        if [ "$o_up" -gt "$MI_UP" ]; then callar "$otro tambien se cree Wheel y lleva mas en pie"; fi
        if [ "$o_up" -eq "$MI_UP" ] && [ "$otro" \< "$NAME" ]; then callar "$otro tambien se cree Wheel (empate)"; fi
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

# Registro de envios: una linea por intento, con el resultado. Es lo que permite
# saber despues si un aviso salio o se quedo pendiente.
registrar(){ # $1=categoria $2=resultado $3=texto
  printf '%s %s %s | %s\n' "$(date '+%m-%d %H:%M:%S' 2>/dev/null)" "$1" "$2" \
    "$(printf '%s' "$3" | head -n 1)" >> "$LOGF" 2>/dev/null
}

# Devuelve 0 SOLO si Telegram confirma el envio ("ok":true con HTTP 200). curl
# sale con 0 aunque la API responda 400 o 500, asi que su codigo de salida no
# sirve para saber si el mensaje llego.
enviar(){ # $1=categoria $2=texto
  if [ "$DRY" = "1" ]; then printf '[DRY] %s\n' "$2"; registrar "$1" dry "$2"; return 0; fi
  if [ -z "$BOT_TOKEN" ] || [ -z "$CHAT_ID" ]; then registrar "$1" "FALLO sin-credenciales" "$2"; return 1; fi
  # La URL (que lleva el token del bot) va por la entrada con -K, no en argv: asi
  # no aparece en `ps` mientras dura el envio.
  _r=$(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$BOT_TOKEN" \
       | curl -s -m 20 -K - -w '\n%{http_code}' \
        --data-urlencode "chat_id=$CHAT_ID" \
        --data-urlencode "text=$2" 2>/dev/null)
  _c=$(printf '%s' "$_r" | tail -n 1)
  case "$_c" in
    200) case "$_r" in *'"ok":true'*) registrar "$1" ok "$2"; return 0 ;; esac ;;
  esac
  registrar "$1" "FALLO http=${_c:-000}" "$2"
  return 1
}

obs(){ # $1=clave $2=nombre $3=ok|mal $4=detalle $5=gracia(s)
  # '|' separa campos en alert.state: no puede colarse en un nombre ni un detalle.
  printf 'O|%s|%s|%s|%s|%s\n' "$1" "$(printf '%s' "$2" | tr '|\t\n' '/  ')" "$3" \
    "$(printf '%s' "$4" | tr '|\t\n' '/  ')" "$(entero "${5:-0}")" >> "$OBS"
}

# Tolerancia por IP, en segundos: GRACE_NODES=ip:segundos[,ip:segundos...]
# 0 (o ausente) = comportamiento de siempre, avisar en cuanto falla el sondeo.
gracia_de(){
  g=0
  for par in $(printf '%s' "${GRACE_NODES:-}" | tr ', ' '\n\n'); do
    case "$par" in "$1":*) g=${par#*:} ;; esac
  done
  case "$g" in *[!0-9]*|"") g=0 ;; esac
  printf '%s' "$g"
}

RQ_GRACIA=$(entero "${RQ_GRACIA:-240}" 240)
TMAX=$(( $(entero "${DATOS_TEMP_MAX_MIN:-20}" 20) * 60 ))
BTMAX=$(( $(entero "${DATOS_BAT_MAX_MIN:-20}" 20) * 60 ))
RECORD=$(( $(entero "${RECORDATORIO_H:-24}" 24) * 3600 ))

# --- 1. rqlite: ¿tiene lider visto desde aqui? ----------------------------
# /readyz de mi propio rqlited: 200 = tiene lider; 503 = sin lider (tormenta de
# elecciones, sin quorum); sin respuesta = el rqlited de este nodo no contesta;
# 401 = rechaza mis credenciales: no se sabe si hay lider, asi que __cl__ no se
# observa (conserva su estado) y el 401 lo cuenta au: (punto 7). Como con el 503,
# RZ no es 200 y esta pasada no se miran rq: ni dt:.
RZ=""
if [ -n "${RQLITE:-}" ]; then
  rqpide /readyz -s -m 5 "$RQLITE/readyz"
  RZ="$RQ_HC"
  case "$RZ" in
    200) obs "__cl__" "rqlite" ok "" "$RQ_GRACIA" ;;
    401) ;;
    000|"") obs "__cl__" "rqlite" mal "el rqlited de $NAME no responde" "$RQ_GRACIA" ;;
    *) obs "__cl__" "rqlite" mal "el clúster no tiene líder visto desde $NAME (readyz $RZ)" "$RQ_GRACIA" ;;
  esac
fi

# --- 3. Nodos: la misma fuente que usa la eleccion -------------------------
# grep -o y no sed: con 'sed s/.*\(IP\).*/\1/' el '.*' inicial es CODICIOSO y se
# come el primer octeto ("192.168.1.124" salia como "2.168.1.124"), con lo que
# ningun nodo respondia y se habria avisado de una caida total falsa.
IPS=$(printf '%s' "$NODOS_JSON" | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | sort -u)
if [ -z "$IPS" ] && [ -r "$BASE/peers.tsv" ]; then
  IPS=$(cut -f1 "$BASE/peers.tsv" | grep -E '^[0-9]' | sort -u)
fi
# Sin lista de la flota (ni rqlite ni peers.tsv) no se sabe quien sobra: los nodos
# que no se sondeen esta pasada conservan su estado en vez de olvidarse.
NODOS_OK=0; [ -n "$IPS" ] && NODOS_OK=1

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

ANTES=""
[ -r "$STATE" ] && ANTES=$(cat "$STATE")

# Foto caducada: no sirve para comparar. Un nodo que no ha sido Wheel en dos dias
# guarda el retrato de una red que ya no existe; al tomar el relevo dispararia
# recuperaciones y caidas falsas. El motor tira los ESTADOS y conserva los nombres.
# Se mira aqui, antes de sondear, porque tambien decide quien "acaba de volver".
STALE=0
SMAX=$(entero "${STATE_MAX:-1800}" 0)
if [ -n "$ANTES" ] && [ "$SMAX" -gt 0 ] && [ "$AHORA" -gt 0 ]; then
  sm=$(stat -c %Y "$STATE" 2>/dev/null || echo "")
  [ -n "$sm" ] && [ $((AHORA - sm)) -gt "$SMAX" ] && STALE=1
fi

# Se pregunta a /fitness (no a /version) porque devuelve el NOMBRE del nodo, y se
# guarda: un nodo caido no puede decir como se llama, asi que el aviso usa el
# ultimo nombre conocido. Sin esto los mensajes solo podrian decir la IP.
# Dos intentos, para no avisar por un fallo suelto. Cuenta como vivo SOLO un
# /fitness de verdad (lleva "nombre"), con el mismo criterio que la eleccion: un
# agente que contesta 401 (se quedo con el token viejo tras una rotacion) esta
# mudo para la flota y antes pasaba por sano.
VIVOS=""   # "ip|nombre" de los que contestan: el resto de pruebas solo mira a estos
VIVOS_DT="" # los mismos, menos los que acaban de volver (ver punto 5)
for ip in $IPS; do
  st="mal"; nom=""; det=""
  for i in 1 2; do
    resp=$(curl -s -m 6 -w '\n%{http_code}' "http://$ip:$PORT/fitness?token=$TOKEN" 2>/dev/null)
    hc=$(printf '%s' "$resp" | tail -n 1)
    case "$resp" in
      *'"nombre"'*)
        st="ok"; det=""
        nom=$(printf '%s' "$resp" | sed -n 's/.*"nombre"[ ]*:[ ]*"\([^"]*\)".*/\1/p' | head -n 1)
        break ;;
    esac
    [ "$hc" = 401 ] && det="rechaza el token de la flota (401)"
    [ "$i" = 1 ] && sleep 3
  done
  # Un nombre raro (espacios, |, comillas) romperia las listas y el estado: se
  # usa la IP. Los de la flota son sentinelNNN.
  case "$nom" in *[!A-Za-z0-9_.-]*) nom="" ;; esac
  [ "${#nom}" -le 40 ] || nom=""
  [ -n "$nom" ] || nom=$(printf '%s\n' "$ANTES" | awk -F'|' -v ip="$ip" '$1==ip{print $2;exit}')
  case "$nom" in ''|*[!A-Za-z0-9_.-]*) nom="$ip" ;; esac   # nunca visto: al menos la IP
  obs "$ip" "$nom" "$st" "$det" "$(gracia_de "$ip")"
  if [ "$st" = ok ]; then
    VIVOS="$VIVOS $ip|$nom"
    # Recien vuelto de una caida: sus datos son de antes de caer y thermal-guard y
    # Sentinel-Bateria aun no han escrito. Mirarlos ahora daba un "datos no llegan"
    # falso junto al "nodo recuperado". Se le miran a partir de la pasada siguiente.
    # (Con la foto caducada ese "caido" no vale: no se aplica.)
    ant=""; [ "$STALE" = 1 ] || ant=$(printf '%s\n' "$ANTES" | awk -F'|' -v ip="$ip" '$1==ip{print $3;exit}')
    [ "$ant" = caido ] || VIVOS_DT="$VIVOS_DT $ip|$nom"
  fi
done

# --- 3b. Bateria: enchufado pero perdiendo carga --------------------------
# El fallo que mato a sentinel017 el 18/08: estaba enchufado, pero Android habia
# cortado la carga por temperatura (~42 C) y el telefono tiro de bateria hasta
# agotarla. El aviso termico de thermal-guard salta a 45 C, POR ENCIMA del corte,
# asi que hay una franja donde un equipo deja de cargar sin que nadie se entere.
#
# Se mira la TENDENCIA, no el instante: un telefono en el limite alterna CHARGING
# y NOT_CHARGING cada pocos minutos (sentinel003 lo hizo dos veces en media hora)
# y avisar de cada cambio seria ruido puro. Lo que no admite discusion es perder
# porcentaje estando enchufado a la corriente.
BCAIDA="${BAT_CAIDA_PCT:-5}"    # puntos perdidos en 2 h que disparan el aviso
BMIN="${BAT_MIN_PCT:-30}"       # suelo absoluto, estando enchufado
if [ -n "${RQLITE:-}" ] && [ -n "$VIVOS" ]; then
  BQ="SELECT b.node,b.pct,b.estado,b.enchufe,ROUND(b.temp_c,1),IFNULL((SELECT pct FROM sentinel_bateria WHERE node=b.node AND ts<=b.ts-7200 ORDER BY ts DESC LIMIT 1),-1),b.salud FROM sentinel_bateria b JOIN (SELECT node n,MAX(ts) m FROM sentinel_bateria WHERE ts > $((AHORA - 7200)) GROUP BY node) x ON b.node=x.n AND b.ts=x.m"
  # Solo filas de las ultimas 2 h: un nodo retirado (o que dejo de mandar) no debe
  # quedarse con su ultima lectura vieja recordandose cada dia. Que deje de mandar
  # ya lo avisa la vigilancia de datos (dt:).
  rqpide /db/query -s -m 12 -G "$RQLITE/db/query" --data-urlencode "q=$BQ" --data-urlencode "level=none"
  BRAW="$RQ_CUERPO"
  case "$BRAW" in *'"values"'*)
    BR=$(printf '%s' "$BRAW" | sed 's/.*"values":\[//; s/\]}.*//' | sed 's/\],\[/\n/g' | tr -d '[]"')
    IFS='
'
    for l in $BR; do
      nb=$(printf '%s' "$l" | cut -d, -f1); pb=$(printf '%s' "$l" | cut -d, -f2)
      eb=$(printf '%s' "$l" | cut -d, -f3); ub=$(printf '%s' "$l" | cut -d, -f4)
      tb=$(printf '%s' "$l" | cut -d, -f5); ab=$(printf '%s' "$l" | cut -d, -f6)
      sb=$(printf '%s' "$l" | cut -d, -f7)
      [ -n "$nb" ] || continue
      # Solo nodos vigilados que contestan: el movil personal (SKIP_NODES) tambien
      # manda bateria, y avisaria cada vez que se carga por debajo del 30 %.
      case "$VIVOS " in *"|$nb "*) ;; *) continue ;; esac
      # Solo nodos vigilados que contestan: el movil personal (SKIP_NODES) tambien
      # manda bateria, y avisaria cada vez que se carga por debajo del 30 %.
      case "$VIVOS " in *"|$nb "*) ;; *) continue ;; esac
      case "$ub" in PLUGGED*) ;; *) continue ;; esac   # desenchufado: es lo normal
      # Bateria que no se puede medir: sentinel018 da siempre 0 %, NOT_CHARGING y
      # salud UNKNOWN con corriente positiva. Con el recordatorio diario seria un
      # aviso para siempre por un sensor que no mide; no se evalua.
      [ "$pb" = 0 ] && [ "$sb" = UNKNOWN ] && continue
      stb=ok; det=""
      if [ "${pb:-100}" -le "$BMIN" ] 2>/dev/null; then stb=mal; det="por debajo del $BMIN%"; fi
      if [ "${ab:--1}" -ge 0 ] 2>/dev/null && [ $((ab - pb)) -ge "$BCAIDA" ] 2>/dev/null; then
        stb=mal; det="ha perdido $((ab - pb)) puntos en 2 h (estaba al $ab%)"
      fi
      if [ "$stb" = mal ]; then obs "bt:$nb" "$nb" mal "$pb% — $det, $eb a $tb °C" 0
      else obs "bt:$nb" "$nb" ok "$pb%" 0; fi
    done
    unset IFS ;;
  esac
fi

# --- 4. rqlited de cada nodo ----------------------------------------------
# /nodes dice, para cada nodo, si el cluster alcanza su rqlited ("reachable"). Solo
# se mira en los nodos cuyo agente SI responde (si no, ya hay aviso de caida) y
# solo si mi propio rqlite tiene lider: un rqlite aislado ve a todos "inalcanzables"
# y avisaria de una caida de toda la flota que no existe.
if [ "$RZ" = 200 ] && [ -n "$NODOS_JSON" ]; then
  # La IP sale de "addr" (la direccion Raft, que viene de la configuracion del
  # cluster) y NO de "api_addr": rqlite solo rellena api_addr si el nodo contesta,
  # asi que justo el nodo inalcanzable venia sin el y nunca se avisaba. Los regex
  # admiten espacios tras los dos puntos, y '{' parte tanto el mapa por id de
  # rqlite v10 ({"id":{...},...}) como la lista {"nodes":[...]} de otras versiones.
  RQMAP=$(printf '%s' "$NODOS_JSON" | tr '{' '\n' | "$AWK" '
    /"addr"[ ]*:/ { ip=""; r=""; v=""
      if (match($0, /"addr"[ ]*:[ ]*"[0-9.]+:/)) { s=substr($0,RSTART,RLENGTH); sub(/^"addr"[ ]*:[ ]*"/,"",s); sub(/:$/,"",s); ip=s }
      if ($0 ~ /"reachable"[ ]*:[ ]*true/) r="ok"; else if ($0 ~ /"reachable"[ ]*:[ ]*false/) r="mal"
      if ($0 ~ /"voter"[ ]*:[ ]*true/) v="votante"; else v="sin voto"
      if (ip!="" && r!="") print ip "|" r "|" v }')
  for par in $VIVOS; do
    ip=${par%%|*}; nom=${par#*|}
    l=$(printf '%s\n' "$RQMAP" | awk -F'|' -v ip="$ip" '$1==ip{print;exit}')
    [ -n "$l" ] || continue            # no esta en el cluster (la laptop): nada que mirar
    r=$(printf '%s' "$l" | cut -d'|' -f2); v=$(printf '%s' "$l" | cut -d'|' -f3)
    obs "rq:$ip" "$nom" "$r" "$v" "$RQ_GRACIA"
  done
fi

# --- 5. ¿Siguen llegando sus datos? ---------------------------------------
# Temperatura (thermal-guard) y bateria (Sentinel-Bateria.sh) de cada nodo que
# responde. Una tabla que un nodo nunca escribio no cuenta (los Ubuntu no tienen
# bateria; la laptop no manda nada). Una sola consulta, con el indice (node, ts).
# Solo con rqlite sano (mi readyz = 200) y solo si la base de verdad recibe datos:
# el dato MAS reciente de toda la flota tiene que ser de los ultimos 5 min
# (temperatura, cada minuto) o 15 min (bateria, cada 5). Si no, el problema es la
# base o mi replica, no los nodos; antes, con la base congelada, salia un "datos
# no llegan" de media flota. Gracia de 2 pasadas.
# Ese caso tiene su propia clave, df:flota: con lider (readyz 200) y la consulta
# respondida, que NADIE escriba es un problema de toda la base (contrasena
# rechazada en toda la flota, cron parado en todos, mi replica atrasada) y antes
# no lo avisaba nadie. Se dice una vez, con la edad del ultimo dato. Si ninguno de
# los consultados escribio nunca (ni tiene clave dt:) no se opina: puede ser solo
# la laptop, que no manda nada.
DGRACIA=$(entero "${DATOS_GRACIA:-600}" 600)
if [ -n "${RQLITE:-}" ] && [ "$RZ" = 200 ] && [ -n "$VIVOS_DT" ]; then
  SUB=""
  for par in $VIVOS_DT; do
    nom=${par#*|}
    case "$nom" in *[!a-zA-Z0-9_-]*|"") continue ;; esac
    SUB="${SUB:+$SUB UNION ALL }SELECT '$nom' AS n"
  done
  if [ -n "$SUB" ]; then
    # La referencia de la flota es el dato mas reciente de cada tabla entre todos
    # los nodos consultados (sale del indice, sin recorrer la tabla).
    DQ="SELECT n,(SELECT MAX(ts) FROM sentinel_temp WHERE node=n),(SELECT MAX(ts) FROM sentinel_bateria WHERE node=n) FROM ($SUB)"
    rqpide /db/query -s -m 12 -G "$RQLITE/db/query" --data-urlencode "q=$DQ" --data-urlencode "level=none"
    DRAW="$RQ_CUERPO"
    case "$DRAW" in *'"values"'*)
      printf '%s' "$DRAW" | sed 's/.*"values":\[//; s/\]}.*//' | sed 's/\],\[/\n/g' | tr -d '[]" ' \
      | "$AWK" -F, -v now="$AHORA" -v tmax="$TMAX" -v btmax="$BTMAX" -v antes="$STATE" -v g="$DGRACIA" '
        function dur(s){ if (s<3600) return int(s/60) " min"; if (s<86400) return int(s/3600) " h " int((s%3600)/60) " min"; return int(s/86400) " d " int((s%86400)/3600) " h" }
        function num(x){ return (x=="null"||x=="") ? "" : x+0 }
        function hace(x){ return (x=="") ? "nunca" : "hace " dur(now-x) }
        BEGIN { while ((getline l < antes) > 0) if (l ~ /^dt:/) { split(l, a, "|"); Prev[substr(a[1],4)] = 1 } }
        { n=$1; N[++k]=n; T[n]=num($2); B[n]=num($3); if (n in Prev) hayPrev=1
          if (T[n]!="" && (mt=="" || T[n]>mt)) mt=T[n]
          if (B[n]!="" && (mb=="" || B[n]>mb)) mb=B[n] }
        END {
          okT = (mt!="" && now-mt <= 300)     # la base recibe temperatura
          okB = (mb!="" && now-mb <= 900)     # la base recibe bateria
          # Para 5b: mi replica esta al dia (lo mas reciente de la flota, de
          # temperatura o de bateria, tiene <= 5 min). El motor no lo lee.
          mx = (mt != "" && (mb == "" || mt > mb)) ? mt : mb
          if (mx != "" && now - mx <= 300) print "T|fresca"
          if (okT || okB) printf "O|df:flota|flota|ok||%d\n", g
          else if (mt!="" || mb!="" || hayPrev) printf "O|df:flota|flota|mal|última temperatura %s; última batería %s|%d\n", hace(mt), hace(mb), g
          if (!okT && !okB) exit              # base parada o replica atrasada: no culpar a cada nodo
          for (i=1;i<=k;i++){ n=N[i]; d=""; vale=0
            if (okT && T[n]!="") { vale=1; if (now-T[n] > tmax) d = "sin temperatura desde hace " dur(now-T[n]) }
            if (okB && B[n]!="") { vale=1; if (now-B[n] > btmax) d = d (d==""?"":"; ") "sin batería desde hace " dur(now-B[n]) }
            if (!vale) { if (T[n]=="" && B[n]=="" && (n in Prev)) printf "O|dt:%s|%s|mal|sin datos en la base|%d\n", n, n, g; continue }
            if (d=="") printf "O|dt:%s|%s|ok||%d\n", n, n, g
            else printf "O|dt:%s|%s|mal|%s|%d\n", n, n, d, g
          } }' >> "$OBS" ;;
    esac
  fi
fi

# --- 5b. ¿Sigue funcionando el monitoreo de BTC? ---------------------------
# La pasada de BTC (sentinel014, cada 5 min; ver btc/README.md) reescribe en
# cada pasada las ultimas velas diarias de cada producto con actualizado = la
# hora de la pasada, y despues de medianoche UTC trae la vela del dia. Por
# producto (bv:<producto>) se avisa si:
#   - no escribe desde hace mas de BTC_DATOS_MAX_MIN (15 = tres pasadas): falla
#     la pasada, su temporizador o el propio 014 (y entonces ya hay aviso del
#     nodo);
#   - escribe, pero no hay vela de hoy pasado ese plazo tras medianoche UTC:
#     Coinbase no la trae (producto parado, vencido o renombrado).
# Los productos que solo cotizan de lunes a viernes (TEK-19DEC30-CDE, el Tech
# 100: sin velas UTC en sabado ni domingo, ni en los festivos de la bolsa de
# EE. UU.) se reconocen por sus datos: al menos 10 velas en los ultimos 28 dias
# y ninguna en sabado o domingo. En ellos, la vela que falta se cuenta en dias
# HABILES (lunes a viernes UTC), y un dia habil solo cuenta cuando ya pasaron
# 6 h de el mas el plazo (en invierno el lunes abre a las 01:00 UTC y a
# medianoche apenas hay operaciones). Se avisa si faltan 2 o mas seguidos: un
# festivo entre semana no avisa; dos dias habiles sin vela, si (a partir de las
# 06:15 UTC del segundo). Los demas (24/7, o con pocos datos, o parados) siguen
# la regla de arriba.
# Un producto escrito por ultima vez mas de una semana antes que el mas al dia
# se da por retirado (se quito de BTC_PRODUCTOS) y deja de mirarse; si se paran
# TODOS, se siguen mirando, con su recordatorio, aunque pasen semanas (y uno
# retirado hace tiempo sigue fuera).
# Y las señales (bs:senales): la pasada apunta en sentinel_vigia (btc-senales)
# desde cuando falla su paso 7 (Telegram que no acepta, el calculo, rqlite); se
# avisa si lleva fallando mas de ese mismo plazo. Ese fallo no deja de escribir
# las velas, asi que bv: no lo ve.
# Solo con mi replica al dia (temperatura de la flota de hace <= 5 min, "T|fresca"
# del punto 5): con la base parada o mi replica atrasada no se culpa a BTC. Sin
# la tabla, o si la consulta falla, no se observa nada y las claves conservan su
# estado.
BVMAX=$(( $(entero "${BTC_DATOS_MAX_MIN:-15}" 15) * 60 ))
if [ -n "${RQLITE:-}" ] && [ "$RZ" = 200 ] && grep -q '^T|fresca' "$OBS"; then
  # Columnas 4 y 5: velas de los ultimos 28 dias y, de ellas, las de sabado o
  # domingo UTC ((ts/86400 + 4) % 7: 0 domingo, 6 sabado; el 01/01/1970 fue jueves).
  BV28=$((AHORA - 2419200))
  VQ="SELECT producto, MAX(actualizado), MAX(ts), SUM(CASE WHEN ts>=$BV28 THEN 1 ELSE 0 END), SUM(CASE WHEN ts>=$BV28 AND (ts/86400+4)%7 IN (0,6) THEN 1 ELSE 0 END) FROM cripto_vela WHERE marco='1d' GROUP BY producto"
  rqpide /db/query -s -m 12 -G "$RQLITE/db/query" --data-urlencode "q=$VQ" --data-urlencode "level=none"
  case "$RQ_CUERPO" in *'"values"'*)
    printf '%s' "$RQ_CUERPO" | sed 's/.*"values":\[//; s/\]}.*//' | sed 's/\],\[/\n/g' | tr -d '[]" ' \
    | "$AWK" -F, -v now="$AHORA" -v max="$BVMAX" '
      function dur(s){ if (s<3600) return int(s/60) " min"; if (s<86400) return int(s/3600) " h " int((s%3600)/60) " min"; return int(s/86400) " d " int((s%86400)/3600) " h" }
      function fecha(t,  z,era,doe,yoe,doy,mp,d,m){ z=int(t/86400)+719468; era=int(z/146097); doe=z-era*146097; yoe=int((doe-int(doe/1460)+int(doe/36524)-int(doe/146096))/365); doy=doe-(365*yoe+int(yoe/4)-int(yoe/100)); mp=int((5*doy+2)/153); d=doy-int((153*mp+2)/5)+1; m=(mp<10)?mp+3:mp-9; return sprintf("%02d/%02d",d,m) }
      $1 ~ /^[A-Z0-9-]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { n++; P[n]=$1; A[n]=$2; V[n]=$3; R[n]=($4 ~ /^[0-9]+$/) ? $4+0 : 0; F[n]=($5 ~ /^[0-9]+$/) ? $5+0 : -1; if (fr=="" || now-$2 < fr) fr=now-$2 }
      END { for (i=1;i<=n;i++) { e=now-A[i]
          if (e - fr > 604800) continue          # retirado: una semana mas viejo que el mas al dia
          if (e > max) printf "O|bv:%s|%s|mal|sin escribir desde hace %s|0\n", P[i], P[i], dur(e)
          else if (R[i] >= 10 && F[i] == 0) {    # de lunes a viernes: dias habiles que faltan
            dv = int(V[i] / 86400); k = 0; pf = -1
            for (d = dv + 1; d <= dv + 400 && d * 86400 + 21600 + max <= now; d++) {
              w = (d + 4) % 7; if (w != 0 && w != 6) { k++; if (pf < 0) pf = d } }
            if (k >= 2) printf "O|bv:%s|%s|mal|escribe, pero Coinbase no trae la vela del %s (UTC); la última es del %s|0\n", P[i], P[i], fecha(pf * 86400), fecha(V[i])
            else printf "O|bv:%s|%s|ok||0\n", P[i], P[i] }
          else if (now - V[i] > 86400 + max) printf "O|bv:%s|%s|mal|escribe, pero Coinbase no trae la vela del %s (UTC); la última es del %s|0\n", P[i], P[i], fecha(V[i] + 86400), fecha(V[i])
          else printf "O|bv:%s|%s|ok||0\n", P[i], P[i] } }' >> "$OBS" ;;
  esac
  rqpide /db/query -s -m 8 -G "$RQLITE/db/query" --data-urlencode "q=SELECT ts, pendientes, wheel FROM sentinel_vigia WHERE clave='btc-senales'" \
        --data-urlencode "level=none"
  _s=$(printf '%s' "$RQ_CUERPO" | grep -oE '"values":\[\[[^]]*' | sed 's/.*\[\[//' | tr -d '" ')
  _sts=$(printf '%s' "$_s" | cut -d, -f1); _src=$(printf '%s' "$_s" | cut -d, -f2)
  case "$_sts" in ''|*[!0-9]*) ;; *)
    case "$_src" in ''|*[!0-9]*) ;; 0) obs "bs:senales" "señales de BTC" ok "" 0 ;; *)
      if [ $((AHORA - _sts)) -gt "$BVMAX" ]; then
        _sd=$(( AHORA - _sts )); if [ "$_sd" -lt 3600 ]; then _sd="$((_sd / 60)) min"; elif [ "$_sd" -lt 86400 ]; then _sd="$((_sd / 3600)) h $(( (_sd % 3600) / 60 )) min"; else _sd="$((_sd / 86400)) d $(( (_sd % 86400) / 3600 )) h"; fi
        obs "bs:senales" "señales de BTC" mal "fallan desde hace $_sd (el paso 7 sale con $_src)" 0
      else obs "bs:senales" "señales de BTC" ok "" 0; fi ;;
    esac ;;
  esac
fi

# --- 6. Equipos sin agente Sentinel (EXTRA_CHECKS) -------------------------
# EXTRA_CHECKS=nombre=tcp://ip:puerto[,nombre=http://ip:puerto/...]
# tcp: vale con que acepte la conexion (curl telnet:// mide el tiempo de conexion,
# que es 0 si no llego a conectar). http: vale cualquier respuesta, incluido 401.
set -f
for par in $(printf '%s' "${EXTRA_CHECKS:-}" | tr ',' ' '); do
  en=${par%%=*}; url=${par#*=}
  case "$en" in *[!a-zA-Z0-9_-]*|"") continue ;; esac
  [ "$url" != "$par" ] || continue
  case "$url" in tcp://?*|http://?*|https://?*) ;; *) continue ;; esac   # mal escrito: se ignora, no se da por caido
  st=mal
  for i in 1 2; do
    case "$url" in
      tcp://*) tc=$(curl -s -o /dev/null -m 4 --connect-timeout 4 -w '%{time_connect}' "telnet://${url#tcp://}" </dev/null 2>/dev/null)
               case "$tc" in *[1-9]*) st=ok ;; esac ;;   # "0.000000" = no conecto
      # -k: solo se mira si el equipo contesta, no quien es; sin el, un certificado
      # autofirmado lo daba por caido. Un servicio con certificado de CLIENTE
      # (mTLS, como el 8443 de stunnel) corta el saludo igual: ese, con tcp://.
      http://*|https://*) hc=$(curl -s -k -o /dev/null -m 6 -w '%{http_code}' "$url" 2>/dev/null)
               case "$hc" in ''|000) ;; *) st=ok ;; esac ;;
    esac
    [ "$st" = ok ] && break
    [ "$i" = 1 ] && sleep 3
  done
  h=${url#*://}; h=${h%%/*}; h=${h%%:*}
  obs "ex:$en" "$en" "$st" "$url" "$(gracia_de "$h")"
done
set +f

# --- Wheel anterior (sentinel_vigia) --------------------------------------
# Se lee aqui, antes del motor, para que su respuesta tambien cuente en au: (es
# la unica consulta que se hace en todas las pasadas). Se usa mas abajo, en el
# cambio de Wheel; la fila solo se escribe al final, asi que leerla antes no
# cambia nada.
WANT=""
if [ -n "${RQLITE:-}" ]; then
  rqpide /db/query -s -m 6 -G "$RQLITE/db/query" --data-urlencode "q=SELECT ts, wheel, pendientes FROM sentinel_vigia WHERE clave='avisos'" \
        --data-urlencode "level=none"
  _v=$(printf '%s' "$RQ_CUERPO" | grep -oE '"values":\[\[[^]]*' | sed 's/.*\[\[//' | tr -d '" ' | cut -d, -f2)
  case "$_v" in ''|*[!A-Za-z0-9_.-]*) ;; *) WANT="$_v" ;; esac
fi

# --- 7. ¿Acepta rqlite mis credenciales? ----------------------------------
# Un 401 en cualquier peticion de esta pasada = rqlite rechaza la contrasena de
# este nodo (fichero de credenciales viejo tras una rotacion, o ausente cuando ya
# se exige). Sin gracia: no es un fallo que vaya y venga. Si nada de rqlite
# contesto (rqlited caido) no se sabe: la clave conserva su estado.
if [ -n "$RQ_401" ]; then
  obs "au:$NAME" "$NAME" mal "rqlite rechaza sus credenciales (401 en $RQ_401)" 0
elif [ "$RQ_OK" = 1 ]; then
  obs "au:$NAME" "$NAME" ok "" 0
fi

# --- Motor: de lo observado a avisos y estado -----------------------------
# Formato de alert.state:  clave|nombre|estado|desde|ult_aviso|visto|ok_desde
#   clave: la IP (nodos) o un prefijo rq: dt: df: au: ex: bt: bv: bs: y __cl__.
#   desde: epoch del primer fallo de la racha (alimenta la tolerancia y la duracion).
#   ult_aviso: epoch del ultimo aviso de esta racha (para el recordatorio).
#   visto: ultima vez que se observo. Lo que no se observa se conserva tal cual
#   (un nodo caido no deja mirar su rqlite ni sus datos) y se olvida a la semana.
#   ok_desde: solo rqlite (__cl__, rq:): desde cuando va bien estando aun en mal.
# Un fichero antiguo de 3 o 4 campos se lee igual. bat.state, si existe, se
# importa una vez como claves bt: y se borra.
ANTESF="$STATE"; [ -r "$STATE" ] || ANTESF="$VACIO"
BATF="$BASE/bat.state"; [ -r "$BATF" ] || BATF="$VACIO.b"
[ -r "$BATF" ] || : > "$BATF"
"$AWK" -v now="$AHORA" -v stale="$STALE" -v record="$RECORD" -v vistomax=604800 \
     -v nodos_ok="$NODOS_OK" -v fa="$ANTESF" -v fb="$BATF" -v fo="$OBS" '
function dur(s){ if (s<60) return "menos de 1 min"; if (s<3600) return int(s/60) " min"; if (s<86400) return int(s/3600) " h " int((s%3600)/60) " min"; return int(s/86400) " d " int((s%86400)/3600) " h" }
function tipo(k){ if (k=="__cl__") return "cl"; if (index(k,":")>0) return substr(k,1,2); return "nodo" }
function linea(k,st,de,ul,vi,ok,   s){ s=st; if (tipo(k)=="nodo" && s=="mal") s="caido"; return k "|" Nom[k] "|" s "|" de "|" ul "|" vi "|" ok }
function bala(k,clase,det,espera,g,   t,ip){
	t=tipo(k)
	if (t=="nodo") { ip=k
		if (clase=="mal") return "• " Nom[k] " (" ip ")" ((det!="") ? " — " det : "") ((g>0) ? " — sin responder desde hace " dur(espera) : "")
		if (clase=="bien") return "• " Nom[k] " (" ip ")" ((Desde[k]!="") ? " tras " dur(now-Desde[k]) : "")
		return "• " Nom[k] " (" ip ") sin responder desde hace " dur(now-Desde[k]) }
	if (t=="rq") { ip=substr(k,4)
		if (clase=="mal") return "• " Nom[k] " (" ip ", " det ")"
		if (clase=="bien") return "• " Nom[k] " (" ip ")"
		return "• rqlited de " Nom[k] " fuera del clúster desde hace " dur(now-Desde[k]) }
	if (t=="cl") {
		if (clase=="mal") return "• " det
		if (clase=="bien") return "• vuelve a tener líder" ((Desde[k]!="") ? " tras " dur(now-Desde[k]) : "")
		return "• rqlite: " det " (desde hace " dur(now-Desde[k]) ")" }
	if (t=="dt") {
		if (clase=="mal") return "• " Nom[k] ": " det
		if (clase=="bien") return "• " Nom[k]
		return "• " Nom[k] ": " det }
	if (t=="df") {
		if (clase=="mal") return "• " det
		if (clase=="bien") return "• toda la flota" ((Desde[k]!="") ? " tras " dur(now-Desde[k]) : "")
		return "• la base no recibe datos nuevos: " det " (desde hace " dur(now-Desde[k]) ")" }
	if (t=="au") {
		if (clase=="mal") return "• " Nom[k] ": " det
		if (clase=="bien") return "• " Nom[k] ((Desde[k]!="") ? " tras " dur(now-Desde[k]) : "")
		return "• " Nom[k] ": " det " (desde hace " dur(now-Desde[k]) ")" }
	if (t=="ex") {
		if (clase=="mal") return "• " Nom[k] " (" det ")"
		if (clase=="bien") return "• " Nom[k] ((Desde[k]!="") ? " tras " dur(now-Desde[k]) : "")
		return "• " Nom[k] " sin responder desde hace " dur(now-Desde[k]) }
	if (t=="bt") {
		if (clase=="mal") return "• " Nom[k] " " det
		if (clase=="bien") return "• " Nom[k] " " det
		return "• " Nom[k] ": batería " det }
	if (t=="bv" || t=="bs") {
		# Al volver, sin "tras X": Desde es cuando el Wheel lo vio mal, que es el
		# plazo despues de la ultima escritura; la cifra contradiria la del aviso.
		if (clase=="mal") return "• " Nom[k] ": " det
		if (clase=="bien") return "• " Nom[k]
		return "• " Nom[k] ": " det }
	return "• " k
}
BEGIN { FS="|" }
FILENAME==fa {
	if ($0 ~ /^__wheel__=/ || NF < 3 || $1 == "") next
	k=$1; if (k in Prev) next
	Prev[k]=1; Orden[++np]=k; Nom[k]=$2; St[k]=($3=="caido") ? "mal" : $3
	Desde[k]=$4; Ult[k]=$5; Visto[k]=$6; Okd[k]=$7
	if (tipo(k)=="bt") hayBt=1
	if (stale) { St[k]="ok"; Desde[k]=""; Ult[k]=""; Okd[k]="" }
	next
}
FILENAME==fb {
	if (hayBt || NF < 2 || $1 == "") next
	k="bt:" $1; if (k in Prev) next
	Prev[k]=1; Orden[++np]=k; Nom[k]=$1; St[k]=(stale) ? "ok" : $2; Desde[k]=""; Ult[k]=""; Visto[k]=""; Okd[k]=""
	next
}
FILENAME==fo {
	if ($1 != "O") next
	k=$2; if (k in Obs) next
	Obs[k]=1; OrdenO[++no]=k; ONom[k]=$3; OSon[k]=$4; ODet[k]=$5; OGra[k]=$6+0
	next
}
END {
	for (i=1;i<=no;i++){
		k=OrdenO[i]
		if (!(k in Prev)) { St[k]="ok"; Desde[k]=""; Ult[k]=""; Okd[k]="" }   # nuevo: se asume sano
		ant=St[k]; de=Desde[k]; ul=Ult[k]; okd=Okd[k]; t=tipo(k)
		if (ONom[k]!="") Nom[k]=ONom[k]
		g=OGra[k]; espera=0
		# rqlite tambien pide estabilidad AL VOLVER: en una tormenta de elecciones
		# /readyz y "reachable" oscilan, y sin esto salia un par "sin lider" / "de
		# vuelta" cada 15 min durante horas. okd = desde cuando va bien otra vez.
		gv=(t=="cl" || t=="rq") ? g : 0
		if (OSon[k]=="mal") {
			okd=""
			if (de=="") de=now
			espera=now-de
			decl=(g>0 && espera<g) ? ant : "mal"
		} else if (ant=="mal" && gv>0) {
			if (okd=="") okd=now
			decl=(now-okd >= gv) ? "ok" : "mal"
		} else { decl="ok" }
		cm="-"
		if (ant=="ok" && decl=="mal") {
			cm=t "_mal"; if (t=="nodo") cm="caido"
			printf "M\t%s\t%s\n", cm, bala(k,"mal",ODet[k],espera,g)
			c=linea(k,"mal",de,now,now,""); f=linea(k,"ok",de,ul,now,"")
		} else if (ant=="mal" && decl=="ok") {
			cm=t "_bien"; if (t=="nodo") cm="vuelto"
			printf "M\t%s\t%s\n", cm, bala(k,"bien",ODet[k],0,g)
			c=linea(k,"ok","","",now,""); f=linea(k,"mal",Desde[k],ul,now,okd)
		} else if (decl=="mal") {
			if (ul=="") ul=now                  # racha heredada sin fecha de aviso
			if (de=="") de=now
			Desde[k]=de
			# Recordatorio solo si sigue fallando de verdad (no si ya va bien y solo
			# espera la estabilidad), y RECORDATORIO_H=0 lo desactiva.
			if (OSon[k]=="mal" && record>0 && now-ul >= record) {
				cm="recuerdo"
				printf "M\t%s\t%s\n", cm, bala(k,"recuerdo",ODet[k],0,g)
				c=linea(k,"mal",de,now,now,okd); f=linea(k,"mal",de,ul,now,okd)
			} else { c=linea(k,"mal",de,ul,now,okd); f=c }
		} else {
			if (OSon[k]=="ok") de=""
			c=linea(k,"ok",de,"",now,""); f=c
		}
		printf "S\t%s\t%s\t%s\n", cm, c, f
	}
	for (i=1;i<=np;i++){
		k=Orden[i]; if (k in Obs) continue
		if (tipo(k)=="nodo" && nodos_ok) continue       # ya no esta en la flota
		vi=Visto[k]; if (vi=="") vi=now
		if (now-vi > vistomax) continue                 # una semana sin observarse: se olvida
		# Sin observar, una racha a medias no sigue contando: si iba "ok" dentro de
		# su tolerancia, al volver a mirarse empieza de cero (antes se la saltaba);
		# y una vuelta a medias de rqlite tampoco se da por buena.
		# Excepto los datos (dt:): su antiguedad la da el propio ts, y si se borrara
		# aqui un nodo que se cae una pasada de cada cuatro no avisaria nunca de que
		# sus datos estan parados.
		de=(St[k]=="ok" && tipo(k)!="dt") ? "" : Desde[k]
		c=linea(k,St[k],de,Ult[k],vi,"")
		printf "S\t-\t%s\t%s\n", c, c
	}
}' "$ANTESF" "$BATF" "$OBS" > "$OUT"
MRC=$?
# Sin un motor sano no se toca nada: un estado vacio olvidaria todas las caidas y
# las volveria a anunciar sin nombre en la pasada siguiente.
if [ "$MRC" != 0 ] || [ ! -f "$OUT" ] || { [ -n "$ANTES" ] && ! grep -q "^S$TAB" "$OUT"; }; then
  registrar motor "FALLO rc=$MRC" "no se escribe alert.state en esta pasada"
  exit 1
fi

# --- Envio por categorias -------------------------------------------------
# Un mensaje por categoria y pasada. Si una categoria no se puede enviar, sus
# claves vuelven a su estado anterior y la pasada siguiente lo reintenta.
cuerpo(){ grep "^M$TAB$1$TAB" "$OUT" | cut -f3- | sed 's/^/  /'; }
OKC=" - "; FALLOS=0
mandar(){ # $1=categoria $2=cabecera $3=pie
  _b=$(cuerpo "$1"); [ -n "$_b" ] || return 0
  if enviar "$1" "$2
$_b${3:+
$3}"; then OKC="$OKC$1 "; else FALLOS=$((FALLOS + 1)); fi
}
W="Avisa $NAME (Wheel)."
mandar caido   "🔴 Sentinel: nodo sin responder:" "Dos sondeos fallidos al puerto $PORT. $W"
mandar vuelto  "🟢 Sentinel: nodo recuperado:" "$W"
mandar cl_mal  "🔴 Sentinel: rqlite sin líder:" "Sin líder no se guarda telemetría ni responde el chatbot. $W"
mandar cl_bien "🟢 Sentinel: rqlite de vuelta:" "$W"
mandar au_mal  "🔴 Sentinel: rqlite rechaza la contraseña de:" "Revisar ~/.config/rqlite/sentinel.curlrc (o RQLITE_CRED de sentinel.conf) en ese nodo. Sin credenciales válidas, ese nodo no guarda telemetría ni vigila bien. $W"
mandar au_bien "🟢 Sentinel: rqlite vuelve a aceptar la contraseña de:" "$W"
mandar rq_mal  "🔴 Sentinel: el clúster no alcanza el rqlite de:" "El agente del nodo sí responde: lo caído es su rqlited. $W"
mandar rq_bien "🟢 Sentinel: rqlite de vuelta en el clúster:" "$W"
mandar dt_mal  "🟠 Sentinel: el nodo responde, pero sus datos no llegan:" "Temperatura = thermal-guard; batería = Sentinel-Bateria. En Termux los dos van por cron: si se paró, tampoco corren ahí la elección, los avisos ni el vigilante. Si rqlite ya pide contraseña, también puede ser que rechace la de ese nodo (revisar ~/.config/rqlite/sentinel.curlrc). $W"
mandar dt_bien "🟢 Sentinel: vuelven a llegar los datos de:" "$W"
mandar df_mal  "🔴 Sentinel: la base no recibe datos nuevos de ningún nodo:" "rqlite tiene líder, pero nadie escribe. Causas posibles: la contraseña rechazada (401) en toda la flota, el cron parado en todos los nodos o la réplica de $NAME atrasada. $W"
mandar df_bien "🟢 Sentinel: la base vuelve a recibir datos:" "$W"
mandar ex_mal  "🔴 Sentinel: equipo sin responder:" "Dos sondeos fallidos. $W"
mandar ex_bien "🟢 Sentinel: equipo recuperado:" "$W"
mandar bt_mal  "🔋 Sentinel: enchufado pero perdiendo batería:" "Android corta la carga por encima de unos 42 °C. $W"
mandar bt_bien "🔌 Sentinel: batería recuperada:" "$W"
mandar bv_mal  "🟠 Sentinel: el monitoreo de BTC no está al día:" "Lo escribe sentinel014 cada 5 min (temporizador sentinel-btc-velas). En 014: tail ~/PRC_Sentinel/btc/velas.log y journalctl --user -u sentinel-btc-velas. Sin esto tampoco salen las señales de mercado. $W"
mandar bv_bien "🟢 Sentinel: el monitoreo de BTC vuelve a estar al día:" "$W"
mandar bs_mal  "🟠 Sentinel: las señales de BTC no salen:" "Las calcula y las manda por Telegram la pasada de sentinel014 (paso 7). En 014: grep señales ~/PRC_Sentinel/btc/velas.log. Las de una vela cerrada hace más de 36 h ya no se mandarán. $W"
mandar bs_bien "🟢 Sentinel: las señales de BTC vuelven a salir:" "$W"
mandar recuerdo "🟠 Sentinel: sigue pendiente (recordatorio cada $(( RECORD / 3600 )) h):" "$W"

# --- Cambio de Wheel ------------------------------------------------------
# Quien paso por ultima vez se lee de rqlite (sentinel_vigia, la fila del latido),
# que es comun a todos. alert.state es de cada nodo y cada uno solo apunta su
# propio nombre, asi que comparando con el no salia nunca este aviso en un relevo
# real. Sin rqlite se mira el fichero, como antes. Si el envio falla, el latido
# guarda el Wheel anterior para que la pasada siguiente lo reintente.
# (WANT se leyo antes del motor, para que esa consulta cuente en au:.)
WLOCAL=$(printf '%s\n' "$ANTES" | sed -n 's/^__wheel__=//p' | head -1)
[ -n "$WANT" ] || WANT="$WLOCAL"
# Solo si de verdad acabo de llegar: mi alert.state no dice ya que soy yo (o es de
# otra epoca). Si no, dos nodos que se creyeran Wheel a la vez y no se vieran se
# anunciarian el relevo el uno al otro cada 5 min.
NUEVO_W=0; { [ "$WLOCAL" != "$NAME" ] || [ "$STALE" = 1 ]; } && NUEVO_W=1
WNUEVO="$NAME"; WLAT="$NAME"
if [ -n "$WANT" ] && [ "$WANT" != "$NAME" ] && [ "$NUEVO_W" = 1 ]; then
  if ! enviar wheel "🔵 Sentinel: el coordinador (Wheel) pasa de $WANT a $NAME."; then
    WNUEVO="$WANT"; WLAT="$WANT"; FALLOS=$((FALLOS + 1))
  fi
fi

# --- Estado nuevo (escritura atomica) -------------------------------------
# En DRY no se guarda: daria por enviados avisos que solo se imprimieron, y una
# prueba a mano en el Wheel se comeria la alerta real.
if [ "$DRY" = "1" ]; then
  echo "[DRY] alert.state no se guarda ($(grep -c "^S$TAB" "$OUT") claves)"
elif {
  while IFS="$TAB" read -r tag ca c f; do
    [ "$tag" = S ] || continue
    case "$OKC" in *" $ca "*) printf '%s\n' "$c" ;; *) printf '%s\n' "$f" ;; esac
  done < "$OUT"
  printf '__wheel__=%s\n' "$WNUEVO"
} > "$STATE.tmp.$$" && mv "$STATE.tmp.$$" "$STATE"; then
  rm -f "$BASE/bat.state" "$VACIO.b"    # ya importado como claves bt:
fi

if [ -f "$LOGF" ] && [ "$(wc -l < "$LOGF")" -gt 600 ]; then
  tail -n 300 "$LOGF" > "$LOGF.tmp" 2>/dev/null && mv "$LOGF.tmp" "$LOGF"
fi

# --- Latido ---------------------------------------------------------------
# La hora de esta pasada, para que alguien de FUERA pueda ver que los avisos
# siguen corriendo (Sentinel-Latido.sh la lleva a la EC2). 'pendientes' = envios
# que fallaron en esta pasada: si no baja de 0, Telegram no esta llegando.
# Si rqlite no lo acepta (401, sin lider...) queda en alert.log: la EC2 vera que
# la pasada no avanza, y aqui se sabra por que.
if [ "$DRY" != "1" ] && [ -n "${RQLITE:-}" ]; then
  rqpide /db/execute -s -m 8 -XPOST "$RQLITE/db/execute" -H 'Content-Type: application/json' \
    -d "[[\"CREATE TABLE IF NOT EXISTS sentinel_vigia (clave TEXT PRIMARY KEY, ts INTEGER NOT NULL, wheel TEXT, pendientes INTEGER)\"], [\"INSERT OR REPLACE INTO sentinel_vigia (clave, ts, wheel, pendientes) VALUES (?, ?, ?, ?)\", \"avisos\", $AHORA, \"$WLAT\", $FALLOS]]"
  [ "$RQ_HC" = 200 ] || registrar latido "FALLO http=$RQ_HC" "no se pudo apuntar la pasada en sentinel_vigia"
fi
exit 0
