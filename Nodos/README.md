# Sentinel Infra — Flota Android/Termux (mirror de documentación)

Mirror local (solo lectura) del código que corre en la flota de teléfonos Android
con Termux. El código real vive en cada dispositivo bajo
`/data/data/com.termux/files/home/`. Este repo existe para que codebase-memory
lo indexe y sirva como memoria de arquitectura. **Editar aquí NO cambia nada en
los dispositivos** — hay que copiar por `scp` al nodo correspondiente.

Última auditoría: 2026-07-05 (desde la laptop, vía `ssh sentinel001`).
Verificación remota parcial: 2026-07-21 (clúster rqlite, telemetría, chatbot).
Alta de sentinel019 / node11: 2026-07-24 (clúster verificado en vivo: 11 nodos).

## Flota / mapeo de nodos

Todos son teléfonos o tablets Android con Termux, usuario `sentinel`, SSH puerto
**8022** (configurados en `~/.ssh/config` de la laptop). La columna **Modelo**
sale de `getprop ro.product.model` preguntado **en vivo a cada equipo el
2026-09-16**, no de suposiciones. Los tres nodos que no respondieron ese día
quedan como *sin determinar*: sondearlos cuando vuelvan con
`ssh <nodo> 'getprop ro.product.model; getprop ro.product.manufacturer'`.

| Host SSH    | IP LAN         | rqlite node-id | Modelo (SoC / SO)                | Rol extra                        |
|-------------|----------------|----------------|----------------------------------|----------------------------------|
| sentinel001 | 192.168.0.231  | node1          | Samsung Galaxy A12 `SM-A125U` (MediaTek Helio P35 / MT6765, Android 12) | WhatsApp_Checker + API del reloj (:8002), Puente Telegram (:8003), PRC_Sentinel (:8081-8100) |
| sentinel002 | 192.168.0.45   | node9          | OnePlus Nord N100 `BE2015`, variante Metro (Snapdragon 460 / bengal, Android 11) | unido 2026-07-17 |
| sentinel003 | 192.168.0.214  | node2          | Samsung Galaxy A14 `SM-A145P` / `a14m` (MediaTek Helio G80 / MT6768, Android 15) | tope de carga ~80 % |
| sentinel005 | 192.168.0.166  | node3          | T-Mobile REVVL V+ 5G `Sprout`, de Wingtech (Dimensity 700 / MT6833, Android 12) |                                  |
| sentinel009 | 192.168.0.154  | node4          | Amazon Fire HD 8 12.ª gen `KFRAWI` / `raspite` (MT8169, Fire OS 8.3.3.8) | gemela física de 010 |
| sentinel010 | 192.168.0.34   | node5          | Amazon Fire HD 8 12.ª gen `KFRAWI` / `raspite` (MT8169, Fire OS 8.3.3.8) | líder rqlite habitual · gemela física de 009 |
| sentinel014 | 192.168.0.21   | node6          | — no es teléfono (Ubuntu 24.04)  | rqlite en Ubuntu 24.04 (systemd user), **RPA Monitor Extron** (ciclo 2×/día + dashboard :3008), **Monitoreo de BTC** (cada 5 min, Servicio 11) |
| sentinel016 | 192.168.0.159  | node7          | — no es teléfono (Ubuntu 24.04)  | rqlite en Ubuntu 24.04 (systemd user), prc-agent-jupiter (Docker, wallet Phantom) |
| sentinel017 | 192.168.0.22   | node8          | Motorola moto g play 2024 `fogona` (Qualcomm Snapdragon, plataforma `bengal`, Android 14) | unido 2026-07-17 |
| sentinel018 | 192.168.0.130  | node10         | Samsung Galaxy A20 `SM-A205U` / `a20p` (Samsung Exynos 7904, Android 10) | detectado en auditoría remota 2026-07-21 (reporta telemetría battery) |
| sentinel019 | 192.168.0.218  | node11         | Google Pixel 6 (Tensor, Android 17, aarch64) | celular personal, unido 2026-07-24. Backend **Sentinel SMS** (:8010, solo loopback, pm2) |

**Cambio de subred (2026-10-04).** Con el router y el proveedor nuevos la LAN
pasó de `192.168.1.0/24` a **`192.168.0.0/24`** (gateway `192.168.0.1`, mismo
SSID). La tabla de arriba lleva las IP nuevas; la laptop sentinel013 quedó en
`192.168.0.209`. Las IP salen por DHCP: **hay que reservarlas por MAC en el
router**, porque van escritas en el arranque de rqlited, en `~/.profile`, en
`sentinel.conf` y en el `~/.ssh/config` de la laptop. Los 11 nodos quedaron
reconfigurados ese mismo día. **sentinel020 (192.168.0.79)** necesitó que el
dueño le abriera SSH a mano: Windows trató la red nueva como *Pública* y la
regla de OpenSSH solo aplica al perfil Privado. Ahí se corrigieron los dos
alias hacia sentinel014 de su `~/.ssh/config` y, en sentinel014, el
`from="192.168.0.79"` de la llave `sentinel020-rpa-ampronix`. **Quedan sus
reglas de firewall de los paneles** las actualizó el dueño (origen
`192.168.0.0/24`, red en perfil Privado): los seis paneles responden desde la
LAN. **El relay de DOTmed dejó de servir tal cual:** con la IP pública del
proveedor nuevo `dotmed.com` devuelve 403 a todos los equipos de casa (probado
con el `curl` exacto de la app desde 014, 016, 005 y 010). Se resolvió sacando
ese `curl` por **RED Proxy** (puertos fijos 8801–8850 y rotativo 8888, salida
por IPv6 de AWS): RPA Ampronix elige un puerto fijo al azar en cada petición
(`DOTMED_RELAY_PROXY`). **El relay de RED Proxy se mudó ese mismo día de
sentinel014 a sentinel020**, por decisión del dueño de tener allí los dos
proxies: ahora son dos tareas programadas («RED Proxy - Tunel» y «RED Proxy -
Rotador», en `D:\RED Proxy\relay\`), y en sentinel014 `prc-relay-tunnel` y
`prc-relay-proxy` quedaron parados y deshabilitados. Detalle en el README del
repositorio RED Proxy. Qué se tocó en cada nodo y cómo se recuperó rqlite: ver
[Servicio 2](#servicio-2-rqlite-clúster-de-11-nodos).

**Cron tras un reinicio (hallado el 2026-10-04 en sentinel001 y sentinel019).**
Cuando a `crond` lo arranca el script de Termux:Boot, sus trabajos no heredan
el `LD_PRELOAD` de termux-exec, y los scripts con `#!/usr/bin/env sh` (elect,
alert, watchdog, bateria, cripto, roam) fallan con *not found* — en Termux no
existe `/usr/bin/env`. Solo sobrevive `thermal-guard.sh`, que lleva shebang
absoluto, así que la telemetría sigue y **nada delata el fallo**: estaban así
sentinel018 desde el 28/08, sentinel019 desde el 26/08, sentinel003 desde el
22/09 y sentinel001 desde el 30/09. Se ve en `watchdog.log` (`watchdog.sh: not
found`) y en la fecha de la última línea de `elect.log`. Corregido el 2026-10-04
en el arranque de **los nueve nodos Termux** y en
[`termux_boot/00-services.sh`](termux_boot/00-services.sh): `crond` se lanza con
`LD_PRELOAD` puesto. En los cuatro afectados se sustituyó además el `crond` en
marcha. La corrección del arranque no se ha probado con un reinicio real.

**Pendiente de ese cambio en sentinel016:** el agente Jupiter filtra por IP de
origen en dos capas —`TRADE_ALLOWED_IPS` en su `.env` y las reglas `DOCKER-USER`
de `deploy/firewall-sentinel016.sh`— y ambas siguen con `192.168.1.250`
(sentinel014) y `192.168.1.117` (laptop). Hasta que se actualicen a
`192.168.0.21` y `192.168.0.209` (el script exige `sudo`), el puerto 3011 solo
responde desde el propio sentinel016.

**Bypass de batería: ninguno lo soporta** (comprobado 2026-09-16). Ningún modelo
lo trae de fábrica —es cosa de móviles gaming—, **no hay root en ningún nodo**
(el `su` del PATH es el stub de Termux, responde "No su program found") y SELinux
bloquea `/sys/class/power_supply/` en los cinco equipos alcanzables. Las Fire HD
son las únicas que exponen el interruptor correcto, `en_power_path` bajo
`/proc/mtk_battery_cmd/` (el power-path de MediaTek), y es solo-root. El único
candidato posible sería el Pixel 6 por tener bootloader desbloqueable, y es
justo el móvil personal que viaja. OJO: `settings list global|secure` **no sirve**
para auditar topes de carga desde Termux — lanza SecurityException por
INTERACT_ACROSS_USERS y devuelve vacío, que parece un "no existe" y no lo es.

La laptop se llama **sentinel013** y no es nodo rqlite: corre el pm2 con 16 apps
(dashboards RPA en 3001-3013) y ahora el panel Sentinel SMS en 3014. Los RPA
Monitor han ido saliendo de ahí hacia sentinel020 (ver abajo); los procesos que
migran se borran del dump de pm2 con `pm2 delete` + `pm2 save`.

**sentinel020** (192.168.0.79 desde el 2026-10-04, antes 192.168.1.99 —
`ssh sentinel020` por llave, puerto 22) **tampoco
es nodo rqlite**: es el equipo donde se concentran los **RPA Monitor**. Windows 11
25H2, usuario `sentinel`, Ryzen 5 3500U, 15.4 GB RAM, `D:` con ~300 GB libres.
Node 23.11.0 en `%USERPROFILE%\node`, Git y Chrome oficial; **sin PM2**. Verificado
en vivo el 2026-09-22. Ver [Servicio 8](#servicio-8-rpa-monitor-en-sentinel020).

Nota: node-ids NO siguen el orden de los hosts — sentinel002 es node9 (node2 ya lo tenía sentinel003). Al añadir un nodo, usar el siguiente node-id libre, no el número del host. **Comprobar el id libre en vivo** con `curl -K ~/.config/rqlite/sentinel.curlrc 'http://<ip>:4001/nodes?nonvoters&pretty'`, no en esta tabla (sin `?nonvoters` no salen los no votantes).

Otras IPs del ecosistema: `IpWheel=192.168.0.209` (nodo "Wheel" que sirve
`/useragent` a los Sentinels).

## Servicio 1: WhatsApp_Checker (`whatsapp_checker/`)

- Ubicación real: `~/Herramientas/WhatsApp_Checker/` en sentinel001 **y en
  sentinel005** (2 instancias = 2 números de WhatsApp distintos). Mismo código,
  cada una con su propio `auth_info_baileys/` (sesión independiente). En
  sentinel005 el número es uno de Fanytel (VoIP) **1YYYYYYYYYY**; Node.js se
  instaló con `pkg install nodejs` (no venía). El número de sentinel001 es
  **1XXXXXXXXXX** (celular personal, solo checkNumberStatus).
- **sentinel005 corre la variante mejorada `whatsapp_chatbot/server.js`**
  (mirror en `whatsapp_chatbot/`) que combina el checker + un **chatbot de IA**
  en la misma sesión de Baileys (1YYYYYYYYYY). Detalles abajo.

### 1c. API del reloj `/watch/*` (sentinel001, alta 2026-08-26)

Extensión del checker para que el **Fossil Sport** (proyecto PRC Watch) lea y
conteste WhatsApp. Comparte forma exacta con el puente de Telegram (:8003) para
que el reloj pinte una bandeja unificada consultando dos APIs idénticas.

- Auth: cabecera `x-watch-token` contra `watch_token.txt` (600, junto a
  server.js), comparada con `timingSafeEqual`. Sin fichero, el API responde 503
  (cerrado por defecto, no abierto).
- `GET /watch/health` → `{ready, chats, ts}`
- `GET /watch/chats` → lista ordenada por recencia:
  `{jid, name, lastText, lastTs, lastFromMe, unread, group}`
- `GET /watch/messages?jid=<jid>&limit=N` → mensajes ascendentes; resetea el
  contador local de no-leídos. **No envía confirmaciones de lectura a WhatsApp**
  (decisión de privacidad: leer desde el reloj no marca el doble check azul).
- `POST /watch/send {jid, text}` → `jid` acepta dígitos pelados (se normaliza a
  `@s.whatsapp.net`). Límite **20 envíos / 10 min**; cada uno queda en
  `watch_audit.log`.
- Almacén `watch_store.json` junto a server.js: **60 mensajes × 40 chats**, poda
  por recencia. **NO se replica a rqlite**, igual que los SMS de Sentinel SMS: el
  texto de los mensajes no viaja a los 11 nodos.
- Se alimenta de `messages.upsert` (notify + append), `messaging-history.set`,
  `contacts.*` y `groups.upsert`.
- **GOTCHA — arranca sin historial**: Baileys corre sin `syncFullHistory`, así
  que el almacén solo se puebla con mensajes NUEVOS. Además, tras vincular se vio
  un `error in handling message` en un mensaje `category:peer` (probable
  notificación de history sync que no descifró). Si se quiere historial, hay que
  activar `syncFullHistory: true` y **volver a vincular**.
- **Sesión muerta 2026-08-26**: el checker llevaba tiempo en bucle `401
  loggedOut` (WhatsApp había desvinculado el dispositivo) y por eso NO generaba
  QR nuevo: con credenciales muertas en disco, Baileys nunca llega a emitirlo. Se
  arregló apartando `auth_info_baileys` → `auth_info_baileys.dead-20260826` y
  re-escaneando en `/scan`. Si `checkNumberStatus` empieza a dar 503, mirar esto
  primero.

## Servicio 1b: Chatbot IA (sentinel005) — `whatsapp_chatbot/`

- Extiende el checker: añade un handler `messages.upsert` que **solo responde a
  `OWNER_NUMBER`** (1XXXXXXXXXX, el celular personal) e ignora a todos los demás.
  Flujo: escribes desde tu celular al número Fanytel → el bot responde con IA.
- **Gemini** (misma API key que `D:\PRC Indeed`, en `.env` con `chmod 600`,
  cargada por `node --env-file=.env`): `gemini-2.5-flash` con fallback a
  `gemini-2.0-flash`, vía REST `generateContent`. Usa **function calling** con
  3 herramientas de solo lectura:
  - `estado_red` → `GET {RQLITE_API}/nodes` (nodos alcanzables, líder, quórum).
  - `esquema_bd` → tablas + nº de filas + DDL.
  - `consultar_bd(sql)` → `GET {RQLITE_API}/db/query` con guard SELECT/PRAGMA/WITH
    (rechaza escrituras), fallback `level=weak`→`none`.
- `RQLITE_API=http://192.168.0.166:4001` en el `.env`. Desde el 2026-07-05 rqlited
  escucha en `0.0.0.0`, así que localhost también valdría (antes no). Con contraseña
  (2026-11-11), el chatbot pregunta como `lector` con `RQLITE_USER` y `RQLITE_PASSWORD`
  en el mismo `.env` (ver `rqlite/auth/README.md`).
- **Memoria (2026-07-06)**: persiste en `chat_state.json` (junto a server.js):
  - **Esquema cacheado** (5 min) inyectado en el system prompt con columnas y
    nº de filas de cada tabla → el bot NO redescubre el esquema cada vez ni
    falla con nombres en español. Regla de mapeo español→inglés
    (título=title, empresa=company, ubicación=location, salario=salary…) y
    aviso de que `salary` es TEXTO libre ("$23 - $29 an hour"), no número.
  - **Historial de conversación** por remitente (últimos 6 intercambios) →
    entiende follow-ups ("y de esos dos, cuál paga más?").
  - **Preferencias persistentes** por remitente con tools `guardar_preferencia`
    / `olvidar_preferencia`; se inyectan en el system prompt y sobreviven
    reinicios (verificado). El `senderId` es el LID/número del remitente.
- Endpoints extra: `POST /ask {q, from?}` prueba el chatbot sin WhatsApp
  (`from` fija el senderId para probar memoria); `GET /` muestra
  `chatbot:{owner,gemini,usuarios_con_memoria}`. Handler en try/catch para no
  tumbar el checker. Backup del checker puro en `server.checker.bak.js`.
- Verificado (backend): estado de red, esquema de BD vacía, consulta SQL
  (`sqlite_version`→3.53.2) y checkNumberStatus, todo OK.
- **GOTCHA LID**: WhatsApp entrega `msg.key.remoteJid` como **LID**
  (`000000000000000@lid`), NO como `1XXXXXXXXXX@s.whatsapp.net`. El filtro del
  owner acepta `@lid` y `@s.whatsapp.net`; el LID del owner se resuelve al
  conectar con `sock.onWhatsApp(OWNER_NUMBER).lid` y hay respaldo `OWNER_LID`
  en el `.env`. Además se procesan los upsert type `append` (offline), no solo
  `notify`. Verificado end-to-end por WhatsApp el 2026-07-05.
- Node.js + Express + **@whiskeysockets/baileys** (WhatsApp Web por WebSockets
  puro, sin navegador). v2.0.0. Puerto **8002** (env `PORT`).
- Sesión persistida en `auth_info_baileys/` (multi-file auth state). Hay un
  `.wwebjs_auth/` legado de la v1 (whatsapp-web.js con navegador).
- Log: `wac.log` en la misma carpeta.
- Endpoints:
  - `GET /` — salud: `{service, ready, awaitingQr}`
  - `GET /qr` — PNG del QR de vinculación
  - `GET /scan` — página HTML de auto-refresco para escanear el QR
  - `GET /pair?number=<digits>` — vinculación por código de 8 dígitos
  - `POST /checkNumberStatus` — body `{args:{contactId:"<numero>@c.us"}}`.
    Usa `sock.onWhatsApp()` para validar existencia y `getBusinessProfile()`
    para marcar `isBusiness`. Respuesta imita el formato que espera el
    **parseador AWK** legado: `{"id":"...c.us","status":200,"isBusiness":...}`
    (status 200=existe, 404=no existe, 503=no vinculado).
- Consumidor típico:
  `curl -s -X POST http://sentinel001:8002/checkNumberStatus -H 'Content-Type: application/json' -d '{"args":{"contactId":"17147135677@c.us"}}'`
- **Supervisado por runit desde 2026-07-05**: servicio
  `$PREFIX/var/service/whatsapp_checker` en sentinel001 y sentinel005 (ver
  `runit_services/`), log con svlogd en
  `$PREFIX/var/log/sv/whatsapp_checker/current`. Baileys se reconecta solo
  salvo `loggedOut`. runsvdir lo levanta también tras reboot (boot script).
- Errores recurrentes en wac.log: `Timed Out` en init queries y
  `stream errored out` → ciclo close/reconnect código 500; se recupera solo.

## Servicio 2: rqlite (clúster de 11 nodos)

- Binarios: `~/go/bin/rqlited` y `~/go/bin/rqlite` (instalados con Go),
  versión API 10.
- Datos: `~/rqlite-data/` (db.sqlite + raft.db + wsnapshots). Log: `~/rqlited.log`.
- Lanzamiento (registrado en el log del 2026-06-30, node1):
  `~/go/bin/rqlited -node-id node1 -http-addr 192.168.1.69:4001 -raft-addr 192.168.1.69:4002 ~/rqlite-data`
  — HTTP API en **:4001**, Raft en **:4002**. node1 hizo bootstrap y
  node2..node5 se unieron como voters el 2026-06-30, node6 (sentinel014) y node7 (sentinel016) el 2026-07-07, y node8 (sentinel017) y node9 (sentinel002) el 2026-07-17.
- **node8 (sentinel017, 2026-07-17)**: Android/Termux aarch64, IP 192.168.1.212.
  rqlited/rqlite compilados desde el repo (`git clone --branch v10.2.5` + `go build`,
  porque el go.mod de v10.2.5 lleva directivas `replace` y `go install ...@v10.2.5` falla),
  Go 1.26.4. Supervisado por runit igual que los otros nodos Android. Termux:Boot +
  Caffeinate + optimización de batería desactivada aplicados 2026-07-17. Boot script
  `~/.termux/boot/00-services.sh` desplegado.
- **node9 (sentinel002, 2026-07-17)**: Android/Termux aarch64, IP 192.168.1.65. Mismo
  procedimiento que node8 (build v10.2.5 desde repo, Go 1.26.5, runit, boot script).
  Termux:Boot + Caffeinate + optimización de batería ya instalados. node-id node9
  porque node2 lo ocupa sentinel003.
- **node11 (sentinel019, 2026-07-24)**: Pixel 6, Android 17, Termux aarch64,
  IP 192.168.1.210, 229 GB de disco (~200 GB libres), sin SD. Termux limpio: se
  instalaron `golang git cronie termux-services termux-tools openssh` (termux-api y
  curl ya venían). Build de rqlite v10.2.5 desde el repo con Go 1.26.5 (mismo
  procedimiento que node8/node9). runit + Termux:Boot + thermal-guard desplegados.
  Se unió como voter y replicó el log completo (applied_index == last_log_index) en
  segundos; `level=strong` a través de él OK. node-id node11 = siguiente libre.
  **Ciclo de reboot verificado el 2026-07-24**: Termux:Boot levantó runsvdir, sshd,
  crond y rqlited sin tocar el teléfono, y volvió al clúster 7 s después de arrancar
  rqlited. Pero el arranque total fue de **~8 min** (hueco 22:12→22:20 UTC en la
  telemetría), no los 40-100 s de las Fire HD / Samsung — probablemente por el
  primer desbloqueo (hasta entonces Android mantiene cifrados los datos de la app
  y Termux:Boot no puede arrancar). No asumir que este nodo vuelve en segundos.
  Telemetría cada 2 min confirmada (deltas 119-121 s) y `activo=1` en la vista.
- **Supervisado por runit desde 2026-07-05** en los nodos Android/Termux (9 a 2026-07-24) y por **systemd (--user)** en los nodos Ubuntu (sentinel014 y sentinel016).
  - Android/Termux: servicio `$PREFIX/var/service/rqlited` (ver `runit_services/`), log con svlogd en `$PREFIX/var/log/sv/rqlited/current`.
  - Ubuntu (sentinel014/sentinel016): servicio de usuario systemd `~/.config/systemd/user/rqlited.service`, log con `journalctl --user -u rqlited`. Linger habilitado. **Copia local en [`systemd_services/`](systemd_services) desde 2026-07-26.**
  - Configuración del join: desde el 2026-10-30 todos apuntan a los tres votantes,
    `-join 192.168.0.21:4002,192.168.0.159:4002,192.168.0.166:4002` (014, 016 y
    005), quitando la propia. Con un único destino, si ese equipo está apagado un
    nodo que reinicia no arranca (`failed to join cluster`).
- **Cambio de subred y recuperación del clúster (2026-10-04).** Al pasar la LAN a
  `192.168.0.x` cada rqlited quedó `Candidate` viéndose solo a sí mismo: la
  configuración Raft guarda las direcciones de los 11 peers y todas eran
  `192.168.1.x`. Sin quórum no se puede cambiar la configuración por la vía
  normal, así que se recuperó con `peers.json` (procedimiento oficial de rqlite):
  1. Comprobar en `/status` que los nodos presentes tienen el **mismo**
     `last_log_index` y `term` (lo tenían: 4635878 / 5384).
  2. Parar rqlited en **todos** los que participan antes de arrancar ninguno.
     En sentinel009 `sv stop` se quedó colgado a medio apagar («want down, got
     TERM», puerto ya cerrado): hubo que matarlo por PID.
  3. Respaldo: `tar -cf ~/rqlite-data.bak-20261004.tar -C ~ rqlite-data`.
  4. `~/rqlite-data/raft/peers.json` idéntico en todos, con `id`, `address`
     (IP nueva `:4002`) y `non_voter:false` de los nodos presentes.
  5. Cambiar `-http-adv-addr`, `-raft-adv-addr` y `-join` en el arranque
     (`$PREFIX/var/service/rqlited/run` o la unidad systemd + `daemon-reload`).
  6. Arrancar todos a la vez. Líder en menos de un minuto.

  Se recuperó con cinco (003, 009, 010, 014, 018). Los que llegaron después
  **no necesitan `peers.json`**: basta corregir su arranque y reiniciar; al
  arrancar piden el join y el líder sustituye su dirección vieja (sentinel001,
  002, 005, 016 y 019 entraron así, conservando sus datos). Quedó en 11 voters.
  sentinel001 era el nodo de arranque y no llevaba `-join`; ahora lo lleva como
  los demás.
  **Ojo con un nodo muy atrasado**: sentinel016 llevaba tres días fuera y
  necesitó la copia completa (~355 MB por WiFi). Mientras sentinel014 se la
  enviaba perdió el contacto con el quórum y **dejó de ser líder**; el relevo
  fue limpio (sentinel010), pero el rqlited de 016 quedó sin responder hasta
  reiniciarlo. Reingresar nodos atrasados de uno en uno y comprobar después
  `applied_index` contra el líder. sentinel017 tenía el almacén roto desde el
  7/09 (`interrupted reap plan … data.db: no such file`): se apartó a
  `~/rqlite-data.corrupto-20261004` y entró limpio como node8.
  Respaldos del arranque original: `~/rqlited.run.bak-20261004` (Termux) y
  `~/rqlited.service.bak-20261004` (sentinel014).
- **2026-10-15/16: tormenta de elecciones por un snapshot de 410 MB.** sentinel002
  se atrasó más que `trailing_logs` (10240 entradas, ~4 h) y el líder tuvo que
  mandarle la base entera por WiFi 2,4 GHz. Los envíos fallaban (`snapshot reader
  idle timeout exceeded`), cada líder nuevo reintentaba y la red se saturaba:
  cambios de líder vistos desde 014, de 3-17/día a **439 el 15/10 y 548 el
  16/10** (término 5384 el 04/10 → 7319). Mientras tanto nadie escribía (huecos
  simultáneos de telemetría en todos los nodos) y el watchdog reiniciaba
  aceptadores (también en 014). Se agravaba porque los tiempos de Raft eran los
  de fábrica: un líder-teléfono dimitía solo con cualquier parón de 500 ms (105
  `failed to contact quorum of nodes, stepping down` en el log de sentinel001).
  **Cambio: `-raft-heartbeat-timeout=4s -raft-election-timeout=4s
  -raft-leader-lease-timeout=4s`** en el arranque, aplicado de uno en uno con
  `applied_index` y líder comprobados tras cada nodo: 001, 002, 003, 005, 009,
  010, 014, 017, 018, (21:20) 019 y (19/10) 016: los 11. Entre
  las 18:37 y las 21:19 hubo 4 elecciones, frente a ~15 por hora antes.
  Respaldo: `run.bak-20261016` junto al `run` (Termux) y
  `rqlited.service.bak-20261016` (014).
- **2026-10-30: solo 3 nodos con voto**, decisión del dueño: los de mayor permanencia
  y potencia. Votan **sentinel014 (node6), sentinel016 (node7) y sentinel005 (node3)**;
  el resto replica con `-raft-non-voter=true`. Suplente: sentinel009. Quórum: 2 de 3,
  o sea que **aguanta la caída de un solo votante**; con dos caídos nadie escribe.
  Elegidos con datos de ese día (tiempo fuera según `sentinel_temp`; potencia = tiempo
  de un bucle de 3 millones en gawk):

  | Nodo | Fuera 90 d (min) | Fuera 30 d (min) | Bucle (ms) | RAM (GB) |
  |---|---|---|---|---|
  | sentinel014 | 464 | 395 | 356 | 7,4 |
  | sentinel016 | 24.547 | 24.327 | 464 | 7,7 |
  | sentinel005 | 479 | 451 | 828 | 3,7 |
  | sentinel009 | 453 | 441 | 1984 | 1,8 |
  | sentinel010 | 507 | 484 | 2004 | 1,8 |
  | sentinel003 | 17.779 | 430 | 964 | 3,7 |
  | sentinel001 | 2.215 | 788 | 1910 | 2,7 |
  | sentinel002 | 3.629 | 3.582 | 1596 | 3,6 |
  | sentinel018 | 24.470 | 1.406 | 1882 | 2,7 |
  | sentinel019 | 48.482 | 7.323 | 805 | 7,6 |

  sentinel016 es la apuesta: es el segundo más potente, pero su historial es malo. Pasó
  ~13 días fuera en octubre, cuando el agente Jupiter lo llevaba a 80-89 °C; se retiró
  el 19/10 y desde entonces da 1426-1440 filas al día, a 44-51 °C. Si vuelve a caerse,
  cambiarlo por sentinel009, que tiene la mejor permanencia pero solo 1,8 GB de RAM.
  sentinel019 no se consideró: es el móvil personal y sale de casa.
  - **`/nodes` solo lista los nodos con voto.** Quien quiera la flota entera debe pedir
    `/nodes?nonvoters`. Sin eso, las alertas y la elección de Wheel habrían perdido de
    vista a 7 teléfonos en silencio; por eso se cambiaron antes `Sentinel-Wheel.awk`,
    `Sentinel-Alert.sh` y `toolEstadoRed` del chatbot, que además cuenta el quórum solo
    entre votantes. Lo mismo vale para cualquier script nuevo.
  - **Quitarle el voto a un nodo** (de uno en uno; 9-15 s y sin elecciones):
    1. Añadir `-raft-non-voter=true` al `run` (respaldo `run.bak-20261030`).
    2. `sv -w 60 down rqlited`
    3. `curl -K ~/.config/rqlite/admin.curlrc -XDELETE http://192.168.0.21:4001/remove -d '{"id":"nodeN"}'`
       (desde la laptop, que es donde vive `admin.curlrc`). Antes de arrancar, cambiar
       también su `auth.json` por el de no votante, o por el de votante si gana el voto.
    4. `sv up rqlited` y comprobar en `/nodes?nonvoters` que sale `voter:false`.

    El `/remove` es obligatorio: si el id y la dirección ya están en el clúster, rqlite
    ignora el join y el nodo seguiría votando. **Dar el voto** es lo mismo, quitando el
    flag.
  - **Mover al líder:** `curl -K ~/.config/rqlite/admin.curlrc -XPOST http://<ip-del-lider>:4001/leader -d '{"id":"node6"}'` (desde la laptop).
    Ojo: en el líder surte efecto al instante, no es una consulta.
  - **Pendiente: sentinel017.** Se quitó del clúster estando caído, sin poder cambiar su
    `run`, así que **al volver entrará como votante** y serían 4, con quórum de 3. En
    cuanto reaparezca hay que aplicarle el procedimiento de arriba y copiarle
    `Sentinel-Wheel.awk` y `Sentinel-Alert.sh`. Mientras no esté en el clúster, las
    alertas no lo vigilan: su lista sale de `/nodes`.
- 2026-07-07: quórum restaurado y ampliado — los 7 nodos vivos, node5 líder,
  `SELECT 1` con `level=strong` OK.
- 2026-07-24: 11 nodos, todos `voter` y `reachable`; líder **node8 (sentinel017)**.
  El líder rota — no dar por hecho que es node5; consultar `/nodes` antes de
  diagnosticar.
- **BIND 0.0.0.0 (2026-07-05, causa raíz de caídas post-reboot)**: rqlited
  se vinculaba a `<IP>:4002`. En los teléfonos inactivos (node2/4/5), Android
  recicla la IP del WiFi durante el doze; el socket de escucha atado a esa IP
  MUERE y no se re-vincula → el proceso sigue vivo (hace Raft saliente, ping y
  TCP saliente OK) pero **nadie puede conectarse a sus puertos** (ni él mismo:
  `curl` a su propia IP:4001 da "connection refused"), y el nodo se cae del
  clúster. Diagnóstico: proceso up + `/proc/net/tcp` no legible en Android +
  outbound OK + inbound refused. Fix: `-http-addr 0.0.0.0:4001 -http-adv-addr
  <IP>:4001 -raft-addr 0.0.0.0:4002 -raft-adv-addr <IP>:4002`. El listener en
  0.0.0.0 sobrevive a que la IP desaparezca/regrese. Aplicado en los 5 nodos.
  Defensa adicional: mantener Caffeinate/Keep Screen On activos en node2/4/5
  (los que dozean) para que el WiFi no se apague del todo.
- **Contenido de la BD (verificado 2026-07-21)** — ya NO está vacía:
  - `indeed_jobs` (pipeline PRC Indeed).
  - Telemetría: `sentinel_temp` y `sentinel_disk` (1 fila/nodo/minuto,
    retención 90 días, ~42k filas c/u) + vista `v_sentinel_estado`
    (última lectura por nodo: temp, disco, activo).
  - Lotería: `sorteo`, `premio`, `archivo`, `catalogo_web`, `prediccion`,
    `calidad_sorteo`, `equidad`, `no_encontrado`, `corrida`.
- **GOTCHA 'now' en DDL (2026-07-21)**: rqlite reescribe funciones no
  deterministas (`strftime('%s','now')`, `datetime('now')`, `RANDOM()`) a
  **constantes** antes de pasarlas por Raft. Un `CREATE VIEW` o `DEFAULT` con
  `'now'` queda congelado al instante de creación (pasó en `v_sentinel_estado`
  → `activo` siempre 1, y en el DEFAULT de `sorteo.creado_en` — ambos
  corregidos el 2026-07-21; `sorteo` se recreó SIN default y conservó sus
  1033 filas). En vistas, comparar contra `(SELECT MAX(ts) FROM tabla)` en
  vez de 'now'. Para timestamps de creación: mandar la fecha en el propio
  `INSERT` — ahí sí se puede usar `datetime('now')`, porque rqlite lo congela
  por sentencia al hacer commit (igual en todas las réplicas).
- **Fix v_sentinel_estado (2026-07-21)**: la vista original tardaba 17.5 s
  (subconsulta correlacionada `MAX(id)` por fila sin índice en (node,id)) y el
  chatbot aborta a los 8 s → timeouts al preguntar temperatura/estado. Se
  recreó con el patrón `JOIN (SELECT node, MAX(ts) ... GROUP BY node)` que usa
  `idx_temp_node_ts`/`idx_disk_node_ts`: ahora responde en ~0.1 s y `activo`
  se calcula contra el MAX(ts) de la tabla. Regla: toda consulta que use el
  chatbot debe terminar muy por debajo de 8 s (`AbortSignal.timeout(8000)`).
- Consultas útiles (con contraseña desde el 2026-11-11: `-K ~/.config/rqlite/sentinel.curlrc`,
  que está en la laptop y en cada nodo y vale contra votantes y no votantes):
  - `curl -K ~/.config/rqlite/sentinel.curlrc 'http://<ip>:4001/status?pretty'`
  - `curl -K ~/.config/rqlite/sentinel.curlrc 'http://<ip>:4001/nodes?nonvoters&pretty'`
  - `curl -K ~/.config/rqlite/sentinel.curlrc -G '<ip>:4001/db/query' --data-urlencode 'q=SELECT ...' --data-urlencode 'level=none'`
    (`level=none` responde aunque no haya quórum)

## Servicio 3: PRC_Sentinel (`prc_sentinel/`)

- Ubicación real: `~/PRC_Sentinel/` en sentinel001 (estructura estándar de los
  PRC: `Script/ Datos/ Log/ Run/ Temporal/`).
- **Servidor HTTP escrito en gawk puro** (`Sentinel-Server.awk`), multi-clon:
  un proceso gawk por puerto en **8081–8100** (20 clones). El clon en 8081 es
  el "EYE" (coordinador: expone `/listclone`, `/enableclone/<port>`,
  `/sentinelversion`, `/useragent`, redirige trabajo a otros clones).
- `Sentinel-Clone.sh` + `Sentinel-Clone.awk`: watchdog vía **crontab cada
  minuto** (`* * * * *` y `@reboot`): comprueba `/sentinelversion` de cada
  clon, mata duplicados y clones colgados (>300 s) y relanza los muertos.
  Multi-OS: detecta Termux/Ubuntu/Raspberry/Tiny/Windows.
- `Sentinel-Client.awk`: cliente TCP crudo (`/inet4/tcp/...`) que sigue
  redirecciones "Redirect to port NNNN" entre clones.
- `Sentinel-Search.awk`: lógica de búsqueda/scraping usada por el servidor.
- Config por entorno en `~/.profile`: `PathSentinel`, `MyIP=192.168.0.231`,
  `OS=Termux`, `UserAgent`, `IpWheel=192.168.0.209`, `Name=Sentinel001`.
- Datos calientes en `Datos/Hot.db` (SQLite).
- Relación histórica: `Run/` enlaza a scripts de `PRC_Crypto_Trends`
  (precios del order book de Binance, hoy comentados en el crontab).

## Servicio 4: RPA Monitor Extron (sentinel014) — ⚠️ OBSOLETO

> **Extron ya no corre en sentinel014.** Comprobado en vivo el 2026-09-22:
> `rpa-extron-cycle.timer` no aparece en `systemctl --user list-timers` y
> `rpa-extron-dashboard` está `inactive`; sentinel014 solo mantiene rqlite y los
> timers `sentinel-v2-*`. El RPA se movió a **sentinel020**, donde corre con el
> Programador de tareas (`RPA Extron - Monitoreo` → `Script\cycle.cmd`,
> `RPA Extron - Ampronix`, `RPA Extron - Panel` en `:3008`).
>
> Lo de abajo se conserva como **registro histórico** del montaje en Ubuntu —
> sigue siendo la referencia para los gotchas de Bright Data y las unidades
> systemd. Lo que ya no describe es dónde corre hoy.
>
> **Corrección 2026-10-04:** el túnel ya tampoco está en sentinel014. Desde el
> 2026-09-24 corre en sentinel020 como servicio de Windows, con los destinos en
> `localhost` (ver [`cloudflared/`](cloudflared)). El párrafo siguiente describe
> el estado del 22/09.
>
> **El túnel sí sigue en sentinel014 y está sano** (verificado 2026-09-22):
> `cloudflared` `active`, y su `/etc/cloudflared/config.yml` ya estaba reapuntado
> a `http://192.168.1.99:3008` — sentinel020. `https://extron.batchtoday.us`
> devuelve 401 del Express real. Es decir, **sentinel014 quedó como pura puerta
> de entrada**: enruta pero no sirve nada (nada escucha en su 3008). Lo que
> estaba obsoleto era la copia del repo, ya reconciliada en
> [`cloudflared/`](cloudflared).

- Migrado desde la PC el 2026-07-20. Código en `~/RPA_Monitor_Extron` (fuente
  original y assets históricos de 6.5 GB: `D:\RPA Monitor Extron` en la laptop).
- Node 20 vía nvm (`~/.nvm/versions/node/v20.20.2`). Disco extendido con lvextend
  (LV ahora 26 GB, ~19 GB libres).
- systemd user: `rpa-extron-cycle.timer` (06:00 y 18:00 hora local del nodo,
  America/Los_Angeles) + `rpa-extron-dashboard.service` (puerto **3008**).
  Logs: `journalctl --user -u rpa-extron-cycle`.
  **Copia local de las tres unidades en [`systemd_services/sentinel014/`](systemd_services/sentinel014)
  desde 2026-07-26.** Invocan Node por ruta absoluta a `~/.nvm/.../v20.20.2/bin/node`:
  si esa versión desaparece del nodo, fallan sin explicar por qué.
- Todo el tráfico a extron.com sale por **Bright Data Scraping Browser** (CDP,
  `BRD_WSS` en el `.env`, $4/GB): la IP pública de la casa está cloaked por
  Extron (página de mantenimiento falsa con HTTP 200). Solo detecta/scrapea
  productos NUEVOS (monitor.js retirado); publica a Gurus/Shopify y enriquece
  con Grok. Costo proxy estimado <$1/mes.
- GOTCHA BRD: `ctx.request` de Playwright NO tuneliza por connectOverCDP (sale
  por la IP local) — binarios vía fetch same-origin en página remota anclada o
  navegación directa; `/download/` de www redirige a `media.extron.com/public/`.
- **Alertas Telegram**: cada ciclo publica en el grupo de alertas rqlite (mismo
  bot que thermal-guard; `TG_BOT_TOKEN`/`TG_CHAT_ID` en el `.env` del RPA,
  copiados de `~/PRC_Thermal/thermal-guard.conf`): resumen estado + nº de
  productos nuevos, y aviso inmediato por paso fallido. Mensajes en inglés.
- **Dashboard público**: `https://extron.batchtoday.us` vía **Cloudflare Tunnel**
  (`rpa-extron`, id <TUNNEL-UUID>, servicio systemd de sistema `cloudflared`, config
  en `/etc/cloudflared/config.yml`, cert en `~/.cloudflared/`) → localhost:3008.
  **Copia local de la config y la unidad en [`cloudflared/`](cloudflared) desde
  2026-07-26** (la credencial del túnel NO se copió: es un secreto). El mismo
  túnel publica `ampronix.batchtoday.us` → `192.168.1.117:3013`, o sea que
  sentinel014 es la puerta de entrada del dashboard que corre en la laptop.
  Basic Auth en el propio Express (`DASH_USER`/`DASH_PASS` en el `.env`).
  Cero puertos abiertos: túnel saliente, inmune a cambios de IP residencial.
- La BD `Datos/Hot.db` del nodo es LA VIVA desde el 2026-07-20; la de la PC
  quedó congelada como respaldo histórico.

## Alta de un nodo nuevo (checklist, validado en sentinel019 / 2026-07-24)

El alta **no termina cuando rqlite se une al clúster**: hay pasos en otros
dispositivos. Orden probado:

1. **En el teléfono, a mano** (no se puede por SSH): instalar Termux, Termux:API
   y Termux:Boot, abrir Termux:Boot **una vez**, quitar la optimización de
   batería a Termux, y activar Caffeinate / Keep Screen On.
2. **Llave SSH**: `ssh-copy-id -p 8022 -i ~/.ssh/id_ed25519.pub sentinel@<IP>`
   (o pegar la pública en `~/.ssh/authorized_keys` del teléfono). Sin esto no se
   puede hacer nada remoto. Añadir el `Host sentinel0NN` al `~/.ssh/config` de
   la laptop (`Port 8022`, `IdentityFile id_ed25519`, `IdentitiesOnly yes`).
3. **Paquetes**: `pkg install -y golang git cronie termux-services termux-tools
   openssh` (`termux-api` y `curl` suelen venir de fábrica).
4. **`~/.profile`** (600) con `Name=Sentinel0NN`, `MyIP=<IP>`, `OS=Termux`,
   `IpWheel`, `UserAgent`, `IP_Simulador`.
5. **Build de rqlite**: `git clone --depth 1 --branch v10.2.5` + `go build -o
   ~/go/bin/ ./cmd/rqlited ./cmd/rqlite`. `go install ...@v10.2.5` **falla** por
   las directivas `replace` del go.mod.
6. **Servicio runit** `$PREFIX/var/service/rqlited/{run,log/run}` con el
   **siguiente node-id libre según `/nodes?nonvoters` en vivo**, bind `0.0.0.0` +
   adv addr y `-raft-non-voter=true`: un nodo nuevo entra sin voto. Desde el
   2026-11-11 el `run` lleva también `-auth ... -join-as nodo` (plantilla en
   `runit_services/rqlited.run.sh`), y **antes de arrancarlo** hay que copiarle
   `~/.config/rqlite/auth.json` (el de no votante) y `sentinel.curlrc`, los dos en 600:
   ver [`rqlite/auth/README.md`](../rqlite/auth/README.md). Sin `auth.json` rqlited
   no arranca, y sin `sentinel.curlrc` sus scripts reciben 401.
7. **Boot**: `~/.termux/boot/00-services.sh`. Arrancar con
   `. $PREFIX/etc/profile.d/start-services.sh` (con `SVDIR` exportado).
8. **thermal-guard**: copiar `thermal-guard.sh` + `.conf` desde otro nodo
   Android, `echo node<N> > ~/PRC_Thermal/.raft_id`, y el cron cada minuto.
9. **Chatbot en sentinel005** (`~/Herramientas/WhatsApp_Checker/server.js`):
   añadir el nodo al `NODE_MAP` **y** actualizar el conteo y la lista de hosts
   del `SYSTEM_BASE` (si no, el bot sigue diciendo que hay N-1 nodos).
   `node --check server.js` y `sv restart whatsapp_checker`; Baileys se
   reconecta sin re-escanear QR.
10. **Verificar**: `/nodes` lo muestra `voter`+`reachable`, `applied_index ==
    last_log_index` en su `/status`, `level=strong` a través de él, una fila
    suya en `sentinel_temp`/`sentinel_disk`, y que aparece en
    `v_sentinel_estado`. Refrescar este README.

## Servicio 5: thermal-guard (todos los nodos Android) — `prc_thermal/`

Es el **productor** de la telemetría que alimenta `sentinel_temp`/`sentinel_disk`
y la vista `v_sentinel_estado`. Sin él, un nodo nuevo se une al clúster pero
nunca aparece en el dashboard ni en las respuestas del chatbot.

- Ubicación real: `~/PRC_Thermal/thermal-guard.sh` (700) + `thermal-guard.conf`
  (600, lleva `BOT_TOKEN`/`CHAT_ID` de Telegram — **no está en el mirror**).
  **Al propagarlo, `scp -p` + `chmod 600`**: sin `-p`, el fichero se crea con la
  umask del *destino*, y así los dos Ubuntu acabaron en 664 (umask 002) mientras
  los Termux quedaban en 600 (umask 077). Corregido el 2026-08-16 y verificado
  en los 11 nodos.
  Cron cada minuto: `* * * * * ~/PRC_Thermal/thermal-guard.sh >/dev/null 2>&1`.
  **Excepción: sentinel019 corre `*/2` (cada 2 min)** — es el celular personal y
  se le quiso bajar la carga. El límite es la ventana de `activo` de la vista
  `v_sentinel_estado` (**180 s**): cualquier intervalo por encima de 3 min hace
  que el nodo se vea "inactivo" aunque esté sano. Si algún día se quiere bajar
  más, hay que recrear la vista con una ventana mayor (y ojo con el gotcha de
  `'now'` en DDL: comparar contra `(SELECT MAX(ts) FROM sentinel_temp)`).
- Lee la temperatura con `termux-battery-status` (requiere **Termux:API**), con
  fallback a `/sys/class/thermal/thermal_zone0/temp`, y el disco con `df -Pk`
  (interno + SD si existe en `~/storage/external-1`). Inserta una fila en cada
  tabla por minuto contra `http://localhost:4001` — funciona porque rqlited
  bindea a `0.0.0.0`.
- El nombre del nodo sale de `Name` en `~/.profile` **pasado a minúsculas**
  (`Sentinel019` → `sentinel019`): tiene que casar con el `NODE_MAP` del chatbot
  y con lo que ya hay en las tablas. El `raft_node_id` se cachea en
  `~/PRC_Thermal/.raft_id` (se extrae del cmdline de rqlited la primera vez; en
  un alta conviene escribirlo a mano para no depender de eso).
- Umbrales (`WARN 45` / `CRIT 50` / `EMERG 55` / `REARM 42`, `MINGAP 900`): a
  CRIT mata la carga de Sentinel y suelta el wake-lock para enfriar; a EMERG
  además baja `rqlited`; al bajar de REARM restaura ambos. Alertas a Telegram
  con rate-limit por nivel.

## Servicio 6: Sentinel SMS — `sentinel_sms/`

Panel web para leer y enviar SMS, ver el historial de llamadas y marcar, sin
tocar el teléfono. Alta 2026-07-24. **Dos procesos**, uno en cada máquina:

```
navegador -> [laptop sentinel013 :3014, pm2] -> túnel SSH -> [sentinel019 127.0.0.1:8010, pm2]
```

El backend tiene que vivir en el teléfono porque Termux:API solo funciona en el
dispositivo; el panel vive en la laptop, que es donde está el pm2 de siempre.

### 6a. Backend en el teléfono — `sentinel_sms/telefono/`

- Ubicación real: `~/Sentinel_SMS/` en sentinel019. Node.js 26.4.0 + Express 5.
- Puerto **8010 en `127.0.0.1` únicamente**: no está expuesto en la WiFi. La única
  entrada es el túnel SSH, que exige la llave de la laptop.
- Supervisado por **pm2 7.0.3** — el único proceso de la flota bajo pm2 en Termux;
  el resto usa runit o systemd.
  - **GOTCHA pm2 en Termux**: `pm2 startup` NO sirve (no hay systemd). El arranque
    tras reboot es un `pm2 resurrect` explícito al final de
    `~/.termux/boot/00-services.sh`, que relee `~/.pm2/dump.pm2`. **Si se añade o
    quita un proceso hay que volver a hacer `pm2 save`** o el reboot lo pierde.
- Seguridad: Basic Auth propio + `X-Action-Token` para enviar SMS y llamar, con
  límite de tasa (10 acciones / 10 min). Todo envío o llamada queda en
  `~/Sentinel_SMS/audit.log`. Los comandos se lanzan con `execFile` + array de
  argumentos, nunca por shell. `.env` en 600.

### 6c. Acceso desde fuera de casa — INTENTADO Y REVERTIDO (2026-07-25)

**Estado: no existe. Se montó, se probó, y se decidió revertirlo el mismo día
para no exponer los SMS a internet.** El servicio vive solo en la LAN, servido
desde la laptop. Esta sección se conserva porque lo aprendido vale para el
próximo intento; nada de lo que describe está desplegado ahora mismo.

Revertido en batchtoday: servicio systemd eliminado, `~/sentinel-sms` borrado,
`cloudflared` purgado, llave del móvil fuera del `authorized_keys` y
`sshd_config` restaurado. En el móvil: servicio runit `tunel-batchtoday` y llave
`id_batchtoday` eliminados. Verificado con conexión nueva tras recargar sshd.

**Por qué exponerlo da respeto**: detrás de esa URL están los SMS, que es por
donde llegan los códigos de verificación del banco y de las cuentas. Quien tenga
la URL y la contraseña puede leer cada OTP y enviar SMS desde ese número. No es
comparable al dashboard de Extron. Si se retoma, **Cloudflare Access delante del
hostname** antes que nada — identidad real en vez de una contraseña compartida.

El diseño que funcionaba, para no rehacerlo desde cero:

El montaje de la laptop solo sirve dentro de casa: abre el túnel **hacia** el
móvil por su IP de LAN. En cuanto el teléfono sale del WiFi y pasa a datos
móviles, queda detrás del **CGNAT del operador** y no admite ninguna conexión
entrante — ni desde la laptop ni desde sentinel014. Por eso el acceso público
tiene que ir al revés: **el móvil abre el túnel hacia fuera**.

```
navegador  →  Cloudflare  →  cloudflared (batchtoday)  →  127.0.0.1:3014  app web
                                                             ↓ 127.0.0.1:18010
                                        ssh -R abierto DESDE sentinel019
                                                             ↓
                                        backend Termux del móvil, 127.0.0.1:8010
```

- **Por qué batchtoday y no sentinel014**: sentinel014 está en la LAN de casa, así
  que cualquier cosa anclada ahí depende de la red doméstica. batchtoday es la
  EC2 (18.221.108.18) con IP pública y siempre encendida, así que el camino no
  pasa por casa en ningún punto.
- **Túnel en el móvil**: servicio runit `$PREFIX/var/service/tunel-batchtoday`
  (mirror en `sentinel_sms/telefono/tunel-batchtoday.run.sh`), con
  `ServerAliveInterval=20`/`CountMax=3` para detectar la caída en ~60 s y un
  `sleep 5` al principio del `run` como suelo entre reintentos — runit relanza
  al instante y sin eso un fallo persistente daría un bucle cerrado.
- **Llave dedicada y restringida**: `~/.ssh/id_batchtoday` en el móvil, y en el
  `authorized_keys` de batchtoday entra como
  `restrict,port-forwarding,permitlisten="127.0.0.1:18010"` → **no da shell y
  solo puede abrir ese reenvío**. Si el teléfono se perdiera, esa llave no sirve
  para nada más. `GatewayPorts no` en batchtoday mantiene el puerto en loopback.
- **App en batchtoday**: `~/sentinel-sms/`, servicio systemd de sistema
  `sentinel-sms` (habilitado al arranque), puerto 3014 en loopback.
  `DASH_PASS` propio y distinto del de la laptop — es el que queda expuesto.
- **GOTCHA Node 18 en batchtoday**: no soporta `--env-file` (llegó en la 20.6).
  El `server.js` trae su propio cargador de `.env`, que además no pisa lo que ya
  venga del entorno, así que el mismo fichero arranca igual en la laptop (Node
  23) y ahí. Por eso `ecosystem.config.js` ya no necesita `node_args`.
- **`TUNEL=externo`** en el `.env` de batchtoday: la app no abre el túnel, lo
  espera. Sondea `127.0.0.1:18010` cada 20 s y da el túnel por vivo con
  cualquier respuesta HTTP, incluido el 401.
- **GOTCHA CRÍTICO — el puerto reenviado se queda retenido (2026-07-25)**:
  batchtoday venía con `ClientAliveInterval 0`, así que sshd **nunca** comprueba
  si el cliente sigue vivo. Al morir el móvil de golpe, su sesión sshd quedaba
  huérfana **reteniendo el 18010 en LISTEN**, y el túnel nuevo moría al instante
  con `Error: remote port forwarding failed for listen port 18010`, en bucle.
  Medido: 26 minutos y seguía bloqueado; el límite real habría sido el keepalive
  TCP del kernel, 2 horas. Y es exactamente el escenario para el que se montó
  esto: al pasar de WiFi a datos móviles la conexión muere sin cierre limpio.
  Arreglado con `ClientAliveInterval 30` + `ClientAliveCountMax 2` en
  `/etc/ssh/sshd_config` de batchtoday (backup en `sshd_config.bak-20260725`,
  validado con `sshd -t` y aplicado con `reload`, no `restart`, para no tirar las
  sesiones abiertas). Ahora la recuperación está acotada a ~90 s en el peor caso
  y fue de 8 s en la prueba con cierre limpio.
  **Si algún día el túnel no vuelve, mirar primero si el puerto está retenido**:
  `sudo ss -ltnp | grep 18010` en batchtoday, y matar esa sesión sshd concreta.

### 6b. Cliente de SMS en la laptop — `sentinel_sms/laptop/`

- Ubicación real: `D:\Sentinel SMS\` en sentinel013 (la laptop). Puerto **3014**
  en `127.0.0.1`, siguiendo la convención 30xx del resto de dashboards del pm2.
- **Solo SMS** (decidido 2026-07-24). Una sola vista: lista de conversaciones a
  la izquierda, hilo a la derecha, compositor abajo. Los contactos siguen ahí
  pero únicamente como autocompletado del destinatario, no como sección.
  En pantallas estrechas la lista y el hilo se turnan con un botón «volver».
- Enviar exige el `X-Action-Token` además de la Basic Auth, con un diálogo de
  confirmación que muestra destinatario, nº de segmentos y el texto completo.
- **Nombre y número siempre juntos**, nunca uno en lugar del otro: en la lista de
  conversaciones, en la cabecera del hilo, en cada ficha de destinatario y en el
  diálogo de confirmación. Si el número no está en la agenda lo dice.
- **Envío a varios destinatarios** (2026-07-24). El backend ya lo soportaba
  (`termux-sms-send -n a,b,c` y el validador recorre la lista), faltaba la
  interfaz: fichas con nombre + número y su «×», que se cierran con Enter, coma,
  punto y coma o Tab; Retroceso con el campo vacío quita la última; pegar
  «600111222, 600333444» crea una ficha por número. Máximo 20.
  - **Deduplica por los últimos 9 dígitos**, así que el mismo contacto en dos
    formatos (`+1XXXXXXXXXX` y `XXXXXXXXXX`) no se cuela dos veces ni se paga
    dos veces.
  - La línea bajo las fichas dice **el coste real**: `N destinatarios × M
    segmentos = total SMS`. Con varios destinatarios es fácil no darse cuenta.
  - Al enviar a varios no hay hilo al que pertenezca el mensaje, así que en vez
    de una burbuja se muestra un acuse con la lista completa.
- **BUG corregido en `normalizarNumero()` (2026-07-24)**: la expresión regular
  exigía que el primer carácter fuese dígito o `+`, así que **rechazaba en
  silencio los números guardados como `(714) 261-3196` — 27 de los 367 contactos
  de la agenda**. Y el cuantificador `{3,24}` imponía un mínimo de 5 caracteres,
  contradiciendo la comprobación de longitud de debajo, que decía admitir 3
  dígitos: los códigos cortos tipo `911` nunca pasaban. Ahora es
  `/^\+?[0-9(][0-9\s()\-.]{2,24}$/` **en los dos lados**. Hay una prueba que
  extrae el validador del navegador y el del teléfono y los compara sobre la
  misma batería de entradas: si divergen, la interfaz aceptaría destinatarios
  que el backend devuelve con 400 después de haber redactado el mensaje.
- **Corrector ortográfico en dos capas.** El nativo del navegador
  (`spellcheck="true" lang="es"` en el textarea) cubre las faltas normales; una
  capa propia cubre su punto ciego, las tildes perdidas al escribir rápido:
  - **Seguras** (~90 entradas + regla de sufijo): la forma sin tilde no es una
    palabra válida, así que se corrigen sin riesgo. Hay un «aplicar las seguras».
  - **Dudas** (`mas`, `aun`, `anos`, `esta`, `estas`): dependen del contexto, se
    sugieren con borde discontinuo y **quedan fuera** del «aplicar todas».
  - Regla de sufijo **`-ion` → `-ión`** (informac**ión**, reun**ión**, cam**ión**,
    reg**ión**). Cubre más que `-ción`/`-sión` por separado — «reunión» no es
    ninguna de las dos y se escapaba. **Solo el singular**: el plural pierde la
    tilde (*reuniones*, *informaciones*), así que una regla para `-iones` sería
    un error. Verificado con un caso de prueba dedicado.
  - Al aplicar varias correcciones se recorren **de atrás hacia delante**: de
    izquierda a derecha, cada sustitución desplaza los índices de las siguientes.
- **Retirado el 2026-07-24**: la consola de voz con Gemini y la vista de
  llamadas. El HTML quedó en `D:\Sentinel SMS\_retirado\` y la clave de Gemini
  se borró de ese `.env` porque ya no hace falta ahí. **Los endpoints de
  llamadas del teléfono siguen intactos** (`/api/calls`, `/api/call`): solo
  dejaron de pintarse.
- Lecciones que dejó la consola de voz, por si vuelve:
  - `gemini-2.5-flash` devuelve **404 NOT_FOUND** con esta clave pese a aparecer
    en `/v1beta/models`, y `gemini-2.0-flash` tiene el free tier agotado (429
    `generate_content_free_tier_requests`). Verificados OK con function calling:
    `gemini-3.6-flash`, `gemini-3.5-flash`, `gemini-flash-latest`,
    `gemini-3-flash-preview`. **El chatbot de sentinel005 sigue pidiendo
    `gemini-2.5-flash`** y solo sobrevive por su fallback: conviene actualizarlo.
  - **`thought_signature` de Gemini 3**: al devolver a la API la parte
    `functionCall` del modelo hay que empujar el objeto `candidates[0].content`
    **original**, no un `{functionCall: ...}` reconstruido. Si se pierde la firma,
    la siguiente petición falla con `400 Function call is missing a
    thought_signature in functionCall parts`. Cambio respecto a Gemini 2.x.
  - `getUserMedia` y `SpeechRecognition` exigen contexto seguro: `127.0.0.1`
    vale, la IP de LAN no. El cliente de SMS ya no usa micrófono, así que ese
    límite dejó de aplicar y `BIND` puede abrirse a la LAN si hiciera falta.
- Registrado en el **pm2 de la laptop como `red-sms-dashboard`**. Ese daemon
  corre **elevado**: desde una shell normal `pm2` falla con
  `connect EPERM //./pipe/rpc.sock`. Hay que lanzar `pm2 start` / `pm2 save`
  desde una terminal de administrador.
- Mantiene el túnel `ssh -N -L 127.0.0.1:18010:127.0.0.1:8010` vivo por su cuenta
  (respawn con backoff exponencial 2 s → 60 s, `ServerAliveInterval=15` para
  detectar el móvil sin WiFi en ~45 s). No hace falta autossh.
- Hace de proxy de `/api/*` añadiendo la Basic Auth del backend. Valida su propia
  Basic Auth de cara al usuario; el token de acción lo sigue validando el teléfono.
  `GET /api/tunnel` da el estado del túnel y el panel lo muestra en la cabecera.
- **GOTCHA `--env-file` de Node**: trata la barra invertida como escape, así que
  `SSH_KEY=C:\Users\ariel\...` llega como `C:Usersariel...` y ssh cae de vuelta a
  la llave por defecto sin decir nada útil. Usar **barras normales** en el `.env`.
- **Los SMS NO se persisten en rqlite** (decisión de 2026-07-24): se leen en vivo
  del teléfono para no replicar el texto de los mensajes a los 11 nodos.
- **GOTCHA Termux:API concurrente**: dos comandos `termux-*` a la vez se pisan —
  el segundo falla con `Command failed` y stdout vacío (se vio en `/api/health`
  lanzando `sms-list` y `call-log` en `Promise.all`). El servidor los serializa
  todos por una cola en serie.
- **GOTCHA permisos restringidos de Android**: SMS y registro de llamadas son
  *restricted permissions*; en apps que no vienen de Play Store (Termux:API es de
  F-Droid) Android los bloquea con el diálogo "App was denied access / puede poner
  en riesgo tu info personal y financiera". Se desbloquea en **Ajustes → Apps →
  Termux:API → menú ⋮ → Permitir ajustes restringidos**, y después ya se puede
  conceder el permiso. El menú ⋮ solo está en la pantalla de info de la app.
  `termux-sms-list` necesita **READ_SMS y READ_CONTACTS**: sin Contactos tampoco
  lista mensajes.
- **Limitación sin arreglo**: Termux:API no expone descolgar ni colgar. Las
  llamadas entrantes hay que contestarlas en el teléfono.
- **GOTCHA `termux-sms-send` no deja rastro en "enviados"** (probado 2026-07-24):
  el envío sale por `SmsManager`, pero Termux:API **no es la app de SMS por
  defecto**, así que no puede escribir en el proveedor de SMS del sistema.
  Resultado: `termux-sms-list -t sent` devuelve `[]` y los mensajes enviados desde
  el panel **nunca aparecen en el hilo**. El comando devuelve éxito igualmente.
  La única confirmación de entrega es mirar el teléfono que recibe.
- **GOTCHA `termux-telephony-call` y el *background activity launch***: al
  principio la API devolvía `{"ok":true}` pero no marcaba nada — ni entrada en el
  registro de llamadas ni rastro de `ACTION_CALL` en `logcat`. Es la restricción
  de Android que impide a un proceso en segundo plano lanzar una actividad (la
  misma que tumba el diálogo de `termux-open` por SSH). Se resolvió dándole a
  Termux/Termux:API el permiso **"Mostrar sobre otras apps"**
  (`SYSTEM_ALERT_WINDOW`), que exime a la app de esa restricción. **Verificado
  funcionando el 2026-07-24 21:31** (llamada saliente de 52 s desde el panel).
  Si algún día vuelve a "decir ok y no marcar", ese permiso es lo primero a mirar.
- **LÍMITE DURO: el audio de la llamada no puede salir del teléfono.** Android
  reserva las fuentes `VOICE_CALL` / `VOICE_DOWNLINK` / `VOICE_UPLINK` a apps con
  `CAPTURE_AUDIO_OUTPUT`, que es `signature|privileged` — solo apps de sistema. Y
  desde Android 10 `AudioPlaybackCapture` excluye explícitamente el audio de
  telefonía. Termux:API solo trae `termux-microphone-record` (micrófono, no la
  llamada). Ni siquiera con root es fiable: en hardware tipo Pixel el módem rutea
  la voz por el DSP y nunca pasa por un stream capturable. **Para oír la llamada
  en el navegador hay que dejar de usar la línea celular y pasar a VoIP/WebRTC.**
- Endpoints: `GET /` (panel), `/api/health`, `/api/conversations`, `/api/thread`,
  `/api/calls`, `/api/contacts`, `/api/audit`; `POST /api/sms`, `/api/call`.

## Servicio 7: Puente Telegram (sentinel001) — `telegram_bridge/`

Alta 2026-08-26. Segundo puente del proyecto **PRC Watch**: el reloj lee y
contesta Telegram sin instalar nada en él (Wear OS 2 no tiene cliente viable).
Expone la **misma API `/watch/*`** que el checker de WhatsApp, en otro puerto, de
modo que la app del reloj muestre una bandeja unificada.

- Ubicación real: `~/Herramientas/Telegram_Bridge/` en sentinel001. Puerto
  **8003**. Node 26.3.1.
- **Sesión de USUARIO, no bot**: un bot NO puede leer los chats personales
  (privacy mode: solo ve lo que se le envía). Telegram permite clientes de
  terceros con `api_id` propio; la sesión sale en Ajustes > Dispositivos como
  "PRC Watch Bridge" y el usuario puede revocarla desde ahí.
- **Librería: `teleproto` 1.229.0** (fork activo de GramJS,
  github.com/sanyok12345/teleproto). Decisión verificada 2026-08-25:
  - **GramJS (npm `telegram`) está ARCHIVADO** desde el 14-jul-2026 y deprecado
    en el registry; su último código es de dic-2024 (capa TL 193, ~36 capas por
    detrás). No usarlo.
  - **mtcute está descartado**: `@mtcute/node` declara `better-sqlite3` en
    `dependencies` (no optional) y lo importa en el barrel, así que en Termux
    intenta compilar con node-gyp aunque uses MemoryStorage.
  - teleproto es **JS puro sin paso nativo**: instaló en Termux ARM en 21 s.
    Versionado MAJOR.LAYER.PATCH — el `229` es la capa TL. **Fijar versión exacta
    sin caret**: la session string equivale a acceso total a la cuenta.
- Secretos (600, fuera del mirror): `api.txt` (`api_id`/`api_hash` de
  my.telegram.org — **uno por número, NO se puede rotar ni revocar**),
  `watch_token.txt` (mismo valor que el del checker, para que el reloj use un
  solo token), `session.txt` (session string tras el login).
- Login por HTTP con **promesas diferidas** (el callback `phoneCode` de
  `client.start()` espera a que llegue el dato por endpoint):
  `POST /login/start {phone}` → `POST /login/code {code}` → si hay 2FA,
  `POST /login/password {password}`. Todos exigen `x-watch-token`.
  **El código llega DENTRO de Telegram, no por SMS, y los servidores invalidan
  cualquier código que se reenvíe por un chat.**
- Endpoints del reloj: idénticos al bloque 1c, con `jid` prefijado `tg:<chatId>`
  y `service: "telegram"` en cada chat.
- Ajustes aplicados tras revisión adversarial (importan, no son cosmética):
  - **`reconnectRetries`** es el que hay que acotar, NO `connectionRetries`
    (que ya vale 5 por defecto en teleproto). Sin acotarlo es Infinity y runit
    nunca recupera el control.
  - `keepAliveInterval` 30 s por el NAT móvil.
  - **`catchUp()`** al reconectar para no dejar un hueco silencioso de mensajes;
    si el hueco es enorme devuelve `UpdatesTooLong` y el fallback es refetchear
    diálogos.
  - **Throttle de 60 s en `getDialogs`**: sin `limit` trae TODO, y llamarlo por
    cada petición del reloj da FLOOD_WAIT y pico de RAM. Entre refrescos, los
    eventos `NewMessage` mantienen el almacén vivo.
  - **Lock `bridge.pid` con comprobación de PID vivo**: dos procesos con la misma
    auth key hacen que Telegram la invalide (`AUTH_KEY_DUPLICATED`) y obligan a
    re-loguear. Nunca sacar `session.txt` del nodo ni cargarlo en otra máquina.
  - Arranca con `--max-old-space-size=192`. No existe benchmark público de RAM de
    ningún cliente MTProto en JS: medir `VmRSS` a las 24 h y ajustar.
- **Aviso de ToS**: los términos de la API de Telegram prohíben usar o agregar
  los datos obtenidos para entrenar modelos de IA/ML. A tener en cuenta si algún
  día se quiere pasar el contenido de los mensajes por un LLM.
- **Supervisado por runit desde 2026-08-26**: servicio
  `$PREFIX/var/service/telegram_bridge` (mirror en
  [`runit_services/`](runit_services)), log con svlogd en
  `$PREFIX/var/log/sv/telegram_bridge/current`. Arranca solo tras reboot porque
  `runsvdir` recoge todo el directorio de servicios; el `00-services.sh` no
  necesita una línea por servicio.
- **Al pasar de un arranque manual a runit, matar PRIMERO el proceso suelto**
  (`kill $(cat bridge.pid)`, NUNCA `pkill -f`) y crear el servicio con archivo
  `down` para que no arranquen los dos a la vez: dos clientes con la misma auth
  key hacen que Telegram la invalide. Verificado el relevo el 2026-08-26: el
  servicio reconectó con la sesión guardada sin pedir código.

## Servicio 8: RPA Monitor en sentinel020

**sentinel020 es hoy el host de todos los RPA Monitor.** No es nodo rqlite y no
lleva thermal-guard: es un Windows 11 dedicado a los scrapers. Fueron llegando
por fases (Extron y LG primero, luego Eizo, Sony el 2026-09-22 y Barco el mismo
día). Estado verificado en vivo el **2026-09-22**.

| Marca | Carpeta | Panel | `Monitoreo` |
|---|---|---|---|
| LG | `D:\RPA Monitor LG` | `:3005` | cada hora en `:35` |
| Sony | `D:\RPA Monitor Sony` | `:3006` | cada hora en `:50` |
| **Barco** | `D:\RPA Monitor Barco` | `:3007` | cada hora en `:05` |
| Extron | `D:\RPA Monitor Extron` | `:3008` | 2×/día 06:00 y 18:00 (+ `RPA Extron - Ampronix` a las 19:00) |
| Eizo | `D:\RPA Monitor Eizo` | `:3009` | cada hora en `:20` |

### Convención de la máquina

Sustituye a PM2, que **no está instalado** aquí. Cada marca tiene:

- Dos wrappers en `Script\`: `scraper_<marca>.cmd` y `panel_<marca>.cmd`.
  Descubren la raíz con `%~dp0..` y node con fallback a
  `%USERPROFILE%\node\node.exe`, así que no llevan rutas fijas. El del panel deja
  node en primer plano (la tarea figura `Running`) y lleva una guarda `netstat`
  contra doble arranque.
- Dos tareas del Programador: `RPA <Marca> - Monitoreo` (horaria, límite 2 h) y
  `RPA <Marca> - Panel` (al arrancar + cada 5 min, que revive el panel si cae).
  Principal `sentinel`, logon **S4U**, RunLevel Limited,
  `MultipleInstances=IgnoreNew`.
- Scripts de alta versionados en el repo de cada marca:
  `dev\register_<marca>_tasks.ps1` y `dev\enable_<marca>_tasks.ps1`.
- Una regla de firewall Inbound TCP por panel, perfiles Domain+Private.

**Exposición a internet:** LG, Sony, Barco y Eizo son **solo LAN**. Los dos que
salen fuera lo hacen por el túnel `rpa-extron` que corre en **sentinel014**, que
apunta a este equipo: `extron.batchtoday.us` → `192.168.1.99:3008` y
`ampronix.batchtoday.us` (solo `^/api/agent/`) → `192.168.1.99:3013`. La
autenticación no la hace Cloudflare sino el propio Express (Basic Auth,
`DASH_USER`/`DASH_PASS` del `.env`). Detalle en
[`cloudflared/`](cloudflared).

### Escalonado horario (2026-09-22)

Las cuatro marcas horarias disparaban todas en punto: cuatro Chrome compitiendo
a la vez hacían que la corrida de Barco pasara de 49 s a **68 s** (+39 %). Se
repartieron en `:05` Barco, `:20` Eizo, `:35` LG, `:50` Sony, dejando `:00` libre
para el ciclo de Extron, que es el pesado (descargas + IA + sync a Shopify).
El XML previo de cada tarea quedó respaldado en `D:\_backup_tareas\`; revertir
una es `schtasks /create /xml <fichero> /tn "<tarea>" /f`.

### Gotchas de este equipo

- **`pm2 stop` NO congela un RPA con `cron_restart`** en la máquina de origen:
  PM2 reinicia la app en cada disparo del cron aunque esté `stopped`. Para
  congelar de verdad antes de migrar hay que `pm2 delete` + `pm2 save`.
- **El shell remoto de sentinel020 ya es `cmd.exe`.** Anteponer `cmd /c` rompe el
  encadenado: `ssh nodo "cmd /c cd /d X && git log"` ejecuta el `cd` en un
  subproceso que muere y el resto corre en `C:\Users\sentinel`. Mandar
  `cd /d "ruta" && <comando>` directamente, o usar `git -C`.
- **Nunca `taskkill /im node.exe`**: los cinco paneles son `node.exe` y caerían
  todos. Sacar el PID de `netstat -ano | findstr ":<puerto>"` y matar ese.
- **`Last Result: 267009`** en una tarea es `SCHED_S_TASK_RUNNING`, no un fallo.
  Esperar a que `Status` vuelva a `Ready` antes de leerlo.
- `New-ScheduledTaskTrigger -Daily` y `-RepetitionInterval` son juegos de
  parámetros incompatibles (`AmbiguousParameterSet`). Para un disparador diario
  con repetición horaria, construir la repetición con un trigger `-Once` auxiliar
  y copiar `.Repetition`.
- Al migrar, los ficheros **gitignored no viajan en el `git clone`** y hay que
  copiarlos a mano: `.env`, `Datos\`, `Docs\` y los de configuración local. En
  Barco, olvidar `Script\orphan_products.json` descataloga 7 productos por error
  a las 3 horas.
- **El hash de un fichero SQLite no sirve** para validar una copia: abrirlo en
  lectura-escritura cambia la cabecera. Comparar contenido (conteos de filas,
  `last_seen`), no bytes.
- Tras un `git pull` que reescribe un `.cmd` en uso, **reiniciar la tarea**:
  `cmd.exe` lee los batch de forma incremental y el cambio de finales de línea
  (git los deja en CRLF) desplaza los offsets.

Runbook completo de la migración más reciente, con las cinco fases y todo lo
verificado: `D:\RPA Monitor Barco\MIGRACION_SENTINEL020.md`.

## Servicio 9: Respaldo de rqlite (sentinel020 + sentinel014)

Alta 2026-10-30. Cada noche a las 10:45 UTC (03:45 en horario de verano, 02:45 en invierno:
el disparador quedó atado a UTC) la tarea `RED Respaldo - rqlite` de sentinel020
baja una copia de la base, la comprueba y la sube a la EC2. En sentinel014, el timer
`sentinel-v2-respaldo-vigia` avisa si deja de haber copias recientes. Cómo funciona y
cómo restaurar: [`rqlite/README.md`](../rqlite/README.md#respaldo-diario).

- En sentinel020: `D:\RED Respaldo\` (`Script\`, `rqlite\`, `Log\respaldo.log`, `.env`
  con el bot de Telegram, copiado del `.env` de RPA Monitor Extron).
- Los avisos fallidos llegan por Telegram una vez por pasada. Si todo va bien, no hay
  mensaje.
- Comprobar: `curl -K ~/.config/rqlite/sentinel.curlrc -G 192.168.0.21:4001/db/query --data-urlencode "q=SELECT * FROM
  sentinel_respaldo ORDER BY ts DESC LIMIT 3"`.

## Servicio 10: Avisos de la red y latido a la EC2

Alta 2026-11-09. Por qué y cómo se decidió: [`ROLLOUT_v2.md`](../ROLLOUT_v2.md),
«Avisos sin puntos ciegos y quórum por nodos».

**Dentro de casa: `Sentinel-Alert.sh`**, solo en el Wheel, cada 5 min (cron en
Termux, timer `sentinel-v2-alert` en Ubuntu). Vigila que cada nodo responda, que
rqlite tenga líder y alcance el rqlited de cada uno, que siga llegando la
telemetría de cada nodo vivo, los equipos sin agente de `EXTRA_CHECKS`
(sentinel020) y la batería. Avisa al pasar a mal, al volver y con un recordatorio
cada 24 h.

- Ficheros en el Wheel (`~/PRC_Sentinel/v2/`): `alert.state` (estado, 7 campos),
  `alert.log` (cada envío con su resultado; `FALLO` = se reintentará).
- Claves de `sentinel.conf`, **iguales en todos los nodos** (cualquiera puede ser
  Wheel): `EXTRA_NODES`, `SKIP_NODES`, `GRACE_NODES` (laptop y 020 a 1800 s),
  `EXTRA_CHECKS`, `DATOS_TEMP_MAX_MIN`, `DATOS_BAT_MAX_MIN`, `RQ_GRACIA`,
  `RECORDATORIO_H`. Ver `Sentinel-Node.conf.example`.
- Probar sin enviar ni tocar el estado real: copiar **con `cp -p`** `sentinel.conf`,
  `fleet.token`, `wheel.state`, `alert.state` y `peers.tsv` a un directorio
  temporal y ejecutar `DRY=1 WHEEL_SETTLE=0 SENTINEL_NOJITTER=1 SENTINEL_BASE=<ese dir> sh Sentinel-Alert.sh`.
  Sin `-p` el `wheel.state` copiado parece recién coronado y la pasada calla; en
  DRY el script dice siempre por qué no pasa. Los datos parados tienen 2 pasadas de
  gracia, así que una sola pasada en seco no los enseña todavía.
- Banco: `sh Sentinel-Selftest-Avisos.sh` (mejor en sentinel014: ~1 min).
- Por qué no llegó un aviso: `grep FALLO alert.log` en el Wheel; desde fuera,
  `SELECT clave, ts, wheel, pendientes FROM sentinel_vigia`. Tiene dos filas:
  `avisos` es la última pasada del Wheel (`ts`), quién era y sus envíos
  pendientes; `btc-senales` es el estado de las señales de BTC (`ts` = desde
  cuándo, `wheel` = el equipo de BTC, `pendientes` = su código, 0 = bien).

**Desde fuera: latido a la EC2.** Cubre lo que el Wheel no puede ver desde dentro:
apagón, internet caído o el Wheel con el cron parado.

- En **sentinel014 y sentinel016**: llave `~/.ssh/sentinel_latido` (ed25519, sin
  frase), `LATIDO_DESTINO=ubuntu@<la EC2>` en `sentinel.conf`, la huella de la EC2
  en `~/.ssh/known_hosts` y el timer `sentinel-v2-latido` (`Sentinel-Latido.sh`).
- En la **EC2**, `~/sentinel-latido/`: `latido-recibir.sh`, `latido-vigilar.sh`,
  `telegram.conf` (600; `BOT_TOKEN` y `CHAT_ID` del thermal-guard) y lo que va
  escribiendo (`sentinelNNN.latido`, `vigilar.state`, `vigilar.log`).
- `authorized_keys` de la EC2, una línea por mini-PC; la llave no abre shell ni
  reenvía puertos, y el nombre del nodo lo fija la línea:
  `restrict,command="/home/ubuntu/sentinel-latido/latido-recibir.sh sentinel014" ssh-ed25519 AAAA... sentinel014-latido`
- Cron de la EC2: `*/5 * * * * $HOME/sentinel-latido/latido-vigilar.sh`.
- Orden al montarlo: primero el `Sentinel-Alert.sh` nuevo en el Wheel (crea
  `sentinel_vigia`), luego el timer de latido de 014 y 016, y por último el cron de
  la EC2. La EC2 da de margen 15 min sin ningún latido y 40 min sin ninguna pasada
  antes de avisar, así que el orden no genera avisos falsos, pero así se prueba
  cada pieza con la anterior ya en marcha.
- Avisa (prefijo «Sentinel (desde la EC2)») si no llega ningún latido en 15 min,
  si la última pasada de los avisos tiene más de 40 min o si el Wheel lleva 10 min
  sin poder mandar a Telegram.
- Comprobar: `ssh batchtoday 'cat ~/sentinel-latido/*.latido ~/sentinel-latido/vigilar.state'`
  (cada `.latido`: recibido, nodo, última pasada, Wheel, pendientes, readyz).
- Si se cambia el bot de Telegram, actualizar también `telegram.conf` de la EC2.

## Servicio 11: Monitoreo de BTC (sentinel014) — [`btc/`](../btc)

Velas diarias y semanales de BTC en Coinbase (el perpetuo de futuros
`BIP-20DEC30-CDE` y el spot `BTC-USD`), con Heikin Ashi, indicadores y Fibonacci,
en las tablas `cripto_vela`, `cripto_indicador` y `cripto_fibonacci` del rqlite.
Y señales al cierre de cada vela (`cripto_aviso`), que la propia pasada manda
por Telegram con el bot de thermal-guard de 014.

- Corre en **sentinel014** con el temporizador de usuario `sentinel-btc-velas`:
  una pasada cada 5 min (minutos 2, 7, 12… y segundo 30, en UTC) desde el
  13/11/2026. Código en `~/PRC_Sentinel/v2/btc/`; log en
  `~/PRC_Sentinel/btc/velas.log`.
- Una pasada normal: ~1,5 s y 4 entradas de Raft (~0,8 por minuto en total).
- Instalar, actualizar, mirar y quitar: [`btc/README.md`](../btc/README.md),
  sección «Dónde corre».
- Lo vigila el Wheel, con `Sentinel-Alert.sh`:
  - clave `bv:<producto>`, «el monitoreo de BTC no está al día»: lleva más de
    15 min (`BTC_DATOS_MAX_MIN`) sin escribir las velas, o escribe pero
    Coinbase no trae la vela del día;
  - clave `bs:senales`, «las señales de BTC no salen»: la pasada apunta en
    `sentinel_vigia` (fila `btc-senales`) desde cuándo falla su paso de las
    señales, y el Wheel avisa a los 15 min.

  No avisa con la base parada, sin líder o con su réplica atrasada, que ya
  tienen su propio aviso. Detalles en `btc/README.md`, «Señales».

## Credenciales de Bright Data

Qué ficheros guardan cada credencial y cómo comprobarlas está en una nota privada
del dueño, fuera de este repo público. Ningún nodo Termux usa Bright Data, y rotar
el API key no afecta a `BRD_WSS`, que usa usuario y contraseña de zona.

## Gotchas operativos

- `ps`/`pgrep` en Termux solo ven procesos del propio usuario; el "phantom
  process killer" de Android puede matar procesos largos (node, rqlited) —
  causa probable de que node1 esté caído con logs recientes.
- La hora local del dispositivo y las marcas del log de rqlite difieren
  (log en UTC, dispositivo en hora local UTC-6).
- `which` no existe en Termux; usar `command -v`.
- `sv status <svc>` en sesión SSH necesita `export SVDIR=$PREFIX/var/service`.
- **`crond` no relee el crontab en caliente** (visto el 2026-07-24 en sentinel019 al
  pasar thermal-guard de `*` a `*/2`: siguió ejecutándose cada minuto hasta el
  reinicio). Tras editar con `crontab -e`/`crontab -`, reiniciar el demonio
  (`pkill -x crond; crond`) o el cambio no surte efecto.
- `pkill -f` desde ssh puede matarse a sí mismo si el patrón aparece en la
  línea de comando remota; usar `pkill -x <nombre>`.
  **Corolario nuevo (2026-08-26): `pkill -f "node server.js"` es doblemente
  peligroso** — mata la sesión ssh Y coincide con TODOS los servicios de la
  flota, porque el checker de WhatsApp y el puente de Telegram se llaman ambos
  `server.js`. Para parar el puente de Telegram, usar el PID de `bridge.pid`;
  para el checker, `sv down whatsapp_checker`.
- **En la laptop (sentinel013), comprobar que el puerto esté libre ANTES de
  lanzar nada de pruebas.** El pm2 tiene 16 apps repartidas por 3000-3020 y
  varias no responden como se espera: un servicio ajeno en el puerto elegido
  devuelve sus propios 404 y sirve sus propias páginas, y se pierde un buen rato
  depurando un fallo que no existe (pasó el 2026-07-24 con el 3020). Pedir la
  lista con `Get-NetTCPConnection -State Listen` y elegir por encima de 3100.
- runit reinicia procesos muertos al instante; para sobrevivir reinicios del
  teléfono se usa **Termux:Boot 0.8.1** (F-Droid, com.termux.boot_1000.apk,
  sha256 6f7cf9b9...) con el script `~/.termux/boot/00-services.sh` (mirror en
  `termux_boot/`) que hace wake-lock, arranca sshd/crond y `service-daemon`.
  Los servicios runit sshd/crond traen archivo `down` — se arrancan directo.
  Tras instalar el APK hay que **abrir Termux:Boot una vez** y quitar la
  optimización de batería a Termux para que Android respete el autoarranque.
- Instalar el APK desde el home privado de Termux da **"parse error"**: hay
  que copiarlo a `~/storage/downloads/` (previo `termux-setup-storage`) e
  instalarlo desde ahí con `termux-open` en primer plano (por SSH el diálogo
  ni siquiera aparece — restricción de background activity de Android).
- Complemento anti-doze: en los dispositivos se usan las apps **Caffeinate**
  y **Keep Screen On** para mantener la pantalla encendida y evitar que
  Android duerma los procesos en segundo plano (tercera capa junto al
  wake-lock de Termux y runit).
- **Ciclo verificado en LOS 5 NODOS con reboot real (2026-07-05)**: reboot →
  40-100 s → sshd, crond y rqlited arriba y el nodo de vuelta en el clúster,
  sin tocar el teléfono; en sentinel001 además whatsapp_checker vuelve
  `ready:true` sin re-escanear QR. Funciona igual en las Fire HD 8 (009/010).
  Requisitos aprendidos: abrir Termux:Boot una vez ANTES del primer reboot
  (registra el boot receiver) y sin bloqueo de pantalla que impida el
  arranque de apps.
- Load average alto (~20) en sentinel001 es habitual (hardware modesto,
  20 clones gawk + cron cada minuto).
