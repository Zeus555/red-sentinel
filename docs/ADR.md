# ADR — Architecture Decision Records de RED Sentinel

> **Procedencia:** este documento proviene del knowledge graph del proyecto
> (codebase-memory, proyecto `D-RED-Sentinel`), exportado con
> `manage_adr(mode='get')` el **2026-09-01** para quedar versionado en git.
> La copia maestra vive en el knowledge graph; tras cada `index_repository`
> hay que volver a guardarla alli con `manage_adr(mode='update')`
> (el reindexado la borra — comprobado el 2026-08-24).

---

## PURPOSE

Red Sentinel es una flota de 12 equipos domesticos (moviles Android con Termux,
dos tablets Amazon Fire, dos Linux y una laptop Windows) que se vigilan entre si
y ejecutan trabajo util en conjunto. La carga real es **registrar precio de
criptomonedas cada 10 segundos** en una base replicada, sin agujeros en la serie.

Objetivo de diseno dominante: **disponibilidad sobre potencia**. Los nodos son
telefonos que Android apaga, congela y desconecta a voluntad.

> ⚠️ **`index_repository` BORRA este ADR.** Tras cada reindexado hay que volver a
> guardarlo con `manage_adr(mode='update')`. Comprobado el 2026-08-24.

> 📘 El detalle historico completo (5 generaciones, orderbook, arbitraje, los
> conectores de cada exchange y las 7 versiones del colector) esta en
> **`HISTORIA_CRIPTO.md`** en la raiz del repo.

## STACK

- **Servidor HTTP: gawk** (`Sentinel-Server2.awk`) sobre `/inet4/tcp/PORT/0/0`.
  No tiene TLS nativo y **siempre ata 0.0.0.0**, lo que condiciona la seguridad.
- **Base: rqlite** (Raft sobre SQLite), 11 nodos. Semilla: sentinel001.
- **mTLS: stunnel** en el 8443, delante del backend gawk.
- **Supervision:** runit en Termux, systemd `--user` en los Linux. Arranque
  Android via **Termux:Boot** (`~/.termux/boot/00-services.sh`).
- **Fuente de precio:** contenedor Docker `prc-agent-jupiter` en sentinel016:3011
  (Chrome headless que mantiene viva una pagina de Jupiter).

Puertos: **8181** gawk · **8443** mTLS · **4001** rqlite · **4002** Raft ·
**8022** sshd Termux · **3011** agente Jupiter.

## ARCHITECTURE

### Inventario (2026-08-24)

| Nodo | IP | Plataforma | Papel |
|---|---|---|---|
| sentinel001 | .69 | Termux | semilla de Raft (node1, sin `-join`) |
| sentinel002 | .65 | Termux | |
| sentinel003 | .94 | Termux | tope de carga ~80 %, ausencias ~15 % aceptadas |
| sentinel005 | .252 | Termux | |
| sentinel009 | .124 | Amazon Fire KFRAWI | **gemela fisica de 010** |
| sentinel010 | .190 | Amazon Fire KFRAWI | **gemela fisica de 009** |
| sentinel013 | .117 | Windows/git-bash | laptop. NO guarda BD, NO elegible como Wheel |
| sentinel014 | .250 | Linux | Wheel actual · recolector |
| sentinel016 | .91 | Ubuntu | **aloja el agente Jupiter** · recolector · lider Raft |
| sentinel017 | .212 | Termux | inestable, se cae repetidamente |
| sentinel018 | .211 | Termux | |
| sentinel019 | .210 | Termux | movil personal: `SKIP_NODES`, no elegible |

### Eleccion del Wheel

No hay coordinador fijo: la red lo elige por **aptitud** (`Sentinel-Wheel.awk`),
gana el mas disponible, no el mas potente. Se escribe en `wheel.state`, que cambia
lo que responde `/version` sin reiniciar. El aceptador NO dispara la eleccion
(`ELECTSECS=0`): la lanza cron, porque hacerlo en su bucle mataba el servicio.

### Subsistema de precio actual (`Sentinel-Cripto.sh`)

```
cripto_precio (par, exchange, ts, precio, edad_ms, nodo,
               PRIMARY KEY (par, exchange, ts))
```

Rejilla de 10 s (`epoch/10*10`) con `INSERT OR IGNORE`. **Redundancia deliberada:**
varios nodos muestrean el MISMO instante (`CRIPTO_NODOS=sentinel014,sentinel016`
mas quien sea Wheel); si uno se atasca, el otro ya escribio la fila. Cron de 1
minuto con bucle interno de 57 s. Retencion 90 dias.

Medido 2026-08-24: 28.267 filas, **99,977 % de cobertura en 24 h**, 0 rancias,
edad media 578 ms, reparto 014:4.387 / 016:4.251.

### Historia del trabajo cripto (ver HISTORIA_CRIPTO.md)

`Wheel/OLD/Sentinel00X/PRC_Crypto_Trends/` contiene **dos lineas paralelas**,
paradas desde 2024:

- **Linea CEX** — `DWD Get Price.awk`. Unico sitio del repo que captura **libro de
  ordenes**: `dwd_price(market, product, ask, ask_size, ask_numorders, bid,
  bid_size, bid_numorders, ...)` de Coinbase y Kraken en UNA tabla, que es el
  sustrato del **arbitraje**. Los datos llegan por un proxy propio en AWS
  (`batchtoday.us/price` y `:2053/price`), **no** por API directa: la logica de
  hablar con los exchanges NO esta en este repo.
  **La consulta de arbitraje nunca se escribio** (solo existe el nombre del
  temporal, `_ArbitAll.tmp`), `dwd_price` era tabla de foto (`delete` + insert) y
  **la tabla ya no existe en ninguna Hot.db superviviente**. Abandonada.
- **Linea DEX** — Jupiter y Raydium. Es la que corrio de verdad (752 temporales).
  `JUPI_Get_Price.awk` sintetiza un spread **preguntando dos veces en sentidos
  opuestos** (`ids=BASE&vsToken=QUOTE` para el ask; el inverso 1/x para el bid),
  lo que captura deslizamiento y comisiones reales sin libro de ordenes.
  `RAYD_Get_Price.awk` trae pools AMM (`ammId, liquidity, price`).

Almacen por capas: `dwd_` (foto) → `dwf_` (historico) → `dws_` (maximos/minimos
por token) + dimensiones en fichero (`Alias.dim` usa **IDs de CoinMarketCap**).

⚠️ `dwd_price_tokens` tiene **columnas distintas** en sentinel001 (Jupiter:
ask/bid) y sentinel002 (Raydium: ammId/liquidity). Mismo nombre, dos esquemas.

## PATTERNS

### El trabajo sigue al Wheel, sin configurar nada

Los scripts corren por cron en TODOS los nodos y cada uno comprueba si le toca
(`wheel.state` == `NAME`, o estar en `CRIPTO_NODOS`). Al haber relevo el trabajo
migra solo.

### Jitter determinista contra la estampida

Todo arrancaba en `:00` y los nodos se tumbaban entre si. Se reparte con `cksum`
de `<nombre>-<tarea>` modulo 120: desfase **estable por nodo**, no aleatorio.
Los fallos en `:00` bajaron del 97 % al 6 %.

### Un nodo atascado es peor que uno caido

`/nodes` de rqlite hace **sondeos EN VIVO**, asi que se vuelve lento justo cuando
la red va mal. Un nodo atascado llevo `/nodes` de 40 ms a >30 s y rompio en
silencio la busqueda de candidatos, `peers.tsv`, la corroboracion y las alertas.
**Toda llamada va acotada** con `?timeout=Ns` (2 s general, 5 s corroboracion).

### Defensa en 4 capas contra el split-brain del Wheel

Doble sondeo (`Prueba()` reintenta al doble de timeout) + `MaxMiss=2` +
**corroboracion por transporte distinto** (`WheelAlcanzable()` pregunta a rqlite,
que viaja por otro camino) + ventana de asentamiento `WHEEL_SETTLE=420`.

### Avisar por tendencia, no por estado instantaneo

Se compara contra el estado anterior (`alert.state`, 4 campos). Snapshots viejos
se descartan (`STATE_MAX=1800`) preservando nombres. Tolerancias por nodo via
`GRACE_NODES`.

### Zona horaria fijada en la configuracion, no en el aparato

`TZ` va **exportada** en `sentinel.conf` (lo leen los 7 scripts que hacen
`source`), porque la flota mezcla Ubuntu, Termux y Fire OS. Los datos no dependen
de esto (todo usa `date +%s`); los logs y las consultas si.
**Excepcion Windows:** git-bash no trae `/usr/share/zoneinfo`, asi que alli se usa
la forma POSIX `PST8PDT,M3.2.0,M11.1.0`.

## TRADEOFFS

### El token es lo unico que protege el backend

gawk no hace TLS y **siempre ata 0.0.0.0**: el 8181 es alcanzable sin pasar por
stunnel. El secreto de flota es la unica barrera (3 fallos → 30 s de bloqueo). Por
eso el servicio `cmd` esta limitado a una lista blanca **a proposito**, y debe
seguir asi. Certificados mTLS: renovar antes de **noviembre de 2028**.

### rqlite replica la base ENTERA en cada nodo

La capacidad util **no** es la suma de discos: es el disco libre del nodo mas
pequeno. A 10 s son 8.640 filas/dia; 90 dias ≈ 125 MB.

### El agente Jupiter es un punto unico de fallo

Vive solo en sentinel016. La redundancia protege de que falle un **nodo**, no de
que falle el **agente**: los dos recolectores preguntan al mismo sitio. Ademas
solo sostiene UNA moneda caliente — al alternar simbolos devuelve valores de
15-20 s. Por eso se consulta **solo WBTC**.

### La generacion actual perdio el libro de ordenes

Hoy se guarda un precio unico, sin bid ni ask. La version de 2024 capturaba
profundidad (tamano y numero de ordenes por lado). Para volver al arbitraje hay
que recuperar aquello.

### Un recolector permanente mata un telefono

Convertir sentinel018 en recolector lo rompio: el bucle de 57 de cada 60 segundos
es un proceso permanentemente vivo y Android lo mata. Fue el unico nodo con cortes
(3 cortes, 255 min/24 h) y aporto 0 de 2.893 muestras. **Los recolectores deben ser
los Linux, no los moviles.**

## PHILOSOPHY

### Medir antes de concluir, y desconfiar del propio metodo

Hipotesis plausibles que resultaron falsas: la saturacion de sentinel016 (pico
real 0,76 s), la radio de sentinel005 (20/20 correctos), un corte termico de carga
a 42 °C (refutado: cargaba a 42 y paraba a 38; era el tope del ~80 %), y una
prediccion de muerte por bateria en 6 h extrapolada de **una sola muestra** (el
historico mostraba el nivel clavado en 78-80 %). **No extrapolar de un punto.**

El metodo puede enmascarar el fallo: medir sentinel005 **por SSH** dio 47 muestras
sin un error, porque SSH mantiene el telefono despierto. La condicion solo aparece
con una sonda por cron en el propio nodo.

### Fallos que no dan error

El patron mas caro no es el que revienta, es el que **responde algo plausible**:

- Jupiter con un parametro mal escrito (`a=`, `pair=`, `id=`) **no da error:
  devuelve SOL**. Documentado en 2024 (`JUPI_Get_Price.awk`) y **redescubierto en
  2026** (`Sentinel-Cripto.sh`). Ambas generaciones lo resolvieron igual: validar
  que el activo devuelto sea el pedido ANTES de guardar.
- `TZ=America/Los_Angeles` en git-bash **no falla: cae a GMT**.
- Un precio rancio re-guardado **no deja un hueco: deja una linea plana**, que
  parece dato bueno. De ahi que `edad_ms` sea columna y no descarte.

### Herramientas de diagnostico que mienten en Termux

- `pgrep`, `ps` y `netstat` dan respuestas falsas. Usar **`sv status`** y matar
  por PID.
- `pkill -f <patron>` **mata tu propia sesion SSH**.
- `ps | grep -c X` se cuenta a si mismo (dio 4 crond habiendo 1).
- `sv up <svc>` falla sin ruta completa: `$PREFIX/var/service/<svc>`.
- `grep '"reachable":true'` no encuentra nada: el JSON lleva un espacio. Este
  error hizo reportar "0/11 alcanzables" siendo 11/11.
- Tras apagarse por bateria agotada, Android **suspende Termux:Boot hasta el
  siguiente reinicio limpio**. Ejecutar el script a mano no lo resuelve.
- Las tablets sentinel009 y sentinel010 son **fisicamente identicas** (Amazon
  KFRAWI): un cambio destinado a una acabo en la otra. Para distinguirlas se usa
  `termux-notification` + `termux-vibrate`, que las identifica en fisico.

### Deuda conocida

- `Nodos/prc_sentinel/Script/v2/` (copia de referencia para desplegar) ha divergido
  de `Wheel/Script/v2/`: conserva la version **antigua de Coinbase** de
  `Sentinel-Cripto.sh` y un `.conf.example` sin `CRIPTO_NODOS`.
- `rqlited` **no hace `source` de `sentinel.conf`**: la TZ fijada ahi no le llega.
  Si sentinel009/010 llegan a lideres de Raft, `localtime` saldra 1 h desfasada
  (su Android sigue en `America/Denver`).
- El agente Jupiter consume ~127 % de CPU sostenido y su RAM sube despacio
  (1,745 → 1,94 GiB sobre un limite de 2,761 GiB en 25 h).
- sentinel017 se cae repetidamente sin ser problema de energia (ultima lectura:
  100 %, enchufado, 33 °C).
- `RAYD_Main.sh` y `RAYD_Hot.sh` son byte a byte identicos.

