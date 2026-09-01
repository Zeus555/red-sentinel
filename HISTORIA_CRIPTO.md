# Red Sentinel — Linaje de versiones y el trabajo con criptomonedas

> Documento de arqueología y estado, escrito el **2026-08-24** a partir de leer el
> código, los esquemas SQLite supervivientes y los ficheros temporales que
> quedaron. Complementa a [README.md](README.md) (qué hay en el repo),
> [ROLLOUT_v2.md](ROLLOUT_v2.md) (cómo se despliega) y
> [Nodos/README.md](Nodos/README.md) (inventario de servicios).
>
> Hay además un ADR consultable en el grafo de código
> (`manage_adr(project="D-RED-Sentinel", mode="get")`) con la arquitectura viva.

---

## 1. Cómo leer este repo

El repositorio mezcla **cinco generaciones** de un mismo proyecto. No están
separadas por ramas ni por tags, sino por carpetas, y algunas comparten nombre de
fichero con contenidos completamente distintos. Este es el mapa:

| Carpeta | Generación | Estado |
|---|---|---|
| `Wheel/OLD/Script20240706/Versiones/` | G0 · 2020 | laboratorio, arqueología |
| `Wheel/OLD/Script20240706/` | G1 · 2021 | arqueología |
| `Wheel/OLD/Sentinel00X/PRC_Crypto_Trends/` | G2 · 2022-2024 | **el trabajo cripto**, parado |
| `Wheel/Script/` (raíz) | G3 · 2024-2025 | Sentinel v1, parado |
| `Wheel/Script/v2/` | G4 · 2026 | **en producción** |
| `Nodos/prc_sentinel/Script/v2/` | G4 espejo | copia de despliegue (ver §8) |

`Wheel/OLD/PYT Router/` **no es de este proyecto**: es un driver WiFi Realtek
vendorizado (1.240 ficheros `.c/.h`). Está excluido del índice de código en
[.cbmignore](.cbmignore) porque generaba 163.952 nodos de ruido.

---

## 2. Línea temporal

### G0 · 2020 — Aprender a hacer HTTP con gawk

`Wheel/OLD/Script20240706/Versiones/` conserva la secuencia de prueba y error,
fechada al día: `inetlib 20201031_17.awk`, `ServidorHttp 20201017.awk`,
`TestServer20201017_09/12/17.awk`, `WebSocket 20201107_07/11.awk`.

Aquí se resuelve el problema fundacional del proyecto: **gawk puede abrir sockets**
(`/inet4/tcp/PORT/0/0`) y por tanto puede ser un servidor HTTP. Todo lo demás sale
de ahí. Incluso hay un `Sec-WebSocket-Accept.py` porque el handshake de WebSocket
necesita SHA-1 y base64, que awk no trae.

### G1 · 2021 — El primer Sentinel

`Sentinel.awk`, `Sentinel-Server.awk`, `Sentinel-Client.awk` (agosto 2021, 361
bytes cada uno). Esqueletos mínimos. `Wheel/OLD/MobilAgente/` añade `mobag.awk`:
el primer intento de llevarlo a un móvil.

### G2 · 2022-2024 — PRC_Crypto_Trends *(el grueso de este documento)*

Un proyecto paralelo, con vida propia, montado sobre Termux y SQLite. Es donde
está **todo lo de orderbook, liquidez y arbitraje**. Ver §3 a §6.

### G3 · 2024-2025 — Sentinel v1

`Wheel/Script/`. Agente HTTP en gawk con despacho **EYE/clone** en los puertos
**8081-8100** y descubrimiento por barrido `/24`. `Sentinel-Server.awk` llegó a
24.110 bytes. Tiene tres superficies de RCE sin autenticar (`cmd`, `addprice`,
`addproducts`) — motivo por el que está parado y no debe reactivarse tal cual.

### G4 · 2026 — Sentinel v2 *(producción)*

`Wheel/Script/v2/`. Reescritura completa: **puerto único** 8181 con modelo de
workers paralelos, coordinador (*Wheel*) **electivo por aptitud**, base replicada
**rqlite** en 11 nodos, **mTLS** por stunnel en el 8443 y token de flota
obligatorio. Es la generación que hoy recoge el precio.

---

## 3. El trabajo con criptomonedas: dos líneas paralelas

Lo que más confunde al volver a este código es que `PRC_Crypto_Trends` no es un
proyecto sino **dos**, con esquemas distintos y hasta con el mismo nombre de tabla
significando cosas diferentes según el nodo.

| | **Línea CEX** | **Línea DEX** |
|---|---|---|
| Mercados | Coinbase, Kraken | Jupiter, Raydium (Solana) |
| Unidad | par de trading (`BTC-USD`) | token / pool AMM |
| Qué mide | **libro de órdenes** (bid/ask, tamaño, nº órdenes) | precio y **liquidez** del pool |
| Tabla | `dwd_price` | `dwd_price_tokens` |
| Objetivo | **arbitraje entre exchanges** | detectar extremos de liquidez |
| Nodo | sentinel001 | sentinel001 (Jupiter) · sentinel002 (Raydium) |
| ¿Llegó a correr? | **no sobrevive evidencia** | **sí** (752 temporales) |

---

## 4. Línea CEX — orderbook y arbitraje

### 4.1 Qué captura

`Wheel/OLD/Sentinel001/PRC_Crypto_Trends/Script/DWD Get Price.awk` (junio 2024) es
el único fichero de todo el repositorio que captura **libro de órdenes**. Recoge el
**tope del libro (Level 1)** de dos mercados y los deja **en la misma tabla**:

```sql
insert into dwd_price(
    market, product,
    ask, ask_size, ask_numorders,
    bid, bid_size, bid_numorders,
    dateupdate, lastupdate) values (...)
```

Guardar `ask_numorders` y `bid_numorders` junto al tamaño es la decisión
interesante: no basta con saber que hay 2 BTC ofertados a X, importa si son **una
orden de 2 o veinte de 0,1**, porque cambia por completo lo que pasa si intentas
barrer ese nivel. Es información pensada para ejecutar, no para graficar.

### 4.2 De dónde salen los datos

No consulta a los exchanges directamente. Ambos mercados llegan por un **proxy
propio en AWS**:

| Mercado | Endpoint |
|---|---|
| Coinbase | `https://batchtoday.us/price` |
| Kraken | `https://batchtoday.us:2053/price` |

Es la misma máquina que aparece como host `batchtoday` en `~/.ssh/config`
(`18.221.108.18`). El script además simula un User-Agent de Chrome y tiene
preparada, comentada, una salida por `socks5://127.0.0.1:8080`.

**Consecuencia para quien reordene esto:** la lógica de hablar con Coinbase y
Kraken **no está en este repositorio**. Vive en el proxy. Lo que hay aquí es el
consumidor, que espera un JSON ya normalizado con los campos
`name, ask, ask_size, ask_numorders, bid, bid_size, bid_numorders, dateupdate, lastupdate`.

### 4.3 El arbitraje: intención documentada, cálculo ausente

El fichero temporal que genera el proceso se llama:

```awk
FchSQL = DirTemporal IdExec "_ArbitAll.tmp"
```

**`ArbitAll`** es la única mención a arbitraje en todo el proyecto. Y el diseño lo
respalda: meter Coinbase y Kraken en una sola tabla con `market` como columna es
exactamente lo que se hace cuando el paso siguiente es comparar el `bid` de un
mercado contra el `ask` del otro para el mismo `product`.

Ahora la parte incómoda, y conviene decirla clara:

> **La consulta de arbitraje no existe en el repositorio.** Busqué un `SELECT` que
> cruce `dwd_price` consigo misma o que filtre por `market <> market`: no hay
> ninguno. Lo que está construido es el **sustrato** — la captura sincronizada de
> ambos libros — no el cálculo.

Además, `dwd_price` es una tabla **de foto, no de histórico**: cada ejecución hace
`delete from dwd_price;` antes de insertar. Sirve para detectar una oportunidad
*ahora*, no para estudiar cuántas hubo el mes pasado.

### 4.4 Y la tabla ya no está

Revisé las dos bases `Hot.db` que sobrevivieron (sentinel001, 18 MB; sentinel003,
14 MB). Ninguna contiene `dwd_price`:

```
Hot.db -> dwd_tokens, dwd_price_tokens
```

Los temporales que quedaron son **404 `JUPI_GetPrice.tmp` y 348
`JUPI_GetTokens.tmp`**, ni uno solo de `_ArbitAll.tmp`. La conclusión honesta es
que **la línea CEX se abandonó antes de consolidarse**, y que lo último que estuvo
corriendo de verdad fue la línea DEX de Jupiter.

Si vas a retomar el arbitraje, **empiezas por aquí**: el capturador está escrito y
es bueno, pero hay que recrear la tabla, decidir si pasa a histórico, y escribir el
cálculo que nunca se escribió.

---

## 5. Línea DEX — Jupiter y Raydium

### 5.1 Jupiter: un spread sintético a partir de dos consultas

`JUPI_Get_Price.awk` resuelve un problema real: la API de precios de Jupiter no da
libro de órdenes, da **un precio de ruta**. Un agregador DEX no tiene bid ni ask.

La solución es elegante — **preguntar dos veces, en sentidos opuestos**:

```awk
# ASK: cuánto cuesta el base medido en quote
curl "https://price.jup.ag/v6/price?ids=BASE&vsToken=QUOTE"   ->  ask

# BID: cuánto cuesta el quote medido en base, y se invierte
curl "https://price.jup.ag/v6/price?ids=QUOTE&vsToken=BASE"   ->  bid = 1/precio
```

La diferencia entre ambos **es el coste real de ida y vuelta**: deslizamiento,
comisiones y profundidad del pool, todo junto. Es un spread efectivo obtenido sin
libro de órdenes. Para comparar contra un CEX es incluso más honesto que el bid/ask
nominal, porque ya incorpora lo que te va a costar ejecutar.

### 5.2 El fallo silencioso que lleva dos años mordiendo

En el mismo fichero, en 2024:

```awk
# En caso que se busca el precio del token pero este no existe,
# y el servicio te devuelve por defecto SOL-USDC
if (sbase=="SOL" && squote=="USDC"){ ask=0; bid=0 }
```

Y en `Wheel/Script/v2/Sentinel-Cripto.sh`, en 2026:

```sh
# OJO CON EL PARAMETRO: solo `symbol=` y `token=` funcionan. Con `a=`, `pair=` o
# `id=` el agente NO da error: devuelve SOL como si nada.
```

**Es el mismo fallo, con dos años de diferencia y en dos implementaciones
distintas.** Jupiter no responde con un error cuando no encuentra lo que pides:
responde con SOL. Ambas generaciones tuvieron que aprenderlo por su cuenta y ambas
lo resolvieron igual — **validando que el activo devuelto sea el pedido antes de
guardar**. Que esté escrito aquí es para que la tercera no lo redescubra.

### 5.3 Catálogo de tokens

`JUPI_Get_Tokens.awk` descarga `https://token.jup.ag/all` y llena `dwd_tokens`
(**115.420 filas** en la base superviviente), con filtros deliberados: descarta
símbolos vacíos, con espacios o de más de 20 caracteres — defensa básica contra
tokens basura y contra intentos de inyección por el nombre.

### 5.4 Raydium: pools AMM y liquidez

`Wheel/OLD/Sentinel002/PRC_Crypto_Trends/Script/RAYD_Get_Price.awk` consume
`https://api.raydium.io/v2/main/pairs` y extrae por pool:

```
ammId, baseMint, quoteMint, liquidity, price
```

Aquí la unidad de análisis no es el par sino **el pool concreto** (`ammId`), y la
métrica que importa es la **liquidez**, no el precio: un precio en un pool sin
fondo no significa nada.

> ⚠️ **Trampa de esquema.** La tabla se llama `dwd_price_tokens` igual que en
> sentinel001, pero **tiene columnas distintas**:
>
> - sentinel001 (Jupiter): `dateinsert, dateupdate, market, address, product, ask, bid`
> - sentinel002 (Raydium): `ammId, baseMint, quoteMint, liquidity, price`
>
> Mismo nombre, dos significados. Si unificas los nodos sin mirar, machacas datos.

### 5.5 Kraken, aquí, es un catálogo

`KRAK_Get_Products.awk` **no** trae precios: consume
`https://api.kraken.com/0/public/AssetPairs` y llena `dwd_products` y `dwd_alias`.
Es la dimensión de qué pares existen y cómo se llaman en cada sitio. Los precios de
Kraken venían por el proxy (§4.2).

---

## 6. El almacén de datos

`PRC_Crypto_Trends` no vuelca a una tabla plana: implementa un **almacén por capas**
con nomenclatura consistente.

| Prefijo | Significado | Comportamiento |
|---|---|---|
| `dwd_` | **Detail** — la foto de ahora | se borra y se reescribe cada ejecución |
| `dwf_` | **Fact** — el histórico | se acumula (`INSERT ... SELECT` desde `dwd_`) |
| `dws_` | **Summary** — los extremos | mantiene máximos y mínimos por token |
| `.dim` | dimensiones en fichero | `Config/Alias.dim`, `Config/TypePrice.dim` |

El flujo, en `Wheel/OLD/Sentinel002/PRC_Crypto_Trends/Script/`:

```
captura  →  DWD_*  →  DWF_PRICE_TOKENS.sql  →  DWS_TOKENS_*.sql
 (awk)      (foto)      (histórico)            (máximos/mínimos)
                             ↓
                     PartitionDWF.sh  (particionado del histórico)
                       UpdateDIM.sh   (refresco de dimensiones)
```

`DWS_TOKENS_LIQUIDITY.sql` merece una lectura: mantiene por token el **máximo y el
mínimo histórico de liquidez junto con el precio al que ocurrieron**. Hace tres
pasadas — actualizar los que superan el máximo, actualizar los que bajan del
mínimo, e insertar los tokens nuevos. Hay equivalentes para `PRICE`, `CHANGE1H` y
`CHANGE24H`.

Las dimensiones son pequeñas pero reveladoras:

- `Alias.dim` → `1;BTC` `1027;ETH` `2010;ADA` — son **IDs de CoinMarketCap**, o sea
  que hubo una integración con CMC en la generación de 2022.
- `TypePrice.dim` → `spot`, `sell`, `buy`, `ticker` — los cuatro tipos de precio de
  la API v2 de Coinbase. Ya entonces se distinguía precio de compra y de venta.

---

## 7. Todas las versiones del colector de precio, en una tabla

| # | Fecha | Fichero | Fuente | Qué capturaba | Destino | Estado |
|---|---|---|---|---|---|---|
| 1 | ago 2022 | `GetPrice.awk` + `.sh` | `api.pro.coinbase.com/.../ticker` y `api.coinbase.com/v2/prices/` | ticker y spot/buy/sell por alias CMC | SQLite | arqueología |
| 2 | jun 2024 | **`DWD Get Price.awk`** | proxy AWS → Coinbase + Kraken | **libro L1: bid/ask, tamaño y nº de órdenes** | `dwd_price` | **abandonado; la tabla no sobrevive** |
| 3 | jun 2024 | `JUPI_Get_Price.awk` | `price.jup.ag/v6` (dos consultas invertidas) | ask y **bid sintético** | `dwd_price_tokens` | corrió de verdad (404 temporales) |
| 4 | jun 2024 | `JUPI_Get_Tokens.awk` | `token.jup.ag/all` | catálogo de 115.420 tokens | `dwd_tokens` | corrió (348 temporales) |
| 5 | jun 2024 | `RAYD_Get_Price.awk` | `api.raydium.io/v2/main/pairs` | pools AMM: `ammId`, liquidez, precio | `dwd_price_tokens` *(otro esquema)* | sentinel002 |
| 6 | jun 2024 | `KRAK_Get_Products.awk` | `api.kraken.com/0/public/AssetPairs` | catálogo de pares y alias | `dwd_products`, `dwd_alias` | sentinel002 |
| 7 | ago 2026 | **`Sentinel-Cripto.sh`** | agente `prc-agent-jupiter` local | precio WBTC y **`edad_ms`** | `cripto_precio` (rqlite) | **producción** |
| 8 | ago 2026 | **`Sentinel-Libro.sh`** | API propia AWS → Coinbase L1 | **libro: ask/bid + tamaño + nº órdenes** | `cripto_libro` (rqlite) | **producción** |
| 9 | ago 2026 | **`Sentinel-Profundidad.sh`** | Coinbase Advanced Trade, **directo** | **VWAP ejecutable** caminando el libro, por tamaño de clip | `cripto_profundidad` (rqlite) | **producción** |

### La versión actual (7), en detalle

```sql
cripto_precio (par, exchange, ts, precio, edad_ms, nodo,
               PRIMARY KEY (par, exchange, ts))
```

Rompe con todas las anteriores en tres cosas:

1. **La base es replicada** (rqlite/Raft en 11 nodos), no un SQLite local por nodo.
   Como rqlite replica la base **entera** en todos, la capacidad útil de la red es
   el disco libre del nodo **más pequeño**, no la suma.
2. **Varios nodos muestrean el mismo instante a propósito.** El instante se redondea
   a la rejilla de 10 s y forma parte de la clave, con `INSERT OR IGNORE`: si uno se
   atasca, el otro ya escribió esa fila y no queda hueco. Medido en 24 h: **99,977 %
   de cobertura**, reparto sentinel014 4.387 / sentinel016 4.251.
3. **`edad_ms` es una columna, no un descarte.** Si una muestra llega vieja queda
   constancia en el dato. Es la lección de que *un precio rancio re-guardado no deja
   un hueco: deja una línea plana*, que parece dato bueno y es peor que un agujero.

Y una regresión respecto a la generación de 2024: **hoy solo se guarda un precio,
sin bid ni ask**. La fuente es un Chrome headless que sostiene **una sola moneda
caliente** (WBTC); al alternar símbolos devuelve valores de 15-20 s. Si se quiere
volver al arbitraje habrá que recuperar la captura de libro de la versión 2.

---

## 7 bis. El libro de Coinbase, reactivado (2026-08-29)

La línea CEX volvió, pero por otro camino: no se resucitó el `DWD Get Price.awk`
de 2024 sino que se conectó Sentinel v2 directamente a la API de AWS.

### Lo que había apagado en AWS

En `batchtoday` (`18.221.108.18`) estaba **todo el cableado intacto**, solo con el
proceso parado:

| Pieza | Estado |
|---|---|
| App PM2 `GetPriceOrderBookLevel1Coinbase` | en la lista guardada, **detenida** |
| `/home/ubuntu/PRC Sentinel/Script/GetPriceOrderBookLevel1Coinbase.js` | presente, con `node_modules` |
| nginx `location /` → `localhost:2052` | activo, cert de Cloudflare |

Un `pm2 resurrect` bastó para que `https://batchtoday.us/price/BTC-USD` volviera a
responder. **Kraken (`GetPriceOrderBookLevel1Kraken.js`) se deja apagado a
propósito.**

### Cómo funciona la app de AWS

`GetProducts()` lista los productos de `api.exchange.coinbase.com/products`,
descarta EUR, GBP y deslistados, y se queda con los `online` — **464 productos**.
Luego `GetPrice()` los recorre de 10 en 10 llamando a
`/products/<PAR>/book?level=1`, y repite cada 60 s.

El barrido por sí solo daba **~65 s de resolución por par**, no 10 s: Coinbase le
aplica rate limit y el recorrido completo consume el minuto (medido sobre
BTC-USD: `23:24:10 → 23:25:19 → 23:26:24`).

### La lista caliente (2026-08-30)

Se añadió al `GetPriceOrderBookLevel1Coinbase.js` un segundo bucle, independiente
del barrido, que refresca solo los pares que interesan:

```js
const HOT_PAIRS = (process.env.HOT_PAIRS || 'BTC-USD').split(',')...
const HOT_MS    = parseInt(process.env.HOT_MS || '2000', 10);
```

`HotLoop()` escribe sobre el **mismo objeto de `Products`**, así que `/price` y
`/price/<PAR>` lo sirven sin cambiar nada más, y afloja a 10 s tras cuatro fallos
seguidos para no empeorar el rate limit del barrido. Es la misma idea que el
agente Jupiter con su única moneda caliente. Se configura por entorno
(`HOT_PAIRS`, `HOT_MS`) sin tocar el fichero.

Resultado medido:

| | Barrido solo | Con lista caliente |
|---|---|---|
| Refresco de BTC-USD | ~65 s | **~2 s** (30 valores distintos en 30 sondeos) |
| `edad_ms` media en la BD | 31.542 ms | **1.952 ms** |
| Peor `edad_ms` | 68.000 ms | **3.000 ms** |
| Filas frescas (<15 s) | 20 % | **100 %** |
| Productos del barrido con precio | 147 de 464 | **442 de 464** |

El barrido general **no se resintió** por el tráfico extra: al contrario, subió de
147 a 442 productos con precio. El proceso queda en ~10 % de CPU y 83 MB.

### Lo que guarda Sentinel

```sql
cripto_libro (par, exchange, ts, ask, ask_size, ask_numorders,
              bid, bid_size, bid_numorders, ts_fuente, edad_ms, nodo,
              PRIMARY KEY (par, exchange, ts))
```

Misma rejilla de 10 s que `cripto_precio` **a propósito**, para poder cruzar las
dos series por `ts`. `ts_fuente` y `edad_ms` los calcula SQLite a partir del
`dateupdate` ISO-8601 de Coinbase — rqlite lo parsea con nanosegundos y zona `Z`
sin ayuda, lo que evita depender de la implementación de `date` en cada nodo.

La vista `v_cripto_comparado` cruza ambas y añade `cb_spread`, `cb_spread_bps`,
`dif_vs_medio` y `dif_bps` (Jupiter WBTC contra el punto medio de Coinbase).
Filtra con `WHERE cb_edad < 15000` para quedarte solo con observaciones genuinas.

### El fallo del minuto alterno

Al ponerlo en cron, la serie salía al **55 %**: recogía los minutos pares y se
saltaba enteros los impares, en las dos máquinas a la vez. La causa medida fue
que el bucle terminaba **57 s después de arrancar**, así que el proceso seguía
vivo en el segundo exacto en que cron disparaba el siguiente; éste no conseguía
el lock y se iba (observado: `16:36:59` proceso vivo → `16:37:01` lock libre y
cero procesos).

Se arregló **anclando el final del bucle a la rejilla del minuto** (`ini - ini%60
+ 57`) y capando el último `sleep` para que no cruce ese límite. Resultado tras
el cambio: **26 de 26 muestras, 0 cortes, los dos nodos escribiendo**.

`Sentinel-Cripto.sh` comparte la estructura del `+57` y **no** presenta el
síntoma (99,977 % medido), así que se dejó como está; si algún día alterna, la
causa y el arreglo están aquí.

---

## 7 ter. Profundidad ejecutable (2026-08-31)

El paso 3 de la hoja de ruta del §8 —*"comparar `bid` de uno contra `ask` del
otro… y contrastar el `size` disponible contra el tamaño que quieras mover"*— no
se podía escribir con lo que había: `cripto_libro` guarda **nivel 1**, y el tope
del libro no dice a qué precio ejecutas. Medido sobre BTC-USD, el spread del
nivel 1 promedia **0,02 bps** mientras el spread ejecutable a $250.000 es de
**2,51 bps**: el nivel 1 subestimaba el coste real por un factor de 125.

`Sentinel-Profundidad.sh` cierra ese hueco. **Camina el libro** y guarda el VWAP
alcanzado para cuatro tamaños, en la misma rejilla de 10 s que sus dos hermanos.

```sql
cripto_profundidad (par, exchange, ts,
                    ask_2k,  bid_2k,  ask_10k,  bid_10k,
                    ask_50k, bid_50k, ask_250k, bid_250k,
                    niveles_ask, niveles_bid, prof_ask_usd, prof_bid_usd,
                    ts_fuente, edad_ms, nodo,
                    PRIMARY KEY (par, exchange, ts))
```

Tres decisiones que lo separan de la versión 8:

1. **No pasa por el proxy de AWS.** Consulta
   `api.coinbase.com/api/v3/brokerage/market/product_book`, que es pública y sin
   token. Se piden 100 niveles: ~9 KB. Deliberadamente **no** se usa el
   `book?level=2` de `api.exchange.coinbase.com`, que devuelve el libro entero
   (1,15 MB; a 10 s serían 600 MB/hora **por nodo**).
2. **Un clip que no se puede cubrir se guarda `NULL`, no cero.** Con 50 niveles
   el lado ask no alcanzaba los $250.000 el **48,3 %** de las veces; se subió a
   100 y ambos lados cubren. La lección de `edad_ms` aplicada a otra columna: un
   cero se promedia y contamina, un `NULL` se ve.
3. **`edad_ms` se mide contra el segundo de la petición, no contra el bucket.**
   En la versión 8 la fuente es el proxy y lo que interesa es cuánto se ha
   quedado atrás respecto del instante de la rejilla. Aquí la fuente es directa,
   así que el libro siempre es *de dentro* del bucket y esa resta daría negativos
   sistemáticos que no son vejez. Medido: media 592 ms, rango [−1.000, 2.000].

Los clips son **columnas y no filas** a propósito: mantiene una fila cada 10 s,
como las tablas hermanas. Añadir un tamaño es un cambio de esquema, y eso es
preferible a multiplicar filas por clip.

**Estado medido el 2026-08-31** (1.070 filas, ~3 h): cobertura 98,71 %, reparto
sentinel014 73,2 % / sentinel016 26,8 %, y **0 filas** violando la coherencia
estructural (ask VWAP creciente con el tamaño, bid decreciente, ask > bid).

Aparecieron **2 filas de 1.070 con todo el lado bid a `NULL`** teniendo 50
niveles, con el lado ask perfecto. La profundidad total de 50 niveles del lado
bid está normalmente entre $490.000 y $833.000, así que no era libro fino. La
hipótesis que encaja es que la API devolvió niveles con **tamaño cero** —la
guarda `qty <= 0` haría exactamente eso—, pero **no se capturó la respuesta cruda
y queda sin confirmar**. Por eso se añadieron `prof_ask_usd` / `prof_bid_usd`: si
vuelve a pasar, un `NULL` con profundidad holgada delante señala a la fuente y no
al mercado.

---

## 8. Estado real y deuda conocida

**Vivo:** las versiones 7, 8 y 9. Todo `PRC_Crypto_Trends` está parado desde 2024.

**Deuda que afecta a quien reordene:**

- `Nodos/prc_sentinel/Script/v2/` es la **copia de referencia para desplegar** y ha
  divergido de `Wheel/Script/v2/`: conserva la versión **antigua de Coinbase** de
  `Sentinel-Cripto.sh` y un `.conf.example` sin `CRIPTO_NODOS`. Instalar un nodo
  desde ahí le mete el colector obsoleto.
- El agente Jupiter es **punto único de fallo**: vive solo en sentinel016. La
  redundancia protege de que caiga un nodo, **no** de que caiga el agente — los dos
  recolectores preguntan al mismo sitio.
- `RAYD_Main.sh` y `RAYD_Hot.sh` son **byte a byte idénticos**. Duplicado.
- `dwd_price_tokens` significa dos cosas distintas según el nodo (§5.4).
- La lógica de Coinbase y Kraken vive en el proxy `batchtoday.us`, **fuera de este
  repositorio**. Sin ese proxy, la versión 2 no arranca.

**Si el objetivo es retomar el arbitraje**, el orden natural era:

1. ✅ **Hecho (2026-08-31).** Se reescribió la captura contra la API directamente:
   `Sentinel-Profundidad.sh` consulta Coinbase Advanced Trade sin pasar por el
   proxy. Kraken sigue apagado.
2. ✅ **Hecho.** `cripto_profundidad` es histórico, no foto: una fila cada 10 s con
   retención de 90 días, así que sí permite estudiar oportunidades pasadas.
3. ⚠️ **A medias.** El dato para hacer el cálculo ya existe —VWAP ejecutable por
   tamaño, cruzable con `cripto_precio` por `ts`— pero **el cálculo neto de
   comisiones no está escrito en la base**. Hoy hay que hacerlo en la consulta.
4. ✅ **Hecho.** Vive en rqlite con la misma elección `CRIPTO_NODOS` + Wheel y el
   mismo `INSERT OR IGNORE` que sus hermanas, así que hereda la redundancia.

**Advertencia sobre el punto 3**, medida en esta casa y no supuesta: el hueco
bruto entre el mark de Jupiter y Coinbase es de **0,47 bps de mediana y 10,84 bps
en el peor caso de 44,8 h**, mientras que la comisión *taker* de Coinbase en el
tramo base es de **60 bps**. Con esos números el arbitraje spot no existe salvo
para quien opere con rebate. El valor de esta serie, hoy, es **vigilar que el
mark del agente no se despegue** de la referencia externa, no ejecutar contra él.
