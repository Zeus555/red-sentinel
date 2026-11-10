#!/bin/sh
# Sentinel - Recibe un latido de casa (EC2). NO se ejecuta a mano: lo lanza sshd
# por el command= de authorized_keys, con el nombre del nodo FIJO en cada llave:
#
#   restrict,command="/home/ubuntu/sentinel-latido/latido-recibir.sh sentinel014" ssh-ed25519 AAAA... sentinel014-latido
#
# Asi quien llama no puede elegir que fichero se escribe ni ejecutar otra cosa: lo
# que pida como comando se ignora, y solo se acepta UNA linea con el formato
#   <nodo> <ts_ultima_pasada_de_avisos> <wheel> <pendientes> <readyz>
# donde <nodo> tiene que ser el mismo que fija la llave. Los numeros, sin ceros a
# la izquierda: dash los leeria como octal y latido-vigilar.sh fallaria.
set -u
D=$(cd "$(dirname "$0")" && pwd)
n="${1:-}"
case "$n" in sentinel[0-9][0-9][0-9]) ;; *) echo "nodo invalido"; exit 1 ;; esac
l=$(head -c 200 | head -n 1 | tr -d '\r')
if ! printf '%s\n' "$l" | grep -Eqx "$n (0|[1-9][0-9]{0,11}) [A-Za-z0-9_-]{1,32} (0|[1-9][0-9]{0,3}) [0-9]{3}"; then
  echo "linea invalida"; exit 1
fi
now=$(date +%s)
printf '%s %s\n' "$now" "$l" > "$D/$n.latido.tmp" && mv "$D/$n.latido.tmp" "$D/$n.latido"
echo ok
