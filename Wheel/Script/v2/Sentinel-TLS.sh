#!/usr/bin/env sh
# Sentinel v2 - Terminador TLS con mTLS delante del aceptador gawk (Fase 3).
#
#   ./Sentinel-TLS.sh <nombre-nodo> [puerto_tls] [puerto_backend]
#
# gawk no habla TLS: el cifrado lo pone stunnel por delante, y openssl genera la
# PKI (ver Sentinel-PKI.sh). Con requireCert/verifyChain, un cliente sin
# certificado firmado por la CA Sentinel NO llega siquiera al backend.
#
# POR QUE stunnel Y NO 'openssl s_server' (probado el 2026-08-13):
#   s_server -Verify 1 REGISTRA el fallo de verificacion ("unable to get local
#   issuer certificate") pero SIRVE LA RESPUESTA IGUAL — un cliente con un
#   certificado de otra CA obtuvo el contenido completo, en TLS 1.3 y tambien
#   forzando TLS 1.2. Es una herramienta de pruebas, no una pasarela de
#   seguridad. Usarla de terminador dejaria el mTLS de adorno. Por eso este
#   script PREFIERE FALLAR a arrancar sin stunnel.
#
# AVISO IMPORTANTE — el backend sigue expuesto:
#   gawk solo sabe atar 0.0.0.0 (su sintaxis /inet4/tcp/PUERTO/0/0 no tiene campo
#   de direccion local), asi que el puerto en claro del backend es alcanzable
#   desde la LAN y cualquiera puede SALTARSE este terminador. Por eso el
#   aceptador exige token en las rutas sensibles, y ademas conviene cerrar el
#   puerto del backend en el cortafuegos (ver ayuda al final).

set -u
NAME="${1:-}"
TLS_PORT="${2:-8443}"
BACK_PORT="${3:-8181}"
DIR="$(cd "$(dirname "$0")" && pwd)"
CERTS="${SENTINEL_CERTS:-$DIR/Certs}"
RUNDIR="${SENTINEL_RUN:-$DIR/_run}"

[ -n "$NAME" ] || { echo "uso: $0 <nombre-nodo> [puerto_tls] [puerto_backend]" >&2; exit 1; }
mkdir -p "$RUNDIR"

die(){ echo "ERROR: $1" >&2; exit 1; }

detect_os(){
  u=$(uname -a 2>/dev/null || echo "")
  case "$u" in
    *Android*)  echo Termux ;;
    *Ubuntu*)   echo Ubuntu ;;
    *Debian*)   echo Debian ;;
    *Raspbian*) echo Raspberry ;;
    *tinycore*) echo Tiny ;; *MINGW*|*MSYS*|*CYGWIN*) echo Windows ;;
    "")         echo Windows ;;
    *)          echo Linux ;;
  esac
}

# Instalacion NO interactiva. Sin las opciones de dpkg, un paquete con fichero de
# configuracion modificado (p.ej. openssl.cnf retocado) abre un dialogo
# "Y/I/N/O/D/Z" y, al no haber stdin, aborta con "end of file on stdin at
# conffile prompt" y no instala nada. Visto en sentinel003 el 2026-08-13.
APT_NI='-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef'
apt_install(){ DEBIAN_FRONTEND=noninteractive apt-get install -y $APT_NI "$@"; }

# Los intentos de instalacion se ESPACIAN. Este script lo arranca un supervisor
# (runit/systemd) que lo relanza al instante si falla, asi que sin freno cada
# reinicio dispara un apt-get: se pelean por el lock de dpkg, no dejan instalar ni
# a mano, y se comen bateria y CPU del telefono. Visto en sentinel010 el
# 2026-08-13 (lock retenido por el propio bucle del servicio).
# Una marca POR PAQUETE: con una sola marca compartida, instalar el primer
# paquete consumia el intento y bloqueaba el segundo (visto en sentinel002:
# openssl entraba y stunnel se quedaba fuera).
pkg_throttled(){ # $1 = nombre del paquete
  PKGTRY="$RUNDIR/.ultimo-intento-$1"
  [ -f "$PKGTRY" ] || return 1                       # nunca se intento: adelante
  last=$(gawk 'NR==1{print $1+0}' "$PKGTRY" 2>/dev/null); [ -n "$last" ] || last=0
  now=$(date +%s 2>/dev/null || echo 0)
  [ $((now - last)) -lt 3600 ]                        # menos de 1 h: no reintentar
}

ensure_pkg(){ # $1=binario  $2=paquete termux  $3=paquete apt  $4=paquete tce  $5=paquete choco
  command -v "$1" >/dev/null 2>&1 && return 0
  if pkg_throttled "$1"; then
    echo "'$1' falta, pero ya se intento instalar hace menos de 1 h: no se insiste."
    return 1
  fi
  date +%s > "$RUNDIR/.ultimo-intento-$1" 2>/dev/null
  echo "'$1' no esta instalado; intentando instalarlo para $(detect_os)..."
  # El indice puede estar rancio y pedir una version que ya no existe en el
  # espejo (404). Visto en sentinel009 el 2026-08-13.
  case "$(detect_os)" in
    Termux|Ubuntu|Debian|Raspberry) (apt-get update -y >/dev/null 2>&1 || true) ;;
  esac
  case "$(detect_os)" in
    Termux)                 apt_install "$2" ;;
    Ubuntu|Debian|Raspberry) (sudo apt-get update -y && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $APT_NI "$3") || apt_install "$3" ;;
    Tiny)                   tce-load -wi "$4" ;;
    Windows)                command -v choco >/dev/null 2>&1 && choco install -y "$5" ;;
    *)                      echo "SO no reconocido: instala '$1' a mano" ;;
  esac
  command -v "$1" >/dev/null 2>&1
}

ensure_pkg openssl openssl-tool openssl openssl openssl \
  || die "sin openssl no hay PKI posible; instalalo a mano"

# Certificados: se generan si faltan (la CA debe existir ya; se crea en el Wheel).
[ -f "$CERTS/ca.pem" ] || die "falta la CA. Crea con: ./Sentinel-PKI.sh ca  (y copia ca.pem a este nodo)"
if [ ! -f "$CERTS/$NAME.pem" ]; then
  [ -f "$CERTS/ca.key" ] || die "falta $CERTS/$NAME.pem y no hay ca.key aqui para emitirlo. Emitelo en el Wheel y copia $NAME.pem/$NAME.key"
  echo "Emitiendo certificado para $NAME..."
  sh "$DIR/Sentinel-PKI.sh" node "$NAME" "$(hostname -i 2>/dev/null | awk '{print $1}')" || die "no se pudo emitir el certificado"
fi

if ! ensure_pkg stunnel stunnel apt-stunnel4-placeholder stunnel stunnel; then
  # Segundo intento con el nombre real del paquete en Debian/Ubuntu.
  case "$(detect_os)" in
    Ubuntu|Debian|Raspberry) (sudo apt-get install -y stunnel4 || apt-get install -y stunnel4) >/dev/null 2>&1 ;;
  esac
fi
command -v stunnel >/dev/null 2>&1 || command -v stunnel4 >/dev/null 2>&1 || cat >&2 <<EOF
ERROR: no hay stunnel y no se pudo instalar.

NO se arranca un terminador improvisado con 'openssl s_server': se comprobo que
sirve la respuesta a clientes con certificado de otra CA, o sea que el mTLS
quedaria de adorno. Es preferible no tener TLS a creer que se tiene.

Instalalo a mano y vuelve a ejecutar:
  Termux            pkg install stunnel
  Ubuntu/Debian     sudo apt-get install stunnel4
  Raspberry         sudo apt-get install stunnel4
  TinyCore          tce-load -wi stunnel
  Windows           choco install stunnel   (o binario de stunnel.org)
EOF
if ! command -v stunnel >/dev/null 2>&1 && ! command -v stunnel4 >/dev/null 2>&1; then
  # Esperar ANTES de rendirse: el supervisor relanza al instante, y sin este
  # freno el servicio giraria en vacio cada 2 s. Al siguiente ciclo se vuelve a
  # intentar la instalacion (espaciada 1 h) o se aprovecha si alguien la hizo.
  echo "Se reintentara en 5 minutos."
  sleep 300
  exit 1
fi
STUNNEL=$(command -v stunnel || command -v stunnel4)

CONF="$RUNDIR/stunnel-$NAME.conf"
cat > "$CONF" <<EOF
; Generado por Sentinel-TLS.sh — no editar a mano, se regenera.
foreground = yes
pid        =
debug      = 4
output     = $RUNDIR/stunnel-$NAME.log

[sentinel]
accept  = 0.0.0.0:$TLS_PORT
connect = 127.0.0.1:$BACK_PORT
cert    = $CERTS/$NAME.pem
key     = $CERTS/$NAME.key
CAfile  = $CERTS/ca.pem
; mTLS: exige certificado de cliente y que encadene con la CA Sentinel.
verifyChain    = yes
requireCert    = yes
sslVersion     = TLSv1.2
options        = NO_SSLv2
options        = NO_SSLv3
EOF
chmod 600 "$CONF" 2>/dev/null

echo "Terminador TLS listo:"
echo "  entrada mTLS : https://0.0.0.0:$TLS_PORT   (exige certificado de la CA Sentinel)"
echo "  backend      : 127.0.0.1:$BACK_PORT"
echo "  config       : $CONF"
echo
echo "RECUERDA: el backend en $BACK_PORT escucha en 0.0.0.0 (limite de gawk) y se"
echo "puede alcanzar sin pasar por aqui. Manten el token del aceptador y, si puedes,"
echo "cierra el puerto en el cortafuegos:"
echo "  Ubuntu/Raspberry : sudo ufw deny $BACK_PORT/tcp"
echo "  Windows          : New-NetFirewallRule -DisplayName SentinelBackend -Direction Inbound -LocalPort $BACK_PORT -Protocol TCP -Action Block"
echo "  (en Termux no hay cortafuegos: el token es la unica defensa)"
echo
exec "$STUNNEL" "$CONF"
