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

Todos son teléfonos Android con Termux, usuario `sentinel`, SSH puerto **8022**
(configurados en `~/.ssh/config` de la laptop). sentinel001 es un Samsung
Galaxy (aarch64, kernel abA125USQS9CXJ4).

| Host SSH    | IP LAN         | rqlite node-id | Rol extra                        |
|-------------|----------------|----------------|----------------------------------|
| sentinel001 | 192.168.1.69   | node1          | WhatsApp_Checker + API del reloj (:8002), Puente Telegram (:8003), PRC_Sentinel (:8081-8100) |
| sentinel002 | 192.168.1.65   | node9          | Android/Termux (aarch64), unido 2026-07-17 |
| sentinel003 | 192.168.1.94   | node2          |                                  |
| sentinel005 | 192.168.1.252  | node3          |                                  |
| sentinel009 | 192.168.1.124  | node4          |                                  |
| sentinel010 | 192.168.1.190  | node5          | líder rqlite habitual            |
| sentinel014 | 192.168.1.250  | node6          | rqlite en Ubuntu 24.04 (systemd user), **RPA Monitor Extron** (ciclo 2×/día + dashboard :3008) |
| sentinel016 | 192.168.1.91   | node7          | rqlite en Ubuntu 24.04 (systemd user), prc-agent-jupiter (Docker, wallet Phantom) |
| sentinel017 | 192.168.1.212  | node8          | Android/Termux (aarch64), unido 2026-07-17 |
| sentinel018 | 192.168.1.211  | node10         | detectado en auditoría remota 2026-07-21 (reporta telemetría battery) |
| sentinel019 | 192.168.1.210  | node11         | Pixel 6 (Android 17, aarch64), celular personal, unido 2026-07-24. Backend **Sentinel SMS** (:8010, solo loopback, pm2) |

La laptop se llama **sentinel013** y no es nodo rqlite: corre el pm2 con 16 apps
(dashboards RPA en 3001-3013) y ahora el panel Sentinel SMS en 3014.

Nota: node-ids NO siguen el orden de los hosts — sentinel002 es node9 (node2 ya lo tenía sentinel003). Al añadir un nodo, usar el siguiente node-id libre, no el número del host. **Comprobar el id libre en vivo** con `curl 'http://<ip>:4001/nodes?pretty'`, no en esta tabla.

Otras IPs del ecosistema: `IpWheel=192.168.1.117` (nodo "Wheel" que sirve
`/useragent` a los Sentinels).

## Servicio 1: WhatsApp_Checker (`whatsapp_checker/`)

- Ubicación real: `~/Herramientas/WhatsApp_Checker/` en sentinel001 **y en
  sentinel005** (2 instancias = 2 números de WhatsApp distintos). Mismo código,
  cada una con su propio `auth_info_baileys/` (sesión independiente). En
  sentinel005 el número es uno de Fanytel (VoIP) **13107744000**; Node.js se
  instaló con `pkg install nodejs` (no venía). El número de sentinel001 es
  **14088410157** (celular personal, solo checkNumberStatus).
- **sentinel005 corre la variante mejorada `whatsapp_chatbot/server.js`**
  (mirror en `whatsapp_chatbot/`) que combina el checker + un **chatbot de IA**
  en la misma sesión de Baileys (13107744000). Detalles abajo.

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
  `OWNER_NUMBER`** (14088410157, el celular personal) e ignora a todos los demás.
  Flujo: escribes desde tu celular al número Fanytel → el bot responde con IA.
- **Gemini** (misma API key que `D:\PRC Indeed`, en `.env` con `chmod 600`,
  cargada por `node --env-file=.env`): `gemini-2.5-flash` con fallback a
  `gemini-2.0-flash`, vía REST `generateContent`. Usa **function calling** con
  3 herramientas de solo lectura:
  - `estado_red` → `GET {RQLITE_API}/nodes` (nodos alcanzables, líder, quórum).
  - `esquema_bd` → tablas + nº de filas + DDL.
  - `consultar_bd(sql)` → `GET {RQLITE_API}/db/query` con guard SELECT/PRAGMA/WITH
    (rechaza escrituras), fallback `level=weak`→`none`.
- **GOTCHA**: rqlited escucha en la IP LAN (`-http-addr 192.168.1.252:4001`),
  **NO en localhost** → `RQLITE_API=http://192.168.1.252:4001` en el `.env`
  (o el `MyIP` del nodo). localhost:4001 da respuesta vacía.
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
  (`224644086931540@lid`), NO como `14088410157@s.whatsapp.net`. El filtro del
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
  - Configuración del join: los nodos secundarios llevan `-join 192.168.1.69:4002`.
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
- Consultas útiles:
  - `curl 'http://<ip>:4001/status?pretty'`
  - `curl 'http://<ip>:4001/nodes?pretty'`
  - `curl -G '<ip>:4001/db/query' --data-urlencode 'q=SELECT ...' --data-urlencode 'level=none'`
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
- Config por entorno en `~/.profile`: `PathSentinel`, `MyIP=192.168.1.69`,
  `OS=Termux`, `UserAgent`, `IpWheel=192.168.1.117`, `Name=Sentinel001`.
- Datos calientes en `Datos/Hot.db` (SQLite).
- Relación histórica: `Run/` enlaza a scripts de `PRC_Crypto_Trends`
  (precios del order book de Binance, hoy comentados en el crontab).

## Servicio 4: RPA Monitor Extron (sentinel014)

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
  (`rpa-extron`, id 4f0a2058, servicio systemd de sistema `cloudflared`, config
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
   **siguiente node-id libre según `/nodes` en vivo** y bind `0.0.0.0` + adv addr.
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
    formatos (`+14088410157` y `4088410157`) no se cuela dos veces ni se paga
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
