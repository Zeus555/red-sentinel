#!/usr/bin/env sh
# Sentinel v2 - Telemetria de bateria (Termux).
#
# POR QUE EXISTE: sentinel017 murio sin previo aviso el 2026-08-18. Estaba
# enchufado, pero Android habia dejado de cargarlo — por encima de ~42 C corta la
# carga para proteger la bateria — y el telefono estuvo dias tirando de bateria
# hasta agotarla. No habia forma de saberlo: guardabamos temperatura, pero NO
# carga. Y el aviso termico de thermal-guard salta a 45 C, POR ENCIMA del corte,
# asi que existe una franja donde el equipo deja de cargar en silencio.
#
# NO se toca thermal-guard: es codigo en produccion que apaga el telefono si se
# calienta de verdad. Esto va aparte y solo lee y escribe.
#
# Se limita a los nodos Termux; en Ubuntu/Windows sale sin hacer nada.
set -u
BASE="${SENTINEL_BASE:-$HOME/PRC_Sentinel/v2}"
CONF="$BASE/sentinel.conf"
[ -r "$CONF" ] || exit 0
. "$CONF"
command -v termux-battery-status >/dev/null 2>&1 || exit 0
RQ="${RQLITE:-http://127.0.0.1:4001}"

# --- Nodos moviles: a donde escribir cuando no hay rqlite local -------------
# En el movil, Sentinel-Roam.sh para rqlited al salir de casa para no replicar
# Raft sobre datos moviles. Sin esto la telemetria de bateria se perderia justo
# cuando mas hace falta: fuera de casa el telefono vive de la bateria, y este
# script existe precisamente porque un nodo se agoto sin que nadie lo viera.
# Con RQLITE_FALLBACK definido se escribe al lider remoto por la malla (una fila
# cada 5 min es trafico despreciable). Sin la variable —los nodos fijos— no se
# comprueba nada y el comportamiento es el de siempre.
if [ -n "${RQLITE_FALLBACK:-}" ]; then
  curl -s -m 4 -o /dev/null "$RQ/status" 2>/dev/null || RQ="$RQLITE_FALLBACK"
fi

# --- Reparto en el tiempo -------------------------------------------------
# Sin esto los 11 nodos disparan en el MISMO segundo :00 y cada equipo recibe una
# veintena de peticiones a la vez sobre un aceptador monohilo. Medido el 17/08:
# 148 de los 153 fallos de "no responde" cayeron exactamente en el segundo :00, y
# hubo nodos que en ese instante no se alcanzaban ni a si mismos por 127.0.0.1.
# El desfase es FIJO por nodo y por tarea (sale del nombre), no aleatorio: cada
# equipo tiene siempre su hueco, el reparto no cambia en cada arranque y se puede
# predecir al depurar. Comprobado que con los nombres reales no hay colisiones.
# SENTINEL_NOJITTER=1 lo salta, para probar a mano sin esperar.
if [ "${SENTINEL_NOJITTER:-0}" != "1" ]; then
  _j=$(printf '%s-bateria' "${NAME:-x}" | cksum 2>/dev/null | cut -d' ' -f1)
  case "${_j:-}" in ''|*[!0-9]*) _j=0 ;; esac
  [ "$_j" -gt 0 ] && sleep $(( _j % 120 ))
fi

B=$(termux-battery-status 2>/dev/null | tr -d '\n ')
[ -n "$B" ] || exit 0
campo(){ printf '%s' "$B" | grep -oE "\"$1\":\"?[-A-Za-z_0-9.]+\"?" | head -1 | cut -d: -f2 | tr -d '"'; }

PCT=$(campo percentage); EST=$(campo status); ENCH=$(campo plugged)
TMP=$(campo temperature);  SAL=$(campo health);  CC=$(campo charge_counter)
UA=$(campo current_average)
case "${PCT:-}" in ''|*[!0-9]*) exit 0 ;; esac      # sin dato fiable, no se inventa

num(){ case "${1:-}" in ''|*[!-0-9.]*) printf 0 ;; *) printf '%s' "$1" ;; esac; }
UA=$(num "$UA"); CC=$(num "$CC"); TMP=$(num "$TMP")

sql(){ curl -s -m 10 -o /dev/null -H "Content-Type: application/json" -d "$1" "$RQ/db/execute"; }

# Tabla propia, creada a la primera. Se deja aparte de sentinel_temp para no
# tocar la que ya alimenta el panel y el chatbot.
sql '[["CREATE TABLE IF NOT EXISTS sentinel_bateria (id INTEGER PRIMARY KEY AUTOINCREMENT, node TEXT, ts INTEGER, pct INTEGER, estado TEXT, enchufe TEXT, ua INTEGER, temp_c REAL, salud TEXT, cc INTEGER)"]]'
sql '[["CREATE INDEX IF NOT EXISTS ix_bateria_node_ts ON sentinel_bateria(node, ts)"]]'

sql "[[\"INSERT INTO sentinel_bateria(node,ts,pct,estado,enchufe,ua,temp_c,salud,cc) VALUES(?,?,?,?,?,?,?,?,?)\",\"${NAME}\",$(date +%s),$PCT,\"${EST:-?}\",\"${ENCH:-?}\",$UA,$TMP,\"${SAL:-?}\",$CC]]"

# Poda una vez al dia y desde un solo sitio por nodo: 9 telefonos cada 5 min son
# ~2600 filas diarias, y esto tiene que caber en un movil.
MARCA="$BASE/.bateria-podada"
HOY=$(date +%Y-%m-%d)
if [ "$(cat "$MARCA" 2>/dev/null)" != "$HOY" ]; then
  sql "[[\"DELETE FROM sentinel_bateria WHERE node=? AND ts < strftime('%s','now')-1209600\",\"${NAME}\"]]"
  printf '%s\n' "$HOY" > "$MARCA"
fi
exit 0
