// Comprueba una copia de la base rqlite y escribe su manifiesto.
//
//   node respaldo-verifica.js <copia.sqlite> <manifiesto.json> [manifiesto-previo.json]
//
// Sale con 0 = sana | 1 = no sirve | 2 = sana, pero con algo raro (ver avisos).
// Escribe en stdout una sola linea, que Sentinel-Respaldo.sh guarda en su log.
//
// Va con node:sqlite porque sentinel020 no trae sqlite3 y node ya esta instalado.
// Abre la copia descomprimida en lectura-escritura a proposito: rqlite la deja con
// la cabecera en modo WAL, que necesita crear -wal y -shm. Es un fichero temporal y
// el hash que vale es el del .gz, tomado antes de abrirla.
'use strict';
const fs = require('node:fs');
const { DatabaseSync } = require('node:sqlite');

const [, , copia, salida, previo] = process.argv;
const MAX_EDAD_S = Number(process.env.RESP_MAX_EDAD_S) || 900;
const UMBRAL_CAIDA = Number(process.env.RESP_UMBRAL_CAIDA) || 0.2;
const MIN_FILAS = 100; // por debajo de esto, un cambio relativo no dice nada

function falla(motivo) {
  console.log('NO SIRVE: ' + motivo);
  process.exit(1);
}

let db;
try {
  db = new DatabaseSync(copia);
} catch (e) {
  falla(e.message);
}

const avisos = [];
const tablas = {};
let edad = null;
try {
  const integridad = db.prepare('PRAGMA integrity_check').all().map((f) => f.integrity_check).join('; ');
  if (integridad !== 'ok') falla('integrity_check: ' + integridad.slice(0, 200));

  const nombres = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").all();
  if (nombres.length === 0) falla('la copia no tiene tablas');
  for (const { name } of nombres) {
    tablas[name] = db.prepare(`SELECT COUNT(*) c FROM "${name.replace(/"/g, '""')}"`).get().c;
  }

  // Sin escrituras recientes la copia puede estar bien y aun asi avisar de algo: un
  // nodo muy atrasado o un cluster sin quorum. Nada mas lo mira hoy.
  if ('sentinel_temp' in tablas) {
    const m = db.prepare('SELECT MAX(ts) m FROM sentinel_temp').get().m;
    if (m) edad = Math.floor(Date.now() / 1000) - m;
  }
} catch (e) {
  falla(e.message);
} finally {
  db.close();
}

if (edad === null) avisos.push('sin telemetria en sentinel_temp');
else if (edad > MAX_EDAD_S) avisos.push(`la telemetria mas reciente tiene ${Math.round(edad / 60)} min`);

// Lo que no es corrupcion pero duele igual: la base bien formada y medio vacia. Es
// justo lo que produciria un borrado replicado.
if (previo && fs.existsSync(previo)) {
  try {
    const antes = JSON.parse(fs.readFileSync(previo, 'utf8')).tablas || {};
    for (const [t, n] of Object.entries(antes)) {
      if (n < MIN_FILAS) continue;
      if (!(t in tablas)) avisos.push(`desaparecio la tabla ${t} (${n} filas)`);
      else if (tablas[t] < n * (1 - UMBRAL_CAIDA)) avisos.push(`${t} bajo de ${n} a ${tablas[t]} filas`);
    }
  } catch (e) {
    avisos.push('no se pudo leer el manifiesto anterior: ' + e.message);
  }
}

const total = Object.values(tablas).reduce((a, b) => a + b, 0);
fs.writeFileSync(salida, JSON.stringify({
  generado: new Date().toISOString(),
  fichero: process.env.RESP_FICHERO || '',
  fuente: process.env.RESP_FUENTE || '',
  bytes_gz: Number(process.env.RESP_BYTES) || 0,
  sha256: process.env.RESP_SHA || '',
  bytes_sqlite: fs.statSync(copia).size,
  edad_telemetria_s: edad,
  tablas,
  avisos,
}, null, 2) + '\n');

const base = `integridad ok, ${Object.keys(tablas).length} tablas, ${total} filas, telemetria de hace ${edad === null ? '?' : edad + ' s'}`;
if (avisos.length) {
  console.log(base + '; AVISOS: ' + avisos.join('; '));
  process.exit(2);
}
console.log(base);
