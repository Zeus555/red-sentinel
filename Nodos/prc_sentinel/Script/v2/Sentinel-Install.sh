#!/usr/bin/env sh
# Sentinel v2 - Instalador por nodo (Fase 5).
#
#   ./Sentinel-Install.sh <nombre-nodo> [--role Super] [--port 8181] [--apply]
#
# SIN --apply no escribe nada: enseña exactamente lo que haría (dry-run). Es el
# modo por defecto a proposito — esto toca dispositivos de la flota.
#
# Instala en ~/PRC_Sentinel/v2/ (junto al v1, sin tocarlo) y deja el servicio
# DEFINIDO PERO PARADO: arrancarlo es un paso manual aparte, para que el alta y
# la puesta en marcha no ocurran por accidente en la misma orden.
#
# Idempotente: si sentinel.conf ya existe conserva su TOKEN (regenerarlo dejaria
# fuera a los clientes que ya lo tienen).

set -u
NAME=""; ROLE="Nodo"; PORT="8181"; APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    -*) echo "opcion desconocida: $1" >&2; exit 1 ;;
    *) NAME="$1"; shift ;;
  esac
done
[ -n "$NAME" ] || { echo "uso: $0 <nombre-nodo> [--role Super] [--port 8181] [--apply]" >&2; exit 1; }

SRC="$(cd "$(dirname "$0")" && pwd)"
BASE="$HOME/PRC_Sentinel/v2"
say(){ [ "$APPLY" = "1" ] && echo "  $*" || echo "  [dry-run] $*"; }
do_(){ if [ "$APPLY" = "1" ]; then eval "$@"; else echo "  [dry-run] $*"; fi }

detect_os(){
  u=$(uname -a 2>/dev/null || echo "")
  case "$u" in
    *Android*) echo Termux ;; *Ubuntu*) echo Ubuntu ;; *Debian*) echo Debian ;;
    *Raspbian*) echo Raspberry ;; *tinycore*) echo Tiny ;; *MINGW*|*MSYS*|*CYGWIN*) echo Windows ;; "") echo Windows ;; *) echo Linux ;;
  esac
}
OS=$(detect_os)

echo "== Sentinel v2 :: instalacion en '$NAME' ($OS), rol=$ROLE puerto=$PORT =="
[ "$APPLY" = "1" ] || echo "   MODO DRY-RUN: no se escribe nada. Añade --apply para aplicar."

# --- Requisitos ---
for b in gawk curl; do
  command -v $b >/dev/null 2>&1 || { echo "FALTA '$b': imprescindible. Abortado." >&2; exit 1; }
done
echo "  requisitos: gawk y curl presentes"

# --- Comprobacion previa del puerto ---
# En Android no vale netstat (no deja leer /proc/net/tcp): se comprueba
# conectandose. Si algo responde ya en el puerto, el servicio entraria en bucle
# de bind sin explicar por que.
# Se mira TODA la cabecera, no solo 'Server': hay servicios (rqlite, sin ir mas
# lejos) que no la envian, y quedarnos en ese campo daria por libre un puerto
# que esta ocupado.
HDR=$(curl -s -m 2 -D- -o /dev/null "http://127.0.0.1:$PORT/version" 2>/dev/null)
if [ -n "$HDR" ]; then
  case "$HDR" in
    *Sentinel*) echo "  aviso: el puerto $PORT ya lo sirve un Sentinel (reinstalacion)" ;;
    *) echo "NO ESTA LIBRE el puerto $PORT: responde otro servicio:" >&2
       echo "$HDR" | head -1 | sed 's/^/    /' >&2
       echo "  Usa --port con otro puerto, o para ese servicio. Abortado." >&2; exit 1 ;;
  esac
else
  echo "  puerto $PORT libre"
fi

# --- Directorios ---
do_ "mkdir -p '$BASE/jobs' '$BASE/spool' '$BASE/Certs' '$HOME/PRC_Sentinel/Run'"

# --- Codigo ---
for f in Sentinel-Server2.awk Sentinel-Worker.awk Sentinel-Allow.conf Sentinel-Discover.awk Sentinel-PKI.sh Sentinel-TLS.sh Sentinel-Token.sh Sentinel-Wheel.awk; do
  [ -f "$SRC/$f" ] || { echo "FALTA el fuente $f en $SRC. Abortado." >&2; exit 1; }
  do_ "cp -f '$SRC/$f' '$BASE/$f'"
done
say "codigo copiado a $BASE"

# --- Configuracion: conserva el TOKEN si ya existe ---
CONF="$BASE/sentinel.conf"
if [ -f "$CONF" ]; then
  say "sentinel.conf ya existe: se conserva (y con el, su TOKEN)"
else
  # NO se genera token aqui: el token es UNO SOLO para toda la flota. Generar uno
  # por nodo (como hacia la version anterior de este instalador) dejaba a cada
  # nodo en su propia "red" y el Wheel no podia coordinar nada.
  if [ "$APPLY" = "1" ]; then
    sed -e "s/^NAME=.*/NAME=$NAME/" -e "s/^ROLE=.*/ROLE=$ROLE/" -e "s/^PORT=.*/PORT=$PORT/" \
        -e "s/^TOKEN=.*/TOKEN=/" "$SRC/Sentinel-Node.conf.example" > "$CONF"
    chmod 600 "$CONF"
    echo "  sentinel.conf creado (600), SIN token"
  else
    echo "  [dry-run] crearia $CONF (600) con NAME=$NAME ROLE=$ROLE PORT=$PORT y SIN token"
  fi
fi

# --- Token de flota ---
if [ -f "$BASE/fleet.token" ]; then
  say "token de flota ya presente (no se toca)"
else
  echo "  FALTA EL TOKEN DE FLOTA. El servicio no arrancara sin el."
  echo "    primer nodo de la red:  sh $BASE/Sentinel-Token.sh create"
  echo "    resto de nodos:         sh $BASE/Sentinel-Token.sh import <token>"
fi

# --- Servicio, DEFINIDO PERO PARADO ---
case "$OS" in
  Termux)
    SV="$PREFIX/var/service/sentinel-v2"
    do_ "mkdir -p '$SV/log'"
    do_ "cp -f '$SRC/service/sentinel-start.sh' '$BASE/sentinel-start.sh'"
    do_ "chmod 755 '$BASE/sentinel-start.sh'"
    do_ "cp -f '$SRC/service/runit-run.sh' '$SV/run'"
    do_ "chmod 755 '$SV/run'"
    # 'down' hace que runit NO lo arranque al crearlo ni tras reboot hasta que se quite.
    do_ "touch '$SV/down'"
    if [ "$APPLY" = "1" ]; then
      printf '#!/data/data/com.termux/files/usr/bin/sh\nexec svlogd -tt %s/var/log/sv/sentinel-v2\n' "$PREFIX" > "$SV/log/run"
      chmod 755 "$SV/log/run"; mkdir -p "$PREFIX/var/log/sv/sentinel-v2"
    else echo "  [dry-run] crearia $SV/log/run (svlogd)"; fi
    say "servicio runit definido en $SV (con fichero 'down': NO arranca solo)"
    # Terminador TLS, tambien supervisado: si se lanza a mano no sobrevive a un
    # reinicio y el nodo se queda sin mTLS sin que nadie lo note.
    SVT="$PREFIX/var/service/sentinel-v2-tls"
    do_ "mkdir -p '$SVT/log'"
    do_ "cp -f '$SRC/service/sentinel-tls-start.sh' '$BASE/sentinel-tls-start.sh'"
    do_ "chmod 755 '$BASE/sentinel-tls-start.sh'"
    do_ "cp -f '$SRC/service/runit-tls-run.sh' '$SVT/run'"
    do_ "chmod 755 '$SVT/run'"
    do_ "touch '$SVT/down'"
    if [ "$APPLY" = "1" ]; then
      printf '#!/data/data/com.termux/files/usr/bin/sh\nexec svlogd -tt %s/var/log/sv/sentinel-v2-tls\n' "$PREFIX" > "$SVT/log/run"
      chmod 755 "$SVT/log/run"; mkdir -p "$PREFIX/var/log/sv/sentinel-v2-tls"
    else echo "  [dry-run] crearia $SVT/log/run (svlogd)"; fi
    say "servicio TLS definido en $SVT (tambien parado)"
    echo "  para arrancarlos:  rm $SV/down && sv up sentinel-v2"
    echo "                     rm $SVT/down && sv up sentinel-v2-tls   (tras copiar los certificados)"
    ;;
  Ubuntu|Debian|Raspberry|Linux)
    UD="$HOME/.config/systemd/user"
    do_ "mkdir -p '$UD'"
    do_ "cp -f '$SRC/service/sentinel-start.sh' '$BASE/sentinel-start.sh'"
    do_ "chmod 755 '$BASE/sentinel-start.sh'"
    do_ "cp -f '$SRC/service/sentinel-tls-start.sh' '$BASE/sentinel-tls-start.sh'"
    do_ "chmod 755 '$BASE/sentinel-tls-start.sh'"
    do_ "cp -f '$SRC/service/sentinel-v2.service' '$UD/sentinel-v2.service'"
    do_ "cp -f '$SRC/service/sentinel-v2-tls.service' '$UD/sentinel-v2-tls.service'"
    do_ "systemctl --user daemon-reload"
    say "unidad systemd instalada en $UD (sin enable ni start)"
    echo "  para arrancarlo:  systemctl --user enable --now sentinel-v2"
    ;;
  Windows)
    say "en el Wheel no se registra tarea automatica: revisar a mano"
    echo "  arranque manual sugerido:"
    echo "    gawk -v Port=$PORT -v role=$ROLE -v token=<TOKEN> ... -f Sentinel-Server2.awk"
    ;;
  *) say "SO no reconocido: instalar el servicio a mano" ;;
esac

echo
echo "== Resumen =="
echo "  El v1 NO se ha tocado: sigue en ~/PRC_Sentinel/ y su crontab sigue comentado."
echo "  El servicio queda DEFINIDO PERO PARADO. Arrancarlo es un paso aparte."
echo "  Siguiente: copiar ca.pem + <nodo>.pem/.key a $BASE/Certs y lanzar Sentinel-TLS.sh"
