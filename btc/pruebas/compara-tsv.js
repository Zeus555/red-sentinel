// Compara la salida tsv de indicadores-calculo.awk con indicadores-ref.js.
// Uso: node compara-tsv.js <velas.tsv> <indicadores.tsv> [clave=valor ...]
//   velas.tsv        salida tsv de velas-calculo.awk (desde=0)
//   indicadores.tsv  salida tsv de indicadores-calculo.awk (desde=0)
//   clave=valor      los mismos largos que se pasaron al awk (ema_a=3 ...)
// Imprime "coincide N filas ..." y sale con 0, o la lista de diferencias y 1.
'use strict';
const fs = require('fs');
const IR = require('./indicadores-ref');

const [fv, fi, ...extra] = process.argv.slice(2);
const o = {};
for (const p of extra) { const [k, v] = p.split('='); o[k] = +v; }
const lee = f => fs.readFileSync(f, 'utf8').split('\n').filter(Boolean).map(l => l.split('\t'));
const velas = lee(fv).map(a => ({ marco: a[0], ts: +a[1], c: +a[5], hc: +a[10], cerrada: +a[11] }));
const nul = x => (x === 'null' ? null : +x);
const got = lee(fi).map(a => {
  const r = { marco: a[0], base: a[1], ts: +a[2] };
  IR.COLUMNAS.forEach((k, i) => { r[k] = nul(a[3 + i]); });
  r.cerrada = +a[3 + IR.COLUMNAS.length]; r.version = IR.VERSION;
  return r;
}).sort((a, b) => (a.marco < b.marco ? -1 : a.marco > b.marco ? 1 : a.base < b.base ? -1 : a.base > b.base ? 1 : a.ts - b.ts));
const exp = IR.indicadores(velas, o);
const f = IR.compara(got, exp, 8);
if (f.length) { console.log('NO COINCIDE: ' + f.join(' | ')); process.exit(1); }
const arriba = got.filter(r => r.rl_ruptura === 1).length, abajo = got.filter(r => r.rl_ruptura === -1).length;
console.log(`coincide ${got.length} filas (rupturas: ${arriba} al alza, ${abajo} a la baja)`);
