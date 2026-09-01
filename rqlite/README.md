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
rqlite -H 192.168.1.250 -p 4001 < esquema.sql
```

O sentencia a sentencia contra la API:

```bash
curl -XPOST '192.168.1.250:4001/db/execute' -H 'Content-Type: application/json' -d '["CREATE TABLE ..."]'
```

Ojo: `rqlited` escucha en la IP LAN, **no en localhost**. `localhost:4001`
devuelve respuesta vacía. Usar siempre la IP del nodo.

## Lo que esto NO es

Un respaldo de los **datos**. Solo del esquema. Los 989.207 premios y los 225.418
registros de telemetría viven en el clúster y en nada más. Si eso importa, hace
falta un `.dump` periódico, que hoy no existe.
