-- =====================================================================
-- Esquema del cluster rqlite de la red Sentinel
-- =====================================================================
--
-- Rescatado el 2026-07-26 desde el cluster EN VIVO, leyendo sqlite_master por
-- la API HTTP de node6 (sentinel014, 192.168.0.21:4001) con level=none.
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
-- COMO SE APLICA (con contraseña desde el 2026-11-11: desde la laptop, con admin y
-- contra un votante; ver rqlite/auth/README.md, "Operaciones a mano con la puerta cerrada")
--   curl -K ~/.config/rqlite/admin.curlrc -XPOST 'http://<ip-votante>:4001/db/execute' \
--        -H 'Content-Type: application/json' -d '["CREATE TABLE ..."]'
-- El shell "rqlite -H <ip> -p 4001 < esquema.sql" solo acepta la clave con -u (queda
-- en argv): mejor no usarlo.
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

-- ---------------------------------------------------------------------
-- RESPALDOS (una fila por copia buena; la escribe sentinel020 y la lee el vigia
-- de sentinel014, ver respaldo/). Anadida el 2026-10-30.
-- ---------------------------------------------------------------------

CREATE TABLE sentinel_respaldo (fichero TEXT PRIMARY KEY, ts INTEGER NOT NULL, fuente TEXT, bytes INTEGER, sha256 TEXT, offsite INTEGER, aviso TEXT);


-- ---------------------------------------------------------------------
-- VELAS DE BTC de Coinbase, diarias y semanales con Heikin Ashi: el perpetuo
-- de futuros (BIP-20DEC30-CDE, volumen en contratos de 0,01 BTC) y el spot
-- (BTC-USD). La escribe btc/Sentinel-BTC-Velas.sh (usuario sentinel), que la
-- crea si no existe. Una fila por producto, marco ('1d' o '1w', semana de lunes
-- 00:00 UTC) y ts (inicio de la vela, segundos UTC). cerrada=0 es la vela en
-- curso. dias solo en '1w': cuantos dias la forman (7 = completa; 5 en los que
-- solo cotizan de lunes a viernes, como TEK-19DEC30-CDE, el perpetuo del Tech
-- 100, cuya semana se cierra al acabar el viernes). ~4.700 filas de BTC-USD
-- desde 2015, ~550 del perpetuo desde 18/07/2025 y ~130 de TEK desde
-- 15/06/2026; ~21 filas nuevas por semana. Anadida el 2026-11-12; TEK el
-- 2026-11-14.
-- ---------------------------------------------------------------------

CREATE TABLE cripto_vela (producto TEXT NOT NULL, marco TEXT NOT NULL, ts INTEGER NOT NULL, apertura REAL NOT NULL, maximo REAL NOT NULL, minimo REAL NOT NULL, cierre REAL NOT NULL, volumen REAL NOT NULL, ha_apertura REAL, ha_maximo REAL, ha_minimo REAL, ha_cierre REAL, cerrada INTEGER NOT NULL, dias INTEGER, fuente TEXT, actualizado INTEGER NOT NULL, PRIMARY KEY (producto, marco, ts)) WITHOUT ROWID;

-- ---------------------------------------------------------------------
-- INDICADORES DE BTC sobre cripto_vela: una fila por producto, marco, base y
-- ts (los de cripto_vela). base 'real' calcula sobre el cierre real y 'ha'
-- sobre el cierre Heikin Ashi (lo que dibuja TradingView en Heikin Ashi).
-- EMA 100 y 200; Bollinger 20 con 2σ; canal de regresion de 100 velas con 2σ
-- (centro, bandas, pendiente por vela, Pearson con signo) y rl_ruptura: 1 si el
-- cierre quedo por encima del canal de las 100 velas anteriores, -1 por debajo,
-- 0 dentro. null donde aun no hay velas suficientes. version es la del calculo
-- (indicadores-calculo.awk). La escribe btc/Sentinel-BTC-Velas.sh, que la crea
-- si no existe. ~10.600 filas. Anadida el 2026-11-12.
-- ---------------------------------------------------------------------

CREATE TABLE cripto_indicador (producto TEXT NOT NULL, marco TEXT NOT NULL, base TEXT NOT NULL, ts INTEGER NOT NULL, ema100 REAL, ema200 REAL, bb_media REAL, bb_sup REAL, bb_inf REAL, rl_centro REAL, rl_sup REAL, rl_inf REAL, rl_pendiente REAL, rl_r REAL, rl_ruptura INTEGER, cerrada INTEGER NOT NULL, version INTEGER NOT NULL, actualizado INTEGER NOT NULL, PRIMARY KEY (producto, marco, base, ts)) WITHOUT ROWID;

-- ---------------------------------------------------------------------
-- FIBONACCI DE BTC: los niveles de retroceso del tramo 'ciclo', del fondo del
-- ultimo mercado bajista ya superado (el peor cierre >= 50 % bajo el maximo
-- historico de entonces, y al menos un año hasta volver a superarlo) al maximo
-- historico; hoy del minimo de 2022 (15.460) al ATH de 2025 (126.296).
-- nivel 0 = el maximo, 1 = el minimo, precio = alto - nivel x (alto - bajo);
-- los de TradingView por defecto (0 a 1, y 1,618 a 4,236 solo si dan un precio
-- positivo). Cada fila lleva las dos anclas y caida (lo que cayo el cierre en
-- aquel bajista). Solo hay filas de un producto con historia para tener un
-- ciclo (BTC-USD). Se rehace entera en cada pasada de btc/Sentinel-BTC-Velas.sh,
-- que la crea si no existe. Hoy 7 filas. Anadida el 2026-11-12.
-- ---------------------------------------------------------------------

CREATE TABLE cripto_fibonacci (producto TEXT NOT NULL, tramo TEXT NOT NULL, nivel REAL NOT NULL, precio REAL NOT NULL, bajo_ts INTEGER NOT NULL, bajo REAL NOT NULL, alto_ts INTEGER NOT NULL, alto REAL NOT NULL, caida REAL NOT NULL, actualizado INTEGER NOT NULL, PRIMARY KEY (producto, tramo, nivel)) WITHOUT ROWID;

-- ---------------------------------------------------------------------
-- SEÑALES DE MERCADO (BTC y el Tech 100): una fila por grupo (el activo: su
-- producto principal, BIP-20DEC30-CDE para BTC y TEK-19DEC30-CDE para el Tech
-- 100), señal al cierre de una vela (marco 1d/1w, ts de la vela) y tipo: canal (ruptura del canal de regresion), ema100, ema200, emas
-- (cruce entre las dos), fib (cruce de niveles de Fibonacci) o ha (cambio de
-- color del Heikin Ashi). producto = la serie de la que salio: en BTC, el
-- perpetuo, o el spot donde al perpetuo le falta el dato; en el Tech 100, TEK. sentido 1 arriba, -1 abajo; precio =
-- cierre; nivel = la referencia cruzada (EMA, borde, nivel, cierre HA); texto =
-- la linea del mensaje. enviado: null pendiente, 0 no se manda (de antes de
-- crear la tabla), -1 caducada sin mandar (vela cerrada hace mas de 36 h), o la
-- hora en que Telegram la acepto. La escribe btc/Sentinel-BTC-Velas.sh con
-- INSERT OR IGNORE (una señal no se duplica ni se vuelve a mandar), que la crea
-- con sus primeras señales. El estado de ese paso va en sentinel_vigia (fila
-- btc-senales: ts desde cuando, pendientes = su codigo, 0 bien). Anadida el
-- 2026-11-13 con la clave (marco, ts, tipo); el 2026-11-14 paso a (grupo,
-- marco, ts, tipo) para el Tech 100 (el script migra sola la de antes, en una
-- transaccion: las señales viejas quedan con grupo BIP-20DEC30-CDE).
-- ---------------------------------------------------------------------

CREATE TABLE cripto_aviso (grupo TEXT NOT NULL, marco TEXT NOT NULL, ts INTEGER NOT NULL, tipo TEXT NOT NULL, producto TEXT NOT NULL, sentido INTEGER NOT NULL, precio REAL NOT NULL, nivel REAL, texto TEXT NOT NULL, creado INTEGER NOT NULL, enviado INTEGER, PRIMARY KEY (grupo, marco, ts, tipo)) WITHOUT ROWID;

-- fin: 17 tablas, 1 vista(s), 7 indices
