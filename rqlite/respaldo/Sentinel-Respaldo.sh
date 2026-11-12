#!/usr/bin/bash
# Sentinel - Respaldo diario de la base rqlite (corre en sentinel020, con Git Bash).
#
# POR QUE EXISTE: rqlite replica, no respalda. Un DELETE sin WHERE o un DROP se
# copia a los 11 nodos en un instante, y hasta ahora las unicas copias eran los
# .tar que dejo el cambio de router del 2026-10-04.
#
# POR QUE EN sentinel020: no es nodo del cluster y tiene 300 GB libres. La copia
# se TIRA desde fuera: ningun nodo tiene acceso a estos ficheros, asi que ni un
# script equivocado ni un telefono comprometido pueden borrarlos.
#
# POR QUE ?noleader: la copia sale del disco del propio Linux, no del lider. El
# lider suele ser un telefono, y hacerle comprimir 418 MB es buscar otra tormenta.
# Medido en sentinel014 el 2026-10-30: 9,7 s, load 0,24, ninguna eleccion.
#
# SE CONFIRMA ANTES DE DARLA POR BUENA: gzip, integrity_check y conteos contra la
# copia anterior (ver respaldo-verifica.js). Una copia que no pasa no sustituye a
# nada, y una con la base encogida frena la retencion, para que las copias buenas
# no roten mientras alguien mira que paso.
#
# CREDENCIALES DE rqlite: RQ_CRED (por defecto "$BASE/rqlite-respaldo.curlrc";
# se puede cambiar en .env) es un fichero con UNA linea en formato de curl:
#     user = "respaldo:<clave>"
# El usuario respaldo tiene justo backup y execute: la copia y el INSERT en
# sentinel_respaldo, las dos unicas llamadas a rqlite. Se le pasa a curl.exe con
# -K y la ruta convertida con win(), asi la clave nunca sale en la linea de
# comandos. Solo va a rqlite: ni a Telegram ni a la EC2. Sin fichero se pregunta
# sin credenciales, como siempre (un rqlited sin -auth no las pide). Un 401 tiene
# su propio aviso: no es lo mismo que un nodo caido.
#
# Uso:  Sentinel-Respaldo.sh                 pasada normal (la lanza la tarea)
#       DRY=1 Sentinel-Respaldo.sh           imprime los avisos en vez de enviarlos
#       Sentinel-Respaldo.sh --plan D W M    ensaya la retencion: lee nombres por
#                                            stdin y escribe los que sobrarian

set -u
export PATH=/usr/bin:/mingw64/bin:$PATH
# curl y node son ejecutables nativos de Windows. Sin esto MSYS reescribe cualquier
# argumento que parezca una ruta, incluido el texto de los avisos. Por eso a ellos
# se les pasan las rutas ya convertidas con win().
export MSYS_NO_PATHCONV=1
export NODE_NO_WARNINGS=1

BASE="${RESPALDO_BASE:-/d/RED Respaldo}"
[ -r "$BASE/.env" ] && . "$BASE/.env"

# De donde sale la copia, por orden. Solo los Linux: ver ?noleader arriba.
FUENTES="${FUENTES:-192.168.0.21 192.168.0.159}"
RQ_PUERTO="${RQ_PUERTO:-4001}"
# 154 MB a 3 MB/s son menos de un minuto. Sin limite, los dos extremos van por WiFi
# y la copia se comeria el aire que necesitan los latidos de Raft.
LIMITE_BAJADA="${LIMITE_BAJADA:-3M}"
LIMITE_SUBIDA_KBIT="${LIMITE_SUBIDA_KBIT:-16000}"
RONDAS="${RONDAS:-3}"
ESPERA_RONDA="${ESPERA_RONDA:-120}"
LIBRE_MIN_MB="${LIBRE_MIN_MB:-2048}"
# Retencion: copias diarias, semanales y mensuales que se conservan.
LOCAL_D="${LOCAL_D:-14}"; LOCAL_W="${LOCAL_W:-8}"; LOCAL_M="${LOCAL_M:-12}"
# La EC2 solo tiene 8,7 GB de disco y ademas es un servidor web.
EC2_HOST="${EC2_HOST:-batchtoday}"
EC2_DIR="${EC2_DIR:-respaldos/rqlite}"
EC2_D="${EC2_D:-3}"; EC2_W="${EC2_W:-2}"; EC2_M="${EC2_M:-1}"
EC2_MARGEN_MB="${EC2_MARGEN_MB:-1024}"

DIR="$BASE/rqlite"
TMP="$BASE/tmp"
LOG="$BASE/Log/respaldo.log"
ESTADO="$BASE/estado.txt"
VERIFICA="$BASE/Script/respaldo-verifica.js"
NODE_BIN="${NODE_BIN:-$HOME/node/node.exe}"
[ -x "$NODE_BIN" ] || NODE_BIN=$(command -v node)

win(){ cygpath -m "$1"; }
# Credenciales de rqlite (ver la cabecera): solo si el fichero es legible.
RQ_CRED="${RQ_CRED:-$BASE/rqlite-respaldo.curlrc}"
rqcurl(){ if [ -r "$RQ_CRED" ]; then curl -K "$(win "$RQ_CRED")" "$@"; else curl "$@"; fi; }
anota(){ printf '%s %s\n' "$(date '+%F %T')" "$1" | tee -a "$LOG"; }
ec2(){ ssh -n -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=20 "$EC2_HOST" "$1"; }

avisar(){ # $1 = texto
  if [ "${DRY:-0}" = "1" ]; then printf '[DRY] %s\n' "$1"; return 0; fi
  if [ -z "${TG_BOT_TOKEN:-}" ] || [ -z "${TG_CHAT_ID:-}" ]; then
    anota "sin credenciales de Telegram: no se pudo avisar"
    return 1
  fi
  # curl.exe (mingw, sin "Unicode" en sus Features) recibe argv ya pasado a la pagina
  # de codigos de Windows (1252). Un texto con tildes, "•" o emoji le llegaba a Telegram
  # en bytes que no son UTF-8, y Telegram lo rechazaba con 400 ("strings must be encoded
  # in UTF-8"). Ademas -o /dev/null hacia salir a curl con 23 y nadie se enteraba (visto
  # el 2026-11-11). Por eso el texto va en un fichero (text@fichero: curl lo lee tal
  # cual) y el aviso solo cuenta como enviado con 200 y "ok":true; si no, queda en el log.
  mkdir -p "$TMP" 2>/dev/null
  local f="$TMP/aviso.txt" r cod
  rm -f "$f"
  if command -v iconv >/dev/null 2>&1; then
    # Quita los bytes que no sean UTF-8 (cut -c de Git Bash corta por bytes y puede partir
    # una letra). iconv -c sale con 1 cuando quita algo: no se mira su codigo, sino que el
    # fichero exista.
    printf '%s' "$1" | iconv -f UTF-8 -t UTF-8 -c > "$f" 2>/dev/null
  else
    printf '%s' "$1" > "$f"
  fi
  [ -f "$f" ] || { anota "aviso de Telegram NO enviado: no se pudo escribir $f"; return 1; }
  r=$(curl -sS -m 20 -w '\n%{http_code}' --data-urlencode "chat_id=$TG_CHAT_ID" \
      --data-urlencode "text@$(win "$f")" \
      "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" 2>>"$LOG")
  rm -f "$f"
  cod=${r##*$'\n'}
  if [ "$cod" = "200" ]; then case "$r" in *'"ok":true'*) return 0 ;; esac; fi
  anota "aviso de Telegram NO enviado (http ${cod:-000}): $(printf '%s' "${r%$'\n'*}" | tr -d '\r\n' | cut -c1-200)"
  return 1
}

# Lee nombres por stdin y escribe los que SOBRAN. Se recorren de nuevo a viejo: la
# primera de cada dia, semana ISO o mes es la que cuenta. Un nombre sin sello de
# fecha nunca se escribe, o sea que nunca se borra.
plan_retencion(){ # $1=diarias $2=semanales $3=mensuales
  sort -r | awk -v D="$1" -v W="$2" -v M="$3" '
    match($0, /[0-9]{8}-[0-9]{4}/) {
      f = substr($0, RSTART, 8); y = substr(f, 1, 4); m = substr(f, 5, 2); d = substr(f, 7, 2)
      sem = strftime("%G%V", mktime(y " " m " " d " 12 0 0")); mes = y m
      k = 0
      if (!(f in vd)   && nd < D) { vd[f] = 1;   nd++; k = 1 }
      if (!(sem in vw) && nw < W) { vw[sem] = 1; nw++; k = 1 }
      if (!(mes in vm) && nm < M) { vm[mes] = 1; nm++; k = 1 }
      if (!k) print
    }'
}

if [ "${1:-}" = "--plan" ]; then
  plan_retencion "${2:-$LOCAL_D}" "${3:-$LOCAL_W}" "${4:-$LOCAL_M}"
  exit 0
fi

mkdir -p "$DIR" "$TMP" "$BASE/Log"

# Cerrojo: la tarea lleva IgnoreNew, pero una pasada a mano podria coincidir con
# ella. mkdir es atomico; un cerrojo de mas de 2 h es de una pasada que murio.
LOCK="$BASE/.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  lt=$(stat -c %Y "$LOCK" 2>/dev/null || echo 0)
  if [ "$lt" -gt 0 ] && [ $(( $(date +%s) - lt )) -gt 7200 ]; then
    rmdir "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || exit 0
  else
    anota "hay otra pasada en curso: esta se la cede"; exit 0
  fi
fi
trap 'rm -rf "$TMP"; rmdir "$LOCK" 2>/dev/null' EXIT INT TERM HUP
rm -rf "$TMP"; mkdir -p "$TMP"

NOMBRE="rqlite-$(date +%Y%m%d-%H%M)"
FINAL="$DIR/$NOMBRE.sqlite.gz"
MANIF="$DIR/$NOMBRE.json"
PART="$TMP/copia.gz"
DB="$TMP/copia.sqlite"
PROBLEMAS=""; AVISOS=""; FUENTE=""; BYTES=0; SHA=""; RC_VERIF=1; OFFSITE=0; RECHAZO401=0

problema(){ anota "PROBLEMA: $1"; PROBLEMAS="$PROBLEMAS
  • $1"; }

terminar(){
  ant=$(cat "$ESTADO" 2>/dev/null)
  if [ -n "$PROBLEMAS" ]; then
    avisar "🔴 Respaldo rqlite (sentinel020):$PROBLEMAS"
    printf 'fallo\n' > "$ESTADO"
    [ "$(wc -l < "$LOG")" -gt 2000 ] && tail -n 1000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
    exit 1
  fi
  [ "$ant" = "fallo" ] && avisar "🟢 Respaldo rqlite: la ultima copia salio sin avisos ($NOMBRE)."
  printf 'ok\n' > "$ESTADO"
  [ "$(wc -l < "$LOG")" -gt 2000 ] && tail -n 1000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  exit 0
}

libre=$(df -k --output=avail "$DIR" 2>/dev/null | tail -1 | tr -d ' ')
case "$libre" in ''|*[!0-9]*) libre=0 ;; esac
if [ "$libre" -lt $(( LIBRE_MIN_MB * 1024 )) ]; then
  problema "poco disco en sentinel020: $(( libre / 1024 )) MB libres"
  terminar
fi

# Baja una copia de $1 y la comprueba. Deja $PART y un manifiesto provisional.
bajar(){
  src=$1
  rm -f "$PART" "$DB" "$DB-wal" "$DB-shm" "$TMP/manif.json"
  # Con -f curl sale con 22 ante cualquier error HTTP; -w dice si fue un 401.
  cod=$(rqcurl -sS -f -m 900 --limit-rate "$LIMITE_BAJADA" -w '%{http_code}' -o "$(win "$PART")" \
       "http://$src:$RQ_PUERTO/db/backup?noleader&compress" 2>>"$LOG"); rc=$?
  if [ "$rc" != "0" ]; then
    if [ "$(printf '%s' "$cod" | tr -d '\r ')" = "401" ]; then
      RECHAZO401=1; anota "$src: rqlite rechaza la contraseña del usuario respaldo (401)"
    else
      anota "$src: fallo la descarga"
    fi
    return 1
  fi
  gzip -t "$PART" 2>>"$LOG" || { anota "$src: el gzip no es valido"; return 1; }
  gzip -dc "$PART" > "$DB" 2>>"$LOG" || { anota "$src: no se pudo descomprimir"; return 1; }
  BYTES=$(stat -c %s "$PART")
  SHA=$(sha256sum "$PART" | cut -d' ' -f1)
  previo=$(ls -1 "$DIR"/rqlite-*.json 2>/dev/null | sort | tail -1)
  RESUMEN=$(RESP_FICHERO="$NOMBRE.sqlite.gz" RESP_FUENTE="$src" RESP_BYTES="$BYTES" RESP_SHA="$SHA" \
    "$NODE_BIN" "$(win "$VERIFICA")" "$(win "$DB")" "$(win "$TMP/manif.json")" "${previo:+$(win "$previo")}" 2>&1)
  RC_VERIF=$?
  anota "$src: $RESUMEN"
  rm -f "$DB" "$DB-wal" "$DB-shm"
  [ "$RC_VERIF" = "0" ] || [ "$RC_VERIF" = "2" ] || return 1
  FUENTE=$src
  return 0
}

ronda=1
while [ -z "$FUENTE" ] && [ "$ronda" -le "$RONDAS" ]; do
  for src in $FUENTES; do
    bajar "$src" && break
  done
  if [ -z "$FUENTE" ] && [ "$ronda" -lt "$RONDAS" ]; then sleep "$ESPERA_RONDA"; fi
  ronda=$(( ronda + 1 ))
done
if [ -z "$FUENTE" ]; then
  if [ "$RECHAZO401" = "1" ]; then
    problema "ninguna copia valida tras $RONDAS rondas (fuentes: $FUENTES): rqlite rechaza la contraseña del usuario respaldo (401). Revisar $(win "$RQ_CRED")"
  else
    problema "ninguna copia valida tras $RONDAS rondas (fuentes: $FUENTES)"
  fi
  terminar
fi

mv "$PART" "$FINAL" && mv "$TMP/manif.json" "$MANIF" || { problema "no se pudo guardar $NOMBRE"; terminar; }
anota "guardada $NOMBRE.sqlite.gz ($BYTES bytes, sha256 $(printf '%.8s' "$SHA"))"
if [ "$RC_VERIF" = "2" ]; then
  AVISOS="$RESUMEN"
  problema "copia guardada, pero con avisos: $RESUMEN. No se rota ninguna copia hasta la proxima pasada limpia."
fi

# --- Copia fuera de casa ---------------------------------------------------
subir(){
  ec2 "mkdir -p '$EC2_DIR' && chmod 700 '${EC2_DIR%%/*}'" 2>>"$LOG" || { problema "EC2 inalcanzable"; return 1; }
  rlibre=$(ec2 "df -k --output=avail '$EC2_DIR' | tail -1" 2>>"$LOG" | tr -d ' ')
  case "$rlibre" in ''|*[!0-9]*) rlibre=0 ;; esac
  if [ "$rlibre" -lt $(( BYTES / 1024 + EC2_MARGEN_MB * 1024 )) ]; then
    problema "la EC2 solo tiene $(( rlibre / 1024 )) MB libres: no se sube la copia"
    return 1
  fi
  # Se sube con otro nombre y se renombra tras comparar el hash: un corte a medias
  # no puede dejar algo que parezca una copia.
  if ! scp -q -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=20 -l "$LIMITE_SUBIDA_KBIT" "$FINAL" "$EC2_HOST:$EC2_DIR/.subiendo" 2>>"$LOG"; then
    problema "fallo la subida a la EC2"; return 1
  fi
  rsha=$(ec2 "sha256sum '$EC2_DIR/.subiendo' | cut -d' ' -f1" 2>>"$LOG")
  if [ "$rsha" != "$SHA" ]; then
    problema "el hash de la copia en la EC2 no coincide"
    ec2 "rm -f '$EC2_DIR/.subiendo'" 2>>"$LOG"
    return 1
  fi
  ec2 "mv '$EC2_DIR/.subiendo' '$EC2_DIR/$NOMBRE.sqlite.gz'" 2>>"$LOG" || { problema "no se pudo renombrar en la EC2"; return 1; }
  scp -q -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=20 "$MANIF" "$EC2_HOST:$EC2_DIR/$NOMBRE.json" 2>>"$LOG"
  OFFSITE=1
  anota "subida a $EC2_HOST:$EC2_DIR"
}
subir

# --- Registro: de aqui lee el vigia de sentinel014 ---------------------------
AVISO_SQL=$(printf '%s' "$AVISOS" | tr -d '"\\' | tr '\n\r' '  ' | cut -c1-300)
# El codigo HTTP va en la ultima linea: un 401 llega con el cuerpo vacio.
R=$(rqcurl -sS -m 20 -w '\n%{http_code}' -H 'Content-Type: application/json' \
  -d "[[\"INSERT INTO sentinel_respaldo(ts,fichero,fuente,bytes,sha256,offsite,aviso) VALUES(?,?,?,?,?,?,?)\",$(date +%s),\"$NOMBRE.sqlite.gz\",\"$FUENTE\",$BYTES,\"$SHA\",$OFFSITE,\"$AVISO_SQL\"]]" \
  "http://$FUENTE:$RQ_PUERTO/db/execute" 2>>"$LOG")
COD=$(printf '%s' "$R" | tail -n 1 | tr -d '\r ')
R=$(printf '%s\n' "$R" | sed '$d')
case "$R" in
  *'"rows_affected":1'*) : ;;
  *) if [ "$COD" = "401" ]; then
       problema "copia hecha, pero rqlite rechaza la contraseña del usuario respaldo (401): no quedó registrada y el vigía de sentinel014 avisará de que no hay copia reciente. Revisar $(win "$RQ_CRED")"
     else
       problema "copia hecha, pero no se pudo registrar en rqlite (HTTP ${COD:-?}): $(printf '%s' "$R" | cut -c1-120)"
     fi ;;
esac

# --- Retencion -------------------------------------------------------------
# Se salta si esta copia trae avisos: si la base encogio de verdad, las copias
# viejas son justo las que hacen falta.
if [ "$RC_VERIF" = "0" ]; then
  n=0
  for f in $(ls -1 "$DIR" | grep -E '^rqlite-[0-9]{8}-[0-9]{4}\.sqlite\.gz$' | plan_retencion "$LOCAL_D" "$LOCAL_W" "$LOCAL_M"); do
    rm -f "$DIR/$f" "$DIR/${f%.sqlite.gz}.json"; n=$(( n + 1 ))
  done
  [ "$n" -gt 0 ] && anota "retencion local: $n copias retiradas"
  if [ "$OFFSITE" = "1" ]; then
    n=0
    for f in $(ec2 "ls -1 '$EC2_DIR'" 2>>"$LOG" | grep -E '^rqlite-[0-9]{8}-[0-9]{4}\.sqlite\.gz$' | plan_retencion "$EC2_D" "$EC2_W" "$EC2_M"); do
      ec2 "rm -f '$EC2_DIR/$f' '$EC2_DIR/${f%.sqlite.gz}.json'" 2>>"$LOG"; n=$(( n + 1 ))
    done
    [ "$n" -gt 0 ] && anota "retencion EC2: $n copias retiradas"
  fi
fi

terminar
