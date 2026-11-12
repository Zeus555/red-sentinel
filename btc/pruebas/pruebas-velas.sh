#!/usr/bin/env sh
# Banco de pruebas de Sentinel-BTC-Velas.sh.
#
#   A. Calculo (velas-calculo.awk) con numeros hechos a mano.
#   B. Lector de Coinbase (coinbase-velas.awk): respuestas buenas, rotas y vacias.
#   C. Pasadas reales del script contra un rqlite LOCAL con contraseña y un
#      Coinbase falso (cb-falso.js). Cada resultado se compara, fila a fila, con
#      un calculo independiente en JavaScript (serie-falsa.js).
#
# NUNCA toca el rqlite de la red ni Coinbase: todo va a 127.0.0.1 y el
# sentinel.conf del equipo no se lee (SENTINEL_BASE apunta a una carpeta propia).
# Necesita: awk, curl, node y rqlited (la parte C se salta si falta alguno).
set -u
AQUI=$(cd "$(dirname "$0")" && pwd)
BTC=$(cd "$AQUI/.." && pwd)
CALC="$BTC/velas-calculo.awk"; LECTOR="$BTC/coinbase-velas.awk"; SCRIPT="$BTC/Sentinel-BTC-Velas.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/btcpruebas.XXXXXX")
PIDS=""
limpia(){ for p in $PIDS; do kill "$p" 2>/dev/null; done; sleep 1; rm -rf "$T"; }
trap limpia EXIT
trap 'exit 130' INT TERM HUP

ok=0; mal=0
pasa(){ ok=$((ok + 1)); printf 'ok   %s\n' "$1"; }
falla(){ mal=$((mal + 1)); printf 'MAL  %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; return 0; }
igual(){ if [ "$2" = "$3" ]; then pasa "$1"; else falla "$1" "esperado [$2] obtenido [$3]"; fi; }
TAB=$(printf '\t')

# ============================ A. Calculo ======================================
D0=1704067200   # 2024-01-01, lunes
printf '%s\n' "$D0 100 110 90 105 1" "$((D0 + 86400)) 105 120 100 115 2" "$((D0 + 172800)) 115 118 95 100 3" > "$T/a1.txt"
AH=$((D0 + 3 * 86400 + 3600))
awk -v producto=X -v ahora="$AH" -v desde=0 -v salida=tsv -f "$CALC" "$T/a1.txt" > "$T/a1.out" 2> "$T/a1.err"
cat > "$T/a1.esp" <<EOF
1d${TAB}1704067200${TAB}100${TAB}110${TAB}90${TAB}105${TAB}1${TAB}102.5${TAB}110${TAB}90${TAB}101.25${TAB}1${TAB}null
1d${TAB}1704153600${TAB}105${TAB}120${TAB}100${TAB}115${TAB}2${TAB}101.875${TAB}120${TAB}100${TAB}110${TAB}1${TAB}null
1d${TAB}1704240000${TAB}115${TAB}118${TAB}95${TAB}100${TAB}3${TAB}105.9375${TAB}118${TAB}95${TAB}107${TAB}1${TAB}null
1w${TAB}1704067200${TAB}100${TAB}120${TAB}90${TAB}100${TAB}6.00000000${TAB}100${TAB}120${TAB}90${TAB}102.5${TAB}0${TAB}3
EOF
if cmp -s "$T/a1.out" "$T/a1.esp"; then pasa "A1 Heikin Ashi diaria y semanal con numeros hechos a mano"
else falla "A1 Heikin Ashi diaria y semanal con numeros hechos a mano" "$(diff "$T/a1.esp" "$T/a1.out" | head -6 | tr '\n' '|')"; fi
igual "A1 resumen" "diarias=3 semanales=1 huecos=0" "$(grep -o 'diarias=[0-9]* semanales=[0-9]* huecos=[0-9]*' "$T/a1.err")"

# Domingo 07/01, lunes 08/01, (falta el martes 09/01), miercoles 10/01 en curso.
S=1704585600; L=1704672000; X=1704844800
printf '%s\n' "$S 10 12 9 11 1" "$L 11 13 10 12 1" "$X 12 14 11 13 1" > "$T/a2.txt"
awk -v producto=X -v ahora=$((X + 3600)) -v desde=0 -v salida=tsv -f "$CALC" "$T/a2.txt" > "$T/a2.out" 2> "$T/a2.err"
igual "A2 el domingo cierra su semana y el lunes abre otra" "1w 1704067200 1 1|1w 1704672000 0 2|" \
  "$(awk -F"$TAB" '$1 == "1w" { printf "%s %s %s %s|", $1, $2, $12, $13 }' "$T/a2.out")"
igual "A2 el dia que falta se anota como hueco y no se inventa" "HUECO 1704758400 1704758400" "$(grep '^HUECO' "$T/a2.err")"
igual "A2 la vela del dia en curso queda abierta" "0" "$(awk -F"$TAB" '$1 == "1d" && $2 == 1704844800 { print $12 }' "$T/a2.out")"

awk -v producto=X -v ahora=$((X + 3600)) -v desde="$L" -v salida=tsv -f "$CALC" "$T/a2.txt" > "$T/a3.out" 2>/dev/null
igual "A3 'desde' emite solo los dias y semanas que tocan" "1d 1704672000|1d 1704844800|1w 1704672000|" \
  "$(awk -F"$TAB" '{ printf "%s %s|", $1, $2 }' "$T/a3.out")"
# ...pero calcula con toda la historia: la HA del lunes es la misma con y sin 'desde'.
igual "A3 la Heikin Ashi no cambia al emitir a trozos" \
  "$(awk -F"$TAB" '$1 == "1d" && $2 == 1704672000 { print $8, $11 }' "$T/a2.out")" \
  "$(awk -F"$TAB" '$1 == "1d" && $2 == 1704672000 { print $8, $11 }' "$T/a3.out")"

printf '%s\n' "$D0 1 1 1 1 1" "$D0 1 1 1 1 1" > "$T/a4.txt"
awk -v producto=X -v ahora="$AH" -v salida=tsv -f "$CALC" "$T/a4.txt" > "$T/a4.out" 2>/dev/null; r=$?
igual "A4 una serie con dias repetidos se rechaza (sale con 2)" "2" "$r"

awk -v producto=BTC-USD -v ahora="$AH" -v desde=0 -v salida=json -v fuente=nodo -v actualizado=5 -f "$CALC" "$T/a1.txt" > "$T/a5.out" 2>/dev/null
if command -v node >/dev/null 2>&1; then
  r=$(node -e '
    const L = require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n");
    let ok = L.length === 4;
    for (const l of L) { const a = JSON.parse(l); ok = ok && a.length === 17 && /^INSERT OR REPLACE INTO cripto_vela/.test(a[0]) && a[1] === "BTC-USD" && a[15] === "nodo" && a[16] === 5; }
    ok = ok && JSON.parse(L[0])[14] === null && JSON.parse(L[3])[14] === 3;
    console.log(ok ? "si" : "no");' "$T/a5.out" 2>&1)
  igual "A5 cada sentencia JSON es valida y lleva 16 parametros" "si" "$r"
fi

# ============================ B. Lector de Coinbase ===========================
lee(){ printf '%s' "$1" | awk -f "$LECTOR" > "$T/b.out" 2>/dev/null; echo $?; }
r=$(lee '{"candles":[{"start":"1704153600","low":"100","high":"120","open":"105","close":"115","volume":"2"},{"start":"1704067200","low":"90","high":"110","open":"100","close":"105","volume":"1"}]}')
igual "B1 respuesta normal" "0|1704153600 105 120 100 115 2|1704067200 100 110 90 105 1|" "$r|$(tr '\n' '|' < "$T/b.out")"
r=$(lee '{"candles":[]}'); igual "B2 sin velas: sale bien y no imprime nada" "0|" "$r|$(cat "$T/b.out")"
r=$(lee '{"error":"INVALID_ARGUMENT","message":"x"}'); igual "B3 error de la API: sale con 4" "4" "$r"
r=$(lee '{"candles":[{"start":"1704067200","low":"90","high":"100","open":"100","close":"105","volume":"1"}]}')
igual "B4 vela imposible (maximo bajo el cierre): sale con 3 y no imprime nada" "3|" "$r|$(cat "$T/b.out")"
r=$(lee '{"candles":[{"start":"1704067201","low":"1","high":"1","open":"1","close":"1","volume":"1"}]}')
igual "B5 vela que no empieza a medianoche UTC: sale con 3" "3" "$r"
r=$(lee '{"candles":[{"open":"1","close":"1","high":"1","low":"1","volume":"1e-05","start":"1704067200"}]}')
igual "B6 campos en otro orden y volumen con exponente" "0|1704067200 1 1 1 1 1e-05|" "$r|$(tr '\n' '|' < "$T/b.out")"
r=$(lee '{"candles":[{"start":"1704067200","low":"1","high":"1","open":"1","close":"abc","volume":"1"}]}')
igual "B7 un campo que no es numero: sale con 3" "3" "$r"

# Precision relativa: un producto de precio muy bajo no pierde decimales.
printf '%s\n' "$D0 0.00001234 0.0000131 0.000012 0.0000125 1" > "$T/a6.txt"
awk -v producto=X -v ahora="$AH" -v desde=0 -v salida=tsv -f "$CALC" "$T/a6.txt" 2>/dev/null > "$T/a6.out"
igual "A6 la Heikin Ashi guarda precision relativa (precios muy bajos)" "1.2485e-05" "$(awk -F"$TAB" '$1 == "1d" { print $11 }' "$T/a6.out")"

# ============================ C. Pasadas reales ===============================
if ! command -v node >/dev/null 2>&1 || ! command -v rqlited >/dev/null 2>&1; then
  printf 'salto la parte C: hace falta node y rqlited\n'
else
  PCB=18081; PRQ=14001; PRAFT=14002
  # Los puertos tienen que estar LIBRES: si hay otro rqlited (p. ej. uno de
  # ensayo) en el mismo puerto, el banco le haria DROP TABLE. Cuando nadie
  # escucha, curl sale con 7 (Linux) o con 28 (Windows reintenta la conexion
  # rechazada hasta agotar el tiempo); con alguien escuchando, con otro codigo.
  libres=1
  for p in $PCB $PRQ $PRAFT; do
    curl -q -s -m 3 -o /dev/null "http://127.0.0.1:$p/" 2>/dev/null; c=$?
    [ "$c" -eq 7 ] || [ "$c" -eq 28 ] || { falla "C0 puerto 127.0.0.1:$p libre" "ocupado (curl $c): no lanzo la parte C"; libres=0; }
  done
fi
if [ "${libres:-0}" = 1 ]; then
  E="$T/estado.json"
  est(){ printf '%s' "$1" > "$E"; }
  AHORA0=1794506400   # 12/11/2026 18:00 UTC
  INICIO=1672617600   # 02/01/2023, primera vela de la serie falsa
  est "{\"ahora\":$AHORA0}"
  node "$AQUI/cb-falso.js" "$PCB" "$E" > "$T/cb.log" 2>&1 & PIDS="$PIDS $!"; PCBPID=$!
  printf '[{"username":"prueba","password":"clave-prueba","perms":["all"]}]' > "$T/auth.json"
  printf 'user = "prueba:clave-prueba"\n' > "$T/prueba.curlrc"
  printf 'user = "prueba:otra-clave"\n' > "$T/mala.curlrc"
  mkdir -p "$T/rq"
  NODO="prueba-$$"
  rqlited -auth "$T/auth.json" -http-addr 127.0.0.1:$PRQ -raft-addr 127.0.0.1:$PRAFT -node-id "$NODO" "$T/rq" > "$T/rq.log" 2>&1 & PIDS="$PIDS $!"; RQPID=$!
  # -f: hace falta un 200 de verdad (con lider), no cualquier respuesta.
  i=0; until curl -q -f -s -m 2 -o /dev/null -K "$T/prueba.curlrc" "http://127.0.0.1:$PRQ/readyz" 2>/dev/null; do i=$((i + 1)); [ $i -gt 30 ] && break; sleep 1; done
  j=0; until curl -q -s -m 2 -o /dev/null "http://127.0.0.1:$PCB/_peticiones" 2>/dev/null; do j=$((j + 1)); [ $j -gt 15 ] && break; sleep 1; done
  if [ $i -gt 30 ] || [ $j -gt 15 ] || ! kill -0 "$RQPID" 2>/dev/null || ! kill -0 "$PCBPID" 2>/dev/null \
     || ! curl -q -s -K "$T/prueba.curlrc" "http://127.0.0.1:$PRQ/status" | grep -q "\"node_id\":\"$NODO\""; then
    falla "C0 arrancan el rqlited y el Coinbase falso de ESTA pasada" "$(tail -3 "$T/rq.log" | tr '\n' '|')"
  else
  pasa "C0 arrancan el rqlited y el Coinbase falso de esta pasada"

  RQ="http://127.0.0.1:$PRQ"
  mkdir -p "$T/base" "$T/casa"   # base sin sentinel.conf
  # Una casa con un ~/.curlrc que lleva una clave de mentira: si el script se
  # olvidara del -q, curl la mandaria a Coinbase y C13 lo veria.
  printf 'user = "fuga:x"\n' > "$T/casa/.curlrc"; cp "$T/casa/.curlrc" "$T/casa/_curlrc"
  corre(){ # corre <ahora> [opciones...]  -> $T/salida, devuelve el codigo del script
    a=$1; shift
    # Por defecto solo BTC-USD, para que los conteos de peticiones y filas sean
    # fijos; C16 prueba el spot y el perpetuo juntos (PRODS).
    env HOME="$T/casa" CURL_HOME="$T/casa" SENTINEL_BASE="$T/base" RQLITE="$RQ" RQLITE_CRED="${CRED:-$T/prueba.curlrc}" \
        CB_API="http://127.0.0.1:$PCB" CB_PAUSA=0 CB_ESPERA=0 BTC_DIR="$T/dir" BTC_AHORA="$a" \
        BTC_PRODUCTOS="${PRODS:-BTC-USD}" sh "$SCRIPT" "$@" > "$T/salida" 2>&1
  }
  comprueba(){ node "$AQUI/comprueba.js" "$RQ" "prueba:clave-prueba" "$E" "${1:-BTC-USD}" 2>&1; }
  sql1(){ curl -q -s -K "$T/prueba.curlrc" -G "$RQ/db/query" --data-urlencode "q=$1" | sed -n 's/.*"values":\[\[\([^]]*\)\]\].*/\1/p'; }
  ejecuta(){ printf '%s' "$1" | curl -q -s -K "$T/prueba.curlrc" -H 'Content-Type: application/json' --data-binary @- "$RQ/db/execute" > /dev/null; }
  huella(){ sql1 "SELECT COUNT(*), MAX(actualizado), SUM(cierre) FROM cripto_vela"; }
  escritas(){ sed -n 's/.* \([0-9]*\) filas escritas.*/\1/p' "$T/salida" | tail -1; }
  pet(){ curl -q -s "http://127.0.0.1:$PCB/_peticiones"; }
  coincide(){ # coincide <nombre> <codigo esperado>
    c=$(comprueba)
    case "$r|$c" in "$2|coincide"*) pasa "$1" ;; *) falla "$1" "r=$r $c $(head -c 300 "$T/salida")" ;; esac
  }
  sin_aviso(){ if grep -q 'Coinbase cambio' "$T/salida"; then falla "$1" "$(cat "$T/salida")"; else pasa "$1"; fi; }

  p0=$(pet); corre $AHORA0; r=$?
  igual "C1 carga completa en una base vacia: sale bien" "0" "$r"
  grep -q 'creada la tabla cripto_vela' "$T/salida" && pasa "C1 crea la tabla" || falla "C1 crea la tabla" "$(head -3 "$T/salida")"
  coincide "C1 todas las filas coinciden con el calculo independiente" 0
  igual "C1 la carga completa hace 7 peticiones (5 con velas y 2 vacias para cerrar)" "7" "$(( $(pet) - p0 ))"

  p0=$(pet); corre $AHORA0; r=$?
  igual "C2 segunda pasada sin novedades: sale bien" "0" "$r"
  # 3 dias de margen + el ultimo cerrado + el de hoy = 5 diarias, y 1 o 2 semanas
  # (2 si el margen cae en la semana anterior, como aqui: empieza en domingo).
  n=$(escritas); [ -n "$n" ] && [ "$n" -le 7 ] && pasa "C2 solo reescribe los ultimos dias ($n filas)" || falla "C2 solo reescribe los ultimos dias" "escritas=$n; $(cat "$T/salida")"
  coincide "C2 sigue coincidiendo" 0
  igual "C2 la pasada incremental hace 1 sola peticion" "1" "$(( $(pet) - p0 ))"

  AHORA1=$((AHORA0 + 2 * 86400 + 5 * 3600))
  est "{\"ahora\":$AHORA1}"
  corre $AHORA1; r=$?
  coincide "C3 dos dias despues: la vela que estaba abierta se cierra bien y entran las nuevas" 0
  sin_aviso "C3 cerrar la vela que estaba abierta no es una 'correccion de Coinbase'"

  # Cambio de dia UTC: 23:50 guarda la vela de hoy a medias; 00:00:30 (dentro
  # del margen) la deja abierta; 00:10 la cierra. Ninguna es una correccion.
  M=$(( (AHORA1 / 86400 + 1) * 86400 ))       # proxima medianoche UTC
  est "{\"ahora\":$((M - 600))}"; corre $((M - 600)); r=$?
  coincide "C3b a las 23:50 la vela del dia queda guardada a medias" 0
  est "{\"ahora\":$((M + 30))}"; corre $((M + 30)); r=$?
  igual "C3b a las 00:00:30 la vela de ayer sigue abierta (margen de 60 s)" "0" "$(sql1 "SELECT cerrada FROM cripto_vela WHERE producto='BTC-USD' AND marco='1d' AND ts=$((M - 86400))")"
  est "{\"ahora\":$((M + 600))}"; corre $((M + 600)); r=$?
  coincide "C3b a las 00:10 se cierra con los valores definitivos" 0
  sin_aviso "C3b el cambio de dia no da aviso de correccion"
  AHORA1=$((M + 600))

  # Coinbase corrige una vela ya cerrada (la de anteayer).
  DIAC=$(( (AHORA1 / 86400) * 86400 - 2 * 86400 ))
  est "{\"ahora\":$AHORA1,\"cambiar\":{\"$DIAC\":{\"c\":1,\"l\":1}}}"
  corre $AHORA1; r=$?
  coincide "C4 una vela cerrada corregida por Coinbase se sobrescribe y la HA posterior se recalcula" 0
  grep -q 'Coinbase cambio 1 velas que ya estaban cerradas' "$T/salida" && pasa "C4 se avisa de la correccion" || falla "C4 se avisa de la correccion" "$(cat "$T/salida")"

  # Un dia que nunca existio en Coinbase, en una base nueva.
  ejecuta '[["DROP TABLE cripto_vela"]]'
  HUECO=$((INICIO + 100 * 86400))
  est "{\"ahora\":$AHORA1,\"quitar\":[$HUECO]}"
  corre $AHORA1; r=$?
  coincide "C5 un dia que falta en Coinbase: la semana queda con 6 dias y no se inventa nada" 0
  grep -q '1 dias faltantes en 1 tramos' "$T/salida" && pasa "C5 se anota el hueco" || falla "C5 se anota el hueco" "$(cat "$T/salida")"

  antes=$(huella)
  corre $((AHORA1 + 60)) --seco; r=$?
  igual "C6 --seco no escribe nada (ni reescribe filas iguales)" "0 $antes" "$r $(huella)"
  ls "$T/dir/seco/"BTC-USD.*.json > /dev/null 2>&1 && pasa "C6 --seco deja los lotes para revisarlos" || falla "C6 --seco deja los lotes"

  est "{\"ahora\":$AHORA1,\"quitar\":[$HUECO],\"fallo500\":true}"
  corre $AHORA1; r=$?
  igual "C7 Coinbase caido: sale con 1" "1" "$r"
  grep -q 'Coinbase respondio http 500 4 veces' "$T/salida" && pasa "C7 explica el fallo de Coinbase" || falla "C7 explica el fallo" "$(cat "$T/salida")"

  est "{\"ahora\":$AHORA1,\"quitar\":[$HUECO],\"invalida\":true}"
  antes=$(huella); corre $AHORA1; r=$?
  igual "C8 una vela imposible de Coinbase: sale con 2 y no escribe nada" "2 $antes" "$r $(huella)"

  est "{\"ahora\":$AHORA1,\"quitar\":[$HUECO],\"vacio\":true}"
  antes=$(huella); corre $AHORA1; r=$?
  igual "C8b Coinbase devuelve la lista vacia: sale con 1 y no cierra la vela a medias" "1 $antes" "$r $(huella)"
  grep -q 'no devolvio el dia' "$T/salida" && pasa "C8b lo explica" || falla "C8b lo explica" "$(cat "$T/salida")"
  est "{\"ahora\":$AHORA1,\"quitar\":[$HUECO]}"

  antes=$(huella); corre $((AHORA1 - 3 * 86400)); r=$?
  igual "C8c reloj atrasado 3 dias: sale con 2 y no escribe nada" "2 $antes" "$r $(huella)"
  grep -q 'reloj de este equipo' "$T/salida" && pasa "C8c lo explica" || falla "C8c lo explica" "$(cat "$T/salida")"

  RQ_BUENO=$RQ; RQ="http://127.0.0.1:14999"
  corre $AHORA1; r=$?; RQ=$RQ_BUENO
  igual "C9 rqlite inalcanzable: sale con 1" "1" "$r"
  CRED="$T/mala.curlrc" corre $AHORA1; r=$?
  igual "C10 clave de rqlite equivocada: sale con 1" "1" "$r"
  grep -q 'http 401' "$T/salida" && pasa "C10 dice que fue un 401" || falla "C10 dice que fue un 401" "$(cat "$T/salida")"

  mkdir -p "$T/dir"; mkdir "$T/dir/.velas.lock"
  corre $AHORA1; r=$?
  igual "C11 con otra pasada en curso no hace nada" "0" "$r"
  grep -q 'ya hay otra pasada en curso' "$T/salida" && pasa "C11 lo dice" || falla "C11 lo dice" "$(cat "$T/salida")"
  rmdir "$T/dir/.velas.lock"
  : > "$T/dir/.velas.lock"
  corre $AHORA1; r=$?
  igual "C11b si el cerrojo no se puede crear (hay un fichero) sale con 1, no con 'otra pasada'" "1" "$r"
  rm -f "$T/dir/.velas.lock"

  printf 'NAME=nodo-prueba\nRQLITE=http://127.0.0.1:14999\nRQLITE_CRED=%s\n' "$T/mala.curlrc" > "$T/base/sentinel.conf"
  corre $AHORA1; r=$?
  igual "C12 RQLITE y RQLITE_CRED del entorno mandan sobre sentinel.conf" "0" "$r"
  f=$(sql1 "SELECT COUNT(*) FROM cripto_vela WHERE fuente='nodo-prueba'")
  [ "${f:-0}" -gt 0 ] && pasa "C12 la columna fuente lleva el NAME del nodo" || falla "C12 fuente = NAME" "$f"
  printf 'NAME=nodo-prueba\nBTC_NODOS="otro-nodo sentinel014"\n' > "$T/base/sentinel.conf"
  p0=$(pet); antes=$(huella); corre $((AHORA1 + 120)); r=$?
  igual "C12b con BTC_NODOS sin este nodo no hace nada" "0 0 $antes" "$r $(( $(pet) - p0 )) $(huella)"
  rm -f "$T/base/sentinel.conf"

  igual "C13 ninguna peticion a Coinbase llevo credenciales (ni las de un ~/.curlrc)" "0" "$(curl -q -s "http://127.0.0.1:$PCB/_conclave")"

  # rqlite contesta 200 aunque la sentencia falle: el error va dentro del JSON.
  # Tabla con un esquema viejo (sin la columna dias): el INSERT falla con un 200.
  ejecuta '[["DROP TABLE cripto_vela"],["CREATE TABLE cripto_vela (producto TEXT NOT NULL, marco TEXT NOT NULL, ts INTEGER NOT NULL, apertura REAL NOT NULL, maximo REAL NOT NULL, minimo REAL NOT NULL, cierre REAL NOT NULL, volumen REAL NOT NULL, ha_apertura REAL, ha_maximo REAL, ha_minimo REAL, ha_cierre REAL, cerrada INTEGER NOT NULL, fuente TEXT, actualizado INTEGER NOT NULL, PRIMARY KEY (producto, marco, ts)) WITHOUT ROWID"]]'
  corre $AHORA1; r=$?
  igual "C14 un error de SQL dentro de un 200 de rqlite: sale con 1" "1" "$r"
  grep -q 'fallo al escribir' "$T/salida" && pasa "C14 lo explica" || falla "C14 lo explica" "$(cat "$T/salida")"

  # Una ventana vacia en medio de la historia no puede recortar la carga completa.
  ejecuta '[["DROP TABLE cripto_vela"]]'
  est "{\"ahora\":$AHORA1,\"ventanaVacia\":$((INICIO + 700 * 86400))}"
  corre $AHORA1; r=$?
  igual "C15 ventana vacia en medio de la carga completa: sale con 1 y no escribe" "1 0" "$r $(sql1 'SELECT COUNT(*) FROM cripto_vela')"
  grep -q 'ventana vacia en medio' "$T/salida" && pasa "C15 lo explica" || falla "C15 lo explica" "$(cat "$T/salida")"
  est "{\"ahora\":$AHORA1}"
  corre $AHORA1; r=$?
  coincide "C15 la pasada siguiente carga la historia completa" 0

  # Spot y perpetuo de futuros juntos (lo que se usa por defecto en la red).
  # El perpetuo empieza un viernes: su primera semana sale con 3 dias.
  ejecuta '[["DROP TABLE cripto_vela"]]'
  PRODS="BTC-USD BIP-20DEC30-CDE" corre $AHORA1; r=$?
  igual "C16 spot y perpetuo en la misma pasada: sale bien" "0" "$r"
  c1=$(comprueba BTC-USD); c2=$(comprueba BIP-20DEC30-CDE)
  case "$c1|$c2" in coincide*\|coincide*) pasa "C16 las dos series coinciden con el calculo independiente ($c2)" ;; *) falla "C16 las dos series coinciden" "$c1 / $c2" ;; esac
  igual "C16 la primera semana del perpetuo queda con los dias que tiene" "3" "$(sql1 "SELECT dias FROM cripto_vela WHERE producto='BIP-20DEC30-CDE' AND marco='1w' ORDER BY ts LIMIT 1")"
  AHORA2=$((AHORA1 + 86400))
  est "{\"ahora\":$AHORA2}"
  PRODS="BTC-USD BIP-20DEC30-CDE" corre $AHORA2; r=$?
  c1=$(comprueba BTC-USD); c2=$(comprueba BIP-20DEC30-CDE)
  case "$r|$c1|$c2" in 0\|coincide*\|coincide*) pasa "C16 la pasada incremental de las dos series tambien coincide" ;; *) falla "C16 pasada incremental de las dos series" "r=$r $c1 / $c2" ;; esac
  PRODS="BTC-USD NO-EXISTE" corre $AHORA2; r=$?
  igual "C16 un producto que Coinbase no conoce sale con 1 sin tapar al otro" "1" "$r"
  grep -q '^BTC-USD:' "$T/salida" && pasa "C16 el otro producto se proceso igual" || falla "C16 el otro producto se proceso igual" "$(cat "$T/salida")"
  fi
fi

printf '\n%d bien, %d mal\n' "$ok" "$mal"
[ "$mal" -eq 0 ]
