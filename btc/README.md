# Monitoreo de BTC y del Tech 100 (Coinbase: futuros y spot)

Servicio nuevo de la red Sentinel, hecho desde cero el 12/11/2026.

Lo que hace hoy, todo guardado en el rqlite de la red:
- **velas diarias y semanales con Heikin Ashi** (tabla `cripto_vela`);
- **indicadores** sobre esas velas (tabla `cripto_indicador`): EMA 100 y 200,
  Bollinger 20 con 2σ y canal de regresión de 100 velas con sus rupturas;
- **niveles de Fibonacci** del ciclo (tabla `cripto_fibonacci`): del mínimo
  de 2022 al ATH de 2025, y se mueven solos cuando llegue el ciclo siguiente;
- **señales al cierre** de cada vela, por Telegram (tabla `cripto_aviso`):
  ruptura del canal, cruces con las EMA y entre ellas, niveles de Fibonacci y
  cambio de color del Heikin Ashi, del perpetuo en diaria y semanal.

Desde el 14/11/2026 sigue también el **Tech 100** de Coinbase Derivatives
(`TEK-19DEC30-CDE`), con sus propias velas, indicadores y señales (ver «El
Tech 100»).

Y si deja de escribir, el Wheel de la red avisa por Telegram (ver «Señales»).

## Series

| Producto | Qué es | Desde | Para qué |
|---|---|---|---|
| `BIP-20DEC30-CDE` | El perpetuo de futuros de BTC de Coinbase en EE. UU. ("nano BTC Perp": 0,01 BTC por contrato, precios en saltos de $5, sin vencimiento hasta dic-2030). | 18/07/2025 (~70 semanas) | La serie para operar, también en corto. |
| `BTC-USD` | El spot. | 20/07/2015 (~590 semanas) | Lo que necesita historia larga y el perpetuo no tiene. La EMA 100 semanal pide 100 semanas y la EMA 200, 200. |
| `TEK-19DEC30-CDE` | El perpetuo del «Tech 100» de Coinbase Derivatives: 1 $ por punto del MarketVector US Listed Innovators 100 (no es el Nasdaq-100: vale ~3.700). Solo de lunes a viernes. | 15/06/2026 (~22 semanas) | Un índice tecnológico de EE. UU. que se puede operar en corto, regulado por la CFTC. |

Las tres van por defecto (`BTC_PRODUCTOS`). En la semana del 09/11/2026 el
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

## El Tech 100

Lo pidió el dueño el 13/11/2026, después de ver que los perpetuos de acciones
sueltas (Apple, Nvidia) aún no se pueden operar desde EE. UU.

- **Qué es.** `TEK-19DEC30-CDE`, «Tech 100 Perpetual» en Coinbase. Sigue al
  MarketVector US Listed Innovators 100 (MVIN100): las 100 mayores del Nasdaq
  sin financieras, con tope del 30 % por empresa; Apple, Nvidia y Microsoft
  pesan 10-14 % cada una. Perpetuo de verdad desde el 26/10/2026 (el «19DEC30»
  del nombre es solo una referencia).
- **Calendario.** Cotiza de domingo 19:00 CT a viernes 16:00 CT, sin pausa
  diaria. En UTC son velas de **lunes a viernes**, y ninguna los festivos de
  bolsa de EE. UU. Por eso va en `BTC_LABORABLES`: el sábado y el domingo no son
  huecos (un festivo sí: Coinbase no trae su vela), y **la vela semanal se cierra
  al acabar el viernes** (sábado 00:00 UTC), así que su señal semanal sale en la
  pasada del sábado a las 00:02:30 UTC y no el lunes.
- **Historia.** Desde el 15/06/2026: ~107 velas diarias y ~22 semanales al
  14/11/2026. Alcanza para la EMA 100 diaria, no para la EMA 200 diaria ni para
  las semanales, ni para el canal semanal. Fibonacci no tiene ciclo (hace falta
  un mercado bajista ya superado). Todo eso sale `null` y aparece solo cuando
  haya velas.
- **Va solo.** No hay en Coinbase una serie larga del mismo índice, así que su
  grupo de señales es solo él (no hay un «spot» detrás, como en BTC).
- **La primera pasada** baja su historia (3 peticiones) y manda, si las hay, sus
  señales de las últimas 36 h: en `cripto_aviso` ya existía la tabla, así que
  no se guardan como «ya enviadas».

## Ficheros

| Fichero | Qué es |
|---|---|
| `Sentinel-BTC-Velas.sh` | La pasada: baja de Coinbase lo que falta, recalcula y escribe en rqlite. Usa sh, awk y curl, así que corre en cualquier nodo (Termux, Ubuntu o la laptop). |
| `velas-calculo.awk` | El cálculo: Heikin Ashi diaria, vela semanal y Heikin Ashi semanal. |
| `indicadores-calculo.awk` | Los indicadores, sobre el cierre real y sobre el Heikin Ashi. |
| `fibonacci-calculo.awk` | El tramo del ciclo y sus niveles de Fibonacci. |
| `coinbase-velas.awk` | Lee y valida la respuesta de Coinbase. |
| `avisos-calculo.awk` | Las señales al cierre de cada vela, con su texto, y de qué serie sale cada una. |
| `servicio/` | El temporizador y el servicio de systemd de sentinel014 (ver «Dónde corre»). |
| `pruebas/pruebas-velas.sh` | El banco de pruebas: rqlite local con contraseña más un Coinbase falso, comparado con un cálculo independiente en JavaScript. |
| `pruebas/indicadores-ref.js` | El cálculo independiente de los indicadores, con otras fórmulas, para las pruebas y para la comprobación con datos reales. |
| `pruebas/fibonacci-ref.js` | Lo mismo para Fibonacci, buscando el tramo de otra manera. |
| `pruebas/contra-coinbase.js` | Rehace semanas, Heikin Ashi, indicadores y Fibonacci desde lo guardado (estricto). Además compara lo guardado con otras fuentes de Coinbase: la API Exchange (spot), las velas horarias (perpetuo) y ONE_WEEK. |
| `pruebas/avisos-ref.js` | El cálculo independiente de las señales (y de sus textos), para el banco. |
| `pruebas/avisos-comprueba.js` | Rehace las señales desde la serie falsa con las tres referencias y las compara con `cripto_aviso`. |

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

## Señales

Lo pidió el dueño el 13/11/2026: en el perpetuo, diaria y semanal, al cierre de
la vela. Las calcula `avisos-calculo.awk` en cada pasada (paso 7) y las manda la
propia pasada de sentinel014 por Telegram, con el bot de thermal-guard
(`~/PRC_Thermal/thermal-guard.conf`).

| Tipo | Señal |
|---|---|
| `canal` | El cierre rompe el canal de regresión de las 100 velas anteriores, hacia arriba o hacia abajo (`rl_ruptura` pasa a 1 o a −1). Mientras sigue fuera no se repite. |
| `ema100`, `ema200` | El cierre cruza la EMA: la vela anterior cerró a un lado y esta al otro. |
| `emas` | La EMA 100 cruza la EMA 200: cruce dorado hacia arriba, cruce de la muerte hacia abajo. |
| `fib` | El cierre cruza uno o más niveles de Fibonacci del ciclo: los que había **antes** de esa vela. Si cruza varios, van en una línea, en el orden en que los cruza. El 0 % es el máximo del ciclo y el 100 %, el mínimo: cerrar por encima del máximo «supera el máximo del ciclo». |
| `ha` | La vela Heikin Ashi cambia de color: verde si su cierre supera su apertura, roja si queda por debajo. Una vela sin color no cambia nada. |

**Solo velas cerradas.** Una señal compara la última vela cerrada con la
anterior. La diaria se decide en la pasada de las 00:02:30 UTC; la semanal, en
la del lunes a la misma hora. Cerrar justo en un nivel cuenta como cerrar por
debajo.

**Los niveles de Fibonacci de cada vela.** Son los del ciclo calculado con las
velas diarias cerradas anteriores a ella: las líneas que había en el gráfico al
abrirse (en la diaria, con todo hasta ayer; en la semanal, hasta el domingo
anterior). Así un máximo nuevo durante el día (que mueve el tramo) no cambia
la señal de una vela ya cerrada, ni da señales tardías y contradictorias. Y el
día que el precio cierre por encima del ATH, eso es «supera el máximo del
ciclo»; desde la vela siguiente, los niveles son los del tramo nuevo.

**De qué serie.** Del perpetuo, salvo donde le falta el dato. El perpetuo tiene
~70 semanas, así que la EMA y el canal semanales salen hoy del spot, igual que
Fibonacci, porque el perpetuo aún no tiene ciclo propio. Se decide por señal,
marco y vela: si el perpetuo tiene el dato y no hay señal, no se mira el spot.
Cuando el perpetuo tenga historia, pasa a usar el suyo solo. El mensaje lo dice
(«Perpetuo, …» o «Spot, …»). Spot y perpetuo van a menos de $25 uno de otro.

**El mensaje.** Uno por pasada, con todas las pendientes (25 como mucho; el
resto, en la pasada siguiente). Con tres señales reales de estas semanas (en la
práctica cada una llega el día de su cierre):

```
📊 BTC: señales al cierre
• 📉 Spot, semanal del 26/10: cierra por debajo de la EMA 100: cierre 78.231, EMA 78.940
• 🔴 Perpetuo, diaria del 06/11: la vela Heikin Ashi pasa a roja
• 📉 Perpetuo, diaria del 10/11: rompe el canal de regresión hacia abajo: cierre 73.710, borde inferior 74.503
Spot = BTC-USD, solo donde al perpetuo le falta historia.
Lo manda sentinel014.
```

**Cuántas.** Con los datos reales de los 60 días hasta el 13/11/2026 habrían
salido 41: unas 5 por semana, la mayoría cambios de color del Heikin Ashi
diario.

**Grupos.** `BTC_AVISOS` lleva un grupo por activo, separados por comas: por
defecto `BIP-20DEC30-CDE BTC-USD, TEK-19DEC30-CDE` (BTC, con el spot de
respaldo, y el Tech 100). Cada grupo se calcula aparte y solo si todos sus
productos salieron bien en la pasada; si un grupo falla, los demás siguen. El
mensaje lleva una parte por grupo, en ese orden:

```
📊 BTC: señales al cierre
• 🔴 Perpetuo, diaria del 13/11: la vela Heikin Ashi pasa a roja

📊 Tech 100: señales al cierre
• 🟢 Tech 100, diaria del 13/11: la vela Heikin Ashi pasa a verde
Lo manda sentinel014.
```

**Tabla `cripto_aviso`.** Una fila por señal: `grupo` (el producto principal
del grupo: `BIP-20DEC30-CDE` para BTC, `TEK-19DEC30-CDE` para el Tech 100),
`marco`, `ts` (de la vela) y `tipo` son la clave, así que una señal calculada
otra vez en la pasada siguiente no se duplica ni se vuelve a mandar, y la de
BTC y la del Tech 100 de la misma vela no chocan. Además lleva `producto` (la serie de la que
sale), `sentido` (1 arriba, −1 abajo), `precio` (el cierre), `nivel` (lo
cruzado: la EMA, el borde del canal, el primer nivel de Fibonacci o el cierre
Heikin Ashi), `texto` (la línea del mensaje), `creado` y `enviado`:
- `null`: pendiente;
- la hora a la que Telegram la aceptó;
- `0`: no se manda. Lo llevan las de los 7 días anteriores a crear la tabla,
  para que la primera pasada no mande nada viejo. La tabla la crea la primera
  pasada que calcula señales, en la misma transacción que ellas: si esa pasada
  falla, la siguiente sigue siendo «la primera»;
- `-1`: caducada sin mandar. La señal de una vela cerrada hace más de
  `BTC_AVISO_HORAS` (36) ya no sirve para operar (p. ej. tras días sin
  Telegram).

**La tabla de antes de los grupos.** Hasta el 14/11/2026 la clave era `(marco,
ts, tipo)`. La primera pasada con el script nuevo la migra sola, una vez y en
una transacción: crea `cripto_aviso_nueva`, copia todas las filas con el grupo
de su producto (las de `BIP-20DEC30-CDE` y `BTC-USD`, a `BIP-20DEC30-CDE`),
borra la vieja y renombra la nueva. Si falla, la tabla sigue como estaba, las
señales no salen en esa pasada (sale con 1, y el Wheel avisa si dura) y la
siguiente lo reintenta. Con `--seco` no se toca.

**Sin vuelta atrás automática.** Un script de antes del 14/11 (un `.bak`, un
checkout viejo en la laptop) ya no puede escribir en la tabla migrada: su
INSERT no lleva `grupo` y falla. Para volver al script viejo hay que deshacer
la migración a mano, quedándose solo con las de BTC (en la clave vieja, las de
los dos grupos chocarían):

```sql
CREATE TABLE cripto_aviso_vieja (marco TEXT NOT NULL, ts INTEGER NOT NULL, tipo TEXT NOT NULL, producto TEXT NOT NULL, sentido INTEGER NOT NULL, precio REAL NOT NULL, nivel REAL, texto TEXT NOT NULL, creado INTEGER NOT NULL, enviado INTEGER, PRIMARY KEY (marco, ts, tipo)) WITHOUT ROWID;
INSERT INTO cripto_aviso_vieja SELECT marco, ts, tipo, producto, sentido, precio, nivel, texto, creado, enviado FROM cripto_aviso WHERE grupo = 'BIP-20DEC30-CDE';
DROP TABLE cripto_aviso;
ALTER TABLE cripto_aviso_vieja RENAME TO cripto_aviso;
```

(las cuatro en una sola petición con `?transaction`).

**El principal de cada grupo es su clave.** Si se cambia el orden de un grupo
en `BTC_AVISOS` (p. ej. `BTC-USD BIP-…`), sus señales de los últimos 7 días
entran otra vez con la clave nueva, y se vuelven a mandar las de menos de 36 h.

**Escrituras.** En cada pasada se recalculan los últimos 7 días, pero solo se
escriben las señales que no estaban: sin nada nuevo, las señales no añaden
ninguna entrada de Raft.

**Si algo falla.**
- **Telegram no acepta el mensaje:** siguen pendientes, la pasada sale con 1 y
  la siguiente lo reintenta.
- **Se manda pero no se puede marcar** (rqlite): la pasada siguiente lo repite.
  Mejor repetida que perdida.
- **Un producto falla en la pasada:** las señales de SU grupo no se calculan
  (en BTC, el reparto entre perpetuo y spot saldría mal); las de los otros
  grupos sí. Las pendientes se mandan igual y la pasada sale con 3. La siguiente
  recalcula los últimos 7 días.
- **El cálculo de las señales falla:** las velas ya entraron y la pasada sale
  con 2.

En todos esos casos la pasada apunta en `sentinel_vigia` (fila `btc-senales`)
desde cuándo falla el paso de las señales, con su código, y el Wheel avisa si
dura más de 15 min (abajo). Compara con la fila (una lectura, sin Raft) y solo
la escribe si cambia: de bien a mal, de mal a bien, o de un código de fallo a
otro (sin mover el «desde»). Una fila que alguien dejó distinta se corrige en la
pasada siguiente. Con las señales apagadas (`BTC_AVISOS=`), una fila en fallo
que escribió el propio equipo vuelve a 0, para que apagarlas quite el aviso.

**Lo vigila el Wheel** de la red, desde fuera de 014 (`Sentinel-Alert.sh`):
- `bv:<producto>`, «el monitoreo de BTC no está al día», si:
  - la pasada lleva más de 15 min (`BTC_DATOS_MAX_MIN`, tres pasadas) sin
    escribir las velas de ese producto: falla la pasada, su temporizador o 014;
  - escribe, pero pasados esos 15 min tras la medianoche UTC no hay vela del
    día: Coinbase no la trae (el producto parado, vencido o renombrado). En los
    que solo cotizan de lunes a viernes (lo deduce de los datos: 10 o más velas
    en 28 días y ninguna en sábado o domingo, como TEK), el fin de semana no
    cuenta, y un día hábil sin vela tampoco (un festivo): avisa cuando faltan
    dos días hábiles seguidos, a partir de las 06:15 UTC del segundo.
- `bs:senales`, «las señales de BTC no salen», si el paso de las señales lleva
  fallando más de 15 min (Telegram que no las acepta, el cálculo, rqlite).

Con un recordatorio cada 24 h y otro aviso al volver. No culpa a BTC si la base
está parada, sin líder o con la réplica del Wheel atrasada: de eso avisa por su
lado. Un producto que no se escribe desde hace una semana mientras otro sí, se
da por retirado (se quitó de `BTC_PRODUCTOS`) y deja de mirarse; si no se
escribe ninguno, se siguen mirando todos, aunque pasen semanas. Al quitar o
renombrar un producto, el Wheel avisará de él durante esa semana. Con 014 caído
llegan dos avisos de la misma causa: el del nodo y el de BTC.

**Configuración** (entorno o `sentinel.conf` de 014):
- `BTC_AVISOS`: grupos de las señales separados por comas; en cada uno, sus
  productos, el principal primero. Por defecto,
  `"BIP-20DEC30-CDE BTC-USD, TEK-19DEC30-CDE"`; vacío, sin señales.
- `BTC_LABORABLES`: los productos que solo cotizan de lunes a viernes. Por
  defecto, `"TEK-19DEC30-CDE"`; vacío, ninguno.
- `BTC_AVISO_HORAS`: horas tras el cierre de la vela en que una señal todavía
  se manda (36).
- `BTC_TG_CONF`: el fichero del bot.

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

`btc/pruebas/pruebas-velas.sh`: 267 pruebas, todas pasan, en sentinel014 con su
`sh`, que es dash (130 s), y en la laptop (13/11/2026). El Coinbase falso
sirve también un perpetuo con saltos de $5 que empieza un viernes, y hace de
Telegram (apunta cada intento, con su token y su chat, y falla si se le pide).
Cubren:
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
  - cerrojo: el de otra pasada se respeta y deja una línea en el log; el que
    quedó puesto hace más de 30 min se libera;
  - un `--completo` que falla a mitad pide repetirlo;
  - ventanas vacías;
  - que ninguna petición a Coinbase lleve credenciales.
- Las señales:
  - cada una, en los dos sentidos, con su texto, hechas a mano; los bordes
    (cerrar justo en un nivel o en la EMA, varios niveles en una vela, los
    extremos del ciclo, Heikin Ashi sin color en todas sus combinaciones, la
    ruptura que sigue);
  - cada vela con sus propios niveles de Fibonacci, y «supera el máximo»;
  - el reparto entre perpetuo y spot, y lo que deja fuera `desde`;
  - los errores de la entrada (una vela sin su fila de indicadores no cae
    nunca al spot: sale con 2);
  - 8 series al azar contra `avisos-ref.js` (unas 3.500 señales);
  - en las pasadas, comparadas con la referencia de punta a punta (que rehace
    velas, indicadores y Fibonacci por su lado, también los niveles de cada
    vela): la primera que crea la tabla y guarda sin mandar (y la que falla
    antes, que no la crea); las nuevas en un solo mensaje, comparado entero,
    con las del spot y su nota; sin repetir y sin escribir en Raft si no hay
    nada nuevo; Telegram que falla; el borde de las 36 h, diaria y semanal; el
    tope de 25; sin credenciales; un producto que falla; `--seco`; marcar que
    falla; la configuración que no vale (dicha en el log); el awk que falta o
    está roto; los valores por defecto de 014; el estado en `sentinel_vigia`,
    escrito solo al cambiar; y el token, que no sale nunca en la salida, el
    log ni los argumentos de curl.

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

Las señales pasaron por dos rondas de revisión adversarial (cuatro enfoques y
luego los arreglos), con verificadores que intentaban refutar cada hallazgo.
La primera encontró que nadie avisaba si las señales dejaban de salir (de ahí
`bs:senales`), que los niveles de Fibonacci se movían con la vela abierta (de
ahí los niveles de cada vela) y que el aviso del Wheel se callaba tras una
semana parado. La segunda, que el estado de las señales se guiaba por un
fichero local y daba «bien» con un producto caído. Todo lo confirmado está
arreglado. Se estropearon a propósito 40 copias (12 del awk, 18 del script y 10
de `Sentinel-Alert.sh`); las 2 que se colaron en la primera tanda (el borde de
`desde` y los niveles con la propia vela) tienen ya su prueba, y con ellas las
40 se detectan. El banco de avisos (`Sentinel-Selftest-Avisos.sh`) da 191/191
en sentinel014.

## Uso

Lo normal es no hacer nada: el temporizador de sentinel014 hace una pasada cada
5 min (ver «Dónde corre»).

```sh
# Una pasada a mano: en 014, por el mismo servicio (nunca se solapa con el temporizador)
ssh sentinel014 systemctl --user start sentinel-btc-velas.service
# Toda la historia otra vez, también en 014 (comparte el cerrojo con el temporizador)
ssh sentinel014 sh PRC_Sentinel/v2/btc/Sentinel-BTC-Velas.sh --completo
# Desde la laptop: calcular sin escribir (deja los lotes en ~/PRC_Sentinel/btc/seco/)
RQLITE=http://192.168.0.21:4001 sh btc/Sentinel-BTC-Velas.sh --seco
# Banco de pruebas (necesita node y rqlited)
sh btc/pruebas/pruebas-velas.sh
```

**Desde la laptop, mejor no escribir.** El cerrojo es de cada equipo: la laptop
no ve el de 014. Una pasada normal desde la laptop, con el mismo código que hay
en 014 y lejos de las 00:00 UTC, no hace daño. Pero un `--completo` o un código
con otra `VERSION` de los indicadores, con el temporizador en marcha, hacen que
las dos se pisen: 014 acaba rehaciendo todo y los indicadores quedan un rato a
medias. Para probar código nuevo contra la red: parar antes el temporizador o
desplegarlo primero en 014. Además, si la laptop tiene el bot de thermal-guard,
una pasada que escribe también manda las señales pendientes, a la vez que 014:
con `BTC_AVISOS=` (vacío) no las calcula ni las manda.

**Credenciales.** Usa `~/.config/rqlite/sentinel.curlrc`, el usuario `sentinel`
(execute y query). Las peticiones a Coinbase van con `curl -q`, así que nunca
leen un curlrc y nunca llevan credenciales.

**Escrituras.** Una pasada normal reescribe los 4 últimos días cerrados, el de
hoy y 1 o 2 semanas: 6 o 7 filas de velas y 12 o 14 de indicadores por
producto, en 1 entrada de Raft. Fibonacci va en otra: el borrado y los 7 niveles
del spot, y en el perpetuo solo el borrado. En total, 4 entradas de Raft y unos
18 KB por pasada: cada 5 min son ~0,8 entradas por minuto, frente a las ~35 de
base de la red. Además lee la serie diaria (unos 230 KB del spot y 22 KB del
perpetuo) y cuenta los indicadores guardados, a través del líder. La carga
completa va en lotes de 200 con `?transaction`: ~80 lotes y 29 s en 014.

**Un solo nodo.** El cron va en un solo nodo. Si `sentinel.conf` define
`BTC_NODOS="sentinelNNN"`, los demás nodos salen sin hacer nada. Con dos nodos a
la vez la base no se rompe, pero cerca de las 00:00 UTC un reloj desfasado hace
cosas raras durante unos minutos. Uno atrasado puede reabrir la vela de ayer. Uno
adelantado más de 1 min puede cerrar la de hoy antes de tiempo, y deja en el log
un aviso falso de «Coinbase cambio».

## Dónde corre

En **sentinel014**, con un temporizador de systemd de usuario, como el latido.
Es el Ubuntu siempre encendido de la red, con el reloj sincronizado (NTP), y hoy
el líder de rqlite: escribe y lee en local.

| Pieza | En 014 |
|---|---|
| `servicio/sentinel-btc-velas.timer` | Una pasada cada 5 min: minutos 2, 7, 12… y segundo 30, en UTC. La de las 00:02:30 cierra la vela de ayer. |
| `servicio/sentinel-btc-velas.service` | La pasada: `/bin/sh ~/PRC_Sentinel/v2/btc/Sentinel-BTC-Velas.sh`, con `Nice=10` (por debajo de rqlited) y un tope de 20 min. |
| `~/PRC_Sentinel/v2/btc/` | El script y los cinco awk. |
| `~/PRC_Sentinel/btc/` | `velas.log` (las últimas 1.000 líneas, unos 2 días) y el cerrojo. Más atrás, en el journal. |

Usa lo que ya hay en 014: `RQLITE=http://127.0.0.1:4001` de su `sentinel.conf`,
`~/.config/rqlite/sentinel.curlrc` y, para las señales, el bot de
`~/PRC_Thermal/thermal-guard.conf`. Una pasada normal tarda ~1,5 s y 0,6 s de
CPU.

**Instalar o actualizar**, desde Git Bash en la raíz del repo de la laptop (no
desde PowerShell, que estropea la tubería):

```sh
git -c core.autocrlf=false archive HEAD btc/Sentinel-BTC-Velas.sh btc/velas-calculo.awk btc/indicadores-calculo.awk btc/fibonacci-calculo.awk btc/avisos-calculo.awk btc/coinbase-velas.awk btc/servicio | ssh sentinel014 'set -e; d=$(mktemp -d); tar -x -C "$d"; systemctl --user stop sentinel-btc-velas.timer sentinel-btc-velas.service 2>/dev/null || true; mkdir -p ~/PRC_Sentinel/v2/btc; cp "$d"/btc/Sentinel-BTC-Velas.sh "$d"/btc/*.awk ~/PRC_Sentinel/v2/btc/; cp "$d"/btc/servicio/sentinel-btc-velas.* ~/.config/systemd/user/; rm -rf "$d"; systemctl --user daemon-reload; systemctl --user enable --now sentinel-btc-velas.timer'
```

- Si el `git archive` falla, el `set -e` corta antes de parar nada.
- Para el temporizador y una pasada en curso antes de cambiar los ficheros.
- Ojo con el `-c core.autocrlf=false`: en la laptop `core.autocrlf` está a `true`
  y, sin él, `git archive` manda los ficheros con finales CRLF, que dash no
  entiende.
- Comprobar después que el `md5sum` de lo copiado en 014 es el de
  `git show HEAD:<fichero> | md5sum`.

**Volver atrás:** el mismo comando con el commit anterior en lugar de `HEAD`. Si
ese commit tiene otra `VERSION` de los indicadores, la primera pasada los
reescribe enteros (~1 min): mirar el log.

**Quitar:** en 014,
`systemctl --user disable --now sentinel-btc-velas.timer`, borrar las dos
unidades de `~/.config/systemd/user/` y `systemctl --user daemon-reload`. Las
tablas se quedan como estaban.

**Mirar cómo va**, en 014:

```sh
systemctl --user list-timers sentinel-btc-velas.timer    # próxima y última pasada
systemctl --user status sentinel-btc-velas.service       # código de la última
tail ~/PRC_Sentinel/btc/velas.log
journalctl --user -u sentinel-btc-velas -n 30
```

Y desde la laptop, sin entrar en 014: cuántos segundos hace que se escribieron
las velas de cada producto, y el estado de las señales. Cada pasada buena las
reescribe, así que más de 900 s (3 pasadas) quiere decir que algo falla: la
pasada, el temporizador o el propio 014. Es lo mismo que mira el Wheel, que
avisa solo (ver «Señales»).

```sh
curl -q -s -K ~/.config/rqlite/lector.curlrc -G http://192.168.0.21:4001/db/query --data-urlencode "q=SELECT producto, strftime('%s','now') - MAX(actualizado) FROM cripto_vela WHERE marco='1d' GROUP BY producto"
curl -q -s -K ~/.config/rqlite/lector.curlrc -G http://192.168.0.21:4001/db/query --data-urlencode "q=SELECT ts, pendientes FROM sentinel_vigia WHERE clave='btc-senales'"
```

En la segunda, `pendientes` es el código del paso de las señales (0 = bien) y
`ts`, desde cuándo. Un cerrojo que quedó puesto (corte de luz en mitad de una
pasada) se libera solo a los 30 min. Saltar una pasada por el cerrojo y
liberarlo quedan en `velas.log`.

**`contra-coinbase.js` con el temporizador en marcha.** Lee en cuatro
peticiones. Si una pasada entra entre ellas, puede dar «no coinciden» en la vela
de hoy o en su semana. Mejor lanzarlo fuera de los minutos 2-3 y 7-8, y
repetirlo si eso es lo único que sale.

## Pendiente

- Nada por ahora. Lo siguiente lo decide el dueño.
