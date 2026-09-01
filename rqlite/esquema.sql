-- =====================================================================
-- Esquema del cluster rqlite de la red Sentinel
-- =====================================================================
--
-- Rescatado el 2026-07-26 desde el cluster EN VIVO, leyendo sqlite_master por
-- la API HTTP de node6 (sentinel014, 192.168.1.250:4001) con level=none.
-- Solo lectura: no se escribio nada en el cluster para obtener esto.
--
-- POR QUE EXISTE ESTE FICHERO
-- Hasta hoy el esquema vivia UNICAMENTE en el cluster. Si los 11 nodos perdian
-- quorum a la vez no habia forma de recrearlo: la vista v_sentinel_estado, en
-- particular, se recreo en vivo el 2026-07-21 con un fix de rendimiento que no
-- estaba escrito en ningun sitio. Este es el respaldo de ese conocimiento.
--
-- ESTADO EN EL MOMENTO DEL RESCATE
--   nodos            11 (todos alcanzables), lider node4
--   sqlite           3.53.2
--   sentinel_temp    113.226 filas
--   sentinel_disk    112.192 filas
--   premio           989.207 filas
--   sorteo           1033 filas
--   indeed_jobs      503 filas
--
-- OJO AL RESTAURAR: rqlite reescribe las funciones no deterministas
-- (strftime('%s','now'), datetime('now'), RANDOM()) a CONSTANTES antes de
-- pasarlas por Raft. Un CREATE VIEW o un DEFAULT que use 'now' queda congelado
-- al instante de creacion. Por eso v_sentinel_estado compara contra
-- (SELECT MAX(ts) FROM sentinel_temp) y no contra 'now', y por eso la tabla
-- sorteo no lleva DEFAULT en creado_en: la fecha se manda en el propio INSERT.
-- Este fichero ya refleja las versiones corregidas. NO reintroducir 'now'.
--
-- COMO SE APLICA
--   rqlite -H <ip> -p 4001 < esquema.sql
-- o sentencia a sentencia:
--   curl -XPOST '<ip>:4001/db/execute' -H 'Content-Type: application/json' \
--        -d '["CREATE TABLE ..."]'
-- =====================================================================


-- ---------------------------------------------------------------------
-- TELEMETRIA DE LA FLOTA
-- ---------------------------------------------------------------------

CREATE TABLE sentinel_temp (id INTEGER PRIMARY KEY AUTOINCREMENT, node TEXT NOT NULL, ts INTEGER NOT NULL, temp_c REAL NOT NULL, source TEXT, level TEXT, raft_node_id TEXT);
CREATE INDEX idx_temp_node_ts ON sentinel_temp(node, ts);

CREATE TABLE sentinel_disk (id INTEGER PRIMARY KEY AUTOINCREMENT, node TEXT NOT NULL, raft_node_id TEXT, ts INTEGER NOT NULL, int_total_kb INTEGER, int_free_kb INTEGER, sd_total_kb INTEGER, sd_free_kb INTEGER);
CREATE INDEX idx_disk_node_ts ON sentinel_disk(node, ts);

CREATE VIEW "v_sentinel_estado" AS SELECT "t"."node", "t"."raft_node_id", CASE WHEN "t"."ts" > (SELECT MAX("ts") FROM "sentinel_temp") - 180 THEN 1 ELSE 0 END AS "activo", "t"."temp_c", "t"."level" AS "nivel_temp", "t"."source" AS "fuente_temp", ROUND("d"."int_free_kb" / 1048576.0, 1) AS "libre_gb", ROUND("d"."int_total_kb" / 1048576.0, 1) AS "total_gb", ROUND(100.0 * "d"."int_free_kb" / "d"."int_total_kb") AS "pct_libre", ROUND("d"."sd_free_kb" / 1048576.0, 1) AS "sd_libre_gb", datetime("t"."ts", 'unixepoch', 'localtime') AS "ultima_lectura" FROM "sentinel_temp" AS "t" JOIN (SELECT "node", MAX("ts") AS "mts" FROM "sentinel_temp" GROUP BY "node") AS "m" ON "m"."node" = "t"."node" AND "t"."ts" = "m"."mts" AND "t"."id" = (SELECT MAX("id") FROM "sentinel_temp" WHERE "node" = "t"."node" AND "ts" = "t"."ts") LEFT JOIN (SELECT "node", MAX("ts") AS "mts" FROM "sentinel_disk" GROUP BY "node") AS "md" ON "md"."node" = "t"."node" LEFT JOIN "sentinel_disk" AS "d" ON "d"."node" = "md"."node" AND "d"."ts" = "md"."mts" AND "d"."id" = (SELECT MAX("id") FROM "sentinel_disk" WHERE "node" = "d"."node" AND "ts" = "d"."ts");

-- ---------------------------------------------------------------------
-- LOTERIA NACIONAL
-- ---------------------------------------------------------------------

CREATE TABLE sorteo (num_sorteo INTEGER PRIMARY KEY, tipo TEXT, fecha TEXT, fecha_txt TEXT, nombre TEXT, url_pdf TEXT, url_img TEXT, fuente TEXT, creado_en TEXT);

CREATE TABLE premio (
  id           INTEGER PRIMARY KEY,
  num_sorteo   INTEGER NOT NULL,
  tipo_premio  TEXT NOT NULL,
  numero       TEXT NOT NULL,
  serie        TEXT,
  monto        REAL,
  metodo       TEXT NOT NULL,
  confianza    REAL
);
CREATE INDEX idx_premio_numero ON premio(numero);
CREATE INDEX idx_premio_sorteo ON premio(num_sorteo);

CREATE TABLE archivo (
  ruta            TEXT PRIMARY KEY,
  num_sorteo      INTEGER,
  tipo            TEXT,
  sha256          TEXT,
  bytes           INTEGER,
  num_interno_pdf INTEGER,
  descargado_en   TEXT,
  verificado_en   TEXT,
  estado          TEXT
);
CREATE INDEX idx_archivo_sorteo ON archivo(num_sorteo);

CREATE TABLE catalogo_web (
  capturado_en TEXT,
  num_sorteo   INTEGER,
  url_pdf      TEXT,
  url_img      TEXT,
  fecha_txt    TEXT,
  PRIMARY KEY (capturado_en, num_sorteo)
);

CREATE TABLE prediccion (
  generado_en   TEXT,
  para_sorteo   INTEGER,
  modelo        TEXT,
  ambito        TEXT,
  valor         TEXT,
  probabilidad  REAL,
  PRIMARY KEY (generado_en, para_sorteo, modelo, ambito, valor)
);

CREATE TABLE calidad_sorteo (
  num_sorteo          INTEGER PRIMARY KEY,
  tiene_pdf           INTEGER,
  tiene_img           INTEGER,
  tiene_info          INTEGER,
  nombre_coincide     INTEGER,
  premios_extraidos   INTEGER,
  premios_esperados   INTEGER,
  acuerdo_metodos     REAL,
  score               REAL,
  detalle             TEXT,
  evaluado_en         TEXT
);

CREATE TABLE equidad (analizado_en TEXT, test TEXT, estadistico REAL, df INTEGER, p_value REAL, significativo_fdr INTEGER, detalle TEXT, PRIMARY KEY (analizado_en, test));

CREATE TABLE no_encontrado (
  num_sorteo  INTEGER,
  numero      TEXT,
  monto       REAL,
  tipo_premio TEXT,
  origen      TEXT
);

CREATE TABLE corrida (
  id                INTEGER PRIMARY KEY,
  inicio            TEXT,
  fin               TEXT,
  comando           TEXT,
  filas_procesadas  INTEGER,
  ok                INTEGER,
  detalle           TEXT
);

-- ---------------------------------------------------------------------
-- PIPELINE INDEED
-- ---------------------------------------------------------------------

CREATE TABLE indeed_jobs (
        job_key TEXT PRIMARY KEY,
        title TEXT,
        company TEXT,
        location TEXT,
        salary TEXT,
        link TEXT,
        description TEXT,
        english_level TEXT,
        hours_per_week TEXT,
        shift_schedule TEXT,
        match_score INTEGER,
        match_reason TEXT,
        status TEXT,
        is_sponsored INTEGER,
        first_seen_at TEXT,
        last_seen_at TEXT,
        disappeared_at TEXT,
        applied_at TEXT,
        synced_at TEXT
    );
CREATE INDEX idx_indeed_jobs_last_seen ON indeed_jobs(last_seen_at);
CREATE INDEX idx_indeed_jobs_status ON indeed_jobs(status);

-- fin: 12 tablas, 1 vista(s), 7 indices
