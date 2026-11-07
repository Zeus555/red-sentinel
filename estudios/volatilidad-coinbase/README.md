# Estudio: volatilidad y libro de órdenes en Coinbase

Pregunta: con $1000, ¿hay algún activo volátil de Coinbase, algún monto y algún
horizonte (segundos a minutos) en que comprar del libro y vender después deje
ganancia **después de comisiones**? El plan completo (fases F0-F6) se acordó el
2026-11-02; aquí vive el código de cada fase a medida que se construye.

**Estado (2026-11-06): cerrado tras la F1b.** La F1 (velas, 5-60 min) salió
no-go en intro. El dueño corrigió el horizonte (su ventana real es de ~20 s a
1 min, a veces hasta 5 h), así que se reabrió como F1b con trades a 1 s y la
estrategia «comprar, dejar la venta límite y esperar». También no-go: 0
combinaciones pasan en ningún nivel hasta vip_1. La F2 no se hará. Resultados en
[`resultados-f1/`](resultados-f1/) y [`resultados-f1b/`](resultados-f1b/).

**Solo lectura:** todo usa endpoints públicos. Nada de claves, nada de órdenes.
**Los datos no van a rqlite** (una base grande por WiFi tumbó el clúster el
15-16/10) ni a este repo: viven en `~/estudio-coinbase/` del nodo que los captura.

## Ficheros

| Fichero | Qué es |
|---|---|
| `parametros.json` | F0: comisiones por nivel, cuenta del dueño, universo y umbrales **congelados antes de mirar datos**. Cambiar un umbral después de ver el resultado invalida la puerta; si se cambia algo, se anota en `historial`. |
| `cb_comun.py` | Cliente HTTP lento (≤1 petición/s, reintentos con espera), recorrido del libro y utilidades. |
| `f1_descarga.py` | F1: universo del día, velas de 1 min de 30 días y fotos del libro cada 20 min, en una SQLite local. Reanudable. |
| `f1_analisis.py` | F1: tablas, rankings, curva de monto e informe con la decisión de la puerta. |
| `f1b_descarga.py` | F1b: todos los trades públicos de Exchange de la misma ventana y universo, en páginas paralelas validadas (5 peticiones/s, 6 hilos). Reanudable. |
| `f1b_analisis.py` | F1b: rejilla de 1 s con ask/bid coherentes, puerta ρ a 5-60 s, toma de ganancia (5 s → sin plazo), tiempos de llegada e impulso. Caché por activo. |
| `f1b_informe.py` | F1b: escribe `informe_f1b.md` a partir de los CSV. |

Solo biblioteca estándar de Python 3 (sentinel014 no tiene Node ni pip).

## F1: puerta barata

Con velas no se ven ni el bid/ask ni los llenados, así que la F1 usa **cotas
favorables a la estrategia**: coste = solo comisión y salida en el máximo de las
velas siguientes. Si ni así aparece nada, el no-go es robusto; un "pasa" solo
justifica gastar la F2 en ese activo.

**Regla preregistrada (v2).** Para cada combinación activo × horizonte × modo:

    ρ_req = U / (σ_h · factor)          U = (1 + f_compra) / (1 − f_venta) − 1

ρ_req es la correlación que tendría que tener una señal con el retorno a h para
que, operando solo el q = 1 % de ventanas en que la señal es más alta, el retorno
medio cubra U. Se calcula con dos factores y decide el más favorable:

- **normal**: φ(z_q)/q = 2,665;
- **empírico**: el mismo factor medido con los retornos reales del activo (una
  señal simulada de ρ = 0,2 sobre sus retornos estandarizados, corregida por un
  control normal del mismo tamaño). Con las colas gruesas de las criptos rinde un
  15-75 % más que la normal (revisión del 2026-11-06).

Si en el nivel de comisión de la cuenta **todas** las combinaciones de un modo
(TT, MT o TM) quedan con ρ_req > 0,2, ese modo es **no-go**. MM no se puede
evaluar con velas y pasa siempre a la F2. Un activo con tramos de velas que
faltan queda fuera de la puerta (sus huecos rellenados desinflarían σ).

### Cómo se corre (en sentinel014)

```bash
scp cb_comun.py f1_descarga.py f1_analisis.py parametros.json sentinel014:estudio-coinbase/codigo/
```

```bash
ssh sentinel014 'systemd-run --user --unit=estudio-coinbase-f1 --collect -p Nice=10 --working-directory=/home/sentinel/estudio-coinbase/codigo /usr/bin/python3 f1_descarga.py --datos /home/sentinel/estudio-coinbase/f1'
```

Tarda ~1 h 45 min para 51 activos (124 peticiones de velas por activo a 1/s). Si
se corta, el mismo comando sigue donde estaba: la ventana y el universo quedan
congelados en la primera ejecución. Al terminar deja `descarga.ok`.

```bash
ssh sentinel014 'cd ~/estudio-coinbase/codigo && python3 f1_analisis.py --datos ~/estudio-coinbase/f1'
```

Escribe en la carpeta de datos `informe_f1.md`, `f1_combinaciones.csv`,
`f1_activos.csv`, `f1_monto.csv` y `f1_resumen.json`.

Prueba corta (un día, tres activos, en otra carpeta):

```bash
ssh sentinel014 'cd ~/estudio-coinbase/codigo && python3 f1_descarga.py --datos ~/estudio-coinbase/prueba --dias 1 --solo ZEC-USD,BTC-USD'
```

### Sesgos que la F1 declara

- El universo es el de **hoy** mirando 30 días atrás: los activos deslistados no están.
- Las velas son trades, no bid/ask: el maker no se puede evaluar y los segundos (5-30 s) no se ven.
- El monto sale de pocas fotos del libro de un solo día.

## Resultado de la F1 (2026-11-06)

Ventana 2026-10-07 → 2026-11-06, 51 activos, 1 638 439 velas, 0 errores.

- **Intro:** la regla pasa formalmente solo en BIRB-USD (5 y 15 min) y
  ALIGN-USD (15 min), y solo por el factor empírico. Los dos casos salen de un
  único bombeo cada uno (BIRB, 23-24/10; ALIGN, 05/11). Quitando entre 1 y 10
  ventanas extremas vuelven a no-go. Además son libros finos: el 69 % y el 81 % de
  los minutos no tienen ningún trade, y ALIGN solo admite unos $66.
- **Activos líquidos** (NEAR, ENA, ZEC, ONDO, HYPE, UNI): no-go en intro,
  advanced_1 y advanced_2. La puerta abre por primera vez en advanced_3
  ($250K de volumen a 30 días), y solo a 15 min. BTC y ETH necesitan nivel VIP.
- **Monto:** con $1000 el coste de ida y vuelta en los líquidos es de unos
  184-188 pb, casi todo comisión. El tamaño apenas cambia el resultado.

| Fichero en `resultados-f1/` | Qué es |
|---|---|
| `informe_f1.md` | Informe completo: decisión por nivel y modo, top 10, nivel necesario, curva de monto. |
| `robustez_f1.md` | Diagnóstico posterior de los «pasa» (no cambia la regla). |
| `diagnostico_colas.py` | Script de ese diagnóstico (solo lectura sobre `f1.sqlite`). |
| `f1_activos.csv`, `f1_monto.csv` | Tablas por activo y por monto. |

La SQLite (144 MB), `f1_combinaciones.csv` (2 MB) y `f1_resumen.json` se quedan
en sentinel014, en `~/estudio-coinbase/f1/`, y no se suben al repo.

## F1b: segundos y toma de ganancia (2026-11-06)

La F1 medía horizontes fijos de 5 a 60 min. El dueño corrigió: su ventana real es
de unos 20 s, nunca más de 1 min, aunque a veces vio que duraba hasta 5 h, y cree
que «el suceso es más probable en el menor tiempo». La F1b mide eso:

- **Datos:** `GET /products/{id}/trades?after=` de Exchange (público). `side` es
  el lado del **maker**: `sell` = compra taker al ask. Se confirmó con barridos
  (trades seguidos del mismo lado en el mismo ms): 3,85 M encajan y 13,5 K no.
  Total: 51,2 M trades, 0 respuestas 429, 0 páginas inválidas.
- **Rejilla de 1 s:** ask y bid salen del último taker de cada lado. El lado que
  no opera se mueve con el que sí; si lleva más de 60 s quieto se reancla con el
  spread mediano de las fotos de la F1. Nunca quedan cruzados.
- **Toma de ganancia (decide):** comprar al ask y dejar una venta límite que deja
  m neto (10-100 pb) tras las dos comisiones. Esperar 5 s … 5 h o sin plazo; si no
  se llena, vender a mercado. Pasa si en **cada mitad** de la ventana $1000
  terminan por encima de $1000 y de comprar y mantener, con ≥ 30 operaciones.
  Llenado: basta un taker que pague el objetivo (favorable); la variante con
  volumen exige ≥ $1000 comprados en un segundo (la cota contraria).
- **Puerta ρ de la F1 a 5, 10, 20, 30 y 60 s**, y **exploratorio de impulso**
  (entrar cuando el ask ya subió X pb en 5 s; no decide).

El código pasó una revisión adversarial (30 agentes) y un recálculo independiente
de BNB y PONS que cuadró al decimal. Los cambios están en `parametros.json`
(v3, v3.1); ninguna regla de decisión cambió tras ver datos.

### Cómo se corre (en sentinel014)

```bash
ssh sentinel014 'systemd-run --user --unit=estudio-coinbase-f1b --collect -p Nice=10 --working-directory=/home/sentinel/estudio-coinbase/codigo /usr/bin/python3 f1b_descarga.py --datos /home/sentinel/estudio-coinbase/f1b'
```

```bash
ssh sentinel014 'cd ~/estudio-coinbase/codigo && nice -n 10 python3 f1b_analisis.py --datos ~/estudio-coinbase/f1b --esperar && python3 f1b_informe.py --datos ~/estudio-coinbase/f1b'
```

La descarga tarda ~2 h (35 467 páginas). El análisis con trades tarda ~2,5 h en
014 (`--solo-velas` ~8 min). Los dos se reanudan: la descarga por página y el
análisis por activo, con una caché que se invalida si cambia el código o los
parámetros.

### Resultado de la F1b

- **Comprar, dejar la venta y esperar:** 0 de 2244 combinaciones pasan en TM y 0
  en TT (intro), también con la variante con volumen. **Ninguna pasa en ningún
  nivel hasta vip_1.** Con plazo finito, ni una sola deja ambas mitades por encima
  de $1000, ni siquiera en vip_1.
- **La media por operación no mejora con la espera:** en NEAR es de unos −180 pb
  esperando 20 s, 1 h o 5 h. Solo cambia el reparto: más aciertos, pero pérdidas
  más grandes en los que no llegan. Sin una señal que prediga, una venta límite con
  plazo no crea ventaja (teorema de parada opcional): queda ≈ deriva − comisión.
- **¿Más probable en menos tiempo?** Con intro, el objetivo queda a ~151 pb de la
  entrada para ganar 10 pb netos, y en 20 s el precio se mueve ~3 pb (BTC), ~10 pb
  (NEAR) o ~30 pb (BIRB). Por eso, en 42 de 51 activos, las llegadas por segundo
  alcanzan su máximo después de 5 min (32 de ellos entre 15 min y 3 h). Solo 7
  activos finos lo tienen dentro del primer minuto (BIRB, ALIGN, CLANKER, ICNT,
  DRV, WLFI, CBETH). Incluso en BIRB, solo el 2,1 % de las entradas llega en
  20 s, frente al 76 % en 5 h. En el activo mediano, de lo que llega en 5 h solo el
  0,08 % llega en el primer minuto.
- **Horizonte fijo 5-60 s:** 0 de 255 en cada modo. Mejor ρ_req: 0,39 (BIRB a
  60 s, TM), frente a la puerta de 0,20. BTC necesitaría ρ ≥ 8.
- **Impulso:** comprar cuando ya subió 25-50 pb en 5 s no ayuda. BIRB acierta el
  10 % a 20 s, pero pierde 203 pb de media.

| Fichero en `resultados-f1b/` | Qué es |
|---|---|
| `informe_f1b.md` | Informe completo: respuesta corta, tiempos de llegada, toma de ganancia, nivel necesario, puerta ρ, impulso y comprobaciones. |
| `f1b_resumen.json`, `f1b_velas_resumen.json` | Resumen de la decisión (trades y velas). |
| `f1b_tiempos_intro_tm10.csv`, `f1b_velas_tiempos_intro_tm10.csv` | Probabilidad de llegar antes de cada plazo y densidad por tramo (TM, intro, 10 pb netos), por activo. |
| `f1b_activos.csv`, `f1b_velas_activos.csv` | Trades por activo, barridos por lado y cobertura. |
| `f1b_impulso.csv` | Exploratorio de impulso. |

La SQLite de trades (569 MB) y los CSV completos (`f1b_toma_ganancia.csv` 5 MB,
`f1b_puerta_segundos.csv` 1,4 MB, `f1b_tiempos.csv`) se quedan en sentinel014,
en `~/estudio-coinbase/f1b/`.

## Pendiente del dueño (F0)

En `parametros.json → cuenta`: región confirmada, `nivel_real` (lo muestra la
página de comisiones de Coinbase Advanced), Coinbase One y promo VIP3. Mientras
`nivel_real` sea `null`, la puerta se evalúa con `nivel_supuesto` (`intro`) y el
informe lo dice.
