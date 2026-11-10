#!/bin/sh
# Sentinel v2 - Banco de pruebas de los avisos y del quorum de la eleccion.
#
# No toca la red ni Telegram: pone delante un `curl` falso que contesta desde un
# "mundo" de ficheros (que nodos responden, que dice rqlite, si Telegram acepta el
# mensaje) y un `sleep` que no espera. El reloj se fija con SENTINEL_NOW, asi que
# se pueden simular dias en segundos.
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
printf 'BOT_TOKEN="x"\nCHAT_ID="1"\n' > "$H/PRC_Thermal/thermal-guard.conf"
printf '%s\n' "0123456789abcdef0123456789abcdef0123" > "$B/fleet.token"

# ---------------------------------------------------------------- curl falso
cat > "$BIN/curl" <<'EOF'
#!/bin/sh
M="$MUNDO"; url=""; w=""; o=""; q=""; text=""; data=""; cfg=""
while [ $# -gt 0 ]; do
  case "$1" in
    -m|--connect-timeout|-H) shift ;;
    -w) shift; w="$1" ;;
    -o) shift; o="$1" ;;
    -d) shift; data="$1" ;;
    -K) shift; [ "$1" = "-" ] && cfg=$(cat) ;;
    --data-urlencode) shift; case "$1" in q=*) q="${1#q=}" ;; text=*) text="${1#text=}" ;; esac ;;
    -s|-G|-XPOST|-k) ;;
    -*) ;;
    *) url="$1" ;;
  esac
  shift
done
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
  */readyz) c=$(cat "$M/readyz" 2>/dev/null || echo 200); printf '%s' "$c"; exit 0 ;;
  */nodes\?*)
    [ -f "$M/nodes.json" ] || exit 7
    # Sin ?timeout=, un nodo atascado deja /nodes colgado >30 s (21/08) y curl corta:
    # el banco lo imita para que quitar el parametro rompa las pruebas.
    case "$url" in *timeout=*) ;; *) exit 28 ;; esac
    # Sin ?nonvoters, rqlite solo da los votantes: el banco lo imita para que quitar
    # el parametro rompa las pruebas.
    case "$url" in *nonvoters*) cat "$M/nodes.json" ;; *) sed 's/{"id":"n-[0-9.]*"[^}]*"voter":false[^}]*},\{0,1\}//g' "$M/nodes.json" ;; esac
    exit 0 ;;
  */db/execute) printf '%s\n' "$data" >> "$M/execute.log"; printf '{"results":[{}]}'; exit 0 ;;
  */db/query)
    case "$q" in
      *"FROM sentinel_vigia"*) if [ -f "$M/vigia" ]; then printf '{"results":[{"columns":["ts","wheel","pendientes"],"values":[[%s]]}]}' "$(cat "$M/vigia")"; else printf '{"results":[{"columns":["ts","wheel","pendientes"]}]}'; fi; exit 0 ;;
      *"sentinel_bateria b JOIN"*) [ -f "$M/bat.json" ] && cat "$M/bat.json" || printf '{"results":[{"columns":["a"]}]}'; exit 0 ;;
      *"FROM sentinel_temp WHERE node=n"*)
        [ -f "$M/datos.caido" ] && exit 7
        printf '{"results":[{"columns":["n","t","b"],"values":['
        sep=""
        for n in $(printf '%s' "$q" | grep -oE "SELECT '[^']*' AS n" | sed "s/SELECT '//; s/' AS n//"); do
          l=$(grep "^$n," "$M/datos" 2>/dev/null | head -1)
          t=$(printf '%s' "$l" | cut -d, -f2); b=$(printf '%s' "$l" | cut -d, -f3)
          printf '%s["%s",%s,%s]' "$sep" "$n" "${t:-null}" "${b:-null}"; sep=","
        done
        printf ']}]}'; exit 0 ;;
    esac
    printf '{"results":[{"error":"no esperado"}]}'; exit 0 ;;
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
# nodos_json "ip:reachable:voter ..."  Con el formato de rqlite v10: un nodo
# inalcanzable NO trae api_addr (rqlite solo lo sabe si el nodo contesta) y si un
# "error". Con $M/nodes.espacios, ademas, espacio tras los dos puntos.
nodos_json(){
  printf '{"nodes":[' > "$M/nodes.json"; sep=""
  for e in "$@"; do
    ip=${e%%:*}; r=${e#*:}; v=${r#*:}; r=${r%%:*}
    if [ "$r" = true ]; then
      printf '%s{"id":"n-%s","api_addr":"http://%s:4001","addr":"%s:4002","voter":%s,"reachable":true,"leader":false,"time":0.0012}' "$sep" "$ip" "$ip" "$ip" "$v" >> "$M/nodes.json"
    else
      printf '%s{"id":"n-%s","addr":"%s:4002","voter":%s,"reachable":false,"leader":false,"error":"dial tcp %s:4002: i/o timeout"}' "$sep" "$ip" "$ip" "$v" "$ip" >> "$M/nodes.json"
    fi
    sep=","
  done
  printf ']}' >> "$M/nodes.json"
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
        -f "$V2/Sentinel-Wheel.awk" 2>&1 )
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

echo
echo "Resultado: $PASS pasan, $FAIL fallan"
[ "$FAIL" -eq 0 ]
