#!/bin/sh
# Sentinel v2 - Banco de pruebas del control de acceso por token (determinista).
# Uso: sh Sentinel-Selftest-Token.sh <dir_v2> <dir_temporal>
# Prueba dirigida del cambio "token por entorno + fallo cerrado".
# No depende de la red ni de temporizaciones: solo del control de acceso.
V2="$1"
T="$2"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
no(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

rm -rf "$T"; mkdir -p "$T/jobs"
TOKEN=aaaabbbbccccddddeeeeffff00001111222233334444555566667777888899990

arranca(){ # $1=puerto  $2=modo(argv|env|ninguno)
  P="$1"; M="$2"
  case "$M" in
    argv) gawk -v Port="$P" -v role=Nodo -v token="$TOKEN" -v jobs="$T/jobs" \
            -v worker="$V2/Sentinel-Worker.awk" -v allow="$V2/Sentinel-Allow.conf" \
            -v name=nodoTest -v maxjobs=2 -v electsecs=0 -v eligible=no \
            -f "$V2/Sentinel-Server2.awk" >"$T/s-$P.log" 2>&1 & ;;
    env)  SENTINEL_TOKEN="$TOKEN" gawk -v Port="$P" -v role=Nodo -v jobs="$T/jobs" \
            -v worker="$V2/Sentinel-Worker.awk" -v allow="$V2/Sentinel-Allow.conf" \
            -v name=nodoTest -v maxjobs=2 -v electsecs=0 -v eligible=no \
            -f "$V2/Sentinel-Server2.awk" >"$T/s-$P.log" 2>&1 & ;;
    ninguno) gawk -v Port="$P" -v role=Nodo -v jobs="$T/jobs" \
            -v worker="$V2/Sentinel-Worker.awk" -v allow="$V2/Sentinel-Allow.conf" \
            -v name=nodoTest -v maxjobs=2 -v electsecs=0 -v eligible=no \
            -f "$V2/Sentinel-Server2.awk" >"$T/s-$P.log" 2>&1 & ;;
  esac
  echo $! > "$T/pid-$P"
  i=0; while [ $i -lt 40 ]; do
    curl -s -m 1 -o /dev/null "http://127.0.0.1:$P/version" 2>/dev/null && break
    i=$((i+1)); sleep 0.25
  done
  sleep 1
}
para(){ kill "$(cat "$T/pid-$1" 2>/dev/null)" 2>/dev/null; wait 2>/dev/null; sleep 0.4; }
code(){ curl -s -m 4 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null; }

echo "== A) token por argv (compatibilidad hacia atras) =="
arranca 18301 argv
[ "$(code "http://127.0.0.1:18301/version?token=$TOKEN")" = "200" ] && ok "A1 con token -> 200" || no "A1 ($(code "http://127.0.0.1:18301/version?token=$TOKEN"))"
[ "$(code "http://127.0.0.1:18301/version")" = "401" ] && ok "A2 sin token -> 401" || no "A2 ($(code "http://127.0.0.1:18301/version"))"
para 18301

echo "== B) token por ENTORNO (lo nuevo) =="
arranca 18302 env
[ "$(code "http://127.0.0.1:18302/version?token=$TOKEN")" = "200" ] && ok "B1 con token -> 200" || no "B1 ($(code "http://127.0.0.1:18302/version?token=$TOKEN"))"
[ "$(code "http://127.0.0.1:18302/version")" = "401" ] && ok "B2 sin token -> 401" || no "B2 ($(code "http://127.0.0.1:18302/version"))"
[ "$(code "http://127.0.0.1:18302/version?token=otracosa")" = "401" ] && ok "B3 token ajeno -> 401" || no "B3"
# el worker debe heredar SENTINEL_TOKEN y completar el callback
J=$(curl -s -m 5 -X POST "http://127.0.0.1:18302/task?token=$TOKEN&action=whoami" 2>/dev/null)
ID=$(echo "$J" | sed -n 's/.*"job":"\([^"]*\)".*/\1/p')
if [ -n "$ID" ]; then
  i=0; ST=""
  while [ $i -lt 20 ]; do
    ST=$(sed -n 's/^status\t//p' "$T/jobs/$ID.status" 2>/dev/null)
    [ "$ST" = "done" ] && break
    i=$((i+1)); sleep 0.5
  done
  [ "$ST" = "done" ] && ok "B4 el worker hereda el token y completa el callback" || no "B4 (status='$ST')"
  # El worker escribe el .status ANTES de mandar el callback, asi que hay que
  # sondear: comprobarlo una sola vez es una carrera (fallo de la prueba, no del codigo).
  j=0; IN=""
  while [ $j -lt 20 ]; do
    IN=$(curl -s -m 4 "http://127.0.0.1:18302/health?token=$TOKEN" 2>/dev/null | grep -o '"inflight":[0-9]*' | cut -d: -f2)
    [ "$IN" = "0" ] && break
    j=$((j+1)); sleep 0.5
  done
  [ "$IN" = "0" ] && ok "B5 el callback libero la ranura (inflight=0)" || no "B5 (inflight=$IN)"
else
  no "B4 no se pudo encolar el trabajo"; no "B5"
fi
para 18302

echo "== C) SIN token: debe FALLAR CERRADO (antes abria el agente) =="
arranca 18303 ninguno
C1=$(code "http://127.0.0.1:18303/version")
[ "$C1" = "503" ] && ok "C1 sin token configurado -> 503, no sirve nada" || no "C1 (devolvio $C1; 200 = AGENTE ABIERTO)"
C2=$(code "http://127.0.0.1:18303/version?token=$TOKEN")
[ "$C2" = "503" ] && ok "C2 tampoco sirve con un token cualquiera" || no "C2 ($C2)"
para 18303

echo
echo "== Resultado dirigido: $PASS PASS / $FAIL FAIL =="
[ "$FAIL" -eq 0 ]
