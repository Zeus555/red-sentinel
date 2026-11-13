// Lineas F de la corriente de las señales (avisos-calculo.awk) para el banco: los
// niveles de Fibonacci de cada vela candidata, calculados con fibonacci-ref.js
// sobre las diarias CERRADAS anteriores a ella, como hace la pasada con
// fibonacci-calculo.awk (fib_por_vela).
// Uso: node niveles-por-vela.js <velas.tsv> <producto> <desde> [caida=0.5] [dura=365]
'use strict';
const fs = require('fs');
const FR = require('./fibonacci-ref');

const [fv, p, desde, ...extra] = process.argv.slice(2);
const o = {};
for (const x of extra) { const [k, v] = x.split('='); o[k] = +v; }
const filas = fs.readFileSync(fv, 'utf8').split('\n').filter(Boolean).map(l => l.split('\t'));
const dias = filas.filter(a => a[0] === '1d' && a[11] === '1').map(a => ({ marco: '1d', ts: +a[1], h: +a[3], l: +a[4], c: +a[5] }));
const hechas = new Set();
let out = '';
for (const a of filas) {
  const ts = +a[1];
  if (a[11] !== '1' || ts + (a[0] === '1d' ? 86400 : 604800) <= +desde || hechas.has(ts)) continue;
  hechas.add(ts);
  const f = FR.fibonacci(dias.filter(d => d.ts < ts), o);
  if (!f) continue;
  for (const n of f.niveles) out += [p, 'F', ts, n.nivel, n.precio, f.bajo_ts, f.bajo, f.alto_ts, f.alto, f.caida].join('\t') + '\n';
}
process.stdout.write(out);
