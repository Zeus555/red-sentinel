#!/usr/bin/env sh
# Sentinel BTC - velas diarias y semanales de BTC en Coinbase, con Heikin Ashi,
# guardadas en el rqlite de la red. Por defecto, dos series:
#   BIP-20DEC30-CDE  el perpetuo de futuros de BTC de Coinbase en EE. UU. ("nano
#                    BTC Perp", 0,01 BTC por contrato, sin vencimiento hasta
#                    dic-2030). Es la serie para operar, tambien en corto. Su
#                    historia empieza el 18/07/2025 (~70 semanas). El volumen va
#                    en CONTRATOS, no en BTC.
#   BTC-USD          el spot, desde el 20/07/2015. Hace falta para lo que pide
#                    historia larga y el perpetuo no tiene: la EMA 100 y 200
#                    semanal necesitan 100 y 200 semanas.
#
# QUE HACE, en cada pasada y por cada producto (BTC_PRODUCTOS):
#   1. Lee de rqlite las velas diarias que ya hay (tabla cripto_vela, marco 1d).
#   2. Pide a Coinbase lo que falta:
#        - si no hay nada (o con --completo): toda la historia, hacia atras en
#          ventanas de 300 dias hasta dos ventanas vacias seguidas. Para BTC-USD
#          son ~4.100 dias desde el 20/07/2015 en ~16 peticiones; para el
#          perpetuo, ~480 dias en 4;
#        - si ya hay: desde 3 dias antes de la ultima vela cerrada hasta ahora.
#          Esos 3 dias de margen recogen la vela que se guardo a medias (la del
#          dia en curso) y cualquier correccion tardia de Coinbase.
#   3. Junta lo guardado con lo nuevo (lo nuevo manda) y recalcula, SIEMPRE sobre
#      toda la historia, la Heikin Ashi diaria, la vela semanal (lunes 00:00 UTC)
#      y su Heikin Ashi (velas-calculo.awk). La Heikin Ashi es recursiva: un
#      calculo a trozos acumularia error.
#   4. Escribe solo las filas que pueden haber cambiado, en lotes con
#      ?transaction. Una pasada sin novedades reescribe 3-4 dias y 1-2 semanas.
#
# Solo usa el endpoint PUBLICO de velas de Coinbase Advanced Trade: sin claves,
# sin cuenta, sin ordenes. Las peticiones a Coinbase van con `curl -q` para que
# curl NUNCA lea un ~/.curlrc y no se le escape una credencial de rqlite.
#
# Velas "cerradas": una vela diaria esta cerrada cuando ya pasaron sus 24 h; la
# semanal, cuando paso el domingo 23:59:59 UTC. La vela en curso se guarda con
# cerrada=0 y se va actualizando en cada pasada: los indicadores y las rupturas
# deben mirar solo velas cerradas.
#
# Un dia que falte en Coinbase NO se inventa: se anota en el log como hueco y la
# semana que lo contiene queda con dias < 7.
#
# Uso:
#   Sentinel-BTC-Velas.sh              pasada normal (incremental)
#   Sentinel-BTC-Velas.sh --completo   vuelve a bajar y a escribir toda la historia
#   Sentinel-BTC-Velas.sh --seco       calcula pero NO escribe; deja los lotes en
#                                      $BTC_DIR/seco/ para revisarlos
#
# Variables de entorno (todas opcionales):
#   RQLITE        URL de rqlite (por defecto http://127.0.0.1:4001; en un equipo
#                 sin rqlited, la de un nodo, p. ej. http://192.168.0.21:4001)
#   RQLITE_CRED   fichero curlrc del usuario de rqlite (por defecto
#                 ~/.config/rqlite/sentinel.curlrc; necesita execute y query)
#   BTC_PRODUCTOS productos de Coinbase separados por espacio (por defecto
#                 "BIP-20DEC30-CDE BTC-USD"). Cuando el perpetuo cambie de
#                 nombre (vence en dic-2030), se cambia aqui o en sentinel.conf.
#   BTC_DIR       carpeta del log y del cerrojo (por defecto ~/PRC_Sentinel/btc)
#   BTC_MARGEN    segundos tras el fin de una vela para darla por cerrada (60)
#   BTC_NODOS     (en sentinel.conf) unico nodo donde corre; los demas salen
#   CB_API, CB_PAUSA, CB_ESPERA, BTC_LOTE, BTC_AHORA   solo para pruebas
#
# Codigos de salida: 0 bien; 1 fallo de red, de Coinbase o de rqlite (se puede
# reintentar: escribir dos veces la misma vela no cambia nada); 2 datos que no
# cuadran (no se escribio nada de ese producto); 64 uso incorrecto.
set -u
# Punto decimal SIEMPRE: con un locale de coma decimal, awk podria escribir
# "71487,33" y el JSON de la sentencia dejaria de serlo.
LC_ALL=C; export LC_ALL

AQUI=$(cd "$(dirname "$0")" && pwd)
BASE="${SENTINEL_BASE:-$HOME/PRC_Sentinel/v2}"
CONF="$BASE/sentinel.conf"
# sentinel.conf da NAME (nombre del nodo) y puede dar RQLITE. Es opcional: en un
# equipo que no es nodo se usa el nombre de la maquina. Lo que venga por el
# entorno MANDA sobre el fichero: se guarda antes de leerlo. Si no, una prueba o
# una pasada a mano contra otro rqlite acabaria escribiendo en el de la red.
ENV_RQ="${RQLITE:-}"; ENV_CRED="${RQLITE_CRED:-}"
if [ -r "$CONF" ]; then . "$CONF"; fi

RQ="${ENV_RQ:-${RQLITE:-http://127.0.0.1:4001}}"
RQLITE_CRED="${ENV_CRED:-${RQLITE_CRED:-$HOME/.config/rqlite/sentinel.curlrc}}"
CB="${CB_API:-https://api.coinbase.com/api/v3/brokerage/market}"
PRODUCTOS="${BTC_PRODUCTOS:-BIP-20DEC30-CDE BTC-USD}"
PAUSA="${CB_PAUSA:-1}"
DIR="${BTC_DIR:-$HOME/PRC_Sentinel/btc}"
LOTE="${BTC_LOTE:-200}"
AHORA="${BTC_AHORA:-$(date +%s)}"
# Una vela se da por cerrada cuando su fin quedo al menos MARGEN segundos atras.
# Cubre el desfase de reloj entre nodos y que Coinbase tarda unos segundos en
# terminar de agregar la vela tras las 00:00 UTC: una pasada a las 00:00:05 deja
# la de ayer abierta y la cierra la siguiente, con sus valores definitivos.
MARGEN="${BTC_MARGEN:-60}"
UA="sentinel-btc-velas/1.0"
CALC="$AQUI/velas-calculo.awk"
LECTOR="$AQUI/coinbase-velas.awk"
DIA=86400
VENTANA=300          # dias por peticion (Coinbase acepta hasta 350)
MAXV=60              # tope de ventanas hacia atras (~49 años): evita un bucle sin fin
LOG="$DIR/velas.log"

uso(){ awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; }

MODO=incremental; SECO=0
for a in "$@"; do
  case "$a" in
    --completo) MODO=completo ;;
    --seco) SECO=1 ;;
    -h|--help) uso; exit 0 ;;
    *) printf 'opcion desconocida: %s (usa --help)\n' "$a" >&2; exit 64 ;;
  esac
done
case "$AHORA" in ''|*[!0-9]*) printf 'BTC_AHORA no es un numero\n' >&2; exit 64 ;; esac
case "$LOTE" in ''|0|*[!0-9]*) printf 'BTC_LOTE no es un numero positivo\n' >&2; exit 64 ;; esac
case "$MARGEN" in ''|*[!0-9]*) printf 'BTC_MARGEN no es un numero\n' >&2; exit 64 ;; esac
CORTE=$((AHORA - MARGEN))

# Debe correr en UN solo nodo (ver mas abajo, en el cerrojo). Si sentinel.conf
# trae BTC_NODOS (nombres separados por espacios) y este nodo no esta, no hace
# nada. Sin BTC_NODOS corre donde se le llame, como en una pasada a mano.
if [ -n "${BTC_NODOS:-}" ]; then
  case " $BTC_NODOS " in *" ${NAME:-} "*) ;; *) exit 0 ;; esac
fi

# Nombre del equipo que escribe: solo letras, cifras, punto, guion y guion bajo,
# porque va dentro del JSON de la sentencia.
FUENTE=$(printf '%s' "${NAME:-$(hostname 2>/dev/null)}" | tr -cd 'A-Za-z0-9._-')
[ -n "$FUENTE" ] || FUENTE=desconocido

mkdir -p "$DIR" || exit 1
log(){ printf '%s %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG"; printf '%s\n' "$1"; }

# --- Una sola pasada a la vez en este equipo ---------------------------------
# El cerrojo es SOLO local. Dos nodos a la vez no rompen la base (cada lote es una
# transaccion y escribir la misma vela dos veces da lo mismo), pero cerca de las
# 00:00 UTC uno con el reloj algo atrasado puede devolver durante una pasada la
# vela de ayer a cerrada=0. Por eso el cron va en un solo nodo (BTC_NODOS).
# Un cerrojo de mas de 2 h es de una pasada que murio sin limpiar (corte de luz,
# kill -9): se libera.
LOCK="$DIR/.velas.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ ! -d "$LOCK" ]; then
    # No es "otra pasada": no se puede crear (permisos, disco lleno, o hay un
    # FICHERO con ese nombre). Un reintento cubre la carrera con otra pasada que
    # justo acaba de soltar el cerrojo.
    mkdir "$LOCK" 2>/dev/null || { log "ERROR no puedo crear el cerrojo $LOCK (sin permiso, sin espacio o hay un fichero con ese nombre)"; exit 1; }
  elif [ -n "$(find "$LOCK" -maxdepth 0 -mmin +120 2>/dev/null)" ]; then
    rmdir "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || exit 0
  else
    printf 'ya hay otra pasada en curso (%s)\n' "$LOCK"; exit 0
  fi
fi
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/btcvelas.XXXXXX") || { rmdir "$LOCK"; exit 1; }
trap 'rm -rf "$TMPD"; rmdir "$LOCK" 2>/dev/null' EXIT
# PIPE tambien: con `| head` dash muere por SIGPIPE sin pasar por EXIT y el
# cerrojo quedaria puesto 2 h. Se CAPTURA (no se ignora) para que los programas
# que lanza el script sigan con la accion normal de SIGPIPE.
trap 'exit 130' INT TERM HUP PIPE

# --- rqlite --------------------------------------------------------------------
# -q primero: curl no lee ~/.curlrc; las credenciales van SOLO por -K.
rqcurl(){ if [ -r "$RQLITE_CRED" ]; then curl -q -K "$RQLITE_CRED" "$@"; else curl -q "$@"; fi; }
[ -r "$RQLITE_CRED" ] || log "AVISO: no encuentro $RQLITE_CRED; con rqlite protegido por contraseña las peticiones daran 401"

# rq <execute?transaction|query?level=weak> <fichero JSON>  ->  $TMPD/rq.out
# Devuelve 0 solo si rqlite contesto 200 y ninguna sentencia dio error (rqlite
# contesta 200 aunque una sentencia falle: el error va dentro del JSON).
ERRMSG=""
rq(){
  cod=$(rqcurl -s -m 60 -o "$TMPD/rq.out" -w '%{http_code}' -H 'Content-Type: application/json' \
        --data-binary @- "$RQ/db/$1" < "$2" 2>/dev/null) || cod=000
  if [ "$cod" != 200 ]; then ERRMSG="rqlite respondio http $cod"; return 1; fi
  if grep -q '"error"' "$TMPD/rq.out"; then
    ERRMSG="rqlite: $(sed -n 's/.*"error":"\([^"]*\)".*/\1/p' "$TMPD/rq.out" | head -1)"; return 1
  fi
  return 0
}

TABLA='CREATE TABLE IF NOT EXISTS cripto_vela (producto TEXT NOT NULL, marco TEXT NOT NULL, ts INTEGER NOT NULL, apertura REAL NOT NULL, maximo REAL NOT NULL, minimo REAL NOT NULL, cierre REAL NOT NULL, volumen REAL NOT NULL, ha_apertura REAL, ha_maximo REAL, ha_minimo REAL, ha_cierre REAL, cerrada INTEGER NOT NULL, dias INTEGER, fuente TEXT, actualizado INTEGER NOT NULL, PRIMARY KEY (producto, marco, ts)) WITHOUT ROWID'

# Se pregunta antes de crear: un CREATE TABLE IF NOT EXISTS es una escritura de
# Raft que se replicaria a los 11 nodos en cada pasada para nada.
tabla_existe(){
  printf '[["SELECT name FROM sqlite_master WHERE type=? AND name=?","table","cripto_vela"]]' > "$TMPD/q.json"
  rq 'query?level=weak' "$TMPD/q.json" || return 2
  grep -q '"cripto_vela"' "$TMPD/rq.out"
}

# --- Coinbase ------------------------------------------------------------------
# cb_get <url>  ->  $TMPD/cb.out. Tres reintentos con espera creciente.
cb_get(){
  n=0
  while :; do
    cod=$(curl -q -s -m 30 -A "$UA" -o "$TMPD/cb.out" -w '%{http_code}' "$1" 2>/dev/null) || cod=000
    [ "$cod" = 200 ] && return 0
    n=$((n + 1))
    if [ "$n" -ge 4 ]; then ERRMSG="Coinbase respondio http $cod $n veces seguidas"; return 1; fi
    sleep $((n * ${CB_ESPERA:-5}))
  done
}

# baja <producto> <inicio> <fin>  ->  añade velas a $TMPD/nuevas.txt;
# devuelve 0 con velas, 3 si la ventana vino vacia, 1 o 2 si fallo.
baja(){
  cb_get "$CB/products/$1/candles?granularity=ONE_DAY&start=$2&end=$3" || return 1
  if ! awk -f "$LECTOR" "$TMPD/cb.out" > "$TMPD/cb.txt" 2> "$TMPD/cb.err"; then
    ERRMSG="respuesta de Coinbase que no cuadra: $(head -c 300 "$TMPD/cb.err")"; return 2
  fi
  [ -s "$TMPD/cb.txt" ] || return 3
  cat "$TMPD/cb.txt" >> "$TMPD/nuevas.txt"
  return 0
}

# Fecha AAAA-MM-DD de un instante UTC, sin depender de `date -d` (no es POSIX).
FECHA_AWK='function fecha(t,  z,era,doe,yoe,y,doy,mp,d,m){ z=int(t/86400)+719468; era=int(z/146097); doe=z-era*146097; yoe=int((doe-int(doe/1460)+int(doe/36524)-int(doe/146096))/365); y=yoe+era*400; doy=doe-(365*yoe+int(yoe/4)-int(yoe/100)); mp=int((5*doy+2)/153); d=doy-int((153*mp+2)/5)+1; m=(mp<10)?mp+3:mp-9; if(m<=2)y++; return sprintf("%04d-%02d-%02d",y,m,d) }'

# --- Un producto -----------------------------------------------------------------
procesa(){
  P="$1"
  case "$P" in ''|*[!A-Z0-9-]*) log "ERROR producto con caracteres no validos: $P"; return 2 ;; esac
  : > "$TMPD/nuevas.txt"; : > "$TMPD/guardadas.txt"

  # 1. Lo que ya hay en rqlite (con la columna cerrada tal como se guardo).
  if [ "$TABLA_OK" = 1 ] && [ "$MODO" = incremental ]; then
    printf '[["SELECT ts,apertura,maximo,minimo,cierre,volumen,cerrada FROM cripto_vela WHERE producto=? AND marco=? ORDER BY ts","%s","1d"]]' "$P" > "$TMPD/q.json"
    rq 'query?level=weak' "$TMPD/q.json" || { log "ERROR $P: no pude leer las velas guardadas ($ERRMSG)"; return 1; }
    # Solo hay numeros en estas columnas, asi que el primer "]]" cierra "values".
    awk '{ t = t $0 } END { if (t !~ /"values"/) exit 0
           sub(/.*"values":\[\[/, "", t); sub(/\]\].*$/, "", t)
           n = split(t, f, /\],\[/); for (i = 1; i <= n; i++) { gsub(/,/, " ", f[i]); print f[i] } }' \
      "$TMPD/rq.out" > "$TMPD/guardadas.txt"
  fi

  # 2. Lo que falta, de Coinbase.
  if [ -s "$TMPD/guardadas.txt" ]; then
    ULT=$(awk 'END { print $1 + 0 }' "$TMPD/guardadas.txt")      # viene ORDER BY ts
    # Un reloj atrasado mas de un dia reabriria velas ya cerradas (cerrada 1 -> 0)
    # y, muy atrasado, reescribiria media tabla. Mejor no escribir y decirlo.
    if [ $((AHORA + DIA)) -lt "$ULT" ]; then
      log "ERROR $P: el reloj de este equipo ($(echo "$AHORA" | awk "$FECHA_AWK"' { print fecha($1) }')) va por detras de la ultima vela guardada ($(echo "$ULT" | awk "$FECHA_AWK"' { print fecha($1) }')); no escribo nada: revisa la hora (NTP)"
      return 2
    fi
    CERRADO=$(awk -v a="$CORTE" '$1 + 86400 <= a { u = $1 } END { print u + 0 }' "$TMPD/guardadas.txt")
    if [ "$CERRADO" -gt 0 ]; then DESDE=$((CERRADO - 3 * DIA)); else DESDE=$(awk 'NR == 1 { print $1 }' "$TMPD/guardadas.txt"); fi
    ini=$DESDE; k=0
    while [ "$ini" -lt "$AHORA" ] && [ "$k" -lt "$MAXV" ]; do
      fin=$((ini + VENTANA * DIA)); [ "$fin" -gt "$AHORA" ] && fin=$AHORA
      [ "$k" -gt 0 ] && sleep "$PAUSA"
      baja "$P" "$ini" "$fin"; r=$?
      [ "$r" = 1 ] || [ "$r" = 2 ] && { log "ERROR $P: $ERRMSG"; return "$r"; }
      ini=$fin; k=$((k + 1))
    done
    # El ultimo dia guardado tiene que volver a llegar. Si Coinbase manda la lista
    # vacia o cortada, la vela que se guardo a medias pasaria a cerrada=1 con
    # valores incompletos. Se reintenta en la proxima pasada.
    # (Solo si ese dia ya empezo segun este reloj: con otro nodo y un reloj unos
    # segundos atrasado tras las 00:00 UTC, el dia guardado puede ser "manana".)
    if [ "$ULT" -lt "$AHORA" ] && ! awk -v u="$ULT" '$1 == u { e = 1 } END { exit (e ? 0 : 1) }' "$TMPD/nuevas.txt"; then
      log "ERROR $P: Coinbase no devolvio el dia $(echo "$ULT" | awk "$FECHA_AWK"' { print fecha($1) }'), que ya estaba guardado; no escribo nada"
      return 1
    fi
  else
    # Carga completa hacia atras. Se da la historia por terminada con DOS
    # ventanas vacias seguidas: una sola vacia puede ser un fallo puntual de
    # Coinbase, y la historia quedaria recortada para siempre.
    DESDE=0; CERRADO=0; fin=$AHORA; k=0; vacia=0
    while [ "$k" -lt "$MAXV" ]; do
      ini=$((fin - VENTANA * DIA))
      [ "$k" -gt 0 ] && sleep "$PAUSA"
      baja "$P" "$ini" "$fin"; r=$?
      if [ "$r" = 3 ]; then
        [ "$vacia" = 1 ] && break
        vacia=1
      elif [ "$r" = 0 ]; then
        if [ "$vacia" = 1 ]; then log "ERROR $P: Coinbase devolvio una ventana vacia en medio de la historia; no escribo nada"; return 1; fi
      else
        log "ERROR $P: $ERRMSG"; return "$r"
      fi
      fin=$ini; k=$((k + 1))
    done
    if [ ! -s "$TMPD/nuevas.txt" ]; then log "ERROR $P: Coinbase no devolvio ninguna vela"; return 2; fi
  fi

  # 3. Juntar: por cada dia gana lo ultimo bajado. Se cuentan las velas que ya
  #    estaban guardadas como CERRADAS y Coinbase ha cambiado (deberia ser 0; si
  #    no, se avisa). La vela que se guardo abierta y ahora llega terminada no
  #    cuenta: cambiar es lo normal en ella.
  #    Columnas: ts o h l c v origen(0 guardada, 1 nueva) cerrada_guardada
  { awk '{ print $1, $2, $3, $4, $5, $6, 0, $7 + 0 }' "$TMPD/guardadas.txt"
    awk '{ print $1, $2, $3, $4, $5, $6, 1, 0 }' "$TMPD/nuevas.txt"; } \
  | LC_ALL=C sort -k1,1n -k7,7n \
  | CAMBIOS_F="$TMPD/cambios.txt" awk '
      function sale() { if (hay) print lin }
      { k = $1 " " $2 " " $3 " " $4 " " $5 " " $6
        if (hay && $1 == t) {
          if (vieja == 0 && vcerr == 1 && $7 == 1 && (($2-o)^2 + ($3-h)^2 + ($4-l)^2 + ($5-c)^2 + ($6-v)^2 > 0)) n++
        } else sale()
        hay = 1; t = $1; lin = k; vieja = $7; vcerr = $8; o = $2; h = $3; l = $4; c = $5; v = $6 }
      END { sale(); print n + 0 > ENVIRON["CAMBIOS_F"] }' > "$TMPD/serie.txt" \
  || { log "ERROR $P: no pude juntar las velas"; return 1; }
  CAMBIOS=$(cat "$TMPD/cambios.txt" 2>/dev/null || echo 0)

  # 4. Calcular. "Cerrada" se decide con CORTE (ahora menos el margen).
  if ! awk -v producto="$P" -v ahora="$CORTE" -v desde="$DESDE" -v salida=json \
          -v fuente="$FUENTE" -v actualizado="$AHORA" -f "$CALC" "$TMPD/serie.txt" \
          > "$TMPD/sentencias.txt" 2> "$TMPD/calc.err"; then
    log "ERROR $P: el calculo rechazo la serie: $(grep ERROR "$TMPD/calc.err" | head -1)"; return 2
  fi
  RES=$(grep '^RESUMEN' "$TMPD/calc.err")
  HUECOS=$(grep -c '^HUECO' "$TMPD/calc.err")

  # 5. Escribir en lotes. La carpeta va por ENVIRON y no por -v: -v interpreta
  #    las barras invertidas, y en Windows TMPDIR puede ser C:\Users\...
  rm -f "$TMPD"/lote.*.json
  LOTES="$TMPD" awk -v lote="$LOTE" '
      (NR - 1) % lote == 0 { if (f) { print "]" > f; close(f) }; n++; f = sprintf("%s/lote.%05d.json", ENVIRON["LOTES"], n); printf "[" > f; sep = "" }
      { printf "%s%s", sep, $0 > f; sep = "," }
      END { if (f) { print "]" > f; close(f) } }' "$TMPD/sentencias.txt" \
  || { log "ERROR $P: no pude preparar los lotes en $TMPD"; return 1; }
  ESCRITAS=$(wc -l < "$TMPD/sentencias.txt" | tr -d ' ')
  if [ "$ESCRITAS" -gt 0 ] && [ ! -e "$TMPD/lote.00001.json" ]; then
    log "ERROR $P: hay $ESCRITAS sentencias pero ningun lote"; return 1
  fi
  if [ "$SECO" = 1 ]; then
    mkdir -p "$DIR/seco"; rm -f "$DIR/seco/$P".*.json
    for f in "$TMPD"/lote.*.json; do [ -e "$f" ] && cp "$f" "$DIR/seco/$P.${f##*/lote.}"; done
  else
    for f in "$TMPD"/lote.*.json; do
      [ -e "$f" ] || continue
      rq 'execute?transaction' "$f" || { log "ERROR $P: fallo al escribir ${f##*/} ($ERRMSG); lo que ya entro es valido y la proxima pasada completa el resto"; return 1; }
    done
  fi

  # 6. Resumen legible.
  printf '%s\n' "$RES" | awk -v escritas="$ESCRITAS" -v huecos="$HUECOS" -v cambios="$CAMBIOS" \
      -v modo="$MODO" -v seco="$SECO" -v ahora="$CORTE" "$FECHA_AWK"'
    { for (i = 2; i <= NF; i++) { split($i, kv, "="); r[kv[1]] = kv[2] } }
    END {
      abierta = (r["ultima"] + 86400 > ahora) ? " (vela de hoy, aun abierta)" : ""
      printf "%s: %d velas diarias (%s a %s) y %d semanales; %d dias faltantes en %d tramos; %d velas cerradas corregidas por Coinbase; %d filas %s (modo %s); ultimo cierre %s%s\n", \
        r["producto"], r["diarias"], fecha(r["primera"]), fecha(r["ultima"]), r["semanales"], r["huecos"], r["tramos"], \
        cambios, escritas, (seco ? "calculadas sin escribir" : "escritas"), modo, r["cierre"], abierta
    }' > "$TMPD/linea.txt"
  log "$(cat "$TMPD/linea.txt")"
  [ "$HUECOS" -gt 0 ] && log "  huecos de $P: $(grep '^HUECO' "$TMPD/calc.err" | awk "$FECHA_AWK"' { printf "%s%s..%s", (NR > 1 ? ", " : ""), fecha($2), fecha($3) }' | head -c 400)"
  [ "$CAMBIOS" -gt 0 ] && log "  AVISO $P: Coinbase cambio $CAMBIOS velas que ya estaban cerradas; quedaron sobrescritas"
  return 0
}

# --- Principal ---------------------------------------------------------------
TABLA_OK=0
tabla_existe; r=$?
if [ "$r" = 0 ]; then
  TABLA_OK=1
elif [ "$r" = 2 ]; then
  log "ERROR no puedo consultar rqlite en $RQ ($ERRMSG)"; exit 1
elif [ "$SECO" = 0 ]; then
  printf '[["%s"]]' "$TABLA" > "$TMPD/t.json"
  rq 'execute' "$TMPD/t.json" || { log "ERROR no pude crear la tabla cripto_vela ($ERRMSG)"; exit 1; }
  log "creada la tabla cripto_vela en rqlite"
  TABLA_OK=1
fi

final=0
for P in $PRODUCTOS; do
  procesa "$P"; r=$?
  [ "$r" -gt "$final" ] && final=$r
done

# El log es un diario: con las ultimas 1000 lineas sobra.
tail -n 1000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
exit "$final"
