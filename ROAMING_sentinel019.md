# sentinel019 fuera de casa — que el móvil siga en la red al pasar a datos móviles

Estado a 2026-08-25: **DESPLEGADO Y VERIFICADO**. La malla es **WireGuard con hub
propio en batchtoday** — no Tailscale. Detalle en el [§8](#8-estado-hecho-y-pendiente).

Objetivo: que `sentinel019` (Pixel 6, móvil personal, `node11`) siga formando parte
de la red Sentinel cuando cruza de la WiFi de casa a los datos móviles.

---

## 1. Por qué hoy no funciona

No es un problema de permisos. Es de **alcanzabilidad**, y tiene cuatro capas.

### Muro 1 — la red entera funciona por sondeo entrante

Todo el modelo es *pull*: los demás abren conexiones **hacia** el nodo. El nodo
nunca llama a casa.

| Quién sondea | A dónde | Fichero |
|---|---|---|
| Elección de Wheel | `GET /fitness` | [`Sentinel-Wheel.awk:25`](Wheel/Script/v2/Sentinel-Wheel.awk:25) |
| Alertas | `GET /fitness` | [`Sentinel-Alert.sh:249`](Wheel/Script/v2/Sentinel-Alert.sh:249) |
| Descubrimiento | `GET /version` | [`Sentinel-Discover.awk:92`](Wheel/Script/v2/Sentinel-Discover.awk:92) |
| Raft | TCP 4002 | [`rqlited.run.sh:14`](Nodos/runit_services/rqlited.run.sh:14) |

Los únicos flujos salientes del nodo van a `127.0.0.1` (el callback del worker en
[`Sentinel-Worker.awk:73`](Wheel/Script/v2/Sentinel-Worker.awk:73) y el watchdog en
[`watchdog.sh:35`](Wheel/Script/v2/service/watchdog.sh:35)).

Existe una ruta que *parecería* servir de alta —`POST /ingest/eye` en
[`Sentinel-Server2.awk:16`](Wheel/Script/v2/Sentinel-Server2.awk:16)— pero **está
huérfana**: nada del v2 la llama, solo el banco de pruebas. Es herencia del
`/addeye` del v1.

Detrás del CGNAT del operador ninguna de esas flechas llega, y no hay ningún
mecanismo de registro saliente que pudiera sustituirlas.

### Muro 2 — la identidad de transporte es la IP de la LAN

El **nombre** es la identidad declarada (el rol de Wheel se decide por nombre, no
por IP: [`Sentinel-Wheel.awk:338`](Wheel/Script/v2/Sentinel-Wheel.awk:338)), pero
el encuentro es siempre por IP. `sentinel019` está atado a `192.168.1.210` en seis
sitios:

| Dónde | Referencia |
|---|---|
| `peers.tsv`, claveado por IP | [`Sentinel-Wheel.awk:320`](Wheel/Script/v2/Sentinel-Wheel.awk:320) |
| `alert.state`, claveado por IP | [`Sentinel-Alert.sh:222`](Wheel/Script/v2/Sentinel-Alert.sh:222) |
| `SKIP_NODES` / `EXTRA_NODES` / `GRACE_NODES` | [`Sentinel-Node.conf.example:58`](Wheel/Script/v2/Sentinel-Node.conf.example:58) |
| `-raft-adv-addr` de rqlite | [`rqlited.run.sh:14`](Nodos/runit_services/rqlited.run.sh:14) |
| SAN del certificado del nodo | [`Sentinel-PKI.sh:103`](Wheel/Script/v2/Sentinel-PKI.sh:103) |
| `NODE_MAP` del chatbot | [`server.js:143`](Nodos/whatsapp_chatbot/server.js:143) |

En cuanto la IP cambia, el nodo deja de ser localizable aunque su nombre, su token
y su certificado sigan siendo perfectamente válidos.

### Muro 3 — Raft necesita las dos direcciones

Ya está documentado como causa raíz de caídas reales
([`Nodos/README.md:159`](Nodos/README.md:159)): un nodo que solo tiene salida
—Raft saliente OK, ping OK— **se cae del clúster igual**, porque nadie puede
conectarse a sus puertos. Es literalmente el escenario del móvil en LTE.

### Muro 4 — el silencio de alertas está atado a una IP

`SKIP_NODES=192.168.1.210` silencia **una dirección, no un nodo**. Si el móvil
apareciera con otra IP, dejaría de estar silenciado y avisaría en cada cambio de
red. Y `totalCand` ([`Sentinel-Wheel.awk:232`](Wheel/Script/v2/Sentinel-Wheel.awk:232))
cuenta a los candidatos aunque no respondan, así que un node11 fantasma endurece
el quórum de elección de todos los demás.

---

## 2. Lo que NO es el problema

Conviene decirlo porque ahorra buscar donde no hay nada:

- **El token viaja bien.** No hay ningún filtro por IP de origen en todo el v2, y
  es deliberado: gawk no expone la IP del par
  ([`Sentinel-Server2.awk:28`](Wheel/Script/v2/Sentinel-Server2.awk:28)). Un nodo
  que llegue desde una IP móvil cualquiera entra si presenta el token.
- **El mTLS también.** `verifyChain`/`requireCert` validan la cadena hasta la CA,
  no el origen ([`Sentinel-TLS.sh:152`](Wheel/Script/v2/Sentinel-TLS.sh:152)).
- **`Sentinel-Allow.conf` no tiene nada que ver con IPs**: es la lista blanca de
  *acciones* ejecutables ([`Sentinel-Allow.conf:1`](Wheel/Script/v2/Sentinel-Allow.conf:1)).

**La credencial de pertenencia viaja con el nodo sin problema. Lo que no viaja es
su dirección.**

---

## 3. La solución, en dos capas

El error sería tratar esto como un solo problema. Son dos, y tienen respuestas
distintas:

| Capa | Problema | Respuesta |
|---|---|---|
| **Alcanzabilidad** | nadie puede abrirle conexión | malla WireGuard → IP fija que vale en las dos redes |
| **Coste** | Raft sobre LTE quema plan y batería | `Sentinel-Roam.sh` para rqlited fuera de casa |

### Por qué una malla y no un túnel

Una malla resuelve los cuatro muros **sin tocar una línea del código Sentinel**:
si el móvil tiene una dirección estable que funciona dentro y fuera de casa, la
identidad-por-IP repartida por esos seis ficheros sigue siendo *cierta*. Cualquier
otra opción obliga a reescribir el modelo de descubrimiento.

Además arregla de rebote un fallo ya conocido de esta flota: en doze, Android
recicla la IP del WiFi y el socket atado a ella muere
([`Nodos/README.md:159`](Nodos/README.md:159)). La IP de la malla no se recicla.

### Por qué NO Raft sobre datos móviles

rqlite replica **cada escritura a los 11 nodos**. Solo el muestreo de cripto son
8.640 filas/día ([`Sentinel-Node.conf.example:83`](Wheel/Script/v2/Sentinel-Node.conf.example:83)),
más la telemetría de 11 nodos por minuto. Sobre LTE eso son cientos de MB al mes y
drenaje continuo de batería, en un teléfono **personal**.

Que el móvil salga del clúster al salir de casa **no es una regresión**: es
exactamente lo que ya pasa hoy. La diferencia es que ahora el agente v2, sshd y la
telemetría se quedan en pie, que es lo que se buscaba.

---

## 4. Direccionamiento — y por qué NO hay subnet router

El diseño inicial ponía a `sentinel014` a anunciar `192.168.1.0/24` como subnet
router, con una ruta estática en el gateway. **Se descartó, y por un fallo real**:

> Si el móvil acepta la ruta `192.168.1.0/24`, alcanza `192.168.1.69` **también
> desde LTE**. `Sentinel-Roam.sh` sondea justo esa IP para decidir dónde está, así
> que concluiría "estoy en casa" estando en la calle: nunca pararía `rqlited`, y la
> pieza que veníamos a arreglar quedaría rota por la pieza que la arregla.

La investigación posterior encontró un segundo efecto en el mismo sentido: el
**hairpin** en casa — el móvil hablando con un vecino a dos metros dando la vuelta
por sentinel014, y los nodos viéndolo como `192.168.1.250` en lugar de con su IP
real, por el SNAT que los subnet routers aplican por defecto.

La pregunta correcta era **qué necesita el móvil de la LAN estando fuera**. La
respuesta es: una sola cosa, escribir su telemetría de batería. Y eso no necesita
ruta ninguna, porque `sentinel014` es `node6` del clúster y **acepta escrituras
reenviándolas al líder** (verificado en vivo: `HTTP 200` contra `:4001/db/execute`).
Basta apuntar `RQLITE_FALLBACK` a su IP de malla.

```
   LTE / CGNAT                    malla WireGuard (hub en batchtoday)
  +------------+                 +--------------------------+
  | sentinel019| -- 10.9.0.x fija -|  sentinel014   (rqlite)  |
  |  (movil)   |                 |  batchtoday = HUB        |
  +------------+                 +--------------------------+
        |                                   |
        +-- en casa, ademas, por la LAN ----+
  +---------------------------------------------------------+
  |  casa 192.168.1.0/24 - los otros 9 nodos, SIN CAMBIOS    |
  +---------------------------------------------------------+
```

Lo que esto elimina: el subnet router, la aprobación de rutas, el debate del SNAT,
la ambigüedad de la detección de red y **la ruta estática en el gateway del
operador** — que era el único paso con riesgo sobre la conectividad de la casa.

**Qué se pierde:** que un nodo de la LAN **sin** malla alcance al móvil cuando está
fuera. No hace falta: con `rqlited` parado, `node11` no sale en `/nodes`, así que ni
la elección ni las alertas lo sondean. La administración va por la laptop, que sí
está en la malla.

**rqlite se queda como está**, anunciando `192.168.1.210`: solo corre en casa.

---

## 5. Procedimiento de instalación y autenticación

> **HISTÓRICO — no es lo que corre hoy.** Este procedimiento (Tailscale) se ejecutó
> completo y funcionó, pero el dueño prefirió **no depender de un tercero** y se
> migró a **WireGuard con hub propio en batchtoday** el mismo día. Se conserva
> porque el diagnóstico, los gotchas de Android y el GATE siguen siendo válidos
> para cualquier malla: el §5.3 (ajustes del Pixel) y el §5bis aplican igual.
> La configuración vigente está en el [§8](#8-estado-hecho-y-pendiente).

Producto elegido: **Tailscale**. Atraviesa el CGNAT sin abrir un solo puerto ni en
casa ni en la EC2, y la IP `100.x` es fija de por vida del dispositivo, que es lo
que mantiene válida la identidad-por-IP del proyecto.

Leyenda: **[WEB]** consola · **[SSH]** desde la laptop · **[TEL]** manos sobre el
teléfono.

### Orden, y por qué

`autoApprovers` y `tagOwners` **no son retroactivos**, y la elección de proveedor de
identidad es casi irreversible: por eso la cuenta va antes del primer
`tailscale up`. Y el **GATE** (§5.4) va antes que nada opcional: si la premisa no se
cumple, lo demás sobra.

Regla transversal: **`tailscale up` para el alta; `tailscale set` para cualquier
cambio posterior.** `up` no persiste flags entre ejecuciones — revierte a sus
valores por defecto todo lo que no menciones.

### 5.1 — Crear la tailnet [WEB]

`https://login.tailscale.com` → **Sign in with Google**.

- **No uses GitHub ni Apple**: son los dos proveedores con bloqueo duro documentado,
  sin migración posible ni abriendo ticket.
- Con Gmail personal la tailnet es *shared domain*: **no se puede transferir la
  titularidad**, y cambiar de proveedor exige soporte. Si algún día esta malla
  tuviera que sostener el negocio de la recepcionista IA, lo que da portabilidad es
  una tailnet con **dominio propio verificado**. Esa puerta se cierra ahora, no
  después.
- Plan Personal: 6 usuarios, dispositivos de usuario ilimitados, 50 recursos
  etiquetados. Con 11 nodos no rozas ningún techo. Es para uso **no comercial**.

Continuidad, el día 1 y gratis: endurece la cuenta de Google (códigos de respaldo,
passkey), invita un segundo usuario **Admin**, y crea un **OAuth client**
(Settings → Trust credentials) — no caduca y pertenece a la tailnet, no a ti: es el
break-glass si pierdes el Gmail.

### 5.2 — sentinel014 [SSH]

Reenvío IP **antes** de instalar. `tailscale up` avisa si falta, pero
`tailscale set --advertise-routes` **no comprueba ni avisa** (issue #14760):

```bash
echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-tailscale.conf
```

```bash
sudo sysctl -p /etc/sysctl.d/99-tailscale.conf && sysctl net.ipv4.ip_forward
```

> **No añadas `net.ipv6.conf.all.forwarding=1`.** Pasa la interfaz de modo *host* a
> modo *router*, desactiva `accept_ra`, y sentinel014 puede **perder su default
> route IPv6 nativa** — quizá al expirar el RA actual, con retraso y pareciendo no
> relacionado. Aquí no se anuncia ninguna ruta, así que no hace falta.

Instalar:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
```

Alta. `--accept-dns=false` porque el nodo lleva 10 semanas en pie con servicios
propios y no conviene que Tailscale toque `resolv.conf`; `100.100.100.100` sigue
respondiendo igual:

```bash
sudo tailscale up --hostname=sentinel014 --accept-dns=false
```

Queda bloqueado imprimiendo una URL `https://login.tailscale.com/a/XXXXXXXX`:
ábrela en cualquier navegador, autentica con Google y el comando se desbloquea solo.
Si se corta el SSH antes de completar el login, hay que relanzarlo.

**No añadas `--advertise-routes`** (ver §4), ni `--accept-routes` (innecesario: las
`100.x` de los peers son nativas del tailnet), ni `--advertise-exit-node` — esto
último es la garantía dura contra un full-tunnel accidental en el móvil.

UFW está inactivo en este nodo, así que no hay nada que hacer ahí. Tailscale no
necesita puertos entrantes, solo salida.

### 5.3 — El Pixel 6 [TEL]

1. Play Store → **Tailscale** → **Get Started**.
2. Acepta el diálogo del sistema de configuración de VPN. Sin eso no hay túnel.
3. Permite las notificaciones: es el canal por el que avisa de re-autenticación.
4. **Sign in with Google, la misma cuenta que en §5.1.** Con otra identidad, el
   móvil y sentinel014 quedan en tailnets distintas y no se ven.

Dentro de la app:

- **Exit Node = None.** Es el único ajuste que convierte esto en VPN de tráfico
  total. Como sentinel014 no anuncia exit node, la lista estará vacía.
- **No excluyas Termux del split tunneling.** La exclusión es por UID y
  `com.termux` comparte `sharedUserId` con sus add-ons: excluirlo tumba de golpe
  `8181`, `8443`, `8022`, `4001` y `4002`. Por defecto viene incluido.
- **Desactiva la aceptación de rutas de subred** si el interruptor existe en tu
  versión (viene activado). No es crítico mientras nadie anuncie rutas, pero deja
  el nodo a prueba de que alguien las anuncie en el futuro.

En Android, y **esto es lo que mantiene vivo el nodo**:

- **VPN siempre activa**: Ajustes → Red e Internet → VPN → **engranaje** a la
  derecha de "Tailscale" (no el nombre) → activar.
- **NO actives "Bloquear conexiones sin VPN"** (lockdown), justo debajo. Sin exit
  node, Tailscale es split-tunnel y no puede cursar el tráfico a Internet: Android
  lo fuerza por el túnel igualmente y el teléfono se queda **sin datos ni WiFi para
  todo lo que no sea la tailnet** — sin navegación y sin WhatsApp. Falla en silencio
  (issue #12925). Si al activar Always-on el móvil pierde datos, mira aquí primero.
- **Batería "Sin restricciones"** para **Tailscale** y para **Termux**:
  Ajustes → Apps → *[app]* → Uso de batería de la app.
- **Phantom process killer** (esto salva a runit, no a Tailscale): Opciones de
  desarrollador → **"Inhabilitar restricciones de procesos secundarios"** →
  reiniciar. Desactiva los dos criterios (>32 procesos y CPU excesiva); con
  `rqlited` latiendo, el peligroso es el de CPU. Si algún día apagas Opciones de
  desarrollador, **vuelve a su valor por defecto**.
- Termux con **wakelock** y `termux-boot` instalado.

**[WEB]** En `console.tailscale.com/admin/machines`: renombra el nodo a
`sentinel019`, **desmarca "auto-generate from OS hostname"**, y anota la `100.x`.
**Nunca borres el nodo**: borrarlo y volver a registrarlo asigna una IP nueva.
**No lo etiquetes** — los tags quitan la identidad de usuario del dispositivo y son
difíciles de revertir en un móvil personal.

### 5.4 — GATE: la premisa crítica [SSH]

Con el móvil **en LTE y la WiFi apagada**, desde sentinel014:

```bash
tailscale status
```

```bash
curl -sS --max-time 5 "http://<100.x-del-movil>:8181/version?token=$(cat ~/PRC_Sentinel/v2/fleet.token)"
```

- **Responde** → premisa confirmada, sigue.
- **Cuelga sin respuesta** (SYN reintentado) → el SYN llega y el SYN-ACK se pierde:
  Termux excluido del split tunneling, o lockdown activado.
- **Silencio con `status` sano** → filtrado por UID: batería restringida, o el
  foreground service de Termux caído.
- **El peer ni aparece** → problema de plano de control, no de Termux.

### 5.5 — Desactivar la caducidad de clave [WEB]

**El paso que más vale de todo el procedimiento.** Por defecto son **180 días**; al
expirar, el nodo deja de funcionar **sin cambio de configuración y sin ningún aviso**
en el host (no hay correo ni health-check anticipado en Linux headless ni en
Android).

Machines → fila del dispositivo → **menú de tres puntos** → **"Disable key expiry"**.
Para `sentinel014` y `sentinel019`.

> Es **preventivo, no de rescate**. Si un nodo ya caducó, usa *"Temporarily extend
> key"* (30 min) y reautentica. Pulsar *Disable key expiry* sobre un nodo **ya
> caducado** hace desaparecer esa opción y lo deja irrecuperable sin acceso físico
> (issue #19785).

### 5.6 — Configuración del nodo móvil [SSH]

En `~/PRC_Sentinel/v2/sentinel.conf` de sentinel019:

```sh
ROAM_SEED=192.168.1.69                          # solo alcanzable en la LAN real
ROAM_SVC=rqlited
ROAM_CONFIRMA=2
RQLITE_FALLBACK=http://<100.x-de-sentinel014>:4001
```

Cron, junto al `*/2` de thermal-guard y el `*/5` de elección:

```
*/5 * * * * ~/PRC_Sentinel/v2/Sentinel-Roam.sh >/dev/null 2>&1
```

**`crond` no relee el crontab en caliente** (visto en este mismo teléfono el
2026-07-24): tras editar, reinicia el demonio o el cambio no surte efecto.

Y en `~/.ssh/config` de la laptop, cambia `sentinel019` a la `100.x`: funciona en
las dos redes.

### 5.7 — Certificado

El SAN del cert lleva la IP LAN y `Sentinel-PKI.sh` **es idempotente, no reemite**:
hay que borrar y volver a emitir para incluir la `100.x`. No es urgente —ningún
componente del v2 usa el 8443 hoy— pero dejarlo sin hacer es poner una trampa.

> **No uses el FQDN `sentinel019.<tailnet>.ts.net` como destino de stunnel**: la
> verificación mTLS fallaría salvo que metas ese nombre como SAN.

---

## 5bis. Gotchas verificados

| Trampa | Síntoma observable |
|---|---|
| **Caducidad de clave (180 d)** | A los ~6 meses el nodo desaparece de golpe, sin cambio de config y sin aviso. |
| **"Bloquear conexiones sin VPN"** | El móvil se queda sin Internet: sin navegación, sin WhatsApp. En silencio. |
| **Termux excluido del split tunneling** | El puerto *parece* abierto pero no responde nunca. |
| **Doze / bucket RESTRICTED sobre Termux** | Falla **solo con la pantalla apagada**; al tocar el teléfono, responde. |
| **Phantom process killing** | `[Process completed (signal 9)]`; servicios con PID nuevo. `rqlited` es la víctima probable. |
| **Reboot del móvil** | Nodo ausente **hasta el primer desbloqueo de pantalla** (ver abajo). |
| **Borrar y recrear el nodo** | `100.x` nueva; todo lo que la referencie deja de funcionar. |
| **`tailscale up` con menos flags** | Preferencias revertidas en silencio. Usa `set`. |

### El límite estructural que hay que asumir

**Tras un reinicio, el Pixel no vuelve a la malla hasta el primer desbloqueo de
pantalla.** El cliente guarda su estado en almacenamiento cifrado por credenciales
(FBE/CE), así que no puede conectar en Direct Boot. **Always-on VPN no lo
soluciona.** Y no es solo Tailscale: Termux:Boot y runit dependen igual de
`ACTION_BOOT_COMPLETED` y de almacenamiento CE.

Consecuencia operativa: **una actualización OTA nocturna = sentinel019 desaparecido
hasta que alguien toque el teléfono**. Primer paso del runbook cuando el móvil no
aparezca: *¿se reinició? desbloquéalo*. No se puede automatizar sin root.

---

## 5ter. Por qué NO `tailscaled` dentro de Termux

Existe la opción de correr `tailscaled --tun=userspace-networking` en Termux sin
root. **No la uses**, y no por rendimiento:

- En ese modo `tailscaled` **termina** la conexión del peer y abre otra hacia
  `127.0.0.1`. Los servicios verían `srcIP = 127.0.0.1`: la identidad-por-IP muere
  del todo y los logs pierden atribución.
- Peor: netstack reenvía **cualquier** puerto a loopback. El backend de **Sentinel
  SMS** en `127.0.0.1:8010` —hoy inalcanzable desde la red, y deliberadamente,
  porque por ahí llegan los OTP del banco— pasaría a ser alcanzable desde el
  tailnet. Y el `8181` en claro quedaría accesible **saltándose stunnel y el mTLS
  entero**. Con la app oficial (TUN real) nada de esto ocurre.

Solo tiene sentido como plan B si el GATE falla, y entonces con `8181` atado a
loopback y la autorización colgando del CN del certificado.

## 6. Alertas: qué hacer con SKIP_NODES

Hoy `SKIP_NODES=192.168.1.210` existe porque el móvil desaparecía a diario y
avisarlo era ruido constante.

**Recomendación: dejarlo como está al principio.** Aunque ahora se espere que el
móvil esté siempre alcanzable, sigue habiendo ausencias legítimas y frecuentes —sin
cobertura, modo avión, batería agotada, un túnel— y convertirlas en alertas
reproduce el ruido que `SKIP_NODES` vino a callar.

Cuando haya un mes de `roam.log` que enseñe el patrón real, se puede subir de
nivel: sacarlo de `SKIP_NODES`, añadir su IP de malla a `EXTRA_NODES` y darle un
`GRACE_NODES` generoso (1800 s, como la laptop) para que solo avise si lleva media
hora ilocalizable. Entonces su ausencia pasa a ser información en vez de ruido.

> `EXTRA_NODES` **solo admite IPs**: el `grep -E '^[0-9]'` de
> [`Sentinel-Alert.sh:192`](Wheel/Script/v2/Sentinel-Alert.sh:192) descarta en
> silencio cualquier entrada que empiece por letra. Un hostname ahí no da error, se
> pierde sin decir nada.

---

## 7. Verificación

Con el móvil **en datos móviles** (WiFi apagada):

```bash
curl -s -m 6 "http://10.9.0.19:8181/version?token=$(cat ~/PRC_Sentinel/v2/fleet.token)"
```

| Comprobación | Esperado |
|---|---|
| `/version` desde la laptop | responde `Sentinel ... 2.0.0` |
| `/version` **sin** token | `401` |
| `ssh sentinel019` | entra |
| desde el móvil: `curl 192.168.1.69:4001/status` | **falla** — y debe fallar: es lo que le dice a `Sentinel-Roam.sh` que está fuera |
| desde el móvil: `curl 10.9.0.14:4001/status` | responde — es la vía de la telemetría |
| `sv status rqlited` en el móvil | `down` — lo paró `Sentinel-Roam.sh` |
| `cat ~/PRC_Sentinel/v2/roam.state` | `fuera\|fuera\|N` |
| `sentinel_bateria` en rqlite | sigue recibiendo filas de `sentinel019` |

Al volver a casa, en ≤10 min `roam.state` debe decir `casa|casa|N`, `rqlited`
volver a `up` y `node11` reaparecer en `/nodes` como `reachable`.

---

## 8. Estado: hecho y pendiente

### Hecho y probado en este repo

| Qué | Dónde |
|---|---|
| `Sentinel-Roam.sh` — conmutación de red con histéresis | [`Wheel/Script/v2/Sentinel-Roam.sh`](Wheel/Script/v2/Sentinel-Roam.sh) + espejo |
| Fallback de telemetría cuando no hay rqlite local | [`Sentinel-Bateria.sh:22`](Wheel/Script/v2/Sentinel-Bateria.sh:22) |
| Variables nuevas documentadas | [`Sentinel-Node.conf.example`](Wheel/Script/v2/Sentinel-Node.conf.example) + espejo |

`Sentinel-Roam.sh` se probó contra el clúster real en los cinco escenarios: arranque
en casa, salida (espera confirmación y conmuta a la 2ª pasada), vuelta, **parpadeo
de un solo ciclo (no conmuta**, que es lo que evita el flapping de Raft**)** y nodo
fijo sin `ROAM_SEED` (sale sin tocar nada, así que se puede repartir a la flota
entera sin riesgo).

> **Bug que cazó el banco de pruebas**: `$PREFIX` solo existe en Termux, y bajo
> `set -u` la referencia mataba el script **en la pasada que tenía que conmutar**
> —justo esa—, dejando el nodo con el estado viejo para siempre. El síntoma habría
> sido "el script corre sin quejarse y no hace nada". Corregido con `${PREFIX:-}`
> y un valor por defecto.

### Lo que corre hoy: WireGuard con hub propio (2026-08-25)

Se eligió WireGuard sobre Tailscale para **no depender de un tercero**, y sobre
OpenVPN porque OpenVPN renegocia TLS entero en cada cambio de red y gasta más
batería — que son justo los dos ejes de este proyecto.

| Nodo | IP de malla | Papel |
|---|---|---|
| batchtoday (EC2, `18.221.108.18`) | `10.9.0.1` | hub — relé de toda la malla |
| sentinel014 | `10.9.0.14` | peer; extremo rqlite de la telemetría |
| sentinel019 (Pixel 6) | `10.9.0.19` | peer; el nodo móvil |
| laptop sentinel013 | `10.9.0.13` | reservada, **aún no instalada** |

Ficheros: `/etc/wireguard/wg0.conf` en el hub y en sentinel014 (600, root).
Claves privadas en `/etc/wireguard/*.key`. Servicio `wg-quick@wg0`, habilitado
al arranque en ambos. Security group AWS `sg-00c839f60bbbb792d`: regla
`sgr-0c8232cc45903a30a`, UDP 51820 desde `0.0.0.0/0`.

Decisiones de configuración que importan:

- **`AllowedIPs = 10.9.0.0/24`** en los peers, no `0.0.0.0/0`: solo el tráfico de
  la malla entra al túnel. La navegación del móvil no se toca.
- **`PersistentKeepalive = 25`**: sin esto el CGNAT del operador cierra la sesión
  y el hub no puede iniciar hacia el móvil. Es obligatorio, no opcional.
- **`net.ipv4.ip_forward=1` en el hub** (`/etc/sysctl.d/99-wireguard.conf`): los
  peers se hablan **entre sí a través del hub**, no directamente.
- **NO se anuncian rutas hacia `192.168.1.0/24`**, por lo explicado en el §4:
  el sondeo de `ROAM_SEED` dejaría de distinguir casa de calle.

Config del nodo móvil (`~/PRC_Sentinel/v2/sentinel.conf`):

```sh
ROAM_SEED=192.168.1.69                  # solo alcanzable en la LAN real
ROAM_SVC=rqlited
ROAM_CONFIRMA=2
RQLITE_FALLBACK=http://10.9.0.14:4001   # sentinel014 por la malla
```

### Verificado en vivo

**Ciclo de roaming completo**, observado de punta a punta:

```
20:25  veo 'fuera' pero declarado 'casa' (1 de 2): espero a confirmar
20:30  fuera de casa: rqlited abajo para no replicar Raft sobre datos moviles
20:39  fila de bateria nueva en el cluster, con rqlited abajo -> el fallback funciona
20:45  veo 'casa' pero declarado 'fuera' (1 de 2): espero a confirmar
20:50  roam.state casa|casa|2, rqlited arriba, cluster 11/11
```

**Sobre WireGuard**: agente v2 responde `Sentinel 2.0.0` en `10.9.0.19`, `401` sin
token, y SSH real de `10.9.0.14` a `10.9.0.19`. Latencia ~110 ms al hub y ~360 ms
entre peers (dos saltos por Ohio).

> **Peaje asumido a conciencia**: todo el tráfico de malla pasa por el hub, incluso
> entre dos equipos que están en la misma habitación. Tailscale conectaba directo
> en casa. Para unos KB cada 5 minutos da igual, pero conviene recordarlo antes de
> mover volumen por esta malla.

### Incidencias de la puesta en marcha

| Qué pasó | Causa | Cómo se resolvió |
|---|---|---|
| Se borró el crontab del móvil | se usó `/tmp`, que **no existe en Termux** (es `$TMPDIR`); el fichero intermedio quedó vacío y `crontab -` escribió solo la línea nueva | restaurado de `~/.cache/crontab/crontab.bak`, que `crontab` crea solo |
| La telemetría no llegaba estando fuera | `Sentinel-Bateria.sh` se modificó en el repo pero **no se desplegó** al móvil | desplegado; fila nueva confirmada con `rqlited` abajo |
| `qrencode` se quedaba colgado | el `<` de la redirección lo ejecuta el usuario, no root, y `/etc/wireguard` es 700 | usar `qrencode -r fichero`, que abre el fichero ya como root |
| WireGuard no activaba: *"túnel no autorizado"* | **Always-on VPN de Tailscale**: Android solo permite una VPN y la marcada como siempre-activa bloquea a las demás | desactivar Always-on en Tailscale antes de activar WireGuard |
| **sentinel019 perdió sshd otra vez** | sshd es el **único servicio del nodo que nadie supervisa** (lleva fichero `down`; lo arranca el script de arranque) | arrancado a mano en Termux. `restart-sshd` NO bastó: los jobs se quedaron colgados ocupando las dos ranuras de `MAXJOBS` |

## Correcciones del 2026-08-26

Dos correcciones de flota, ambas nacidas de observaciones hechas al desplegar el
arreglo del parser.

### 1. `sshd-guard` en los 8 nodos Termux

Los ocho tienen el mismo fichero `down` en el servicio `sshd` de runit que
sentinel019, es decir el mismo fallo latente: si sshd muere, no lo levanta nadie.

Desplegado `sshd-guard` + cron cada minuto en los 7 accesibles (sentinel019 ya lo
tenía). El guardián **deduce el puerto** de `sshd_config` en vez de fijarlo, para
seguir siendo correcto si algún día se cambia en un nodo. Ninguno de los nueve
tiene directiva `Port`, así que todos usan el 8022 por defecto de Termux.

| Nodo | Guardián | Cron | Prueba |
|---|---|---|---|
| sentinel001, 002, 003, 005, 009, 010, 018 | instalado | 1 línea | `ok: sshd ya escucha en 8022` |
| sentinel019 | ya estaba | 1 línea | `ok: sshd ya escucha en 8022` |
| sentinel017 | **pendiente** | — | nodo caído |

### 2. El token de flota, fuera de la línea de comandos

**El problema**: el token viajaba como `-v token=SECRETO` en el `argv` de gawk. En
Linux `/proc/<pid>/cmdline` es legible por cualquier usuario, mientras que
`fleet.token` está en 600. En Termux el alcance es menor (Android aísla los
procesos entre apps) y en Windows queda visible para procesos del mismo usuario.

**El riesgo del arreglo era mayor que el del fallo**, y eso condicionó el diseño.
`AuthState()` empezaba con:

```awk
if (Token=="") return "ok"    # sin token configurado (solo pruebas)
```

Es decir: una migración mal hecha no habría expuesto el token — habría dejado **los
12 agentes abiertos a la red**. Por eso el cambio incluye que falle **cerrado**.

**Qué cambió**, en cuatro sitios:

| Fichero | Cambio |
|---|---|
| `service/sentinel-start.sh` | `export SENTINEL_TOKEN="$TOKEN"` en vez de `-v token=` |
| `Sentinel-Server2.awk` | `Token = (length(token)>0) ? token : ENVIRON["SENTINEL_TOKEN"]` |
| `Sentinel-Server2.awk` | token vacío → `503`, no `"ok"`. Y `503` añadido al mapa de códigos de `Reply()` |
| `Sentinel-Server2.awk` | `SpawnJob()` ya no pasa `-v token=`: el worker **hereda el entorno** |
| `Sentinel-Worker.awk` | lee `ENVIRON["SENTINEL_TOKEN"]` para el callback |

Se mantiene el soporte de `-v token=` **a propósito**: permite desplegar el awk
nuevo con el lanzador viejo, así que el orden de despliegue deja de importar. Y
como ahora falla cerrado, cualquier combinación incompleta deja el nodo mudo, no
abierto.

### Cómo se validó

El `Sentinel-Selftest.sh` general **no sirve como red de seguridad para esto**:
en Windows falla entre 29 y 31 tests por entorno (red y temporizaciones) y los
resultados **varían entre ejecuciones** — una primera comparación sugirió 8
regresiones que resultaron ser ruido. Se estableció línea base ejecutándolo sobre
los ficheros originales en un sandbox antes de sacar conclusiones.

Por eso se escribió [`Sentinel-Selftest-Token.sh`](Wheel/Script/v2/Sentinel-Selftest-Token.sh),
determinista y centrado en el control de acceso. **9/9**:

| | Comprobación |
|---|---|
| A1-A2 | `-v token=` sigue funcionando (compatibilidad) |
| B1-B3 | token por entorno: 200 con token, 401 sin él, 401 con token ajeno |
| B4 | el worker **hereda** el token y completa el callback |
| B5 | el callback libera la ranura (`inflight=0`) |
| C1-C2 | **sin token configurado → 503**, no sirve nada |

> Dos fallos propios durante la validación, ambos corregidos: `Json(503,...)`
> devolvía `400` porque `Reply()` no conocía ese código; y el test B5 comprobaba
> `inflight` una sola vez, cuando el worker escribe el `.status` **antes** de mandar
> el callback — era una carrera de la prueba, no del código.

### Estado final

Verificado en las 11 máquinas accesibles: `200` con token, `401` sin él y con token
ajeno, 7 acciones en memoria, `NF=4` en la lista blanca y **el token ausente del
`argv`**.

**sentinel017 quedó fuera de las dos correcciones: lleva caído desde el 2026-08-24
00:16.** No responde en 8022, 8181 ni 4001, y rqlite lo da por inalcanzable. Su
última telemetría lo dejó al **100% de batería, enchufado y a 34 °C** — no es el
fallo de agotamiento de agosto, se calló de golpe estando sano. El Wheel
(sentinel016) lo tiene marcado como `caido` en `alert.state` y tiene credenciales
de Telegram configuradas.

**Al recuperarlo hay que aplicarle las tres cosas**: arreglo del parser,
`sshd-guard` + cron, y el token por entorno.

### Pendiente

1. **sshd sin supervisor.** Mitigado el 2026-08-26 con `sshd-guard` (ver abajo),
   pero la causa de fondo sigue: sshd y crond son los dos unicos servicios con
   fichero `down` en runit. Migrarlos es la solucion definitiva; hacerlo con el
   telefono enchufado y en la mano, siguiendo el procedimiento del red team.

### sshd-guard y el bug del parser (2026-08-26)

**Bug encontrado, con impacto en los 12 equipos**: la accion de rescate
`restart-sshd` **nunca funciono**. Su plantilla contenia `||`, y
[`LoadAllow()`](Wheel/Script/v2/Sentinel-Worker.awk:35) hace `split(linea, f, "|")`
quedandose con `f[4]`: la mitad que arranca sshd se descartaba en silencio.
Demostrado con gawk sobre el fichero real (NF=6 en vez de 4).

> **Regla nueva: ninguna plantilla de `Sentinel-Allow.conf` puede contener `|`.**
> Usar `if/fi` y `;` en lugar de `&&`/`||`.

**Desplegado a los 12 equipos el 2026-08-26.** Los 10 nodos remotos, la laptop
(que lee su copia de `~/PRC_Sentinel/v2/`, **no del repo**) y sentinel019.
Verificado: `NF=4`, 7 acciones en memoria y la accion completando en los 12, con
respuesta adecuada por plataforma (Termux arranca sshd; Ubuntu responde "no aplica").

> **Segundo fallo, independiente, encontrado al desplegar**: `sentinel005` y
> `sentinel014` tenian **6 acciones en memoria en vez de 7**. El servidor carga la
> lista blanca **solo al arrancar** ([`Sentinel-Server2.awk:356`](Wheel/Script/v2/Sentinel-Server2.awk:356)),
> y sus agentes llevaban corriendo desde antes de que se anadiera `restart-sshd`
> el 2026-08-14: **nunca la habian aceptado**. Se creia desplegada en 12 maquinas y
> en dos de ellas devolvia "accion no esta en la lista blanca". Resuelto
> reiniciando los dos agentes.
>
> **Leccion**: anadir una accion nueva a `Sentinel-Allow.conf` NO basta; hay que
> reiniciar el agente. Cambiar el comando de una accion **existente** si basta,
> porque el worker relee la lista en cada trabajo.

**Pendiente**: los 8 nodos Termux tienen el mismo fichero `down` en sshd que
sentinel019, y ninguno tiene `sshd-guard`. Su accion de rescate ahora funciona,
pero arranca sshd **a ciegas** (no puede verificar). Desplegar el guardian a los 8
les daria la misma proteccion automatica.

Reescrita sin `|` y **manteniendo el nombre**, asi que no hizo falta reiniciar el
agente: el worker relee la lista en cada trabajo
([`Sentinel-Worker.awk:96`](Wheel/Script/v2/Sentinel-Worker.awk:96)) y el servidor
solo valida el nombre. Verificado: `status done`, `rc 0`, sin colgarse.

**`sshd-guard`** ([`Wheel/Script/v2/sshd-guard.sh`](Wheel/Script/v2/sshd-guard.sh)),
por cron cada minuto. Comprueba el **puerto**, no el proceso.

> Dos intentos fallidos antes de acertar con la deteccion: `pgrep` miente, y
> `/proc/net/tcp` da **`Permission denied`** en este Pixel (Android lo bloquea a
> las apps sin privilegios). Lo que si funciona es `/dev/tcp` de bash: una prueba
> funcional que no depende de permisos.

**Se estreno solo**: el telefono se reinicio durante el despliegue, el
`pgrep -x sshd` del script de arranque mintio diciendo que sshd ya corria, sshd no
arranco — y `sshd-guard` lo levanto en su primera ejecucion. La tercera caida de
sshd de este nodo, resuelta sin intervencion.
2. ~~Retirar Tailscale de sentinel014~~ **HECHO (2026-08-25)**: `tailscale logout`,
   servicio deshabilitado, paquete purgado, repo/keyring y `/var/lib/tailscale`
   eliminados. Verificado: sin binario, sin units, sin `tailscale0`, y WireGuard
   y los servicios de producción intactos.
   **Falta desinstalar la app del Pixel** (`com.tailscale.ipn`) — no se puede en
   remoto: Android no deja que una app desinstale a otra sin root. Y borrar los
   dos dispositivos en la consola de Tailscale.
3. **WireGuard en la laptop** (`10.9.0.13`), si se quiere administrar el móvil
   desde fuera de casa. Mientras tanto:
   `ssh -J sentinel014 -p 8022 sentinel@10.9.0.19`.
4. Reemitir el certificado con `10.9.0.19` en el SAN (§5.7). No urgente: hoy nada
   del v2 usa el 8443.

---

## 9. Alternativas descartadas

| Opción | Por qué no |
|---|---|
| **Túnel SSH inverso a batchtoday** | Ya se probó y funcionó (2026-07-25, [`Nodos/README.md:355`](Nodos/README.md:355)), pero solo da **administración**, no pertenencia: no hace al móvil alcanzable por los demás nodos ni por Raft. Además arrastra el fallo del puerto reenviado retenido, que se manifestaba justo al cruzar de WiFi a datos móviles. |
| **Mantener node11 como voter en LTE** | Cientos de MB al mes de replicación y batería, en un teléfono personal. |
| **Sacar a sentinel019 del clúster** | Resolvería el coste, pero pierde la réplica local también en casa, que es donde sí sale gratis. |
| **Reescribir el v2 a modelo push** | El endpoint ya existe (`/ingest/eye`), pero resolvería el *descubrimiento* sin resolver la *alcanzabilidad*: los demás seguirían sin poder abrirle conexión. Sería trabajo grande para media solución. |
