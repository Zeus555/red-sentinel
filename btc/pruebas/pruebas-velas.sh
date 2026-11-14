#!/usr/bin/env sh
# Banco de pruebas de Sentinel-BTC-Velas.sh.
#
#   A. Calculo (velas-calculo.awk) con numeros hechos a mano.
#   B. Lector de Coinbase (coinbase-velas.awk): respuestas buenas, rotas y vacias.
#   I. Indicadores (indicadores-calculo.awk): numeros hechos a mano y la serie
#      falsa entera contra un calculo independiente (indicadores-ref.js).
#   F. Fibonacci (fibonacci-calculo.awk): casos hechos a mano, la serie falsa y
#      480 series al azar contra un calculo independiente (fibonacci-ref.js).
#   V. Señales (avisos-calculo.awk): casos hechos a mano, el reparto entre
#      perpetuo y spot, errores, el JSON y series al azar contra avisos-ref.js.
#   C. Pasadas reales del script contra un rqlite LOCAL con contraseña y un
#      Coinbase falso (cb-falso.js). Cada resultado (velas e indicadores) se
#      compara, fila a fila, con los calculos independientes en JavaScript
#      (serie-falsa.js, indicadores-ref.js y fibonacci-ref.js).
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

# Laborable (TEK: solo de lunes a viernes). D0 es lunes: la semana del 01/01 de
# lunes a viernes, el lunes 08/01, sin el martes 09/01 (festivo) y el miercoles.
lab(){ # lab <laborable> <ahora> <fichero>  -> $T/a6.out y $T/a6.err
  awk -v producto=TEK-T -v ahora="$2" -v desde=0 -v salida=tsv -v laborable="$1" -f "$CALC" "$3" > "$T/a6.out" 2> "$T/a6.err"; }
for k in 0 1 2 3 4; do printf '%s 100 110 90 105 1\n' "$((D0 + k * 86400))"; done > "$T/a6.txt"
lab 1 $((D0 + 5 * 86400)) "$T/a6.txt"
igual "A6 laborable: la semana de lunes a viernes cierra al acabar el viernes (sabado 00:00), con 5 dias" "1 5" \
  "$(awk -F"$TAB" '$1 == "1w" { print $12, $13 }' "$T/a6.out")"
lab 1 $((D0 + 5 * 86400 - 1)) "$T/a6.txt"
igual "A6 ...un segundo antes, aun abierta" "0" "$(awk -F"$TAB" '$1 == "1w" { print $12 }' "$T/a6.out")"
lab 0 $((D0 + 5 * 86400)) "$T/a6.txt"
igual "A6 sin laborable, esa misma semana sigue abierta hasta el domingo" "0" "$(awk -F"$TAB" '$1 == "1w" { print $12 }' "$T/a6.out")"
{ cat "$T/a6.txt"; printf '%s 100 110 90 105 1\n' "$((D0 + 7 * 86400))" "$((D0 + 9 * 86400))"; } > "$T/a6b.txt"
lab 1 $((D0 + 9 * 86400 + 3600)) "$T/a6b.txt"
igual "A6 laborable: el fin de semana no es hueco; el martes que falta (festivo), si" "huecos=1 tramos=1|HUECO $((D0 + 8 * 86400)) $((D0 + 8 * 86400))" \
  "$(grep -o 'huecos=[0-9]* tramos=[0-9]*' "$T/a6.err")|$(grep '^HUECO' "$T/a6.err")"
igual "A6 ...y la Heikin Ashi y las semanas no cambian por ser laborable" \
  "$(awk -v producto=TEK-T -v ahora=$((D0 + 9 * 86400 + 3600)) -v desde=0 -v salida=tsv -f "$CALC" "$T/a6b.txt" 2>/dev/null | cut -f1-11,13)" "$(cut -f1-11,13 "$T/a6.out")"
lab 0 $((D0 + 9 * 86400 + 3600)) "$T/a6b.txt"
igual "A6 sin laborable, el fin de semana si cuenta como hueco" "huecos=3 tramos=2" "$(grep -o 'huecos=[0-9]* tramos=[0-9]*' "$T/a6.err")"
# Un hueco que cruza el fin de semana: del viernes al lunes faltan los dos habiles.
{ for k in 0 1 2 3; do printf '%s 100 110 90 105 1\n' "$((D0 + k * 86400))"; done; printf '%s 100 110 90 105 1\n' "$((D0 + 8 * 86400))"; } > "$T/a6c.txt"
lab 1 $((D0 + 8 * 86400 + 3600)) "$T/a6c.txt"
igual "A6 laborable: faltan el viernes y el lunes: 2 dias en 1 tramo, del viernes al lunes" "huecos=2 tramos=1|HUECO $((D0 + 4 * 86400)) $((D0 + 7 * 86400))" \
  "$(grep -o 'huecos=[0-9]* tramos=[0-9]*' "$T/a6.err")|$(grep '^HUECO' "$T/a6.err")"
{ cat "$T/a6.txt"; printf '%s 100 110 90 105 1\n' "$((D0 + 5 * 86400))"; } > "$T/a6d.txt"
lab 1 $((D0 + 6 * 86400)) "$T/a6d.txt"
igual "A6 laborable con una vela de sabado: el resumen la cuenta (finde=1) para que la pasada lo diga" "finde=1" "$(grep -o 'finde=[0-9]*' "$T/a6.err")"
lab 0 $((D0 + 6 * 86400)) "$T/a6d.txt"
igual "A6 ...sin laborable no se cuenta" "finde=0" "$(grep -o 'finde=[0-9]*' "$T/a6.err")"
lab 2 $((D0 + 5 * 86400)) "$T/a6.txt"; r=$?
igual "A6 laborable que no es 0 ni 1: sale con 2 sin emitir nada" "2|0|si" "$r|$(wc -l < "$T/a6.out" | tr -d ' ')|$(grep -q 'ERROR laborable' "$T/a6.err" && echo si)"

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

# ============================ I. Indicadores ==================================
# Largos cortos (EMA 3 y 5, Bollinger 3, canal de 4) para poder hacer las
# cuentas a mano. Cierres reales 1 2 3 4 5 9 2; Heikin Ashi plano en 10.
IND="$BTC/indicadores-calculo.awk"
CORTOS="-v ema_a=3 -v ema_b=5 -v bb_n=3 -v rl_n=4 -v rl_k=2"
: > "$T/i1.txt"; k=0
for c in 1 2 3 4 5 9 2; do
  printf '1d\t%d\t%s\t%s\t%s\t%s\t1\t10\t10\t10\t10\t%d\tnull\n' $((D0 + k * 86400)) $c $c $c $c $([ $k -lt 6 ] && echo 1 || echo 0) >> "$T/i1.txt"
  k=$((k + 1))
done
printf '1w\t%d\t1\t5\t1\t100\t1\t1\t1\t1\t100\t1\t7\n1w\t%d\t9\t9\t2\t200\t1\t1\t1\t1\t200\t0\t1\n' "$D0" $((D0 + 7 * 86400)) >> "$T/i1.txt"
awk $CORTOS -v producto=X -v desde=0 -v salida=tsv -f "$IND" "$T/i1.txt" > "$T/i1.out" 2> "$T/i1.err"; r=$?
igual "I1 sale bien y emite una fila por vela y base" "0 18" "$r $(wc -l < "$T/i1.out" | tr -d ' ')"
col(){ awk -F"$TAB" -v m="$1" -v b="$2" -v c="$3" '$1 == m && $2 == b { printf "%s ", $c }' "$T/i1.out"; }
igual "I1 EMA 3: null hasta la 3a vela, que es la media simple; despues alfa 1/2" "null null 2 3 4 6.5 4.25 " "$(col 1d real 4)"
igual "I1 EMA 5: empieza en la 5a vela con la media de las 5" "null null null null 3 5 4 " "$(col 1d real 5)"
igual "I1 Bollinger 3: media 2 y desviacion poblacional sqrt(2/3) en la 3a vela" "2 1.632993" \
  "$(awk -F"$TAB" '$1 == "1d" && $2 == "real" && NR == 5 { printf "%s %.6f", $6, $7 - $6 }' "$T/i1.out")"
igual "I1 canal sobre 1 2 3 4 (recta perfecta): centro 4, ancho 0, pendiente 1, R 1" "4 4 4 1 1" \
  "$(awk -F"$TAB" '$1 == "1d" && $2 == "real" && $3 == '$((D0 + 3 * 86400))' { print $9, $10, $11, $12, $13 }' "$T/i1.out")"
igual "I1 canal sobre 3 4 5 9: centro 8.1, pendiente 1.9, ancho 2*sqrt(0.9)" "8.100000 1.900000 1.897367" \
  "$(awk -F"$TAB" '$1 == "1d" && $2 == "real" && $3 == '$((D0 + 5 * 86400))' { printf "%.6f %.6f %.6f", $9, $12, $10 - $9 }' "$T/i1.out")"
igual "I1 rupturas: 5 cae en el canal prolongado, 9 lo rompe al alza y 2 a la baja" "null null null null 0 1 -1 " "$(col 1d real 14)"
igual "I1 la base ha usa el cierre Heikin Ashi (plano: todo 10, ancho 0, R 0, sin rupturas)" "10 10 10 10 10 0 0 0" \
  "$(awk -F"$TAB" '$1 == "1d" && $2 == "ha" && $3 == '$((D0 + 6 * 86400))' { print $4, $6, $7, $9, $10, $12, $13, $14 }' "$T/i1.out")"
igual "I1 las semanas son otra serie: con 2 velas todo es null" "null null null null null null " \
  "$(awk -F"$TAB" '$1 == "1w" && $2 == "real" { printf "%s %s %s ", $4, $6, $9 }' "$T/i1.out")"
igual "I1 cerrada se copia de la vela" "1 0 " "$(awk -F"$TAB" '$2 == "real" && ($3 == '$((D0 + 5 * 86400))' || $3 == '$((D0 + 6 * 86400))') && $1 == "1d" { printf "%s ", $15 }' "$T/i1.out")"

# Con 'desde' emite solo lo reciente, con los MISMOS valores que con toda la
# historia, y cuenta las filas que deja atras (las dos bases).
awk $CORTOS -v producto=X -v desde=$((D0 + 4 * 86400)) -v salida=tsv -f "$IND" "$T/i1.txt" > "$T/i2.out" 2> "$T/i2.err"
igual "I2 'desde' emite las diarias desde ese dia y las semanas que acaban despues (la 0 contiene el dia 4)" "1d 4|1d 5|1d 6|1w 0|1w 1|" \
  "$(awk -F"$TAB" -v d0=$D0 '$2 == "real" { printf "%s %d|", $1, ($3 - d0) / ($1 == "1d" ? 86400 : 604800) }' "$T/i2.out")"
igual "I2 ...con los mismos valores que calculando todo" "" \
  "$(awk -F"$TAB" 'NR == FNR { v[$1 $2 $3] = $0; next } v[$1 $2 $3] != $0' "$T/i1.out" "$T/i2.out")"
igual "I2 previas cuenta lo que no emitio: 4 diarias x 2 bases" "previas=8" "$(grep -o 'previas=[0-9]*' "$T/i2.err")"
awk $CORTOS -v producto=X -v desde=$((D0 + 7 * 86400)) -v salida=tsv -f "$IND" "$T/i1.txt" > /dev/null 2> "$T/i2.err"
igual "I2 con desde en el lunes siguiente la semana 0 ya no se emite: (7 diarias + 1 semana) x 2" "previas=16" "$(grep -o 'previas=[0-9]*' "$T/i2.err")"

printf '1d\t1\t1\t1\t1\t1\t1\t1\t1\t1\t1\t1\n' > "$T/i3.txt"
awk -v producto=X -f "$IND" "$T/i3.txt" > /dev/null 2>&1; r=$?
igual "I3 una linea con 12 campos se rechaza (sale con 2)" "2" "$r"
printf '1d\t%d\t1\t1\t1\t1\t1\t1\t1\t1\t1\t1\tnull\n' 200 100 > "$T/i3.txt"
awk -v producto=X -f "$IND" "$T/i3.txt" > /dev/null 2>&1; r=$?
igual "I3 una serie desordenada se rechaza (sale con 2)" "2" "$r"

awk $CORTOS -v producto=BTC-USD -v desde=0 -v actualizado=7 -f "$IND" "$T/i1.txt" > "$T/i4.out" 2>/dev/null
if command -v node >/dev/null 2>&1; then
  r=$(node -e '
    const L = require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n").map(l => JSON.parse(l));
    let ok = L.length === 18;
    for (const a of L) ok = ok && a.length === 19 && /^INSERT OR REPLACE INTO cripto_indicador\(producto,marco,base,ts,/.test(a[0]) && (a[0].match(/\?/g) || []).length === 18 && a[1] === "BTC-USD" && a[17] === 1 && a[18] === 7;
    const r6 = L.find(a => a[2] === "1d" && a[3] === "real" && a[4] === +process.argv[2]);
    ok = ok && r6 && r6[15] === 1 && r6[5] === 6.5 && L[0][5] === null;
    console.log(ok ? "si" : "no");' "$T/i4.out" $((D0 + 5 * 86400)) 2>&1)
  igual "I4 cada sentencia JSON es valida y lleva 18 parametros" "si" "$r"

  # Toda la serie falsa (1.411 dias), con los largos de verdad y con los cortos,
  # contra el calculo independiente en JavaScript.
  node -e 'const { velas } = require(process.argv[1]); for (const v of velas({ ahora: 1794506400 }, "BTC-USD")) console.log(v.t, v.o, v.h, v.l, v.c, v.v);' "$AQUI/serie-falsa.js" > "$T/i5.txt"
  awk -v producto=X -v ahora=1794506340 -v desde=0 -v salida=tsv -f "$CALC" "$T/i5.txt" > "$T/i5.tsv" 2>/dev/null
  awk -v producto=X -v desde=0 -v salida=tsv -f "$IND" "$T/i5.tsv" > "$T/i5.out" 2>/dev/null
  r=$(node "$AQUI/compara-tsv.js" "$T/i5.tsv" "$T/i5.out" 2>&1)
  case "$r" in coincide*) pasa "I5 serie falsa completa, largos de verdad: $r" ;; *) falla "I5 serie falsa completa, largos de verdad" "$r" ;; esac
  awk $CORTOS -v producto=X -v desde=0 -v salida=tsv -f "$IND" "$T/i5.tsv" > "$T/i5c.out" 2>/dev/null
  r=$(node "$AQUI/compara-tsv.js" "$T/i5.tsv" "$T/i5c.out" ema_a=3 ema_b=5 bb_n=3 rl_n=4 rl_k=2 2>&1)
  case "$r" in coincide*) pasa "I5 serie falsa completa, largos cortos: $r" ;; *) falla "I5 serie falsa completa, largos cortos" "$r" ;; esac
  # Huella fija de la salida con los largos de verdad, junto a la VERSION del
  # calculo. Si cambia es que cambio el calculo: hay que subir VERSION en
  # indicadores-calculo.awk (asi la red lo reescribe todo en la proxima pasada)
  # y poner aqui la version y la huella nuevas.
  HUELLA_IND="1 2407514039 566608"
  igual "I6 la salida no cambio sin subir VERSION (si cambiaste el calculo: sube VERSION y pon la huella nueva)" "$HUELLA_IND" \
    "$(sed -n 's/^ *VERSION = \([0-9]*\).*/\1/p' "$IND" | head -1) $(cksum < "$T/i5.out")"
fi

# ============================ F. Fibonacci ====================================
FIB="$BTC/fibonacci-calculo.awk"
# fserie <fichero> "maximo minimo cierre [dia]" ... : una vela diaria por
# argumento; sin dia, la siguiente a la anterior (la primera, D0). Para
# Fibonacci solo cuentan esos tres: la apertura y las columnas Heikin Ashi
# llevan OTROS valores a proposito, para que leer una columna equivocada se note.
fserie(){ f=$1; shift; printf '%s\n' "$@" | awk -v d0=$D0 '
  { d = (NF >= 4) ? $4 : d + 1; if (NR == 1 && NF < 4) d = 0
    printf "1d\t%d\t%s\t%s\t%s\t%s\t1\t1\t%s\t%s\t%s\t1\tnull\n", d0 + d * 86400, ($1 + $2) / 2, $1, $2, $3, $1 * 10, $2 / 10, $3 * 7 }' > "$f"; }
# fib <fichero> [-v ...]: "dia_bajo:bajo->dia_alto:alto caida X | nivel=precio ..."
# (dias contados desde D0) o "sin ciclo". El resumen queda en $T/f.err. Va con
# dura=0 (sin duracion minima) salvo que se pase otra: la duracion se prueba
# aparte (F12).
fib(){ f=$1; shift
  awk -v dura=0 "$@" -v salida=tsv -f "$FIB" "$f" 2> "$T/f.err" | awk -F"$TAB" -v d0=$D0 '
    { n++; if (n == 1) printf "%d:%s->%d:%s caida %s |", ($3 - d0) / 86400, $4, ($5 - d0) / 86400, $6, $7; printf " %s=%s", $1, $2 }
    END { if (!n) printf "sin ciclo" }'; }
anclas(){ r=$(fib "$@"); printf '%s' "${r%% |*}"; }

CICLO="2:30->4:150 caida 0.55 | 0=150 0.236=121.68 0.382=104.16 0.5=90 0.618=75.84 0.786=55.68 1=30"
fserie "$T/f1.txt" "100 90 95" "98 40 45" "70 30 60" "99 50 90" "150 95 140" "145 120 130"
igual "F1 cierre un 55 % bajo el maximo y luego un maximo nuevo: ciclo del fondo (mecha) al maximo, niveles de TradingView" "$CICLO" "$(fib "$T/f1.txt")"
igual "F1 el resumen dice donde esta el ultimo cierre (130: retroceso 1/6)" "ciclo=1 retroceso=0.166666666666667" \
  "$(sed -n 's/^RESUMEN_FIB \(ciclo=1\) .*\(retroceso=[0-9.]*\).*/\1 \2/p' "$T/f.err")"
igual "F1 ...y las dos anclas, con su dia" "bajo_ts=$((D0 + 2 * 86400)) bajo=30 alto_ts=$((D0 + 4 * 86400)) alto=150 caida=0.55 cierre=130" \
  "$(sed -n 's/^RESUMEN_FIB ciclo=1 \(.*cierre=[0-9.]*\).*/\1/p' "$T/f.err")"
fserie "$T/f2.txt" "100 90 95" "98 40 45" "70 30 60" "99 50 90" "150 95 140" "145 120 130" "140 20 25"
igual "F2 una caida en curso, aun sin maximo nuevo, no mueve el tramo" "$CICLO" "$(fib "$T/f2.txt")"
fserie "$T/f2.txt" "100 90 95" "98 40 45" "70 30 60" "99 50 90" "150 95 140" "145 120 130" "140 20 25" "151 100 150"
igual "F2 ...y en cuanto se supera el maximo, el ciclo es el de esa caida (la ultima)" "6:20->7:151 caida 0.833333333333333" "$(anclas "$T/f2.txt")"
fserie "$T/f3.txt" "100 90 95" "99 10 80" "120 100 110"
igual "F3 una mecha del 90 % con cierres altos no es una caida importante" "sin ciclo" "$(fib "$T/f3.txt")"
igual "F3 ...el resumen lo dice" "RESUMEN_FIB ciclo=0 diarias=3" "$(cat "$T/f.err")"
igual "F3 ...y el json solo borra lo que hubiera del producto" '["DELETE FROM cripto_fibonacci WHERE producto=?","BTC-USD"]' \
  "$(awk -v dura=0 -v producto=BTC-USD -v actualizado=5 -f "$FIB" "$T/f3.txt" 2>/dev/null)"
fserie "$T/f4.txt" "100 90 95" "99 52 53" "120 100 110"
igual "F4 un cierre un 47 % abajo: con el 50 % no hay ciclo" "sin ciclo" "$(fib "$T/f4.txt")"
igual "F4 ...con caida=0.3 si" "1:52->2:120 caida 0.47" "$(anclas "$T/f4.txt" -v caida=0.3)"
fserie "$T/f4.txt" "100 90 95" "99 45 50" "120 100 110"
igual "F4 un cierre justo en el 50 % ya cuenta" "1:45->2:120 caida 0.5" "$(anclas "$T/f4.txt")"
fserie "$T/f4.txt" "100 90 95" "99 45 50.01" "120 100 110"
igual "F4 ...y uno un centimo por encima, no" "sin ciclo" "$(fib "$T/f4.txt")"
# Con precios de verdad el margen del borde (1e-12) tiene que ser invisible:
# 126.296 -> 63.148 es justo la mitad; 63.148,01, ya no.
fserie "$T/f4.txt" "126296 120000 125000" "100000 60000 63148" "126300 120000 125000"
r=$(anclas "$T/f4.txt")
fserie "$T/f4.txt" "126296 120000 125000" "100000 60000 63148.01" "126300 120000 125000"
igual "F4 ...tambien con precios reales: 126.296 -> 63.148 cuenta y 63.148,01 no" "1:60000->2:126300 caida 0.5 / sin ciclo" "$r / $(fib "$T/f4.txt")"
# Bordes donde la cuenta en coma flotante se queda corta: 90 x 0,7 = 62,99999...
fserie "$T/f4.txt" "90 85 88" "85 60 63" "100 90 95"
igual "F4 ...tambien con caida=0.3 (90 -> 63, justo un 30 %)" "1:60->2:100 caida 0.3" "$(anclas "$T/f4.txt" -v caida=0.3)"
fserie "$T/f4.txt" "100 90 95" "85 70 80" "120 100 110"
igual "F4 ...y con caida=0.2 (100 -> 80, justo un 20 %)" "1:70->2:120 caida 0.2" "$(anclas "$T/f4.txt" -v caida=0.2)"
fserie "$T/f5.txt" "100 90 95" "100 40 45" "101 95 100"
igual "F5 igualar el maximo no es un maximo nuevo: la vela sigue en la caida" "1:40->2:101 caida 0.55" "$(anclas "$T/f5.txt")"
fserie "$T/f5.txt" "100 90 95" "90 30 45" "80 30 40" "120 100 110"
igual "F5 dos minimos iguales: el ancla es el primero" "1:30->3:120 caida 0.6" "$(anclas "$T/f5.txt")"
fserie "$T/f6.txt" "100 10 20" "101 95 100"
igual "F6 la vela del maximo no es parte de su caida (aunque cierre abajo)" "sin ciclo" "$(fib "$T/f6.txt")"
fserie "$T/f6.txt" "100 90 95" "90 44 45" "150 10 140"
igual "F6 ...ni la que lo supera: su minimo no es el fondo" "1:44->2:150 caida 0.55" "$(anclas "$T/f6.txt")"
{ cat "$T/f1.txt"; printf '1w\t%d\t1\t1000\t1\t1\t1\t1\t1000\t1\t1\t1\t7\n' "$D0"; } > "$T/f7.txt"
igual "F7 las semanales no cuentan" "$CICLO" "$(fib "$T/f7.txt")"
r=""
printf '1d\t1\t1\t1\t1\t1\t1\t1\t1\t1\t1\t1\n' > "$T/f8.txt"; awk -f "$FIB" "$T/f8.txt" > /dev/null 2>&1; r="$r$?"
printf '1d\t%d\t1\t1\t1\t1\t1\t1\t1\t1\t1\t1\tnull\n' 200 100 > "$T/f8.txt"; awk -f "$FIB" "$T/f8.txt" > /dev/null 2>&1; r="$r $?"
printf '1d\t%d\t1\t1\t1\t1\t1\t1\t1\t1\t1\t1\tnull\n' 100 100 > "$T/f8.txt"; awk -f "$FIB" "$T/f8.txt" > /dev/null 2>&1; r="$r $?"
printf '1m\t1\t1\t1\t1\t1\t1\t1\t1\t1\t1\t1\tnull\n' > "$T/f8.txt"; awk -f "$FIB" "$T/f8.txt" > /dev/null 2>&1; r="$r $?"
for o in caida=1 caida=0 caida=-0.5 dura=-1 salida=xml; do awk -v "$o" -f "$FIB" "$T/f1.txt" > /dev/null 2>&1; r="$r $?"; done
igual "F8 se rechaza con 2: 12 campos, desordenada, repetida, marco raro, caida 1, 0 o negativa, dura negativa y salida rara" "2 2 2 2 2 2 2 2 2" "$r"
awk -v caida=1 -f "$FIB" "$T/f1.txt" 2>&1 >/dev/null | grep -q '^ERROR caida' \
  && pasa "F8 ...con una linea ERROR que lo explica" || falla "F8 ...con una linea ERROR que lo explica"

# La vela de hoy, aun abierta, tambien cuenta: si hace un maximo nuevo, el
# tramo cambia ya.
fserie "$T/f12.txt" "100 90 95" "98 40 45" "160 100 150"
awk -F"$TAB" -v OFS="$TAB" 'NR == 3 { $12 = 0 } 1' "$T/f12.txt" > "$T/f12b.txt"
igual "F9 la vela abierta cuenta: si supera el maximo, cierra la caida y es el ancla alta" "1:40->2:160 caida 0.55" "$(anclas "$T/f12b.txt")"
igual "F9 ...y el resumen da su cierre" "cierre=150" "$(grep -o 'cierre=[0-9.]*' "$T/f.err")"

# La duracion: un mercado bajista tarda al menos `dura` dias (365) en volver a
# superar su maximo. Las correcciones a mitad de ciclo no mueven el tramo, como
# la de 2021 en el spot (-54 % al cierre, superada en 189 dias).
fserie "$T/f12.txt" "100 90 95 0" "98 40 45 10" "150 95 140 364"
igual "F10 una caida del 55 % superada en 364 dias no es un mercado bajista" "sin ciclo" "$(fib "$T/f12.txt" -v dura=365)"
fserie "$T/f12.txt" "100 90 95 0" "98 40 45 10" "150 95 140 365"
igual "F10 ...en 365 dias, si" "10:40->365:150 caida 0.55" "$(anclas "$T/f12.txt" -v dura=365)"
r=$(awk -v salida=tsv -f "$FIB" "$T/f12.txt" 2>/dev/null | wc -l | tr -d ' ')
fserie "$T/f12.txt" "100 90 95 0" "98 40 45 10" "150 95 140 364"
igual "F10 ...y 365 dias es lo que se usa si no se dice nada (365: 7 niveles; 364: ninguno)" "7 0" \
  "$r $(awk -v salida=tsv -f "$FIB" "$T/f12.txt" 2>/dev/null | wc -l | tr -d ' ')"
# Como 2018 -> 2021 -> 2022: un bajista largo, una correccion corta tan honda
# como el y un maximo nuevo. El tramo sigue en el fondo del bajista.
fserie "$T/f12.txt" "100 90 95 0" "60 15 20 300" "120 100 110 800" "200 150 190 900" "150 85 90 950" "210 180 200 1000"
igual "F10 una correccion corta del 55 % entre dos maximos no sustituye al ultimo mercado bajista" "300:15->1000:210 caida 0.8" "$(anclas "$T/f12.txt" -v dura=365)"

# Las extensiones de TradingView (1,618...) solo cuando dan un precio positivo.
fserie "$T/f13.txt" "120 110 115" "100 58 59" "125 100 120"
igual "F11 con un tramo corto (58 -> 125) sale tambien el 1,618 (125 - 1,618 x 67); el 2,618 seria negativo" \
  "1:58->2:125 caida 0.508333333333333 | 0=125 0.236=109.188 0.382=99.406 0.5=91.5 0.618=83.594 0.786=72.338 1=58 1.618=16.594" "$(fib "$T/f13.txt")"
# Una extension que vale justo 0 no se emite, aunque el redondeo la deje en
# +-1e-13: 787,95 -> 2.062,95 (309/809) da 2062,95 - 1,618 x 1275 = 0.
fserie "$T/f13.txt" "1800 1700 1750" "1000 787.95 850" "2062.95 1900 2000"
awk -v dura=0 -v salida=tsv -f "$FIB" "$T/f13.txt" > "$T/f13.out" 2>/dev/null
igual "F11 ...y una que da justo 0 no sale" "1:787.95->2:2062.95 caida 0.527777777777778 7 niveles" "$(anclas "$T/f13.txt") $(wc -l < "$T/f13.out" | tr -d ' ') niveles"

if command -v node >/dev/null 2>&1; then
  awk -v dura=0 -v producto=BTC-USD -v actualizado=7 -f "$FIB" "$T/f1.txt" > "$T/f9.out" 2>/dev/null
  r=$(node -e '
    const L = require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n").map(l => JSON.parse(l));
    const d0 = +process.argv[2], niv = [0, 0.236, 0.382, 0.5, 0.618, 0.786, 1];
    let ok = L.length === 8 && JSON.stringify(L[0]) === JSON.stringify(["DELETE FROM cripto_fibonacci WHERE producto=?", "BTC-USD"]);
    L.slice(1).forEach((a, i) => { ok = ok && a.length === 11 && /^INSERT INTO cripto_fibonacci\(producto,tramo,nivel,precio,bajo_ts,bajo,alto_ts,alto,caida,actualizado\) VALUES/.test(a[0])
      && (a[0].match(/\?/g) || []).length === 10 && a[1] === "BTC-USD" && a[2] === "ciclo" && a[3] === niv[i]
      && a[5] === d0 + 2 * 86400 && a[6] === 30 && a[7] === d0 + 4 * 86400 && a[8] === 150 && a[10] === 7; });
    console.log(ok ? "si" : "no");' "$T/f9.out" "$D0" 2>&1)
  igual "F12 json: primero el DELETE del producto y despues un INSERT valido por nivel, con sus 10 parametros" "si" "$r"

  # La serie falsa entera (sin ciclo de verdad; con el 20 % y sin duracion
  # minima, si) contra la referencia, y 480 series al azar (4 semillas) con
  # empates (precios enteros), caidas y duraciones de todos los tamaños.
  r=""
  for o in "caida=0.5" "caida=0.2 dura=0"; do
    awk $(for kv in $o; do printf ' -v %s' "$kv"; done) -v salida=tsv -f "$FIB" "$T/i5.tsv" > "$T/f10.out" 2>/dev/null
    r="$r$(node "$AQUI/fibonacci-ref.js" "$T/i5.tsv" "$T/f10.out" $o 2>&1); "
  done
  case "$r" in "coincide: sin ciclo; coincide: ciclo "*) pasa "F13 la serie falsa completa coincide con la referencia: $r" ;; *) falla "F13 la serie falsa completa coincide con la referencia" "$r" ;; esac
  igual "F13 la referencia tampoco emite la extension que da justo 0 (F11)" "coincide: ciclo 787.95 -> 2062.95, 7 niveles" \
    "$(node "$AQUI/fibonacci-ref.js" "$T/f13.txt" "$T/f13.out" dura=0 2>&1)"
  r=$(node -e '
    const { spawnSync } = require("child_process"), FR = require(process.argv[1]);
    let malas = 0, ciclos = 0, ext = 0, msg = "";
    for (const semilla of [1, 11, 15, 42]) {
      let s = semilla;
      const rnd = () => { s = (Math.imul(s, 1103515245) + 12345) >>> 0; return s / 4294967296; };
      for (let k = 0; k < 120; k++) {
        const n = 3 + Math.floor(rnd() * 300), caida = [0.2, 0.3, 0.5, 0.7][k % 4], dura = [0, 3, 20, 60][(k >> 2) % 4], vs = [];
        let p = 100;
        for (let i = 0; i < n; i++) {
          const o = p; p = Math.max(1, Math.round(p * Math.exp((rnd() - 0.5) * 0.6)));
          vs.push({ marco: "1d", ts: 1704067200 + i * 86400, o, h: Math.max(o, p) + Math.floor(rnd() * 4), l: Math.max(1, Math.min(o, p) - Math.floor(rnd() * 4)), c: p });
        }
        // La apertura y las columnas Heikin Ashi, con otros valores a proposito.
        const tsv = vs.map(v => ["1d", v.ts, v.o, v.h, v.l, v.c, 1, 1, v.h * 10, v.l / 10, v.c * 7, 1, "null"].join("\t")).join("\n") + "\n";
        const out = spawnSync("awk", ["-v", "salida=tsv", "-v", "caida=" + caida, "-v", "dura=" + dura, "-f", process.argv[2]], { input: tsv, encoding: "utf8" });
        const got = out.stdout.split("\n").filter(Boolean).map(l => l.split("\t").map(Number)).map(a => ({ nivel: a[0], precio: a[1], bajo_ts: a[2], bajo: a[3], alto_ts: a[4], alto: a[5], caida: a[6] }));
        const exp = FR.fibonacci(vs, { caida, dura });
        if (exp) { ciclos++; if (exp.niveles.length > 7) ext++; }
        const f = FR.compara(got, exp, 2);
        if (out.status !== 0 || f.length) { malas++; if (!msg) msg = `semilla ${semilla} serie ${k}: ${out.status} ${f.join(" | ")}`; }
      }
    }
    // Sin ciclos o sin extensiones la prueba no probaria nada.
    if (!malas && (ciclos < 100 || ext < 10)) { malas = 1; msg = `pocos casos: ${ciclos} con ciclo, ${ext} con extensiones`; }
    console.log(malas ? `NO COINCIDE: ${malas} series; ${msg}` : `coincide en las 480 (${ciclos} con ciclo, ${ext} con extensiones)`);' "$AQUI/fibonacci-ref.js" "$FIB" 2>&1)
  case "$r" in "coincide en las 480"*) pasa "F14 series al azar contra la referencia: $r" ;; *) falla "F14 series al azar contra la referencia" "$r" ;; esac
fi

# ============================ V. Señales ======================================
AVIS="$BTC/avisos-calculo.awk"
# Corriente a mano. vv <prod> <marco> <ts> <cierre> <ha_apertura> <ha_cierre> [cerrada]
vv(){ printf '%s\tV\t%s\t%s\t%s\t%s\t%s\t%s\t1\t%s\t%s\t%s\t%s\t%s\tnull\n' "$1" "$2" "$3" "$4" "$4" "$4" "$4" "$5" "$6" "$5" "$6" "${7:-1}"; }
# ii <prod> <marco> <ts> <ema100> <ema200> <rl_centro> <rl_sup> <rl_pendiente> <rl_ruptura> [base]
ii(){ printf '%s\tI\t%s\t%s\t%s\t%s\t%s\tnull\tnull\tnull\t%s\t%s\tnull\t%s\tnull\t%s\t1\n' "$1" "$2" "${10:-real}" "$3" "$4" "$5" "$6" "$7" "$8" "$9"; }
# ff <prod> <nivel> <precio>: el mismo nivel (ciclo 80 -> 120) para cada vela de
# $FC (los niveles van por vela candidata: los de antes de que cerrara).
# fx <prod> <vela> <nivel> <precio> <alto>: un nivel solo para esa vela.
ff(){ for c_ in $FC; do printf '%s\tF\t%s\t%s\t%s\t1\t80\t2\t120\t0.333\n' "$1" "$c_" "$2" "$3"; done; }
fx(){ printf '%s\tF\t%s\t%s\t%s\t1\t80\t2\t%s\t0.333\n' "$1" "$2" "$3" "$4" "$5"; }
D1=$D0; D2=$((D0 + 86400)); D3=$((D0 + 2 * 86400)); D4=$((D0 + 3 * 86400)); D5=$((D0 + 4 * 86400))
FC="$D1 $D2 $D3 $D4"
P=BIP-T
{ vv $P 1d $D1 100 100 101; vv $P 1d $D2 110 100.5 105; vv $P 1d $D3 90 102 95; vv $P 1d $D4 95 98 98; vv $P 1d $D5 200 1 2 0
  ii $P 1d $D1 105 null null null null null; ii $P 1d $D2 105 null 100 104 2 0; ii $P 1d $D2 999 null 100 104 2 0 ha
  ii $P 1d $D3 95 100 97 101 1 -1; ii $P 1d $D4 94 99 96 100 1 -1; ii $P 1d $D5 1 1 1 1 1 1
  ff $P 0 120; ff $P 0.5 100; ff $P 1 80; } > "$T/v1.txt"
awk -v orden="$P" -v desde=$D0 -v salida=tsv -f "$AVIS" "$T/v1.txt" > "$T/v1.out" 2> "$T/v1.err"
cat > "$T/v1.esp" <<EOF
1d${TAB}$D2${TAB}ema100${TAB}$P${TAB}1${TAB}110${TAB}105${TAB}📈 Perpetuo, diaria del 02/01: cierra por encima de la EMA 100: cierre 110, EMA 105
1d${TAB}$D2${TAB}fib${TAB}$P${TAB}1${TAB}110${TAB}100${TAB}📐 Perpetuo, diaria del 02/01: recupera el 50 % (100) de Fibonacci (ciclo 80 → 120); cierre 110
1d${TAB}$D3${TAB}canal${TAB}$P${TAB}-1${TAB}90${TAB}98${TAB}📉 Perpetuo, diaria del 03/01: rompe el canal de regresión hacia abajo: cierre 90, borde inferior 98
1d${TAB}$D3${TAB}ema100${TAB}$P${TAB}-1${TAB}90${TAB}95${TAB}📉 Perpetuo, diaria del 03/01: cierra por debajo de la EMA 100: cierre 90, EMA 95
1d${TAB}$D3${TAB}fib${TAB}$P${TAB}-1${TAB}90${TAB}100${TAB}📐 Perpetuo, diaria del 03/01: pierde el 50 % (100) de Fibonacci (ciclo 80 → 120); cierre 90
1d${TAB}$D3${TAB}ha${TAB}$P${TAB}-1${TAB}90${TAB}95${TAB}🔴 Perpetuo, diaria del 03/01: la vela Heikin Ashi pasa a roja
1d${TAB}$D4${TAB}ema100${TAB}$P${TAB}1${TAB}95${TAB}94${TAB}📈 Perpetuo, diaria del 04/01: cierra por encima de la EMA 100: cierre 95, EMA 94
EOF
if cmp -s "$T/v1.out" "$T/v1.esp"; then pasa "V1 cada señal en su vela, con su sentido y su texto (EMA, canal con su borde, Fibonacci, Heikin Ashi)"
else falla "V1 señales hechas a mano" "$(diff "$T/v1.esp" "$T/v1.out" | head -8 | tr '\n' '|')"; fi
igual "V1 resumen: 7 señales en 4 velas candidatas (la abierta no cuenta)" "RESUMEN_AV senales=7 candidatas=4" "$(cat "$T/v1.err")"
# Lo que no da señal: la EMA 200 sin dato en la vela anterior, el cruce entre EMA
# sin cambio, la ruptura que sigue (-1 tras -1), el Heikin Ashi sin color (se
# compara con la ultima que lo tuvo) y la base "ha" (999) que no se mira.
igual "V1 ...y nada de lo que no es señal" "0" "$(grep -c -E 'ema200|emas|verde|04/01: rompe' "$T/v1.out")"
# Cerrar justo en el nivel es estar debajo: de 100 (en el nivel) a 110 cruza; de 105 a 100, tambien.
{ vv $P 1d $D1 105 1 2; vv $P 1d $D2 100 1 2; vv $P 1d $D3 100 1 2; vv $P 1d $D4 110 1 2
  for d in $D1 $D2 $D3 $D4; do ii $P 1d $d null null null null null null; done; ff $P 0 120; ff $P 0.5 100; ff $P 1 80; } > "$T/v1b.txt"
igual "V1 cerrar justo en el nivel cuenta como debajo" "$D2 -1|$D4 1|" \
  "$(awk -v orden="$P" -v desde=$D0 -v salida=tsv -f "$AVIS" "$T/v1b.txt" 2>/dev/null | awk -F"$TAB" '$3 == "fib" { printf "%s %s|", $2, $5 }')"
# Varios niveles en una vela: en el orden en que los cruza, y el nivel guardado es el primero.
{ vv $P 1d $D1 125 1 2; vv $P 1d $D2 75 1 2; vv $P 1d $D3 119 1 2
  for d in $D1 $D2 $D3; do ii $P 1d $d null null null null null null; done; ff $P 0 120; ff $P 0.5 100; ff $P 1 80; } > "$T/v1c.txt"
awk -v orden="$P" -v desde=$D0 -v salida=tsv -f "$AVIS" "$T/v1c.txt" > "$T/v1c.out" 2>/dev/null
igual "V1 bajando cruza de arriba abajo, y los extremos van con su nombre" "120|pierde el máximo del ciclo (120) y el 50 % (100) y el mínimo del ciclo (80) de Fibonacci" \
  "$(awk -F"$TAB" '$2 == '$D2' { t = $8; sub(/.*: /, "", t); sub(/ \(ciclo.*/, "", t); print $7 "|" t }' "$T/v1c.out")"
igual "V1 ...y subiendo, de abajo arriba" "80|recupera el mínimo del ciclo (80) y el 50 % (100) de Fibonacci" \
  "$(awk -F"$TAB" '$2 == '$D3' { t = $8; sub(/.*: /, "", t); sub(/ \(ciclo.*/, "", t); print $7 "|" t }' "$T/v1c.out")"
# Heikin Ashi verde tras roja; las EMA cruzandose entre si en los dos sentidos.
{ vv $P 1d $D1 100 101 100; vv $P 1d $D2 100 100 101; vv $P 1d $D3 100 100 101
  ii $P 1d $D1 50 60 null null null null; ii $P 1d $D2 70 60 null null null null; ii $P 1d $D3 50 60 null null null null; } > "$T/v1d.txt"
igual "V1 pasa a verde, cruce dorado y cruce de la muerte" \
  "$D2 emas 1 60 la EMA 100 cruza por encima de la EMA 200 (cruce dorado): EMA 100 70, EMA 200 60|$D2 ha 1 101 la vela Heikin Ashi pasa a verde|$D3 emas -1 60 la EMA 100 cruza por debajo de la EMA 200 (cruce de la muerte): EMA 100 50, EMA 200 60|" \
  "$(awk -v orden="$P" -v desde=$D0 -v salida=tsv -f "$AVIS" "$T/v1d.txt" 2>/dev/null | awk -F"$TAB" '{ t = $8; sub(/^[^:]*: /, "", t); printf "%s %s %s %s %s|", $2, $3, $5, $7, t }')"
# Roja, sin color, verde: la de sin color no cambia nada y la verde se compara
# con la roja (la ultima con color). Y cerrar justo en la EMA es cerrar debajo.
{ vv $P 1d $D1 100 101 100; vv $P 1d $D2 100 100 100; vv $P 1d $D3 100 100 101
  ii $P 1d $D1 99 null null null null null; ii $P 1d $D2 100 null null null null null; ii $P 1d $D3 99.5 null null null null null; } > "$T/v1e.txt"
igual "V1 roja, sin color, verde: pasa a verde en la tercera; cerrar en la EMA es debajo" "$D2 ema100 -1|$D3 ema100 1|$D3 ha 1|" \
  "$(awk -v orden="$P" -v desde=$D0 -v salida=tsv -f "$AVIS" "$T/v1e.txt" 2>/dev/null | awk -F"$TAB" '{ printf "%s %s %s|", $2, $3, $5 }')"
# Verde, sin color, verde y roja, sin color, roja: ninguna señal. Y dos sin color
# seguidas antes de un cambio de verdad: la señal sale en la que cambia.
hav(){ # hav <ho1 hc1> <ho2 hc2> ... : velas desde D1 con esos Heikin Ashi -> tipos y sentidos
  d_=$D1; for par in "$@"; do vv $P 1d $d_ 100 ${par% *} ${par#* }; ii $P 1d $d_ null null null null null null; d_=$((d_ + 86400)); done > "$T/v1h.txt"
  awk -v orden="$P" -v desde=$D0 -v salida=tsv -f "$AVIS" "$T/v1h.txt" 2>/dev/null | awk -F"$TAB" '{ printf "%s %s %s|", $2, $3, $5 }'; }
igual "V1 verde, sin color, verde: nada" "" "$(hav "100 101" "100 100" "100 101")"
igual "V1 roja, sin color, roja: nada" "" "$(hav "101 100" "100 100" "101 100")"
igual "V1 verde, sin color, sin color, roja: pasa a roja en la cuarta" "$D4 ha -1|" "$(hav "100 101" "100 100" "100 100" "101 100")"
# Cada vela con sus niveles: los de antes de que cerrara. En la del 03/01 el
# 50 % esta en 105 (con los niveles del 02/01, en 100, 99 -> 103 lo cruzaria) y
# en la del 04/01 el maximo es 120: cerrar en 125 "supera el maximo del ciclo".
{ vv $P 1d $D1 100 1 2; vv $P 1d $D2 99 1 2; vv $P 1d $D3 103 1 2; vv $P 1d $D4 125 1 2
  for d in $D1 $D2 $D3 $D4; do ii $P 1d $d null null null null null null; done
  for d in $D2 $D4; do fx $P $d 0 120 120; fx $P $d 0.5 100 120; fx $P $d 1 80 120; done
  fx $P $D3 0 130 130; fx $P $D3 0.5 105 130; fx $P $D3 1 80 130; } > "$T/v1f.txt"
igual "V1 cada vela con sus niveles; por encima del maximo, supera el maximo del ciclo" \
  "$D4 fib 1 120 supera el máximo del ciclo (120) de Fibonacci (ciclo 80 → 120); cierre 125|" \
  "$(awk -v orden="$P" -v desde=$D0 -v salida=tsv -f "$AVIS" "$T/v1f.txt" 2>/dev/null | awk -F"$TAB" '{ t = $8; sub(/^[^:]*: /, "", t); printf "%s %s %s %s %s|", $2, $3, $5, $7, t }')"
grep -v "${TAB}F${TAB}$D4${TAB}" "$T/v1f.txt" > "$T/v1g.txt"
igual "V1 la misma vela sin sus niveles (sin ciclo entonces) no da Fibonacci" "" \
  "$(awk -v orden="$P" -v desde=$D0 -v salida=tsv -f "$AVIS" "$T/v1g.txt" 2>/dev/null | awk -F"$TAB" '{ printf "%s %s|", $2, $3 }')"

# Reparto: el perpetuo (BIP-T) sin EMA semanal ni Fibonacci; el spot si. El
# perpetuo manda donde tiene el dato aunque no haya señal (EMA diaria, Heikin
# Ashi), y el spot da la EMA semanal y Fibonacci.
W1=$D0; W2=$((D0 + 7 * 86400)); W3=$((D0 + 14 * 86400))
S=BTC-USD
{ vv $P 1d $D1 90 99 100; vv $P 1d $D2 95 99 100; ii $P 1d $D1 100 null null null null null; ii $P 1d $D2 100 null null null null null
  vv $P 1w $W1 100 99 100; vv $P 1w $W2 100 99 100; vv $P 1w $W3 100 99 100
  for w in $W1 $W2 $W3; do ii $P 1w $w null null null null null null; done
  vv $S 1d $D1 90 99 100; vv $S 1d $D2 110 101 100; ii $S 1d $D1 100 null null null null null; ii $S 1d $D2 100 null null null null null
  vv $S 1w $W1 100 99 100; vv $S 1w $W2 100 101 100; vv $S 1w $W3 110 99 100
  ii $S 1w $W1 105 null null null null null; ii $S 1w $W2 105 null null null null null; ii $S 1w $W3 105 null null null null null
  FC="$D1 $D2 $W2 $W3"; ff $S 0 120; ff $S 0.5 100; ff $S 1 80; FC="$D1 $D2 $D3 $D4"; } > "$T/v2.txt"
awk -v orden="$P $S" -v desde=$D0 -v salida=tsv -f "$AVIS" "$T/v2.txt" > "$T/v2.out" 2> "$T/v2.err"
igual "V2 el perpetuo manda donde tiene el dato; el spot da solo lo que al perpetuo le falta" \
  "1d $D2 fib $S|1w $W3 ema100 $S|1w $W3 fib $S|" "$(awk -F"$TAB" '{ printf "%s %s %s %s|", $1, $2, $3, $4 }' "$T/v2.out")"
grep -q "Spot, semanal del 15/01: cierra por encima de la EMA 100: cierre 110, EMA 105" "$T/v2.out" \
  && pasa "V2 ...y el texto dice que es del spot" || falla "V2 el texto dice Spot" "$(cat "$T/v2.out")"
igual "V2 con el spot primero, manda el spot en todo" "1d $D2 ema100 $S|1d $D2 fib $S|1d $D2 ha $S|1w $W2 ha $S|1w $W3 ema100 $S|1w $W3 fib $S|1w $W3 ha $S|" \
  "$(awk -v orden="$S $P" -v desde=$D0 -v salida=tsv -f "$AVIS" "$T/v2.txt" 2>/dev/null | awk -F"$TAB" '{ printf "%s %s %s %s|", $1, $2, $3, $4 }')"
igual "V2 desde deja fuera las velas que cerraron antes" "1w $W3 ema100|1w $W3 fib|" \
  "$(awk -v orden="$P $S" -v desde=$((W3 + 86400)) -v salida=tsv -f "$AVIS" "$T/v2.txt" 2>/dev/null | awk -F"$TAB" '{ printf "%s %s %s|", $1, $2, $3 }')"
# El borde: una vela que cierra justo en desde ya no es candidata (las del 02/01
# cierran el 03/01 a las 00:00).
igual "V2 una vela que cierra justo en desde queda fuera" "$D3" \
  "$(awk -v orden="$P" -v desde=$D3 -v salida=tsv -f "$AVIS" "$T/v1.txt" 2>/dev/null | head -1 | cut -f2)"

# Errores: salen con 2 y no dan ninguna señal.
v3(){ # v3 <fichero> [variables...]
  f=$1; shift; awk -v orden="${O3:-$P}" -v desde=$D0 "$@" -f "$AVIS" "$f" > "$T/v3.out" 2> "$T/v3.err"; printf '%s/%s' "$?" "$(wc -l < "$T/v3.out" | tr -d ' ')"; }
grep -v "${TAB}I${TAB}1d${TAB}real${TAB}$D2${TAB}" "$T/v1.txt" > "$T/v3a.txt"
r=$(v3 "$T/v3a.txt")
igual "V3 sin la fila de indicadores de una vela: sale con 2 (nunca cae al spot por un hueco)" "2/0 si" "$r $(grep -q 'faltan los indicadores' "$T/v3.err" && echo si)"
printf '%s\tV\t1d\t1\t2\n' "$P" > "$T/v3b.txt"; r1=$(v3 "$T/v3b.txt")
printf '%s\tX\t1\n' "$P" > "$T/v3c.txt"; r2=$(v3 "$T/v3c.txt")
r3=$(O3="OTRO" v3 "$T/v1.txt")
{ vv $P 1d $D2 1 1 1; vv $P 1d $D1 1 1 1; } > "$T/v3d.txt"; r4=$(v3 "$T/v3d.txt")
r5=$(awk -v orden="$P" -f "$AVIS" "$T/v1.txt" >/dev/null 2>&1; echo $?)
r6=$(v3 "$T/v1.txt" -v enviado=5)
{ ff $P 0.5 100; ff $P 0 120; } > "$T/v3e.txt"; r7=$(v3 "$T/v3e.txt")
r8=$(O3="BIP-T bad;id" v3 "$T/v1.txt")
igual "V3 campos de menos, clase rara, producto fuera de orden, velas desordenadas, sin desde, enviado raro, niveles desordenados, producto con caracteres raros: 2" \
  "2/0 2/0 2/0 2/0 2 2/0 2/0 2/0" "$r1 $r2 $r3 $r4 $r5 $r6 $r7 $r8"

# JSON para rqlite: INSERT OR IGNORE con la clave (grupo, marco, ts, tipo);
# enviado null (pendiente) o 0 (no se manda). Sin grupo, el del primero de orden.
awk -v orden="$P" -v desde=$D0 -v salida=json -v creado=777 -f "$AVIS" "$T/v1.txt" > "$T/v4.json" 2>/dev/null
igual "V4 la sentencia, entera (grupo = el principal)" \
  "[\"INSERT OR IGNORE INTO cripto_aviso(grupo,marco,ts,tipo,producto,sentido,precio,nivel,texto,creado,enviado) VALUES(?,?,?,?,?,?,?,?,?,?,?)\",\"$P\",\"1d\",$D2,\"ema100\",\"$P\",1,110,105,\"📈 Perpetuo, diaria del 02/01: cierra por encima de la EMA 100: cierre 110, EMA 105\",777,null]" \
  "$(head -1 "$T/v4.json")"
igual "V4 con un grupo dado, ese va en la clave" "\"GRUPO-X\",\"1d\",$D2,\"ema100\"" \
  "$(awk -v grupo=GRUPO-X -v orden="$P" -v desde=$D0 -v salida=json -v creado=777 -f "$AVIS" "$T/v1.txt" 2>/dev/null | head -1 | sed 's/^\["[^"]*",//' | cut -d, -f1-4)"
r=$(awk -v grupo='mal grupo' -v orden="$P" -v desde=$D0 -v salida=json -f "$AVIS" "$T/v1.txt" > "$T/v4b.out" 2> "$T/v4b.err"; echo "$?/$(wc -l < "$T/v4b.out" | tr -d ' ')")
igual "V4 un grupo con caracteres raros: sale con 2 sin señales" "2/0 si" "$r $(grep -q 'grupo no valido' "$T/v4b.err" && echo si)"
# El Tech 100 se llama asi en el texto (y la referencia igual).
sed "s/^$P$TAB/TEK-T$TAB/" "$T/v1.txt" > "$T/v4c.txt"
igual "V4 las señales de TEK dicen 'Tech 100'" "📈 Tech 100, diaria del 02/01: cierra por encima de la EMA 100: cierre 110, EMA 105" \
  "$(awk -v orden=TEK-T -v desde=$D0 -v salida=tsv -f "$AVIS" "$T/v4c.txt" 2>/dev/null | head -1 | cut -f8)"
igual "V4 con enviado=0, todas van a 0" "7" "$(awk -v orden="$P" -v desde=$D0 -v salida=json -v creado=777 -v enviado=0 -f "$AVIS" "$T/v1.txt" 2>/dev/null | grep -c ',777,0]$')"
if command -v node >/dev/null 2>&1; then
  r=$(node -e 'const l = require("fs").readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean); let ok = 0; for (const x of l) { const a = JSON.parse(x); if (a.length === 12 && a[1] === "BIP-T" && !/["\\<>&]/.test(a[9])) ok++; } console.log(ok + "/" + l.length);' "$T/v4.json" 2>&1)
  igual "V4 JSON valido, 11 valores (grupo el primero), y textos sin comillas, barras ni <>&" "7/7" "$r"

  # Series al azar: dos productos (uno con historia corta, para que el reparto
  # se note), indicadores cortos para que haya muchas señales, y Fibonacci con
  # un ciclo facil. El awk contra avisos-ref.js, vela a vela.
  tot=0; malv=0; msgv=""
  for sem in 11 23 37 41 53 67 79 97; do
    node -e '
      let s = +process.argv[1]; const rnd = () => { s = (Math.imul(s, 1664525) + 1013904223) >>> 0; return s / 4294967296; };
      for (const [n, f] of [[260, process.argv[2]], [160, process.argv[3]]]) {
        let p = 60000, out = "";
        for (let i = 0; i < n; i++) {
          const t = 1704067200 + (260 - n + i) * 86400, o = p; p = Math.max(1000, Math.round(p * (1 + (rnd() - 0.5) * 0.12)));
          out += [t, o, Math.max(o, p) + Math.round(rnd() * 900), Math.max(1, Math.min(o, p) - Math.round(rnd() * 900)), p, 1].join(" ") + "\n";
        }
        require("fs").writeFileSync(f, out);
      }' "$sem" "$T/v5s.txt" "$T/v5p.txt"
    : > "$T/v5.txt"
    for par in "BTC-USD:$T/v5s.txt" "BIP-T:$T/v5p.txt"; do
      pr=${par%%:*}; fs=${par#*:}
      awk -v producto="$pr" -v ahora=$((1704067200 + 259 * 86400 + 3600)) -v desde=0 -v salida=tsv -f "$CALC" "$fs" > "$T/v5v.tsv" 2>/dev/null
      awk -v producto="$pr" -v desde=0 -v salida=tsv -v ema_a=4 -v ema_b=9 -v bb_n=3 -v rl_n=5 -v rl_k=1 -f "$IND" "$T/v5v.tsv" > "$T/v5i.tsv" 2>/dev/null
      awk -v p="$pr" '{ print p "\tV\t" $0 }' "$T/v5v.tsv" >> "$T/v5.txt"
      awk -v p="$pr" '{ print p "\tI\t" $0 }' "$T/v5i.tsv" >> "$T/v5.txt"
      # Los niveles de cada vela (con las diarias cerradas anteriores), con un
      # ciclo facil para que haya Fibonacci. Salen de fibonacci-ref.js: el awk de
      # Fibonacci ya tiene sus pruebas (parte F) y aqui se prueban las señales.
      node "$AQUI/niveles-por-vela.js" "$T/v5v.tsv" "$pr" 1704067200 caida=0.2 dura=0 >> "$T/v5.txt"
    done
    awk -v orden="BIP-T BTC-USD" -v desde=1704067200 -v salida=tsv -f "$AVIS" "$T/v5.txt" > "$T/v5.out" 2>/dev/null
    r=$(node "$AQUI/avisos-ref.js" "$T/v5.txt" "$T/v5.out" "BIP-T BTC-USD" 1704067200 2>&1)
    case "$r" in "coincide: "*) n=${r#coincide: }; tot=$((tot + ${n%% *})) ;; *) malv=$((malv + 1)); [ -n "$msgv" ] || msgv="semilla $sem: $r" ;; esac
  done
  # Sin variedad la prueba no probaria nada: hacen falta todas las señales, del perpetuo y del spot.
  if [ "$malv" = 0 ]; then
    for k in canal ema100 ema200 emas fib ha; do grep -q "${TAB}$k${TAB}" "$T/v5.out" || { malv=1; msgv="la ultima semilla no tiene $k"; }; done
    grep -q "${TAB}BTC-USD${TAB}" "$T/v5.out" && grep -q "${TAB}BIP-T${TAB}" "$T/v5.out" || { malv=1; msgv="la ultima semilla no reparte"; }
  fi
  [ "$malv" = 0 ] && [ "$tot" -gt 500 ] && pasa "V5 8 series al azar contra la referencia: $tot señales, todas iguales" || falla "V5 series al azar contra la referencia" "$malv mal, $tot señales; $msgv"
fi

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
  # Sin señales salvo donde se pide (AVP), y el bot de prueba (TGC). C38 prueba
  # los valores por defecto quitando las dos.
  AVP=""; TGC="$T/tg.conf"
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
        BTC_PRODUCTOS="${PRODS:-BTC-USD}" BTC_LOTE="${LOTE_P:-200}" ${AVP+"BTC_AVISOS=$AVP"} ${LABP+"BTC_LABORABLES=$LABP"} ${TGC+"BTC_TG_CONF=$TGC"} BTC_TG_API="http://127.0.0.1:$PCB" ${AVH:+BTC_AVISO_HORAS=$AVH} sh "$SCRIPT" "$@" > "$T/salida" 2>&1
  }
  comprueba(){ node "$AQUI/comprueba.js" "$RQ" "prueba:clave-prueba" "$E" "${1:-BTC-USD}" 2>&1; }
  sql1(){ curl -q -s -K "$T/prueba.curlrc" -G "$RQ/db/query" --data-urlencode "q=$1" | sed -n 's/.*"values":\[\[\([^]]*\)\]\].*/\1/p'; }
  ejecuta(){ printf '%s' "$1" | curl -q -s -K "$T/prueba.curlrc" -H 'Content-Type: application/json' --data-binary @- "$RQ/db/execute" > /dev/null; }
  huella(){ sql1 "SELECT (SELECT COUNT(*) FROM cripto_vela), (SELECT MAX(actualizado) FROM cripto_vela), (SELECT SUM(cierre) FROM cripto_vela), (SELECT COUNT(*) FROM cripto_indicador), (SELECT MAX(actualizado) FROM cripto_indicador), (SELECT COUNT(*) FROM cripto_fibonacci), (SELECT MAX(actualizado) FROM cripto_fibonacci)"; }
  fibfilas(){ sql1 "SELECT COUNT(*), MAX(alto), MAX(alto_ts), MAX(actualizado) FROM cripto_fibonacci WHERE producto='${1:-BTC-USD}'"; }
  escritas(){ sed -n 's/.* \([0-9]*\) filas escritas.*/\1/p' "$T/salida" | tail -1; }
  indfilas(){ sed -n 's/.* \([0-9]*\) filas de indicadores (\([a-z]*\)).*/\1 \2/p' "$T/salida" | tail -1; }
  modo_ind(){ set -- $(indfilas); printf '%s' "${2:-}"; }
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
  grep -q 'creada la tabla cripto_indicador' "$T/salida" && pasa "C1 crea la tabla de indicadores" || falla "C1 crea la tabla de indicadores" "$(head -3 "$T/salida")"
  igual "C1 escribe todos los indicadores: (1411 diarias + 202 semanas) x 2 bases" "3226 completo" "$(indfilas)"
  grep -q 'creada la tabla cripto_fibonacci' "$T/salida" && pasa "C1 crea la tabla de Fibonacci" || falla "C1 crea la tabla de Fibonacci" "$(head -3 "$T/salida")"
  # La serie falsa sube hasta junio de 2023 y luego cae sin volver al maximo:
  # no hay ningun ciclo terminado (C24 lo fabrica).
  grep -q '; sin ciclo para Fibonacci;' "$T/salida" && pasa "C1 sin ciclo para Fibonacci en la serie falsa, y lo dice" || falla "C1 sin ciclo para Fibonacci" "$(cat "$T/salida")"

  p0=$(pet); corre $AHORA0; r=$?
  igual "C2 segunda pasada sin novedades: sale bien" "0" "$r"
  # 3 dias de margen + el ultimo cerrado + el de hoy = 5 diarias, y 1 o 2 semanas
  # (2 si el margen cae en la semana anterior, como aqui: empieza en domingo).
  n=$(escritas); [ -n "$n" ] && [ "$n" -le 7 ] && pasa "C2 solo reescribe los ultimos dias ($n filas)" || falla "C2 solo reescribe los ultimos dias" "escritas=$n; $(cat "$T/salida")"
  coincide "C2 sigue coincidiendo" 0
  igual "C2 la pasada incremental hace 1 sola peticion" "1" "$(( $(pet) - p0 ))"
  n=$(indfilas)
  case "$n" in *" incremental") [ "${n% *}" -le 14 ] && pasa "C2 los indicadores tambien: solo los recientes (${n% *} filas)" || falla "C2 indicadores solo los recientes" "$n" ;;
    *) falla "C2 indicadores solo los recientes" "[$n] $(cat "$T/salida")" ;; esac

  AHORA1=$((AHORA0 + 2 * 86400 + 5 * 3600))
  est "{\"ahora\":$AHORA1}"
  corre $AHORA1; r=$?
  coincide "C3 dos dias despues: la vela que estaba abierta se cierra bien y entran las nuevas" 0
  sin_aviso "C3 cerrar la vela que estaba abierta no es una 'correccion de Coinbase'"
  # Aqui DESDE cae en lunes: el borde de la semana en la cuenta de lo guardado.
  igual "C3 los indicadores siguen en incremental (DESDE en lunes)" "incremental" "$(modo_ind)"

  # Cambio de dia UTC: 23:50 guarda la vela de hoy a medias; 00:00:30 (dentro
  # del margen) la deja abierta; 00:10 la cierra. Ninguna es una correccion.
  M=$(( (AHORA1 / 86400 + 1) * 86400 ))       # proxima medianoche UTC
  est "{\"ahora\":$((M - 600))}"; corre $((M - 600)); r=$?
  coincide "C3b a las 23:50 la vela del dia queda guardada a medias" 0
  m1=$(modo_ind)
  est "{\"ahora\":$((M + 30))}"; corre $((M + 30)); r=$?
  igual "C3b a las 00:00:30 la vela de ayer sigue abierta (margen de 60 s)" "0" "$(sql1 "SELECT cerrada FROM cripto_vela WHERE producto='BTC-USD' AND marco='1d' AND ts=$((M - 86400))")"
  igual "C3b ...y sus indicadores tambien, en las dos bases" "0,2" "$(sql1 "SELECT SUM(cerrada), COUNT(*) FROM cripto_indicador WHERE producto='BTC-USD' AND marco='1d' AND ts=$((M - 86400))")"
  m2=$(modo_ind)
  est "{\"ahora\":$((M + 600))}"; corre $((M + 600)); r=$?
  coincide "C3b a las 00:10 se cierra con los valores definitivos" 0
  sin_aviso "C3b el cambio de dia no da aviso de correccion"
  igual "C3b las tres pasadas del cambio de dia son incrementales" "incremental incremental incremental" "$m1 $m2 $(modo_ind)"
  AHORA1=$((M + 600))

  # Coinbase corrige una vela ya cerrada (la de anteayer).
  DIAC=$(( (AHORA1 / 86400) * 86400 - 2 * 86400 ))
  est "{\"ahora\":$AHORA1,\"cambiar\":{\"$DIAC\":{\"c\":1,\"l\":1}}}"
  corre $AHORA1; r=$?
  coincide "C4 una vela cerrada corregida por Coinbase se sobrescribe y la HA posterior se recalcula" 0
  grep -q 'Coinbase cambio 1 velas que ya estaban cerradas' "$T/salida" && pasa "C4 se avisa de la correccion" || falla "C4 se avisa de la correccion" "$(cat "$T/salida")"

  # Indicadores: si lo guardado ANTES de las filas recientes no esta completo o
  # es de otra version del calculo, la pasada borra y reescribe todo el producto.
  ejecuta '[["DROP TABLE cripto_indicador"]]'
  corre $AHORA1; r=$?
  grep -q 'creada la tabla cripto_indicador' "$T/salida" && pasa "C17 sin tabla de indicadores (velas al dia): la crea" || falla "C17 la crea" "$(cat "$T/salida")"
  coincide "C17 ...y escribe todos los indicadores" 0
  igual "C17 en modo completo" "completo" "$(modo_ind)"
  corre $AHORA1; r=$?
  igual "C17 la pasada siguiente vuelve a incremental" "0 incremental" "$r $(modo_ind)"
  ejecuta "[[\"DELETE FROM cripto_indicador WHERE marco='1d' AND base='ha' AND ts < $((INICIO + 50 * 86400))\"]]"
  corre $AHORA1; r=$?
  coincide "C18 faltan indicadores viejos (una pasada cortada): se reescriben todos" 0
  igual "C18 en modo completo" "completo" "$(modo_ind)"
  grep -q 'indicadores de BTC-USD reescritos enteros' "$T/salida" && pasa "C18 el log dice por que" || falla "C18 el log dice por que" "$(cat "$T/salida")"
  ejecuta "[[\"UPDATE cripto_indicador SET cerrada=0 WHERE marco='1d' AND base='real' AND ts=$((INICIO + 40 * 86400))\"]]"
  corre $AHORA1; r=$?
  coincide "C18b una fila vieja guardada con la vela a medias: se rehace" 0
  igual "C18b en modo completo" "completo" "$(modo_ind)"
  ejecuta "[[\"UPDATE cripto_indicador SET version=0 WHERE marco='1w' AND ts < $((INICIO + 30 * 86400))\"]]"
  corre $AHORA1; r=$?
  coincide "C19 filas de una version anterior del calculo: se reescriben todas" 0
  igual "C19 en modo completo" "completo" "$(modo_ind)"
  ejecuta "[[\"UPDATE cripto_indicador SET version=99 WHERE marco='1d' AND ts < $((INICIO + 30 * 86400))\"]]"
  corre $AHORA1; r=$?
  coincide "C19 filas de una version POSTERIOR (se volvio a un script anterior): tambien" 0
  igual "C19 en modo completo" "completo" "$(modo_ind)"
  ejecuta "[[\"INSERT INTO cripto_indicador(producto,marco,base,ts,cerrada,version,actualizado) VALUES('BTC-USD','1d','real',$((INICIO - 10 * 86400)),1,1,1)\"]]"
  corre $AHORA1; r=$?
  coincide "C20 una fila de una vela que no existe: se borra al reescribir" 0
  igual "C20 en modo completo" "completo" "$(modo_ind)"
  ejecuta "[[\"INSERT INTO cripto_indicador(producto,marco,base,ts,cerrada,version,actualizado) VALUES('OTRO','1d','real',1,1,7,1)\"]]"
  corre $AHORA1; r=$?
  igual "C20 las filas de otro producto no cuentan" "0 incremental" "$r $(modo_ind)"
  # ...ni se tocan en una reescritura completa (ni la marca ni el borrado final).
  ejecuta "[[\"UPDATE cripto_indicador SET version=0 WHERE producto='BTC-USD' AND marco='1w' AND ts < $((INICIO + 30 * 86400))\"]]"
  corre $((AHORA1 + 30)); r=$?
  igual "C20 una reescritura completa no toca las filas de otro producto" "0 completo 1,7" "$r $(modo_ind) $(sql1 "SELECT COUNT(*), MAX(version) FROM cripto_indicador WHERE producto='OTRO'")"
  ejecuta "[[\"DELETE FROM cripto_indicador WHERE producto='OTRO'\"]]"
  # Filas de mas (de una vela que no existe) en cualquier version y zona.
  AYER=$(( (AHORA1 / 86400) * 86400 - 86400 ))
  ejecuta "[[\"INSERT INTO cripto_indicador(producto,marco,base,ts,cerrada,version,actualizado) VALUES('BTC-USD','1d','real',$((AYER + 3600)),1,1,1)\"]]"
  corre $((AHORA1 + 40)); r=$?
  coincide "C20b una fila de mas en la zona reciente: la pasada normal la borra" 0
  igual "C20b ...sin reescribir todo" "incremental" "$(modo_ind)"
  ejecuta "[[\"INSERT INTO cripto_indicador(producto,marco,base,ts,cerrada,version,actualizado) VALUES('BTC-USD','1d','real',$((INICIO - 20 * 86400)),1,0,1)\"]]"
  corre $((AHORA1 + 45)); r=$?
  coincide "C20c una fila de mas, vieja y marcada (un borrado final que fallo): se borra" 0
  igual "C20c en modo completo" "completo" "$(modo_ind)"

  # Una reescritura completa que se corta a medias (aqui, un trigger que hace
  # fallar el lote de un dia viejo) no deja huecos: lo mas reciente entra
  # primero y no se borra nada antes de escribir.
  ejecuta '[["UPDATE cripto_indicador SET version=0"]]'
  ejecuta "[[\"CREATE TRIGGER prueba_corte BEFORE INSERT ON cripto_indicador WHEN NEW.ts = $((INICIO + 100 * 86400)) BEGIN SELECT RAISE(ABORT, 'corte de prueba'); END\"]]"
  antes=$(sql1 "SELECT COUNT(*) FROM cripto_indicador WHERE producto='BTC-USD'")
  corre $((AHORA1 + 60)); r=$?
  igual "C21 un lote que falla a mitad de la reescritura completa: sale con 1" "1" "$r"
  igual "C21 ...no se borro ninguna fila" "$antes" "$(sql1 "SELECT COUNT(*) FROM cripto_indicador WHERE producto='BTC-USD'")"
  igual "C21 ...y el dia mas reciente ya quedo con la version nueva (las dos bases)" "2,1" \
    "$(sql1 "SELECT COUNT(*), MIN(version) FROM cripto_indicador WHERE producto='BTC-USD' AND marco='1d' AND ts=(SELECT MAX(ts) FROM cripto_vela WHERE producto='BTC-USD' AND marco='1d')")"
  ejecuta '[["DROP TRIGGER prueba_corte"]]'
  corre $((AHORA1 + 60)); r=$?
  coincide "C21 la pasada siguiente lo termina" 0
  igual "C21 en modo completo" "completo" "$(modo_ind)"

  # Coinbase corrige una vela VIEJA (fuera de los 3 dias de margen) y se lanza
  # --completo, que se corta a mitad de los indicadores. Las velas ya quedaron
  # corregidas; los indicadores que no se rehicieron siguen marcados (version 0)
  # y la pasada normal siguiente los rehace. Sin la marca, quedarian para siempre
  # los de la serie anterior y la cuenta no lo veria.
  VIEJA=$((INICIO + 500 * 86400))
  CV=$(node -e 'const { velas } = require(process.argv[1]); console.log(velas({ ahora: +process.argv[2] }).find(v => v.t === +process.argv[3]).l)' "$AQUI/serie-falsa.js" "$AHORA1" "$VIEJA")
  est "{\"ahora\":$AHORA1,\"cambiar\":{\"$VIEJA\":{\"c\":$CV}}}"
  ejecuta "[[\"CREATE TRIGGER prueba_corte BEFORE INSERT ON cripto_indicador WHEN NEW.ts = $((INICIO + 900 * 86400)) BEGIN SELECT RAISE(ABORT, 'corte de prueba'); END\"]]"
  corre $((AHORA1 + 90)) --completo; r=$?
  igual "C22 --completo cortado a mitad de los indicadores (tras corregirse una vela vieja): sale con 1" "1" "$r"
  ejecuta '[["DROP TRIGGER prueba_corte"]]'
  corre $((AHORA1 + 90)); r=$?
  coincide "C22 la pasada normal siguiente rehace los indicadores sobre la serie corregida" 0
  igual "C22 en modo completo" "completo" "$(modo_ind)"

  # Pasada normal en lotes pequenos (BTC_LOTE=5) que se corta en el lote con los
  # indicadores de hoy: esas filas, que ya existian, quedan marcadas.
  HOY=$(( (AHORA1 / 86400) * 86400 ))
  ejecuta "[[\"CREATE TRIGGER prueba_corte BEFORE INSERT ON cripto_indicador WHEN NEW.ts = $HOY BEGIN SELECT RAISE(ABORT, 'corte de prueba'); END\"]]"
  LOTE_P=5 corre $((AHORA1 + 150)); r=$?
  igual "C23 pasada normal en varios lotes que falla en el de hoy: sale con 1" "1" "$r"
  igual "C23 ...y las filas de hoy, que no se rehicieron, quedan marcadas por reescribir" "0,2" \
    "$(sql1 "SELECT MAX(version), COUNT(*) FROM cripto_indicador WHERE producto='BTC-USD' AND marco='1d' AND ts=$HOY")"
  ejecuta '[["DROP TRIGGER prueba_corte"]]'
  LOTE_P=5 corre $((AHORA1 + 150)); r=$?
  coincide "C23 la pasada siguiente lo deja bien" 0

  # Fibonacci. Coinbase da ayer un maximo de 200.000 (la serie falsa no pasa de
  # 185.783): se cierra la caida que empezo en junio de 2023 y aparece el ciclo.
  # (La correccion vieja de C22 se mantiene: si Coinbase la deshiciera, la
  # pasada normal no la veria, porque esta fuera de los 3 dias de margen.)
  DIAF=$(( (AHORA1 / 86400) * 86400 - 86400 ))
  EST_C22="\"$VIEJA\":{\"c\":$CV}"
  est "{\"ahora\":$AHORA1,\"cambiar\":{$EST_C22,\"$DIAF\":{\"h\":200000}}}"
  corre $((AHORA1 + 200)); r=$?
  coincide "C24 un maximo historico nuevo cierra la caida: aparecen los 7 niveles y coinciden con la referencia" 0
  igual "C24 ...con el ATH nuevo como ancla alta" "7,200000,$DIAF,$((AHORA1 + 200))" "$(fibfilas)"
  esp=$(node -e '
    const { leeEstado, velas, esperadas } = require(process.argv[1]), FR = require(process.argv[2]), e = leeEstado(process.argv[3]);
    const vs = esperadas(velas(e), e.ahora), x = FR.fibonacci(vs.map(v => ({ marco: v.marco, ts: v.ts, h: v.h, l: v.l, c: v.c })));
    const f = t => new Date(t * 1000).toISOString().slice(0, 10), c = vs.filter(v => v.marco === "1d").pop().c;
    console.log(x ? `; Fibonacci del ciclo ${x.bajo} (${f(x.bajo_ts)}) a ${x.alto} (${f(x.alto_ts)}), cierre en el ${(100 * (x.alto - c) / (x.alto - x.bajo)).toFixed(1)} %;` : "sin ciclo");' "$AQUI/serie-falsa.js" "$AQUI/fibonacci-ref.js" "$E" 2>&1)
  case "$esp" in "; Fibonacci del ciclo "*) grep -qF "$esp" "$T/salida" && pasa "C24 el resumen da el tramo de la referencia y donde esta el cierre" || falla "C24 el resumen da el tramo de la referencia" "esperaba [$esp] en: $(cat "$T/salida")" ;;
    *) falla "C24 el resumen da el tramo de la referencia" "$esp" ;; esac
  corre $((AHORA1 + 230)); r=$?
  igual "C24 cada pasada rehace los 7 niveles" "0 7,200000,$DIAF,$((AHORA1 + 230))" "$r $(fibfilas)"
  antes=$(huella); corre $((AHORA1 + 235)) --seco; r=$?
  igual "C24 --seco con ciclo tampoco escribe los niveles" "0 $antes" "$r $(huella)"
  ejecuta "[[\"INSERT INTO cripto_fibonacci VALUES('BTC-USD','otro',0.9,1,1,1,1,1,0.5,1)\"],[\"INSERT INTO cripto_fibonacci VALUES('OTRO','ciclo',0.5,1,1,1,1,1,0.5,1)\"]]"
  corre $((AHORA1 + 240)); r=$?
  coincide "C24 una fila de mas del producto (otro tramo) se borra" 0
  igual "C24 ...y las de otro producto no se tocan" "1" "$(sql1 "SELECT COUNT(*) FROM cripto_fibonacci WHERE producto='OTRO'")"
  ejecuta "[[\"DELETE FROM cripto_fibonacci WHERE producto='OTRO'\"],[\"DROP TABLE cripto_fibonacci\"]]"
  corre $((AHORA1 + 250)); r=$?
  grep -q 'creada la tabla cripto_fibonacci' "$T/salida" && pasa "C24 sin la tabla de Fibonacci: la crea" || falla "C24 sin la tabla de Fibonacci: la crea" "$(cat "$T/salida")"
  coincide "C24 ...y la llena" 0

  # Si falla el lote de Fibonacci (aqui, un trigger), las velas y los indicadores
  # ya entraron y los niveles de antes quedan ENTEROS: el DELETE se deshace con
  # la transaccion.
  ejecuta "[[\"CREATE TRIGGER prueba_fib BEFORE INSERT ON cripto_fibonacci WHEN NEW.nivel = 0.5 BEGIN SELECT RAISE(ABORT, 'corte de prueba'); END\"]]"
  corre $((AHORA1 + 260)); r=$?
  igual "C25 falla la escritura de Fibonacci: sale con 1" "1" "$r"
  grep -q 'fallo al escribir Fibonacci' "$T/salida" && pasa "C25 lo explica" || falla "C25 lo explica" "$(cat "$T/salida")"
  igual "C25 ...los 7 niveles de antes siguen enteros" "7,200000,$DIAF,$((AHORA1 + 250))" "$(fibfilas)"
  igual "C25 ...y las velas de la pasada si entraron" "$((AHORA1 + 260))" "$(sql1 "SELECT MAX(actualizado) FROM cripto_vela")"
  ejecuta '[["DROP TRIGGER prueba_fib"]]'
  corre $((AHORA1 + 270)); r=$?
  coincide "C25 la pasada siguiente lo deja bien" 0
  # La vela de hoy, aun abierta, supera ese maximo: es el ancla alta ya, sin
  # esperar a que cierre. (La caida de un dia no abre otro ciclo.)
  HOYF=$(( (AHORA1 / 86400) * 86400 ))
  est "{\"ahora\":$AHORA1,\"cambiar\":{$EST_C22,\"$DIAF\":{\"h\":200000},\"$HOYF\":{\"h\":210000}}}"
  corre $((AHORA1 + 275)); r=$?
  coincide "C25b la vela de hoy, abierta, con un maximo nuevo: coincide con la referencia" 0
  igual "C25b ...y es el ancla alta" "7,210000,$HOYF,$((AHORA1 + 275))" "$(fibfilas)"
  # Coinbase deshace el maximo: ya no hay ciclo y los niveles se borran.
  est "{\"ahora\":$AHORA1,\"cambiar\":{$EST_C22}}"
  corre $((AHORA1 + 280)); r=$?
  coincide "C25 si Coinbase quita ese maximo, el ciclo desaparece" 0
  igual "C25 ...y no queda ningun nivel" "0" "$(sql1 "SELECT COUNT(*) FROM cripto_fibonacci")"

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
  [ -s "$T/dir/seco/BTC-USD.fibonacci.json" ] && pasa "C6 ...tambien el de Fibonacci" || falla "C6 ...tambien el de Fibonacci" "$(ls "$T/dir/seco/")"

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
  # Un cerrojo que quedo puesto (corte de luz, kill -9) se libera a los 30 min,
  # y las dos cosas, saltar y liberar, quedan en velas.log.
  L="$T/dir/velas.log"
  mkdir "$T/dir/.velas.lock"; touch -d '-20 minutes' "$T/dir/.velas.lock"
  n0=$(grep -c 'ya hay otra pasada en curso' "$L"); antes=$(huella); corre $((AHORA1 + 31)); r=$?
  igual "C11j un cerrojo de 20 min se respeta: no escribe nada y lo deja en velas.log" "0|$antes|$((n0 + 1))" "$r|$(huella)|$(grep -c 'ya hay otra pasada en curso' "$L")"
  touch -d '-40 minutes' "$T/dir/.velas.lock"
  corre $((AHORA1 + 61)); r=$?
  igual "C11j uno de 40 min es de una pasada muerta: lo libera, lo dice en velas.log y hace la pasada" "0 si no" \
    "$r $(grep -q 'libero un cerrojo de mas de 30 min' "$L" && echo si || echo no) $([ -d "$T/dir/.velas.lock" ] && echo si || echo no)"
  n=$(sql1 "SELECT COUNT(*) FROM cripto_vela WHERE actualizado=$((AHORA1 + 61))")
  [ "${n:-0}" -gt 0 ] && pasa "C11j ...y escribe ($n velas)" || falla "C11j ...y escribe" "$n; $(cat "$T/salida")"
  rmdir "$T/dir/.velas.lock" 2>/dev/null

  # Una copia a medias de btc/ (sin el awk de los indicadores) no escribe nada.
  mkdir -p "$T/btc2"; cp "$SCRIPT" "$CALC" "$LECTOR" "$FIB" "$AVIS" "$T/btc2/"
  SCRIPT_BUENO=$SCRIPT; SCRIPT="$T/btc2/Sentinel-BTC-Velas.sh"
  # Otro AHORA: si escribiera algo, MAX(actualizado) de la huella cambiaria.
  antes=$(huella); corre $((AHORA1 + 180)); r=$?; SCRIPT=$SCRIPT_BUENO
  igual "C11c sin indicadores-calculo.awk: sale con 1 y no escribe nada" "1 $antes" "$r $(huella)"
  grep -q 'falta .*indicadores-calculo.awk' "$T/salida" && pasa "C11c lo explica" || falla "C11c lo explica" "$(cat "$T/salida")"
  printf 'BEGIN {\n' > "$T/btc2/indicadores-calculo.awk"   # un awk roto
  SCRIPT="$T/btc2/Sentinel-BTC-Velas.sh"
  antes=$(huella); corre $((AHORA1 + 210)); r=$?; SCRIPT=$SCRIPT_BUENO
  igual "C11d con el awk de indicadores roto: sale con 2 y no escribe nada" "2 $antes" "$r $(huella)"
  grep -q 'indicadores fallo: ..*' "$T/salida" && pasa "C11d el log trae lo que dijo awk" || falla "C11d el log trae lo que dijo awk" "$(cat "$T/salida")"
  # Lo mismo con el awk de Fibonacci: sin el, roto o mudo, no se escribe nada
  # del producto (tampoco las velas).
  cp "$IND" "$T/btc2/"; rm -f "$T/btc2/fibonacci-calculo.awk"
  SCRIPT="$T/btc2/Sentinel-BTC-Velas.sh"
  antes=$(huella); corre $((AHORA1 + 220)); r=$?; SCRIPT=$SCRIPT_BUENO
  igual "C11e sin fibonacci-calculo.awk: sale con 1 y no escribe nada" "1 $antes" "$r $(huella)"
  grep -q 'falta .*fibonacci-calculo.awk' "$T/salida" && pasa "C11e lo explica" || falla "C11e lo explica" "$(cat "$T/salida")"
  printf 'BEGIN {\n' > "$T/btc2/fibonacci-calculo.awk"
  SCRIPT="$T/btc2/Sentinel-BTC-Velas.sh"
  antes=$(huella); corre $((AHORA1 + 230)); r=$?; SCRIPT=$SCRIPT_BUENO
  igual "C11f con el awk de Fibonacci roto: sale con 2 y no escribe nada" "2 $antes" "$r $(huella)"
  grep -q 'Fibonacci fallo: ..*' "$T/salida" && pasa "C11f el log trae lo que dijo awk" || falla "C11f el log trae lo que dijo awk" "$(cat "$T/salida")"
  printf 'END { }\n' > "$T/btc2/fibonacci-calculo.awk"   # sale bien sin decir nada
  SCRIPT="$T/btc2/Sentinel-BTC-Velas.sh"
  antes=$(huella); corre $((AHORA1 + 240)); r=$?; SCRIPT=$SCRIPT_BUENO
  igual "C11g con un awk de Fibonacci que no emite nada: sale con 2 y no escribe nada" "2 $antes" "$r $(huella)"
  # Emite sentencias pero no el resumen: tampoco es de fiar.
  printf '%s\n' 'END { print "[\"DELETE FROM cripto_fibonacci WHERE producto=?\",\"BTC-USD\"]" }' > "$T/btc2/fibonacci-calculo.awk"
  SCRIPT="$T/btc2/Sentinel-BTC-Velas.sh"
  antes=$(huella); corre $((AHORA1 + 250)); r=$?; SCRIPT=$SCRIPT_BUENO
  igual "C11h con un awk de Fibonacci que no da resumen: sale con 2 y no escribe nada" "2 $antes" "$r $(huella)"
  # ...y al reves: da el resumen pero ninguna sentencia.
  printf '%s\n' 'END { print "RESUMEN_FIB ciclo=0 diarias=1" > "/dev/stderr" }' > "$T/btc2/fibonacci-calculo.awk"
  SCRIPT="$T/btc2/Sentinel-BTC-Velas.sh"
  antes=$(huella); corre $((AHORA1 + 260)); r=$?; SCRIPT=$SCRIPT_BUENO
  igual "C11i con un awk de Fibonacci que da el resumen sin ninguna sentencia: sale con 2 y no escribe nada" "2 $antes" "$r $(huella)"

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
  grep -q 'fallo al escribir.*la proxima pasada completa el resto' "$T/salida" && pasa "C14 lo explica" || falla "C14 lo explica" "$(cat "$T/salida")"
  # En un --completo la pasada siguiente NO lo arregla: hay que repetirlo.
  corre $AHORA1 --completo; r=$?
  igual "C14b lo mismo en un --completo: sale con 1" "1" "$r"
  if grep -q 'fallo al escribir.*repite --completo' "$T/salida" && ! grep -q 'la proxima pasada completa' "$T/salida"; then
    pasa "C14b ...y pide repetir el --completo en vez de esperar a la pasada siguiente"
  else falla "C14b pide repetir el --completo" "$(cat "$T/salida")"; fi

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
  # Con un ATH nuevo ayer en el spot (como en C24): el spot tiene ciclo y el
  # perpetuo, que se procesa despues, no; su DELETE no toca lo del spot.
  DIAF=$(( (AHORA2 / 86400) * 86400 - 86400 ))
  est "{\"ahora\":$AHORA2,\"cambiar\":{\"$DIAF\":{\"h\":200000}}}"
  PRODS="BTC-USD BIP-20DEC30-CDE" corre $AHORA2; r=$?
  c1=$(comprueba BTC-USD); c2=$(comprueba BIP-20DEC30-CDE)
  case "$r|$c1|$c2" in 0\|coincide*\|coincide*) pasa "C16 la pasada incremental de las dos series tambien coincide" ;; *) falla "C16 pasada incremental de las dos series" "r=$r $c1 / $c2" ;; esac
  igual "C16 Fibonacci: 7 niveles del spot y ninguno del perpetuo" "7 0" \
    "$(sql1 "SELECT COUNT(*) FROM cripto_fibonacci WHERE producto='BTC-USD'") $(sql1 "SELECT COUNT(*) FROM cripto_fibonacci WHERE producto='BIP-20DEC30-CDE'")"
  PRODS="BTC-USD NO-EXISTE" corre $AHORA2; r=$?
  igual "C16 un producto que Coinbase no conoce sale con 1 sin tapar al otro" "1" "$r"
  grep -q '^BTC-USD:' "$T/salida" && pasa "C16 el otro producto se proceso igual" || falla "C16 el otro producto se proceso igual" "$(cat "$T/salida")"

  # ---------------- Señales (paso 7) ----------------
  igual "C27 sin BTC_AVISOS no se crea la tabla de señales" "0" "$(sql1 "SELECT COUNT(*) FROM sqlite_master WHERE name='cripto_aviso'")"
  # tg n|ok|txt|meta: el Telegram falso (intentos, aceptados, ultimo texto, y
  # token|chat|metodo|cabecera Authorization del ultimo).
  tg(){ curl -q -s "http://127.0.0.1:$PCB/_telegram" | node -e 'let s = ""; process.stdin.on("data", d => { s += d; }).on("end", () => {
      const a = JSON.parse(s), m = process.argv[1], u = a[a.length - 1] || {};
      if (m === "n") console.log(a.length); else if (m === "ok") console.log(a.filter(x => x.ok).length);
      else if (m === "txt") console.log(u.texto || ""); else console.log([u.token, u.chat, u.metodo, u.auth].join("|")); });' "$1"; }
  # msge <enviado>: el mensaje que deberia haber salido con las señales marcadas
  # con esa hora, rehecho desde rqlite (cabecera, una linea por señal en orden,
  # la nota del spot si alguna es del spot, y quien lo manda).
  msge(){ node -e '
      const [rq, env] = process.argv.slice(1);
      fetch(rq + "/db/query?level=strong", { method: "POST", headers: { "Content-Type": "application/json", Authorization: "Basic " + Buffer.from("prueba:clave-prueba").toString("base64") },
        body: JSON.stringify([["SELECT texto, producto FROM cripto_aviso WHERE enviado=? ORDER BY ts,marco,tipo", +env], ["SELECT fuente FROM cripto_vela LIMIT 1"]]) })
        .then(r => r.json()).then(j => { const f = j.results[0].values || [];
          let m = "📊 BTC: señales al cierre\n" + f.map(x => "• " + x[0]).join("\n") + "\n";
          if (f.some(x => x[1] === "BTC-USD")) m += "Spot = BTC-USD, solo donde al perpetuo le falta historia.\n";
          console.log(m + "Lo manda " + j.results[1].values[0][0] + "."); });' "$RQ" "$1"; }
  AV2="BIP-20DEC30-CDE BTC-USD"
  avc(){ node "$AQUI/avisos-comprueba.js" "$RQ" "prueba:clave-prueba" "$E" "$AV2" 2>&1; }
  pend(){ sql1 "SELECT COUNT(*) FROM cripto_aviso WHERE enviado IS NULL"; }
  vigia(){ sql1 "SELECT ts, pendientes FROM sentinel_vigia WHERE clave='btc-senales'"; }
  # Entradas de Raft aplicadas por el rqlite de prueba (para ver cuanto escribe una pasada).
  raft(){ curl -q -s -K "$T/prueba.curlrc" "$RQ/status" | grep -o '"applied_index":[0-9]*' | head -1 | cut -d: -f2; }
  ejecuta '[["DROP TABLE IF EXISTS cripto_vela"],["DROP TABLE IF EXISTS cripto_indicador"],["DROP TABLE IF EXISTS cripto_fibonacci"],["DROP TABLE IF EXISTS cripto_aviso"],["DROP TABLE IF EXISTS sentinel_vigia"]]'
  printf 'BOT_TOKEN="tok-prueba"\nCHAT_ID="42"\n' > "$T/tg.conf"
  # Parejas de dias forzados: un cierre muy bajo y, al dia siguiente, uno muy
  # alto, en el perpetuo y en el spot. Dan seguro señales en cada pasada nueva:
  # EMA, canal y Heikin Ashi del perpetuo, y Fibonacci del spot (con un maximo
  # de 200.000 en DIAF tiene ciclo; el perpetuo no tiene ninguno).
  H3=$(( (AHORA2 / 86400) * 86400 + 10 * 86400 )); AHORA3=$((H3 + 36000))
  bajo(){ printf '"%s":{"c":1000,"l":1000}' "$1"; }; alto(){ printf '"%s":{"c":%s,"h":%s}' "$1" "$2" "$2"; }
  pares(){ printf '%s,%s,%s,%s,%s,%s' "$(bajo $((H3 - 3 * 86400)))" "$(alto $((H3 - 2 * 86400)) $1)" "$(bajo $H3)" "$(alto $((H3 + 86400)) $1)" \
             "$(bajo $((H3 + 3 * 86400)))" "$(alto $((H3 + 4 * 86400)) $1)"; }
  # El ultimo dia alto del spot cierra por ENCIMA del maximo (200.000): con los
  # niveles de antes de esa vela, "supera el maximo del ciclo". Si se calcularan
  # con la propia vela (maximo 250.000) saldria otra cosa, y la referencia lo ve.
  CAM="\"cambiar\":{\"$DIAF\":{\"h\":200000}},\"cambiarEn\":{\"BIP-20DEC30-CDE\":{$(pares 1000000)},\"BTC-USD\":{$(pares 190000 | sed "s/\"$((H3 + 4 * 86400))\":{\"c\":190000,\"h\":190000}/\"$((H3 + 4 * 86400))\":{\"c\":240000,\"h\":250000}/")}}"
  AVP="$AV2"; PRODS="$AV2"
  # La primera pasada con un producto que falla no calcula señales: tampoco crea
  # la tabla, y la siguiente sigue siendo "la primera" (no manda nada viejo).
  est "{\"ahora\":$((AHORA3 - 600)),$CAM,\"fallaProducto\":\"BIP-20DEC30-CDE\"}"
  corre $((AHORA3 - 600)); r=$?
  igual "C27 si la primera pasada no calcula señales (un producto falla), no crea la tabla y sale con 3" "3|0" \
    "$r|$(sql1 "SELECT COUNT(*) FROM sqlite_master WHERE name='cripto_aviso'")"
  igual "C27 ...y apunta en sentinel_vigia que las señales no salen (3), para el Wheel" "$((AHORA3 - 600)),3" "$(vigia)"
  est "{\"ahora\":$AHORA3,$CAM}"
  t0=$(tg n); corre $AHORA3; r=$?
  igual "C27 la siguiente: sale bien y crea la tabla" "0 si" "$r $(grep -q 'creada la tabla cripto_aviso' "$T/salida" && echo si)"
  n=$(sql1 "SELECT COUNT(*) FROM cripto_aviso")
  igual "C27 ...guarda las de los ultimos 7 dias como ya enviadas, sin mandar nada (y el log da la cuenta justa)" "si|0|$n|si" \
    "$([ "${n:-0}" -gt 0 ] && echo si)|$(( $(tg n) - t0 ))|$(sql1 "SELECT COUNT(*) FROM cripto_aviso WHERE enviado=0")|$(grep -q "señales: $n guardadas sin mandar (la tabla es nueva" "$T/salida" && echo si)"
  c=$(avc); case "$c" in "coincide: "*) pasa "C27 ...y son las de la referencia ($c)" ;; *) falla "C27 señales contra la referencia" "$c" ;; esac
  igual "C27 ...hay Fibonacci del spot (el perpetuo no tiene ciclo)" "si" "$([ "$(sql1 "SELECT COUNT(*) FROM cripto_aviso WHERE tipo='fib' AND producto='BTC-USD'")" -gt 0 ] && echo si)"
  igual "C27 ...y el estado vuelve a bien desde esta pasada" "$AHORA3,0" "$(vigia)"

  AHORA4=$((AHORA3 + 2 * 86400)); est "{\"ahora\":$AHORA4,$CAM}"
  t0=$(tg n); corre $AHORA4; r=$?
  m=$(sql1 "SELECT COUNT(*) FROM cripto_aviso WHERE enviado=$AHORA4")
  igual "C28 dos dias despues: señales nuevas, mandadas en UN mensaje y marcadas con la hora" "0|1|si|0" \
    "$r|$(( $(tg n) - t0 ))|$([ "${m:-0}" -gt 0 ] && echo si)|$(pend)"
  igual "C28 ...el mensaje, entero: cabecera, cada señal en orden, la nota del spot y quien lo manda" "$(msge $AHORA4)" "$(tg txt)"
  igual "C28 ...y entre ellas hay del spot (Fibonacci), con su nota" "si si" \
    "$([ "$(sql1 "SELECT COUNT(*) FROM cripto_aviso WHERE enviado=$AHORA4 AND producto='BTC-USD' AND tipo='fib'")" -gt 0 ] && echo si) $(tg txt | grep -q '^Spot = BTC-USD' && echo si)"
  igual "C28 ...con el token y el chat del fichero, por POST y sin la clave de rqlite" "tok-prueba|42|POST|false" "$(tg meta)"
  grep -q "señales: mandadas $m por Telegram" "$T/salida" && pasa "C28 ...y el log lo dice" || falla "C28 el log lo dice" "$(cat "$T/salida")"
  c=$(avc); case "$c" in "coincide: "*) pasa "C28 ...y son las de la referencia ($c)" ;; *) falla "C28 señales contra la referencia" "$c" ;; esac
  igual "C28 el token del bot no sale ni en la salida ni en el log" "0 0" "$(grep -c tok-prueba "$T/salida") $(grep -c tok-prueba "$T/dir/velas.log")"
  # Ni en la linea de comandos de curl (se veria en ps): un curl envoltorio apunta
  # los argumentos de cada llamada y llama al de verdad.
  mkdir -p "$T/envuelto"; CURL_REAL=$(command -v curl)
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/argv.log"\nexec "%s" "$@"\n' "$T" "$CURL_REAL" > "$T/envuelto/curl"; chmod +x "$T/envuelto/curl"
  : > "$T/argv.log"; ejecuta "[[\"UPDATE cripto_aviso SET enviado=NULL WHERE enviado=$AHORA4\"]]"
  PATH_BUENO=$PATH; PATH="$T/envuelto:$PATH"; t0=$(tg n); corre $((AHORA4 + 60)); r=$?; PATH=$PATH_BUENO
  igual "C28 ...ni en los argumentos de curl (y el envoltorio de verdad se uso)" "0|1|0|si" \
    "$r|$(( $(tg n) - t0 ))|$(grep -c tok-prueba "$T/argv.log")|$(grep -q 'sendMessage\|data-urlencode' "$T/argv.log" && echo si)"

  n0=$(sql1 "SELECT COUNT(*) FROM cripto_aviso"); t0=$(tg n); i0=$(raft); corre $((AHORA4 + 300)); r=$?; i1=$(raft)
  igual "C29 otra pasada el mismo dia: ni señales nuevas ni mensaje" "0|$n0|0" "$r|$(sql1 "SELECT COUNT(*) FROM cripto_aviso")|$(( $(tg n) - t0 ))"
  # Sin nada nuevo, las señales no escriben en Raft (ni INSERT para nada ni el
  # estado, que no cambia): solo las velas y Fibonacci, 2 por producto.
  igual "C29 ...y escribe solo lo de las velas: 4 entradas de Raft" "4" "$((i1 - i0))"
  igual "C29 ...el estado de las señales sigue el de antes (no se reescribe)" "$AHORA3,0" "$(vigia)"

  AHORA5=$((AHORA3 + 5 * 86400)); est "{\"ahora\":$AHORA5,$CAM,\"tgFalla\":true}"
  t0=$(tg n); k0=$(tg ok); corre $AHORA5; r=$?
  p=$(pend)
  igual "C30 Telegram falla: sale con 1, lo intenta una vez y las señales siguen pendientes" "1|1|0|si" \
    "$r|$(( $(tg n) - t0 ))|$(( $(tg ok) - k0 ))|$([ "${p:-0}" -gt 0 ] && echo si)"
  grep -q 'Telegram no acepto las señales (Telegram respondio http 500); siguen pendientes' "$T/salida" && pasa "C30 ...y lo explica" || falla "C30 lo explica" "$(cat "$T/salida")"
  igual "C30 ...y apunta en sentinel_vigia que las señales fallan desde ahora (para el Wheel)" "$AHORA5,1" "$(vigia)"
  corre $((AHORA5 + 120)); r=$?
  igual "C30 otra pasada fallando: no reescribe el estado (sigue el desde de antes)" "1|$AHORA5,1" "$r|$(vigia)"
  est "{\"ahora\":$AHORA5,$CAM}"
  t0=$(tg n); corre $((AHORA5 + 300)); r=$?
  igual "C30 la pasada siguiente las manda y quedan marcadas" "0|1|0|$p" "$r|$(( $(tg n) - t0 ))|$(pend)|$(sql1 "SELECT COUNT(*) FROM cripto_aviso WHERE enviado=$((AHORA5 + 300))")"
  igual "C30 ...y el estado vuelve a bien" "$((AHORA5 + 300)),0" "$(vigia)"
  c=$(avc); case "$c" in "coincide: "*) pasa "C30 ...y son las de la referencia ($c)" ;; *) falla "C30 señales contra la referencia" "$c" ;; esac
  igual "C30 ...entre ellas, el spot que supera el maximo del ciclo (los niveles de antes de esa vela)" "1" \
    "$(sql1 "SELECT COUNT(*) FROM cripto_aviso WHERE ts=$((H3 + 4 * 86400)) AND marco='1d' AND tipo='fib' AND texto LIKE '%supera%el máximo del ciclo (200.000)%'")"

  # Pendientes viejas (la vela cerro hace mas de BTC_AVISO_HORAS): caducan (-1)
  # sin mandarlas. Con un plazo mayor, si se mandan.
  ejecuta "[[\"UPDATE cripto_aviso SET enviado=NULL WHERE ts = $((H3 - 2 * 86400)) AND marco='1d'\"]]"
  v=$(pend); t0=$(tg n); c0=$(sql1 "SELECT COUNT(*) FROM cripto_aviso WHERE enviado=-1"); corre $((AHORA5 + 600)); r=$?
  igual "C31 pendientes de velas cerradas hace mas de 36 h: no se mandan y caducan (-1)" "0|si|0|0|$v" \
    "$r|$([ "${v:-0}" -gt 0 ] && echo si)|$(( $(tg n) - t0 ))|$(pend)|$(( $(sql1 "SELECT COUNT(*) FROM cripto_aviso WHERE enviado=-1") - c0 ))"
  grep -q "$v de hace mas de 36 h, marcadas sin mandar" "$T/salida" && pasa "C31 ...y el log lo dice" || falla "C31 el log lo dice" "$(cat "$T/salida")"
  ejecuta "[[\"UPDATE cripto_aviso SET enviado=NULL WHERE ts = $((H3 - 2 * 86400)) AND marco='1d'\"]]"
  t0=$(tg n); AVH=1000; corre $((AHORA5 + 900)); r=$?; unset AVH
  igual "C31 con BTC_AVISO_HORAS=1000, esas mismas se mandan" "0|1|0" "$r|$(( $(tg n) - t0 ))|$(pend)"
  # El borde de las 36 h, contra el CIERRE de la vela (no su inicio), diaria y
  # semanal: cerrada hace 35 h se manda; hace 37 h, no.
  A=$((AHORA5 + 930))
  bd=$(awk -v a=$A 'BEGIN { split("1d 1d 1w 1w", m, " "); split("35 37 35 37", h, " ")
         for (k = 1; k <= 4; k++) { d = (m[k] == "1d") ? 86400 : 604800
           printf "%s[\"INSERT INTO cripto_aviso(grupo,marco,ts,tipo,producto,sentido,precio,nivel,texto,creado,enviado) VALUES(?,?,?,?,?,?,?,?,?,?,?)\",\"BIP-20DEC30-CDE\",\"%s\",%d,\"borde\",\"BTC-USD\",1,1,1,\"borde %s %s h\",%d,null]", (k > 1 ? "," : "["), m[k], a - d - h[k] * 3600, m[k], h[k], a }
         print "]" }')
  ejecuta "$bd"; t0=$(tg n); corre $A; r=$?
  igual "C31 el borde de las 36 h: diaria y semanal cerradas hace 35 h se mandan; hace 37 h caducan" "0|1|• borde 1w 35 h|• borde 1d 35 h|2,2" \
    "$r|$(( $(tg n) - t0 ))|$(tg txt | sed -n 2p)|$(tg txt | sed -n 3p)|$(sql1 "SELECT COUNT(*) FROM cripto_aviso WHERE tipo='borde' AND texto LIKE '% 35 h' AND enviado=$A"),$(sql1 "SELECT COUNT(*) FROM cripto_aviso WHERE tipo='borde' AND texto LIKE '% 37 h' AND enviado=-1")"
  ejecuta '[["DELETE FROM cripto_aviso WHERE tipo='"'"'borde'"'"'"]]'
  # Un mensaje lleva 25 como mucho (Telegram corta en 4096 caracteres): el resto,
  # en las pasadas siguientes. Con 30 señales de prueba (semanas que cerraron
  # hace unos minutos), que luego se borran.
  sp=$(awk -v a=$AHORA5 'BEGIN { for (k = 1; k <= 30; k++) printf "%s[\"INSERT INTO cripto_aviso(grupo,marco,ts,tipo,producto,sentido,precio,nivel,texto,creado,enviado) VALUES(?,?,?,?,?,?,?,?,?,?,?)\",\"BIP-20DEC30-CDE\",\"1w\",%d,\"prueba\",\"BTC-USD\",1,1,1,\"señal de prueba %d\",%d,null]", (k > 1 ? "," : "["), a - 604800 - k * 60, k, a; print "]" }')
  ejecuta "$sp"; tot=$(pend)
  if [ "${tot:-0}" = 30 ]; then
    t0=$(tg n); AVH=1000; corre $((AHORA5 + 950)); r=$?
    igual "C31 con 30 pendientes: un mensaje de 25, en orden, y 5 para la pasada siguiente" "0|1|25|si|5|si" \
      "$r|$(( $(tg n) - t0 ))|$(tg txt | grep -c '^• ')|$(tg txt | sed -n 2p | grep -qx '• señal de prueba 30' && echo si)|$(pend)|$(grep -q "mandadas 25 por Telegram; 5 para la proxima pasada" "$T/salida" && echo si)"
    corre $((AHORA5 + 960)); r=$?
    igual "C31 ...y la siguiente manda las 5 que faltan" "0|5|0" "$r|$(tg txt | grep -c '^• ')|$(pend)"
    unset AVH
  else falla "C31 no entraron las 30 señales de prueba" "${tot:-?}"; fi
  ejecuta '[["DELETE FROM cripto_aviso WHERE tipo='"'"'prueba'"'"'"]]'

  # Una pendiente reciente para las pruebas que siguen.
  ULT=$(sql1 "SELECT MAX(ts) FROM cripto_aviso WHERE marco='1d'")
  reciente(){ ejecuta "[[\"UPDATE cripto_aviso SET enviado=NULL WHERE marco='1d' AND ts=$ULT\"]]"; }
  reciente; p=$(pend); t0=$(tg n); TGC="$T/no-existe"; corre $((AHORA5 + 1200)); r=$?; TGC="$T/tg.conf"
  igual "C32 sin el fichero del bot: sale con 1, no intenta nada y siguen pendientes" "1|0|$p|si" \
    "$r|$(( $(tg n) - t0 ))|$(pend)|$(grep -q 'no hay BOT_TOKEN y CHAT_ID en' "$T/salida" && echo si)"
  printf 'BOT_TOKEN=\nCHAT_ID="42"\n' > "$T/tg-vacio.conf"; TGC="$T/tg-vacio.conf"; corre $((AHORA5 + 1210)); r=$?; TGC="$T/tg.conf"
  igual "C32 ...ni con el token vacio" "1|0|$p" "$r|$(( $(tg n) - t0 ))|$(pend)"

  est "{\"ahora\":$AHORA5,$CAM,\"fallaProducto\":\"BIP-20DEC30-CDE\"}"
  t0=$(tg n); n0=$(sql1 "SELECT COUNT(*) FROM cripto_aviso"); corre $((AHORA5 + 1500)); r=$?
  igual "C33 si el perpetuo falla: sale con 3, no calcula señales y manda las pendientes" "3|$n0|1|0|si" \
    "$r|$(sql1 "SELECT COUNT(*) FROM cripto_aviso")|$(( $(tg n) - t0 ))|$(pend)|$(grep -q 'no se calculan en esta pasada porque BIP-20DEC30-CDE no salio bien' "$T/salida" && echo si)"
  # Venia fallando con 1 (C32, sin credenciales): el codigo cambia a 3, y el
  # "desde" se conserva (el Wheel no vuelve a esperar sus 15 min).
  igual "C33 ...y el estado pasa de 1 a 3 conservando desde cuando falla" "$((AHORA5 + 1200)),3" "$(vigia)"
  est "{\"ahora\":$AHORA5,$CAM}"

  reciente; p=$(pend); t0=$(tg n); n0=$(sql1 "SELECT COUNT(*) FROM cripto_aviso"); rm -rf "$T/dir/seco"; corre $((AHORA5 + 1800)) --seco; r=$?
  igual "C34 --seco: calcula y deja las señales en seco/, sin escribir ni mandar" "0|si si|$n0|0|$p" \
    "$r|$([ -s "$T/dir/seco/senales.json" ] && echo si) $([ -s "$T/dir/seco/senales.corriente" ] && echo si)|$(sql1 "SELECT COUNT(*) FROM cripto_aviso")|$(( $(tg n) - t0 ))|$(pend)"

  # Telegram acepta pero rqlite no deja marcarlas: sale con 1 y la pasada
  # siguiente las vuelve a mandar (mejor repetida que perdida).
  ejecuta '[["CREATE TRIGGER no_marca BEFORE UPDATE ON cripto_aviso BEGIN SELECT RAISE(ABORT, '"'"'falla a proposito'"'"'); END"]]'
  t0=$(tg n); corre $((AHORA5 + 2100)); r=$?
  igual "C35 mandadas pero sin poder marcarlas: sale con 1 y siguen pendientes" "1|1|$p|si" \
    "$r|$(( $(tg n) - t0 ))|$(pend)|$(grep -q 'no pude marcarlas' "$T/salida" && echo si)"
  ejecuta '[["DROP TRIGGER no_marca"]]'
  t0=$(tg n); corre $((AHORA5 + 2400)); r=$?
  igual "C35 ...la siguiente las repite y las marca" "0|1|0" "$r|$(( $(tg n) - t0 ))|$(pend)"

  # Configuracion que no vale: 64, sin tocar nada; la de los productos, en el log.
  r1=$(PRODS=BTC-USD; corre $((AHORA5 + 2700)); echo $?)
  l1=$(grep -c 'ERROR BTC_AVISOS: BIP-20DEC30-CDE no esta en BTC_PRODUCTOS' "$T/dir/velas.log")
  r2=$(AVH=0; corre $((AHORA5 + 2700)); echo $?)
  r3=$(AVH=abc; corre $((AHORA5 + 2700)); echo $?)
  igual "C36 BTC_AVISOS con un producto que no esta en BTC_PRODUCTOS (dicho en velas.log), o BTC_AVISO_HORAS 0 o raro: 64" "64 1 64 64" "$r1 $l1 $r2 $r3"

  # El awk de las señales: sin el, nada; roto, las velas entran igual y sale con 2.
  rm -f "$T/btc2/"*; cp "$SCRIPT" "$CALC" "$LECTOR" "$FIB" "$IND" "$T/btc2/"
  SCRIPT_BUENO=$SCRIPT; SCRIPT="$T/btc2/Sentinel-BTC-Velas.sh"
  antes=$(huella); corre $((AHORA5 + 3000)); r=$?
  igual "C37 sin avisos-calculo.awk: sale con 1 y no escribe nada" "1|$antes|si" "$r|$(huella)|$(grep -q 'falta .*avisos-calculo.awk' "$T/salida" && echo si)"
  printf 'BEGIN {\n' > "$T/btc2/avisos-calculo.awk"
  corre $((AHORA5 + 3300)); r=$?; SCRIPT=$SCRIPT_BUENO
  igual "C37 con el awk de señales roto: las velas entran, y sale con 2 diciendo por que" "2|si|si|$((AHORA5 + 3300)),2" \
    "$r|$([ "$(sql1 "SELECT MAX(actualizado) FROM cripto_vela")" = $((AHORA5 + 3300)) ] && echo si)|$(grep -q 'el calculo de las señales de BTC fallo: ..*' "$T/salida" && echo si)|$(vigia)"

  # Los valores por defecto, los de 014: BTC_AVISOS y el fichero del bot de
  # thermal-guard en ~/PRC_Thermal (el HOME de las pasadas es $T/casa).
  mkdir -p "$T/casa/PRC_Thermal"; printf 'BOT_TOKEN="tok-casa"\nCHAT_ID="77"\n' > "$T/casa/PRC_Thermal/thermal-guard.conf"
  # Los productos tambien son los de por defecto (con el TEK, que entra aqui por
  # primera vez y del que salen las señales de sus ultimos dias).
  unset AVP TGC; reciente; t0=$(tg n); PRODS="$AV2 TEK-19DEC30-CDE"; corre $((AHORA5 + 3600)); r=$?; PRODS="$AV2"
  igual "C38 con los valores por defecto: señales de BTC (perpetuo y spot) y del Tech 100, y el bot de thermal-guard" "0|1|tok-casa|77|0|si" \
    "$r|$(( $(tg n) - t0 ))|$(tg meta | cut -d'|' -f1)|$(tg meta | cut -d'|' -f2)|$(pend)|$([ "$(sql1 "SELECT COUNT(DISTINCT grupo) FROM cripto_aviso WHERE grupo IN ('BIP-20DEC30-CDE','TEK-19DEC30-CDE')")" = 2 ] && echo si)"
  AVP=""; TGC="$T/tg.conf"

  # El estado se compara con la fila de la base, no con nada local: una fila que
  # alguien dejo distinta se corrige en la pasada siguiente.
  AVP="$AV2"; ejecuta '[["UPDATE sentinel_vigia SET ts=123, pendientes=2 WHERE clave='"'"'btc-senales'"'"'"]]'
  corre $((AHORA5 + 3900)); r=$?
  igual "C39 una fila btc-senales que no cuadra (2 con todo bien) se corrige en la pasada siguiente" "0|$((AHORA5 + 3900)),0" "$r|$(vigia)"
  # Señales apagadas (BTC_AVISOS vacio) con la fila en fallo: si la escribio este
  # equipo, queda a 0 (apagarlas quita su aviso); si otro, no se toca.
  ejecuta '[["UPDATE sentinel_vigia SET ts=123, pendientes=1 WHERE clave='"'"'btc-senales'"'"'"]]'
  AVP=""; corre $((AHORA5 + 4200)); r=$?
  igual "C39 con las señales apagadas, la fila en fallo de este equipo vuelve a 0" "0|$((AHORA5 + 4200)),0" "$r|$(vigia)"
  ejecuta '[["UPDATE sentinel_vigia SET ts=123, pendientes=1, wheel='"'"'otro-nodo'"'"' WHERE clave='"'"'btc-senales'"'"'"]]'
  corre $((AHORA5 + 4500)); r=$?
  igual "C39 ...pero la de otro equipo no la toca" "0|123,1" "$r|$(vigia)"

  # ---------------- TEK (el Tech 100): de lunes a viernes, y los grupos ----------------
  TK=TEK-19DEC30-CDE; AVT="$AV2, $TK"; PT="$AV2 $TK"
  # sqln <consulta>: todas las filas, "a,b c,d" (sin comillas).
  sqln(){ curl -q -s -K "$T/prueba.curlrc" -G "$RQ/db/query" --data-urlencode "q=$1" | node -e 'let s = ""; process.stdin.on("data", d => { s += d; }).on("end", () => {
      const r = JSON.parse(s).results[0]; console.log(r.error ? "ERROR " + r.error : (r.values || []).map(v => v.join(",")).join(" ")); });'; }
  # msge2 <enviado>: como msge, pero con una parte por grupo (BTC primero) y una
  # linea en blanco entre partes.
  msge2(){ node -e '
      const [rq, env] = process.argv.slice(1);
      fetch(rq + "/db/query?level=strong", { method: "POST", headers: { "Content-Type": "application/json", Authorization: "Basic " + Buffer.from("prueba:clave-prueba").toString("base64") },
        body: JSON.stringify([["SELECT grupo, texto, producto FROM cripto_aviso WHERE enviado=? ORDER BY ts,grupo,marco,tipo", +env], ["SELECT fuente FROM cripto_vela LIMIT 1"]]) })
        .then(r => r.json()).then(j => { const f = j.results[0].values || [];
          const orden = ["BIP-20DEC30-CDE", "TEK-19DEC30-CDE"], et = { "BIP-20DEC30-CDE": "BTC", "TEK-19DEC30-CDE": "Tech 100" };
          const partes = orden.filter(g => f.some(x => x[0] === g)).map(g => { const s = f.filter(x => x[0] === g);
            return "📊 " + et[g] + ": señales al cierre\n" + s.map(x => "• " + x[1]).join("\n") + "\n" + (s.some(x => x[2] === "BTC-USD") ? "Spot = BTC-USD, solo donde al perpetuo le falta historia.\n" : ""); });
          console.log(partes.join("\n") + "Lo manda " + j.results[1].values[0][0] + "."); });' "$RQ" "$1"; }
  avg(){ node "$AQUI/avisos-comprueba.js" "$RQ" "prueba:clave-prueba" "$E" "$1" 2>&1; }
  # conGrupo: 1 si cripto_aviso tiene la clave con grupo.
  conGrupo(){ sql1 "SELECT COUNT(*) FROM sqlite_master WHERE name='cripto_aviso' AND sql LIKE '%grupo TEXT%' AND sql LIKE '%PRIMARY KEY (grupo, marco, ts, tipo)%'"; }
  # El sabado siguiente, 10:00 UTC (el reloj de las pasadas solo va hacia delante).
  d_=$(( (AHORA5 + 4800) / 86400 )); w_=$(( (d_ + 4) % 7 )); k_=$(( (6 - w_ + 7) % 7 )); [ "$k_" = 0 ] && k_=7
  SAB=$(( (d_ + k_) * 86400 )); AHT=$((SAB + 36000))
  est "{\"ahora\":$AHT,$CAM}"
  ejecuta "[[\"DELETE FROM cripto_vela WHERE producto='$TK'\"],[\"DELETE FROM cripto_indicador WHERE producto='$TK'\"],[\"DELETE FROM cripto_fibonacci WHERE producto='$TK'\"]]"
  p0=$(pet); AVP=""; PRODS="$TK"; corre $AHT; r=$?; c=$(comprueba $TK)
  case "$r|$c" in "0|coincide"*) pasa "C40 TEK desde cero: todo coincide con la referencia de lunes a viernes ($c)" ;; *) falla "C40 TEK desde cero" "r=$r $c $(head -c 300 "$T/salida")" ;; esac
  igual "C40 ...el fin de semana no es hueco: solo falta el festivo (19/06), y la carga completa lo detalla" "si si" \
    "$(grep -q "^$TK: .* 1 dias faltantes en 1 tramos" "$T/salida" && echo si) $(grep -q "huecos de $TK: 2026-06-19..2026-06-19" "$T/salida" && echo si)"
  igual "C40 ...el sabado, la semana de lunes a viernes ya esta cerrada, con 5 dias" "1,5" \
    "$(sql1 "SELECT cerrada, dias FROM cripto_vela WHERE producto='$TK' AND marco='1w' AND ts=$((SAB - 5 * 86400))")"
  igual "C40 ...sin ciclo de Fibonacci (nacio en junio de 2026)" "si|0" \
    "$(grep -q "^$TK: .*sin ciclo para Fibonacci" "$T/salida" && echo si)|$(sql1 "SELECT COUNT(*) FROM cripto_fibonacci WHERE producto='$TK'")"
  igual "C40 ...y la carga completa hace 3 peticiones (1 con velas y 2 vacias)" "3" "$(( $(pet) - p0 ))"
  # Con BTC_LABORABLES vacio se trata como uno de todos los dias: el fin de
  # semana pasa a ser hueco y la semana sigue abierta hasta el domingo.
  LABP=""; corre $((AHT + 60)); r=$?; unset LABP
  igual "C42 con BTC_LABORABLES vacio, el fin de semana es hueco y la semana sigue abierta" "0|si|0" \
    "$r|$(grep -q "^$TK: .* dias faltantes en [2-9][0-9]* tramos" "$T/salida" && echo si)|$(sql1 "SELECT cerrada FROM cripto_vela WHERE producto='$TK' AND marco='1w' AND ts=$((SAB - 5 * 86400))")"
  corre $((AHT + 120)); r=$?; c=$(comprueba $TK)
  case "$r|$c" in "0|coincide"*) pasa "C42 ...y con el de por defecto, todo coincide otra vez" ;; *) falla "C42 vuelta al de por defecto" "r=$r $c" ;; esac
  # Domingo y lunes 00:30 UTC: pasadas normales.
  est "{\"ahora\":$((AHT + 86400)),$CAM}"; p0=$(pet); corre $((AHT + 86400)); r=$?; c=$(comprueba $TK)
  case "$r|$c" in "0|coincide"*) pasa "C41 el domingo: pasada normal que coincide" ;; *) falla "C41 el domingo" "r=$r $c" ;; esac
  igual "C41 ...una sola peticion, y el festivo viejo no se repite en el log (el resumen si lo cuenta)" "1|0|si" \
    "$(( $(pet) - p0 ))|$(grep -c "huecos de $TK" "$T/salida")|$(grep -q "^$TK: .* 1 dias faltantes en 1 tramos" "$T/salida" && echo si)"
  A_=$((SAB + 2 * 86400 + 1800)); est "{\"ahora\":$A_,$CAM}"; corre $A_; r=$?; c=$(comprueba $TK)
  case "$r|$c" in "0|coincide"*) pasa "C41 el lunes 00:30: la vela del lunes entra a medias y coincide" ;; *) falla "C41 el lunes" "r=$r $c" ;; esac
  igual "C41 ...con la semana nueva abierta" "0,1" "$(sql1 "SELECT cerrada, dias FROM cripto_vela WHERE producto='$TK' AND marco='1w' AND ts=$((SAB + 2 * 86400))")"

  # Dos grupos, BTC y el Tech 100. En seco, una señal del TEK; en la base, una
  # de BTC con su misma (marco, ts, tipo): con la clave de antes chocarian.
  WED=$((SAB + 4 * 86400 + 36000)); est "{\"ahora\":$WED,$CAM}"
  AVP="$AVT"; PRODS="$PT"; rm -rf "$T/dir/seco"; corre $WED --seco
  kt=$(node -e 'const a = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const x = a.find(s => s[1] === process.argv[2]); console.log(x ? [x[2], x[3], x[4]].join(" ") : "")' "$T/dir/seco/senales.json" "$TK" 2>/dev/null)
  set -- $kt
  if [ $# = 3 ]; then
    ejecuta "[[\"DELETE FROM cripto_aviso WHERE grupo='$TK' AND marco='$1' AND ts=$2 AND tipo='$3'\"],[\"INSERT OR IGNORE INTO cripto_aviso(grupo,marco,ts,tipo,producto,sentido,precio,nivel,texto,creado,enviado) VALUES('BIP-20DEC30-CDE','$1',$2,'$3','BTC-USD',1,1,1,'choque',1,0)\"]]"
    t0=$(tg n); corre $WED; r=$?
    igual "C43 con los dos grupos: sale bien y la señal del TEK entra aunque BTC tenga una con su misma (marco, ts, tipo)" "0|1|1" \
      "$r|$(sql1 "SELECT COUNT(*) FROM cripto_aviso WHERE grupo='$TK' AND marco='$1' AND ts=$2 AND tipo='$3'")|$(sql1 "SELECT COUNT(*) FROM cripto_aviso WHERE grupo='BIP-20DEC30-CDE' AND marco='$1' AND ts=$2 AND tipo='$3'")"
    igual "C43 ...un solo mensaje, con una parte por grupo (BTC primero) y la del Tech 100" "1|$(msge2 $WED)|si" \
      "$(( $(tg n) - t0 ))|$(tg txt)|$(tg txt | grep -qx '📊 Tech 100: señales al cierre' && echo si)"
    ejecuta '[["DELETE FROM cripto_aviso WHERE texto='"'"'choque'"'"'"]]'
    c1=$(avg "$AV2"); c2=$(avg "$TK")
    case "$c1|$c2" in "coincide: "*"|coincide: "*) pasa "C43 ...y las de cada grupo son las de su referencia ($c1 / $c2)" ;; *) falla "C43 señales de los dos grupos contra la referencia" "$c1 / $c2" ;; esac
  else falla "C43 el --seco no dio ninguna señal del TEK" "[$kt] $(cat "$T/salida")"; fi
  igual "C43 ...y el estado de las señales, a bien" "$WED,0" "$(vigia)"

  # Si falla un producto del TEK, BTC calcula y guarda las suyas igual.
  THU=$((WED + 86400)); est "{\"ahora\":$THU,$CAM,\"fallaProducto\":\"$TK\"}"
  corre $THU; r=$?; c1=$(avg "$AV2")
  igual "C44 si falla el TEK: sale con 3, BTC calcula y guarda las suyas, y lo dice" "3|si|si" \
    "$r|$(grep -q "señales de Tech 100: no se calculan en esta pasada porque $TK no salio bien" "$T/salida" && echo si)|$(case "$c1" in "coincide: "*) echo si ;; esac)"
  igual "C44 ...y el estado de las señales pasa a 3 (el Wheel avisa si dura)" "$THU,3" "$(vigia)"
  est "{\"ahora\":$THU,$CAM}"; corre $((THU + 300)); r=$?; c2=$(avg "$TK")
  igual "C44 la siguiente: el TEK se pone al dia y el estado vuelve a bien" "0|si|$((THU + 300)),0" "$r|$(case "$c2" in "coincide: "*) echo si ;; esac)|$(vigia)"
  i0=$(raft); corre $((THU + 600)); r=$?; i1=$(raft)
  igual "C45 una pasada sin novedades con los tres productos y los dos grupos: 6 entradas de Raft (2 por producto)" "0|6" "$r|$((i1 - i0))"

  # La semanal del TEK cierra el viernes (5 dias): sus 36 h cuentan desde ahi.
  A=$((THU + 700))
  bd=$(awk -v a=$A -v g=$TK 'BEGIN { split("35 37", h, " ")
         for (k = 1; k <= 2; k++) printf "%s[\"INSERT INTO cripto_aviso(grupo,marco,ts,tipo,producto,sentido,precio,nivel,texto,creado,enviado) VALUES(?,?,?,?,?,?,?,?,?,?,?)\",\"%s\",\"1w\",%d,\"borde\",\"%s\",1,1,1,\"borde5 %s h\",%d,null]", (k > 1 ? "," : "["), g, a - 432000 - h[k] * 3600, g, h[k], a
         print "]" }')
  ejecuta "$bd"; t0=$(tg n); corre $A; r=$?
  igual "C45b semanal del TEK cerrada (el viernes) hace 35 h: se manda; hace 37 h: caduca" "0|1|si|1,1" \
    "$r|$(( $(tg n) - t0 ))|$(tg txt | grep -qx '• borde5 35 h' && echo si)|$(sql1 "SELECT COUNT(*) FROM cripto_aviso WHERE tipo='borde' AND texto LIKE '% 35 h' AND enviado=$A"),$(sql1 "SELECT COUNT(*) FROM cripto_aviso WHERE tipo='borde' AND texto LIKE '% 37 h' AND enviado=-1")"
  ejecuta '[["DELETE FROM cripto_aviso WHERE tipo='"'"'borde'"'"'"]]'

  # Sin la tabla y con un grupo que falla: se crea igual con los demas (si no,
  # un grupo roto para siempre dejaria sin señales a todos).
  ejecuta '[["DROP TABLE cripto_aviso"]]'
  est "{\"ahora\":$THU,$CAM,\"fallaProducto\":\"$TK\"}"; t0=$(tg n); corre $((THU + 750)); r=$?; c1=$(avg "$AV2")
  igual "C45c sin la tabla y con el TEK fallando: la crea con las de BTC (como ya enviadas), sin mandar nada, y sale con 3" "3|1|si|0|0|0" \
    "$r|$(conGrupo)|$(case "$c1" in "coincide: "*) echo si ;; esac)|$(sql1 "SELECT COUNT(*) FROM cripto_aviso WHERE grupo<>'BIP-20DEC30-CDE' OR enviado<>0")|$(( $(tg n) - t0 ))|$(grep -c 'no pude' "$T/salida")"
  est "{\"ahora\":$THU,$CAM}"; corre $((THU + 800)); r=$?; c2=$(avg "$TK")
  igual "C45c ...y cuando el TEK vuelve, sus señales entran" "0|si" "$r|$(case "$c2" in "coincide: "*) echo si ;; esac)"

  # La tabla de antes de los grupos (clave marco, ts, tipo) se migra sola.
  F_=$((THU + 900)); est "{\"ahora\":$F_,$CAM}"
  ejecuta "[[\"DROP TABLE cripto_aviso\"],[\"CREATE TABLE cripto_aviso (marco TEXT NOT NULL, ts INTEGER NOT NULL, tipo TEXT NOT NULL, producto TEXT NOT NULL, sentido INTEGER NOT NULL, precio REAL NOT NULL, nivel REAL, texto TEXT NOT NULL, creado INTEGER NOT NULL, enviado INTEGER, PRIMARY KEY (marco, ts, tipo)) WITHOUT ROWID\"],[\"INSERT INTO cripto_aviso VALUES ('1d', 100, 'ema100', 'BIP-20DEC30-CDE', 1, 1, 1, 'vieja 1', 1, 123)\"],[\"INSERT INTO cripto_aviso VALUES ('1w', 200, 'fib', 'BTC-USD', 1, 1, 1, 'vieja 2', 1, 5)\"],[\"INSERT INTO cripto_aviso VALUES ('1d', 300, 'ha', 'OTRO-X', 1, 1, 1, 'vieja 3', 1, -1)\"]]"
  corre $F_ --seco; r=$?
  igual "C46 con --seco, una tabla de antes de los grupos no se toca (y lo dice)" "0|si|0|3" \
    "$r|$(grep -q 'es de antes de los grupos' "$T/salida" && echo si)|$(conGrupo)|$(sql1 "SELECT COUNT(*) FROM cripto_aviso")"
  ejecuta '[["CREATE VIEW cripto_aviso_nueva AS SELECT 1"]]'
  t0=$(tg n); corre $((F_ + 60)); r=$?
  igual "C46 si la migracion falla: sale con 1, la tabla sigue como estaba, no se manda nada y el estado pasa a 1" "1|si|0|3|0|$((F_ + 60)),1" \
    "$r|$(grep -q 'no pude pasar la tabla cripto_aviso a la clave con grupo' "$T/salida" && echo si)|$(conGrupo)|$(sql1 "SELECT COUNT(*) FROM cripto_aviso")|$(( $(tg n) - t0 ))|$(vigia)"
  ejecuta '[["DROP VIEW cripto_aviso_nueva"]]'
  corre $((F_ + 120)); r=$?
  igual "C46 la siguiente la migra, con las 3 señales viejas: cada una con el grupo de su producto y su enviado" \
    "0|si|1|BIP-20DEC30-CDE,123 BIP-20DEC30-CDE,5 OTRO-X,-1|$((F_ + 120)),0" \
    "$r|$(grep -q 'migrada la tabla cripto_aviso a la clave (grupo, marco, ts, tipo): 3 señales' "$T/salida" && echo si)|$(conGrupo)|$(sqln "SELECT grupo, enviado FROM cripto_aviso WHERE ts < 1000 ORDER BY ts")|$(vigia)"
  c1=$(avg "$AV2"); c2=$(avg "$TK")
  case "$c1|$c2" in "coincide: "*"|coincide: "*) pasa "C46 ...y despues guarda las de los dos grupos, las de la referencia ($c1 / $c2)" ;; *) falla "C46 señales tras migrar" "$c1 / $c2" ;; esac
  corre $((F_ + 180)); r=$?
  igual "C46 ...y no vuelve a migrar" "0|0" "$r|$(grep -c 'migrada la tabla' "$T/salida")"

  # Configuracion de grupos que no vale: un producto en dos grupos.
  r1=$(AVP="BTC-USD, BTC-USD"; PRODS=BTC-USD; corre $((F_ + 240)); echo $?)
  igual "C47 un producto en dos grupos: 64, y lo dice en el log" "64|si" "$r1|$(grep -q 'ERROR BTC_AVISOS: BTC-USD esta en dos grupos' "$T/dir/velas.log" && echo si)"
  AVP=""; PRODS="$AV2"
  unset PRODS
  fi
fi

printf '\n%d bien, %d mal\n' "$ok" "$mal"
[ "$mal" -eq 0 ]
