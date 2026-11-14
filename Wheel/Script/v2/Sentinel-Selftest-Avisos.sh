#!/bin/sh
# Sentinel v2 - Banco de pruebas de los avisos y del quorum de la eleccion.
#
# No toca la red ni Telegram: pone delante un `curl` falso que contesta desde un
# "mundo" de ficheros (que nodos responden, que dice rqlite, si Telegram acepta el
# mensaje) y un `sleep` que no espera. El reloj se fija con SENTINEL_NOW, asi que
# se pueden simular dias en segundos.
#
# Credenciales de rqlite (Fase 0): el curl falso entiende -K <fichero> y apunta
# cada llamada en argv.log; con $M/rq_clave se porta como un rqlited con -auth
# (401 con cuerpo vacio si el fichero no trae esa linea; /readyz queda abierto).
#
# Uso:  sh Sentinel-Selftest-Avisos.sh        (desde Wheel/Script/v2 o su espejo)
# Sale con 0 si todo pasa. Prueba los scripts con dash si esta instalado, que es
# el sh de Ubuntu y de Termux: lo que pase con bash podria no pasar alli.
set -u
V2=$(cd "$(dirname "$0")" && pwd)
SHX=$(command -v dash 2>/dev/null || command -v sh)
T=$(mktemp -d 2>/dev/null || { d="/tmp/selftest-avisos.$$"; mkdir -p "$d"; echo "$d"; })
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
no(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
si(){ if eval "$2"; then ok "$1"; else no "$1"; fi; }

M="$T/mundo"; B="$T/base"; H="$T/home"; BIN="$T/bin"
mkdir -p "$M" "$B" "$H/PRC_Thermal" "$BIN"
ARGV_TODO="$T/argv.todo"; export ARGV_TODO; : > "$ARGV_TODO"
printf 'BOT_TOKEN="x"\nCHAT_ID="1"\n' > "$H/PRC_Thermal/thermal-guard.conf"
printf '%s\n' "0123456789abcdef0123456789abcdef0123" > "$B/fleet.token"

# ---------------------------------------------------------------- curl falso
cat > "$BIN/curl" <<'EOF'
#!/bin/sh
M="$MUNDO"; url=""; w=""; o=""; q=""; text=""; data=""; cfg=""; kf=""
# Cada llamada, en una linea de argv.log: para ver a quien se mandan credenciales
# y que la clave nunca va en la linea de comandos. ARGV_TODO guarda las de todo el
# banco (argv.log se borra con cada mundo nuevo).
{ printf '%s' "$*" | tr '\n' ' '; printf '\n'; } >> "$M/argv.log"
[ -n "${ARGV_TODO:-}" ] && { printf '%s' "$*" | tr '\n' ' '; printf '\n'; } >> "$ARGV_TODO"
while [ $# -gt 0 ]; do
  case "$1" in
    -m|--connect-timeout|-H) shift ;;
    -w) shift; w="$1" ;;
    -o) shift; o="$1" ;;
    -d) shift; data="$1" ;;
    -K) shift; if [ "$1" = "-" ]; then cfg=$(cat); else kf="$1"; fi ;;
    --data-urlencode) shift; case "$1" in q=*) q="${1#q=}" ;; text=*) text="${1#text=}" ;; esac ;;
    -s|-G|-XPOST|-k) ;;
    -*) ;;
    *) url="$1" ;;
  esac
  shift
done
# El codigo HTTP con el formato que pida -w, como el curl de verdad (que lo
# escribe aunque no conecte: 000).
codigo(){
  case "$w" in
    *'HTTP:%{http_code}'*) printf '\nHTTP:%s' "$1" ;;
    *'\n%{http_code}'*) printf '\n%s' "$1" ;;
    *'%{http_code}'*) printf '%s' "$1" ;;
  esac
}
# rqlite con -auth: si existe $M/rq_clave (la linea que espera, p. ej.
# user = "sentinel:buena"), los endpoints con permiso responden 401 con cuerpo
# vacio salvo que -K apunte a un fichero con exactamente esa linea. /readyz queda
# abierto (usuario "*"), salvo que exista $M/readyz401.
autoriza(){
  [ -f "$M/rq_clave" ] || return 0
  [ -n "$kf" ] && [ -f "$kf" ] && grep -qxF -- "$(cat "$M/rq_clave")" "$kf" && return 0
  codigo 401; exit 0
}
# Como el curl de verdad, la URL puede llegar en un fichero de configuracion (-K -).
# Si la de Telegram llega en argv, el token del bot se veria en `ps`: se apunta.
case "$url" in https://api.telegram.org/*) echo "token mal pasado (en argv)" >> "$M/telegram.log" ;; esac
[ -n "$cfg" ] && url=$(printf '%s\n' "$cfg" | sed -n 's/^url = "\(.*\)"$/\1/p')
case "$url" in
  https://api.telegram.org/*)
    case "$url" in */botx/sendMessage) ;; *) echo "token mal pasado: $url" >> "$M/telegram.log" ;; esac
    printf '%s\n----\n' "$text" >> "$M/telegram.log"
    [ -f "$M/matar_en_tg" ] && { p=$(ls "$SENTINEL_BASE"/.alert.obs.* 2>/dev/null | head -1 | sed 's/.*\.//'); rm -f "$M/matar_en_tg"; kill -TERM "$p"; exit 143; }
    falla=$(cat "$M/tg_falla_si" 2>/dev/null)
    if [ -n "$falla" ] && printf '%s' "$text" | grep -q -- "$falla"; then printf '{"ok":false}\n500'; exit 0; fi
    printf '{"ok":true}\n200'; exit 0 ;;
  */readyz) c=$(cat "$M/readyz" 2>/dev/null || echo 200); [ -f "$M/readyz401" ] && c=401; codigo "$c"; exit 0 ;;
  */status*) autoriza; printf '{"store":{}}'; codigo 200; exit 0 ;;
  */nodes\?*)
    [ -f "$M/nodes.json" ] || { codigo 000; exit 7; }
    # Sin ?timeout=, un nodo atascado deja /nodes colgado >30 s (21/08) y curl corta:
    # el banco lo imita para que quitar el parametro rompa las pruebas.
    case "$url" in *timeout=*) ;; *) codigo 000; exit 28 ;; esac
    autoriza
    # Sin ?nonvoters, rqlite solo da los votantes: el banco lo imita para que quitar
    # el parametro rompa las pruebas. Se quitan del mapa las entradas con
    # "voter":false: primero las que van detras de una coma y luego, si queda, la
    # primera (con su coma), sin dejar el JSON roto.
    case "$url" in
      *nonvoters*) cat "$M/nodes.json" ;;
      *) sed -e 's/,[ ]*"[^"]*"[ ]*:[ ]*{[^}]*"voter"[ ]*:[ ]*false[ ]*}//g' \
             -e 's/^{[ ]*"[^"]*"[ ]*:[ ]*{[^}]*"voter"[ ]*:[ ]*false[ ]*}[ ]*,\{0,1\}[ ]*/{/' "$M/nodes.json" ;;
    esac
    codigo 200; exit 0 ;;
  */db/execute) autoriza; printf '%s\n' "$data" >> "$M/execute.log"; printf '{"results":[{}]}'; codigo 200; exit 0 ;;
  */db/query)
    autoriza
    case "$q" in
      # Estado de las señales de BTC: $M/vigia.btc con "ts,codigo,nodo". Va antes
      # que la fila de los avisos, que tambien es de sentinel_vigia.
      *"clave='btc-senales'"*)
        if [ -f "$M/vigia.btc" ]; then
          printf '{"results":[{"columns":["ts","pendientes","wheel"],"values":[[%s,%s,"%s"]]}]}' \
            "$(cut -d, -f1 "$M/vigia.btc")" "$(cut -d, -f2 "$M/vigia.btc")" "$(cut -d, -f3 "$M/vigia.btc")"
        else printf '{"results":[{"columns":["ts","pendientes","wheel"]}]}'; fi
        codigo 200; exit 0 ;;
      *"FROM sentinel_vigia"*) if [ -f "$M/vigia" ]; then printf '{"results":[{"columns":["ts","wheel","pendientes"],"values":[[%s]]}]}' "$(cat "$M/vigia")"; else printf '{"results":[{"columns":["ts","wheel","pendientes"]}]}'; fi; codigo 200; exit 0 ;;
      *"sentinel_bateria b JOIN"*) [ -f "$M/bat.json" ] && cat "$M/bat.json" || printf '{"results":[{"columns":["a"]}]}'; codigo 200; exit 0 ;;
      *"FROM sentinel_temp WHERE node=n"*)
        [ -f "$M/datos.caido" ] && { codigo 000; exit 7; }
        printf '{"results":[{"columns":["n","t","b"],"values":['
        sep=""
        for n in $(printf '%s' "$q" | grep -oE "SELECT '[^']*' AS n" | sed "s/SELECT '//; s/' AS n//"); do
          l=$(grep "^$n," "$M/datos" 2>/dev/null | head -1)
          t=$(printf '%s' "$l" | cut -d, -f2); b=$(printf '%s' "$l" | cut -d, -f3)
          printf '%s["%s",%s,%s]' "$sep" "$n" "${t:-null}" "${b:-null}"; sep=","
        done
        printf ']}]}'; codigo 200; exit 0 ;;
      # Monitoreo de BTC: $M/btc con lineas "producto,ultimo actualizado[,ts de
      # la ultima vela[,velas en 28 dias,de ellas en fin de semana]]" (sin ts: la
      # vela del dia de ese actualizado; sin los dos ultimos: 28 y 8, un 24/7).
      # Las columnas 4 y 5 solo salen si la consulta pide la ventana de 28 dias
      # de ESTA pasada y el dia de la semana: si el Wheel dejara de pedirlas, las
      # pruebas de lunes a viernes fallarian.
      *"FROM cripto_vela WHERE marco='1d' GROUP BY producto"*)
        [ -f "$M/btc.sintabla" ] && { printf '{"results":[{"error":"no such table: cripto_vela"}]}'; codigo 200; exit 0; }
        cols='"producto","MAX(actualizado)","MAX(ts)"'; ext=0
        case "$q" in *"ts>=$((SENTINEL_NOW - 2419200)) "*"(ts/86400+4)%7 IN (0,6)"*) cols="$cols,\"s28\",\"finde\""; ext=1 ;; esac
        [ -f "$M/btc" ] || { printf '{"results":[{"columns":[%s]}]}' "$cols"; codigo 200; exit 0; }
        printf '{"results":[{"columns":[%s],"values":[' "$cols"
        sep=""
        while IFS=, read -r p ac vt rc fs; do
          [ -n "$p" ] || continue
          [ -n "$vt" ] || vt=$((ac - ac % 86400))
          if [ "$ext" = 1 ]; then printf '%s["%s",%s,%s,%s,%s]' "$sep" "$p" "$ac" "$vt" "${rc:-28}" "${fs:-8}"
          else printf '%s["%s",%s,%s]' "$sep" "$p" "$ac" "$vt"; fi; sep=","
        done < "$M/btc"
        printf ']}]}'; codigo 200; exit 0 ;;
    esac
    printf '{"results":[{"error":"no esperado"}]}'; codigo 200; exit 0 ;;
  telnet://*) hp=${url#telnet://}
    if [ -f "$M/tcp.$hp" ]; then printf '0.001234'; exit 28; else printf '0.000000'; exit 28; fi ;;
  http://*:8181/fitness*|http://*:8181/version*)
    ip=${url#http://}; ip=${ip%%:*}
    f="$M/nodo.$ip"
    # Sondeo suelto perdido: falla SOLO la primera peticion a esa IP.
    if [ -f "$M/falla1.$ip" ]; then rm -f "$M/falla1.$ip"; case "$w" in *http_code*) printf '\n000' ;; esac; exit 7; fi
    # Agente que contesta con error (token viejo): cuerpo JSON y 401, como Server2.
    if [ -f "$M/nodo401.$ip" ]; then printf '{"error":"token invalido"}'; case "$w" in *http_code*) printf '\n401' ;; esac; exit 0; fi
    if [ ! -f "$f" ]; then case "$w" in *http_code*) printf '\n000' ;; esac; exit 7; fi
    case "$url" in
      */version*) if grep -q '"wheel":1' "$f"; then printf '{"wheel":1}'; else printf '{"wheel":0}'; fi ;;
      *) cat "$f" ;;
    esac
    case "$w" in *RTT*) printf '\nRTT:%s' "$(cat "$M/rtt.$ip" 2>/dev/null || echo 0.020)" ;; *http_code*) printf '\n200' ;; esac
    exit 0 ;;
  http://*|https://*) c=$(cat "$M/http" 2>/dev/null || echo 000); printf '%s' "$c"; exit 0 ;;
esac
exit 7
EOF
printf '#!/bin/sh\nexit 0\n' > "$BIN/sleep"
# ssh falso: guarda lo que se le manda por la entrada y el destino.
printf '#!/bin/sh\nfor a; do d="$a"; done\nprintf "%%s\\n" "$d" > "$MUNDO/ssh.destino"\ncat > "$MUNDO/ssh.entrada"\necho ok\n' > "$BIN/ssh"
chmod +x "$BIN/curl" "$BIN/sleep" "$BIN/ssh"

# ---------------------------------------------------------------- mundo
# fitness <ip> <nombre> [estable] [uptime] [wheel] [elegible] [carga]
fitness(){
  printf '{"nombre":"%s","elegible":%s,"wheel":%s,"uptime":%s,"temp":30,"fuente_temp":"bateria","carga":%s,"inflight":0,"maxjobs":4,"queued":0,"maxqueue":64,"estable":%s}' \
    "$2" "${6:-1}" "${5:-0}" "${4:-700000}" "${7:-0}" "${3:-0}" > "$M/nodo.$1"
}
caer(){ rm -f "$M/nodo.$1"; }
# nodos_json "ip:reachable:voter ..."  Con el formato REAL de rqlite v10: un MAPA
# por id (no {"nodes":[...]}), con las claves en orden alfabetico, p. ej.
#   {"node1":{"addr":"192.168.0.231:4002","api_addr":"http://192.168.0.231:4001",
#    "id":"node1","leader":false,"reachable":true,"time":0.0012,"time_s":"1.2ms",
#    "version":"10","voter":false}, ...}
# Un nodo inalcanzable NO trae api_addr (rqlite solo lo sabe si el nodo contesta)
# y si un "error". Con $M/nodes.espacios, ademas, espacio tras los dos puntos.
nodos_json(){
  printf '{' > "$M/nodes.json"; sep=""; i=0
  for e in "$@"; do
    ip=${e%%:*}; r=${e#*:}; v=${r#*:}; r=${r%%:*}; i=$((i + 1))
    if [ "$r" = true ]; then
      printf '%s"node%s":{"addr":"%s:4002","api_addr":"http://%s:4001","id":"node%s","leader":false,"reachable":true,"time":0.0012,"time_s":"1.2ms","version":"10","voter":%s}' "$sep" "$i" "$ip" "$ip" "$i" "$v" >> "$M/nodes.json"
    else
      printf '%s"node%s":{"addr":"%s:4002","error":"dial tcp %s:4002: i/o timeout","id":"node%s","leader":false,"reachable":false,"time":0,"time_s":"0s","version":"","voter":%s}' "$sep" "$i" "$ip" "$ip" "$i" "$v" >> "$M/nodes.json"
    fi
    sep=","
  done
  printf '}' >> "$M/nodes.json"
  [ -f "$M/nodes.espacios" ] && sed -i 's/":/": /g' "$M/nodes.json"
  return 0
}

AHORA0=1794000000
NOW=$AHORA0
conf(){ cat > "$B/sentinel.conf" <<EOF2
NAME=sentinelW
PORT=8181
RQLITE=http://127.0.0.1:4001
EXTRA_NODES=10.0.0.9
SKIP_NODES=10.0.0.8
GRACE_NODES=10.0.0.9:1800,10.0.0.79:1800
EXTRA_CHECKS=sentinel020=tcp://10.0.0.79:22
${1:-}
EOF2
}
mundo_sano(){
  rm -f "$M"/* "$B/alert.state" "$B/alert.log" "$B/bat.state"
  conf
  printf 'sentinelW\n' > "$B/wheel.state"; touch -d "@$((AHORA0 - 86400))" "$B/wheel.state"
  fitness 10.0.0.1 sentinelW 1 900000; fitness 10.0.0.2 sentinelA; fitness 10.0.0.3 sentinelB
  fitness 10.0.0.9 sentinelL 0 3000 0 0; fitness 10.0.0.8 sentinelM
  cp "$M/nodo.10.0.0.1" "$M/nodo.127.0.0.1"
  nodos_json 10.0.0.1:true:true 10.0.0.2:true:false 10.0.0.3:true:false 10.0.0.8:true:false
  echo 200 > "$M/readyz"
  : > "$M/tcp.10.0.0.79:22"
  datos_frescos
  : > "$M/telegram.log"
}
# sentinelM (SKIP) con datos rancios: si una regresion mirara los datos de los
# nodos que no se vigilan, apareceria dt:sentinelM.
datos_frescos(){ printf 'sentinelW,%s,\nsentinelA,%s,%s\nsentinelB,%s,%s\nsentinelM,%s,%s\n' "$NOW" "$NOW" "$NOW" "$NOW" "$NOW" "$((NOW-7200))" "$((NOW-7200))" > "$M/datos"; }

ronda(){ # ejecuta una pasada con el reloj en $NOW; deja en $MSG lo enviado
  : > "$M/telegram.log"
  # En la red el Wheel pasa cada 5 min, asi que su alert.state nunca tiene mas de
  # 5 min. Aqui el reloj salta dias de golpe: se finge esa continuidad para que no
  # salte la "foto caducada" (que tiene su propia prueba, C3).
  [ -f "$B/alert.state" ] && touch -d "@$((NOW - 300))" "$B/alert.state"
  ( cd "$T" && PATH="$BIN:$PATH" MUNDO="$M" HOME="$H" SENTINEL_BASE="$B" SENTINEL_NOW="$NOW" \
      SENTINEL_NOJITTER=1 "$SHX" "$V2/Sentinel-Alert.sh" > "$T/salida" 2>&1 )
  [ -f "$B/alert.state" ] && touch -d "@$NOW" "$B/alert.state"
  MSG=$(cat "$M/telegram.log")
}
avanza(){ NOW=$((NOW + ${1:-300})); }
estado(){ awk -F'|' -v k="$1" '$1==k{print $3}' "$B/alert.state" 2>/dev/null; }
hay(){ printf '%s' "$MSG" | grep -qF -- "$1"; }
nada(){ [ -z "$MSG" ]; }

echo "== Avisos (con $SHX)"
mundo_sano; ronda
si "A1 red sana: ningun mensaje" 'nada'
si "A1 estado con nodos, rqlite, datos y 020" '[ "$(estado 10.0.0.2)" = ok ] && [ "$(estado __cl__)" = ok ] && [ "$(estado dt:sentinelA)" = ok ] && [ "$(estado ex:sentinel020)" = ok ] && [ "$(estado rq:10.0.0.3)" = ok ]'
si "A1 SKIP no se vigila" '[ -z "$(estado 10.0.0.8)" ] && [ -z "$(estado dt:sentinelM)" ]'
si "A1 latido en rqlite con 0 pendientes" 'grep -q "\"avisos\", $NOW, \"sentinelW\", 0" "$M/execute.log"'

avanza; caer 10.0.0.3; ronda
si "A2 nodo caido avisa" 'hay "nodo sin responder" && hay "sentinelB (10.0.0.3)"'
avanza; nodos_json 10.0.0.1:true:true 10.0.0.2:true:false 10.0.0.3:false:false 10.0.0.8:true:false
printf 'sentinelW,%s,\nsentinelA,%s,%s\nsentinelB,%s,%s\n' "$NOW" "$NOW" "$NOW" "$((NOW-7200))" "$((NOW-7200))" > "$M/datos"; ronda; avanza; ronda; avanza; ronda
si "A2 caido con rqlite y datos tambien mal: solo cuenta la caida" '! grep -q "rqlite\|datos no llegan" "$B/alert.log"'
nodos_json 10.0.0.1:true:true 10.0.0.2:true:false 10.0.0.3:true:false 10.0.0.8:true:false; datos_frescos
si "A2 estado caido" '[ "$(estado 10.0.0.3)" = caido ]'
avanza; ronda
si "A3 sigue caido: silencio" 'nada'

avanza; fitness 10.0.0.3 sentinelB; echo "recuperado" > "$M/tg_falla_si"; ronda
si "A4 Telegram falla: se intento" 'hay "nodo recuperado"'
si "A4 la transicion NO se da por hecha" '[ "$(estado 10.0.0.3)" = caido ]'
si "A4 queda en alert.log como FALLO" 'grep -q "vuelto FALLO" "$B/alert.log"'
si "A4 latido con 1 pendiente" 'grep -q "\"avisos\", $NOW, \"sentinelW\", 1" "$M/execute.log"'
avanza; rm -f "$M/tg_falla_si"; ronda
si "A5 reintento: ahora si llega, con la duracion" 'hay "nodo recuperado" && hay "sentinelB (10.0.0.3) tras 30 min"'
si "A5 estado ok" '[ "$(estado 10.0.0.3)" = ok ]'
avanza; ronda
si "A5 y no se repite" 'nada'

avanza; caer 10.0.0.2; echo "sin responder" > "$M/tg_falla_si"; ronda
si "A6 caida con Telegram roto: estado sigue ok" '[ "$(estado 10.0.0.2)" = ok ]'
avanza; rm -f "$M/tg_falla_si"; ronda
si "A6 se reintenta y llega" 'hay "sentinelA (10.0.0.2)" && hay "nodo sin responder"'
avanza; ronda
si "A6 una sola vez" 'nada'

avanza 86400; ronda
si "A7 recordatorio a las 24 h" 'hay "sigue pendiente" && hay "sentinelA (10.0.0.2) sin responder desde hace 1 d"'
avanza; ronda
si "A7 recordatorio no se repite en la pasada siguiente" 'nada'
avanza 86400; ronda
si "A7 otro a las 48 h" 'hay "sigue pendiente"'
fitness 10.0.0.2 sentinelA; avanza; ronda
si "A7 recuperado tras dias" 'hay "nodo recuperado" && hay "sentinelA (10.0.0.2) tras 2 d"'

echo "== Tolerancia"
mundo_sano; ronda; avanza; caer 10.0.0.9; ronda
si "G1 laptop en su plazo: silencio" 'nada && [ "$(estado 10.0.0.9)" = ok ]'
avanza 900; ronda
si "G1 a los 20 min tampoco" 'nada'
avanza 900; ronda
si "G1 pasado el plazo avisa con la espera" 'hay "sentinelL (10.0.0.9) — sin responder desde hace 30 min"'
mundo_sano; ronda; avanza; caer 10.0.0.9; ronda; avanza 600; fitness 10.0.0.9 sentinelL 0 3000 0 0; ronda
si "G2 vuelve dentro del plazo: ni caida ni recuperacion" 'nada && [ "$(estado 10.0.0.9)" = ok ] && [ -z "$(awk -F"|" "\$1==\"10.0.0.9\"{print \$4}" "$B/alert.state")" ]'

echo "== Datos parados"
# datos <tsW> <tsA> <tsB>: temperatura y bateria de A y B con ese ts; W (Ubuntu) solo temperatura.
datos(){ printf 'sentinelW,%s,\nsentinelA,%s,%s\nsentinelB,%s,%s\n' "$1" "$2" "$2" "$3" "$3" > "$M/datos"; }
mundo_sano; ronda; avanza
PARADO=$((NOW-10800)); datos "$NOW" "$PARADO" "$NOW"; ronda
si "D1 nodo vivo sin datos: primera pasada, aun en su gracia" 'nada'
avanza; datos "$NOW" "$PARADO" "$NOW"; ronda; avanza; datos "$NOW" "$PARADO" "$NOW"; ronda
si "D1 a la tercera pasada avisa" 'hay "datos no llegan" && hay "sentinelA: sin temperatura desde hace 3 h 10 min; sin batería desde hace 3 h 10 min"'
avanza; datos "$NOW" "$PARADO" "$NOW"; ronda
si "D1 sigue igual: silencio" 'nada'
avanza; datos_frescos; ronda
si "D1 vuelven los datos" 'hay "vuelven a llegar los datos de" && hay "sentinelA"'
mundo_sano; ronda; CONG=$NOW
for i in 1 2 3 4 5 6; do avanza; datos "$CONG" "$((CONG-200))" "$((CONG-100))"; ronda; done
si "D2 base congelada con mi rqlite sano: no se culpa a cada nodo" '! grep -q "datos no llegan" "$B/alert.log" 2>/dev/null'
mundo_sano; ronda; CONG=$NOW; echo 503 > "$M/readyz"
for i in 1 2 3 4 5 6; do avanza; datos "$CONG" "$((CONG-280))" "$((CONG-30))"; ronda; done
si "D2b sin lider (tormenta): ni un 'datos no llegan', solo el aviso de rqlite" '! grep -q "datos no llegan" "$B/alert.log" && grep -q "cl_mal ok" "$B/alert.log"'
mundo_sano; ronda; avanza; datos_frescos; ronda
si "D3 Ubuntu sin bateria y temperatura al dia: sano" '[ "$(estado dt:sentinelW)" = ok ]'
avanza; touch "$M/datos.caido"; ronda; rm -f "$M/datos.caido"
si "D4 consulta fallida: conserva el estado" '[ "$(estado dt:sentinelA)" = ok ] && nada'
mundo_sano; ronda; avanza; caer 10.0.0.3; ronda; CAIDA=$NOW
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24; do avanza; datos "$NOW" "$NOW" "$((CAIDA-300))"; ronda; done
avanza; fitness 10.0.0.3 sentinelB; datos "$NOW" "$NOW" "$((CAIDA-300))"; ronda
si "D5 vuelve tras 2 h con datos de antes de caer: solo 'recuperado'" 'hay "nodo recuperado" && ! hay "datos no llegan"'
avanza; datos "$NOW" "$NOW" "$((CAIDA-300))"; ronda
si "D5 la pasada siguiente, aun sin datos nuevos: en su gracia" 'nada'
avanza; datos_frescos; ronda
si "D5 y cuando llegan, nada que avisar" 'nada && ! grep -q "dt_mal" "$B/alert.log"'
mundo_sano; ronda; PAR=$((NOW-10800))
for c in 1 2 3 4; do
  avanza; caer 10.0.0.3; datos "$NOW" "$NOW" "$PAR"; ronda
  for j in 1 2 3; do avanza; fitness 10.0.0.3 sentinelB; datos "$NOW" "$NOW" "$PAR"; ronda; done
done
si "D6 cron muerto en un nodo que se cae una pasada de cada cuatro: acaba avisando" 'grep -q "dt_mal ok" "$B/alert.log"'

echo "== Monitoreo de BTC"
# btc "producto,actualizado[,ts de la ultima vela[,velas en 28 dias,en fin de
# semana]]" ...: lo que hay en cripto_vela (sin los dos ultimos, un 24/7).
# rb: una pasada con la telemetria al dia (si no, la replica no cuenta como al
# dia y BTC no se mira, que es otra prueba).
btc(){ printf '%s\n' "$@" > "$M/btc"; }
rb(){ datos_frescos; ronda; }
PE=BIP-20DEC30-CDE
mundo_sano; btc "$PE,$NOW" "BTC-USD,$NOW"; rb
si "BV1 BTC al dia: ningun mensaje y los dos productos en ok" 'nada && [ "$(estado bv:$PE)" = ok ] && [ "$(estado bv:BTC-USD)" = ok ]'
avanza; btc "$PE,$((NOW - 840))" "BTC-USD,$NOW"; rb
si "BV2 14 min sin escribir (menos de tres pasadas): aun no" 'nada && [ "$(estado bv:$PE)" = ok ]'
avanza; btc "$PE,$((NOW - 900))" "BTC-USD,$NOW"; rb
si "BV2 justo 15 min: aun no (el plazo es estricto)" 'nada && [ "$(estado bv:$PE)" = ok ]'
avanza; btc "$PE,$((NOW - 1500))" "BTC-USD,$NOW"; rb
si "BV2 25 min: avisa del producto parado, con cuanto hace y donde mirar" 'hay "el monitoreo de BTC no está al día" && hay "• $PE: sin escribir desde hace 25 min" && hay "sentinel-btc-velas" && ! hay "BTC-USD"'
avanza; btc "$PE,$((NOW - 1800))" "BTC-USD,$NOW"; rb
si "BV2 sigue parado: silencio" 'nada && [ "$(estado bv:$PE)" = mal ]'
avanza; btc "$PE,$NOW" "BTC-USD,$NOW"; rb
si "BV3 vuelve: aviso de vuelta, sin una duracion que contradiga la del aviso" 'hay "el monitoreo de BTC vuelve a estar al día" && hay "• $PE" && ! hay "tras"'
avanza; rb
si "BV3 y no se repite" 'nada'
mundo_sano; btc "$PE,$NOW"; rb; PAR=$NOW
for i in 1 2 3; do avanza; btc "$PE,$PAR"; rb; done
si "BV4 a los 15 min justos, aun nada" '! grep -q "bv_mal" "$B/alert.log" 2>/dev/null'
avanza; btc "$PE,$PAR"; rb
si "BV4 a los 20 min avisa" 'grep -q "bv_mal ok" "$B/alert.log"'
avanza 86400; btc "$PE,$PAR"; rb
si "BV4 parado mas de un dia: recordatorio con la edad al dia" 'hay "sigue pendiente" && hay "• $PE: sin escribir desde hace 1 d 0 h"'
mundo_sano; ronda; CONG=$NOW
for i in 1 2 3 4 5 6; do avanza; datos "$CONG" "$((CONG-200))" "$((CONG-100))"; btc "$PE,$CONG"; ronda; done
si "BV5 base congelada: no se culpa al monitoreo de BTC" '! grep -q "bv_mal" "$B/alert.log" 2>/dev/null'
mundo_sano; btc "$PE,$NOW"; rb; PAR=$NOW
for i in 1 2 3 4 5; do avanza; datos "$((NOW - 660))" "$((NOW - 700))" "$((NOW - 700))"; btc "$PE,$((PAR - 960 + i * 300 - 300))"; ronda; done
si "BV5b replica del Wheel atrasada 11 min (bateria aun dentro de su plazo): tampoco" '! grep -q "bv_mal" "$B/alert.log" 2>/dev/null && [ "$(estado df:flota)" = ok ]'
# Temperatura parada en toda la flota pero bateria al dia: la replica SI esta al
# dia (lo mas reciente es de hace 100 s), asi que BTC se sigue vigilando.
mundo_sano; btc "$PE,$NOW"; rb; PAR=$NOW
for i in 1 2 3 4 5; do avanza; printf 'sentinelW,%s,\nsentinelA,%s,%s\nsentinelB,%s,%s\n' "$((NOW - 660))" "$((NOW - 660))" "$((NOW - 100))" "$((NOW - 660))" "$((NOW - 100))" > "$M/datos"; btc "$PE,$PAR"; ronda; done
si "BV5c sin temperatura en la flota pero con bateria al dia: BTC parado si avisa" 'grep -q "bv_mal ok" "$B/alert.log"'
mundo_sano; btc "$PE,$NOW"; rb; PAR=$NOW; echo 503 > "$M/readyz"
for i in 1 2 3 4 5 6; do avanza; btc "$PE,$PAR"; rb; done
si "BV6 sin lider: solo el aviso de rqlite, ni una palabra de BTC" '! grep -q "bv_mal" "$B/alert.log" && grep -q "cl_mal ok" "$B/alert.log"'
mundo_sano; btc "$PE,$NOW"; rb; touch "$M/btc.sintabla"
for i in 1 2 3 4 5 6; do avanza; rb; done
si "BV7 sin la tabla (o la consulta falla): silencio y conserva el estado" 'nada && [ "$(estado bv:$PE)" = ok ]'
mundo_sano; btc "VIEJO-X,$((NOW - 700000))" "$PE,$NOW"; rb
si "BV8 un producto sin escribir hace mas de una semana, con otro al dia: retirado, no se mira" 'nada && [ -z "$(estado bv:VIEJO-X)" ] && [ "$(estado bv:$PE)" = ok ]'
mundo_sano; btc "$PE,$NOW" "BTC-USD,$NOW"; rb; PAR=$NOW
for i in 1 2 3 4; do avanza; btc "$PE,$PAR" "BTC-USD,$PAR"; rb; done
for d in 1 2 3 4 5 6 7 8; do avanza 86400; btc "$PE,$PAR" "BTC-USD,$PAR"; rb; done
si "BV8b parado todo 8 dias: no se calla (recordatorio del dia 8, de los dos productos)" 'hay "sigue pendiente" && hay "• $PE: sin escribir desde hace 8 d" && hay "• BTC-USD: sin escribir desde hace 8 d"'
avanza; btc "$PE,$NOW" "BTC-USD,$NOW"; rb
si "BV8b ...y cuando vuelve, lo dice" 'hay "vuelve a estar al día" && hay "• $PE"'
mundo_sano; btc "VIEJO-Y,$((NOW - 30 * 86400))" "$PE,$((NOW - 8 * 86400))" "BTC-USD,$((NOW - 8 * 86400))"; rb
si "BV8c todo parado 8 dias y uno retirado hace 30: avisa de los dos de ahora, no del retirado" 'hay "• $PE: sin escribir desde hace 8 d" && hay "• BTC-USD: sin escribir" && ! hay "VIEJO-Y" && [ -z "$(estado bv:VIEJO-Y)" ]'
mundo_sano; conf "BTC_DATOS_MAX_MIN=60"; btc "$PE,$NOW"; rb; PAR=$NOW
for i in 1 2 3 4; do avanza; btc "$PE,$PAR"; rb; done
si "BV9 con BTC_DATOS_MAX_MIN=60, 20 min sin escribir no avisa" 'nada && [ "$(estado bv:$PE)" = ok ] && ! grep -q "bv_mal" "$B/alert.log" 2>/dev/null'
# Escribe, pero la ultima vela es de ayer: Coinbase no la trae. El reloj salta a
# la 01:00 UTC del dia siguiente (siempre hacia delante).
NOW=$(( (NOW / 86400 + 1) * 86400 + 3600 )); HOY=$((NOW - 3600))
mundo_sano; btc "$PE,$NOW,$HOY" "BTC-USD,$NOW,$HOY"; rb
si "BV10 con la vela de hoy: bien" 'nada && [ "$(estado bv:$PE)" = ok ]'
avanza; btc "$PE,$NOW,$((HOY - 86400))" "BTC-USD,$NOW,$HOY"; rb
si "BV10 escribe pero sin la vela de hoy: Coinbase no la trae, con las fechas en UTC" 'hay "no está al día" && hay "• $PE: escribe, pero Coinbase no trae la vela del $(date -u -d "@$HOY" +%d/%m) (UTC); la última es del $(date -u -d "@$((HOY - 86400))" +%d/%m)" && ! hay "BTC-USD"'
NOW=$(( (NOW / 86400 + 1) * 86400 + 840 )); HOY=$((NOW - 840))
mundo_sano; btc "$PE,$NOW,$((HOY - 86400))"; rb
si "BV10 a las 00:14 UTC aun sin la de hoy: todavia no (plazo tras medianoche)" 'nada && [ "$(estado bv:$PE)" = ok ]'

# Un producto de lunes a viernes (el Tech 100): 20 velas en 28 dias y ninguna en
# fin de semana. salta <dia de la semana, 0 domingo .. 6 sabado> <segundos tras
# la medianoche UTC>: el siguiente dia asi (siempre hacia delante); hora <s>: la
# misma fecha, a esa hora (solo hacia delante). fe <ts>: dd/mm en UTC.
TK=TEK-19DEC30-CDE
salta(){ _d=$((NOW / 86400 + 1)); while [ $(( (_d + 4) % 7 )) -ne "$1" ]; do _d=$((_d + 1)); done; NOW=$((_d * 86400 + $2)); }
hora(){ NOW=$((NOW - NOW % 86400 + $1)); }
fe(){ date -u -d "@$1" +%d/%m; }
salta 3 43200; MIE=$((NOW - 43200))
mundo_sano; btc "$TK,$NOW,$MIE,20,0" "$PE,$NOW"; rb
si "BV11 lunes a viernes, al dia un miercoles: bien" 'nada && [ "$(estado bv:$TK)" = ok ] && [ "$(estado bv:$PE)" = ok ]'
salta 5 43200; VIE=$((NOW - 43200))
btc "$TK,$NOW,$VIE,20,0" "$PE,$NOW"; rb
salta 6 43200; btc "$TK,$NOW,$VIE,20,0" "$PE,$NOW"; rb
si "BV11 sabado con la ultima vela del viernes: nada" 'nada && [ "$(estado bv:$TK)" = ok ]'
salta 0 43200; btc "$TK,$NOW,$VIE,20,0" "$PE,$NOW"; rb
si "BV11 domingo con la del viernes: nada" 'nada && [ "$(estado bv:$TK)" = ok ]'
salta 1 1800; LUN=$((NOW - 1800)); btc "$TK,$NOW,$VIE,20,0" "$PE,$NOW"; rb
si "BV11 lunes 00:30 UTC sin la del lunes (en invierno abre a la 01:00): nada" 'nada && [ "$(estado bv:$TK)" = ok ]'
hora 18000; btc "$TK,$NOW,$VIE,20,0" "$PE,$NOW"; rb
si "BV11 lunes 05:00 UTC aun sin la del lunes: nada (6 h de gracia)" 'nada && [ "$(estado bv:$TK)" = ok ]'
hora 25200; btc "$TK,$NOW,$VIE,20,0" "$PE,$NOW"; rb
si "BV11 lunes 07:00 UTC sin la del lunes (un festivo): falta un dia habil, nada" 'nada && [ "$(estado bv:$TK)" = ok ]'
salta 2 18000; btc "$TK,$NOW,$VIE,20,0" "$PE,$NOW"; rb
si "BV11 martes 05:00 UTC con la del viernes: el martes aun no cuenta (6 h de gracia), nada" 'nada && [ "$(estado bv:$TK)" = ok ]'
hora 25200; btc "$TK,$NOW,$VIE,20,0" "$PE,$NOW"; rb
si "BV12 martes 07:00 UTC con la ultima del viernes: faltan dos dias habiles, avisa del lunes" 'hay "no está al día" && hay "• $TK: escribe, pero Coinbase no trae la vela del $(fe "$LUN") (UTC); la última es del $(fe "$VIE")" && ! hay "$PE" && [ "$(estado bv:$PE)" = ok ]'
avanza; btc "$TK,$NOW,$((NOW - 25500)),20,0" "$PE,$NOW"; rb
si "BV12 llega la del martes: vuelve" 'hay "vuelve a estar al día" && hay "• $TK" && [ "$(estado bv:$TK)" = ok ]'
# Con pocos datos (5 velas en 28 dias) no se sabe si es de lunes a viernes: se
# mira como un 24/7. Y un 24/7 con la ultima del viernes avisa el sabado, como
# siempre, aunque al lado haya uno de lunes a viernes igual de quieto.
# Cada caso: viernes 23:00 UTC con la vela del viernes (bien), y el sabado a la
# 01:00 UTC con la misma.
salta 5 82800; VIE=$((NOW - 82800)); mundo_sano; btc "$TK,$NOW,$VIE,5,0"; rb
si "BV13 viernes 23:00, al dia (5 velas en 28 dias)" 'nada && [ "$(estado bv:$TK)" = ok ]'
avanza 7200; btc "$TK,$NOW,$VIE,5,0"; rb
si "BV13 con 5 velas en 28 dias se trata como 24/7: el sabado avisa" 'hay "• $TK: escribe, pero Coinbase no trae la vela del $(fe "$((VIE + 86400))") (UTC); la última es del $(fe "$VIE")"'
salta 5 82800; VIE=$((NOW - 82800)); mundo_sano; btc "$TK,$NOW,$VIE,20,0" "$PE,$NOW,$VIE"; rb
avanza 7200; btc "$TK,$NOW,$VIE,20,0" "$PE,$NOW,$VIE"; rb
si "BV13 un 24/7 parado en el viernes avisa el sabado, y el de lunes a viernes al lado no" 'hay "• $PE: escribe, pero Coinbase no trae la vela del $(fe "$((VIE + 86400))") (UTC)" && ! hay "$TK" && [ "$(estado bv:$TK)" = ok ]'
salta 5 82800; VIE=$((NOW - 82800)); mundo_sano; btc "$TK,$NOW,$VIE,20,1"; rb
avanza 7200; btc "$TK,$NOW,$VIE,20,1"; rb
si "BV13 una sola vela en fin de semana en 28 dias: ya es 24/7 y avisa" 'hay "• $TK: escribe, pero Coinbase no trae la vela del $(fe "$((VIE + 86400))") (UTC)"'

echo "== Señales de BTC"
# vbtc <desde> <codigo>: lo que apunta la pasada de BTC en sentinel_vigia.
vbtc(){ printf '%s,%s,sentinel014\n' "$1" "$2" > "$M/vigia.btc"; }
mundo_sano; btc "$PE,$NOW"; vbtc "$((NOW - 3600))" 0; rb
si "BS1 señales bien: nada, y bs:senales en ok" 'nada && [ "$(estado bs:senales)" = ok ]'
avanza; btc "$PE,$NOW"; vbtc "$((NOW - 600))" 1; rb
si "BS2 fallan desde hace 10 min: aun no" 'nada && [ "$(estado bs:senales)" = ok ]'
avanza; btc "$PE,$NOW"; vbtc "$((NOW - 1000))" 1; rb
si "BS2 desde hace 16 min: avisa, con el codigo y donde mirar" 'hay "las señales de BTC no salen" && hay "• señales de BTC: fallan desde hace 16 min (el paso 7 sale con 1)" && hay "velas.log"'
avanza; btc "$PE,$NOW"; rb
si "BS2 sigue fallando: silencio" 'nada && [ "$(estado bs:senales)" = mal ]'
avanza; btc "$PE,$NOW"; vbtc "$NOW" 0; rb
si "BS3 vuelven a salir: lo dice" 'hay "las señales de BTC vuelven a salir"'
mundo_sano; btc "$PE,$NOW"; rb
si "BS4 sin la fila (la pasada nunca la apunto): no se observa" 'nada && [ -z "$(estado bs:senales)" ]'
mundo_sano; ronda; CONG=$NOW
for i in 1 2 3 4 5 6; do avanza; datos "$CONG" "$((CONG-200))" "$((CONG-100))"; vbtc "$CONG" 2; ronda; done
si "BS5 con la base congelada no se mira" '! grep -q "bs_mal" "$B/alert.log" 2>/dev/null'

echo "== rqlite"
mundo_sano; ronda; avanza; echo 503 > "$M/readyz"; ronda
si "R1 sin lider una pasada: aun no avisa" 'nada'
avanza; ronda
si "R1 dos pasadas: avisa" 'hay "rqlite sin líder" && hay "readyz 503"'
avanza; echo 200 > "$M/readyz"; ronda
si "R1 un solo readyz bueno aun no es la vuelta" 'nada'
avanza; ronda
si "R1 dos seguidos: vuelve" 'hay "rqlite de vuelta"'
avanza; nodos_json 10.0.0.1:true:true 10.0.0.2:false:false 10.0.0.3:true:false 10.0.0.8:true:false; ronda
si "R2 rqlited de un nodo vivo inalcanzable (sin api_addr, como rqlite): aun no" 'nada'
avanza; ronda
si "R2 a la segunda avisa" 'hay "no alcanza el rqlite de" && hay "sentinelA (10.0.0.2, sin voto)"'
avanza; nodos_json 10.0.0.1:true:true 10.0.0.2:true:false 10.0.0.3:true:false 10.0.0.8:true:false; ronda; avanza; ronda
si "R2 vuelve tras dos pasadas buenas" 'hay "rqlite de vuelta en el clúster"'
avanza; echo 503 > "$M/readyz"; nodos_json 10.0.0.1:true:true 10.0.0.2:false:false 10.0.0.3:false:false 10.0.0.8:true:false; ronda; avanza; ronda
si "R3 con mi rqlite sin lider no culpa a cada nodo" '! hay "no alcanza el rqlite" && hay "rqlite sin líder"'
mundo_sano; ronda
for c in 503 503 200 503 503 200 503 503 200 503; do avanza; echo "$c" > "$M/readyz"; ronda; done
si "R4 tormenta (readyz que oscila): un solo 'sin lider' y ninguna vuelta falsa" '[ "$(grep -c "cl_mal ok" "$B/alert.log")" = 1 ] && ! grep -q "cl_bien" "$B/alert.log"'
mundo_sano; touch "$M/nodes.espacios"; nodos_json 10.0.0.1:true:true 10.0.0.2:false:false 10.0.0.3:true:false 10.0.0.8:true:false; ronda; avanza; ronda
si "R5 /nodes con espacios tras los dos puntos: tambien avisa" 'hay "sentinelA (10.0.0.2, sin voto)"'
rm -f "$M/nodes.espacios"
mundo_sano; ronda; avanza; nodos_json 10.0.0.1:true:true 10.0.0.2:false:false 10.0.0.3:true:false 10.0.0.8:true:false; ronda
avanza; caer 10.0.0.2; ronda; avanza; ronda; avanza; fitness 10.0.0.2 sentinelA; ronda
si "R6 la gracia a medias no sobrevive a una caida: al volver, solo 'recuperado'" 'hay "nodo recuperado" && ! hay "no alcanza el rqlite"'

echo "== Nodos: respuestas que no son /fitness"
mundo_sano; ronda; avanza; caer 10.0.0.2; : > "$M/nodo401.10.0.0.2"; ronda
si "N1 agente que rechaza el token (401) cuenta como caido y lo dice" 'hay "sentinelA (10.0.0.2) — rechaza el token de la flota (401)"'

echo "== Equipos sin agente (020)"
mundo_sano; ronda; avanza; rm -f "$M/tcp.10.0.0.79:22"; ronda
si "X1 020 en su plazo: silencio" 'nada'
avanza 1800; ronda
si "X1 pasado el plazo: avisa" 'hay "equipo sin responder" && hay "sentinel020 (tcp://10.0.0.79:22)"'
avanza; : > "$M/tcp.10.0.0.79:22"; ronda
si "X1 vuelve" 'hay "equipo recuperado" && hay "sentinel020 tras"'

echo "== Bateria"
mundo_sano; ronda; avanza
printf '{"results":[{"columns":["a"],"values":[["sentinelA",60,"DISCHARGING","PLUGGED_AC",41.5,70],["sentinelB",90,"CHARGING","PLUGGED_AC",30.0,90]]}]}' > "$M/bat.json"; ronda
si "B1 enchufado perdiendo: avisa" 'hay "enchufado pero perdiendo batería" && hay "sentinelA 60% — ha perdido 10 puntos en 2 h"'
avanza; printf '{"results":[{"columns":["a"],"values":[["sentinelA",65,"CHARGING","PLUGGED_AC",38.0,66]]}]}' > "$M/bat.json"; ronda
si "B1 recuperada" 'hay "batería recuperada" && hay "sentinelA 65%"'
mundo_sano; printf 'sentinelB|mal\n' > "$B/bat.state"
printf '{"results":[{"columns":["a"],"values":[["sentinelB",0,"NOT_CHARGING","PLUGGED_AC",30.1,0,"UNKNOWN"]]}]}' > "$M/bat.json"; ronda
si "B2 bateria que no mide (0 %% y UNKNOWN): ni aviso ni recuperacion" 'nada'
avanza 86400; ronda
si "B2 y tampoco recordatorio diario" 'nada'
mundo_sano; ronda; avanza
printf '{"results":[{"columns":["a"],"values":[["sentinelM",20,"CHARGING","PLUGGED_AC",30.0,25,"GOOD"]]}]}' > "$M/bat.json"; ronda
si "B3 el movil personal (SKIP_NODES) cargandose bajo el 30 %%: sin aviso" 'nada'

echo "== Compatibilidad y bordes"
mundo_sano
printf '10.0.0.2|sentinelA|ok|\n10.0.0.3|sentinelB|caido|%s\n__wheel__=sentinelW\n' "$((NOW-600))" > "$B/alert.state"
printf 'sentinelA|mal\n' > "$B/bat.state"
printf '{"results":[{"columns":["a"],"values":[["sentinelA",60,"DISCHARGING","PLUGGED_AC",41.5,70]]}]}' > "$M/bat.json"
caer 10.0.0.3; touch -d "@$NOW" "$B/alert.state"; ronda
si "C1 estado de 4 campos y bat.state antiguos: sin avisos repetidos" 'nada'
si "C1 bat.state importado y borrado" '[ "$(estado bt:sentinelA)" = mal ] && [ ! -f "$B/bat.state" ]'
avanza; fitness 10.0.0.3 sentinelB; ronda
si "C1 la caida heredada se cierra bien" 'hay "nodo recuperado" && hay "sentinelB (10.0.0.3) tras 15 min"'

# Relevo real: el Wheel anterior (sentinelX) dejo su nombre en sentinel_vigia, y
# yo no tengo alert.state (nunca fui Wheel). Asi es como llega en la flota.
mundo_sano; printf '%s,"sentinelX",0' "$((NOW-900))" > "$M/vigia"; echo "coordinador" > "$M/tg_falla_si"; ronda
si "C2 relevo con Telegram roto: el latido guarda al Wheel anterior para reintentar" 'grep -q "\"avisos\", $NOW, \"sentinelX\"" "$M/execute.log"'
avanza; rm -f "$M/tg_falla_si"; ronda
si "C2 relevo avisado" 'hay "pasa de sentinelX a sentinelW" && grep -q "\"avisos\", $NOW, \"sentinelW\"" "$M/execute.log"'
avanza; printf '%s,"sentinelW",0' "$((NOW-300))" > "$M/vigia"; ronda
si "C2 una sola vez" 'nada'
avanza; printf '%s,"sentinelX",0' "$((NOW-100))" > "$M/vigia"; ronda
si "C2b dos que se creen Wheel y no se ven: no se anuncian el relevo cada 5 min" '! hay "pasa de"'
rm -f "$M/vigia"

mundo_sano; ronda; avanza; caer 10.0.0.3; ronda; avanza 3600; touch -d "@$((NOW - 3600))" "$B/alert.state"
( cd "$T" && PATH="$BIN:$PATH" MUNDO="$M" HOME="$H" SENTINEL_BASE="$B" SENTINEL_NOW="$NOW" SENTINEL_NOJITTER=1 "$SHX" "$V2/Sentinel-Alert.sh" >/dev/null 2>&1 ); MSG=$(cat "$M/telegram.log")
si "C3 foto caducada (relevo): reanuncia lo que sigue caido, conserva nombres" 'hay "sentinelB (10.0.0.3)"'

mundo_sano; printf 'otro\n' > "$B/wheel.state"; touch -d "@$((AHORA0 - 86400))" "$B/wheel.state"; ronda
si "C4 si no soy el Wheel no hago nada" 'nada && [ ! -f "$B/alert.state" ]'

mundo_sano; mkdir "$B/.alert.lock"; touch -d "@$NOW" "$B/.alert.lock"; ronda
si "C5 con otra pasada en curso no hago nada" 'nada && [ ! -f "$B/alert.state" ]'
rmdir "$B/.alert.lock"

mundo_sano; ronda; avanza; rm -f "$M/nodes.json"; echo 000 > "$M/readyz"; printf '10.0.0.2\tSentinel 2.0.0\teye\t1\n10.0.0.3\tSentinel 2.0.0\teye\t1\n' > "$B/peers.tsv"; caer 10.0.0.3; ronda
si "C6 rqlite caido: sigue vigilando con peers.tsv" 'hay "sentinelB (10.0.0.3)" && ! hay "rqlite"'
avanza; ronda
si "C6 y a la segunda pasada avisa del rqlited propio" 'hay "el rqlited de sentinelW no responde"'
rm -f "$B/peers.tsv"

mundo_sano; ronda; avanza; rm -f "$M/nodes.json"; conf "EXTRA_NODES="; ronda
si "C7 sin lista de flota: los nodos conservan su estado" '[ "$(estado 10.0.0.2)" = ok ] && [ "$(estado 10.0.0.3)" = ok ]'

mundo_sano; conf 'EXTRA_CHECKS="a=tcp://10.0.0.5:1,b|c=http://x,d=ftp://y,sinigual"'; ronda
si "C8 EXTRA_CHECKS raro: lo valido se vigila, lo mal escrito se ignora" '[ "$(estado ex:a)" = mal ] && hay "a (tcp://10.0.0.5:1)" && [ -z "$(estado ex:d)" ] && [ -z "$(estado ex:sinigual)" ] && ! grep -q "^ex:b" "$B/alert.state"'

mundo_sano; ronda; ANTES_C9=$(cat "$B/alert.state"); LAT_C9=$(wc -l < "$M/execute.log")
avanza; caer 10.0.0.3; printf 'sentinelA|mal\n' > "$B/bat.state"; touch -d "@$((NOW - 300))" "$B/alert.state"
DRYOUT=$( cd "$T" && PATH="$BIN:$PATH" MUNDO="$M" HOME="$H" SENTINEL_BASE="$B" SENTINEL_NOW="$NOW" SENTINEL_NOJITTER=1 DRY=1 "$SHX" "$V2/Sentinel-Alert.sh" 2>&1 )
si "C9 DRY imprime pero no escribe latido ni estado ni borra bat.state" 'printf "%s" "$DRYOUT" | grep -q "sentinelB (10.0.0.3)" && [ "$(wc -l < "$M/execute.log")" = "$LAT_C9" ] && [ "$(cat "$B/alert.state")" = "$ANTES_C9" ] && [ -f "$B/bat.state" ]'
ronda
si "C9 y la pasada real siguiente avisa de verdad" 'hay "sentinelB (10.0.0.3)"'

mundo_sano; ronda; avanza; caer 10.0.0.3; ronda; ANTES_C10=$(cat "$B/alert.state")
avanza; caer 10.0.0.2; : > "$M/matar_en_tg"; ronda
si "C10 SIGTERM a mitad de envio: alert.state queda como estaba" '[ "$(cat "$B/alert.state")" = "$ANTES_C10" ] && [ ! -d "$B/.alert.lock" ]'
avanza; ronda
si "C10 y la pasada siguiente avisa solo lo nuevo, con nombre" 'hay "sentinelA (10.0.0.2)" && ! hay "sentinelB"'

mundo_sano; ronda; avanza; fitness 10.0.0.2 sentinelA 1 2000000 1; caer 10.0.0.3; ronda
si "C11 si otro mejor tambien se cree Wheel, me callo" 'nada && [ "$(estado 10.0.0.3)" = ok ]'
mundo_sano; ronda; avanza; fitness 10.0.0.2 sentinelA 1 800000 1; caer 10.0.0.3; ronda
si "C11b si el otro lleva menos en pie, aviso yo" 'hay "sentinelB (10.0.0.3)"'
mundo_sano; ronda; avanza; fitness 10.0.0.2 sentinelA 0 2000000 1; caer 10.0.0.3; ronda
si "C11c si el otro es un telefono (no estable), aviso yo" 'hay "sentinelB (10.0.0.3)"'
mundo_sano; ronda; avanza; : > "$M/falla1.10.0.0.3"; ronda
si "C11d un sondeo suelto perdido no es una caida" 'nada && [ "$(estado 10.0.0.3)" = ok ]'

mundo_sano; touch -d "@$((NOW - 100))" "$B/wheel.state"; caer 10.0.0.3; ronda
si "C12 recien coronado: callo un ciclo" 'nada && [ ! -f "$B/alert.state" ]'

mundo_sano; ronda; avanza; mkdir "$B/.alert.lock"; touch -d "@$((NOW - 700))" "$B/.alert.lock"; caer 10.0.0.3; ronda
si "C13 cerrojo huerfano de mas de 10 min: se libera y se avisa" 'hay "sentinelB (10.0.0.3)" && [ ! -d "$B/.alert.lock" ]'

mundo_sano; conf "RECORDATORIO_H=0"; ronda; avanza; caer 10.0.0.3; ronda; avanza 90000; ronda
si "C14 RECORDATORIO_H=0 desactiva el recordatorio" 'nada'

mundo_sano; ronda; avanza; caer 10.0.0.3; ronda
si "C15 el token del bot no viaja en la linea de comandos" 'hay "sentinelB" && ! hay "token mal pasado"'

# ---------------------------------------------------------------- latido
echo "== Latido hacia la EC2"
latir(){ ( cd "$T" && PATH="$BIN:$PATH" MUNDO="$M" HOME="$H" SENTINEL_BASE="$B" "$SHX" "$V2/Sentinel-Latido.sh" > "$T/salida" 2>&1 ); }
mundo_sano; rm -f "$M/ssh.entrada"; latir
si "L1 sin LATIDO_DESTINO no hace nada" '[ ! -f "$M/ssh.entrada" ]'
conf "LATIDO_DESTINO=ubuntu@ec2.test
LATIDO_LLAVE=$H/llave"; : > "$H/llave"
printf '%s,"sentinelW",0' "$NOW" > "$M/vigia"; latir
si "L2 manda nodo, ultima pasada, Wheel y pendientes" '[ "$(cat "$M/ssh.entrada")" = "sentinelW $NOW sentinelW 0 200" ] && [ "$(cat "$M/ssh.destino")" = "ubuntu@ec2.test" ]'
rm -f "$M/vigia"; latir
si "L3 sin pasada registrada manda 0 y -" '[ "$(cat "$M/ssh.entrada")" = "sentinelW 0 - 0 200" ]'
printf '1,"x;rm -rf",9999999' > "$M/vigia"; latir
si "L3b basura en la tabla no sale tal cual" '[ "$(cat "$M/ssh.entrada")" = "sentinelW 1 - 9999 200" ]'
printf '%s,"sentinelW",0' "$NOW" > "$M/vigia"; echo 503 > "$M/readyz"; latir
si "L3c con mi rqlite sin lider, el latido lo dice (503)" '[ "$(cat "$M/ssh.entrada")" = "sentinelW $NOW sentinelW 0 503" ]'
echo 000 > "$M/readyz"; latir
si "L3d con mi rqlited caido, el latido lo dice (000)" '[ "$(cat "$M/ssh.entrada")" = "sentinelW $NOW sentinelW 0 000" ]'
echo 200 > "$M/readyz"

E="$T/ec2"; mkdir -p "$E"; cp "$V2/latido-ec2/latido-recibir.sh" "$V2/latido-ec2/latido-vigilar.sh" "$E/"
printf 'BOT_TOKEN=x\nCHAT_ID=1\n' > "$E/telegram.conf"
recibir(){ printf '%s\n' "$2" | "$SHX" "$E/latido-recibir.sh" "$1" 2>&1; }
r=$(recibir sentinel014 "sentinel014 1794000000 sentinel016 0 200")
si "L4 la EC2 acepta una linea valida" '[ "$r" = ok ] && grep -q " sentinel014 1794000000 sentinel016 0 200$" "$E/sentinel014.latido"'
antes=$(cat "$E/sentinel014.latido")
for mala in "sentinel016 1794000000 sentinel016 0 200" "sentinel014 1794000000 x;id 0 200" "sentinel014 1794000000 sentinel016 0 200 extra" "sentinel014 abc sentinel016 0 200" "sentinel014 01794000000 sentinel016 0 200" "sentinel014 1794000000 sentinel016 08 200" "sentinel014 1794000000 sentinel016 0" ""; do
  r=$(recibir sentinel014 "$mala")
  [ "$r" = "linea invalida" ] || no "L5 acepto: [$mala]"
done
si "L5 la EC2 rechaza otro nodo, inyecciones y formatos raros" '[ "$(cat "$E/sentinel014.latido")" = "$antes" ]'
r=$(recibir "../x" "sentinel014 1 a 0 200")
si "L6 el nombre de la llave tambien se valida" '[ "$r" = "nodo invalido" ]'

vigilar(){ : > "$M/telegram.log"; ( cd "$T" && PATH="$BIN:$PATH" MUNDO="$M" SENTINEL_NOW="$NOW" "$SHX" "$E/latido-vigilar.sh" > "$T/salida" 2>&1 ); MSG=$(cat "$M/telegram.log"); }
latido(){ printf '%s %s %s %s %s %s\n' "$2" "$1" "$3" "$4" "${5:-0}" "${6:-200}" > "$E/$1.latido"; }  # nodo recv ts_avisos wheel pend readyz
rm -f "$E"/*.latido "$E/vigilar.state"
vigilar
si "V0 recien montado, sin latidos todavia: aun no avisa" 'nada'
avanza 900; vigilar
si "V0 pasados 15 min sin ningun latido: avisa" 'hay "no ha llegado ningún latido"'
latido sentinel014 $((NOW-60)) $((NOW-200)) sentinel016; latido sentinel016 $((NOW-30)) $((NOW-200)) sentinel016; vigilar
si "V1 todo al dia: avisa la vuelta y nada mas" 'hay "la casa vuelve a dar señales" && ! hay "avisos de la red"'
avanza; latido sentinel014 $((NOW-60)) $((NOW-200)) sentinel016; latido sentinel016 $((NOW-30)) $((NOW-200)) sentinel016; vigilar
si "V1 y luego silencio" 'nada'
avanza 1200; vigilar
si "V2 sin latidos 20 min: la casa no da senales" 'hay "la casa no da señales desde hace" && hay "Último latido: sentinel016"'
avanza; vigilar
si "V2 una vez" 'nada'
avanza 86400; vigilar
si "V2 recordatorio" 'hay "Recordatorio: " && hay "la casa no da señales"'
latido sentinel014 $((NOW-10)) $((NOW-100)) sentinel016; avanza 10; vigilar
si "V2 vuelve con la duracion" 'hay "la casa vuelve a dar señales (tras 1 d"'
latido sentinel016 $((NOW-5000)) $((NOW-5000)) sentinel016; avanza; latido sentinel014 $((NOW-10)) $((NOW-100)) sentinel016; vigilar
si "V7 un mini-PC sin latir no es la casa caida" 'nada'
avanza; latido sentinel014 $((NOW-10)) $((NOW-2000)) sentinel016; vigilar
si "V3 33 min sin pasada (un relevo puede tardar eso): aun no" 'nada'
avanza; latido sentinel014 $((NOW-10)) $((NOW-3000)) sentinel016; vigilar
si "V3 llegan latidos pero el Wheel lleva 50 min sin pasar: avisa" 'hay "última pasada registrada de los avisos (Wheel sentinel016)" && hay "mirar el cron o el timer de sentinel016"'
avanza; latido sentinel014 $((NOW-10)) $((NOW-60)) sentinel016; vigilar
si "V3 vuelven" 'hay "los avisos de la red vuelven a correr (Wheel sentinel016)"'
avanza; latido sentinel014 $((NOW-10)) $((NOW-3000)) sentinel016 0 503; vigilar
si "V3b sin lider en rqlite no culpa al cron del Wheel" 'hay "rqlite no tiene líder visto desde: sentinel014 (readyz 503)" && ! hay "mirar el cron"'
avanza; latido sentinel014 $((NOW-10)) $((NOW-60)) sentinel016; vigilar
avanza; latido sentinel014 $((NOW-10)) $((NOW-3000)) sentinel014 0 000; vigilar
si "V3c el Wheel late y su rqlited esta caido: lo dice" 'hay "El rqlited de sentinel014 no responde (readyz 000)"'
avanza; latido sentinel014 $((NOW-10)) $((NOW-60)) sentinel014; vigilar
avanza; latido sentinel014 $((NOW-10)) $((NOW-3000)) sentinel014 0 200; latido sentinel016 $((NOW-20)) $((NOW-3000)) sentinel014 0 000; vigilar
si "V3d el Wheel tiene rqlite sano: la culpa es su cron, aunque otro tenga el suyo caido" 'hay "No está pasando: mirar el cron o el timer de sentinel014" && hay "readyz malo en: sentinel016 (readyz 000)"'
avanza; latido sentinel014 $((NOW-10)) $((NOW-60)) sentinel016; latido sentinel016 $((NOW-20)) $((NOW-60)) sentinel016; vigilar
avanza; latido sentinel014 $((NOW-10)) $((NOW-60)) sentinel016 3; vigilar
si "V4 pendientes en una pasada: aun no" 'nada'
avanza 600; latido sentinel014 $((NOW-10)) $((NOW-60)) sentinel016 3; vigilar
si "V4 pendientes 10 min: avisa" 'hay "no consigue mandar sus avisos a Telegram (3 pendientes"'
avanza; latido sentinel014 $((NOW-10)) $((NOW-60)) sentinel016 0; echo "vuelven a llegar a Telegram" > "$M/tg_falla_si"; vigilar
si "V5 si el envio falla no da la vuelta por hecha" 'grep -q "^telegram mal" "$E/vigilar.state"'
avanza; rm -f "$M/tg_falla_si"; latido sentinel014 $((NOW-10)) $((NOW-60)) sentinel016 0; vigilar
si "V5 y la reintenta" 'hay "vuelven a llegar a Telegram" && grep -q "^telegram ok" "$E/vigilar.state"'
rm -f "$E"/*.latido "$E/vigilar.state"; latido sentinel014 $((NOW-10)) $((NOW-60)) sentinel016; vigilar
avanza 1200
for i in 1 2 3; do
  : > "$M/telegram.log"; ( cd "$T" && PATH="$BIN:$PATH" MUNDO="$M" SENTINEL_NOW="$NOW" RECORDATORIO_H=0 "$SHX" "$E/latido-vigilar.sh" >/dev/null 2>&1 ); avanza 90000
done
MSG=$(cat "$M/telegram.log")
si "V8 RECORDATORIO_H=0 en la EC2 tambien desactiva el recordatorio" '! hay "Recordatorio"'

# ---------------------------------------------------------------- eleccion
echo "== Eleccion: quorum y puntuacion"
elegir(){ # $1=self; usa el mundo actual; deja la salida en $EL
  EL=$( cd "$T" && PATH="$BIN:$PATH" MUNDO="$M" gawk -v self="$1" -v port=8181 -v token=t \
        -v peers="$T/peers.tsv" -v state="$T/ws" -v rqlite="${2-http://127.0.0.1:4001}" -v debug=1 \
        -v rqcred="${RQCRED_E:-}" -f "$V2/Sentinel-Wheel.awk" 2>&1 )
}
rm -f "$M"/nodo.* "$T/ws" "$T/ws.miss" "$T/ws.ip" "$T/peers.tsv"; : > "$T/peers.tsv"
L=""; for i in 1 2 3 4 5 6 7 8 9 10 11; do L="$L 10.1.0.$i:true:false"; done; nodos_json $L
fitness 10.1.0.1 nodo01; cp "$M/nodo.10.1.0.1" "$M/nodo.127.0.0.1"
for i in 2 3 4 5; do fitness 10.1.0.$i nodo0$i; done
printf 'nodo09\n' > "$T/ws"
elegir nodo01
si "E1 me veo a mi + 4 de 11: NO decide (antes se contaba dos veces y pasaba)" 'printf "%s" "$EL" | grep -q "solo veo 5 de 11"'
si "E1 y no toca el Wheel" '[ "$(cat "$T/ws")" = nodo09 ]'
fitness 10.1.0.6 nodo06; elegir nodo01
si "E1 con 6 de 11 si decide" 'printf "%s" "$EL" | grep -qE "Wheel: nodo09 -> |el Wheel \(nodo09\) no responde"'

rm -f "$M"/nodo.* "$T/ws.miss"; fitness 10.1.0.1 nodo01; cp "$M/nodo.10.1.0.1" "$M/nodo.127.0.0.1"
nodos_json 10.1.0.1:true:true 10.1.0.2:true:true; printf 'nodo02\n' > "$T/ws"
elegir nodo01
si "E2 solo me veo a mi (con 2 en la flota): respeta al Wheel" 'printf "%s" "$EL" | grep -q "solo me veo a mi mismo" && [ "$(cat "$T/ws")" = nodo02 ]'

rm -f "$M"/nodo.* "$T/ws.miss"
fitness 10.1.0.1 nodoB 1 900000 1 1 0; cp "$M/nodo.10.1.0.1" "$M/nodo.127.0.0.1"
fitness 10.1.0.2 nodoA 1 900000 1 1 0
echo 0.900 > "$M/rtt.10.1.0.2"; echo 0.001 > "$M/rtt.10.1.0.1"; echo 0.001 > "$M/rtt.127.0.0.1"
nodos_json 10.1.0.1:true:true 10.1.0.2:true:true 10.1.0.3:true:false
fitness 10.1.0.3 nodoC
printf 'nodoB\n' > "$T/ws"
elegir nodoB
si "E3 dos Wheels a la vez: el empate no lo gana quien puntua (el RTT ya no cuenta)" 'printf "%s" "$EL" | grep -q "Wheel: nodoB -> nodoA"'
printf 'nodoA\n' > "$T/ws"; rm -f "$T/ws.miss"; elegir nodoA
si "E3 y nodoA, puntuando desde su sitio, coincide" 'printf "%s" "$EL" | grep -q "Wheel sigue siendo nodoA"'
rm -f "$M"/rtt.*

rm -f "$M"/nodo.* "$T/ws" "$T/ws.miss" "$M/nodes.json"
fitness 127.0.0.1 nodo01; printf '10.1.0.2\tx\teye\t1\n10.1.0.3\tx\teye\t1\n' > "$T/peers.tsv"
fitness 10.1.0.2 nodo02
elegir nodo01 ""
si "E4 sin rqlite y sin mi IP en la lista: me cuenta una vez (2 de 3) y decide" 'printf "%s" "$EL" | grep -q "veo 2 nodos distintos de 3" && printf "%s" "$EL" | grep -q "Wheel: (ninguno) -> "'
rm -f "$T/ws" "$T/ws.miss"; printf '10.1.0.2\tx\teye\t1\n10.1.0.3\tx\teye\t1\n10.1.0.4\tx\teye\t1\n' > "$T/peers.tsv"
elegir nodo01 ""
si "E4b yo + 1 de 3 sin mi IP en la lista: el denominador me incluye (2 de 4) y no decide" 'printf "%s" "$EL" | grep -q "solo veo 2 de 4"'

rm -f "$M"/nodo.* "$T/ws.miss"; : > "$T/peers.tsv"
nodos_json 10.1.0.1:true:true 10.1.0.2:true:false 10.1.0.3:true:false
fitness 10.1.0.1 nodo01; cp "$M/nodo.10.1.0.1" "$M/nodo.127.0.0.1"; fitness 10.1.0.2 nodo02
printf 'nodo03\n' > "$T/ws"
elegir nodo01
si "E5 el Wheel falta UNA ronda: no se le releva" 'printf "%s" "$EL" | grep -q "ronda 1 de 2" && [ "$(cat "$T/ws")" = nodo03 ]'
printf '10.1.0.3\n' > "$T/ws.ip"; nodos_json 10.1.0.1:true:true 10.1.0.2:true:false 10.1.0.3:true:false
elegir nodo01
si "E5b a la segunda ronda, si rqlite SI lo alcanza, la ceguera es mia: no se releva" 'printf "%s" "$EL" | grep -q "la ceguera es mia" && [ "$(cat "$T/ws")" = nodo03 ]'
printf '1\n' > "$T/ws.miss"; nodos_json 10.1.0.1:true:true 10.1.0.2:true:false 10.1.0.3:false:false
elegir nodo01
si "E5c si rqlite tampoco lo alcanza: procede el relevo" 'printf "%s" "$EL" | grep -q "procede el relevo" && [ "$(cat "$T/ws")" != nodo03 ]'

rm -f "$M"/nodo.* "$T/ws" "$T/ws.miss" "$T/ws.ip" "$T/ws.self"; : > "$T/peers.tsv"
L=""; for i in 1 2 3 4 5 6 7 8 9 10 11; do L="$L 10.1.0.$i:true:false"; done; nodos_json $L
fitness 10.1.0.1 nodo01; cp "$M/nodo.10.1.0.1" "$M/nodo.127.0.0.1"
for i in 2 3 4 5 6; do fitness 10.1.0.$i nodo0$i; done
elegir nodo01
si "E6 al contestar por mi IP de LAN se recuerda (ws.self)" '[ "$(cat "$T/ws.self" 2>/dev/null)" = 10.1.0.1 ]'
rm -f "$M/nodo.10.1.0.1" "$T/ws" "$T/ws.miss"; elegir nodo01
si "E6 si luego solo contesto por 127.0.0.1, cuento 6 de 11 (no de 12) y decido" 'printf "%s" "$EL" | grep -q "veo 6 nodos distintos de 11" && printf "%s" "$EL" | grep -q "Wheel: (ninguno) -> "'

# ---------------------------------------------------------------- credenciales
# Fase 0 de la contrasena de rqlite. El fichero de credenciales va en la ruta por
# defecto ($HOME/.config/rqlite/sentinel.curlrc, con HOME=$H). "exige" pone el
# rqlite falso en modo -auth: sin -K a un fichero con esa linea, 401 y cuerpo
# vacio (salvo /readyz, abierto). Claves inventadas, solo para el banco.
echo "== Credenciales de rqlite"
CRED="$H/.config/rqlite/sentinel.curlrc"
CB="PruebaBuena0123456789abcdefghijk"; CV="PruebaVieja0123456789abcdefghijk"
clave(){ mkdir -p "$H/.config/rqlite"; printf 'user = "sentinel:%s"\n' "$1" > "$CRED"; chmod 600 "$CRED"; }
exige(){ printf 'user = "sentinel:%s"\n' "$1" > "$M/rq_clave"; }
sin_cred(){ rm -f "$CRED"; }
a_rqlite(){ grep ':4001' "$M/argv.log"; }      # las peticiones a rqlite
con_k(){ grep -F -- "-K $CRED " ; }            # las que llevan el fichero

mundo_sano; clave "$CB"; exige "$CB"; ronda; avanza; caer 10.0.0.3; : > "$M/argv.log"; ronda
si "K1 con fichero: cada peticion a rqlite lleva -K con su ruta" '[ "$(a_rqlite | wc -l)" -ge 5 ] && [ "$(a_rqlite | con_k | wc -l)" = "$(a_rqlite | wc -l)" ]'
si "K1 y las de Telegram y /fitness no" 'hay "sentinelB (10.0.0.3)" && grep -q ":8181/fitness" "$M/argv.log" && grep "chat_id=" "$M/argv.log" | grep -q -- "-K -" && ! grep -F -- "$CRED" "$M/argv.log" | grep -qv ":4001"'
si "K1 rqlite acepta la clave: latido apuntado y credenciales en orden" 'grep -q "\"avisos\", $NOW, \"sentinelW\", 0" "$M/execute.log" && [ "$(estado au:sentinelW)" = ok ] && ! grep -q "latido FALLO" "$B/alert.log"'
si "K2 la clave no sale en argv ni en los registros" '! grep -qs -e "$CB" "$M/argv.log" "$M/telegram.log" "$B/alert.log" "$B/alert.state" "$M/execute.log"'

mundo_sano; sin_cred; ronda; avanza; caer 10.0.0.3; : > "$M/argv.log"; ronda
si "K3 sin fichero: nada lleva -K a un fichero y todo funciona como siempre" 'hay "sentinelB (10.0.0.3)" && [ "$(a_rqlite | wc -l)" -ge 5 ] && ! grep -qE -- "-K [^-]" "$M/argv.log"'

mundo_sano; clave "$CV"; ronda; avanza; exige "$CB"; ronda
si "K4 401 en /nodes y /db/query: avisa de la contrasena del Wheel" 'hay "rqlite rechaza la contraseña de:" && hay "sentinelW: rqlite rechaza sus credenciales (401 en /nodes, /db/query)" && hay "sentinel.curlrc"'
si "K4 y no lo confunde con 'sin lider' ni con 'datos no llegan'" '! hay "sin líder" && ! hay "datos no llegan" && ! hay "la base no recibe"'
si "K4 el latido rechazado queda en alert.log" 'grep -q "latido FALLO http=401" "$B/alert.log"'
for i in 1 2 3 4; do avanza; ronda; done
si "K4 varias pasadas igual: un solo aviso, y ninguno de lider, datos, base ni caidas" '[ "$(grep -c "au_mal ok" "$B/alert.log")" = 1 ] && ! grep -q "cl_mal\|dt_mal\|df_mal\|caido" "$B/alert.log"'
avanza; clave "$CB"; datos_frescos; ronda
si "K5 al arreglar la clave: aviso de vuelta" 'hay "rqlite vuelve a aceptar la contraseña de:" && hay "sentinelW tras 25 min" && [ "$(estado au:sentinelW)" = ok ]'
avanza; datos_frescos; ronda
si "K5 una sola vez" 'nada'

mundo_sano; sin_cred; ronda; avanza; touch "$M/readyz401"; ronda
si "K4b /readyz con 401: lo cuenta la contrasena" 'hay "sentinelW: rqlite rechaza sus credenciales (401 en /readyz)"'
avanza; ronda; avanza; ronda
si "K4b y no es 'sin lider': __cl__ no se observa y conserva su estado" '! grep -q "cl_mal" "$B/alert.log" && [ "$(estado __cl__)" = ok ]'

mundo_sano; ronda; CONG=$NOW
for i in 1 2 3 4; do avanza; datos "$CONG" "$((CONG-200))" "$((CONG-100))"; ronda; done
si "K6 base sin datos nuevos con mi rqlite sano: dentro de la gracia, silencio" '! grep -qs "df_mal" "$B/alert.log"'
avanza; datos "$CONG" "$((CONG-200))" "$((CONG-100))"; ronda
si "K6 pasada la gracia avisa de la base, con la edad del ultimo dato" 'hay "la base no recibe datos nuevos de ningún nodo" && hay "última temperatura hace 25 min; última batería hace 26 min" && hay "réplica de sentinelW"'
avanza; datos "$CONG" "$((CONG-200))" "$((CONG-100))"; ronda
si "K6 una sola vez, y sin culpar a cada nodo (D2)" 'nada && [ "$(grep -c "df_mal ok" "$B/alert.log")" = 1 ] && ! grep -q "datos no llegan" "$B/alert.log"'
avanza; datos_frescos; ronda
si "K6 cuando llegan, la base vuelve (y no 'vuelven los datos de' cada nodo)" 'hay "la base vuelve a recibir datos" && ! hay "vuelven a llegar los datos de"'
avanza; datos_frescos; ronda
si "K6 y la vuelta no se repite" 'nada'
mundo_sano; ronda; : > "$M/datos"; for i in 1 2 3; do avanza; ronda; done
si "K6c tablas vacias con nodos que si escribian: 'nunca'" 'hay "última temperatura nunca; última batería nunca"'
mundo_sano; : > "$M/datos"; for i in 1 2 3 4; do ronda; avanza; done
si "K6d nadie escribio nunca (sin claves dt:): no se opina de la base" '! grep -qs "df_mal" "$B/alert.log" && [ -z "$(estado df:flota)" ]'

mundo_sano; conf "LATIDO_DESTINO=ubuntu@ec2.test
LATIDO_LLAVE=$H/llave"; : > "$H/llave"; printf '%s,"sentinelW",0' "$NOW" > "$M/vigia"
clave "$CB"; exige "$CB"; latir
si "K7 latido con la clave buena: pregunta con -K y manda 200" '[ "$(cat "$M/ssh.entrada")" = "sentinelW $NOW sentinelW 0 200" ] && [ "$(a_rqlite | wc -l)" = 2 ] && [ "$(a_rqlite | con_k | wc -l)" = 2 ]'
clave "$CV"; latir
si "K7 consulta rechazada (401) con /readyz abierto: el quinto campo es 401" '[ "$(cat "$M/ssh.entrada")" = "sentinelW 0 - 0 401" ]'
sin_cred; rm -f "$M/rq_clave"; : > "$M/argv.log"; latir
si "K7 sin fichero: el latido pregunta sin -K, como siempre" '[ "$(cat "$M/ssh.entrada")" = "sentinelW $NOW sentinelW 0 200" ] && ! grep -qE -- "-K [^-]" "$M/argv.log"'

rm -f "$E"/*.latido "$E/vigilar.state"
latido sentinel014 $((NOW-10)) $((NOW-60)) sentinel016; latido sentinel016 $((NOW-20)) $((NOW-60)) sentinel016; vigilar
avanza; latido sentinel014 $((NOW-10)) $((NOW-3000)) sentinel016 0 200; latido sentinel016 $((NOW-20)) 0 - 0 401; vigilar
si "K8 el Wheel late con 401 y su pasada es vieja: credenciales, no 'sin lider' ni el cron" 'hay "rqlite rechaza las credenciales de sentinel016 (401)" && hay "Revisar ~/.config/rqlite/sentinel.curlrc en sentinel016" && ! hay "líder" && ! hay "mirar el cron"'
avanza; latido sentinel014 $((NOW-10)) $((NOW-60)) sentinel016; latido sentinel016 $((NOW-20)) $((NOW-60)) sentinel016; vigilar
avanza; latido sentinel014 $((NOW-10)) $((NOW-3000)) sentinel014 0 200; latido sentinel016 $((NOW-20)) 0 - 0 401; vigilar
si "K8b otro nodo con 401: se nombra como credenciales, no como readyz" 'hay "mirar el cron o el timer de sentinel014" && hay "Además, rqlite rechaza las credenciales de: sentinel016 (401)" && ! hay "readyz malo" && ! hay "readyz 401"'
rm -f "$E/vigilar.state"
avanza; latido sentinel014 $((NOW-10)) 0 - 0 401; latido sentinel016 $((NOW-20)) 0 - 0 401; vigilar
avanza 2400; latido sentinel014 $((NOW-10)) 0 - 0 401; latido sentinel016 $((NOW-20)) 0 - 0 401; vigilar
si "K8c ninguna pasada legible y 401 en los latidos: lo dice" 'hay "sentinel_vigia vacía o ilegible" && hay "rqlite rechaza las credenciales de: sentinel014 sentinel016 (401)" && ! hay "líder"'

# Eleccion: credenciales por RUTA (-v rqcred, -K en el curl de /nodes) y 401.
rm -f "$M"/nodo.* "$M/argv.log" "$M/rq_clave" "$T/ws" "$T/ws.miss" "$T/ws.ip" "$T/ws.self"; : > "$T/peers.tsv"
L=""; for i in 1 2 3 4 5 6 7 8 9 10 11; do L="$L 10.1.0.$i:true:false"; done; nodos_json $L
fitness 10.1.0.1 nodo01; cp "$M/nodo.10.1.0.1" "$M/nodo.127.0.0.1"
for i in 2 3 4 5 6; do fitness 10.1.0.$i nodo0$i; done
clave "$CB"; exige "$CB"; RQCRED_E="$CRED" elegir nodo01
si "K9 con rqcred el /nodes de la eleccion lleva -K (y el /fitness no)" 'grep "/nodes?" "$M/argv.log" | grep -qF -- "-K $CRED " && ! grep ":8181/fitness" "$M/argv.log" | grep -qF -- "$CRED"'
si "K9 la linea HTTP: no se cuela en las IP: 11 candidatos y decide" 'printf "%s" "$EL" | grep -q "rqlite aporto 11 candidatos" && printf "%s" "$EL" | grep -q "Wheel: (ninguno) -> "'
rm -f "$M/rq_clave" "$T/ws" "$T/ws.miss" "$T/ws.self"; : > "$M/argv.log"; RQCRED_E="" elegir nodo01
si "K9 sin rqcred, sin -K" 'grep -q "/nodes?" "$M/argv.log" && ! grep -qE -- "-K [^-]" "$M/argv.log"'
# elect.sh de verdad: calcula la ruta, la pasa y deja el 401 en elect.log.
EB="$T/elect"; mkdir -p "$EB"; cp "$V2/Sentinel-Wheel.awk" "$EB/"; cp "$B/fleet.token" "$EB/"
printf 'NAME=nodo01\nPORT=8181\nRQLITE=http://127.0.0.1:4001\n' > "$EB/sentinel.conf"
: > "$EB/peers.tsv"; for i in 1 2 3 4 5 6 7 8 9 10 11; do printf '10.1.0.%s\tSentinel 2.0.0\teye\t1\n' "$i" >> "$EB/peers.tsv"; done
printf 'nodo09\n' > "$EB/wheel.state"; rm -f "$M"/nodo.*
fitness 10.1.0.1 nodo01; cp "$M/nodo.10.1.0.1" "$M/nodo.127.0.0.1"; for i in 2 3 4 5; do fitness 10.1.0.$i nodo0$i; done
clave "$CV"; exige "$CB"; : > "$M/argv.log"
elect(){ ( cd "$T" && PATH="$BIN:$PATH" MUNDO="$M" HOME="$H" SENTINEL_BASE="$EB" SENTINEL_NOJITTER=1 "$SHX" "$V2/service/elect.sh" > /dev/null 2>&1 ); }
elect
si "K9 elect.sh pasa la ruta por defecto: /nodes con -K" 'grep "/nodes?" "$M/argv.log" | grep -qF -- "-K $CRED "'
si "K9 con 401 en /nodes, elect.log lo dice (sin debug)" 'grep -q "\[wheel\] rqlite rechaza las credenciales (401)" "$EB/elect.log"'
si "K9 y con peers.tsv de toda la flota no se corona por ello" 'grep -q "solo veo 5 de 11" "$EB/elect.log" && [ "$(cat "$EB/wheel.state")" = nodo09 ] && [ "$(wc -l < "$EB/peers.tsv")" = 11 ]'
# WheelAlcanzable: con 200 opina (control); con 401 no opina (-1).
rm -f "$M"/nodo.* "$T/ws.self"; printf '10.1.0.1\tx\teye\t1\n10.1.0.2\tx\teye\t1\n10.1.0.3\tx\teye\t1\n' > "$T/peers.tsv"
nodos_json 10.1.0.1:true:true 10.1.0.2:true:false 10.1.0.3:true:false
fitness 10.1.0.1 nodo01; cp "$M/nodo.10.1.0.1" "$M/nodo.127.0.0.1"; fitness 10.1.0.2 nodo02
printf 'nodo03\n' > "$T/ws"; printf '1\n' > "$T/ws.miss"; printf '10.1.0.3\n' > "$T/ws.ip"
clave "$CB"; exige "$CB"; RQCRED_E="$CRED" elegir nodo01
si "K9 control: con la clave buena rqlite ve al Wheel y no se releva" 'printf "%s" "$EL" | grep -q "la ceguera es mia" && [ "$(cat "$T/ws")" = nodo03 ]'
printf '1\n' > "$T/ws.miss"; clave "$CV"; RQCRED_E="$CRED" elegir nodo01
si "K9 con 401 la segunda opinion no vale (-1) y lo dice" 'printf "%s" "$EL" | grep -q "rqlite rechaza las credenciales (401): sin segunda opinion" && printf "%s" "$EL" | grep -q "sin responder (sin segunda opinion): procede el relevo"'
sin_cred
si "K2 en todo el banco la clave nunca va en la linea de comandos" '[ -s "$ARGV_TODO" ] && ! grep -q -e "$CB" -e "$CV" "$ARGV_TODO" && ! grep -qs -e "$CB" -e "$CV" "$EB/elect.log"'

echo
echo "Resultado: $PASS pasan, $FAIL fallan"
[ "$FAIL" -eq 0 ]
