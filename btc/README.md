# Monitoreo de BTC (Coinbase: futuros y spot)

Servicio nuevo de la red Sentinel, hecho desde cero el 12/11/2026.

Primer paso, el de este directorio: **velas diarias y semanales con Heikin Ashi**
guardadas en el rqlite de la red. Después vendrán los indicadores: EMA 100 y 200,
Bollinger 20 con 2σ, Fibonacci, canales de regresión y rupturas.

## Series

| Producto | Qué es | Desde | Para qué |
|---|---|---|---|
| `BIP-20DEC30-CDE` | El perpetuo de futuros de BTC de Coinbase en EE. UU. ("nano BTC Perp": 0,01 BTC por contrato, precios en saltos de $5, sin vencimiento hasta dic-2030). | 18/07/2025 (~70 semanas) | La serie para operar, también en corto. |
| `BTC-USD` | El spot. | 20/07/2015 (~590 semanas) | Lo que necesita historia larga y el perpetuo no tiene. La EMA 100 semanal pide 100 semanas y la EMA 200, 200. |

Las dos van por defecto (`BTC_PRODUCTOS`). En la semana del 09/11/2026 el
perpetuo y el spot cerraban a menos de $25 uno del otro.

**Volumen.** En el perpetuo va en **contratos**, no en BTC: 1 contrato son 0,01
BTC.

**Incoherencias de Coinbase en el perpetuo.** El histórico de futuros de Coinbase
no siempre cuadra entre granularidades. Se guarda su vela diaria tal cual y las
diferencias se informan. Comprobado el 12/11/2026:
- **10/03/2026:** la diaria da un máximo de 71.790, mientras que las velas de
  1 h, 15 min y 5 min dan 71.845.
- **17/09/2025:** es la horaria la que se equivoca en la apertura.
- **ONE_WEEK:** en 11 de 69 semanas su cierre difiere en $5-10 del cierre del
  domingo, que sí coincide con las velas de 5 min.
- **Volumen:** difiere entre todas las granularidades.

Los días recientes coinciden exactos en todas.

## Ficheros

| Fichero | Qué es |
|---|---|
| `Sentinel-BTC-Velas.sh` | La pasada: baja de Coinbase lo que falta, recalcula y escribe en rqlite. Usa sh, awk y curl, así que corre en cualquier nodo (Termux, Ubuntu o la laptop). |
| `velas-calculo.awk` | El cálculo: Heikin Ashi diaria, vela semanal y Heikin Ashi semanal. |
| `coinbase-velas.awk` | Lee y valida la respuesta de Coinbase. |
| `pruebas/pruebas-velas.sh` | El banco de pruebas: rqlite local con contraseña más un Coinbase falso, comparado con un cálculo independiente en JavaScript. |
| `pruebas/contra-coinbase.js` | Rehace semanas y Heikin Ashi desde lo guardado (estricto). Además compara lo guardado con otras fuentes de Coinbase: la API Exchange (spot), las velas horarias (perpetuo) y ONE_WEEK. |

## Datos

**Fuente.** Es el endpoint público de velas de Coinbase Advanced Trade
(`/api/v3/brokerage/market/products/<producto>/candles`, `ONE_DAY`): sin claves,
sin cuenta y sin órdenes. La carga completa son unas 16 peticiones para el spot
(unas 4.100 velas diarias) y 4 para el perpetuo (unas 480), a una por segundo.
La historia se da por terminada con **dos** ventanas vacías seguidas: una sola
podría ser un fallo puntual de Coinbase y dejaría la historia recortada.

**Tabla `cripto_vela`.** Ver `rqlite/esquema.sql`. Tiene una fila por `producto`,
`marco` (`1d` o `1w`) y `ts`, el inicio de la vela en segundos UTC. En total son
unas 5.300 filas, menos de 1 MB.

**Semana de lunes 00:00 UTC**, la misma que TradingView:
- apertura del lunes;
- máximo y mínimo de la semana;
- cierre del domingo;
- suma del volumen.

Coinbase no ofrece vela semanal en su API documentada, así que la semanal se arma
desde la diaria.

**Heikin Ashi**, con la convención de TradingView:
- cierre = (O+H+L+C)/4;
- apertura = (apertura HA anterior + cierre HA anterior)/2; en la primera vela,
  (O+C)/2;
- máximo y mínimo: el extremo entre la vela real y la apertura y el cierre HA.

La semanal HA se calcula sobre la vela semanal real, no juntando HA diarias. Como
es recursiva, se recalcula siempre desde la primera vela de cada serie.

**`cerrada`.** Vale 0 para la vela en curso, que se actualiza en cada pasada. Los
indicadores y las rupturas deben mirar solo velas cerradas. Una vela se da por
cerrada 60 s después de su fin (`BTC_MARGEN`). Ese margen cubre el desfase de
reloj y el rato que tarda Coinbase en terminar la vela tras las 00:00 UTC.

**Protecciones** (en todas el script sale sin escribir nada de ese producto):
- **Reloj atrasado.** Si el reloj del equipo va más de un día por detrás de la
  última vela guardada.
- **Último día que no llega.** Si Coinbase no vuelve a mandar el último día
  guardado. Pasaría con una lista vacía o cortada.
- **Vela imposible.** Si una vela no es coherente: máximo por debajo del cierre,
  precio a cero, o una hora que no es medianoche.
- **Aviso de corrección.** Si Coinbase cambia una vela que ya estaba guardada
  como cerrada, se sobrescribe y se avisa en el log.

**Huecos.** Un día que falte en Coinbase no se inventa: queda en el log y su
semana sale con `dias` < 7. Hoy no hay ninguno. La primera semana del perpetuo
tiene 3 días, porque empezó un viernes.

## Comprobación con datos reales (12/11/2026, en el rqlite de la red)

**Nuestro cálculo.** La semana y la Heikin Ashi, rehechas desde las diarias
guardadas, coinciden en todas las filas de las dos series.

**Perpetuo.**
- 480 de 482 diarias cerradas son iguales a las armadas desde las velas horarias.
- Las 2 restantes y las diferencias con ONE_WEEK son las incoherencias propias de
  Coinbase descritas arriba.

**Spot:**

- **Diarias:** las 4.133 velas cerradas son idénticas a las de la API Exchange de
  Coinbase en apertura, máximo, mínimo, cierre y volumen.
- **Semanales:** 587 de las 590 cerradas son idénticas a ONE_WEEK. Las 3 que no
  cuadran son fallos de ONE_WEEK, no del cálculo:
  - 20/07/2015: es la primera semana de la historia.
  - 02/04/2018: ONE_WEEK la cierra en 5.200, cuando las velas diarias de esa
    semana cierran en 7.020.
  - 25/01/2021: ONE_WEEK da un máximo que ninguna vela diaria alcanza.
- **Heikin Ashi:** las 4.723 cerradas, diarias y semanales, son idénticas a las
  recalculadas aparte desde la API Exchange.
- Para repetirlo: `node btc/pruebas/contra-coinbase.js <url-rqlite> <curlrc> [producto]`.
  Sale con 1 si algo no cuadra.

## Pruebas

`btc/pruebas/pruebas-velas.sh`: 66 pruebas, todas pasan. El Coinbase falso sirve
también un perpetuo con saltos de $5 que empieza un viernes. Cubren:
- Heikin Ashi y semanas, con números hechos a mano.
- El lector de Coinbase.
- Pasadas reales contra un rqlite local con contraseña y un Coinbase falso,
  comparadas fila a fila con un cálculo independiente en JavaScript. Entre ellas:
  - el cambio de día UTC;
  - correcciones de Coinbase;
  - huecos;
  - fallos de Coinbase y de rqlite;
  - reloj atrasado;
  - cerrojo;
  - ventanas vacías;
  - que ninguna petición a Coinbase lleve credenciales.

Antes de arrancar comprueba que los puertos de prueba están libres, para no
tocar otro rqlited. Una revisión adversarial (25 agentes) encontró 20 fallos, y
todos están arreglados. Se comprobó que el banco detecta cada arreglo: se
estropeó a propósito una copia del script por cada uno y en todos los casos
alguna prueba falla.

## Uso

```sh
# Desde un equipo que no es nodo de rqlite (p. ej. la laptop):
RQLITE=http://192.168.0.21:4001 sh btc/Sentinel-BTC-Velas.sh
# Otras opciones:
sh btc/Sentinel-BTC-Velas.sh --seco       # calcula sin escribir; deja los lotes en ~/PRC_Sentinel/btc/seco/
sh btc/Sentinel-BTC-Velas.sh --completo   # vuelve a bajar y escribir toda la historia
sh btc/pruebas/pruebas-velas.sh           # banco de pruebas (necesita node y rqlited)
```

**Credenciales.** Usa `~/.config/rqlite/sentinel.curlrc`, el usuario `sentinel`
(execute y query). Las peticiones a Coinbase van con `curl -q`, así que nunca
leen un curlrc y nunca llevan credenciales.

**Escrituras.** Una pasada normal reescribe solo los últimos 3 días, el de hoy y
1 o 2 semanas: unas 7 filas, en 1 entrada de Raft. Además lee toda la serie
diaria, unos 230 KB, a través del líder. La carga inicial va en lotes de 200
con `?transaction`.

**Un solo nodo.** El cerrojo es local, así que el cron debe ir en un solo nodo.
Si `sentinel.conf` define `BTC_NODOS="sentinelNNN"`, los demás nodos salen sin
hacer nada. Con dos nodos a la vez la base no se rompe, pero cerca de las 00:00
UTC uno con el reloj algo atrasado podría reabrir la vela de ayer durante una
pasada. Cada 5 a 15 minutos basta: las velas son diarias.

## Pendiente

- Decidir dónde y cada cuánto corre: qué nodo y con qué cron. Por ahora se corre
  a mano.
- Indicadores y rupturas: decidir si se calculan sobre velas reales o Heikin Ashi.
- Avisos.
