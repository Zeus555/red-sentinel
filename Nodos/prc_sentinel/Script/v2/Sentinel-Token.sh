#!/usr/bin/env sh
# Sentinel v2 - Token de flota (Fase 5).
#
# UN SOLO token para toda la red Sentinel. Es el mecanismo de pertenencia: un
# agente que se instale en la LAN pero no tenga este token NO puede entrar a la
# red — el resto de nodos le responden 401 y no le dan ni la version.
#
#   ./Sentinel-Token.sh create           crea el token de flota (primer nodo)
#   ./Sentinel-Token.sh show             lo imprime (para llevarlo a otro nodo)
#   ./Sentinel-Token.sh import <token>   lo instala en este nodo
#   ./Sentinel-Token.sh verify <token>   comprueba si coincide con el de aqui
#   ./Sentinel-Token.sh rotate           genera uno nuevo (¡rompe la flota hasta
#                                        repartirlo a TODOS los nodos!)
#
# CUALQUIER nodo puede crearlo: el que arranca la red primero lo genera y los
# demas lo importan. No hay un "servidor de tokens".
#
# Vive en fleet.token (600), aparte de sentinel.conf, para que rotarlo o
# repartirlo sea copiar un unico fichero.

set -u
BASE="${SENTINEL_BASE:-$HOME/PRC_Sentinel/v2}"
FILE="$BASE/fleet.token"
mkdir -p "$BASE" 2>/dev/null

die(){ echo "ERROR: $1" >&2; exit 1; }

gen(){
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    # Respaldo sin openssl: mezcla varias fuentes debiles para no depender de una
    # sola. Menos bueno que openssl; se avisa.
    echo "AVISO: sin openssl, token generado con entropia debil. Instala openssl y rota." >&2
    gawk -v s="$(date +%s%N 2>/dev/null)$$$(head -c 32 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')" \
      'BEGIN{ srand(); t=""; n=length(s); for(i=0;i<64;i++){ c=substr(s,(i%n)+1,1); t=t sprintf("%x",(index("0123456789abcdef",c)+int(rand()*16))%16) } print t }'
  fi
}

write(){ # $1 = token
  printf '%s\n' "$1" > "$FILE"
  chmod 600 "$FILE" 2>/dev/null
}

case "${1:-}" in
  create)
    [ -f "$FILE" ] && die "ya existe $FILE. Usa 'show' para verlo, o 'rotate' para cambiarlo (rompe la flota hasta repartirlo)."
    t=$(gen); [ -n "$t" ] || die "no se pudo generar el token"
    write "$t"
    echo "Token de flota creado en $FILE"
    echo "Repartelo a los demas nodos con:  ./Sentinel-Token.sh import <token>"
    echo
    echo "$t"
    ;;
  show)
    [ -f "$FILE" ] || die "no hay token en este nodo. Crealo con 'create' o traelo con 'import'."
    cat "$FILE"
    ;;
  import)
    t="${2:-}"; [ -n "$t" ] || die "uso: $0 import <token>"
    # Formato esperado: hexadecimal largo. Se rechaza cualquier cosa mas corta
    # para que un token flojo no entre por descuido.
    echo "$t" | grep -qE '^[0-9a-fA-F]{32,128}$' || die "el token debe ser hexadecimal de 32 a 128 caracteres"
    if [ -f "$FILE" ] && [ "$(cat "$FILE")" = "$t" ]; then
      echo "Ya estaba instalado ese mismo token (sin cambios)."
      exit 0
    fi
    write "$t"
    echo "Token de flota instalado en $FILE"
    echo "Reinicia el servicio para que lo tome:  sv restart sentinel-v2"
    ;;
  verify)
    t="${2:-}"; [ -n "$t" ] || die "uso: $0 verify <token>"
    [ -f "$FILE" ] || die "no hay token en este nodo"
    if [ "$(cat "$FILE")" = "$t" ]; then echo "COINCIDE: este nodo pertenece a esa red"; exit 0
    else echo "NO coincide: este nodo NO pertenece a esa red"; exit 1; fi
    ;;
  rotate)
    [ -f "$FILE" ] || die "no hay token que rotar; usa 'create'"
    cp -f "$FILE" "$FILE.anterior" 2>/dev/null
    t=$(gen); write "$t"
    echo "Token rotado. El anterior queda en $FILE.anterior"
    echo "IMPORTANTE: hasta que este token no este en TODOS los nodos, los que"
    echo "sigan con el viejo quedaran fuera de la red."
    echo
    echo "$t"
    ;;
  *)
    echo "uso: $0 {create | show | import <token> | verify <token> | rotate}"
    exit 1 ;;
esac
