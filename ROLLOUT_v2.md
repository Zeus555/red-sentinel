# Despliegue de Sentinel v2 en la flota (Fase 5)

Plan para llevar el v2 a los dispositivos.

> **Estado 2026-08-14: DESPLIEGUE COMPLETO — 12 de 12 equipos con v2.**
> `sentinel001`, `002`, `003`, `005`, `009`, `010`, `017`, `018`, `019`
> (Termux/runit), `sentinel014`, `016` (Ubuntu/systemd) y `sentinel013`
> (Windows, tarea programada). Clúster 11/11 y telemetría 11 activos, intactos.
> **El Wheel ya no se configura: lo elige la red.** Ahora mismo, `sentinel014`.

## Correcciones aplicadas antes de desplegar

Una revisión de riesgos operativos (58 agentes, 53 riesgos, 42 confirmados o
plausibles) encontró cosas que había que arreglar **antes** de tocar un
dispositivo. Las bloqueantes, corregidas:

| Riesgo | Corrección |
|---|---|
| **runit anula la protección térmica**: thermal-guard mata la carga a 50 °C y el supervisor la resucita al instante, dejando el teléfono caliente | El propio servicio lee la temperatura antes de arrancar (misma fuente y umbral que thermal-guard, `CRIT` de su `.conf`) y **se aparta 120 s** si hace calor. Sin tocar thermal-guard, que es código en producción |
| **stunnel sin supervisar**: se lanzaba a mano y no sobrevivía a un reinicio → el nodo volvía sin mTLS sin que nadie lo notara | Servicio runit propio `sentinel-v2-tls` |
| **Puerto incoherente** 8081 (config) vs 8181 (terminador) | Unificado en **8181**, deliberadamente **fuera del rango del v1** (8081-8100): aunque alguien reactivara el watchdog del v1, nunca competirían por un socket |
| **Bucle de reinicio** sin freno si falla el arranque | `sleep 2` de suelo, y esperas largas ante error de configuración |
| **Arrancaba con `TOKEN=CAMBIAME`** dejando el backend abierto | Fail-fast: sin token configurado no arranca |
| **Spool huérfano tras reinicio**: el reaper solo purga lo que registró en memoria | Purga por antigüedad al arrancar |
| **`MemoryMax=128M`** en systemd limitaba el cgroup entero (aceptador + workers + sqlite) | Retirado, con el motivo escrito en la unidad |
| **Sin comprobación previa de puerto** | El instalador verifica que el puerto responde libre y aborta si no |

## Principios

1. **El v1 no se borra.** El v2 se instala en `~/PRC_Sentinel/v2/`, al lado. La
   vuelta atrás es parar el v2, no restaurar nada.
2. **Instalar y arrancar son dos pasos distintos.** El instalador deja el servicio
   *definido pero parado* (fichero `down` en runit; sin `enable` en systemd). Así
   un despliegue no se convierte en un arranque accidental en 11 equipos.
3. **`--dry-run` es el modo por defecto** del instalador. Hay que escribir `--apply`
   a propósito.
4. **Un nodo cada vez, verificando antes de seguir.** Sin despliegues en paralelo.
5. **El clúster rqlite no se toca.** Ningún paso reinicia `rqlited`, ni cambia su
   configuración, ni ocupa sus puertos (4001/4002).

## Estado comprobado de la flota (2026-08-13)

Verificado en vivo, no supuesto:

| Comprobación | Resultado |
|---|---|
| Puerto **8081 libre** | sí en los 9 nodos alcanzables |
| Crontab del v1 activo | **0** en todos (sigue comentado) |
| `gawk` presente | sí en todos |
| Disco libre | de 5,0 GB (sentinel001) a 37,5 GB |
| `sentinel018` | accesible, pero **nunca tuvo PRC_Sentinel** → alta nueva |
| `sentinel019` | **no responde** (Pixel personal, fuera de la WiFi) |

## Orden de despliegue

De menos a más consecuencias si algo sale mal:

| Ola | Nodos | Por qué en este puesto |
|---|---|---|
| **0 — canario** | `sentinel017` | Sin servicios de producción (solo rqlite + thermal). Ya tiene stunnel y openssl-tool de la prueba de F3. Se deja **48 h** antes de seguir. |
| **1** | `sentinel003`, `sentinel009`, `sentinel010` | Solo rqlite + thermal. Fire HD las dos últimas: buen test de hardware modesto. |
| **2** | `sentinel002` | Igual que la ola 1, pero además tiene el pipeline de Kraken parado. |
| **3** | `sentinel014`, `sentinel016` | Ubuntu: valida la ruta systemd. **014 corre el RPA Extron** (timer 2×/día + dashboard :3008) y **016 el agente Jupiter** en Docker. |
| **4** | `sentinel001`, `sentinel005` | Los que corren **WhatsApp** (:8002) y el chatbot. Los últimos por ser los más delicados. |
| **5** | `sentinel013` (Wheel) | La laptop. Rol `Super`. Arranque manual, sin tarea programada al principio. |
| **aparte** | `sentinel018` | Alta nueva (nunca tuvo el agente). |
| **aparte** | `sentinel019` | Cuando vuelva a la WiFi. |

## Procedimiento por nodo

```bash
# 1) Desde el Wheel: emitir el certificado del nodo (la ca.key NUNCA sale de aquí)
./Sentinel-PKI.sh node <nodo> <ip>

# 2) Copiar código y credenciales
scp -r Sentinel-*.awk Sentinel-*.conf Sentinel-*.sh service <nodo>:~/_v2stage/
scp Certs/ca.pem Certs/<nodo>.pem Certs/<nodo>.key <nodo>:~/PRC_Sentinel/v2/Certs/

# 3) Ver qué haría, sin escribir nada
ssh <nodo> 'cd ~/_v2stage && sh Sentinel-Install.sh <nodo>'

# 4) Aplicar (deja el servicio PARADO)
ssh <nodo> 'cd ~/_v2stage && sh Sentinel-Install.sh <nodo> --apply'

# 5) Arrancar, que es un paso aparte y consciente
ssh <nodo> 'rm $PREFIX/var/service/sentinel-v2/down && sv up sentinel-v2'   # Termux
ssh <nodo> 'systemctl --user enable --now sentinel-v2'                       # Ubuntu
```

### Verificación obligatoria antes de pasar al siguiente nodo

```bash
ssh <nodo> '
  sv status sentinel-v2                      # o systemctl --user status
  curl -s http://127.0.0.1:8081/version      # debe responder Sentinel 2.0.0
  curl -s http://127.0.0.1:8081/health       # inflight/queued coherentes
  sv status rqlited                          # EL CLÚSTER SIGUE BIEN
'
curl -s "http://<ip>:4001/status?pretty" | grep -E "node_id|state"   # sigue en el clúster
```

**Ojo con el diagnóstico en Android** (ver memoria de gotchas): `pgrep` no ve
procesos de otras sesiones y `netstat` no lista listeners. Usar **`sv status`** y
**conectarse al puerto**, nunca `pgrep`/`netstat`, o se diagnostican caídas que no
existen.

## Vuelta atrás

Por nodo, en segundos y sin restaurar nada:

```bash
# Termux
ssh <nodo> 'sv down sentinel-v2 && touch $PREFIX/var/service/sentinel-v2/down'
# Ubuntu
ssh <nodo> 'systemctl --user disable --now sentinel-v2'
```

El v1 sigue intacto en `~/PRC_Sentinel/`; para volver a él basta descomentar su
crontab. Desinstalación completa (si se quisiera borrar el rastro):

```bash
ssh <nodo> 'rm -rf ~/PRC_Sentinel/v2 $PREFIX/var/service/sentinel-v2 $PREFIX/var/log/sv/sentinel-v2'
ssh <nodo> 'pkg uninstall stunnel openssl-tool'   # solo si no se quiere dejar TLS
```

Lo único que no se deshace solo son los **paquetes instalados** (`stunnel`,
`openssl-tool`) y los **certificados emitidos**. Ninguno de los dos estorba.

## Criterios de parada

Abortar el despliegue y revertir el nodo si aparece cualquiera de estos:

- `rqlited` se cae, se reinicia, o el nodo sale del clúster.
- La telemetría del nodo deja de llegar (`v_sentinel_estado` lo marca inactivo).
- La temperatura sube y thermal-guard cruza WARN (45 °C) de forma sostenida.
- El load average sube de forma persistente por encima de lo normal del nodo.
- Un servicio de producción del nodo (WhatsApp, RPA Extron, Jupiter) falla.

## Después del despliegue

- **Descubrimiento**: correr `Sentinel-Discover.awk` desde el Wheel y comprobar que
  encuentra los nodos ya migrados y los marca con su rol.
- **El crontab del v1 se queda comentado.** No se reactiva: el v2 lo sustituye y
  ya está supervisado por runit/systemd (no necesita el watchdog por cron que
  tenía el v1, porque no hay 20 procesos que vigilar).
- **Tareas programadas del Wheel**: recrear `PRC Sentinel` sólo cuando el Wheel
  esté validado a mano. Recordar que la tarea `PRC UserAgent` sigue apuntando a
  una ruta que ya no existe (pendiente del README principal).

## Canario: sentinel017 (2026-08-13)

Desplegado y verificado. Puerto **8181** (backend) y **8443** (mTLS).

| Verificación | Resultado |
|---|---|
| Servicio bajo runit | `run: sentinel-v2: (pid 15068)` |
| `/version` y `/health` | `Sentinel 2.0.0`, contadores a cero |
| mTLS **con** certificado | responde ✅ |
| mTLS **sin** certificado | rechazado (rc=35) |
| Tarea real por el túnel | `status:done rc:0 result:"localhost"` |
| Backend en claro sin token | **401** |
| Puerto 8081 del v1 | libre (v1 sigue dormido) |
| Procesos gawk en reposo | **1** (solo el aceptador) |
| Token de flota: sin él | **401** — un agente ajeno no entra |
| Token de flota: 3 fallos | bloqueo **429** con `Retry-After` |
| Durante el bloqueo, token válido | **200** — los legítimos no quedan fuera |
| `rqlited` | mismo PID que antes del despliegue, sin reiniciar |
| Clúster | **11/11 alcanzables**, node8 `Follower` |
| Telemetría del nodo | `activo=1, 35 °C (OK)`, lectura al minuto |

La CA vive en **`C:\Users\ariel\.sentinel\Certs`**, fuera de `D:\`, siguiendo la
decisión de la Fase 1 de no guardar secretos en el disco de proyectos. Al nodo
sólo viajaron `ca.pem` y su par de certificado: **`ca.key` no sale del Wheel**.

## Token de flota: la credencial de pertenencia a la red

**Decidido y aplicado el 2026-08-13.** Hay **un solo token para toda la red**, y es
lo que decide quién pertenece a ella: un agente Sentinel instalado en la LAN que no
lo tenga **no obtiene absolutamente nada**, ni siquiera la versión, así que no puede
descubrir la red ni unirse a ella.

- **Todas las rutas** lo exigen, incluidas `/version` y `/peers`. Antes estaban
  abiertas para el descubrimiento; ahora el descubridor presenta el token, cosa que
  sólo es posible porque el token es común a la flota.
- **Cualquier nodo puede crearlo** (`Sentinel-Token.sh create`): el primero que
  levanta la red lo genera y los demás lo importan (`import <token>`). No hay
  servidor de tokens.
- Vive en `fleet.token` (600), **aparte de `sentinel.conf`**, para que repartirlo o
  rotarlo sea copiar un único fichero. `rotate` conserva el anterior.
- `import` rechaza tokens débiles (exige hexadecimal de 32 a 128 caracteres).

### Bloqueo tras 3 fallos

Tres comprobaciones fallidas → **30 s de castigo**, con `429` y cabecera
`Retry-After`. Un detalle de diseño que conviene entender:

> gawk **no expone la IP del peer**, así que el bloqueo no puede ser por origen:
> es global. Si el castigo cerrara la puerta a todos, cualquiera podría dejar la
> red fuera de servicio simplemente fallando el token a propósito. Por eso
> **durante el castigo un token válido sigue pasando**: lo que se frena es el
> intento a ciegas, no el trabajo legítimo.

`/health` informa de `auth_fallidos` y `bloqueado` para poder vigilarlo.

## Ola 1: sentinel003, sentinel009, sentinel010 (2026-08-13)

Desplegada nodo a nodo. Los tres verificados: `Sentinel 2.0.0` en 8181, mTLS en
8443 (con certificado responde, sin certificado rechaza), tarea real por el túnel
en estado `done`, sin token **401**, y **1 solo proceso gawk** en reposo.

| Nodo | Temp | Load | rqlited |
|---|---|---|---|
| sentinel017 | 37 °C | 0,73 | intacto |
| sentinel003 | 40 °C | 28,9 | intacto |
| sentinel009 | 34 °C | 6,45 | intacto |
| sentinel010 | 33 °C | 6,33 | intacto |

Clúster **11/11 alcanzables**, los cuatro nodos `activo=1` en la telemetría.

> El load de **sentinel003 ya era ~29 antes** de instalar (las medias de 5 y 15
> min lo confirman): es previo, no lo causó el v2. Aun así conviene vigilarlo.

En las Fire HD (009/010) se puso **`MAXJOBS=2`** por ser el hardware más modesto.

### Tres fallos reales que encontró esta ola

Ninguno se vio en el canario, porque tenía un Termux limpio. Por eso el
despliegue va nodo a nodo:

| Fallo | Corrección |
|---|---|
| **`pkg install` se colgaba en un diálogo de dpkg** (`openssl.cnf` modificado) y abortaba con *"end of file on stdin at conffile prompt"*, sin instalar nada | Instalación no interactiva: `DEBIAN_FRONTEND=noninteractive` + `--force-confold/--force-confdef` |
| **El servicio TLS reintentaba instalar en cada arranque** y runit lo relanzaba sin parar → bucle de `apt-get` que **retenía el lock de dpkg** e impedía instalar hasta a mano (sentinel010) | Los intentos se espacian **1 h** (marca de tiempo), y si falta stunnel el servicio espera **5 min** en vez de reintentar cada 2 s |
| **Índice de paquetes rancio** → pedía `stunnel 5.79`, que ya no está en el espejo (404) | `apt-get update` antes de instalar |
| **La comprobación previa de puerto no funcionaba**: el programa gawk iba entre comillas dobles, el shell expandía `$2` y con `set -u` abortaba; además sólo miraba la cabecera `Server`, que rqlite no envía | Comillas simples y se mira **toda** la cabecera |

## Ola 2: sentinel002 (2026-08-13)

Se usó para validar algo que hasta ahora se había hecho a mano: **dejar que el
servicio instale openssl y stunnel por su cuenta**. Tras dos correcciones, lo
hizo sin intervención. Verificado igual que los anteriores (mTLS con y sin
certificado, tarea real, 401 sin token). Nodo en reposo: 37 °C, load 0,27,
`rqlited` intacto (27 días de uptime).

### Dos fallos más, ambos míos, en el freno de reintentos

| Fallo | Corrección |
|---|---|
| La guarda «si falta stunnel, espera 5 min» estaba **antes** de llamar al script que lo instala, así que **impedía la propia autoinstalación** | La espera se movió *después* del intento: el run script ya no comprueba nada, y `Sentinel-TLS.sh` espera antes de rendirse |
| El freno usaba **una sola marca de tiempo para todos los paquetes**: instalar openssl consumía el intento y **bloqueaba el de stunnel** | Una marca **por paquete** |

## Ola 3a: sentinel016 (Ubuntu 24.04) — 2026-08-13

Primer nodo por **systemd**, y alta nueva (nunca tuvo `PRC_Sentinel`). La unidad
quedó `active`, `NRestarts=0`, responde `os":"Ubuntu"` y la tarea de prueba
devolvió el hostname real. **Nada perturbado**: `rqlited` activo, el contenedor
`prc-agent-jupiter` con 2 semanas de uptime intactas, load 0,06 y **1 solo
proceso gawk**.

### Dos fallos que habrían dejado el nodo abierto

Encontrados **revisando la unidad antes de tocar el nodo**, no en producción:

| Fallo | Corrección |
|---|---|
| La unidad systemd leía `TOKEN` de `sentinel.conf` con `EnvironmentFile`, pero el token de flota vive en `fleet.token` — que sólo leía el script de runit. **En Ubuntu el servicio habría arrancado con token vacío, o sea el nodo ABIERTO a toda la LAN** | Ambas plataformas usan ahora un **lanzador común** (`sentinel-start.sh`) que lee `fleet.token`, aplica el fail-fast y el freno térmico |
| `EnvironmentFile` de systemd **no entiende comentarios en línea**: `ROLE=Nodo  # ...` metía el comentario dentro del valor | Los comentarios de `sentinel.conf` pasan a ir **sobre** la línea |

También faltaba la unidad del terminador TLS para Ubuntu (sólo existía el
servicio runit de Termux): añadida como `sentinel-v2-tls.service`.

Los cinco nodos Termux se migraron al lanzador común y siguen arriba: tener dos
rutas de arranque distintas en la flota era una fuente segura de sorpresas.

**mTLS completado**: `stunnel` se instala con `apt` y exige root; en este nodo
`sudo` pide contraseña, así que lo ejecutó el dueño
(`sudo apt-get install stunnel4 && systemctl --user enable --now sentinel-v2-tls`).
Verificado después: con certificado responde, sin certificado rechaza.

## Ola 3b: sentinel014 (Ubuntu 24.04) — 2026-08-13

**El nodo más delicado de la flota**: corre el RPA Monitor Extron (ciclo 2×/día,
dashboard en 3008) y el túnel Cloudflare que publica dos dominios públicos.
`stunnel4` ya estaba instalado, así que no hizo falta root.

Ambas unidades `active` con **0 reinicios**, backend y mTLS correctos, tarea real
por el túnel devolviendo `sentinel014`.

**Lo que había que no romper, comprobado después del despliegue:**

| | Estado |
|---|---|
| `rqlited` | active |
| `rpa-extron-dashboard` | active |
| `rpa-extron-cycle.timer` | active, próxima ejecución en 2 h |
| `cloudflared` (sistema) | active |
| Dashboard local :3008 | HTTP 401 (Basic Auth, correcto) |
| `https://extron.batchtoday.us` | HTTP 401 — **sigue sirviendo** |
| `https://ampronix.batchtoday.us` | HTTP 401 — **sigue sirviendo** |
| Procesos gawk | 1 |
| Load | 0,06 |

Clúster **11/11 alcanzables**.

## El Wheel se elige solo (2026-08-14)

En el v1 el Wheel era siempre la laptop, fijado a mano: si ese equipo se apagaba,
la red se quedaba sin cabeza. Ahora **lo elige la propia red por aptitud**, y el
relevo no exige reiniciar nada — cada nodo lee el resultado y se anuncia o no
como `Sentinel Super` en `/version`.

**Criterio: gana la DISPONIBILIDAD, no la potencia.** La puntuación (en
`Sentinel-Wheel.awk`, término a término y ajustable):

| Factor | Peso |
|---|---|
| Tiempo en pie | hasta **+84** (se satura a una semana) |
| Equipo siempre encendido, sin batería | **+40** |
| Ser ya el Wheel (histéresis) | **+15** |
| Calor | −2 por grado sobre el umbral |
| Carga del sistema | −5 por punto |
| Ocupación del agente | hasta −20 |
| Cola de tareas | −2 por tarea |
| Lentitud en responder | −1 cada 50 ms |

Descalifican: no ser elegible, calor crítico, o cola saturada.

**La histéresis es deliberada**: sin ese +15, dos nodos parecidos se turnarían el
mando cada pocos minutos. Es preferible un Wheel mediocre estable que un relevo
constante.

**No hay votación ni consenso**: todos puntúan con la misma fórmula sobre los
mismos datos públicos (`/fitness`), así que convergen solos. Los empates se
rompen por nombre. El consenso de verdad ya lo aporta rqlite para los datos.

**`sentinel013` (la laptop) no es elegible** (`WHEEL_ELIGIBLE=no`) y **no lleva
rqlite**: pertenece a la red, pero no la coordina ni guarda su base de datos.

**Verificado en la flota real:**

- Con los 9 nodos en juego gana **sentinel014** (153,8 puntos): Ubuntu siempre
  encendido, 32 °C, carga 0,07.
- **Simulacro de caída**: parado sentinel014, tres nodos re-eligieron **por
  separado y coincidiendo** a `sentinel016`, que asumió el rol sin reiniciarse.
- La laptop quedó excluida en todas las rondas.

### Cuatro fallos que destapó la puesta en marcha

| Fallo | Corrección |
|---|---|
| **Cada nodo se coronaba a sí mismo**: sin lista de vecinos, el único candidato era uno mismo → salieron **tres Super a la vez** | Los candidatos salen del clúster rqlite (`/nodes`), que ya sabe qué nodos existen |
| **El aceptador moría cada 5 minutos**, justo al disparar la elección desde su propio bucle | La elección se desacopla: la lanza **cron** (Termux) o un **timer de systemd** (Ubuntu), como ya hace thermal-guard. `ELECTSECS=0` desactiva el disparo interno |
| **`temp=10035`** en un nodo: el JSON de `termux-battery-status` viene en una línea y al limpiar no-dígitos se pegaban `percentage:100` y `temperature:35` | Se extrae el campo, no se limpia la línea |
| **Un Ubuntu quedaba descalificado a 68 °C**: se le aplicaba el umbral de **batería** (50 °C) de thermal-guard a un sensor de **CPU**, donde 60-70 °C es normal | Umbral por fuente: batería 50 °C, CPU 85 °C, y la fuente viaja en `/fitness` |

## sentinel019 (Pixel 6, móvil personal) — 2026-08-14

Último nodo. Desplegado igual que el resto; openssl y stunnel se instalaron
solos. `MAXJOBS=2` y **`WHEEL_ELIGIBLE=no`**: es el móvil personal y sale de la
WiFi a diario, que es lo contrario de «mayor disponibilidad» — de hecho estuvo
ilocalizable durante todo el despliegue. Su cron de elección va a `*/5`,
conviviendo con el `*/2` que ya tenía thermal-guard.

`rqlited` intacto (mismo PID, 27 h en pie).

### Sentinel SMS estaba caído: restaurado y arreglada la causa

Al desplegar se encontró el **backend de Sentinel SMS parado**: pm2 corría sin
ningún proceso pese a que `~/Sentinel_SMS` y `~/.pm2/dump.pm2` seguían ahí. Con
el permiso del dueño se ejecutó **`pm2 resurrect`** y volvió (`sentinel-sms`
online; `:8010` responde 401, o sea vivo y pidiendo credenciales).

**La causa de fondo, y por qué habría vuelto a caerse en el próximo reinicio:**
el ejecutable `pm2` es un script con shebang `#!/usr/bin/env node`, y **en Termux
no existe `/usr/bin/env`** — solo funciona gracias a `termux-exec` (`LD_PRELOAD`),
que el entorno mínimo del arranque no tiene. Resultado: el `pm2 resurrect` del
boot script **fallaba en silencio** con *not found*. Comprobado reproduciendo el
entorno de arranque con `env -i`.

Arreglado en `~/.termux/boot/00-services.sh` llamando a **node directamente**,
sin depender del shebang:

```sh
/data/data/com.termux/files/usr/bin/node \
  /data/data/com.termux/files/usr/lib/node_modules/pm2/bin/pm2 resurrect
```

Copia previa en `00-services.sh.bak-20260814`, sintaxis validada con `sh -n`, y
la línea nueva probada en un entorno de arranque simulado (ve `sentinel-sms`).
**No hizo falta `pm2 save`**: el volcado ya era correcto; lo que fallaba era
leerlo.

## Un cuelgue que nadie veía: vigilante de salud

`sentinel003` apareció **con el proceso vivo 12 h y sin responder ni en
localhost**. runit y systemd **solo reinician procesos muertos**: un aceptador
colgado se les escapa. El v1 sí lo cubría —su watchdog sondeaba
`/sentinelversion` y mataba clones colgados—, y al pasar a un supervisor esa
red de seguridad se perdió sin que nadie lo notara.

Restaurada como **`watchdog.sh`**, por cron (Termux) y timer de systemd (Ubuntu),
cada 5 min: si el nodo no se contesta a sí mismo **dos veces seguidas**, reinicia
el servicio. Dos intentos y no uno, porque un fallo suelto puede ser un nodo
ocupado, no colgado — `sentinel003` arrastra un load de ~29 previo al despliegue.

## Retirada del v1 (2026-08-14)

El v1 llevaba semanas dormido junto al v2. Retirado de los **9 nodos** que lo
tenían (`sentinel016`, `018` y `019` nunca lo tuvieron):

- Borrados los **scripts**: `Sentinel-Server.awk`, `Sentinel-Client.awk`,
  `Sentinel-Search.awk`, `Sentinel-Clone.awk` y `Sentinel-Clone.sh` (5 por nodo,
  4 en `sentinel010`, que tenía la variante `.bat`).
- **Crontab limpiado de verdad**: las dos líneas de `Sentinel-Clone` —`@reboot` y
  `* * * * *`— estaban *comentadas*, no borradas. Eliminadas en los 6 nodos que
  las tenían, y `crond` reiniciado (no relee en caliente). Ya no puede resucitar
  nadie 19 clones por descuido.
- **Copia de seguridad** en cada nodo: `~/PRC_Sentinel/v1-scripts.bak-20260814.tgz`.
  El código además ya estaba preservado en `Nodos\prc_sentinel\Script\` y en
  `Wheel\Script\`, así que la retirada no pierde nada.

**Lo que se conservó a propósito**, tras comprobar que ningún script de `Run/`
referencia al v1:

| Carpeta | Por qué se queda |
|---|---|
| `Run/` | **La usa el v2** para las acciones `addprice` / `addproducts` |
| `Datos/` | Contiene `Hot.db`: son datos, no código |
| `Log/` | Registros de corridas pasadas: borrarlos sería falsificar historia |
| `v2/` | El agente actual |

Verificado después: **puerto 8081 libre** en toda la flota, v2 intacto y clúster
11/11.

## Nueva acción de rescate: `restart-sshd`

`sentinel019` **perdió sshd** durante estos trabajos: el móvil sigue en la red
(v2, stunnel y rqlite responden, y su telemetría llega), pero **no admite SSH**,
así que no se puede administrar en remoto. Y el agente no podía ayudar: su lista
blanca no tenía ninguna acción capaz de reponer el servicio.

Añadida la acción **`restart-sshd`** (sin parámetros, así que no amplía la
superficie de ataque) y repartida a **los 12 equipos**.

**`sentinel019` volvió solo**: al reintentar, el puerto 8022 estaba abierto de
nuevo sin que nadie tocara el móvil. No hubo que ir a por él.

Al recuperarlo se descubrió algo que **hacía peligrosa la acción tal como estaba
escrita**: `sv status sshd` dice `down` desde hace días **y sin embargo SSH
funciona**, porque en estos nodos **sshd NO lo supervisa runit** — su servicio
lleva fichero `down` y lo arranca directamente el script de arranque, tal como
documenta el README de `Nodos\`. Un `sv restart sshd` o un `pkill` se habría
cargado el sshd que sí funcionaba, dejando el nodo incomunicado justo al intentar
rescatarlo.

Reescrita para ser **idempotente y no destructiva**: solo arranca sshd si no hay
ninguno, y nunca mata nada.

```
restart-sshd|none|nix|pgrep -x sshd >/dev/null 2>&1 && echo "sshd ya estaba arriba" || { sshd && echo "sshd arrancado"; }
```

**Probada en vivo** contra `sentinel019` con sshd funcionando: respondió *"sshd ya
estaba arriba"*, no tocó nada y la sesión SSH siguió intacta.

## Alertas de nodo caído (2026-08-15)

`Sentinel-Alert.sh`, por cron (Termux) y timer de systemd (Ubuntu) cada 5 min en
los 11 nodos. Avisa por **el mismo bot de Telegram que ya usa thermal-guard**
(`~/PRC_Thermal/thermal-guard.conf`), para no abrir un canal nuevo ni duplicar
secretos.

**Quién avisa: solo el Wheel.** Corre en todos los nodos, pero cada uno comprueba
antes si le toca y los demás salen sin hacer nada. Así el aviso **lo hereda solo
el nuevo coordinador** cuando hay relevo, sin configurar nada. Y si cae el propio
Wheel, la siguiente elección (≤5 min) nombra otro, que avisará —incluido el aviso
de que el anterior se cayó.

**Qué avisa: transiciones, no estados.** Solo hay mensaje cuando un nodo pasa de
responder a no responder (y al revés), y cuando cambia el Wheel. Sin eso, un nodo
caído generaría un mensaje cada 5 minutos para siempre. Dos sondeos fallidos
antes de dar por caído, para no avisar por un fallo suelto.

Ejemplo real del mensaje:

```
🔴 Sentinel: nodo sin responder:
  • sentinel018 (192.168.1.211)
Dos sondeos fallidos al puerto 8181. Avisa sentinel016 (Wheel).
```

**Probado de extremo a extremo**: se paró `sentinel018`, llegó el aviso rojo; se
levantó, llegó el verde; y una tercera pasada sin cambios **no envió nada**.

### Dos detalles que costaron una pasada en seco

| | |
|---|---|
| **IPs truncadas**: `sed 's/.*\(IP\).*/\1/'` tiene un `.*` inicial **codicioso** que se comía el primer octeto (`192.168.1.124` → `2.168.1.124`). Ningún nodo respondía y **habría avisado de una caída total falsa** | Cambiado a `grep -oE`. Se descubrió por probar en seco antes de enviar |
| Los mensajes decían la **IP**, no el nombre | Se aprende el nombre de `/fitness` mientras el nodo responde y se guarda: **un nodo caído no puede decir cómo se llama**. El aviso usa el último nombre conocido, con la IP entre paréntesis |

### Quién se vigila y quién no

La lista sale del clúster rqlite, y se ajusta con dos opciones de
`sentinel.conf`. Ambas deben estar en **todos** los nodos, porque cualquiera
puede acabar siendo el Wheel y, por tanto, el que vigila.

| Opción | Para qué |
|---|---|
| `EXTRA_NODES=192.168.1.117` | Añade a **`sentinel013`**: pertenece a la red pero no al clúster, así que no saldría en la lista |
| `SKIP_NODES=192.168.1.210` | Excluye a **`sentinel019`**: es el móvil personal y **se desconecta a diario**. Avisar de cada desconexión sería ruido constante, y un aviso que se ignora deja de ser un aviso |
| `GRACE_NODES=192.168.1.117:1800` | Da a **`sentinel013`** media hora de margen: está siempre en la red pero **se reinicia una vez por semana**, y ese reinicio no es una caída |

**Vigilados (11):** 001, 002, 003, 005, 009, 010, 013, 014, 016, 017, 018.
**Excluido (1):** 019.

Excluir de la vigilancia **no saca a un nodo de la red**: `sentinel019` sigue
exigiendo token, sirviendo por mTLS y participando en todo. Simplemente no se
avisa cuando desaparece, porque se da por normal.

#### La tolerancia: silenciar el reinicio sin silenciar la caída

Excluir la laptop entera habría sido tirar el niño con el agua: **es un nodo que
sí interesa vigilar**, solo que tiene una forma de desaparecer que es legítima.
La tolerancia distingue las dos cosas — **por duración**, que es lo único que las
separa de verdad:

- Deja de responder → **arranca un reloj**, pero se sigue contando como sano.
- Vuelve antes de 30 min → el reloj se borra y **no se manda nada**. Un reinicio
  normal cae aquí, incluido uno con actualizaciones de Windows de por medio.
- Pasa de 30 min → **ahora sí**, aviso con el tiempo transcurrido:
  `• sentinel013 (192.168.1.117) — sin responder desde hace 33 min`.

Sin entrada en `GRACE_NODES` un nodo se declara caído en cuanto falla el sondeo,
que es lo correcto para los que están siempre encendidos.

`alert.state` gana un cuarto campo para el reloj
(`ip|nombre|estado|epoch_primer_fallo`). Los ficheros de tres campos se leen sin
problema: el reloj simplemente empieza en el ciclo siguiente.

### El quórum no bastaba: un sondeo perdido destronaba al Wheel (2026-08-17)

El dueño volvió con una captura de avisos duplicados. Revisando **con datos en
vivo**, resultó que la captura mezclaba dos cosas:

| Lo que se veía | Qué era en realidad |
|---|---|
| Avisos de 18:41 a 20:40 firmados por 4 «Wheels» | El incidente **del 15/08**, ya corregido. Cinco nodos tienen su `alert.state` congelado exactamente en `08-15 20:40`, que es la hora del último mensaje |
| `sentinel013` avisado tras 6 min caído, con 30 min de tolerancia | También del 15/08, a las **04:22 UTC**. Los scripts con la tolerancia llegaron a las **04:52 UTC**, media hora después. La tolerancia no falló: no existía |
| **Que el problema seguía vivo** | **Cierto.** `sentinel002` actuó de Wheel el 17/08 a las 07:05, `sentinel005` el mismo día a las 08:40, `sentinel010` el 16/08 |

**La causa raíz que faltaba.** El quórum de agosto solo salta ante una partición
grande — hay que perder de vista a *más de la mitad* de la flota. Perder a **un**
nodo pasa por debajo del radar; y si ese nodo es justo el Wheel, cualquiera
coronaba a otro al instante. Un teléfono en *doze* o un hipo de WiFi bastaba.

Se comprobó simulando la elección en `sentinel001`, que tenía
`wheel.state=sentinel014`: **viendo a todos los nodos elige `sentinel016` con 195
puntos**, muy por delante. La fórmula estaba bien; lo que fallaba era decidir con
un nodo ausente por un sondeo de 3 s.

**Cuatro correcciones:**

1. **Reintento del sondeo** (`Sentinel-Wheel.awk`): si un nodo no contesta, se
   reintenta una vez con el doble de paciencia. Solo se paga con los que de
   verdad no están.
2. **El Wheel no cae por una ronda** (`MaxMiss=2`): hace falta que falte en dos
   rondas seguidas (~10 min) para relevarlo, con contador en `wheel.state.miss`
   que **se reinicia en cuanto reaparece**, para que los fallos sueltos no se
   acumulen. Coste: un relevo real tarda ~10 min. A cambio, no hay relevos
   fantasma, que era el caso casi siempre.
3. **Callar recién coronado** (`WHEEL_SETTLE=420` en `Sentinel-Alert.sh`): si
   `wheel.state` cambió hace menos de 7 min, no se avisa. `wheel.state` solo se
   reescribe cuando el ganador cambia, así que un Wheel asentado no se ve afectado.
4. **Desempate por aptitud, no por nombre**: el criterio anterior cedía al nodo
   alfabéticamente menor, con lo que **un teléfono (`sentinel001`) desplazaba al
   mini-PC que de verdad es el Wheel** y el aviso lo acababa dando el nodo menos
   fiable. Ahora se cede al de mayor aptitud (estable, luego uptime), igual que
   la elección.

**Dos guardas más que salieron de la misma revisión:**

- **Foto de estado caducada**: un nodo que no ha sido Wheel en dos días guarda el
  retrato de una red que ya no existe; al tomar el relevo dispararía caídas y
  recuperaciones falsas. Pasados 30 min se descartan los estados **conservando
  los nombres aprendidos** (lo único que no caduca).
- **Cerrojo en `elect.sh`** (`mkdir` atómico, con liberación de huérfanos a los
  10 min): se vio en vivo que dos elecciones pueden solaparse e intercalar sus
  líneas. Ahora una cede el turno.

Y `elect.sh` **deja registro** (`elect.log`, recortado a 300 líneas): antes iba a
`/dev/null` y hubo que reconstruir el incidente a partir de fechas de ficheros.

**Verificado**: los 11 nodos deciden `sentinel016` por unanimidad, y las cuatro
situaciones de la protección (Wheel presente / ausente 1 ronda / ausente 2 rondas
/ reaparecido) se probaron contra la flota real antes de desplegar.

#### Una hora de vigilancia: lo que enseñó

Se vigiló la flota durante 60 min (20 rondas de 3 min). **20/20 con un solo
coordinador**, pero lo interesante está en `elect.log`: la protección **tuvo que
actuar 5 veces en 4 horas** — `sentinel002` (11:00), `sentinel001` (11:20),
`sentinel005` (11:40, 12:40, 13:50, 14:15). Cada una habría sido una coronación
espuria con el código anterior. Eso confirma el ritmo (~1/hora) que explicaba por
qué el problema reaparecía a diario.

**Pero una escaló**, y conviene contarla entera:

```
11:35  Wheel sigue siendo sentinel016 (184.1 puntos)
11:40  el Wheel (sentinel016) no responde (ronda 1 de 2): no lo relevo todavia
11:45  el Wheel (sentinel016) lleva 2 rondas sin responder: procede el relevo
       Wheel: sentinel016 -> sentinel014 (180.7 puntos)
11:50  Wheel sigue siendo sentinel014
11:55  Wheel: sentinel014 -> sentinel016 (196.1 puntos)
```

`sentinel005` estuvo **10 min sin ver a `sentinel016`, mientras los otros nueve
nodos lo veían perfectamente**. No fue una caída del Wheel: fue un enlace malo de
un solo teléfono. No llegó a mandar avisos (coronó a *otro*, no a sí mismo, así
que ninguno de los dos se creía Wheel), pero el agujero estaba a la vista.

**La corroboración por rqlite.** `/nodes` publica `"reachable"` por nodo, y eso
viaja por **Raft en el 4002**, un camino de red independiente del sondeo HTTP del
**8181**. Antes de destronar al Wheel se pide esa segunda opinión:

| rqlite dice | Decisión |
|---|---|
| `reachable:true` | **No se releva.** «La ceguera es mía»: contador a cero |
| `reachable:false` | Se releva — dos transportes independientes coinciden |
| No hay respuesta / IP desconocida | Sin segunda opinión: se decide como antes |

**La paciencia con rqlite: 10 s, no 4.** `/nodes` **no responde de memoria**:
sondea a todos los peers en vivo, así que **tarda más justo cuando la red va
mal** — que es exactamente cuando se le pregunta. Con 4 s se perdió una
corroboración (`sentinel005`, 17/08 19:15, *«sin segunda opinión»*) y ese nodo
relevó al Wheel por su propia ceguera. Se paga solo cuando ya se iba a destronar
al coordinador, y una ronda entera sigue tardando ~20 s frente al ciclo de 5 min.

Para poder preguntar por él hace falta saber dónde vive, y un nodo caído ya no lo
puede decir: se memoriza su IP en `wheel.state.ip` mientras responde — el mismo
truco que se usó para que los avisos digan el nombre y no la IP.

Probados los cuatro caminos, incluido `reachable:false` con una respuesta rqlite
fabricada vía `file://`. **Ese caso importaba especialmente**: si el análisis
fallara, la flota nunca podría relevar a un Wheel muerto de verdad — un fallo
bastante peor que el que se está corrigiendo.

### La estampida del segundo `:00` — reparto en el tiempo (2026-08-18)

Dos horas de vigilancia con la elección registrando **quién** no contesta dieron
un patrón que ninguna de las hipótesis anteriores había tocado:

| Dato | Valor |
|---|---|
| Rondas con algún nodo ausente | **153** |
| De ellas, en el segundo `:00`-`:01` | **148 (97 %)** |
| Veces que un nodo **no se alcanzó a sí mismo** por `127.0.0.1` | **29** |
| Sonda de enlace en `sentinel005` (cada minuto, por cron) | **134 muestras, 0 fallos** |

Ese `127.0.0.1` es la prueba: **ahí no hay red que valga**. El agente estaba
ocupado, no inalcanzable.

**Qué pasa realmente.** Cada 5 minutos los 11 nodos lanzan a la vez elección +
alerta + watchdog. Cada equipo dispara del orden de 36 peticiones salientes
*mientras* recibe unas 20 entrantes, y las atiende **un gawk monohilo**, una
detrás de otra. Los teléfonos más flojos no llegan a tiempo y desaparecen para
todos. Cuando el que se queda atrás es el Wheel, el que lo pierde de vista se
cree con derecho a destronarlo — que es el problema original de la semana.

**La corrección: un desfase fijo por nodo y por tarea**, derivado del nombre con
`cksum` y acotado a 120 s:

```sh
_j=$(printf '%s-elect' "$NAME" | cksum | cut -d' ' -f1)
sleep $(( _j % 120 ))
```

**Fijo y no aleatorio** a propósito: cada equipo tiene siempre su hueco, el
reparto no cambia en cada arranque y se puede predecir al depurar. Comprobado con
los nombres reales: **ninguna colisión** en la elección, que es la tarea que
carga a toda la flota. Cuatro sales distintas (`elect`, `alert`, `watchdog`,
`bateria`) para que las cuatro tareas de un mismo nodo tampoco se apilen.
`SENTINEL_NOJITTER=1` lo salta, para poder probar a mano sin esperar.

Se eligió 120 s y no más porque el ciclo es de 300 s y la alerta puede tardar
~100 s cuando hay nodos caídos: con 240 s de desfase, dos ejecuciones podrían
solaparse, que es justo lo que produce avisos duplicados.

**Medida de referencia antes del cambio** (rondas con algún ausente): 49-50 % en
`001`, `002`, `003`, `005`, `010`, `019`; 22-26 % en `009`, `014`, `016`, `018`.

De paso, `elect.sh` **fecha cada línea** y no solo la primera: la elección escribe
varias por ronda desde que registra quién no contesta, y sin marca en todas el
análisis posterior no se puede hacer.

### Telemetría de batería: el punto ciego que mató a `sentinel017` (2026-08-18)

`sentinel017` se apagó sin previo aviso. **Estaba enchufado.** El dueño lo
sospechó al recogerlo —«creo que consume más de lo que carga»— y la medición le
dio la razón, con un segundo nodo ya en camino:

```
sentinel003:  plugged: PLUGGED_AC     ← enchufado
              status:  NOT_CHARGING   ← pero no carga
              current_average: -358 mA   80%   42.0 °C
```
Con 2.169 mAh restantes, **~6 h de autonomía**. Media hora después, ya enfriado a
40 °C, volvía a cargar a +228 mA. **Oscila**: se calienta → deja de cargar → tira
de batería → se enfría → vuelve a cargar.

**El punto ciego, en una frase:** Android corta la carga hacia los **42 °C**, pero
el aviso térmico de thermal-guard salta a **45 °C**. Entre ambos hay tres grados
en los que un equipo **deja de cargar en silencio**. El corte se ve en la propia
flota: `sentinel018` a 39,8 °C carga sin problema; `sentinel003` a 42,0 °C no.

Y no se podía diagnosticar hacia atrás: se guardaba temperatura, **nunca carga**.

**Lo que se añadió:**

| Pieza | Qué hace |
|---|---|
| `Sentinel-Bateria.sh` | Cron cada 5 min en los 9 Termux. Escribe `percentage`, `status`, `plugged`, corriente, temperatura y salud en la tabla nueva `sentinel_bateria`. Poda a 14 días, una vez al día |
| Sección de batería en `Sentinel-Alert.sh` | La ejecuta solo el Wheel, con las mismas guardas que el aviso de nodo caído |

**Dos decisiones de diseño que importan:**

1. **No se toca `thermal-guard`.** Es código en producción que apaga el teléfono
   si se calienta de verdad. Esto va en un script aparte que solo lee y escribe.
2. **Se avisa por TENDENCIA, no por estado instantáneo.** Un equipo en el límite
   alterna `CHARGING`/`NOT_CHARGING` cada pocos minutos, y avisar de cada cambio
   sería ruido puro. Lo que no admite discusión es **perder porcentaje estando
   enchufado**: 5 puntos en 2 h, o bajar del 30 % (`BAT_CAIDA_PCT`, `BAT_MIN_PCT`).
   Los desenchufados se ignoran — `sentinel019` es un móvil personal y estar
   descargándose es su estado normal.

Probado en vivo con datos reales: silencio con umbrales normales, y forzando el
umbral al 100 % aparece el mensaje con los siete nodos enchufados y **sin**
`sentinel019`, que es justo lo que debía pasar.

**Habría avisado de `sentinel017` con días de antelación.**

### `peers.tsv`: cuatro días congelado y nadie lo refrescaba (2026-08-17)

`peers.tsv` es el **plan B** de dos cosas: la lista de candidatos de la elección y
la lista de vigilancia del aviso cuando rqlite no contesta. Lo escribía solo
`Sentinel-Discover.awk`… que **no estaba programado en ningún sitio**. Resultado:

| Síntoma | Detalle |
|---|---|
| Congelado | Todas las copias con fecha **08-14 00:29**, cuatro días |
| Incompleto | 6-8 entradas de 11. A `sentinel005` le faltaban **5 nodos, incluido el propio Wheel** |
| Ausente | `sentinel016`, `018` y `019` **no tenían el fichero** |
| Rol obsoleto | Marcaba `192.168.1.250` como `wheel`, cuando el Wheel es `192.168.1.91` desde hace días |

**Ahora lo refresca la elección**, que es quien ya tiene los datos: corre cada 5
min, sondea a todos y sabe quién vive y quién manda. Tres decisiones:

1. **Solo se reescribe si rqlite contestó.** Sin autoridad no se pisa la última
   foto buena — que es exactamente para lo que existe el fichero.
2. **No se copia a sí mismo.** Se guardan los del clúster más los que hayan
   respondido, y nada de lo que ya hubiera. Si se realimentara, una IP retirada
   seguiría ahí para siempre y además **inflaría el recuento del quórum**.
   Probado: una IP fantasma inyectada a mano desaparece en la primera ronda.
3. **`mv`, no escritura encima.** El awk deja `peers.tsv.tmp` y `elect.sh` lo
   mueve, que es atómico. Escribir directamente abriría una ventana en la que
   otro proceso podría leer media línea, y **media IP es un candidato fantasma
   que descuadra el quórum**.

El rol y la versión se rellenan de verdad (`wheel`/`eye`, `Sentinel Super 2.0.0`
derivado de la misma regla que usa `/version`), porque el endpoint `/peers` los
publica para el gossip.

**Resultado**: los 11 nodos con 11 entradas, Wheel correcto y menos de 2 min de
antigüedad. `Sentinel-Discover.awk` sigue existiendo para el barrido manual de
red, que es lo que sabe encontrar nodos que no están en el clúster.

### Cuatro avisos del mismo suceso: la elección tenía un agujero

Llegaron **cuatro avisos idénticos**, firmados por cuatro «Wheels» distintos
(016, 001, 018, 002). No era un fallo de las alertas sino de la **elección**:

**Un nodo que solo ve una parte de la red elegía «al mejor de los que ve»… que
suele ser él mismo.** El disparador fue repartir el script borrando el
`wheel.state` de todos a la vez: cada nodo eligió por su cuenta antes de verse
con los demás. La red converge sola después —y de hecho lo hizo—, pero durante
esa ventana hubo varios coordinadores y cada uno avisó.

Corregido con **quórum**, en dos reglas:

| Situación | Antes | Ahora |
|---|---|---|
| No veo a nadie más que a mí, y ya hay un Wheel | me coronaba | **no lo toco**: un nodo incomunicado no le quita el mando a quien probablemente siga sano |
| Veo menos de la mitad de los candidatos | decidía igual | **no decido**: visión parcial, dejo el Wheel como está |

Se conserva el arranque en frío: si la red **aún no tiene Wheel**, un nodo solo sí
puede proclamarse, que es lo que permite empezar.

Añadida además una segunda red en las alertas: antes de avisar, el Wheel
comprueba **contra la red** si algún otro nodo también se cree Wheel y, en ese
caso, calla y deja avisar al de nombre menor. Con la elección sana no se activa
nunca, pero evita el aviso por cuadruplicado durante cualquier ventana de
desacuerdo.

**Probado**: un nodo aislado con un Wheel ya existente responde *«solo me veo a mí
mismo y ya hay Wheel (sentinel016): no lo toco»* y no cambia nada. En la flota,
**exactamente un nodo** se cree Wheel y los demás callan.

## Estado de la flota v2

| Nodo | Plataforma | Backend | Sin token | mTLS | rqlited |
|---|---|---|---|---|---|
| sentinel017 | Termux / runit | OK | 401 | activo | intacto |
| sentinel003 | Termux / runit | OK | 401 | activo | intacto |
| sentinel009 | Termux / runit | OK | 401 | activo | intacto |
| sentinel010 | Termux / runit | OK | 401 | activo | intacto |
| sentinel002 | Termux / runit | OK | 401 | activo | intacto |
| sentinel016 | Ubuntu / systemd | OK | 401 | activo | intacto |
| sentinel014 | Ubuntu / systemd | OK | 401 | activo | intacto |
| sentinel001 | Termux / runit | OK | 401 | activo | intacto |
| sentinel005 | Termux / runit | OK | 401 | activo | intacto |
| sentinel013 | Windows (laptop) | OK | 401 | — | **no lleva rqlite** |

**sentinel001 y sentinel005** son los de WhatsApp. Tras el despliegue, el checker
sigue en pie en ambos (`:8002` → 200) y en sentinel005 el chatbot conserva la
sesión (`ready:true`, sin re-escanear QR). En sentinel001 aparece `ready:false`,
pero su último error de WhatsApp es **de hace ~39 días** (marca `1783294512`):
es la desconexión recurrente que ya documenta el README de `Nodos\`, no la causó
el despliegue. En ambos se puso `MAXJOBS=2`.

| sentinel018 | Termux / runit | OK | 401 | activo | intacto |

**sentinel013** entra en la red como nodo simple: `WHEEL_ELIGIBLE=no` y `RQLITE`
vacío. **sentinel018** fue alta nueva (nunca tuvo `PRC_Sentinel`); openssl y
stunnel se instalaron solos.

### El Wheel Windows: supervisión con el Programador de tareas

Windows no tiene runit ni systemd, así que **la supervisión la hace el propio
Programador**: la tarea **`PRC Sentinel v2`** ejecuta cada **5 minutos** un
vigilante que comprueba `/version` y, si no responde, levanta el agente. Es el
mismo patrón que el watchdog del v1, pero para un proceso en vez de veinte.

- La acción es un `.vbs` que llama al `.cmd` **sin abrir ventana**: si no, cada
  5 minutos parpadearía una consola.
- **Sin contraseña almacenada.** `Register-ScheduledTask` falla con *Access is
  denied* (la raíz del Programador pide administrador); se creó con `schtasks`,
  que sí permite tareas del propio usuario. Y se evitó a propósito el
  `LogonType=Password` del que avisa el README principal: esas tareas no se
  pueden reconfigurar por script.
- **Probado**: se mató el agente, se ejecutó la tarea y volvió (`Last Result: 0`).

Consecuencia asumida: al depender del inicio de sesión, el Wheel Windows solo
está disponible cuando hay sesión iniciada — otra razón para que **no sea
elegible** como coordinador.

Clúster **11/11 alcanzables** y **11 nodos activos** en la telemetría.

### Lo que queda

| Nodo | Nota |
|---|---|
| `sentinel001`, `sentinel005` | Los de **WhatsApp** (:8002 y el chatbot). Los más delicados que quedan. |
| `sentinel018` | **Alta nueva**: nunca tuvo `PRC_Sentinel`. |
| `sentinel019` | **No responde** (Pixel personal, fuera de la WiFi). |
| `sentinel013` (Wheel) | Windows, rol `Super`. Sin tarea programada al principio. |

### Pendiente

- **Vigilar 48 h** los cinco nodos: temperatura, `rqlited` y telemetría.
- **Renovación de certificados**: caducan a 825 días y la PKI es idempotente (no
  reemite si el fichero existe). Hace falta un procedimiento de renovación.
- **Programar el descubrimiento**: `peers.tsv` sólo se rellena si alguien ejecuta
  `Sentinel-Discover.awk`; hoy no lo lanza nada.
- **Monitorización**: nada avisa si un nodo v2 se cae o se atasca.
