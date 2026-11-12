#!/usr/bin/env bash
# repartir-clientes.sh - Fase 0 de la contrasena de rqlite: lleva a cada equipo el
# fichero de credenciales de su cliente. No toca rqlited ni reinicia nada.
#
#   11 nodos      ~/.config/rqlite/sentinel.curlrc            (usuario sentinel)
#   sentinel005   ademas RQLITE_USER y RQLITE_PASSWORD en ~/Herramientas/WhatsApp_Checker/.env
#                 (usuario lector), con copia .env.bak-AAAAMMDD. El chatbot NO se
#                 reinicia: lo lee al arrancar, y eso se hace a mano.
#   sentinel020   /d/RED Respaldo/rqlite-respaldo.curlrc     (usuario respaldo)
#
# Los ficheros salen de ${RQLITE_AUTH_DIR:-$HOME/.config/rqlite}, donde los deja
# generar-claves.sh. Los de la laptop (loteria, lector, admin) ya estan en su sitio.
#
# COMO VIAJA LA CLAVE: por la ENTRADA de ssh, nunca en argv (ni aqui ni en el equipo
# remoto, donde saldria en ps). El script remoto va como argumento de sh -c y no
# lleva secretos: umask 077, mkdir -p, escribe en .tmp, chmod 600 y mv. Despues el
# equipo devuelve el md5 y los permisos del fichero, nunca su contenido, y aqui se
# comparan con los del fichero local.
#
# Uso:  repartir-clientes.sh [--seco] [--solo nodo,nodo,...]
#   --seco   dice lo que haria, sin conectar con nadie
#   --solo   solo esos equipos (sentinel005 o 005; separados por comas)
# Codigo de salida: 0 todos OK, 1 alguno fallo, 2 uso incorrecto o ficheros locales mal.

set -u
export LC_ALL=C
# ssh de Git Bash no necesita esto, pero si el ssh que se encuentra es el de Windows
# MSYS no debe tocar los argumentos (el comando de sentinel020 lleva rutas).
export MSYS_NO_PATHCONV=1

DIR="${RQLITE_AUTH_DIR:-$HOME/.config/rqlite}"
NODOS="sentinel001 sentinel002 sentinel003 sentinel005 sentinel009 sentinel010 sentinel014 sentinel016 sentinel017 sentinel018 sentinel019"
TODOS="$NODOS sentinel020"
# Carpeta del respaldo en sentinel020 (Git Bash). Solo se cambia para probar.
DESTINO_020="${DESTINO_020:-/d/RED Respaldo}"
# StrictHostKeyChecking=yes: el ~/.ssh/config de la laptop dice accept-new, y con eso un
# equipo que aun no esta en known_hosts (o un desconocido con su IP, p. ej. fuera de casa)
# recibiria la clave sin verificar quien es. Aqui un host sin clave conocida es FALLO.
# -T: sin pseudoterminal, que podria devolver por eco lo que entra por la entrada.
SSH_OPC="-T -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -o LogLevel=ERROR"
# Tope por equipo: ConnectTimeout solo cubre la conexion, no un telefono que se
# duerme a mitad de camino.
TOPE=60

uso(){ sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; }
SECO=0
SOLO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --seco) SECO=1 ;;
    --solo) [ $# -ge 2 ] || { printf 'falta la lista de --solo\n' >&2; exit 2; }; SOLO=$2; shift ;;
    --solo=*) SOLO=${1#--solo=} ;;
    -h|--ayuda|--help) uso; exit 0 ;;
    *) printf 'opcion desconocida: %s\n' "$1" >&2; uso >&2; exit 2 ;;
  esac
  shift
done

# --- equipos elegidos ----------------------------------------------------------------
if [ -n "$SOLO" ]; then
  ELEGIDOS=""
  for x in $(printf '%s' "$SOLO" | tr ',' ' '); do
    case "$x" in [0-9][0-9][0-9]) x="sentinel$x" ;; esac
    case " $TODOS " in
      *" $x "*) case " $ELEGIDOS " in *" $x "*) ;; *) ELEGIDOS="$ELEGIDOS $x" ;; esac ;;
      *) printf 'equipo desconocido en --solo: %s (validos: %s)\n' "$x" "$TODOS" >&2; exit 2 ;;
    esac
  done
  [ -n "$ELEGIDOS" ] || { printf -- '--solo sin equipos\n' >&2; exit 2; }
else
  ELEGIDOS=$TODOS
fi
elegido(){ case " $ELEGIDOS " in *" $1 "*) return 0 ;; esac; return 1; }

# --- scripts remotos (SIN secretos y SIN comillas simples: van dentro de sh -c '...') --
# Termux y Ubuntu. En Termux HOME es /data/data/com.termux/files/home: siempre $HOME.
R_NODO='umask 077
d="$HOME/.config/rqlite"; f="$d/sentinel.curlrc"
mkdir -p "$d" && chmod 700 "$d" || { echo "no se pudo crear ~/.config/rqlite"; exit 3; }
cat > "$f.tmp" && [ -s "$f.tmp" ] || { rm -f "$f.tmp"; echo "no llego el contenido"; exit 4; }
chmod 600 "$f.tmp" && mv -f "$f.tmp" "$f" || { rm -f "$f.tmp"; echo "no se pudo colocar el fichero"; exit 5; }
echo "md5=$(md5sum < "$f" | cut -c1-32) perm=$(stat -c %a "$f" 2>/dev/null || echo desconocido)"'

# sentinel005: cambia las lineas RQLITE_USER y RQLITE_PASSWORD del .env del chatbot (o
# las anade al final) sin tocar el resto. Las dos lineas nuevas llegan por la entrada y
# se leen con read, que es interno del shell. La copia del dia no se pisa: si se repite
# la pasada, sigue guardando el .env de antes del primer cambio.
R_CHATBOT='umask 077
w="$HOME/Herramientas/WhatsApp_Checker"; e="$w/.env"; t="$e.tmp"
[ -d "$w" ] || { echo "no existe ~/Herramientas/WhatsApp_Checker"; exit 3; }
IFS= read -r nu; IFS= read -r np
case "$nu" in RQLITE_USER=?*) ;; *) echo "entrada inesperada"; exit 4 ;; esac
case "$np" in RQLITE_PASSWORD=?*) ;; *) echo "entrada inesperada"; exit 4 ;; esac
copia="sin .env previo"
if [ -f "$e" ]; then
  b="$e.bak-$(date +%Y%m%d)"
  if [ -e "$b" ]; then copia="${b##*/} (ya existia, no se pisa)"
  else cp -p "$e" "$b" || { echo "no se pudo hacer la copia ${b##*/}"; exit 5; }; copia="${b##*/}"; fi
fi
vu=0; vp=0
{
  if [ -f "$e" ]; then
    while IFS= read -r l || [ -n "$l" ]; do
      case "$l" in
        RQLITE_USER=*|"export RQLITE_USER="*) [ $vu = 1 ] || printf "%s\n" "$nu"; vu=1 ;;
        RQLITE_PASSWORD=*|"export RQLITE_PASSWORD="*) [ $vp = 1 ] || printf "%s\n" "$np"; vp=1 ;;
        *) printf "%s\n" "$l" ;;
      esac
    done < "$e"
  fi
  [ $vu = 1 ] || printf "%s\n" "$nu"
  [ $vp = 1 ] || printf "%s\n" "$np"
} > "$t" || { rm -f "$t"; echo "no se pudo escribir $t"; exit 5; }
nu=""; np=""
chmod 600 "$t" && mv -f "$t" "$e" || { rm -f "$t"; echo "no se pudo colocar el .env"; exit 5; }
n=$(grep -c -E "^(RQLITE_USER|RQLITE_PASSWORD)=" "$e")
m=$(grep -E "^(RQLITE_USER|RQLITE_PASSWORD)=" "$e" | LC_ALL=C sort | md5sum | cut -c1-32)
echo "md5=$m perm=$(stat -c %a "$e" 2>/dev/null || echo desconocido) lineas=$n copia=$copia"'

# sentinel020 es Windows: el ssh abre cmd.exe. A Git Bash se llega con
#   cd /d "C:\Program Files\Git\usr\bin" && .\bash.exe --noprofile --norc -c "<script>"
# El cd evita poner la ruta con espacios entre comillas al principio del comando, que
# cmd /c se come cuando hay mas de dos comillas. Por eso el script va en UNA linea, sin
# comillas dobles ni % (cmd los interpreta). Los permisos de NTFS no se ven desde Git
# Bash, asi que alli no se comprueba el 600.
case "$DESTINO_020" in *"'"*|*'"'*|*%*) printf 'DESTINO_020 no puede llevar comillas ni %%\n' >&2; exit 2 ;; esac
R_020="export PATH=/usr/bin:\$PATH; umask 077; cd '$DESTINO_020' || { echo no existe $DESTINO_020; exit 3; }; cat > rqlite-respaldo.curlrc.tmp && [ -s rqlite-respaldo.curlrc.tmp ] || { rm -f rqlite-respaldo.curlrc.tmp; echo no llego el contenido; exit 4; }; chmod 600 rqlite-respaldo.curlrc.tmp; mv -f rqlite-respaldo.curlrc.tmp rqlite-respaldo.curlrc || { echo no se pudo colocar el fichero; exit 5; }; echo md5=\$(md5sum < rqlite-respaldo.curlrc | cut -c1-32) perm=ntfs"
GITBASH_DIR='C:\Program Files\Git\usr\bin'

# Comprobacion de que los scripts siguen sin las comillas que los romperian.
case "$R_NODO$R_CHATBOT" in *"'"*) printf 'error interno: comilla simple en un script remoto\n' >&2; exit 2 ;; esac
case "$R_020" in *'"'*|*%*) printf 'error interno: comilla doble o %% en el script de sentinel020\n' >&2; exit 2 ;; esac

CMD_NODO="sh -c '$R_NODO'"
CMD_CHATBOT="sh -c '$R_CHATBOT'"
CMD_020="cd /d \"$GITBASH_DIR\" && .\\bash.exe --noprofile --norc -c \"$R_020\""

# --- ficheros locales ----------------------------------------------------------------
F_SENTINEL="$DIR/sentinel.curlrc"
F_RESPALDO="$DIR/respaldo.curlrc"
F_CHATBOT="$DIR/chatbot.env"

curlrc_valido(){ # $1 fichero  $2 usuario
  [ -r "$1" ] && [ "$(wc -l < "$1" | tr -d ' ')" = 1 ] && grep -Eq "^user = \"$2:[A-Za-z0-9]{32}\"\$" "$1"
}
env_valido(){
  [ -r "$1" ] && [ "$(wc -l < "$1" | tr -d ' ')" = 2 ] && [ "$(sed -n 1p "$1")" = RQLITE_USER=lector ] \
    && sed -n 2p "$1" | grep -Eq '^RQLITE_PASSWORD=[A-Za-z0-9]{32}$'
}
md5_de(){ md5sum < "$1" | cut -c1-32; }

mal=0
curlrc_valido "$F_SENTINEL" sentinel || { printf 'falta o esta mal %s (ejecuta generar-claves.sh)\n' "$F_SENTINEL" >&2; mal=1; }
if elegido sentinel005; then env_valido "$F_CHATBOT" || { printf 'falta o esta mal %s (ejecuta generar-claves.sh)\n' "$F_CHATBOT" >&2; mal=1; }; fi
if elegido sentinel020; then curlrc_valido "$F_RESPALDO" respaldo || { printf 'falta o esta mal %s (ejecuta generar-claves.sh)\n' "$F_RESPALDO" >&2; mal=1; }; fi
[ $mal = 0 ] || exit 2

M_SENTINEL=$(md5_de "$F_SENTINEL")
[ -r "$F_RESPALDO" ] && M_RESPALDO=$(md5_de "$F_RESPALDO") || M_RESPALDO=""
[ -r "$F_CHATBOT" ] && M_CHATBOT=$(LC_ALL=C sort "$F_CHATBOT" | md5sum | cut -c1-32) || M_CHATBOT=""

TIMEOUT=""
command -v timeout >/dev/null 2>&1 && TIMEOUT="timeout $TOPE"

# --- un envio ------------------------------------------------------------------------
# Deja en MOTIVO el porque de un fallo y en SALIDA lo que contesto el equipo.
SALIDA=""; MOTIVO=""
enviar(){ # $1 equipo  $2 comando remoto  $3 fichero local (va por la entrada de ssh)
  # shellcheck disable=SC2086  # SSH_OPC y TIMEOUT se parten a proposito
  SALIDA=$($TIMEOUT ssh $SSH_OPC "$1" "$2" < "$3" 2>&1); rc=$?
  ultima=$(printf '%s\n' "$SALIDA" | sed '/^[[:space:]]*$/d' | tail -n 1)
  case $rc in
    0) MOTIVO=""; return 0 ;;
    124) MOTIVO="sin respuesta en ${TOPE} s" ;;
    255) MOTIVO="inalcanzable por ssh${ultima:+: $ultima}" ;;
    *) MOTIVO="${ultima:-el equipo devolvio el codigo $rc}" ;;
  esac
  return 1
}
dato(){ # $1 clave -> valor de la linea md5=... que devolvio el equipo
  printf '%s\n' "$SALIDA" | sed -n "s/^.*$1=\([^ ]*\).*\$/\1/p" | tail -n 1
}

# --- plan en seco --------------------------------------------------------------------
if [ $SECO = 1 ]; then
  printf 'EN SECO: no se conecta con nadie.\n'
  printf 'Ficheros locales en %s\n' "$DIR"
  printf 'Cada envio: ssh %s <equipo> <comando> < <fichero local>\n\n' "$SSH_OPC"
  printf 'Comando de los nodos: sh -c con este script (sin secretos; la clave entra por la entrada):\n'
  printf '%s\n' "$R_NODO" | sed 's/^/    /'
  if elegido sentinel005; then
    printf '\nComando del .env del chatbot de sentinel005: sh -c con este script:\n'
    printf '%s\n' "$R_CHATBOT" | sed 's/^/    /'
  fi
  if elegido sentinel020; then
    printf '\nComando de sentinel020 (lo interpreta cmd.exe):\n    %s\n' "$CMD_020"
  fi
  printf '\n'
  for n in $ELEGIDOS; do
    case $n in
      sentinel020)
        printf '%-12s respaldo.curlrc -> %s/rqlite-respaldo.curlrc (y comprobar md5)\n' "$n" "$DESTINO_020" ;;
      *)
        printf '%-12s sentinel.curlrc -> ~/.config/rqlite/sentinel.curlrc (y comprobar md5 y 600)\n' "$n"
        if [ $n = sentinel005 ]; then
          printf '%-12s chatbot.env     -> RQLITE_USER y RQLITE_PASSWORD en ~/Herramientas/WhatsApp_Checker/.env\n' "$n"
          printf '%-12s                    (copia .env.bak-%s; el chatbot NO se reinicia)\n' "" "$(date +%Y%m%d)"
        fi ;;
    esac
  done
  printf '\nEn seco: %s equipo(s), nada enviado.\n' "$(printf '%s\n' $ELEGIDOS | wc -l | tr -d ' ')"
  exit 0
fi

# --- reparto de verdad ---------------------------------------------------------------
OKS=""; FALLOS=""; PENDIENTE=""
for n in $ELEGIDOS; do
  case $n in
    sentinel020)
      if ! enviar "$n" "$CMD_020" "$F_RESPALDO"; then
        printf '%-12s FALLO  %s\n' "$n" "$MOTIVO"; FALLOS="$FALLOS $n"; continue
      fi
      if [ "$(dato md5)" != "$M_RESPALDO" ]; then
        printf '%-12s FALLO  el md5 remoto no coincide con el local\n' "$n"; FALLOS="$FALLOS $n"; continue
      fi
      printf '%-12s OK     %s/rqlite-respaldo.curlrc (md5 coincide; permisos de NTFS)\n' "$n" "$DESTINO_020"
      OKS="$OKS $n" ;;
    *)
      if ! enviar "$n" "$CMD_NODO" "$F_SENTINEL"; then
        printf '%-12s FALLO  sentinel.curlrc: %s\n' "$n" "$MOTIVO"; FALLOS="$FALLOS $n"; continue
      fi
      if [ "$(dato md5)" != "$M_SENTINEL" ]; then
        printf '%-12s FALLO  sentinel.curlrc: el md5 remoto no coincide con el local\n' "$n"; FALLOS="$FALLOS $n"; continue
      fi
      if [ "$(dato perm)" != 600 ]; then
        printf '%-12s FALLO  sentinel.curlrc: permisos %s, no 600\n' "$n" "$(dato perm)"; FALLOS="$FALLOS $n"; continue
      fi
      extra=""
      if [ $n = sentinel005 ]; then
        if ! enviar "$n" "$CMD_CHATBOT" "$F_CHATBOT"; then
          printf '%-12s FALLO  sentinel.curlrc OK, pero el .env del chatbot no: %s\n' "$n" "$MOTIVO"; FALLOS="$FALLOS $n"; continue
        fi
        copia=$(printf '%s\n' "$SALIDA" | sed -n 's/^.* copia=//p' | tail -n 1)
        if [ "$(dato lineas)" != 2 ] || [ "$(dato md5)" != "$M_CHATBOT" ]; then
          printf '%-12s FALLO  sentinel.curlrc OK, pero en el .env del chatbot las lineas RQLITE_* no son las esperadas (copia: %s)\n' "$n" "$copia"; FALLOS="$FALLOS $n"; continue
        fi
        if [ "$(dato perm)" != 600 ]; then
          printf '%-12s FALLO  sentinel.curlrc OK, pero el .env del chatbot tiene permisos %s, no 600\n' "$n" "$(dato perm)"; FALLOS="$FALLOS $n"; continue
        fi
        extra="; .env del chatbot con RQLITE_USER y RQLITE_PASSWORD (copia: $copia)"
        PENDIENTE="sentinel005: el chatbot no se ha reiniciado. Falta, a mano: SVDIR=\$PREFIX/var/service sv restart whatsapp_checker"
      fi
      printf '%-12s OK     ~/.config/rqlite/sentinel.curlrc (md5 coincide, 600)%s\n' "$n" "$extra"
      OKS="$OKS $n" ;;
  esac
done

n_ok=$(printf '%s\n' $OKS | sed '/^$/d' | wc -l | tr -d ' ')
n_mal=$(printf '%s\n' $FALLOS | sed '/^$/d' | wc -l | tr -d ' ')
printf '\nResumen: %s OK, %s FALLO%s\n' "$n_ok" "$n_mal" "${FALLOS:+ (${FALLOS# })}"
[ -n "$PENDIENTE" ] && printf '%s\n' "$PENDIENTE"
[ "$n_mal" = 0 ] || exit 1
exit 0
