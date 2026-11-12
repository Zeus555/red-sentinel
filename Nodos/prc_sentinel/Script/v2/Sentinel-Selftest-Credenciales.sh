#!/bin/sh
# Sentinel v2 - Banco de pruebas de las credenciales de rqlite en los scripts que
# escriben en la base (bateria, thermal-guard, retencion, respaldo, cripto) y en
# Sentinel-Roam.sh, que NO debe mandarlas.
#
# No toca la red: pone delante un `curl` falso que apunta cada llamada (URL, la
# ruta que llega por -K y el usuario de ese fichero, nunca la clave) y contesta
# desde un "mundo" de ficheros: que rqlite contesta, cual da 401, cual esta caido.
# Tambien hay falsos de termux-battery-status, hostname, ps, sleep, sv, pkill,
# sudo... y un `date` que corre solo, para que los bucles de cripto acaben ya.
#
# Comprueba:
#   (a) con fichero de credenciales, cada peticion a rqlite lleva -K <ruta> (del
#       usuario que toca) y ninguna otra (Telegram, Jupiter, Coinbase) lo lleva;
#   (b) la clave inventada no aparece nunca en argv ni en ningun fichero que dejen
#       los scripts (logs, estados, avisos), y nadie usa -u ni user:clave@;
#   (c) sin fichero, ninguna peticion lleva -K: todo como antes;
#   (d) Sentinel-Roam.sh nunca lleva -K, aunque el fichero exista;
# y que un 401 se distingue de "caido" donde el script decide algo.
#
# Uso:  sh Sentinel-Selftest-Credenciales.sh   (desde Wheel/Script/v2 o su espejo)
# Prueba los scripts con cada shell que encuentre (dash, que es el sh de Ubuntu y
# Termux, y sh); SELFTEST_SHELLS="dash" lo limita. Sentinel-Respaldo.sh es bash y
# se prueba con bash; donde no hay cygpath (fuera de Windows) se finge. Sale con 0
# si todo pasa. SELFTEST_VERBOSE=1 ensena las llamadas de cada prueba que falla.
set -u
unset RQLITE RQLITE_CRED RQLITE_FALLBACK RQ_CRED ROAM_SEED 2>/dev/null
V2=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d 2>/dev/null || { d="/tmp/selftest-cred.$$"; mkdir -p "$d"; echo "$d"; })
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
no(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"
  if [ "${SELFTEST_VERBOSE:-0}" = "1" ]; then
    sed 's/^/      llamada: /' "$M/llamadas" 2>/dev/null; sed 's/^/      salida: /' "$M/salida" 2>/dev/null
  fi; }
si(){ if eval "$2"; then ok "$1"; else no "$1"; fi; }
salta(){ echo "  SKIP: $1"; }

# Clave inventada, con el formato de las de verdad (32 alfanumericos).
CLAVE="InventadaParaElBanco0123456789AB"

# --- Donde estan los scripts --------------------------------------------------
# Los de v2 estan aqui; thermal-guard y el respaldo, en el repo (subiendo hasta
# encontrar Nodos/prc_thermal). En un nodo el vigia vive junto a este banco.
RAIZ=""; d="$V2"
while [ -n "$d" ] && [ "$d" != "/" ] && [ "$d" != "." ]; do
  if [ -f "$d/Nodos/prc_thermal/thermal-guard.sh" ]; then RAIZ="$d"; break; fi
  d=$(dirname "$d")
done
busca(){ for f; do [ -f "$f" ] && { printf '%s' "$f"; return 0; }; done; return 1; }
BAT="$V2/Sentinel-Bateria.sh"; ROAM="$V2/Sentinel-Roam.sh"
CRIPTO="$V2/Sentinel-Cripto.sh"; LIBRO="$V2/Sentinel-Libro.sh"; PROF="$V2/Sentinel-Profundidad.sh"
TGT=$(busca "$RAIZ/Nodos/prc_thermal/thermal-guard.sh") || TGT=""
TGL=$(busca "$RAIZ/Nodos/prc_thermal/thermal-guard-linux.sh") || TGL=""
RET=$(busca "$RAIZ/Nodos/prc_thermal/retention.sh") || RET=""
VIG=$(busca "$RAIZ/rqlite/respaldo/Sentinel-RespaldoVigia.sh" "$V2/Sentinel-RespaldoVigia.sh") || VIG=""
RESP=$(busca "$RAIZ/rqlite/respaldo/Sentinel-Respaldo.sh") || RESP=""

M="$T/mundo"; B="$T/base"; H="$T/home"; BIN="$T/bin"; BINR="$T/bin-reloj"
mkdir -p "$BIN" "$BINR" "$T/sv"
: > "$T/argv-todo"; : > "$T/fugas"

# ---------------------------------------------------------------- curl falso
cat > "$BIN/curl" <<'EOF'
#!/bin/sh
# Apunta la llamada y contesta desde $MUNDO. Nunca escribe la clave: del fichero
# de -K solo saca el usuario.
M="$MUNDO"; url=""; w=""; o=""; k=""; data=""; q=""; text=""; f=0
printf '%s ' "$@" >> "$ARGV_TODO"; printf '\n' >> "$ARGV_TODO"
while [ $# -gt 0 ]; do
  case "$1" in
    -K|--config) shift; k="$1" ;;
    -w|--write-out) shift; w="$1" ;;
    -o|--output) shift; o="$1" ;;
    -d|--data|--data-raw|--data-binary) shift; data="$1" ;;
    --data-urlencode) shift; case "$1" in q=*) q="${1#q=}" ;; text=*) text="${1#text=}" ;; text@*) text=$(cat "${1#text@}") ;; esac ;;
    -u|--user|-u*) echo "credenciales en argv (-u/--user)" >> "$M/prohibido"; [ "$1" = "-u" ] || [ "$1" = "--user" ] && shift ;;
    -m|--max-time|--connect-timeout|-H|--header|--limit-rate|-X|--request|-A|-e) shift ;;
    --fail) f=1 ;;
    --*) ;;
    -*f*) f=1 ;;
    -*) ;;
    *) url="$1" ;;
  esac
  shift
done
case "$url" in *://*:*@*) echo "credenciales en la URL: usuario:clave@" >> "$M/prohibido" ;; esac
ku="-"
if [ -n "$k" ]; then
  if [ -r "$k" ]; then
    ku=$(sed -n 's/^[[:space:]]*user[[:space:]]*=[[:space:]]*"\([^:"]*\):.*$/\1/p' "$k" | head -1)
    [ -n "$ku" ] || ku="?"
  else
    ku="ilegible"
  fi
fi
printf '%s\t%s\t%s\n' "$url" "${k:--}" "$ku" >> "$M/llamadas"

host=${url#*://}; host=${host%%/*}; host=${host%%:*}
ep=""
case "$url" in */db/execute*) ep=execute ;; */db/query*) ep=query ;; */db/backup*) ep=backup ;; */status*) ep=status ;; */readyz*) ep=readyz ;; esac
code=200; body=""; rc=0
case "$url" in
  http://*:4001/*)
    if [ -f "$M/caido.$host" ]; then code=000; rc=7
    elif [ -f "$M/401.$host" ] || [ -f "$M/401.$host.$ep" ]; then code=401   # cuerpo vacio, como rqlited -auth
    else
      case "$ep" in
        status) body='{"store":{"ready":true}}' ;;
        readyz) body='[+]node ok' ;;
        execute) printf '%s\n' "$data" >> "$M/execute.log"; body='{"results":[{"last_insert_id":1,"rows_affected":1}]}' ;;
        query)
          case "$q" in
            *sentinel_respaldo*)
              if [ -f "$M/ultimo_respaldo" ]; then body="{\"results\":[{\"columns\":[\"MAX(ts)\"],\"types\":[\"\"],\"values\":[[$(cat "$M/ultimo_respaldo")]]}]}"
              else body='{"results":[{"columns":["MAX(ts)"],"types":[""],"values":[[null]]}]}'; fi ;;
            *) body='{"results":[{}]}' ;;
          esac ;;
        backup) body="__gzip__" ;;
        *) code=404 ;;
      esac
    fi ;;
  https://api.telegram.org/*) printf '%s\n----\n' "$text" >> "$M/telegram.log"
    if [ -f "$M/tg400" ]; then code=400; body='{"ok":false,"error_code":400,"description":"Bad Request: strings must be encoded in UTF-8"}'
    else body='{"ok":true}'; fi ;;
  http://*:3011/price*) body='{"asset":"WBTC","price":"$65000.12","ageMs":120}' ;;
  https://batchtoday.us/price/*) body='{"name":"BTC-USD","ask":"78201.02","ask_size":"0.5","ask_numorders":3,"bid":"78200.01","bid_size":"0.6","bid_numorders":2,"dateupdate":"2026-11-11T10:00:00.123456789Z"}' ;;
  https://api.coinbase.com/*) body='{"pricebook":{"product_id":"BTC-USD","bids":[{"price":"78200.00","size":"10"}],"asks":[{"price":"78201.00","size":"10"}],"time":"2026-11-11T10:00:00.123Z"}}' ;;
  *) code=000; rc=7 ;;
esac
# Como el de verdad: con -f un error HTTP sale con 22 y sin escribir el cuerpo.
if [ "$rc" = "0" ] && [ "$f" = "1" ] && [ "$code" -ge 400 ]; then rc=22; fi
if [ "$rc" = "0" ]; then
  if [ "$body" = "__gzip__" ]; then
    [ -n "$o" ] && printf 'copia falsa de rqlite\n' | gzip -c > "$o"
  elif [ -n "$o" ]; then
    [ "$o" = "/dev/null" ] || printf '%s' "$body" > "$o"
  else
    printf '%s' "$body"
  fi
fi
[ -n "$w" ] && printf '%b' "$(printf '%s' "$w" | sed "s/%{http_code}/$code/g")"
exit "$rc"
EOF

cat > "$BIN/termux-battery-status" <<'EOF'
#!/bin/sh
t=$(cat "$MUNDO/temp" 2>/dev/null || echo 30.5)
printf '{\n  "health": "GOOD",\n  "percentage": 80,\n  "plugged": "PLUGGED_AC",\n  "status": "CHARGING",\n  "temperature": %s,\n  "current": -1000,\n  "current_average": -1200,\n  "charge_counter": 3000000\n}\n' "$t"
EOF
printf '#!/bin/sh\necho sentinelT\n' > "$BIN/hostname"
printf '#!/bin/sh\necho "u0_a1 4242 1 0 10:00 ? 00:00:01 rqlited -node-id nodoT -http-addr 0.0.0.0:4001 /data/rq"\n' > "$BIN/ps"
printf '#!/bin/sh\nexit 0\n' > "$BIN/sleep"
# Lo que podria apagar o parar algo solo se apunta. sudo dice que no.
for c in sv pkill termux-wake-lock termux-wake-unlock systemctl shutdown; do
  printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >> "$MUNDO/acciones"\nexit 0\n' "$c" > "$BIN/$c"
done
printf '#!/bin/sh\nprintf "sudo %%s\\n" "$*" >> "$MUNDO/acciones"\nexit 1\n' > "$BIN/sudo"
# node falso para el respaldo: da la copia por verificada y deja el manifiesto.
printf '#!/bin/sh\nprintf "{}\\n" > "$3"\necho "verificada (falso)"\nexit 0\n' > "$BIN/node-falso"
# date que avanza 5 s en cada `date +%%s`; lo demas, al de verdad.
REALDATE=$(command -v date)
cat > "$BINR/date" <<EOF
#!/bin/sh
if [ "\${1:-}" = "+%s" ]; then
  n=\$(cat "\$MUNDO/reloj" 2>/dev/null || echo 1794000000)
  echo \$((n + 5)) > "\$MUNDO/reloj"
  echo "\$n"; exit 0
fi
exec "$REALDATE" "\$@"
EOF
chmod +x "$BIN"/* "$BINR"/*

# ---------------------------------------------------------------- mundo
CRED_DEF="$H/.config/rqlite/sentinel.curlrc"
cred(){ mkdir -p "$(dirname "$1")"; printf 'user = "%s:%s"\n' "$2" "$CLAVE" > "$1"; chmod 600 "$1" 2>/dev/null; return 0; }
conf(){ printf 'NAME=sentinelT\nPORT=8181\nRQLITE=http://127.0.0.1:4001\n%s\n' "${1:-}" > "$B/sentinel.conf"; }
mundo(){ # mundo con|sin [linea extra de sentinel.conf]
  rm -rf "$M" "$B" "$H"; mkdir -p "$M" "$B" "$H/PRC_Thermal"
  printf 'BOT_TOKEN="x"\nCHAT_ID="1"\n' > "$H/PRC_Thermal/thermal-guard.conf"
  conf "${2:-}"
  [ "$1" = "con" ] && cred "$CRED_DEF" sentinel
  : > "$M/llamadas"; : > "$M/salida"
}
# Busca la clave en todo lo que hay en el banco salvo los propios ficheros de
# credenciales (*.curlrc). Se llama tras cada pasada: los mundos se borran.
fugas(){ grep -rlF -- "$CLAVE" "$T" 2>/dev/null | grep -v '\.curlrc$' >> "$T/fugas"; return 0; }
corre(){ # corre <script> [VAR=valor ...]: lo lanza con $SHX en el mundo actual
  scr=$1; shift
  ( cd "$T" && env PATH="$BIN:$PATH" MUNDO="$M" ARGV_TODO="$T/argv-todo" HOME="$H" SENTINEL_BASE="$B" \
      SENTINEL_NOJITTER=1 SVDIR="$T/sv" "$@" "$SHX" "$scr" > "$M/salida" 2>&1 )
  fugas
}

# con_cred <ruta> <usuario>: toda llamada a rqlite (puerto 4001) lleva -K <ruta>
# con ese usuario, y ninguna otra lleva -K. Tiene que haber al menos una a rqlite.
con_cred(){ awk -F'\t' -v k="$1" -v u="$2" '
  { if ($1 ~ /^https?:\/\/[^\/]*:4001\//) { nrq++; if ($2 != k || $3 != u) mal++ } else if ($2 != "-") mal++ }
  END { exit !(nrq > 0 && mal == 0) }' "$M/llamadas"; }
# sin_cred: hubo llamadas y ninguna lleva -K.
sin_cred(){ awk -F'\t' '{ n++; if ($2 != "-") mal++ } END { exit !(n > 0 && mal == 0) }' "$M/llamadas"; }
# hay_tg: hubo al menos un mensaje a Telegram (para que "Telegram sin -K" diga algo).
hay_tg(){ grep -q '^https://api\.telegram\.org/' "$M/llamadas"; }
# llamadas_a <patron>: cuantas llamadas a URLs que empiezan por el patron.
llamadas_a(){ awk -F'\t' -v p="$1" 'index($1, p) == 1 { n++ } END { print n + 0 }' "$M/llamadas"; }
ejecuta(){ grep -qF -- "$1" "$M/execute.log" 2>/dev/null; }
tg(){ grep -qF -- "$1" "$M/telegram.log" 2>/dev/null; }
limpio(){ [ ! -s "$M/prohibido" ]; }

# ---------------------------------------------------------------- shells
SHELLS=""; vistos=" "
for s in ${SELFTEST_SHELLS:-dash sh}; do
  p=$(command -v "$s" 2>/dev/null) || continue
  r=$(readlink -f "$p" 2>/dev/null || printf '%s' "$p")
  case "$vistos" in *" $r "*) continue ;; esac
  vistos="$vistos$r "; SHELLS="$SHELLS $p"
done
[ -n "$SHELLS" ] || { echo "no encuentro ni dash ni sh"; exit 1; }

for SHX in $SHELLS; do
echo "== Bateria (con $SHX)"
mundo con; corre "$BAT"
si "B1 con fichero: todo lo de rqlite lleva -K del usuario sentinel" 'con_cred "$CRED_DEF" sentinel && limpio'
si "B1 y la fila llega" 'ejecuta "INSERT INTO sentinel_bateria"'
mundo sin; corre "$BAT"
si "B2 sin fichero: nadie lleva -K y la fila llega igual" 'sin_cred && ejecuta "INSERT INTO sentinel_bateria"'
mundo con "RQLITE_FALLBACK=http://10.9.0.1:4001"; : > "$M/caido.127.0.0.1"; corre "$BAT"
si "B3 rqlite local caido: la sonda y el fallback por la malla llevan -K" 'con_cred "$CRED_DEF" sentinel && [ "$(llamadas_a "http://127.0.0.1:4001/status")" = 1 ] && [ "$(llamadas_a "http://10.9.0.1:4001/db/execute")" -ge 3 ] && ejecuta "INSERT INTO sentinel_bateria"'
mundo con "RQLITE_FALLBACK=http://10.9.0.1:4001"; : > "$M/401.127.0.0.1"; corre "$BAT"
si "B4 rqlite local con 401: cuenta como vivo, no se va al fallback" '[ "$(llamadas_a "http://10.9.0.1")" = 0 ] && [ "$(llamadas_a "http://127.0.0.1:4001/db/execute")" -ge 3 ] && con_cred "$CRED_DEF" sentinel'
mundo sin "RQLITE_CRED=$H/otra/bateria.curlrc"; cred "$H/otra/bateria.curlrc" sentinel; corre "$BAT"
si "B5 RQLITE_CRED en sentinel.conf manda" 'con_cred "$H/otra/bateria.curlrc" sentinel'
mundo con "RQLITE_CRED="; corre "$BAT"
si "B6 RQLITE_CRED vacio: ruta por defecto" 'con_cred "$CRED_DEF" sentinel'

echo "== thermal-guard Termux (con $SHX)"
if [ -n "$TGT" ]; then
  mundo con; echo 46.3 > "$M/temp"; corre "$TGT"
  si "T1 con fichero: los dos INSERT llevan -K y Telegram no" 'con_cred "$CRED_DEF" sentinel && hay_tg && limpio'
  si "T1 llegan temperatura y disco" 'ejecuta "INSERT INTO sentinel_temp" && ejecuta "INSERT INTO sentinel_disk" && ejecuta "\"nodoT\""'
  si "T1 WARN no toca servicios" '[ ! -s "$M/acciones" ]'
  mundo sin; echo 46.3 > "$M/temp"; corre "$TGT"
  si "T2 sin fichero: nadie lleva -K" 'sin_cred && hay_tg && ejecuta "INSERT INTO sentinel_temp"'
  mundo sin; echo 30 > "$M/temp"; cred "$H/otra/tg.curlrc" sentinel
  printf 'BOT_TOKEN="x"\nCHAT_ID="1"\nRQLITE=http://10.0.0.7:4001\nRQLITE_CRED=%s\n' "$H/otra/tg.curlrc" > "$H/PRC_Thermal/thermal-guard.conf"; corre "$TGT"
  si "T3 RQLITE y RQLITE_CRED desde thermal-guard.conf" 'con_cred "$H/otra/tg.curlrc" sentinel && [ "$(llamadas_a "http://10.0.0.7:4001/db/execute")" = 2 ]'
  # La ruta se calcula DESPUES de leer la conf: un RQLITE_CRED vacio en ella no
  # puede dejar al nodo sin credenciales.
  mundo con; echo 30 > "$M/temp"; printf 'BOT_TOKEN="x"\nCHAT_ID="1"\nRQLITE_CRED=\n' > "$H/PRC_Thermal/thermal-guard.conf"; corre "$TGT"
  si "T4 RQLITE_CRED vacio en thermal-guard.conf: ruta por defecto" 'con_cred "$CRED_DEF" sentinel'
else salta "no encuentro Nodos/prc_thermal/thermal-guard.sh"; fi

echo "== thermal-guard Linux (con $SHX)"
# Lee /sys y en CRIT/EMERG llama a sudo. Se prueba una copia que lee la temperatura
# de un /sys de mentira; el resto es el fichero tal cual (se comprueba que solo
# cambian esas dos lineas). A 80 C es WARN: aviso, sin sudo.
case "$T" in *" "*|*"#"*) TGL_OK=0 ;; *) TGL_OK=1 ;; esac
if [ -n "$TGL" ] && [ "$TGL_OK" = 1 ]; then
  sed "s#/sys/class/#$T/sys/class/#g" "$TGL" > "$T/tgl.sh"
  mkdir -p "$T/sys/class/hwmon/hwmon0"; echo coretemp > "$T/sys/class/hwmon/hwmon0/name"; echo 80000 > "$T/sys/class/hwmon/hwmon0/temp1_input"
  si "L0 la copia solo cambia las dos lecturas de /sys" '[ "$(diff "$TGL" "$T/tgl.sh" | grep -c "^>")" = 2 ]'
  mundo con; corre "$T/tgl.sh"
  si "L1 con fichero: los dos INSERT llevan -K y Telegram no" 'con_cred "$CRED_DEF" sentinel && hay_tg && limpio'
  si "L1 llegan temperatura (coretemp) y disco, sin sudo" 'ejecuta "\"coretemp\",\"WARN\"" && ejecuta "INSERT INTO sentinel_disk" && ! grep -q sudo "$M/acciones" 2>/dev/null'
  mundo sin; corre "$T/tgl.sh"
  si "L2 sin fichero: nadie lleva -K" 'sin_cred && hay_tg && ejecuta "INSERT INTO sentinel_temp"'
else salta "thermal-guard-linux.sh (no esta o la ruta temporal tiene espacios)"; fi

echo "== Retencion de sentinel001 (con $SHX)"
if [ -n "$RET" ]; then
  mundo con; corre "$RET"
  si "R1 con fichero: un solo DELETE de 90 dias a localhost, con -K" 'con_cred "$CRED_DEF" sentinel && [ $(wc -l < "$M/llamadas") -eq 1 ] && [ "$(llamadas_a "http://localhost:4001/db/execute")" = 1 ] && [ $(grep -o -- "-90 days" "$M/execute.log" | wc -l) -eq 2 ] && ejecuta "DELETE FROM sentinel_temp" && ejecuta "DELETE FROM sentinel_disk"'
  mundo sin; corre "$RET"
  si "R2 sin fichero: igual que antes, sin -K" 'sin_cred && [ "$(llamadas_a "http://localhost:4001/db/execute")" = 1 ]'
  mundo sin; cred "$H/otra/ret.curlrc" sentinel
  printf 'BOT_TOKEN="x"\nRQLITE=http://10.0.0.7:4001\nRQLITE_CRED=%s\n' "$H/otra/ret.curlrc" > "$H/PRC_Thermal/thermal-guard.conf"; corre "$RET"
  si "R3 RQLITE y RQLITE_CRED desde thermal-guard.conf" 'con_cred "$H/otra/ret.curlrc" sentinel && [ "$(llamadas_a "http://10.0.0.7:4001/db/execute")" = 1 ]'
  mundo con; printf 'BOT_TOKEN="x"\nRQLITE_CRED=\n' > "$H/PRC_Thermal/thermal-guard.conf"; corre "$RET"
  si "R4 RQLITE_CRED vacio en thermal-guard.conf: ruta por defecto" 'con_cred "$CRED_DEF" sentinel'
else salta "no encuentro Nodos/prc_thermal/retention.sh"; fi

echo "== Vigia del respaldo (con $SHX)"
if [ -n "$VIG" ]; then
  mundo con; echo $(( $(date +%s) - 3600 )) > "$M/ultimo_respaldo"; corre "$VIG"
  si "V1 copia reciente: lectura con -K y ningun aviso" 'con_cred "$CRED_DEF" sentinel && ! hay_tg && [ "$(cut -d" " -f1 "$B/respaldo-vigia.state")" = ok ]'
  mundo con; echo $(( $(date +%s) - 40 * 3600 )) > "$M/ultimo_respaldo"; corre "$VIG"
  si "V2 copia vieja: avisa, Telegram sin -K" 'con_cred "$CRED_DEF" sentinel && hay_tg && tg "el ultimo respaldo es de hace 40 h" && limpio'
  mundo con; : > "$M/401.127.0.0.1"; corre "$VIG"
  si "V3 401: dice que rqlite rechaza la contraseña, no que no pudo leer" 'tg "rqlite rechaza la contraseña de sentinel (401)" && ! tg "no se pudo leer la fecha" && ! tg "Revisar la tarea"'
  mundo con; : > "$M/caido.127.0.0.1"; corre "$VIG"
  si "V4 rqlited caido: sigue diciendo que no pudo leer la fecha" 'tg "no se pudo leer la fecha" && ! tg "(401)"'
  mundo sin; echo $(( $(date +%s) - 40 * 3600 )) > "$M/ultimo_respaldo"; corre "$VIG"
  si "V5 sin fichero: nadie lleva -K" 'sin_cred && hay_tg'
else salta "no encuentro Sentinel-RespaldoVigia.sh"; fi

echo "== Cripto, Libro y Profundidad, pausados (con $SHX)"
for par in "$CRIPTO|cripto_precio|http://192.168.1.91:3011/price" "$LIBRO|cripto_libro|https://batchtoday.us/price/" "$PROF|cripto_profundidad|https://api.coinbase.com/"; do
  scr=${par%%|*}; r=${par#*|}; tabla=${r%%|*}; fuente=${r#*|}; nom=$(basename "$scr" .sh)
  mundo con; printf 'sentinelT\n' > "$B/wheel.state"; corre "$scr" PATH="$BINR:$BIN:$PATH"
  si "K1 $nom con fichero: rqlite con -K, la fuente de precios sin el" 'con_cred "$CRED_DEF" sentinel && [ "$(llamadas_a "$fuente")" -ge 1 ] && limpio'
  if [ "$tabla" != "cripto_profundidad" ] || command -v gawk >/dev/null 2>&1; then
    si "K1 $nom guarda sus filas" 'ejecuta "INSERT OR IGNORE INTO $tabla"'
  fi
  mundo sin; printf 'sentinelT\n' > "$B/wheel.state"; corre "$scr" PATH="$BINR:$BIN:$PATH"
  si "K2 $nom sin fichero: nadie lleva -K" 'sin_cred'
done

echo "== Roam: nunca credenciales (con $SHX)"
mundo con "ROAM_SEED=10.0.0.5"; : > "$M/caido.10.0.0.5"; corre "$ROAM"
si "M1 fuera de casa, con fichero: los dos intentos sin -K" 'sin_cred && [ "$(llamadas_a "http://10.0.0.5:4001/readyz?noleader")" = 2 ] && [ "$(cat "$B/roam.state")" = "fuera|fuera|1" ]'
mundo con "ROAM_SEED=10.0.0.5"; : > "$M/401.10.0.0.5"; corre "$ROAM"
si "M2 la semilla contesta 401: eso ya es estar en casa, y sin -K" 'sin_cred && [ "$(llamadas_a "http://10.0.0.5:4001/readyz?noleader")" = 1 ] && [ "$(cat "$B/roam.state")" = "casa|casa|1" ]'
mundo con "ROAM_SEED=10.0.0.5"; corre "$ROAM"
si "M4 pregunta a /readyz?noleader (\"*\" tiene ready: no suma auth_fail) y nunca a /status" '[ "$(llamadas_a "http://10.0.0.5:4001/readyz?noleader")" = 1 ] && [ "$(llamadas_a "http://10.0.0.5:4001/status")" = 0 ] && [ "$(cat "$B/roam.state")" = "casa|casa|1" ]'
mundo con "ROAM_SEED=10.0.0.5
RQLITE_CRED=$CRED_DEF"; corre "$ROAM"
si "M3 ni con RQLITE_CRED puesto en sentinel.conf" 'sin_cred && [ "$(cat "$B/roam.state")" = "casa|casa|1" ]'
done

# ---------------------------------------------------------------- respaldo (bash)
echo "== Respaldo de sentinel020 (con bash)"
BASH_BIN=$(command -v bash 2>/dev/null) || BASH_BIN=""
if [ -n "$RESP" ] && [ -n "$BASH_BIN" ] && command -v gzip >/dev/null 2>&1; then
  RB="$T/respaldo"
  # La ruta que debe llegar a curl.exe: la de win(), o tal cual donde no hay cygpath.
  if command -v cygpath >/dev/null 2>&1; then RQW=$(cygpath -m "$RB/rqlite-respaldo.curlrc"); RQW2=$(cygpath -m "$RB/otra.curlrc")
  else RQW="$RB/rqlite-respaldo.curlrc"; RQW2="$RB/otra.curlrc"; fi
  mundo_r(){ # mundo_r con|sin [linea extra de .env]
    mundo sin; rm -rf "$RB"; mkdir -p "$RB/Script"
    printf 'TG_BOT_TOKEN=x\nTG_CHAT_ID=1\nFUENTES=10.0.0.21\nRONDAS=1\nESPERA_RONDA=0\nLIBRE_MIN_MB=0\nEC2_HOST=ec2.test\n%s\n' "${2:-}" > "$RB/.env"
    [ "$1" = "con" ] && cred "$RB/rqlite-respaldo.curlrc" respaldo
    return 0
  }
  # Sentinel-Respaldo.sh pone /usr/bin delante del PATH, asi que un curl falso en el
  # PATH no le llega: se le dan funciones exportadas, que bash mira antes que el PATH.
  # ssh y scp fallan (la EC2 "no responde"): eso deja un aviso a Telegram que mirar.
  corre_r(){
    ( cd "$T" && env PATH="$BIN:$PATH" MUNDO="$M" ARGV_TODO="$T/argv-todo" HOME="$H" RESPALDO_BASE="$RB" \
        NODE_BIN="${NODE_FALSO:-$BIN/node-falso}" FALSO="$BIN/curl" "$BASH_BIN" -c '
          curl(){ "$FALSO" "$@"; }; ssh(){ return 255; }; scp(){ return 1; }
          export -f curl ssh scp
          if ! command -v cygpath >/dev/null 2>&1; then cygpath(){ printf "%s\n" "$2"; }; export -f cygpath; fi
          exec "$BASH" "$0"' "$RESP" > "$M/salida" 2>&1 )
    fugas
  }
  mundo_r con; corre_r
  si "P1 con fichero: la copia y el INSERT llevan -K (ruta de win(), usuario respaldo)" 'con_cred "$RQW" respaldo && [ "$(llamadas_a "http://10.0.0.21:4001/db/backup")" = 1 ] && [ "$(llamadas_a "http://10.0.0.21:4001/db/execute")" = 1 ] && limpio'
  si "P1 Telegram sin -K, copia registrada y sin hablar de 401" 'hay_tg && ejecuta "INSERT INTO sentinel_respaldo" && tg "EC2 inalcanzable" && ! tg "(401)" && ! tg "no se pudo registrar"'
  mundo_r sin; corre_r
  si "P2 sin fichero: nadie lleva -K y la copia se registra igual" 'sin_cred && ejecuta "INSERT INTO sentinel_respaldo"'
  mundo_r con; : > "$M/401.10.0.0.21.execute"; corre_r
  si "P3 el INSERT da 401: el aviso lo dice" 'tg "rqlite rechaza la contraseña del usuario respaldo (401): no quedó registrada" && ! tg "no se pudo registrar en rqlite"'
  mundo_r con; : > "$M/401.10.0.0.21.backup"; corre_r
  si "P4 la copia da 401: el aviso y el log lo dicen" 'tg "ninguna copia valida tras 1 rondas" && tg "rechaza la contraseña del usuario respaldo (401)" && grep -q "10.0.0.21: rqlite rechaza la contraseña" "$RB/Log/respaldo.log"'
  mundo_r con; : > "$M/caido.10.0.0.21"; corre_r
  si "P5 fuente caida: el aviso de siempre, sin 401" 'tg "ninguna copia valida tras 1 rondas" && ! tg "(401)" && grep -q "10.0.0.21: fallo la descarga" "$RB/Log/respaldo.log"'
  mundo_r sin "RQ_CRED=$RB/otra.curlrc"; cred "$RB/otra.curlrc" respaldo; corre_r
  si "P6 RQ_CRED en .env manda" 'con_cred "$RQW2" respaldo'
  # La ruta de text@ tiene que llegar a curl.exe convertida por win() (si no, curl.exe sale con 26).
  if command -v cygpath >/dev/null 2>&1; then TXW=$(cygpath -m "$RB/tmp/aviso.txt"); else TXW="$RB/tmp/aviso.txt"; fi
  mundo_r con; : > "$M/caido.10.0.0.21"; n0=$(wc -l < "$T/argv-todo"); corre_r
  si "P7 el aviso va en un fichero (text@ con la ruta de win()), entero y con su viñeta" 'tg "ninguna copia valida tras 1 rondas" && tg "•" && tail -n +$((n0 + 1)) "$T/argv-todo" | grep -qF "text@$TXW" && ! tail -n +$((n0 + 1)) "$T/argv-todo" | grep -q "text=" && ! grep -q "NO enviado" "$RB/Log/respaldo.log"'
  mundo_r con; : > "$M/caido.10.0.0.21"; : > "$M/tg400"; corre_r
  si "P8 Telegram contesta 400: el log lo dice" 'grep -q "aviso de Telegram NO enviado (http 400): .*strings must be encoded in UTF-8" "$RB/Log/respaldo.log"'
  # P9: el verificador devuelve 2 con un resumen cortado a mitad de una "ñ" (un C3 suelto,
  # como el que deja cut -c en Git Bash). iconv -c lo quita y sale con 1: el aviso tiene que
  # salir igual, y en UTF-8 valido.
  printf '#!/bin/sh\nprintf "{}\\n" > "$3"\nprintf "avisos: contrase\\303"\nexit 2\n' > "$BIN/node-falso2"; chmod +x "$BIN/node-falso2"
  mundo_r con; NODE_FALSO="$BIN/node-falso2"; corre_r; NODE_FALSO=""
  si "P9 resumen con un byte que no es UTF-8: el aviso sale igual, ya limpio" 'tg "copia guardada, pero con avisos" && ! grep -q "NO enviado" "$RB/Log/respaldo.log" && { ! command -v iconv >/dev/null 2>&1 || iconv -f UTF-8 -t UTF-8 "$M/telegram.log" >/dev/null 2>&1; }'
else salta "Sentinel-Respaldo.sh necesita el repo, bash y gzip"; fi

# ---------------------------------------------------------------- en todo el banco
echo "== En todas las pasadas"
# Tambien se busca la cabecera: un -H "Authorization: Basic ..." llevaria la clave
# en base64, que no casa con el texto de la clave pero sale igual en ps.
si "Z1 la clave inventada no aparece en ningun argv, ni una cabecera Authorization" '[ -s "$T/argv-todo" ] && ! grep -qF -- "$CLAVE" "$T/argv-todo" && ! grep -qi "authorization" "$T/argv-todo"'
si "Z2 ni en ningun fichero que dejaron los scripts" '[ ! -s "$T/fugas" ]'
[ -s "$T/fugas" ] && sort -u "$T/fugas" | sed 's/^/      con la clave: /'

echo
echo "Resultado: $PASS pasan, $FAIL fallan"
[ "$FAIL" -eq 0 ]
