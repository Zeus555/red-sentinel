#!/usr/bin/env sh
# Banco de pruebas de Sentinel-BTC-Velas.sh.
#
#   A. Calculo (velas-calculo.awk) con numeros hechos a mano.
#   B. Lector de Coinbase (coinbase-velas.awk): respuestas buenas, rotas y vacias.
#   I. Indicadores (indicadores-calculo.awk): numeros hechos a mano y la serie
#      falsa entera contra un calculo independiente (indicadores-ref.js).
#   F. Fibonacci (fibonacci-calculo.awk): casos hechos a mano, la serie falsa y
#      480 series al azar contra un calculo independiente (fibonacci-ref.js).
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
        BTC_PRODUCTOS="${PRODS:-BTC-USD}" BTC_LOTE="${LOTE_P:-200}" sh "$SCRIPT" "$@" > "$T/salida" 2>&1
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

  # Una copia a medias de btc/ (sin el awk de los indicadores) no escribe nada.
  mkdir -p "$T/btc2"; cp "$SCRIPT" "$CALC" "$LECTOR" "$FIB" "$T/btc2/"
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
  fi
fi

printf '\n%d bien, %d mal\n' "$ok" "$mal"
[ "$mal" -eq 0 ]
