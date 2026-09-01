# RED Sentinel

**RED Sentinel** es una flota doméstica de 12 equipos (móviles Android con
Termux, dos tablets Amazon Fire, dos Linux y una laptop Windows) que se vigilan
entre sí y ejecutan trabajo útil en conjunto: hoy, registrar el precio de
criptomonedas cada 10 segundos en una base replicada con rqlite, sin agujeros en
la serie. El diseño prioriza **disponibilidad sobre potencia** — los nodos son
teléfonos que Android apaga, congela y desconecta a voluntad. Este repositorio
reúne el código, la configuración de ejemplo y la documentación del sistema;
el código real corre en los nodos y se despliega por `scp`.

Las piezas del sistema Sentinel, reunidas el **2026-07-26**. Antes vivían
dispersas y sin relación aparente: `D:\PRC Sentinel` y `D:\PRC User Agent` en la
raíz, y `D:\Herramientas\Sentinel_Infra` metida entre herramientas de terceros.

| Carpeta | Era | Qué es |
|---|---|---|
| `Wheel\` | `D:\PRC Sentinel` | El nodo **Wheel** que corre en esta laptop (sentinel013, 192.168.1.117). 3106 ficheros. |
| `Nodos\` | `D:\Herramientas\Sentinel_Infra` | Espejo **de solo lectura** del código y del arranque de los 11 nodos. |
| `UserAgent\` | `D:\PRC User Agent` | Alimenta la variable `UserAgent` de toda la red. 6 ficheros. |
| `rqlite\` | — **nuevo** | El DDL del clúster, que hasta hoy solo existía dentro del clúster. |

> 📘 **[HISTORIA_CRIPTO.md](HISTORIA_CRIPTO.md)** — las cinco generaciones del
> proyecto y, en detalle, todo el trabajo con criptomonedas: captura de
> **orderbook**, el **arbitraje** entre Coinbase y Kraken, los conectores de
> Jupiter y Raydium, el almacén DWD/DWF/DWS y las siete versiones del colector de
> precio. Léelo antes de reordenar nada de `Wheel\OLD\`.

## Lo que se rescató de los dispositivos (2026-07-26)

Cuatro piezas críticas no tenían copia en ningún disco: si el hardware moría, se
perdían. Ahora están aquí, cada una con su README de restauración.

| Rescatado | Vivía solo en | Dónde está ahora |
|---|---|---|
| DDL de `sentinel_temp`, `sentinel_disk`, `v_sentinel_estado` (+ Lotería e Indeed) | el clúster rqlite | [`rqlite\esquema.sql`](rqlite/esquema.sql) |
| `config.yml` del túnel `rpa-extron` | `sentinel014:/etc/cloudflared/` | [`Nodos\cloudflared\`](Nodos/cloudflared) |
| `rpa-extron-cycle.{service,timer}` y `rpa-extron-dashboard.service` | `sentinel014` | [`Nodos\systemd_services\`](Nodos/systemd_services) |
| `rqlited.service` de los dos nodos Ubuntu | `sentinel014` y `sentinel016` | [`Nodos\systemd_services\`](Nodos/systemd_services) |

Las unidades systemd fueron a `Nodos\systemd_services\` y no a una carpeta por
hostname en la raíz: `Nodos\` ya contiene `runit_services\` y `termux_boot\`,
que son exactamente lo mismo para los nodos Android. Un solo espejo, no dos.

**Ninguno de estos ficheros se ejecuta desde aquí.** Son copias de referencia:
para que surtan efecto hay que `scp` al nodo y recargar. Lo dice cada README.

Lo que deliberadamente **no** se copió: la credencial del túnel de Cloudflare y
el `.env` del RPA Extron. Son secretos; guardarlos en claro en `D:\` es lo que
se limpió en la Fase 1 del reordenamiento. Consecuencia asumida: se puede
reconstruir la configuración, no el túnel. Ver el README de `cloudflared\`.

## UserAgent: por qué está aquí y no como proyecto aparte

No es un proyecto independiente que casualmente se llame parecido: **es parte
del proceso del Wheel**. Cada nodo define `UserAgent` en su `~/.profile`, y el
clon EYE del puerto 8081 lo expone por `/useragent`. `Get Last UserAgent.awk`
obtiene el último user-agent disponible y lo publica con `setx UserAgent`, más
un `insert into dwd_user_agent` en `Datos\UserAgent.db`.

Originalmente lo scrapeaba de la web —`useragents.me`, línea 26 del `.awk`—
porque no había otra forma. `Prompt_GetSpec_Grok.bat` es el reemplazo por IA.

Es hermano de `Wheel\` y no una subcarpeta suya porque tiene su propio
`Script\ Datos\ Log\`: es un componente par, no una parte interna.

## Por qué son dos carpetas y no una

Es la parte que hay que entender antes de reestructurar. **No son copias
divergentes del mismo código: son dos roles distintos del mismo sistema**, y
ambos tienen un `Script\Sentinel-Server.awk` con contenido diferente.

| | Se identifica como | Base de datos |
|---|---|---|
| `Wheel\` | `Sentinel Super 1.0.0` | `SimuladorOnLine.db` |
| `Nodos\` | `Sentinel 1.0.0` | `Simulador.db` |

`Sentinel-Search.awk` marca como IpWheel al nodo que responde
`Sentinel Super`. Las variables de entorno lo confirman: en esta laptop
`MyIP` = `IpWheel` = `192.168.1.117`.

**Fusionarlos en un solo árbol sobrescribiría un `Sentinel-Server.awk` con el
otro y rompería el descubrimiento del Wheel.** `Sentinel-Search.awk` sí es
idéntico en ambos lados — solo cambian los finales de línea, LF en el espejo
POSIX y CRLF en la copia de Windows.

## Estado

`Wheel\` **no está en uso**. Sus dos tareas programadas (`PRC Sentinel` y
`PRC Sentinel Clone`) **las borró el dueño el 2026-07-26**, para recrearlas al
reestructurar con rqlite.

Su cadencia quedó reconstruida a partir de los logs que el propio script deja
en `Wheel\Log\<fecha>_Sentinel-Start.log`, porque en la definición de las tareas
no se anotó antes de borrarlas:

- **`Sentinel-Start` corría cada hora en el minuto 23** — 00:23:16, 01:23:16,
  02:23:16… con un ciclo de ~3 s («Reiniciando servicio Sentinel» → «Service up
  with version: Sentinel Super 1.0.0»). Último día con actividad: 2026-07-18.
- `PRC UserAgent` seguía la misma forma: diaria a las 18:24 con repetición
  horaria. Es la pista de cómo estaba pensado el conjunto.

`Wheel\Log\` no se tocó en la mudanza: son registros de corridas pasadas y
reescribir sus rutas sería falsificar historia. De ahí salió esta reconstrucción.

`Nodos\` es documentación viva: el código real está en cada teléfono bajo
`/data/data/com.termux/files/home/`. **Editar aquí no cambia nada en los
dispositivos** — hay que copiar por `scp`. Ver `Nodos\README.md` para el mapeo
completo de los 11 nodos del clúster rqlite.

## Lo que quedó tocado en la mudanza

- Cinco rutas fijas `D:\PRC Sentinel` en `Wheel\Script\`: `Sentinel-Test.bat`,
  `Sentinel-Stress.bat` (×2), `Sentinel-Start.bat` y `Sentinel-Clone.bat`.
  Se cambiaron por la ruta nueva, sin introducir `%~dp0`: estos scripts
  gobiernan la red de teléfonos y no hay forma de probarlos desde aquí, así que
  el cambio tenía que ser un no-op semántico verificable.
- `DirSentinel` y `PathSentinel` en `HKCU\Environment` → `D:\RED Sentinel\Wheel`.
  Importa: `PRC Crypto Trends\Script\*.bat` consume `%PathSentinel%`, así que
  sigue funcionando sin tocarlo.
- `RPA Monitor Extron\ESTADO_Y_PENDIENTES.md:146` apuntaba al README de `Nodos\`.

- Dos rutas fijas en `UserAgent\Script\`: `Ejecuta User-Agent.bat:10` con barra
  simple y `Get Last UserAgent.awk:18` con barra escapada (`D:\\PRC User Agent\\`).
  Ese doble escapado es lo que hizo fallar la primera búsqueda sobre `Wheel\`:
  un patrón que busca una sola barra no encuentra las de los `.awk`.

## Pendiente

**`sentinel019` fuera de casa.** El móvil personal deja de estar en la red en
cuanto pasa a datos móviles: toda la red Sentinel funciona por sondeo entrante y
tras el CGNAT del operador nadie puede abrirle conexión. Diseño cerrado, código
hecho y probado; quedan tres pasos que hay que dar a mano (malla en el móvil,
subnet router en `sentinel014`, ruta estática en el router).
Ver [`ROAMING_sentinel019.md`](ROAMING_sentinel019.md).

**La tarea `PRC UserAgent` sigue apuntando a `D:\PRC User Agent\Script\Ejecuta
User-Agent.bat`, que ya no existe.** No se pudo corregir por script: está
configurada con `LogonType=Password`, y tanto `Set-ScheduledTask` como
`schtasks /change` exigen la contraseña de la cuenta para re-registrarla.

Hay que editarla en el Programador de tareas → pestaña Acciones → Editar, y
poner `D:\RED Sentinel\UserAgent\Script\Ejecuta User-Agent.bat`. Windows pedirá
la contraseña. Está `Disabled`, así que mientras tanto no causa daño.

Cuidado con `Set-ScheduledTask` sobre tareas con `LogonType=Password`: funciona
desregistrando y volviendo a registrar, así que un fallo de credenciales en el
segundo paso puede dejar la tarea eliminada. Usar el Programador de tareas.

## Paquetes del repositorio

| Paquete | Qué es |
|---|---|
| `Wheel/` | El nodo **Wheel** de la laptop (sentinel013): servidor HTTP en gawk v1 (`Script/`) y v2 (`Script/v2/`: `Sentinel-Server2.awk`, Wheel, Worker, PKI/TLS/Token/Alert/Roam/Selftest). Sus `Datos/`, `Log/`, `Temporal/`, `Run/` y `OLD/` quedan fuera del repo. |
| `Nodos/` | Espejo **de solo lectura** del código de los 11 nodos Android/Termux+Ubuntu; su `README.md` es el mapa completo de la flota. |
| `Nodos/prc_sentinel/` | Servidores gawk v1 y v2 del sentinel + scripts de instalación, PKI, TLS, token y unidades de servicio (runit/systemd/Windows). |
| `Nodos/whatsapp_chatbot/` | Chatbot WhatsApp con Baileys + Gemini (`server.js`, `.env.example` con placeholders). |
| `Nodos/whatsapp_checker/` | Checker WhatsApp Baileys + API para el reloj Wear OS (`:8002`); su `watch_token.txt` vive solo en el nodo. |
| `Nodos/telegram_bridge/` | Puente Telegram MTProto con sesión de usuario (teleproto); `api_id`/`api_hash` y `session.txt` se leen en runtime en el nodo. |
| `Nodos/prc_thermal/` | Guardián térmico (`thermal-guard.sh` + `thermal-guard.conf.example`). |
| `Nodos/cloudflared/` | Túnel `rpa-extron` rescatado de sentinel014 (`config.yml`, `cloudflared.service`, README); la credencial `.json` vive solo en el nodo. |
| `Nodos/runit_services/`, `Nodos/systemd_services/`, `Nodos/termux_boot/` | Unidades de arranque de rqlited, telegram_bridge, whatsapp_checker y RPA Extron. |
| `UserAgent/` | Alimenta la variable `UserAgent` de toda la red: scripts `.bat`/`.awk` (su `UserAgent.db` queda fuera). |
| `rqlite/` | DDL del clúster (`esquema.sql`) + README; hasta 2026-07 solo existía dentro del clúster. |
| `docs/` | `ADR.md` (decisiones de arquitectura, exportado del knowledge graph) y `ESTRUCTURA.md` (árbol comentado). |

## Arquitectura en breve

- **Flota de 12 nodos** domésticos: Android/Termux, dos Amazon Fire, dos Linux
  (sentinel014/016) y esta laptop Windows (sentinel013).
- **rqlite (Raft sobre SQLite)** en 11 nodos, puertos 4001/4002: la base se
  replica entera en cada nodo; la semilla es sentinel001.
- **El Wheel** (coordinador) no es fijo: la red lo elige por aptitud
  (`Sentinel-Wheel.awk` → `wheel.state`) y el trabajo migra solo con el relevo.
- **Servidor HTTP en gawk** (`Sentinel-Server2.awk`, puerto 8181) sin TLS
  nativo; **mTLS con stunnel** en el 8443 y token de flota como barrera.
- **Carga real**: `Sentinel-Cripto.sh` registra precio cada 10 s con
  recolectores redundantes (los Linux, no los móviles).
- **Servicios satélite**: chatbot y checker de WhatsApp, puente Telegram,
  guardián térmico, túnel Cloudflare del RPA Extron y el alimentador UserAgent.
- Supervisión con **runit** (Termux) y **systemd --user** (Linux); arranque
  Android vía Termux:Boot. El detalle completo está en [`docs/ADR.md`](docs/ADR.md).

## Cómo se despliega hoy

**Nada de este repo se ejecuta desde aquí.** Cada fichero es copia de referencia:
para que surta efecto hay que copiarlo por `scp` al nodo correspondiente y
recargar el servicio a mano (`sv restart` en Termux, `systemctl --user` en los
Linux, tareas programadas en Windows). Así lo documentan
[`Nodos/README.md`](Nodos/README.md) (mapeo de los 11 nodos y procedimientos),
[`Nodos/cloudflared/README.md`](Nodos/cloudflared/README.md) y
[`Nodos/systemd_services/README.md`](Nodos/systemd_services/README.md).
No hay CI/CD ni despliegue automático: mover o renombrar carpetas de este árbol
rompe los scripts de despliegue existentes.

## Qué NO está en este repo

El `.gitignore` del primer commit excluye deliberadamente:

| Excluido | Por qué | Dónde vive |
|---|---|---|
| Llaves y certificados PKI (`*.key`, `*.pem`, `*.crt`, `*.csr`, `*.p12`, `*.srl`) y `Wheel/Script/v2/_test/` | Material criptográfico; `_test/` son residuos del selftest 2026-08-26 (llaves, `fleet.token`, `test.db`) | La PKI real, en los nodos |
| Tokens de flota (`fleet.token`, `*.token`, `watch_token.txt`) | Secretos de autenticación | Ficheros runtime en cada nodo |
| Sesiones Baileys (`auth_info*/`, `creds.json`) y de Telegram (`*session*`) | Credenciales de sesión | Solo en sentinel005 y el nodo del puente |
| `.env` reales (los `.env.example` sí se versionan) | Secretos de servicio | En cada nodo, `chmod 600` |
| Credencial `.json` del túnel Cloudflare | Secreto del túnel | `sentinel014:~/.cloudflared/` |
| `Wheel/OLD/` (366 MB, 2.419 ficheros, congelado desde 2024) | Histórico muerto: copias de nodos viejos, driver Realtek vendorizado, confs de router con contraseñas WiFi y un `.out` de 246 MB | En este disco; su historia está en [`HISTORIA_CRIPTO.md`](HISTORIA_CRIPTO.md) |
| Datos y salidas (`*.db`, `Log/`, `Temporal/`, `Wheel/Run/`, `*.log`, `*.tmp`, `*.out`, `*.state`) | Bases vivas y registros de ejecución, no fuente | En el árbol local y en cada nodo |
| `Sentinel_Escalado_Costos.xlsx` y `Sentinel_Recepcionista_IA_CapEx.xlsx` | Documentos de negocio, no código | En este disco |
| `RouteController.cpp` (0 bytes) y backups `*.bak-*` | Ficheros muertos | En este disco |
| `UserAgent/Script/Prompt_GetSpec_Grok.bat` | Lleva una API key de xAI hardcodeada (hallada en la auditoría del primer commit); volverá al repo cuando lea la clave de un fichero o variable de entorno | En este disco |

Este repositorio está pensado para un remoto **privado** (Tuanilabs-LLC):
`Nodos/README.md` contiene el mapa de red doméstico completo (hostnames, IPs
LAN, puertos y roles).
