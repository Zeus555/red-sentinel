# rqlite — el esquema del clúster

`esquema.sql` es el DDL completo de la base distribuida de la red Sentinel,
rescatado el **2026-07-26** leyendo `sqlite_master` en vivo por la API HTTP de
node6 con `level=none`. Solo lectura: no se escribió nada en el clúster.

Hasta esa fecha **el esquema existía únicamente dentro del clúster**. Si los 11
nodos perdían quórum a la vez no había forma de recrearlo, y la vista
`v_sentinel_estado` en particular se había recreado en vivo el 2026-07-21 con un
fix de rendimiento que no estaba escrito en ningún sitio.

Estado en el momento del rescate: 11 nodos, todos alcanzables, líder node4,
SQLite 3.53.2.

| Dominio | Objetos | Filas |
|---|---|---|
| Telemetría de la flota | `sentinel_temp`, `sentinel_disk`, vista `v_sentinel_estado` | 113.226 / 112.192 |
| Lotería Nacional | `sorteo`, `premio`, `archivo`, `catalogo_web`, `prediccion`, `calidad_sorteo`, `equidad`, `no_encontrado`, `corrida` | 1.033 sorteos, 989.207 premios |
| Pipeline Indeed | `indeed_jobs` | 503 |

12 tablas, 1 vista, 7 índices. Se excluyeron los objetos internos de SQLite
(`sqlite_autoindex_*`, `sqlite_sequence`, `sqlite_stat1`): los crea el motor solo.

## La trampa que este fichero ya esquiva

rqlite reescribe las funciones no deterministas —`strftime('%s','now')`,
`datetime('now')`, `RANDOM()`— a **constantes** antes de pasarlas por Raft, para
que todas las réplicas apliquen lo mismo. Consecuencia: un `CREATE VIEW` o un
`DEFAULT` que use `'now'` queda **congelado en el instante de creación**.

Ya mordió dos veces, y las dos correcciones están dentro de `esquema.sql`:

- `v_sentinel_estado` calculaba `activo` contra `'now'` congelado → siempre daba
  1. Ahora compara contra `(SELECT MAX(ts) FROM sentinel_temp) - 180`.
- `sorteo.creado_en` tenía un `DEFAULT` con `'now'`. La tabla se recreó **sin**
  default, conservando sus 1.033 filas; la fecha se manda en el propio `INSERT`,
  donde `datetime('now')` sí es correcto porque rqlite lo congela por sentencia.

**No reintroducir `'now'` en DDL al restaurar.**

La misma recreación de la vista arregló un problema de rendimiento: la versión
original tardaba 17,5 s por una subconsulta correlacionada `MAX(id)` sin índice,
y el chatbot de WhatsApp aborta a los 8 s. El patrón
`JOIN (SELECT node, MAX(ts) … GROUP BY node)` usa `idx_temp_node_ts` /
`idx_disk_node_ts` y responde en ~0,1 s. Regla: toda consulta que use el chatbot
debe terminar muy por debajo de 8 s.

## Aplicar

```bash
rqlite -H 192.168.0.21 -p 4001 < esquema.sql
```

O sentencia a sentencia contra la API:

```bash
curl -XPOST '192.168.0.21:4001/db/execute' -H 'Content-Type: application/json' -d '["CREATE TABLE ..."]'
```

Ojo: `rqlited` escucha en la IP LAN, **no en localhost**. `localhost:4001`
devuelve respuesta vacía. Usar siempre la IP del nodo.

## Lo que esto NO es

Un respaldo de los **datos**: `esquema.sql` solo guarda el esquema, y además se
quedó atrás (no lleva `sentinel_bateria` ni las tablas `cripto_*`). Los datos se
respaldan cada noche, como se explica abajo.

## Respaldo diario

rqlite replica, no respalda: un `DELETE` sin `WHERE` llega a todos los nodos en un
instante. Por eso, desde el **2026-10-30**, sentinel020 baja cada noche una copia y
la guarda fuera del clúster. Código en [`respaldo/`](respaldo).

| Pieza | Dónde | Qué hace |
|---|---|---|
| Tarea `RED Respaldo - rqlite` | sentinel020, 03:45 | Lanza `Sentinel-Respaldo.sh`. Si el equipo estaba apagado, sale al volver |
| Copias | `D:\RED Respaldo\rqlite\` | Se conservan 14 diarias, 8 semanales y 12 mensuales |
| Copia externa | `batchtoday:~/respaldos/rqlite/` | 3 diarias, 2 semanales y 1 mensual, porque la EC2 solo tiene 8,7 GB |
| Vigía | sentinel014, timer cada 6 h | Avisa si la última copia tiene más de 30 h, por si la tarea ni llega a correr |

Medido el 30/10: 154 MB comprimida, 181 s en total y ninguna elección. La copia sale
del disco de sentinel014 con `?noleader` (si falla, de sentinel016), no del líder.

Una copia solo cuenta si pasa `gzip -t`, `integrity_check` y una comparación de filas
con la copia anterior. Si una tabla desaparece o pierde más del 20 % de sus filas, la
copia se guarda, llega un aviso a Telegram y **no se rota nada** en esa pasada, para
que las copias buenas no se pierdan. Archivar datos a propósito dará ese aviso una vez.

Por qué no `-auto-backup` de rqlite: lo hace el líder, que puede ser un nodo por
WiFi, y exige un bucket de S3.

### Restaurar

Toda copia es un SQLite en gzip. `D:\RED Respaldo\Log\respaldo.log` y el `.json` de
cada copia dicen de dónde salió y cuántas filas tenía. Comprobado el 30/10 con la
copia de la EC2 en un rqlited aislado: 33 s de carga y las 18 tablas iguales al
manifiesto.

**Recuperar unas filas o una tabla (lo más probable).** No hace falta tocar el
clúster: abrir la copia con `sqlite3` en otro equipo y reinsertar lo perdido con
`/db/execute`.

**Restaurar la base entera.** Sustituye TODO lo que hay en el clúster y se replica a
todos los nodos por WiFi: es el último recurso.

```bash
gzip -dc rqlite-AAAAMMDD-HHMM.sqlite.gz > copia.sqlite
curl -XPOST 'http://192.168.0.21:4001/db/load' -H 'Content-Type: application/octet-stream' -T copia.sqlite
```

**Ensayar sin riesgo.** Un rqlited suelto, sin `-join` y en loopback, no puede tocar
el clúster:

```bash
rqlited -node-id ensayo -http-addr 127.0.0.1:14001 -raft-addr 127.0.0.1:14002 /tmp/ensayo
```

### Instalar en otro equipo

Copiar `Sentinel-Respaldo.sh`, `respaldo-verifica.js` y `respaldo.cmd` a
`D:\RED Respaldo\Script\`, crear `D:\RED Respaldo\.env` a partir de
[`.env.example`](respaldo/.env.example) y ejecutar `registrar-tarea.ps1`. El vigía va
en `~/PRC_Sentinel/v2/` y sus unidades en `~/.config/systemd/user/`.

Cuando rqlite lleve `-auth`, el `INSERT` del script y la lectura del vigía necesitarán
credenciales.
