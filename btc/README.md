# Monitoreo de BTC (Coinbase: futuros y spot)

Servicio nuevo de la red Sentinel, hecho desde cero el 12/11/2026.

Lo que hace hoy, todo guardado en el rqlite de la red:
- **velas diarias y semanales con Heikin Ashi** (tabla `cripto_vela`);
- **indicadores** sobre esas velas (tabla `cripto_indicador`): EMA 100 y 200,
  Bollinger 20 con 2σ y canal de regresión de 100 velas con sus rupturas;
- **niveles de Fibonacci** del ciclo (tabla `cripto_fibonacci`): del mínimo
  de 2022 al ATH de 2025, y se mueven solos cuando llegue el ciclo siguiente.

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
| `indicadores-calculo.awk` | Los indicadores, sobre el cierre real y sobre el Heikin Ashi. |
| `fibonacci-calculo.awk` | El tramo del ciclo y sus niveles de Fibonacci. |
| `coinbase-velas.awk` | Lee y valida la respuesta de Coinbase. |
| `pruebas/pruebas-velas.sh` | El banco de pruebas: rqlite local con contraseña más un Coinbase falso, comparado con un cálculo independiente en JavaScript. |
| `pruebas/indicadores-ref.js` | El cálculo independiente de los indicadores, con otras fórmulas, para las pruebas y para la comprobación con datos reales. |
| `pruebas/fibonacci-ref.js` | Lo mismo para Fibonacci, buscando el tramo de otra manera. |
| `pruebas/contra-coinbase.js` | Rehace semanas, Heikin Ashi, indicadores y Fibonacci desde lo guardado (estricto). Además compara lo guardado con otras fuentes de Coinbase: la API Exchange (spot), las velas horarias (perpetuo) y ONE_WEEK. |

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

## Indicadores

**Tabla `cripto_indicador`.** Una fila por `producto`, `marco`, `base` y `ts`,
los mismos `ts` que `cripto_vela`. Son unas 10.600 filas.

**Bases.** Cada indicador se calcula dos veces:
- `real`, sobre el cierre real;
- `ha`, sobre el cierre Heikin Ashi. Es lo que dibuja TradingView cuando el
  gráfico está en Heikin Ashi.

**Qué se calcula** (con los valores por defecto de TradingView):

| Columnas | Qué es |
|---|---|
| `ema100`, `ema200` | EMA con alfa = 2/(n+1). La primera es la media simple de las n primeras velas, como en TA-Lib. Antes de n velas, null. |
| `bb_media`, `bb_sup`, `bb_inf` | Bollinger: media simple de 20 ± 2 desviaciones típicas **poblacionales** (dividiendo por 20, como `ta.stdev` de TradingView). |
| `rl_centro`, `rl_sup`, `rl_inf` | Canal de regresión lineal de las últimas 100 velas (el *Linear Regression Channel* de TradingView): la recta en esta vela ± 2 desviaciones típicas de los residuos (dividiendo por 99). |
| `rl_pendiente` | Cuánto sube o baja la recta por vela (en dólares por día o por semana). |
| `rl_r` | Correlación de Pearson con el tiempo, **con signo**: +1 es una subida limpia y −1 una bajada limpia. TradingView muestra su valor absoluto. |
| `rl_ruptura` | 1 si el cierre quedó **por encima** del canal de las 100 velas anteriores, prolongado una vela; −1 si quedó por debajo; 0 dentro. Necesita 101 velas. |

Donde faltan velas sale null. El perpetuo tiene unas 70 semanas, así que en
semanal no tiene EMA ni canal: para eso está el spot.

**Velas abiertas.** Los indicadores de la vela en curso (`cerrada=0`) cambian en
cada pasada, como en TradingView en tiempo real. Una ruptura solo cuenta cuando
la vela está cerrada.

**Cómo se mantienen.**
- **Causales.** Todos los indicadores son causales: el valor de una vela solo
  depende de ella y de las anteriores. Por eso cada pasada reescribe solo las
  mismas filas recientes que las velas, por dos (las dos bases).
- **Mismos lotes que las velas.** Velas e indicadores van juntos en cada
  transacción. Así un fallo no deja una vela nueva escrita sin su indicador.
- **Marca de «por reescribir».** La primera sentencia de cada pasada, en el
  lote 1 y antes de las velas, pone `version=0` en las filas de indicadores que
  la pasada va a rehacer. Cada fila recupera su versión al reescribirse. Si la
  pasada se corta en cualquier lote, lo que no se rehizo queda marcado y la
  pasada siguiente lo detecta. Así un `--completo` cortado tras una corrección
  vieja de Coinbase no deja indicadores de la serie anterior.
  Al final de una pasada normal se borra lo que siga marcado en la zona
  reciente: son filas de una vela que no existe.
- **Reescritura completa.** Antes de escribir, la pasada cuenta las filas
  guardadas anteriores a las recientes: todas, y aparte las que están cerradas
  y tienen la `version` actual del cálculo. Las dos cuentas deben dar lo que
  dice el cálculo. Si no, se reescriben todos los indicadores del producto:
  - de la vela más nueva a la más vieja;
  - sin borrar nada antes;
  - al final se borra solo lo que sigue marcado, que son filas de una vela que
    ya no existe.

  Si un lote falla a mitad, lo reciente ya está bien y lo viejo sigue ahí,
  marcado; la pasada siguiente lo termina.

  La reescritura completa pasa la primera vez, tras una pasada cortada y con un
  `VERSION` nuevo (o anterior) en `indicadores-calculo.awk`. Entonces el log
  dice por qué. Son unas 54 transacciones: en la red tardó 54 s.
- **Si cambias el cálculo** sube `VERSION` en `indicadores-calculo.awk`. La
  prueba I6 guarda una huella fija de la salida junto a esa versión y falla si
  la salida cambia sin que suba.

## Fibonacci

**Tabla `cripto_fibonacci`.** Los niveles de retroceso del tramo `ciclo`, una
fila por nivel: hoy 7 filas, todas de `BTC-USD`.

**El tramo.** Va del fondo del último mercado bajista al máximo histórico
(ATH). Hoy es del mínimo de 2022 al ATH de 2025, lo mismo que se traza a mano en
TradingView:
- ancla baja: 15.460, el 21/11/2022;
- ancla alta: 126.296, el 06/10/2025.

**La regla**, para que el tramo se mueva solo cuando llegue otro ciclo:
- Un **máximo histórico** es una vela diaria cuyo máximo supera al de todas las
  anteriores. Igualarlo no cuenta.
- **La caída que le sigue** son las velas desde la siguiente hasta la última
  antes de la que lo supera.
- Esa caída es un **mercado bajista** si cumple dos cosas:
  - su peor **cierre** queda al menos un 50 % por debajo de ese máximo;
  - tardó **al menos un año** en volver a superarlo.
- **El ciclo** empieza en el mínimo (la mecha) del último mercado bajista ya
  superado por un máximo nuevo, y acaba en el máximo histórico.

**Por qué el cierre.** Así un precio absurdo de un instante no convierte en
bajista una caída que no lo fue. Coinbase tiene uno: 0,06 $ el 15/04/2017.

**Por qué el año.** Separa los mercados bajistas de las correcciones a mitad de
ciclo, que pueden caer lo mismo. En el spot hay tres caídas del 50 % ya
superadas:

| Caída | Cierre | Hasta superar el máximo | ¿Bajista? |
|---|---|---|---|
| dic-2017 → 2018 | −84 % | 1.080 días | sí |
| abr-2021 → jul-2021 | −54 % | 189 días | no, corrección |
| nov-2021 → 2022 | −77 % | 846 días | sí: abre el ciclo de hoy |

Sin la condición del año, entre el 20/10/2021 y el 04/03/2024 el tramo habría
salido del mínimo de la corrección de 2021 (28.800) en vez del fondo de 2018
(3.128,89), hasta el ATH de cada día (69.000 desde el 10/11/2021).

**La caída de ahora.** Desde el ATH, el cierre llegó a bajar un 53,7 %, con un
mínimo de 57.717,55 el 01/07/2026. Sigue en curso y no mueve el tramo. Como ya
pasó más de un año desde el ATH, el día que el precio supere los 126.296 el
ciclo siguiente empezará en el mínimo más bajo de esta caída (hoy 57.717,55). Con
ese tramo saldrá también el 1,618, mientras el ATH nuevo quede por debajo de
unos 151.100.

**Niveles.** Son los de retroceso que TradingView pone por defecto al trazar del
mínimo al máximo. El nivel 0 es el máximo y el 1 el mínimo:
precio = máximo − nivel × (máximo − mínimo).

| Nivel | Precio | |
|---|---|---|
| 0 | 126.296 | el ATH |
| 0,236 | 100.138,70 | |
| 0,382 | 83.956,65 | |
| 0,5 | 70.878 | |
| 0,618 | 57.799,35 | el mínimo del 01/07/2026 (57.717,55) cayó casi exacto aquí |
| 0,786 | 39.178,90 | |
| 1 | 15.460 | el fondo de 2022 |

TradingView también pone por defecto las extensiones 1,618, 2,618, 3,618 y
4,236, que caen por debajo del mínimo. Solo se guardan las que dan un precio
positivo. Con el tramo de hoy no sale ninguna, pero con uno más corto saldría
el 1,618.

**Columnas:**
- `nivel` y `precio`;
- las dos anclas: `bajo_ts`, `bajo`, `alto_ts` y `alto`;
- `caida`: lo que bajó el cierre en la caída que abrió el ciclo (hoy 0,772).

**El perpetuo, por ahora, no tiene ciclo.** Cada producto se calcula con su
propia historia, y la del perpetuo empieza en julio de 2025: después del fondo
de 2022. Su única caída grande, la que empezó en su ATH de octubre de 2025, aún
no se ha superado. El día que supere ese máximo tendrá su propio ciclo, con sus
precios (saltos de $5), aparte del del spot. Mientras tanto sus precios siguen
al spot a pocos dólares, así que los niveles del spot le sirven igual.

**Real o Heikin Ashi.** Las anclas salen de los máximos y mínimos reales. Con los
del Heikin Ashi el tramo sale exactamente igual.

**Cómo se mantiene:**
- Cada pasada lo rehace entero desde toda la historia diaria.
- Incluye la vela de hoy aún abierta: su máximo y su mínimo ya ocurrieron.
- Va en su propia transacción, después de las velas: primero borra lo del
  producto y después escribe los niveles.
- Si esa transacción falla, se quedan enteros los niveles de antes, y la pasada
  siguiente lo arregla.

## Comprobación con datos reales (12/11/2026, en el rqlite de la red)

**Nuestro cálculo.** La semana y la Heikin Ashi, rehechas desde las diarias
guardadas, coinciden en todas las filas de las dos series.

**Indicadores (13/11/2026).**
- Carga: unos 54 s y sin elecciones (el término de Raft no cambió). Los 11
  nodos tienen las mismas filas: 1.108 del perpetuo y 9.452 del spot.
- Rehechos con `indicadores-ref.js` desde las velas guardadas, coinciden todos.
- La pasada siguiente volvió a ser incremental: 12 filas por producto.

**Fibonacci (13/11/2026).**
- La pasada que creó la tabla tardó 8 s, sin elecciones.
- Los 10 nodos que respondían tienen los mismos 7 niveles del spot. El undécimo
  (192.168.0.22, que no vota) estaba fuera de la red y se pone al día al volver.
- Rehechos con `fibonacci-ref.js` desde las velas guardadas, coinciden. El
  perpetuo, sin ciclo, como debe.
- Con la regla cortada en cada día de la historia del spot, el tramo sale:
  - sin ciclo hasta el 30/11/2020;
  - del fondo de 2018 (3.128,89) al ATH de cada día hasta el 04/03/2024;
  - del fondo de 2022 (15.460) desde el 05/03/2024.

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

`btc/pruebas/pruebas-velas.sh`: 191 pruebas, todas pasan. El Coinbase falso
sirve también un perpetuo con saltos de $5 que empieza un viernes. Cubren:
- Heikin Ashi y semanas, con números hechos a mano.
- El lector de Coinbase.
- Los indicadores:
  - con números hechos a mano (largos cortos);
  - la serie falsa entera, con los largos de verdad y con los cortos, contra
    `indicadores-ref.js`;
  - la huella fija ligada a `VERSION`.
- Fibonacci:
  - con casos hechos a mano: el umbral del 50 % y sus bordes (también con
    precios reales), la duración de un año, la corrección corta entre dos
    bajistas, las mechas, los empates, la vela abierta y las extensiones;
  - la serie falsa y 480 series al azar contra `fibonacci-ref.js`;
  - en las pasadas reales: un ATH nuevo que abre el ciclo (también en la vela de
    hoy, abierta), la línea del resumen, la transacción que falla y deja los
    niveles de antes enteros, filas de más, la tabla que falta, `--seco`, el
    perpetuo sin ciclo y el awk que falta, roto o mudo.
- La reescritura completa de los indicadores:
  - sin tabla;
  - con filas que faltan, que se guardaron abiertas, de otra versión o de una
    vela que no existe;
  - con un lote que falla a mitad (un trigger en el rqlite de prueba), en una
    reescritura completa, en un `--completo` tras corregirse una vela vieja y
    en una pasada normal en varios lotes.
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

Los indicadores pasaron por tres rondas de revisión adversarial, cada una con
revisores y verificadores que intentaban refutar lo encontrado. Todo lo
confirmado está arreglado. Luego se estropearon a propósito 29 copias distintas
(fórmulas, bordes, la cuenta, la marca, el orden y los borrados). En las 29 falla
la prueba que corresponde.

Fibonacci pasó por dos rondas de revisión adversarial. La primera encontró que,
sin la condición del año, la corrección de 2021 se habría tomado por un ciclo;
la segunda, detalles de las pruebas y del texto. Todo lo confirmado está
arreglado. Se estropearon a propósito 46 copias distintas (la regla, los bordes,
las anclas, los niveles, el JSON, el orden de escritura, la transacción y los
chequeos del script). Las 2 que sobrevivieron a la primera tanda tienen ya su
prueba: con ellas, las 46 se detectan.

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
1 o 2 semanas: unas 7 filas de velas y 14 de indicadores por producto, en 1
entrada de Raft. Fibonacci va en otra: el borrado y los 7 niveles del spot, y en
el perpetuo solo el borrado. Además lee toda la serie diaria, unos 230 KB, y cuenta los
indicadores guardados, las dos cosas a través del líder. La carga inicial va en
lotes de 200 con `?transaction`.

**Un solo nodo.** El cerrojo es local, así que el cron debe ir en un solo nodo.
Si `sentinel.conf` define `BTC_NODOS="sentinelNNN"`, los demás nodos salen sin
hacer nada. Con dos nodos a la vez la base no se rompe, pero cerca de las 00:00
UTC uno con el reloj algo atrasado podría reabrir la vela de ayer durante una
pasada. Cada 5 a 15 minutos basta: las velas son diarias.

## Pendiente

- Decidir dónde y cada cuánto corre: qué nodo y con qué cron. Por ahora se corre
  a mano.
- Avisos.
