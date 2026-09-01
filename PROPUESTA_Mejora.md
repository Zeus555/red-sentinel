# Propuesta de mejora — Sentinel v2

Rediseño del agente PRC_Sentinel manteniéndolo en **awk puro** (multiplataforma,
rápido, liviano). Objetivos fijados por el dueño:

1. Seguir en awk, corriendo en Windows / Ubuntu / Raspbian / Termux / TinyCore.
2. Cada nodo es un servidor web que se **busca y conecta** con los demás.
3. Ejecutar **tareas en paralelo sin depender de multipuerto** (hoy usa 20 puertos).
4. Integrar **HTTPS con openssl**, autoinstalándolo según el SO si falta.
5. Limitar el `cmd` a operaciones básicas (lista blanca) — el hallazgo crítico de
   la auditoría previa (RCE-1/2/3 sin autenticación).

## Dos verdades técnicas que condicionan el diseño

- **gawk no habla TLS nativo.** Su red `/inet4/tcp/...` es texto plano. "HTTPS con
  openssl" = openssl **delante** (terminador TLS en loopback) para lo entrante, y
  `curl` / `openssl s_client` para lo saliente entre nodos. No es obstáculo, es
  dónde se pone el cifrado.
- **gawk es monohilo y bloqueante.** Un proceso con un socket atiende de a una
  conexión. Por eso hoy hay 20 puertos. Para paralelismo con **un solo puerto** se
  separa *aceptar* de *ejecutar*: el puerto único acepta y **despacha trabajadores
  desprendidos** (procesos que NO escuchan puertos) y responde al instante.

## Decisiones tomadas

| Tema | Decisión |
|---|---|
| Terminador TLS entrante | **stunnel** (robusto, multi-conexión) delante del aceptador en loopback; `openssl s_server -naccept 1` como fallback. openssl genera la CA privada + certs y cifra el tráfico **entre nodos** vía curl (mTLS = cifrado + identidad). |
| Estado (registro + jobs) | **Híbrido**: cola/resultados de tareas **siempre en local** (ficheros + `Hot.db`), así cualquier nodo ejecuta aunque no esté en rqlite. Descubrimiento consulta **rqlite** si el nodo pertenece al clúster, con **gossip** (`/peers`) y **barrido de red** como respaldo. |

## Eje de decisión: shell, no OS

Aprendizaje de la implementación: la sintaxis de spawn/redirección no depende del
OS sino de **qué shell usa `gawk system()`**. Un Windows bajo git-bash usa `sh`; un
`.bat` bajo cmd.exe usa `cmd`. v2 detecta el shell en runtime (`DetectShell()`,
probando `echo p=$0`) y elige: `posix` → `gawk ... &`; `cmd` → `start "" /B gawk`.
Las plantillas de comando se seleccionan igual (`nix`/`win`). El OS se conserva
solo para telemetría/visualización.

## Fases

| Fase | Qué | Estado |
|---|---|---|
| **F0** | Banco de pruebas en loopback (`Sentinel-Selftest.sh`) | **Hecho y verde (19/19)** |
| **F1** | Un solo puerto + workers en paralelo (reemplaza los 20 puertos) | **Hecho y verificado** |
| **F2** | Lista blanca + saneo de entrada; portar los surfaces de inyección al modelo v2 | **Hecho y verificado adversarialmente** |
| **F3** | HTTPS/mTLS con openssl + autoinstalación por SO | **Verificado end-to-end en un nodo Termux real** |
| **F4** | Descubrimiento v2 (barrido paralelo, generaliza máscara, rqlite + gossip) | **Hecho y medido (18 s → 3 s)** |
| **F5** | Despliegue en la flota + observabilidad | Pendiente |

## F1 — Modelo implementado

Se elimina toda la maquinaria `GetClone` / `enableclone` / `Redirect to port NNNN`
y el rango 8081-8100. Un único proceso escucha en **un puerto**:

- Peticiones rápidas (`/version`, `/health`, `/peers`) → se responden en línea.
- `POST /task?action=<a>&param=<n>` → valida contra la lista blanca, **despacha un
  worker desprendido** y responde `202 {job:ID}` sin bloquearse.
- El worker ejecuta la acción fija, escribe el resultado en el spool
  (`Datos/jobs/<id>.status`) y avisa con `GET /done/<id>` (callback loopback) para
  liberar cupo. **No escucha ningún puerto.**
- `GET /job/<id>` → estado + resultado. Semáforo `MaxJobs` con cola FIFO: si se
  llena el cupo, la tarea espera y un worker que termina arranca la siguiente.

Guardas: `READ_TIMEOUT` en el aceptador (cliente lento no atasca la puerta) y
`param` estrictamente tipado (entero) — ningún byte del cliente llega al shell.

### F2 — Seguridad: eliminados los surfaces de inyección

La lista blanca vive en **`Sentinel-Allow.conf`** (config, no código): añadir una
acción son dos líneas (`nix` + `win`), no se toca el `.awk`. Cada acción mapea a un
comando **fijo**; el cliente solo manda el **nombre** (validado `^[a-z][a-z0-9_-]{1,32}$`)
y, si aplica, un parámetro **tipado**: `none` | `num` (entero) | `ip` (validado por
octetos ≤255). El worker **re-valida** contra su propia lista blanca y el tipo del
parámetro (defensa en profundidad).

Los surfaces de la auditoría quedan portados al modelo v2, ninguno concatena bytes
del cliente:

- **RCE-1** (`CMD:` de shell libre): eliminado. No existe ejecución de comandos
  arbitrarios; solo acciones de la lista blanca. La blacklist `del|delete|rm|remove`
  del v1 deja de existir por construcción (no hay qué filtrar).
- **RCE-2/3** (`/addprice`, `/addproducts`): ahora son acciones `addprice` /
  `addproducts` con parámetro tipo **`ip`**. La IP se valida por octetos antes de
  tocar el script `ADD_Price_UP` / `ADD_Products_UP`.
- **SQLI-1** (`/addeye`, `/monitorprice/addoperation`): ahora `POST /ingest/eye` y
  `/ingest/operation`. Campos tipados (IP, entero, decimal) y cadenas escapadas con
  **`SqlEsc`** (duplica `'`, elimina todo carácter de control → sin breakout de
  literal ni dot-commands de `.read`). Los campos numéricos se validan como tales
  antes de ir sin comillas.

**Guarda extra:** todos los validadores rechazan cualquier carácter de control
(`[[:cntrl:]]`), lo que independiza el resultado de si el motor gawk del nodo casa
`$` antes de un salto de línea final (semántica que varía entre versiones).

Verificado con inyecciones reales en el banco de pruebas: `1.2.3.4;whoami`,
`999.1.1.1`, `10.20.30.40%0awhoami` → **400**; `Ev'il); DROP TABLE dwd_wheels;--`
→ guardado como dato literal, la tabla **sobrevive**; `idtrade=1); DROP...` → **400**.

**Endpoints de solo lectura de Monitor Price** (`/monitorprice/tradeopen`,
`tradecreated/<id>`, `movetpsl/<id>`) NO se portaron aún: ya eran numeric-safe en el
v1 (idtrade validado `[0-9]+`), son de solo lectura y sin riesgo de inyección. Se
portan cuando el consumidor de Monitor Price migre a v2 (parte de F5).

## Revisión de seguridad del propio v2 (2026-08-13)

Antes de añadir TLS se auditó el diseño v2 **contra sí mismo**. La inyección de
comando y de SQL resistió (ver arriba), pero aparecieron **6 fallos propios**, todos
corregidos y con prueba de regresión. Dos se demostraron explotando el servidor real,
no razonando sobre el código:

| # | Fallo | Efecto demostrado | Corrección |
|---|---|---|---|
| 1 | `/done/<id>` no comprobaba nada | 5 llamadas con ids **inventados** bajaron el contador de 2→0; luego corrían **4 workers reales diciendo 2** → bomba de forks en bucle | Solo libera cupo si el id está vivo (`Running[]`) **y** el token coincide |
| 2 | `/stop` sin autenticar | Cualquier vecino de LAN apaga el nodo con un GET | Exige token; **sin token configurado la ruta no existe** (404) |
| 3 | Cola sin tope | `Pending` crecía sin límite → agotar memoria | `MaxQueue` (64 por defecto) → **429** |
| 4 | Cupo no se recuperaba si el worker moría | Pérdida **permanente** de capacidad — el mismo fallo que el `tClone` del v1 (Android mata procesos: *phantom process killer*) | **Reaper**: expira jobs pasados `JobTTL` (300 s) y devuelve el cupo |
| 5 | Rutas de estado servibles por GET | Una web maliciosa dispara acciones en la LAN con `<img src="http://nodo:8181/task?...">` | `/task` y `/ingest/*` exigen **POST** (405 si no) |
| 6 | Spool sin purgar | `.status`/`.sql` acumulándose → llenar disco (crítico en teléfonos) | Purga por edad (`SpoolTTL`, 1 día) en el reaper |

Endurecimiento adicional: tope de cabeceras (100) y de longitud de línea (8 KB) por
petición; `EscAmp` en el worker porque en `gsub` el `&` del texto de reemplazo
significa «lo que casó» y corrompía el comando si la ruta contenía `&` (verificado).

**Por qué token y no filtro por IP de origen:** se comprobó que **gawk no expone la
dirección del peer** en `/inet`, así que no hay forma de restringir por origen dentro
del script. El token es la medida puente hasta el mTLS de F3, que lo sustituye por
identidad real de certificado.

**Gotcha operativo descubierto:** `pkill -f 'Sentinel-Worker'` **mata al aceptador**,
porque su línea de comando incluye `-v worker=...Sentinel-Worker.awk`. Para matar
solo workers hay que filtrar por `-v job=`. Es el mismo tipo de trampa que el README
de `Nodos\` ya documenta sobre `pkill -f`.

## F3 — HTTPS/mTLS con openssl

**`openssl s_server` NO puede ser el terminador.** Probado el 2026-08-13: con
`-Verify 1`, un cliente que presenta un certificado de **otra CA** recibió la
respuesta HTTP completa; el servidor registró `verify error: unable to get local
issuer certificate` y **sirvió igual**. Ocurre en TLS 1.3 y también forzando
TLS 1.2. Es una herramienta de pruebas, no una pasarela. De haberlo usado como
respaldo, el mTLS habría sido decorativo. Por eso `Sentinel-TLS.sh` **prefiere
fallar** a arrancar sin stunnel.

**Arquitectura:**

```
cliente --mTLS--> stunnel :8443 --claro--> gawk 127.0.0.1:8181 (exige token)
```

- **PKI (`Sentinel-PKI.sh`)**: CA privada Sentinel + certificado por nodo y por
  cliente. Da cifrado **e identidad**. Idempotente (regenerar la CA invalidaría
  toda la flota). `ca.key` nunca sale del Wheel; a los nodos solo viaja `ca.pem`.
  - **Gotcha resuelto:** sin `-extensions ca_ext` la CA se emite **sin**
    `basicConstraints CA:TRUE` y ninguna verificación de cadena la acepta; el
    fallo solo se vería en el primer handshake. El script lo valida al crearla.
- **Terminador (`Sentinel-TLS.sh`)**: stunnel con `requireCert`+`verifyChain`,
  autoinstalando openssl/stunnel según el SO (Termux/Ubuntu/Raspbian/TinyCore/
  Windows).
- **Token en el backend**: imprescindible, no opcional. **gawk solo sabe atar
  `0.0.0.0`** — su sintaxis `/inet4/tcp/PUERTO/0/0` no tiene campo de dirección
  local (verificado con `netstat`). El puerto en claro es alcanzable desde la LAN
  y **cualquiera puede saltarse el terminador**, así que el mTLS por sí solo no
  protegería nada. Exigen token: `/task`, `/ingest/*`, `/job`, `/done`, `/stop`.
  Abiertos a propósito: `/version` y `/health`, que el descubrimiento de F4 sondea.

**Gotcha de despliegue (Windows):** el `curl` del sistema usa **Schannel**, que no
acepta certificados de cliente en PEM (falla con rc=58/60). En el Wheel hay que
convertir a PKCS#12 (`openssl pkcs12 -export`) y usar el almacén de Windows, o
instalar un curl compilado con OpenSSL. Entre nodos POSIX no aplica.

### Verificación end-to-end en sentinel017 (Termux/Android aarch64, 2026-08-13)

Probado en un nodo real, no en laboratorio. El nodo **no tenía openssl CLI ni
stunnel**: los scripts los instalaron solos (`openssl-tool` y `stunnel 5.78`),
que era justo el camino que había que validar.

| Prueba a través de `https://sentinel017:18443` | Resultado |
|---|---|
| Cliente con certificado de la CA Sentinel | `{"version":"Sentinel 2.0.0","os":"Termux"}` ✅ |
| Cliente **sin** certificado | rc=35, sin datos — **rechazado** |
| Cliente con certificado de **otra CA** | rc=35, sin datos — **rechazado** |
| HTTP en claro contra el puerto TLS | rc=56 — rechazado |
| Tarea real por el túnel (`POST /task` → `/job`) | `status:done, rc:0, result:"localhost"` ✅ |
| Por el túnel pero **sin token** | **401** (segunda capa) |
| **Saltándose el TLS**, al backend en claro desde la LAN | **401** (el token protege el hueco del `0.0.0.0`) |

El tercer caso es exactamente donde `openssl s_server` sí servía el contenido:
stunnel lo rechaza. La decisión de exigir stunnel queda validada en la práctica.

**Detalle de Termux:** el paquete `openssl` (librería) puede estar instalado y aun
así no haber binario CLI — lo trae **`openssl-tool`**, que es lo que instala el
script.

**Estado del nodo tras la prueba:** procesos parados, `~/_v2test` borrado, puertos
18181/18443 cerrados, `rqlited` intacto (mismo PID, sin reiniciar) y node8 sigue
`Follower` en el clúster. **Quedan instalados `openssl-tool` y `stunnel`**, que
harán falta en F5; se quitan con `pkg uninstall stunnel openssl-tool` si se quiere.

**Gotcha reaprendido a base de tropezar (3 veces):** `pkill -f <patrón>` y
`pgrep -f <patrón>` **coinciden con el propio comando que los ejecuta**, porque el
patrón aparece literal en su línea de comando — mata la sesión SSH. El truco del
corchete (`[S]erver2`) solo funciona si la cadena **no aparece en ninguna otra
parte** del mismo comando. Mejor: obtener PIDs y matar por PID.

**Aviso sobre el diagnóstico en Android:** `pgrep`/`ps` **no ven los procesos de
otras sesiones**, así que dieron `rqlited: CAIDO` estando perfectamente vivo. Para
saber el estado real hay que usar `sv status <servicio>` (runit), nunca `pgrep`.
Lo mismo con `netstat`: no lista los listeners porque Android no deja leer
`/proc/net/tcp` — comprobar el puerto conectándose a él, no mirando la tabla.

## F4 — Descubrimiento v2

`Sentinel-Discover.awk` sustituye al barrido del v1, que era **secuencial** (0,5 s
por host → ~127 s en un /24) y **solo funcionaba con máscara 255.255.255.0**.

**Tres fuentes que se fusionan**, ninguna obligatoria (el modelo híbrido elegido):

1. **rqlite** (`-v rqlite=URL`) — consulta el registro del clúster.
2. **gossip** (`-v gossip=IP,IP`) — pide `/peers` a vecinos conocidos.
3. **barrido de red** — arranque en frío y autocuración.

Un nodo fuera del clúster (Wheel Windows, TinyCore) sigue descubriendo por gossip
o barrido: nunca queda ciego por no pertenecer a rqlite.

**Mejoras medidas:**

| | v1 | v2 |
|---|---|---|
| 30 hosts muertos | **18 s** | **3 s** (6× más rápido) |
| Máscaras | solo /24 | cualquiera: /23 → 510 hosts, /30 → 2, /16, /31, /32 |
| Máscara no contigua | no detectada | rechazada |
| Rango enorme | — | **avisa** del truncado, nunca en silencio |

El barrido lanza `batch` sondas (32 por defecto) en segundo plano contra un spool y
después cosecha, en vez de esperar host por host. El Wheel se identifica igual que
en v1, por la cadena `Sentinel Super` de `/version`.

**`/peers`** publica lo descubierto (`peers.tsv`) en JSON: es lo que hace posible el
gossip. Junto con `/version` son las dos únicas rutas sin token, precisamente
porque son las que usan los nodos para encontrarse.

**Modo `-v dryrun=1`**: calcula el rango y lo imprime **sin enviar una sola sonda**.
Sirve para comprobar qué se va a barrer antes de tocar la red.

## Ficheros v2

Ubicación (staging, no desplegado): `Wheel/Script/v2/` y espejo en
`Nodos/prc_sentinel/Script/v2/`. Wheel vs Nodo ya **no divergen en el código** —
la diferencia es el flag de arranque `-v role=Super`.

| Fichero | Rol |
|---|---|
| `Sentinel-Server2.awk` | Aceptador de un solo puerto + despacho + cola FIFO + ingesta SQL escapada |
| `Sentinel-Worker.awk` | Worker desprendido (ejecuta 1 acción, reporta, muere) |
| `Sentinel-Allow.conf` | Lista blanca de acciones (config compartida) |
| `Sentinel-PKI.sh` | CA privada + certificados de nodo/cliente (openssl) |
| `Sentinel-TLS.sh` | Terminador mTLS con stunnel + autoinstalación por SO |
| `Sentinel-Discover.awk` | Descubrimiento: rqlite + gossip + barrido paralelo |
| `Sentinel-Selftest.sh` | Banco de pruebas F0-F4, 47 casos (solo en Wheel) |

### Cómo probar

```bash
cd "D:/RED Sentinel/Wheel/Script/v2" && bash Sentinel-Selftest.sh
```

Resultado esperado: `47 PASS / 0 FAIL`. T7: 3×`sleep 2` en paralelo terminan en ~2 s
(en serie ~6 s) — paralelismo real sobre un solo puerto. T10-T16: inyección de
comando y SQL. T17-T21: método exigido, token de `/stop`, `/done` falsificado, tope
de cola y recuperación de cupo por el reaper. T22-T23: token en el backend y PKI.
T24-T28: aritmética de red en varias máscaras, barrido, identificación del Wheel,
`/peers` y gossip.

**Falta por verificar (necesita stunnel instalado):** el camino completo
`cliente mTLS → stunnel → backend`. En un nodo con stunnel:

```bash
./Sentinel-PKI.sh ca && ./Sentinel-PKI.sh node <nombre> <ip> && ./Sentinel-PKI.sh client fleet
./Sentinel-TLS.sh <nombre> 8443 8181 &
curl --cacert Certs/ca.pem --cert Certs/fleet.pem --key Certs/fleet.key https://<nombre>:8443/version   # debe responder
curl --cacert Certs/ca.pem https://<nombre>:8443/version                                                # sin cert: debe FALLAR
```

### Parámetros de arranque nuevos

`-v token=<secreto>` (exigido por `/stop` y `/done`), `-v maxqueue=64`,
`-v jobttl=300` (segundos antes de dar un job por muerto), `-v spoolttl=86400`.

## Pendiente / próximos pasos

- **F3:** generación de CA/certs con openssl, terminador stunnel en loopback,
  autoinstalación por SO, curl mTLS entre nodos.
- **F4:** `Sentinel-Search` v2 con barrido paralelo por lotes, cálculo de rango por
  máscara, registro/consulta rqlite + gossip `/peers`, barrido como respaldo.
- **Refinamiento:** el sondeo `GET /job` genera muchas conexiones cortas
  (TIME_WAIT); evaluar long-poll para reducirlas.
- **F5:** unidades runit/systemd/tarea programada para el modelo de un proceso, y
  rollout nodo por nodo reactivando el crontab (hoy comentado) tras validar.

## Nota de seguridad operativa

El servicio v1 sigue **dormido** en toda la flota (crontab comentado, tareas
borradas). v2 es staging local, no desplegado. Endurecer (F2/F3) **antes** de
reactivar con rqlite.
