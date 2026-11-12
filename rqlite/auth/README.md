# rqlite con contraseña (`-auth`)

Hasta el 2026-11-11 el clúster rqlite no pedía usuario: cualquiera que llegara al `:4001`
leía, escribía o descargaba la base entera. Se cerró en tres pasos, y cada uno se podía
desplegar sin romper el anterior:

| Paso | Qué cambia | Qué se rompe si algo sale mal |
|---|---|---|
| **Fase 0** | Los clientes mandan usuario y clave. rqlited sigue **sin** `-auth`, y un rqlited sin `-auth` ignora la cabecera | Nada: sin fichero de credenciales cada cliente funciona como siempre |
| **Ronda 1** | Cada rqlited arranca con `-auth` y `-join-as nodo`, pero el usuario `"*"` (cualquiera, con o sin clave) conserva lo que hacen hoy los clientes sin clave: escribir, leer, `/status`, `/readyz` y el join | Nada: piden clave `/console/` (sirve para comprobar la de cada cliente), `/db/backup`, `/db/load`, `/remove`, `/snapshot` y `/leader`, que solo usan el respaldo (con su clave) y las operaciones a mano |
| **Ronda 2** | `"*"` se queda solo con `ready`: sin una clave buena, todo menos `/readyz` da **HTTP 401** | Un cliente con la clave mal o sin fichero |

**Estado:** las tres hechas el 2026-11-11 en los 11 nodos. Fase 0 y Ronda 1 por la mañana.
Ronda 2 de 19:07 a 19:17, hora de la laptop: `"*"` solo con `ready`, y cada nodo guarda su
fichero de la Ronda 1 como `~/.config/rqlite/auth.json.ronda1`. Antes del cierre se barrieron
todos los clientes, y solo faltaba reiniciar `rpa-indeed`. En los 11, sin clave, `/status`
da 401 y `/readyz` da 200. El join real de `nodo` se probó contra votantes de la Ronda 2
(paso 2b, 010 y 005). Quedan por ver, a su hora, la copia de sentinel020 (10:45 UTC, las
02:45 en invierno) y la carga de Lotería de las 07:53.

Este directorio tiene las herramientas: [`generar-claves.sh`](generar-claves.sh) crea las
claves y todos los ficheros que salen de ellas, y
[`repartir-clientes.sh`](repartir-clientes.sh) los lleva a los equipos en la Fase 0. **Aquí
no hay ninguna clave**: el repositorio es público y las claves viven solo en los equipos.

## Usuarios

| Usuario | Permisos | Quién lo usa |
|---|---|---|
| `nodo` | `join`, `join-read-only` | `-join-as` de cada rqlited, desde la Ronda 1. Un votante necesita `join` y un no votante `join-read-only` (`join` no le basta) |
| `sentinel` | `execute`, `query`, `status`, `ready` | todos los `.sh` de la flota (thermal-guard, Bateria, elect.sh y Wheel.awk, Alert, Latido, vigía del respaldo...) |
| `respaldo` | `backup`, `execute` | `Sentinel-Respaldo.sh` en sentinel020 (la copia y el `INSERT` de su registro) |
| `loteria` | `execute`, `query`, `status` | la cadena de Lotería de la laptop |
| `lector` | `query`, `status` | chatbot de sentinel005 y RED Web Hub |
| `admin` | `all` | operaciones a mano desde la laptop |
| `indeed` | `execute` | RPA Indeed (laptop): su espejo `indeed_jobs` escribe en `sentinel005:4001/db/execute` |
| `*` | Ronda 1: `join`, `join-read-only`, `execute`, `query`, `status`, `ready`. Ronda 2: solo `ready` | cualquier petición, con o sin clave |

En la Ronda 1 cada usuario lleva además `ui`, para poder probar su clave contra `/console/`.
`"*"` no lleva `backup`, `load`, `snapshot`, `remove` ni `leader-ops` ya en la Ronda 1: ningún
cliente los usa sin clave, y así un nodo que se quede atrás en la Ronda 1 no entrega la base
entera a cualquiera por `/db/backup?noleader` ni deja cargar otra base, quitar un nodo o
mover al líder.

**La lista de usuarios se cierra antes de la Ronda 1.** Va metida en los ficheros `-auth`:
añadir un usuario después cuesta dos reinicios rodantes. `Sentinel-Discover.awk` pregunta
sin clave, pero hoy no lo lanza nadie.

Permisos por ruta (verificado en laboratorio con v10.2.7, 264 combinaciones por ronda, y
otra vez con los ficheros ajustados: 398 de 398, con un nodo sin `-auth` que sigue entrando):
`/db/execute` = `execute`, `/db/query` = `query`, `/db/request` = `execute` **y** `query`,
`/nodes`, `/status` y `/debug/vars` = `status`, `/readyz` = `ready`, `/db/backup` =
`backup`, `GET`/`POST /leader` = `leader-ops`, `/console/` = `ui` (con clave buena da 200,
sin redirección). Una petición tiene que pasar **dos** ficheros: el del nodo al que se
pregunta (si no la acepta, da 401 allí mismo, sin reenviar; por ejemplo `admin` contra un
no votante) y, si se reenvía, el del líder. Un rechazo es siempre un 401: con el cuerpo
vacío si lo da el nodo al que se pregunta, o con `remote Execute not authorized` (o
`remote query`/`remote backup ... not authorized`) si lo da el líder tras el reenvío. Hay
que mirar el código, no el cuerpo. Sin líder, `/readyz` da 503 o 500.

### Dos ficheros -auth: votante y no votante

Votan **sentinel014, sentinel016 y sentinel005**; el resto (001, 002, 003, 009, 010, 017,
018 y 019) son no votantes. El fichero del no votante **no lleva `admin`, `respaldo` ni
`indeed`**: esos tres solo hablan con los votantes (el respaldo baja de 014 o 016, RPA Indeed
escribe en 005 y el líder siempre es un votante), y así un teléfono que sale de casa, como
sentinel019, nunca guarda la clave de admin. `loteria` sí va en los dos, porque Lotería pregunta `/status` a los teléfonos para
encontrar al líder.

### Por qué cada entrada lleva los tres campos

rqlite 10.2.x lee el fichero `-auth` reutilizando la misma estructura de una entrada a la
siguiente: **una entrada sin `perms` o sin `password` hereda los de la anterior**. Por eso
todas las entradas llevan `username`, `password` y `perms`, y `"*"` va con
`"password": ""`. No editar los JSON a mano: salen de `claves.tsv`.

## Dónde vive cada fichero

Todo nace en la laptop (sentinel013), en `%USERPROFILE%\.config\rqlite\` (`~/.config/rqlite`
en Git Bash), y desde ahí se copia. Todos los ficheros van en 600 y el directorio en 700.

| Fichero en la laptop | Destino | Lo lee |
|---|---|---|
| `claves.tsv` | **solo la laptop**: es la fuente de verdad (`usuario<TAB>clave`) | `generar-claves.sh` |
| `sentinel.curlrc` | los 11 nodos: `~/.config/rqlite/sentinel.curlrc` (se cambia con `RQLITE_CRED`) | `rqcurl` de los `.sh`; `elect.sh` le pasa la ruta al Wheel.awk |
| `respaldo.curlrc` | sentinel020: `D:\RED Respaldo\rqlite-respaldo.curlrc` | `Sentinel-Respaldo.sh` (`RQ_CRED`) |
| `chatbot.env` | sentinel005: las líneas `RQLITE_USER` y `RQLITE_PASSWORD` de `~/Herramientas/WhatsApp_Checker/.env` | chatbot de WhatsApp (`server.js`), al arrancar |
| `loteria.curlrc` | se queda en la laptop | TareaDiaria.ps1, CargaRqlite.ps1, AplicaCongruencia.ps1, Web/server.js y AnalisisCobertura.py |
| `lector.curlrc` | se queda en la laptop | RED Web Hub |
| `admin.curlrc` | se queda en la laptop | uso a mano (`curl -K`) |
| `indeed.env` | se queda en la laptop: sus dos líneas van en `D:\RPA Indeed\.env` (ignorado por git), detrás de `RQLITE_URL` | RPA Indeed (`src/db/rqlite.js`), al arrancar: tras cambiarlas, `pm2 restart rpa-indeed` |
| `indeed.curlrc` | se queda en la laptop | solo para probar su clave a mano |
| `auth-ronda1-votante.json`, `auth-ronda2-votante.json` | 014, 016 y 005: `~/.config/rqlite/auth.json` | rqlited (`-auth`), solo al arrancar |
| `auth-ronda1-novotante.json`, `auth-ronda2-novotante.json` | 001, 002, 003, 009, 010, 017, 018 y 019: `~/.config/rqlite/auth.json` | rqlited (`-auth`), solo al arrancar |

Los `.curlrc` tienen una sola línea, `user = "usuario:clave"`, y se pasan con `curl -K`: así
la clave no sale en `ps`. Las claves son 32 caracteres `[A-Za-z0-9]`, sin comillas, barras
ni dos puntos. rqlite 10.2.x guarda las claves **en claro** en `auth.json` (no hay bcrypt):
quien tenga una shell en un nodo puede leer las de su fichero.

Si se pierde `claves.tsv` no hay forma de recuperarlo desde los nodos sin leer sus
`auth.json`: guardar una copia fuera del equipo (gestor de contraseñas o un USB cifrado).

## Generar las claves

```bash
bash rqlite/auth/generar-claves.sh               # crea las que falten y regenera el resto
bash rqlite/auth/generar-claves.sh --comprobar   # solo valida, no escribe nada
```

- Crea las claves que falten en `claves.tsv` y **nunca cambia una que ya existe**. Si
  `claves.tsv` tiene una línea mal (sin tabulador, usuario repetido o desconocido, clave con
  otro formato, un CRLF) no toca nada y lo dice.
- Vuelve a escribir cada fichero derivado, y solo lo sustituye si cambia.
- Valida el resultado: JSON válido (con node, o con python si no hay node), que sea un array,
  sin usuarios repetidos, los tres campos con su tipo en cada entrada, permisos solo de la
  lista de v10.2.x (`all`, `join`, `join-read-only`, `remove`, `execute`, `query`, `status`,
  `ready`, `backup`, `load`, `snapshot`, `leader-ops`, `ui`), formato de las claves, que cada
  fichero sea exactamente lo que sale de `claves.tsv` y los permisos 600. En Git Bash `stat`
  no ve los permisos de NTFS: ahí solo avisa (dentro de `%USERPROFILE%` solo entran el
  usuario, SYSTEM y Administradores).
- La salida solo lleva nombres de fichero, usuarios y el md5 de los `auth-*.json`. **Nunca
  una clave.** El md5 es el que tiene que dar `md5sum ~/.config/rqlite/auth.json` en cada nodo.
- Otro directorio con `RQLITE_AUTH_DIR=/ruta`. Se niega a escribir dentro de un repositorio git.

## Fase 0: repartir los ficheros de cliente

Primero se despliega el código de los clientes que sabe mandar credenciales (sin fichero se
comporta como siempre), y después los ficheros:

```bash
bash rqlite/auth/repartir-clientes.sh --seco             # lo que haría, sin conectar
bash rqlite/auth/repartir-clientes.sh                    # los 11 nodos + sentinel020
bash rqlite/auth/repartir-clientes.sh --solo 005,019     # solo esos
```

Para cada equipo la clave viaja por la **entrada** de ssh (nunca en argv); el script remoto
va como argumento de `sh -c`, no lleva secretos y hace `umask 077`, `mkdir -p`, escribe en un
`.tmp`, `chmod 600` y `mv`. Después el equipo devuelve el md5 y los permisos (nunca el
contenido) y se comparan con el fichero local. Usa `$HOME` en remoto, porque en Termux es
`/data/data/com.termux/files/home`. Un equipo inalcanzable da `FALLO` y no frena a los demás;
al final hay un resumen y el código de salida es distinto de 0 si alguno falló. ssh va con
`StrictHostKeyChecking=yes` (el `~/.ssh/config` dice `accept-new`): un equipo que no esté en
`known_hosts` da `FALLO` en vez de recibir la clave sin verificar; se entra una vez a mano y
se repite con `--solo`.

- **sentinel005**: además cambia `RQLITE_USER` y `RQLITE_PASSWORD` en el `.env` del chatbot
  (o los añade al final) sin tocar el resto, con copia `.env.bak-AAAAMMDD` (una segunda
  pasada el mismo día no la pisa). **No reinicia el chatbot**; hay que hacerlo a mano:
  `SVDIR=$PREFIX/var/service sv restart whatsapp_checker`.
- **sentinel020** (Windows): el ssh abre `cmd.exe`, así que se llega a Git Bash con
  `cd /d "C:\Program Files\Git\usr\bin" && .\bash.exe ...`. Los permisos de NTFS no se
  comprueban.

Como rqlited aún no tiene `-auth`, en la Fase 0 no cambia nada visible. Comprobación: los
avisos de Telegram siguen callados y los datos siguen entrando (`MAX(ts)` por tabla).

## Ronda 1: `-auth` con la puerta abierta

Requisitos: Fase 0 completa en los 11 nodos, sentinel020, el chatbot y la laptop, y
comprobada así:
- el md5 de cada script desplegado coincide con el del repositorio, incluidos
  `retention.sh` de sentinel001 y `thermal-guard-linux.sh` de 014 y 016;
- en sentinel005, `sv status whatsapp_checker` da menos segundos en marcha que la edad del
  `.env` (`stat -c %Y`), y su `run` lleva `--env-file`;
- las apps de pm2 de la laptop que hablan con rqlite se reiniciaron después de desplegar su
  código.

En la Ronda 1 nada delata a un cliente que no manda la clave: `"*"` lo deja pasar y
`auth_ok` también cuenta a los anónimos. Si falla, se ve en la Ronda 2. La excepción es el
respaldo: `/db/backup` ya pide clave, así que con la de `respaldo` mal la copia de esa noche
falla (y avisa) ya en la Ronda 1.

Horario: no empezar entre las 02:30 y las 04:30 (copia de sentinel020 desde 014 a las
10:45 UTC, que son las 03:45 en verano y las 02:45 en invierno, unos 3 min; y poda de 001 a
las 03:30) ni entre las 07:45 y las 08:15 (Lotería).

1. **Copiar el fichero -auth** a cada nodo como `~/.config/rqlite/auth.json`. rqlited solo
   lo lee al arrancar, así que copiarlo antes no cambia nada. Desde `~/.config/rqlite` en la
   laptop:

   ```bash
   copia(){ # $1 = equipo  $2 = fichero
     ssh -T -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 "$1" 'umask 077; d="$HOME/.config/rqlite"; mkdir -p "$d" && cat > "$d/auth.json.tmp" && chmod 600 "$d/auth.json.tmp" && mv -f "$d/auth.json.tmp" "$d/auth.json" && md5sum < "$d/auth.json"' < "$2"
   }
   for n in sentinel014 sentinel016 sentinel005; do copia $n auth-ronda1-votante.json; done
   for n in sentinel001 sentinel002 sentinel003 sentinel009 sentinel010 sentinel017 sentinel018 sentinel019; do copia $n auth-ronda1-novotante.json; done
   ```

   Cada md5 tiene que coincidir con el que imprime `generar-claves.sh`.

2. **Añadir `-auth` y `-join-as nodo` al arranque**, nodo a nodo y justo antes de
   reiniciarlo, con copia del original (`run.bak-AAAAMMDD` / `rqlited.service.bak-AAAAMMDD`).
   Van **antes del directorio de datos**, que es el último argumento:
   - Termux: `$PREFIX/var/service/rqlited/run`, con
     `-auth /data/data/com.termux/files/home/.config/rqlite/auth.json -join-as nodo`.
   - Ubuntu (014 y 016): `~/.config/systemd/user/rqlited.service`, con
     `-auth /home/sentinel/.config/rqlite/auth.json -join-as nodo` en `ExecStart`, y luego
     `systemctl --user daemon-reload`.

   Un miembro con `-join` vuelve a hacer el join en **cada** arranque: sin un `-join-as`
   válido muere a los ~12 s y entra en bucle. `-join-as` se ignora si el propio nodo no
   lleva `-auth`.

   En todos los nodos la línea de arranque acaba en el directorio de datos (en sentinel019
   va sola en la última línea, tras una `\`), así que basta un `sed`:

   ```sh
   # Termux
   r=$PREFIX/var/service/rqlited/run; cp -p "$r" "$r.bak-$(date +%Y%m%d)"
   sed -i 's# /data/data/com.termux/files/home/rqlite-data$# -auth /data/data/com.termux/files/home/.config/rqlite/auth.json -join-as nodo /data/data/com.termux/files/home/rqlite-data#' "$r"
   grep -c -- '-join-as nodo /data/data/com.termux/files/home/rqlite-data$' "$r"   # tiene que dar 1
   # Ubuntu
   u=~/.config/systemd/user/rqlited.service; cp -p "$u" "$u.bak-$(date +%Y%m%d)"
   sed -i 's# /home/sentinel/rqlite-data$# -auth /home/sentinel/.config/rqlite/auth.json -join-as nodo /home/sentinel/rqlite-data#' "$u"
   grep -c -- '-join-as nodo /home/sentinel/rqlite-data$' "$u" && systemctl --user daemon-reload
   ```

   Si el `grep` da 0, no reiniciar: la línea no acaba como se esperaba. Al terminar la
   ronda, poner lo mismo en los espejos `Nodos/runit_services/rqlited.run.sh` y
   `Nodos/systemd_services/*/rqlited.service`, y en el alta de nodo de `Nodos/README.md`:
   un nodo reinstalado sin `-auth` no manda la clave en el join, y en la Ronda 2 muere a
   los ~12 s.

3. **Reiniciar de uno en uno**, en este orden: un no votante de prueba (sentinel010), el
   resto de no votantes, **sentinel005**, **sentinel016** y **el líder del momento el
   último** (hoy sentinel014; mirarlo justo antes en `/status`, campo `leader`). Es
   prudencia, no requisito: en el laboratorio, con credenciales no hubo ni un 401 en ningún
   estado mixto, tampoco con el orden equivocado.
   - Antes de reiniciar un votante (005, 016 o el líder): los tres votantes tienen que salir
     `reachable` en `/nodes?nonvoters`. Con uno caído, reiniciar otro deja el clúster sin
     líder hasta que vuelva (laboratorio con 2 votantes: 8 s sin líder y 8 escrituras
     perdidas), y el reiniciado puede morir por el `-join`.
   - **sentinel019, solo en casa**: `roam.state` empieza por `casa` y `sv status rqlited`
     dice `run`. `sv restart` **arranca** un servicio parado: si Sentinel-Roam.sh lo bajó
     fuera de casa, lo levantaría en LTE o en una WiFi ajena, y Roam no lo vuelve a bajar
     hasta el siguiente cambio de sitio. Si está fuera, dejar el fichero copiado y el `run`
     editado: el `sv up` de Roam al volver aplica el cambio. Lo mismo si thermal-guard lo
     bajó por calor (`sv status` dice `down`).
   - Termux: `SVDIR=$PREFIX/var/service sv -w 60 restart rqlited` (tiene que acabar en `ok: run:`)
   - Ubuntu: `systemctl --user restart rqlited`

   Tras cada uno, antes de pasar al siguiente:
   - En su log, una línea `successfully joined cluster` de este arranque y ninguna
     `clustering failure` ni `did you forget to set -join-as`. Termux:
     `grep -E 'successfully joined|clustering failure|did you forget' $PREFIX/var/log/sv/rqlited/current | tail -n 3`.
     Ubuntu: `journalctl --user -u rqlited --since -3min | grep -E 'successfully joined|clustering failure|did you forget'`.
   - Que siga vivo **30 s después de esa línea**, no de `sv restart`. Sin un `-join-as`
     válido el nodo da `/readyz` 200 a los pocos segundos y aplica el log, pero muere unos
     12 s después de empezar el join (5 intentos cada 3 s; medido: 12,2-12,5 s, código de
     salida 1, y runit y systemd lo relanzan en bucle). `/readyz` no prueba nada.
   - Que **su** `/status` diga `"auth":"enabled"` (en el JSON está dentro de `http`), que su
     `applied_index` alcance al del líder y que `/nodes?nonvoters` muestre un líder. Con
     `sentinel.curlrc`, que está en los dos ficheros y tiene `status` (`admin.curlrc` no
     vale contra un no votante en la Ronda 2):

   ```bash
   IP=192.168.0.34; L=192.168.0.21   # el recién reiniciado (aquí sentinel010) y el líder
   for h in $IP $L; do printf '%s ' $h; curl -s -m 5 -K ~/.config/rqlite/sentinel.curlrc "http://$h:4001/status" | grep -o -E '"auth": *"[a-z]+"|"applied_index": *[0-9]+' | tr '\n' ' '; echo; done
   curl -s -m 5 -K ~/.config/rqlite/sentinel.curlrc "http://$IP:4001/nodes?nonvoters&timeout=2s" | grep -o -E '"(leader|reachable)": *true' | sort | uniq -c
   ```

   Medido en sentinel014 (x86, base pequeña): de TERM a `/readyz` 200, 0,66-1,26 s; al
   reiniciar al líder, el cambio de líder tarda menos de 0,6 s (3 de 3 limpios con 3
   votantes). En un teléfono con la base real no está medido: medirlo en sentinel010 antes
   de seguir. Opcional, para el líder: pasarle el mando antes a otro votante con
   `curl -s -o /dev/null -w '%{http_code}\n' -K ~/.config/rqlite/admin.curlrc -XPOST "http://192.168.0.21:4001/leader?wait"`
   (200 = hecho) y reiniciarlo ya como seguidor.

   En sentinel010, que lleva v10.2.5 como los demás teléfonos (el laboratorio fue con
   v10.2.7), probar antes el fichero en un rqlited suelto en loopback:
   `d=$(mktemp -d); ~/go/bin/rqlited -node-id prueba -http-addr 127.0.0.1:14401 -raft-addr 127.0.0.1:14402 -auth ~/.config/rqlite/auth.json $d/datos & p=$!`;
   sin `-K` `/console/` da 401 y `/status` 200; con `-K sentinel.curlrc`, `/console/` da 200.
   Luego `kill -TERM $p; rm -rf $d`.

4. **Probar la clave de cada cliente contra `/console/`**, la única ruta que `"*"` no deja
   pasar. Primero, sin `-K`: `curl -s -o /dev/null -w '%{http_code}\n' http://$IP:4001/console/`
   tiene que dar **401**; si da 200 o 404, ese nodo no tiene `-auth` (o su versión no tiene
   consola) y la prueba no vale ahí. Con una clave buena da **200**; **401** es una clave
   mala; `000` es que no respondió (repetir):

   ```bash
   # desde la laptop, contra un nodo ya reiniciado (IP = la suya; 192.168.0.21 es sentinel014).
   # Un no votante no conoce admin, respaldo ni indeed: con él solo sentinel, loteria y lector.
   IP=192.168.0.21
   for u in sentinel respaldo loteria lector admin indeed; do
     printf '%s ' $u; curl -s -o /dev/null -w '%{http_code}\n' -K ~/.config/rqlite/$u.curlrc http://$IP:4001/console/
   done
   # desde cada nodo, con su propio fichero
   ssh sentinel010 'curl -s -o /dev/null -w "%{http_code}\n" -K "$HOME/.config/rqlite/sentinel.curlrc" http://localhost:4001/console/'
   ```

   El chatbot usa la misma clave que `lector.curlrc`, y sentinel020 la de `respaldo.curlrc`
   (`repartir-clientes.sh` ya comprobó que sus copias son idénticas). `nodo` no tiene
   `.curlrc`: su clave sale del propio `auth.json`, así que basta con que el md5 del paso 1
   sea el bueno.

Marcha atrás: volver al `run`/unidad de la copia y reiniciar ese nodo. En Ubuntu:
`cp -p ~/.config/systemd/user/rqlited.service.bak-AAAAMMDD ~/.config/systemd/user/rqlited.service && systemctl --user daemon-reload && systemctl --user restart rqlited`.

## Ronda 2: cerrar la puerta

1. Copiar `auth-ronda2-votante.json` y `auth-ronda2-novotante.json` igual que en el paso 1
   de la Ronda 1 (mismo reparto) y comprobar los md5. Ojo: a partir de aquí, cualquier
   reinicio de un nodo (un corte de luz, el watchdog) le aplica ya la Ronda 2. Se copia
   también a sentinel017 y sentinel019 aunque su reinicio vaya a mano (paso 5): así su
   próximo arranque ya aplica la Ronda 2.
2. Otro reinicio rodante, en el mismo orden y con las mismas comprobaciones. El arranque no
   cambia: ya lleva `-auth` y `-join-as nodo`. Con el líder aún en la Ronda 1, un cliente
   sin clave que pregunte a un nodo de la Ronda 2 ya recibe 401; uno con clave pasa por
   todos.

   2b. **Probar el join de verdad.** En la Ronda 1 `"*"` deja pasar cualquier join, y en
   esta ronda los no votantes, 005 y 016 hacen el join contra 014 mientras 014 sigue en la
   Ronda 1: el primero que comprueba de verdad la clave de `nodo` es 014, al final. Con 014
   ya reiniciado, reiniciar **otra vez** sentinel010 (no votante, `join-read-only`,
   v10.2.5) y sentinel005 (votante, `join`, v10.2.5), con las comprobaciones del paso 3 de
   la Ronda 1. Si no, la primera prueba real sería el próximo reinicio desatendido de un
   teléfono, y si fallara entraría en bucle sin nadie mirando.
3. En cada nodo: `/status` con `sentinel.curlrc` da 200; sin `-K` da 401 (cuerpo vacío);
   `/readyz` sin clave da 200 (o 503/500 si ese nodo no ve líder). Contra un no votante,
   `admin.curlrc` da 401: es lo esperado, porque no está en su fichero. Justo después de
   reiniciar 005, preguntar al chatbot por el estado de la red: es el primer cliente que
   nota una clave que no carga.
4. Vigilar durante **24 h** el contador `auth_fail` (junto a `auth_ok`, las aceptadas) en
   `/debug/vars` de **cada** nodo, no solo del líder: cada nodo cuenta solo los 401 que da
   él, y el contador vuelve a 0 al reiniciarlo. `/debug/vars` pide `status`, así que vale
   `sentinel.curlrc` en votantes y no votantes. El JSON lleva un espacio tras los dos
   puntos (`"auth_fail": 2`):

   ```bash
   for ip in 192.168.0.231 192.168.0.45 192.168.0.214 192.168.0.166 192.168.0.154 192.168.0.34 192.168.0.21 192.168.0.159 192.168.0.22 192.168.0.130 192.168.0.218; do
     printf '%s ' $ip; curl -s -m 5 -K ~/.config/rqlite/sentinel.curlrc http://$ip:4001/debug/vars | grep -o -E '"auth_(fail|ok)": *[0-9]+' | tr '\n' ' '; echo
   done
   ```

   Avisos de Telegram: Alert (solo en el Wheel), el Latido (014 y 016), el vigía y el
   respaldo dan un aviso propio para el 401, distinto de "sin líder" (`/readyz` 503 **o
   500**) y de "rqlited no responde". thermal-guard y Bateria fallan en silencio: en un nodo
   que no es el Wheel, una clave mala se ve como datos viejos de ese nodo (`dt_mal`, a los
   20 min). Si un nodo da a la vez 401 y sin líder, el Latido solo dice 401.

5. **sentinel019 y sentinel017 van a mano**: 019 pasa mucho tiempo fuera de casa (LTE) y 017
   tiene el Termux de Google Play, que tras un reinicio no vuelve a arrancar solo. 019 aplica
   la Ronda 2 en el próximo `sv up` de Sentinel-Roam.sh al volver a casa: nunca hacerle
   `sv restart` fuera de casa. Mientras sigan con el fichero de la Ronda 1, cualquiera que
   llegue a su `:4001` puede, sin clave, consultar con `level=none` (lee su copia local de
   la base, tabla a tabla) y ver `/status` y `/nodes`. Las escrituras y las lecturas
   `weak`/`strong` (`weak` es la de por defecto) se reenvían al líder y dan 401.
   `/db/backup` ya pide clave también en la Ronda 1 (con el primer fichero de la Ronda 1,
   que se lo dejaba a `"*"`, un nodo así daba la base entera por `/db/backup?noleader`; con
   el fichero ajustado da 401, verificado). Por eso no se deja a ninguno en la Ronda 1 más
   de lo imprescindible.

Marcha atrás: copiar otra vez el fichero de la Ronda 1 y reiniciar ese nodo. Desde el
cierre del 2026-11-11 cada nodo lo tiene a mano, sin pasar por la laptop:
`cp -p ~/.config/rqlite/auth.json.ronda1 ~/.config/rqlite/auth.json` y reiniciar rqlited.

## Operaciones a mano con la puerta cerrada

Desde la Ronda 2, todo lo que se haga a mano contra `:4001` lleva
`-K ~/.config/rqlite/admin.curlrc` y va contra un votante: aplicar `esquema.sql`, `/db/load`
(`rqlite/README.md`) y el `/remove` de "Quitarle el voto" (`Nodos/README.md`). El cliente
`rqlite -H` pide la clave en argv (`-u`): mejor no usarlo. Quien gane o pierda el voto
cambia también de fichero `auth.json` (votante o no votante) antes de arrancar: un votante
con el fichero de no votante que saliera líder rechazaría el `INSERT` reenviado de
`respaldo` y las operaciones de `admin`.

## Rotar una clave

rqlited no recarga el fichero y cada usuario tiene una sola clave, así que hacen falta **dos
reinicios rodantes** (mismo orden que arriba):

1. **Abrir**: copiar los ficheros de la Ronda 1 **tal como están** (con las claves actuales) y
   hacer un reinicio rodante. `"*"` vuelve a dejar pasar lo de la Ronda 1 (escribir, leer,
   `/status`, `/readyz` y el join).
2. **Cambiar la clave**: guardar una copia de `claves.tsv`, borrar la línea del usuario
   (`sed -i '/^sentinel\t/d' ~/.config/rqlite/claves.tsv`) y ejecutar `generar-claves.sh`,
   que crea solo esa. Repartir el fichero de ese cliente (`repartir-clientes.sh`, o nada si es
   de la laptop o es `nodo`) y reiniciar el cliente si la lee al arrancar (el chatbot). Con la
   puerta abierta valen igual la clave vieja y la nueva, **salvo para `respaldo`**:
   `/db/backup` no está en `"*"`, así que desde que sentinel020 tiene la clave nueva hasta
   el cierre la copia falla. Hacer los pasos 2 y 3 fuera de la hora de la copia (10:45 UTC),
   o lanzar la copia a mano después.
3. **Cerrar**: copiar los ficheros de la Ronda 2 (ya con la clave nueva) y hacer el segundo
   reinicio rodante. Vigilar los 401 como en la Ronda 2 y borrar la copia de `claves.tsv`.

**Atajo para un usuario que no sea `nodo`** cuando su cliente puede quedarse unos minutos
sin escribir. Basta un solo reinicio rodante, y solo de los nodos cuyo fichero lleva a ese
usuario: el join sigue usando la clave de `nodo`, que no cambia. Así se rotó `indeed` el
2026-11-11, porque su clave salió en el registro de una sesión:
- `claves.tsv` sin su línea y `generar-claves.sh`;
- el fichero de votante nuevo como `auth.json`, y el de la Ronda 1 como `auth.json.ronda1`
  (para que la marcha atrás no resucite la clave vieja), en 014, 016 y 005;
- reinicio de 005 y 016, mando a node7, reinicio de 014 y mando de vuelta;
- el `.env` de RPA Indeed y `pm2 restart rpa-indeed`.

Con un `execute` de `SELECT 1` contra 005, la clave nueva da 200 y la vieja 401.

El orden importa: si la clave nueva entrara en el reinicio de apertura, el primer nodo
reiniciado haría el join (`-join-as nodo`) contra votantes que todavía no la conocen y con
`"*"` cerrado, y moriría a los ~12 s. Abriendo antes con las claves actuales, durante el
cierre cualquier votante sin reiniciar deja pasar el join por `"*"`.

## Lo que la contraseña NO cierra

- **El puerto de Raft (`:4002`) no tiene autenticación.** Quien llegue a él habla Raft crudo
  y pide `GET_NODE_META`. Peor: en versiones anteriores a **10.6.4** la petición
  `BACKUP_STREAM` manda la base **completa** aunque falle la autenticación
  (GHSA-f4f3-px5g-gm4x), y con una petición nula hace `panic` y tumba el nodo. La flota está
  en 10.2.5 (Termux) y 10.2.7 (014 y 016). Lo arregla subir de versión y limitar quién llega
  al `:4002`, no la contraseña.
- **Las credenciales viajan en claro.** Basic auth por HTTP sin TLS en la WiFi, y las que un
  seguidor reenvía al líder van por el `:4002`, también sin TLS. Cualquier equipo de la red
  que escuche el tráfico puede leerlas.
- **La malla WireGuard llega a sentinel014**, a su `:4001` y a su `:4002`: lo que esté en la
  malla tiene el mismo acceso que la LAN.
- **IPv6**: 014 y 016 también escuchan en su IPv6 global. Que eso sea alcanzable desde
  internet depende de que el router filtre la entrada IPv6, y no está comprobado.
- `/readyz` sigue abierto sin clave, a propósito.

## NUNCA `SIGHUP` a rqlited

rqlited no recarga nada con `SIGHUP`: **lo mata**. Nada de `kill -HUP`, `sv hup rqlited` ni
`pkill -HUP`. Para aplicar un fichero nuevo se reinicia (`sv restart rqlited` /
`systemctl --user restart rqlited`), de uno en uno, como arriba.
