#!/usr/bin/env bash
# Sentinel v2 - Banco de pruebas del control de acceso por token.
# Se separo del Selftest general porque aquel depende de la red y de tiempos, y
# en Windows falla ~30 tests por entorno: no sirve como red de seguridad para un
# cambio de seguridad. Esto es determinista.
# Uso:  sh Sentinel-Selftest-Token.sh <dir_v2> <dir_temporal>
# Sentinel v2 - Banco de pruebas en loopback (Fase 0 + F1 + F2).
# Levanta un nodo aislado, ejerce cada ruta y verifica el comportamiento:
#   - paralelismo real sobre UN SOLO PUERTO (T7/T8)
#   - lista blanca + saneo de entrada, con intentos reales de inyeccion (T5,T6b,T10,T11,T13,T14,T16b)
# No toca la flota ni el servidor v1 ni las BD reales (usa un test.db aislado).

set -u
V2="D:/RED Sentinel/Wheel/Script/v2"
SERVER="$V2/Sentinel-Server2.awk"
WORKER="$V2/Sentinel-Worker.awk"
ALLOW="$V2/Sentinel-Allow.conf"
JOBS="$V2/_test/jobs"
RUN="$V2/_test/Run"
DB="$V2/_test/test.db"
PORT=8181

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
no(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

rm -rf "$V2/_test"; mkdir -p "$JOBS" "$RUN"
# El rol de Wheel ya no se fija por configuracion: lo decide la eleccion. Para
# las pruebas se presiembra el fichero de estado con el nombre del propio nodo.
echo nodoBanco > "$V2/_test/wheel_main.state"

# Stubs de los scripts de Run (simulan ADD_Price_UP / ADD_Products_UP).
cat > "$RUN/ADD_Price_UP"    <<'EOF'
#!/bin/sh
echo "price=$1"
EOF
cat > "$RUN/ADD_Products_UP" <<'EOF'
#!/bin/sh
echo "products=$1"
EOF
chmod +x "$RUN/ADD_Price_UP" "$RUN/ADD_Products_UP"

# BD de prueba con el esquema minimo que usa la ingesta.
sqlite3 "$DB" "CREATE TABLE dwd_wheels(ip TEXT,sentinelname TEXT,netmask TEXT,public TEXT,so TEXT,wheel TEXT);
CREATE TABLE dwd_eyes(ip TEXT,eye INTEGER);
CREATE TABLE dwd_operations(idtrade INTEGER,operation TEXT,price_entry TEXT,price_liquidation TEXT,Total_Fee TEXT,deposit REAL,datemaxmin TEXT);"

TOKEN="tok3nd3pru3ba"
start_server(){ # $1=maxjobs $2=maxqueue $3=jobttl $4=locksecs
  gawk -v Port=$PORT -v jobs="$JOBS" -v worker="$WORKER" -v allow="$ALLOW" -v run="$RUN" \
       -v dbhot="$DB" -v dbsim="$DB" -v token="$TOKEN" -v peers="$V2/_test/peers.tsv" -v maxjobs=$1 \
       -v maxqueue=${2:-64} -v jobttl=${3:-300} -v locksecs=${4:-30} -v name=nodoBanco -v wheelstate="$V2/_test/wheel_main.state" -v electsecs=0 -v debug=0 \
       -f "$SERVER" >"$V2/_test/server.log" 2>&1 &
  SVPID=$!
  for i in $(seq 1 20); do curl -s "http://127.0.0.1:$PORT/version?token=$TOKEN" >/dev/null 2>&1 && return 0; sleep 0.2; done
  return 1
}
stop_server(){ curl -s "http://127.0.0.1:$PORT/stop?token=$TOKEN" >/dev/null 2>&1; sleep 0.5; kill "$SVPID" >/dev/null 2>&1; wait "$SVPID" 2>/dev/null; }

TK="token=$TOKEN"
# Ahora TODA ruta exige token, asi que "denegado" puede ser 401 (token malo)
# o 429 (ya en el castigo tras 3 fallos): ambos significan "no entras".
denied(){ c=$(code "$@"); [ "$c" = "401" ] || [ "$c" = "429" ]; }
# Espera a que expire el castigo para que las pruebas que cuentan intentos
# partan de cero (locksecs=3 en el banco).
reset_lock(){ sleep 4; }
jobid(){ echo "$1" | grep -o '"job":"[^"]*"' | head -1 | sed 's/.*:"//;s/"//'; }
status(){ curl -s "http://127.0.0.1:$PORT/job/$1?$TK" | grep -o '"status":"[^"]*"' | sed 's/.*:"//;s/"//'; }
result(){ curl -s "http://127.0.0.1:$PORT/job/$1?$TK" | grep -o '"result":"[^"]*"' | sed 's/.*:"//;s/"//'; }
poll(){ local t=0; while [ $t -lt $(( $2*5 )) ]; do local s; s=$(status "$1"); [ "$s" = "done" -o "$s" = "rejected" ] && { echo "$s"; return; }; sleep 0.2; t=$((t+1)); done; echo "timeout"; }
code(){ curl -s -o /dev/null -w '%{http_code}' "$@"; }
dbwait(){ local t=0; while [ $t -lt $(( $2*5 )) ]; do local n; n=$(sqlite3 "$DB" "$1" 2>/dev/null); [ "${n:-0}" -ge 1 ] && { echo "$n"; return; }; sleep 0.2; t=$((t+1)); done; echo 0; }

echo "== Sentinel v2 self-test =="
if ! start_server 8; then echo "No arranco el servidor"; cat "$V2/_test/server.log"; exit 1; fi

# ---- F0/F1 ----
curl -s "http://127.0.0.1:$PORT/version?$TK" | grep -q "Sentinel Super 2.0.0" && ok "T1 /version" || no "T1 /version"
curl -s "http://127.0.0.1:$PORT/health?$TK" | grep -q '"inflight"' && ok "T2 /health" || no "T2 /health"
[ "$(code "http://127.0.0.1:$PORT/nope?$TK")" = "404" ] && ok "T3 ruta desconocida 404" || no "T3"

r=$(curl -s -X POST "http://127.0.0.1:$PORT/task?token=$TOKEN&action=whoami"); id=$(jobid "$r")
if [ -n "$id" ]; then st=$(poll "$id" 6); res=$(result "$id"); [ "$st" = "done" ] && [ -n "$res" ] && ok "T4 whoami done (result='$res')" || no "T4 (st=$st res='$res')"; else no "T4 sin job id (r=$r)"; fi

[ "$(code -X POST "http://127.0.0.1:$PORT/task?token=$TOKEN&action=badxyz")" = "400" ] && ok "T5 accion no permitida 400" || no "T5"
[ "$(code -X POST "http://127.0.0.1:$PORT/task?token=$TOKEN&action=sleep")" = "400" ] && ok "T6 sleep sin param 400" || no "T6"
[ "$(code -X POST "http://127.0.0.1:$PORT/task?token=$TOKEN&action=sleep&param=2%3Bwhoami")" = "400" ] && ok "T6b inyeccion en param rechazada 400" || no "T6b"

t0=$(date +%s)
i1=$(jobid "$(curl -s -X POST "http://127.0.0.1:$PORT/task?token=$TOKEN&action=sleep&param=2")")
i2=$(jobid "$(curl -s -X POST "http://127.0.0.1:$PORT/task?token=$TOKEN&action=sleep&param=2")")
i3=$(jobid "$(curl -s -X POST "http://127.0.0.1:$PORT/task?token=$TOKEN&action=sleep&param=2")")
poll "$i1" 12 >/dev/null; poll "$i2" 12 >/dev/null; poll "$i3" 12 >/dev/null
el=$(( $(date +%s) - t0 ))
[ $el -lt 5 ] && ok "T7 3x sleep2 en paralelo: ${el}s (serial ~6s+)" || no "T7 tardo ${el}s"
stop_server

start_server 2 || { echo "no relanzo"; exit 1; }
i1=$(jobid "$(curl -s -X POST "http://127.0.0.1:$PORT/task?token=$TOKEN&action=sleep&param=2")")
i2=$(jobid "$(curl -s -X POST "http://127.0.0.1:$PORT/task?token=$TOKEN&action=sleep&param=2")")
i3=$(jobid "$(curl -s -X POST "http://127.0.0.1:$PORT/task?token=$TOKEN&action=sleep&param=2")")
qd=$(curl -s "http://127.0.0.1:$PORT/health?$TK" | grep -o '"queued":[0-9]*' | sed 's/.*://')
[ "${qd:-0}" -ge 1 ] && ok "T8 cola activa: queued=$qd con cupo=2" || no "T8 queued=$qd"
t0=$(date +%s); poll "$i1" 12 >/dev/null; poll "$i2" 12 >/dev/null; poll "$i3" 12 >/dev/null
el=$(( $(date +%s) - t0 ))
[ $el -ge 3 ] && ok "T8 3ro esperó turno: ${el}s (2 oleadas)" || no "T8 tardo ${el}s"
stop_server

# ---- F2: addprice/addproducts (param IP), ingesta con escape SQL ----
start_server 8 || { echo "no relanzo"; exit 1; }

# T9 addprice con IP valida -> ejecuta el script, resultado contiene la IP
id=$(jobid "$(curl -s -X POST "http://127.0.0.1:$PORT/task?token=$TOKEN&action=addprice&param=10.20.30.40")")
st=$(poll "$id" 6); res=$(result "$id")
[ "$st" = "done" ] && echo "$res" | grep -q "10.20.30.40" && ok "T9 addprice IP valida (result='$res')" || no "T9 (st=$st res='$res')"

# T10 addprice con inyeccion en IP -> 400 (IsIP rechaza ';')
[ "$(code -X POST "http://127.0.0.1:$PORT/task?token=$TOKEN&action=addprice&param=1.2.3.4%3Bwhoami")" = "400" ] && ok "T10 addprice inyeccion IP rechazada 400" || no "T10"

# T11 addprice con octeto fuera de rango -> 400
[ "$(code -X POST "http://127.0.0.1:$PORT/task?token=$TOKEN&action=addprice&param=999.1.1.1")" = "400" ] && ok "T11 addprice octeto>255 rechazado 400" || no "T11"

# T11b addprice con salto de linea (%0a) tras la IP -> 400 (guarda de control chars)
[ "$(code -X POST "http://127.0.0.1:$PORT/task?token=$TOKEN&action=addprice&param=10.20.30.40%0awhoami")" = "400" ] && ok "T11b addprice newline-injection rechazada 400" || no "T11b"

# T12 ingest/eye valido -> fila en dwd_wheels + 3 en dwd_eyes
curl -s -X POST "http://127.0.0.1:$PORT/ingest/eye?token=$TOKEN&ip=10.0.0.5&name=NodeA&netmask=255.255.255.0&public=8.8.8.8&os=Termux&wheel=10.0.0.1&netsentinel=1,2,3" >/dev/null
w=$(dbwait "select count(*) from dwd_wheels where ip='10.0.0.5'" 4)
e=$(sqlite3 "$DB" "select count(*) from dwd_eyes where ip='10.0.0.5'")
[ "$w" -ge 1 ] && [ "$e" = "3" ] && ok "T12 ingest/eye ok (wheels=$w eyes=$e)" || no "T12 (wheels=$w eyes=$e)"

# T13 ingest/eye con SQLi en name -> se guarda como DATO literal, la tabla sobrevive
curl -s -X POST -G "http://127.0.0.1:$PORT/ingest/eye" --data-urlencode "token=$TOKEN" \
  --data-urlencode "ip=10.0.0.9" \
  --data-urlencode "name=Ev'il); DROP TABLE dwd_wheels;--" \
  --data-urlencode "netsentinel=1" >/dev/null
dbwait "select count(*) from dwd_wheels where ip='10.0.0.9'" 4 >/dev/null
tbl=$(sqlite3 "$DB" "select count(*) from sqlite_master where type='table' and name='dwd_wheels'")
nm=$(sqlite3 "$DB" "select sentinelname from dwd_wheels where ip='10.0.0.9'")
[ "$tbl" = "1" ] && echo "$nm" | grep -q "DROP TABLE" && ok "T13 SQLi neutralizada (tabla intacta, name literal='$nm')" || no "T13 (tbl=$tbl name='$nm')"

# T14 ingest/eye con IP invalida -> 400
[ "$(code -X POST --data-urlencode 'ip=1.2.3.4;rm' -G --data-urlencode "token=$TOKEN" http://127.0.0.1:$PORT/ingest/eye)" = "400" ] && ok "T14 ingest/eye IP invalida 400" || no "T14"

# T15 ingest/operation valido -> fila en dwd_operations
curl -s -X POST "http://127.0.0.1:$PORT/ingest/operation?token=$TOKEN&idtrade=77&operation=Buy&price_entry=1.5&price_liquidation=1.2&total_fee=0.01&deposit=100" >/dev/null
o=$(dbwait "select count(*) from dwd_operations where idtrade=77" 4)
[ "$o" -ge 1 ] && ok "T15 ingest/operation ok (rows=$o)" || no "T15 (rows=$o)"

# T16 ingest/operation con idtrade no numerico -> 400
[ "$(code -X POST -G --data-urlencode "token=$TOKEN" --data-urlencode 'idtrade=1); DROP TABLE dwd_operations;--' http://127.0.0.1:$PORT/ingest/operation)" = "400" ] && ok "T16 ingest/operation idtrade no numerico 400" || no "T16"

# ---- Endurecimiento: metodo, token, integridad del contador, cola, reaper ----

# T17 rutas que cambian estado NO se disparan por GET (evita <img src=...> desde una web)
[ "$(code "http://127.0.0.1:$PORT/task?token=$TOKEN&action=whoami")" = "405" ] && ok "T17 /task por GET -> 405" || no "T17"
[ "$(code "http://127.0.0.1:$PORT/ingest/eye?token=$TOKEN&ip=10.0.0.7")" = "405" ] && ok "T17b /ingest/eye por GET -> 405" || no "T17b"

# T18 /stop sin token (o con token erroneo) no apaga el nodo
denied "http://127.0.0.1:$PORT/stop" && ok "T18 /stop sin token -> denegado" || no "T18"
denied "http://127.0.0.1:$PORT/stop?token=malo" && ok "T18b /stop con token erroneo -> denegado" || no "T18b"
reset_lock
curl -s "http://127.0.0.1:$PORT/version?$TK" | grep -q "Sentinel" && ok "T18c el nodo sigue vivo tras los intentos" || no "T18c"

# T19 /done falsificado NO altera el contador de carga (era bypass de maxjobs).
# Con token valido pero id inventado debe dar 404: el token da acceso a la red,
# no derecho a liberar cupo de un job que no existe.
[ "$(code "http://127.0.0.1:$PORT/done/idfalso1?$TK")" = "404" ] && ok "T19 /done con id inventado (y token bueno) -> 404" || no "T19"
denied "http://127.0.0.1:$PORT/done/algo?token=malo" && ok "T19b /done con token erroneo -> denegado" || no "T19b"
reset_lock
stop_server

# T20 la cola tiene tope: con cupo lleno y cola llena se rechaza (429), no crece sin limite
start_server 1 2 || { echo "no relanzo"; exit 1; }
for i in 1 2 3; do curl -s -X POST "http://127.0.0.1:$PORT/task?token=$TOKEN&action=sleep&param=5" >/dev/null; done
c4=$(code -X POST "http://127.0.0.1:$PORT/task?token=$TOKEN&action=sleep&param=5")
[ "$c4" = "429" ] && ok "T20 cola llena -> 429" || no "T20 (code=$c4)"
stop_server

# T21 reaper: si un worker muere sin reportar, el cupo se recupera solo (jobttl=3s)
start_server 2 64 3 || { echo "no relanzo"; exit 1; }
curl -s -X POST "http://127.0.0.1:$PORT/task?token=$TOKEN&action=sleep&param=30" >/dev/null
sleep 1
inf0=$(curl -s "http://127.0.0.1:$PORT/health?$TK" | grep -o '"inflight":[0-9]*' | sed 's/.*://')
# Matar SOLO los workers. OJO: no vale filtrar por 'Sentinel-Worker' — la linea de
# comando del ACEPTADOR tambien la contiene (-v worker=...), asi que se mataria a si
# mismo (mismo gotcha que el 'pkill -f' del README de Nodos). Los workers son los
# unicos que llevan '-v job='.
if uname -a 2>/dev/null | grep -qiE 'linux|android'; then
  pkill -f -- '-v job=' >/dev/null 2>&1
else
  powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='gawk.exe'\" | Where-Object { \$_.CommandLine -match '-v job=' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force }" >/dev/null 2>&1
fi
sleep 5
curl -s "http://127.0.0.1:$PORT/version" >/dev/null 2>&1          # una peticion dispara el reaper
inf1=$(curl -s "http://127.0.0.1:$PORT/health?$TK" | grep -o '"inflight":[0-9]*' | sed 's/.*://')
exp=$(curl -s "http://127.0.0.1:$PORT/health?$TK" | grep -o '"expired":[0-9]*' | sed 's/.*://')
[ "${inf0:-0}" -ge 1 ] && [ "${inf1:-9}" = "0" ] && [ "${exp:-0}" -ge 1 ] && ok "T21 reaper recupera cupo de worker muerto ($inf0 -> $inf1, expired=$exp)" || no "T21 (inf0=$inf0 inf1=$inf1 expired=$exp)"
stop_server

# ---- F3: el backend exige token (gawk ata 0.0.0.0, asi que el terminador TLS
#      se puede saltar: sin esto, el mTLS no protegeria al backend) ----
start_server 8 || { echo "no relanzo"; exit 1; }
denied -X POST "http://127.0.0.1:$PORT/task?action=whoami" && ok "T22 /task sin token -> denegado" || no "T22"
denied -X POST "http://127.0.0.1:$PORT/task?token=malo&action=whoami" && ok "T22b /task con token erroneo -> denegado" || no "T22b"
denied -X POST "http://127.0.0.1:$PORT/ingest/eye?ip=10.0.0.3" && ok "T22c /ingest/eye sin token -> denegado" || no "T22c"
denied "http://127.0.0.1:$PORT/job/cualquiera" && ok "T22d /job sin token -> denegado" || no "T22d"
reset_lock
stop_server

# ---- F3: PKI con openssl ----
CERTD="$V2/_test/Certs"
SENTINEL_CERTS="$CERTD" sh "$V2/Sentinel-PKI.sh" ca >/dev/null 2>&1
SENTINEL_CERTS="$CERTD" sh "$V2/Sentinel-PKI.sh" node nodoprueba 10.1.2.3 >/dev/null 2>&1
SENTINEL_CERTS="$CERTD" sh "$V2/Sentinel-PKI.sh" client clienteprueba >/dev/null 2>&1
openssl verify -CAfile "$CERTD/ca.pem" "$CERTD/nodoprueba.pem" >/dev/null 2>&1 && ok "T23 PKI: certificado de nodo valida contra la CA" || no "T23"
openssl verify -CAfile "$CERTD/ca.pem" "$CERTD/clienteprueba.pem" >/dev/null 2>&1 && ok "T23b PKI: certificado de cliente valida" || no "T23b"
openssl x509 -in "$CERTD/ca.pem" -noout -ext basicConstraints 2>/dev/null | grep -q "CA:TRUE" && ok "T23c PKI: la CA lleva basicConstraints CA:TRUE" || no "T23c"
openssl x509 -in "$CERTD/nodoprueba.pem" -noout -ext subjectAltName 2>/dev/null | grep -q "10.1.2.3" && ok "T23d PKI: el SAN del nodo incluye su IP" || no "T23d"
# La CA no se regenera si ya existe (regenerarla invalidaria toda la flota).
before=$(openssl x509 -in "$CERTD/ca.pem" -noout -fingerprint 2>/dev/null)
SENTINEL_CERTS="$CERTD" sh "$V2/Sentinel-PKI.sh" ca >/dev/null 2>&1
after=$(openssl x509 -in "$CERTD/ca.pem" -noout -fingerprint 2>/dev/null)
[ "$before" = "$after" ] && ok "T23e PKI: idempotente, no pisa la CA existente" || no "T23e"

# ---- F4: descubrimiento (aritmetica de red, barrido paralelo, gossip) ----
DISC="$V2/Sentinel-Discover.awk"
SPOOL="$V2/_test/spool"; PEERS="$V2/_test/peers.tsv"; mkdir -p "$SPOOL"

# T24 aritmetica de red: v1 solo sabia /24; v2 debe resolver cualquier mascara.
r24=$(gawk -v cidr=192.168.1.117/24 -v port=1 -v spool="$SPOOL" -v maxhosts=0 -v dryrun=1 -v debug=1 -f "$DISC" 2>&1 | grep -o 'barriendo [^:]*: [0-9]* hosts')
r23=$(gawk -v cidr=192.168.1.117/23 -v port=1 -v spool="$SPOOL" -v maxhosts=0 -v dryrun=1 -v debug=1 -f "$DISC" 2>&1 | grep -o '[0-9]* hosts' | head -1)
r30=$(gawk -v cidr=172.16.3.9/30  -v port=1 -v spool="$SPOOL" -v maxhosts=0 -v dryrun=1 -v debug=1 -f "$DISC" 2>&1 | grep -o '[0-9]* hosts' | head -1)
echo "$r24" | grep -q "254 hosts" && ok "T24 /24 -> 254 hosts" || no "T24 ($r24)"
[ "$r23" = "510 hosts" ] && ok "T24b /23 -> 510 hosts (v1 no soportaba esta mascara)" || no "T24b ($r23)"
[ "$r30" = "2 hosts" ]   && ok "T24c /30 -> 2 hosts" || no "T24c ($r30)"

# T25 el barrido encuentra un nodo vivo y lo marca como wheel por su version
start_server 8 || { echo "no relanzo"; exit 1; }
out=$(gawk -v cidr=127.0.0.1/32 -v port=$PORT -v spool="$SPOOL" -v out="$PEERS" -v token="$TOKEN" -f "$DISC" 2>&1)
echo "$out" | grep -q "encontrados=1" && ok "T25 barrido encuentra el nodo vivo" || no "T25 ($out)"
echo "$out" | grep -q "wheel=127.0.0.1" && ok "T25b lo identifica como wheel ('Sentinel Super')" || no "T25b ($out)"
grep -q "wheel" "$PEERS" 2>/dev/null && ok "T25c peers.tsv registra el rol" || no "T25c"

# T26 /peers publica lo descubierto (es lo que hace posible el gossip)
curl -s "http://127.0.0.1:$PORT/peers?$TK" | grep -q '"role":"wheel"' && ok "T26 /peers publica el vecino descubierto" || no "T26"

# T27 tope de hosts: debe AVISAR, nunca truncar en silencio
warn=$(gawk -v cidr=10.0.0.1/16 -v port=1 -v spool="$SPOOL" -v maxhosts=4 -v dryrun=1 -v debug=1 -f "$DISC" 2>&1 | grep -c "AVISO")
[ "${warn:-0}" -ge 1 ] && ok "T27 rango enorme: avisa del truncado (no silencioso)" || no "T27"

# T28 gossip: aprende vecinos preguntando a otro nodo, sin barrer
g=$(gawk -v cidr=192.168.99.250/32 -v port=$PORT -v spool="$SPOOL" -v gossip=127.0.0.1 -v token="$TOKEN" -v debug=1 -f "$DISC" 2>&1)
echo "$g" | grep -q "gossip aporto 1" && ok "T28 gossip aprende del vecino" || no "T28 ($(echo "$g" | head -2 | tr '\n' ' '))"
stop_server

# ---- Token de flota: puerta de entrada a la red ----
# locksecs corto para poder probar la espera sin alargar el banco.
start_server 8 64 300 3 || { echo "no relanzo"; exit 1; }

# T29 sin token no se obtiene NADA, ni siquiera la version (asi un agente ajeno
# instalado en la LAN no puede descubrir ni unirse a la red)
denied "http://127.0.0.1:$PORT/version" && ok "T29 /version sin token -> denegado (no se entra a la red)" || no "T29"
denied "http://127.0.0.1:$PORT/health" && ok "T29b /health sin token -> denegado" || no "T29b"
denied "http://127.0.0.1:$PORT/peers" && ok "T29c /peers sin token -> denegado" || no "T29c"
curl -s "http://127.0.0.1:$PORT/version?$TK" | grep -q "Sentinel" && ok "T29d con el token de flota sí responde" || no "T29d"

# T30 tres fallos -> bloqueo con 429 y Retry-After (desde cero: las pruebas de
# arriba ya gastaron intentos)
reset_lock
c1=$(code "http://127.0.0.1:$PORT/version?token=malo1")
c2=$(code "http://127.0.0.1:$PORT/version?token=malo2")
c3=$(code "http://127.0.0.1:$PORT/version?token=malo3")
c4=$(code "http://127.0.0.1:$PORT/version?token=malo4")
[ "$c1" = "401" ] && [ "$c2" = "401" ] && [ "$c3" = "429" ] && ok "T30 3 fallos -> bloqueo (401,401,429)" || no "T30 ($c1,$c2,$c3)"
[ "$c4" = "429" ] && ok "T30b durante el bloqueo sigue 429" || no "T30b ($c4)"
curl -s -D- -o /dev/null "http://127.0.0.1:$PORT/version?token=malo" 2>/dev/null | grep -qi "Retry-After" && ok "T30c la respuesta dice cuanto esperar (Retry-After)" || no "T30c"

# T31 CLAVE: durante el bloqueo, el token valido SIGUE pasando. Si no, cualquiera
# podria dejar la red fuera de servicio fallando el token a proposito.
curl -s "http://127.0.0.1:$PORT/version?$TK" | grep -q "Sentinel" && ok "T31 el token valido pasa durante el bloqueo (no hay auto-DoS)" || no "T31"

# T32 pasado el castigo se puede reintentar
sleep 4
[ "$(code "http://127.0.0.1:$PORT/version?token=otro")" = "401" ] && ok "T32 tras la espera vuelve a admitir intentos" || no "T32"
curl -s "http://127.0.0.1:$PORT/health?$TK" | grep -q '"auth_fallidos"' && ok "T32b /health informa de los intentos fallidos" || no "T32b"

# T33 el descubrimiento presenta el token: con el encuentra, sin el no
outc=$(gawk -v cidr=127.0.0.1/32 -v port=$PORT -v spool="$SPOOL" -v token="$TOKEN" -f "$DISC" 2>&1)
echo "$outc" | grep -q "encontrados=1" && ok "T33 descubrimiento CON token encuentra el nodo" || no "T33 ($outc)"
sleep 4
outs=$(gawk -v cidr=127.0.0.1/32 -v port=$PORT -v spool="$SPOOL" -f "$DISC" 2>&1)
echo "$outs" | grep -q "encontrados=0" && ok "T33b descubrimiento SIN token no ve nada (agente ajeno no entra)" || no "T33b ($outs)"
stop_server

# T34 el gestor de token: crear, mostrar, importar, verificar
TD="$V2/_test/tok"; mkdir -p "$TD"
t1=$(SENTINEL_BASE="$TD" sh "$V2/Sentinel-Token.sh" create 2>/dev/null | tail -1)
echo "$t1" | grep -qE '^[0-9a-f]{64}$' && ok "T34 create genera un token fuerte (64 hex)" || no "T34 ($t1)"
SENTINEL_BASE="$TD" sh "$V2/Sentinel-Token.sh" create >/dev/null 2>&1 && no "T34b create deberia negarse a pisar" || ok "T34b create no pisa un token existente"
TD2="$V2/_test/tok2"; mkdir -p "$TD2"
SENTINEL_BASE="$TD2" sh "$V2/Sentinel-Token.sh" import "$t1" >/dev/null 2>&1
[ "$(SENTINEL_BASE="$TD2" sh "$V2/Sentinel-Token.sh" show 2>/dev/null)" = "$t1" ] && ok "T34c import instala el mismo token en otro nodo" || no "T34c"
SENTINEL_BASE="$TD2" sh "$V2/Sentinel-Token.sh" verify "$t1" >/dev/null 2>&1 && ok "T34d verify acepta el token correcto" || no "T34d"
SENTINEL_BASE="$TD2" sh "$V2/Sentinel-Token.sh" verify "0123456789abcdef0123456789abcdef" >/dev/null 2>&1 && no "T34e verify deberia rechazar otro token" || ok "T34e verify rechaza un token ajeno"
SENTINEL_BASE="$TD2" sh "$V2/Sentinel-Token.sh" import "corto" >/dev/null 2>&1 && no "T34f deberia rechazar un token debil" || ok "T34f import rechaza un token debil"

# ---- Eleccion automatica de Wheel ----
WS="$V2/_test/wheel.state"; PT="$V2/_test/peers_e.tsv"
printf '127.0.0.1\tx\tx\t1\n' > "$PT"
gawk -v Port=$PORT -v name=nodoTest -v jobs="$JOBS" -v worker="$WORKER" -v allow="$ALLOW" -v run="$RUN" \
     -v token="$TOKEN" -v wheelstate="$WS" -v elector="$V2/Sentinel-Wheel.awk" -v peers="$PT" \
     -v eligible=yes -v electsecs=99999 -f "$SERVER" >"$V2/_test/e.log" 2>&1 &
EPID=$!
for i in $(seq 1 20); do curl -s "http://127.0.0.1:$PORT/version?$TK" >/dev/null 2>&1 && break; sleep 0.2; done

# T35 /fitness publica lo que necesita el elector
f=$(curl -s -m 5 "http://127.0.0.1:$PORT/fitness?$TK")
echo "$f" | grep -q '"elegible":1' && echo "$f" | grep -q '"uptime"' && ok "T35 /fitness publica aptitud" || no "T35 ($f)"

# T36 sin Wheel elegido, el nodo NO se anuncia Super
curl -s -m 5 "http://127.0.0.1:$PORT/version?$TK" | grep -q '"wheel":0' && ok "T36 sin eleccion no hay Super" || no "T36"

# T37 el elector puntua y elige
e=$(gawk -v self=nodoTest -v port=$PORT -v token="$TOKEN" -v peers="$PT" -v state="$WS" -v debug=1 -f "$V2/Sentinel-Wheel.awk" 2>&1)
# El propio aceptador lanza una eleccion al arrancar, asi que el Wheel puede
# venir ya puesto: valen tanto el alta como la confirmacion.
echo "$e" | grep -qE "Wheel: .* -> nodoTest|Wheel sigue siendo nodoTest" && ok "T37 el elector elige por puntuacion" || no "T37 ($(echo "$e" | head -2 | tr '\n' ' '))"

# T38 el relevo entra EN CALIENTE, sin reiniciar el servicio
sleep 3
curl -s -m 5 "http://127.0.0.1:$PORT/version?$TK" | grep -q "Sentinel Super" && ok "T38 el elegido se anuncia Super sin reiniciar" || no "T38"
echo "otroNodo" > "$WS"; sleep 3
curl -s -m 5 "http://127.0.0.1:$PORT/version?$TK" | grep -q '"wheel":0' && ok "T38b cede el rol en caliente al cambiar el elegido" || no "T38b"

# T39 la histeresis existe: el Wheel actual puntua mas que el mismo nodo sin serlo
echo "nodoTest" > "$WS"; sleep 3
p1=$(gawk -v self=nodoTest -v port=$PORT -v token="$TOKEN" -v peers="$PT" -v state="$WS" -v debug=1 -f "$V2/Sentinel-Wheel.awk" 2>&1 | grep -o 'pts=[0-9.]*' | head -1 | cut -d= -f2)
echo "otro" > "$WS"; sleep 3
p2=$(gawk -v self=nodoTest -v port=$PORT -v token="$TOKEN" -v peers="$PT" -v state="$WS" -v debug=1 -f "$V2/Sentinel-Wheel.awk" 2>&1 | grep -o 'pts=[0-9.]*' | head -1 | cut -d= -f2)
gawk -v a="${p1:-0}" -v b="${p2:-0}" 'BEGIN{ exit !(a > b) }' && ok "T39 histeresis: el Wheel actual puntua mas ($p1 vs $p2)" || no "T39 ($p1 vs $p2)"
kill $EPID 2>/dev/null; wait $EPID 2>/dev/null

# T40 un nodo marcado no elegible nunca gana
gawk -v Port=$PORT -v name=laptopTest -v jobs="$JOBS" -v worker="$WORKER" -v allow="$ALLOW" -v run="$RUN" \
     -v token="$TOKEN" -v wheelstate="$V2/_test/L.state" -v elector="$V2/Sentinel-Wheel.awk" -v peers="$PT" \
     -v eligible=no -v electsecs=99999 -f "$SERVER" >"$V2/_test/l.log" 2>&1 &
LPID=$!
for i in $(seq 1 20); do curl -s "http://127.0.0.1:$PORT/version?$TK" >/dev/null 2>&1 && break; sleep 0.2; done
el=$(gawk -v self=laptopTest -v port=$PORT -v token="$TOKEN" -v peers="$PT" -v state="$V2/_test/L.state" -f "$V2/Sentinel-Wheel.awk" 2>&1)
echo "$el" | grep -q "ningun candidato apto" && ok "T40 un nodo no elegible nunca es Wheel" || no "T40 ($el)"
kill $LPID 2>/dev/null; wait $LPID 2>/dev/null

echo "== Resultado: $PASS PASS / $FAIL FAIL =="
[ $FAIL -eq 0 ]
