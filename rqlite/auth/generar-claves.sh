#!/usr/bin/env bash
# generar-claves.sh - claves de rqlite (-auth) y todos los ficheros que salen de ellas.
#
# FUENTE DE VERDAD: claves.tsv (usuario<TAB>clave), con los 7 usuarios de la tabla de
# rqlite/auth/README.md. Este script NUNCA cambia una clave que ya existe: solo crea
# las que faltan. Para rotar una clave se borra a mano su linea de claves.tsv (ver el
# README). Todo lo demas se vuelve a generar desde claves.tsv en cada pasada, asi que
# no se edita a mano:
#   <usuario>.curlrc        sentinel, respaldo, loteria, lector, admin e indeed (curl -K)
#   chatbot.env             RQLITE_USER y RQLITE_PASSWORD del chatbot de sentinel005
#   indeed.env              RQLITE_USER y RQLITE_PASSWORD de RPA Indeed (laptop)
#   auth-ronda{1,2}-{votante,novotante}.json   el fichero -auth de rqlited
#
# POR QUE CADA ENTRADA LLEVA LOS TRES CAMPOS: rqlite 10.2.x lee el fichero -auth con
# un solo struct que reutiliza entre entradas, asi que una entrada sin "perms" o sin
# "password" HEREDA los de la anterior. Por eso "*" va con "password": "" y todas
# llevan "perms" explicito, aunque sea repetir.
#
# Uso:  generar-claves.sh               crea las claves que falten y regenera el resto
#       generar-claves.sh --comprobar   valida sin escribir nada
#
# Directorio: ${RQLITE_AUTH_DIR:-$HOME/.config/rqlite}  (700, ficheros 600).
# La salida solo lleva nombres de fichero, usuarios y el md5 de los auth-*.json: el
# md5 sirve para comprobar en cada nodo que su auth.json es el que toca. NUNCA se
# imprime una clave, ni un trozo de un fichero.
# Codigo de salida: 0 todo bien, 1 algun error, 2 uso incorrecto.

set -u
umask 077
export LC_ALL=C

DIR="${RQLITE_AUTH_DIR:-$HOME/.config/rqlite}"
TSV="$DIR/claves.tsv"
TAB=$(printf '\t')

USUARIOS="nodo sentinel respaldo loteria lector admin indeed"
# Los que tienen cliente con curl -K. "nodo" no: solo lo usa -join-as de rqlited,
# que saca la clave de su propio fichero -auth. (RPA Indeed usa indeed.env; su
# .curlrc sirve para probar la clave a mano.)
CLIENTES="sentinel respaldo loteria lector admin indeed"
# El no votante no lleva admin, respaldo ni indeed: esos tres solo hablan con los
# votantes (RPA Indeed escribe en sentinel005), y asi un telefono (sentinel019 sale
# de casa) nunca guarda la clave de admin.
NOVOTANTE="nodo sentinel loteria lector"
AUTHS="auth-ronda1-votante.json auth-ronda1-novotante.json auth-ronda2-votante.json auth-ronda2-novotante.json"
DERIVADOS="sentinel.curlrc respaldo.curlrc loteria.curlrc lector.curlrc admin.curlrc indeed.curlrc chatbot.env indeed.env $AUTHS"

MODO=generar
case "${1:-}" in
  "") ;;
  --comprobar) MODO=comprobar ;;
  -h|--ayuda|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) printf 'uso: %s [--comprobar]\n' "$0" >&2; exit 2 ;;
esac
[ $# -le 1 ] || { printf 'uso: %s [--comprobar]\n' "$0" >&2; exit 2; }

ERRORES=0
err(){ printf 'ERROR: %s\n' "$1" >&2; ERRORES=$((ERRORES+1)); }
aviso(){ printf 'aviso: %s\n' "$1" >&2; }

EN_WINDOWS=0
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) EN_WINDOWS=1 ;; esac

es_usuario(){ case " $USUARIOS " in *" $1 "*) return 0 ;; esac; return 1; }
clave_valida(){ case "$1" in ""|*[!A-Za-z0-9]*) return 1 ;; esac; [ ${#1} -eq 32 ]; }
md5_de(){ md5sum < "$1" | cut -c1-32; }
perm_de(){ stat -c %a "$1" 2>/dev/null || echo '?'; }
# Rutas para node/python, que en Git Bash son ejecutables de Windows.
ruta_nativa(){ if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# 32 caracteres [A-Za-z0-9] de /dev/urandom. La clave queda en una variable: nunca
# pasa por argv de otro programa (printf es interno del shell).
nueva_clave(){ tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 32; }

# Lee claves.tsv en K_<usuario>. Lineas en blanco se ignoran; cualquier otra cosa mal
# formada es un error y entonces no se escribe nada. En los mensajes nunca va el
# contenido de una linea: si le falta el tabulador, la linea entera podria ser una clave.
VISTOS=" "
cargar_claves(){
  [ -f "$TSV" ] || return 0
  n=0
  while IFS= read -r linea || [ -n "$linea" ]; do
    n=$((n+1))
    [ -z "$linea" ] && continue
    u=${linea%%"$TAB"*}
    k=${linea#*"$TAB"}
    if [ "$u" = "$linea" ]; then err "claves.tsv linea $n: falta el tabulador entre usuario y clave"; continue; fi
    if ! es_usuario "$u"; then err "claves.tsv linea $n: usuario desconocido"; continue; fi
    case "$VISTOS" in *" $u "*) err "claves.tsv linea $n: el usuario $u esta repetido"; continue ;; esac
    if ! clave_valida "$k"; then err "claves.tsv linea $n ($u): la clave no son 32 caracteres [A-Za-z0-9] (CRLF?)"; continue; fi
    VISTOS="$VISTOS$u "
    eval "K_$u=\$k"
  done < "$TSV"
}
tiene_clave(){ case "$VISTOS" in *" $1 "*) return 0 ;; esac; return 1; }
clave_de(){ eval "printf '%s' \"\$K_$1\""; }

# ---- contenido de cada fichero derivado (por stdout) ---------------------------------
perms_tabla(){
  case "$1" in
    nodo)     printf '%s' '"join", "join-read-only"' ;;
    sentinel) printf '%s' '"execute", "query", "status", "ready"' ;;
    respaldo) printf '%s' '"backup", "execute"' ;;
    loteria)  printf '%s' '"execute", "query", "status"' ;;
    lector)   printf '%s' '"query", "status"' ;;
    admin)    printf '%s' '"all"' ;;
    indeed)   printf '%s' '"execute"' ;;
  esac
}
# Ronda 1: cada usuario lleva ademas "ui", para comprobar su clave contra /console/, y
# "*" se queda con lo que usan los clientes sin clave y los nodos que se unen sin
# -join-as, asi que nada se rompe. No lleva "backup", "load", "snapshot", "remove",
# "leader-ops" ni "ui": un nodo que se quede en la Ronda 1 ya no da la base entera sin
# clave por /db/backup?noleader, ni deja cargar otra base, quitar un nodo o mover al
# lider. Ronda 2: cada usuario con lo suyo y "*" solo con "ready" (/readyz abierto).
ESTRELLA_R1='"join", "join-read-only", "execute", "query", "status", "ready"'
ESTRELLA_R2='"ready"'

gen_auth(){ # $1 = 1|2   $2 = votante|novotante
  if [ "$2" = votante ]; then lista=$USUARIOS; else lista=$NOVOTANTE; fi
  printf '[\n'
  for u in $lista; do
    p=$(perms_tabla "$u")
    [ "$1" = 1 ] && p="$p, \"ui\""
    printf '  {"username": "%s", "password": "%s", "perms": [%s]},\n' "$u" "$(clave_de "$u")" "$p"
  done
  if [ "$1" = 1 ]; then p=$ESTRELLA_R1; else p=$ESTRELLA_R2; fi
  printf '  {"username": "*", "password": "", "perms": [%s]}\n' "$p"
  printf ']\n'
}

gen_fichero(){ # $1 = nombre del fichero derivado
  case "$1" in
    *.curlrc)    printf 'user = "%s:%s"\n' "${1%.curlrc}" "$(clave_de "${1%.curlrc}")" ;;
    chatbot.env) printf 'RQLITE_USER=lector\nRQLITE_PASSWORD=%s\n' "$(clave_de lector)" ;;
    indeed.env)  printf 'RQLITE_USER=indeed\nRQLITE_PASSWORD=%s\n' "$(clave_de indeed)" ;;
    auth-ronda1-votante.json)   gen_auth 1 votante ;;
    auth-ronda1-novotante.json) gen_auth 1 novotante ;;
    auth-ronda2-votante.json)   gen_auth 2 votante ;;
    auth-ronda2-novotante.json) gen_auth 2 novotante ;;
  esac
}

# ---- validacion de los auth-*.json ---------------------------------------------------
# Con node si esta; si no, con python. Los mensajes nunca llevan una clave: ni el texto
# del error de JSON.parse (en node reciente cita un trozo del fichero) ni un campo raro.
JS_VALIDA='
const fs = require("fs"), path = require("path");
const PERMS = new Set(["all","join","join-read-only","remove","execute","query","status",
  "ready","backup","load","snapshot","leader-ops","ui"]);
const NOMBRES = new Set(["nodo","sentinel","respaldo","loteria","lector","admin","indeed","*"]);
const CLAVE = new RegExp("^[A-Za-z0-9]{32}$"), PALABRA = new RegExp("^[a-z-]{1,20}$");
let malos = 0;
for (const f of process.argv.slice(1)) {
  const nombre = path.basename(f);
  const fallo = m => { console.error("ERROR: " + nombre + ": " + m); malos++; };
  let d, texto;
  try { texto = fs.readFileSync(f, "utf8"); } catch (e) { fallo("no se pudo leer"); continue; }
  try { d = JSON.parse(texto); } catch (e) { fallo("no es JSON valido"); continue; }
  if (!Array.isArray(d)) { fallo("no es un array"); continue; }
  if (!d.length) { fallo("array vacio"); continue; }
  const vistos = new Set();
  d.forEach((e, i) => {
    let q = "entrada " + (i + 1);
    if (e === null || typeof e !== "object" || Array.isArray(e)) { fallo(q + ": no es un objeto"); return; }
    if (typeof e.username === "string" && NOMBRES.has(e.username)) q += " (" + e.username + ")";
    for (const k of ["username", "password", "perms"]) if (!(k in e)) fallo(q + ": falta \"" + k + "\"");
    for (const k of Object.keys(e)) if (!["username", "password", "perms"].includes(k))
      fallo(q + ": campo de mas" + (PALABRA.test(k) ? " \"" + k + "\"" : ""));
    if ("username" in e) {
      if (typeof e.username !== "string" || !e.username) fallo(q + ": username no es texto");
      else if (!NOMBRES.has(e.username)) fallo(q + ": usuario desconocido");
      else if (vistos.has(e.username)) fallo(q + ": usuario repetido");
      else vistos.add(e.username);
    }
    if ("password" in e) {
      if (typeof e.password !== "string") fallo(q + ": password no es texto");
      else if (e.username === "*") { if (e.password !== "") fallo(q + ": \"*\" va con password vacia"); }
      else if (!CLAVE.test(e.password)) fallo(q + ": la clave no son 32 caracteres [A-Za-z0-9]");
    }
    if ("perms" in e) {
      if (!Array.isArray(e.perms)) { fallo(q + ": perms no es un array"); return; }
      if (!e.perms.length) fallo(q + ": perms vacio");
      const ps = new Set();
      for (const p of e.perms) {
        if (typeof p !== "string" || !PERMS.has(p)) fallo(q + ": permiso no valido" + (typeof p === "string" && PALABRA.test(p) ? " \"" + p + "\"" : ""));
        else if (ps.has(p)) fallo(q + ": permiso repetido \"" + p + "\"");
        ps.add(p);
      }
    }
  });
  if (!vistos.has("*")) fallo("falta la entrada \"*\"");
}
process.exit(malos ? 1 : 0);
'
PY_VALIDA='
import json, os, re, sys
PERMS = {"all","join","join-read-only","remove","execute","query","status","ready",
         "backup","load","snapshot","leader-ops","ui"}
NOMBRES = {"nodo","sentinel","respaldo","loteria","lector","admin","indeed","*"}
CLAVE = re.compile(r"^[A-Za-z0-9]{32}\Z"); PALABRA = re.compile(r"^[a-z-]{1,20}\Z")
malos = 0
for f in sys.argv[1:]:
    nombre = os.path.basename(f)
    def fallo(m):
        global malos
        print("ERROR: " + nombre + ": " + m, file=sys.stderr); malos += 1
    try:
        with open(f, encoding="utf-8") as fh: texto = fh.read()
    except Exception:
        fallo("no se pudo leer"); continue
    try:
        d = json.loads(texto)
    except Exception:
        fallo("no es JSON valido"); continue
    if not isinstance(d, list): fallo("no es un array"); continue
    if not d: fallo("array vacio"); continue
    vistos = set()
    for i, e in enumerate(d):
        q = "entrada %d" % (i + 1)
        if not isinstance(e, dict): fallo(q + ": no es un objeto"); continue
        u = e.get("username")
        if isinstance(u, str) and u in NOMBRES: q += " (" + u + ")"
        for k in ("username", "password", "perms"):
            if k not in e: fallo(q + ": falta \"" + k + "\"")
        for k in e:
            if k not in ("username", "password", "perms"):
                fallo(q + ": campo de mas" + ((" \"" + k + "\"") if isinstance(k, str) and PALABRA.match(k) else ""))
        if "username" in e:
            if not isinstance(u, str) or not u: fallo(q + ": username no es texto")
            elif u not in NOMBRES: fallo(q + ": usuario desconocido")
            elif u in vistos: fallo(q + ": usuario repetido")
            else: vistos.add(u)
        if "password" in e:
            p = e["password"]
            if not isinstance(p, str): fallo(q + ": password no es texto")
            elif u == "*":
                if p != "": fallo(q + ": \"*\" va con password vacia")
            elif not CLAVE.match(p): fallo(q + ": la clave no son 32 caracteres [A-Za-z0-9]")
        if "perms" in e:
            ps = e["perms"]
            if not isinstance(ps, list): fallo(q + ": perms no es un array"); continue
            if not ps: fallo(q + ": perms vacio")
            vp = set()
            for p in ps:
                if not isinstance(p, str) or p not in PERMS:
                    fallo(q + ": permiso no valido" + ((" \"" + p + "\"") if isinstance(p, str) and PALABRA.match(p) else ""))
                elif p in vp: fallo(q + ": permiso repetido \"" + p + "\"")
                if isinstance(p, str): vp.add(p)
    if "*" not in vistos: fallo("falta la entrada \"*\"")
sys.exit(1 if malos else 0)
'
# Valida los auth-*.json que haya en el directorio, uno por uno. VALIDAR_CON=python
# fuerza python aunque haya node (sirve para probar ese camino).
# MSYS_NO_PATHCONV: que Git Bash no "traduzca" el codigo como si fuera una ruta.
validar_json(){
  validador=""
  if [ "${VALIDAR_CON:-}" != python ] && command -v node >/dev/null 2>&1; then
    validador=node
  else
    for py in python3 python; do
      # En Windows "python" puede ser el atajo de la Tienda, que no ejecuta nada.
      if command -v "$py" >/dev/null 2>&1 && "$py" -c 'import json' >/dev/null 2>&1; then validador=$py; break; fi
    done
  fi
  if [ -z "$validador" ]; then err "no hay node ni python para validar el JSON de los auth-*.json"; return; fi
  for nombre in $AUTHS; do
    [ -f "$DIR/$nombre" ] || continue
    if [ "$validador" = node ]; then
      MSYS_NO_PATHCONV=1 node -e "$JS_VALIDA" "$(ruta_nativa "$DIR/$nombre")" || ERRORES=$((ERRORES+1))
    else
      MSYS_NO_PATHCONV=1 "$validador" -I -c "$PY_VALIDA" "$(ruta_nativa "$DIR/$nombre")" || ERRORES=$((ERRORES+1))
    fi
  done
}

# ---- comprobaciones (las dos modalidades acaban aqui) --------------------------------
comprobar(){
  if [ ! -d "$DIR" ]; then err "no existe el directorio $DIR"; return; fi
  if [ ! -f "$TSV" ]; then err "falta $TSV (ejecuta generar-claves.sh sin opciones)"; return; fi
  for u in $USUARIOS; do tiene_clave "$u" || err "claves.tsv: falta la clave de $u"; done
  [ $ERRORES -eq 0 ] || return

  presentes=""
  for nombre in $DERIVADOS; do
    f="$DIR/$nombre"
    if [ ! -f "$f" ]; then err "$nombre: no existe (ejecuta generar-claves.sh sin opciones)"; continue; fi
    presentes="$presentes $nombre"
    # Lo que hay en disco tiene que ser exactamente lo que sale de claves.tsv.
    if [ "$(gen_fichero "$nombre" | md5sum | cut -c1-32)" != "$(md5_de "$f")" ]; then
      err "$nombre: no corresponde a claves.tsv (ejecuta generar-claves.sh sin opciones)"
    fi
  done

  # Formato de los ficheros de cliente, por si alguien los toca a mano.
  for u in $CLIENTES; do
    f="$DIR/$u.curlrc"
    [ -f "$f" ] || continue
    if [ "$(wc -l < "$f" | tr -d ' ')" != 1 ] || ! grep -Eq "^user = \"$u:[A-Za-z0-9]{32}\"\$" "$f"; then
      err "$u.curlrc: formato incorrecto (tiene que ser una sola linea  user = \"$u:<clave>\")"
    fi
  done
  for par in chatbot.env:lector indeed.env:indeed; do
    nombre=${par%%:*}; u=${par#*:}; f="$DIR/$nombre"
    [ -f "$f" ] || continue
    if [ "$(wc -l < "$f" | tr -d ' ')" != 2 ] || [ "$(sed -n 1p "$f")" != "RQLITE_USER=$u" ] \
       || ! sed -n 2p "$f" | grep -Eq '^RQLITE_PASSWORD=[A-Za-z0-9]{32}$'; then
      err "$nombre: formato incorrecto (RQLITE_USER=$u y RQLITE_PASSWORD=<clave>)"
    fi
  done

  validar_json

  # Permisos: 700 el directorio y 600 cada fichero. En Git Bash stat no ve los
  # permisos de NTFS (contesta segun la umask del proceso): ahi solo se avisa.
  if [ $EN_WINDOWS = 1 ]; then
    aviso "en Windows (Git Bash) stat no ve los permisos de NTFS, asi que el 600 no se comprueba (dentro de %USERPROFILE% solo entran tu usuario, SYSTEM y Administradores)"
  else
    [ "$(perm_de "$DIR")" = 700 ] || err "$DIR: permisos $(perm_de "$DIR"), tienen que ser 700"
    for nombre in claves.tsv $presentes; do
      p=$(perm_de "$DIR/$nombre")
      [ "$p" = 600 ] || err "$nombre: permisos $p, tienen que ser 600"
    done
  fi
}

# ---- no guardar nunca claves dentro de un repositorio (el de la red es PUBLICO) ------
# Se mira desde el primer antecesor que exista, para no crear antes el directorio.
dentro_de_git(){
  command -v git >/dev/null 2>&1 || return 1
  d=$DIR
  while [ ! -d "$d" ]; do
    p=$(dirname "$d"); [ "$p" = "$d" ] && return 1; d=$p
  done
  git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

printf 'Directorio: %s\n' "$DIR"

if dentro_de_git; then err "$DIR esta dentro de un repositorio git: las claves no pueden vivir ahi"; exit 1; fi
if [ $MODO = generar ]; then
  if ! mkdir -p "$DIR"; then err "no se pudo crear $DIR"; exit 1; fi
  chmod 700 "$DIR" 2>/dev/null
fi

cargar_claves
if [ $ERRORES -gt 0 ]; then
  printf 'claves.tsv tiene errores: no se ha tocado nada.\n' >&2
  exit 1
fi

if [ $MODO = generar ]; then
  # Todos los temporales son <fichero>.tmp.<pid> dentro del directorio.
  trap 'rm -f "$DIR"/*.tmp.$$' EXIT
  trap 'exit 1' HUP INT TERM

  # 1. Claves que falten. Las existentes no se tocan: solo se anaden lineas al final.
  nuevas=""
  for u in $USUARIOS; do
    tiene_clave "$u" && continue
    k=$(nueva_clave)
    if ! clave_valida "$k"; then err "no se pudo sacar una clave de 32 caracteres de /dev/urandom"; exit 1; fi
    eval "K_$u=\$k"
    VISTOS="$VISTOS$u "
    nuevas="$nuevas $u"
  done
  k=""
  if [ -n "$nuevas" ]; then
    t="$TSV.tmp.$$"
    {
      if [ -s "$TSV" ]; then
        cat "$TSV"
        # Si a la ultima linea le falta el salto, se pone para no pegar dos claves.
        [ "$(tail -c 1 "$TSV" | wc -l | tr -d ' ')" = 1 ] || printf '\n'
      fi
      for u in $nuevas; do printf '%s\t%s\n' "$u" "$(clave_de "$u")"; done
    } > "$t" || { err "no se pudo escribir claves.tsv"; exit 1; }
    chmod 600 "$t" 2>/dev/null
    mv -f "$t" "$TSV" || { err "no se pudo escribir claves.tsv"; exit 1; }
    printf 'claves.tsv: clave nueva para%s\n' "$nuevas"
  else
    printf 'claves.tsv: estan las %d claves, ninguna nueva\n' "$(set -- $USUARIOS; echo $#)"
  fi
  chmod 600 "$TSV" 2>/dev/null

  # 2. Ficheros derivados: se escriben en .tmp y se cambian de golpe, y solo si cambian.
  for nombre in $DERIVADOS; do
    f="$DIR/$nombre"; t="$f.tmp.$$"
    if ! gen_fichero "$nombre" > "$t"; then err "$nombre: no se pudo escribir"; continue; fi
    chmod 600 "$t" 2>/dev/null
    if [ -f "$f" ] && cmp -s "$t" "$f"; then
      rm -f "$t"; chmod 600 "$f" 2>/dev/null; estado="sin cambios"
    else
      if [ -f "$f" ]; then estado=actualizado; else estado=creado; fi
      mv -f "$t" "$f" || { err "$nombre: no se pudo colocar"; continue; }
    fi
    printf '  %-28s %s\n' "$nombre" "$estado"
  done
fi

comprobar

printf 'md5 de los ficheros -auth (en cada nodo: md5sum ~/.config/rqlite/auth.json):\n'
for nombre in $AUTHS; do
  [ -f "$DIR/$nombre" ] && printf '  %-28s %s\n' "$nombre" "$(md5_de "$DIR/$nombre")"
done

if [ $ERRORES -gt 0 ]; then
  printf 'Comprobacion: %d error(es).\n' "$ERRORES" >&2
  exit 1
fi
printf 'Comprobacion: OK\n'
exit 0
