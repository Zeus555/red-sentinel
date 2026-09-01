#!/usr/bin/env sh
# Sentinel v2 - PKI privada con openssl (Fase 3).
# Crea la CA de la red Sentinel y los certificados de nodo/cliente que dan
# IDENTIDAD ademas de cifrado (mTLS): un nodo sin certificado firmado por esta CA
# no puede ni abrir la conexion.
#
#   ./Sentinel-PKI.sh ca                      -> crea la CA (una sola vez, en el Wheel)
#   ./Sentinel-PKI.sh node <nombre> [ip]      -> certificado de servidor para un nodo
#   ./Sentinel-PKI.sh client <nombre>         -> certificado de cliente para un llamador
#
# Idempotente: si el fichero ya existe no lo pisa (regenerar una CA invalidaria
# todos los certificados de la flota).
# La clave de la CA (ca.key) NO se copia a los nodos: solo viaja ca.pem.

set -u
DIR="${SENTINEL_CERTS:-$(cd "$(dirname "$0")" && pwd)/Certs}"
DAYS_CA=3650
DAYS_CERT=825          # limite habitual de los clientes TLS modernos
mkdir -p "$DIR"

die(){ echo "ERROR: $1" >&2; exit 1; }

# Instala openssl segun el SO si falta (mismo detector que el resto del v2).
ensure_openssl(){
  command -v openssl >/dev/null 2>&1 && return 0
  echo "openssl no esta; intentando instalarlo..."
  u=$(uname -a 2>/dev/null || echo "")
  # NO interactivo: un paquete con configuracion modificada (openssl.cnf) abre un
  # dialogo de dpkg y, sin stdin, aborta con "end of file on stdin at conffile
  # prompt" sin instalar nada (visto en sentinel003 el 2026-08-13).
  NI='-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef'
  export DEBIAN_FRONTEND=noninteractive
  case "$u" in
    *Android*)   apt-get install -y $NI openssl-tool || apt-get install -y $NI openssl ;;
    *Ubuntu*|*Debian*|*Raspbian*) (sudo apt-get update -y && sudo -E apt-get install -y $NI openssl) || apt-get install -y $NI openssl ;;
    *tinycore*)  tce-load -wi openssl ;;
    *MINGW*|*MSYS*|*CYGWIN*) command -v choco >/dev/null 2>&1 && choco install -y openssl ;;
    *)           command -v choco >/dev/null 2>&1 && choco install -y openssl ;;
  esac
  command -v openssl >/dev/null 2>&1 || die "no se pudo instalar openssl; instalalo a mano"
}

# Fichero de configuracion temporal: -addext no existe en openssl viejos, y asi
# el mismo script sirve en toda la flota.
mkconf(){ # $1=CN  $2=SAN(opcional)  $3=fichero
  cat > "$3" <<EOF
[req]
distinguished_name = dn
prompt             = no
[dn]
CN = $1
O  = Sentinel
[ca_ext]
basicConstraints       = critical,CA:TRUE
keyUsage               = critical,keyCertSign,cRLSign
subjectKeyIdentifier   = hash
EOF
  if [ -n "${2:-}" ]; then
    cat >> "$3" <<EOF
[ext]
subjectAltName   = $2
basicConstraints = CA:FALSE
keyUsage         = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
EOF
  fi
}

cmd_ca(){
  [ -f "$DIR/ca.pem" ] && { echo "La CA ya existe: $DIR/ca.pem (no se toca)"; return 0; }
  cnf="$DIR/.ca.cnf"; mkconf "Sentinel Root CA" "" "$cnf"
  # -extensions ca_ext es imprescindible: sin basicConstraints CA:TRUE el
  # certificado se emite igual pero NINGUNA verificacion de cadena lo acepta
  # ("invalid CA certificate"), y el fallo solo aparece en el primer handshake.
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 \
    -days "$DAYS_CA" -keyout "$DIR/ca.key" -out "$DIR/ca.pem" \
    -config "$cnf" -extensions ca_ext || die "fallo creando la CA"
  rm -f "$cnf"; chmod 600 "$DIR/ca.key" 2>/dev/null
  openssl verify -CAfile "$DIR/ca.pem" "$DIR/ca.pem" >/dev/null 2>&1 \
    || die "la CA generada no se valida a si misma; revisa la version de openssl"
  echo "CA creada: $DIR/ca.pem  (guarda ca.key: NO se copia a los nodos)"
}

issue(){ # $1=nombre  $2=SAN  $3=etiqueta
  name="$1"; san="$2"
  [ -f "$DIR/ca.pem" ] || die "primero crea la CA:  ./Sentinel-PKI.sh ca"
  [ -f "$DIR/$name.pem" ] && { echo "Ya existe $DIR/$name.pem (no se toca)"; return 0; }
  cnf="$DIR/.$name.cnf"; mkconf "$name" "$san" "$cnf"
  openssl req -newkey rsa:2048 -nodes -sha256 \
    -keyout "$DIR/$name.key" -out "$DIR/$name.csr" -config "$cnf" || die "fallo creando la CSR"
  openssl x509 -req -in "$DIR/$name.csr" -CA "$DIR/ca.pem" -CAkey "$DIR/ca.key" \
    -CAcreateserial -days "$DAYS_CERT" -sha256 \
    -extfile "$cnf" -extensions ext -out "$DIR/$name.pem" || die "fallo firmando"
  rm -f "$cnf" "$DIR/$name.csr"; chmod 600 "$DIR/$name.key" 2>/dev/null
  echo "Certificado de $3 creado: $DIR/$name.pem"
}

ensure_openssl
case "${1:-}" in
  ca)     cmd_ca ;;
  node)   n="${2:-}"; [ -n "$n" ] || die "uso: $0 node <nombre> [ip]"
          ip="${3:-}"
          san="DNS:$n,DNS:localhost,IP:127.0.0.1"
          [ -n "$ip" ] && san="$san,IP:$ip"
          issue "$n" "$san" "nodo" ;;
  client) n="${2:-}"; [ -n "$n" ] || die "uso: $0 client <nombre>"
          issue "$n" "DNS:$n" "cliente" ;;
  *) echo "uso: $0 {ca | node <nombre> [ip] | client <nombre>}"; exit 1 ;;
esac
