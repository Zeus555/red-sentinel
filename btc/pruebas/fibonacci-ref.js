// Calculo de referencia de Fibonacci (fibonacci-calculo.awk), escrito aparte y
// de OTRA forma a proposito: el awk recorre las velas una vez y va cerrando
// caidas; aqui se buscan primero TODOS los maximos historicos, se mira cada par
// seguido de ellos y el precio se saca como media ponderada de las anclas. Si
// los dos coinciden, el awk esta bien. Lo usan las pruebas (comprueba.js y la
// parte F) y la comprobacion con datos reales (contra-coinbase.js).
//
// Tambien sirve suelto, para comparar una salida tsv del awk:
//   node fibonacci-ref.js <velas.tsv> <fibonacci.tsv> [caida=0.5] [dura=365]
'use strict';
const fs = require('fs');

// Los de TradingView por defecto; los mayores que 1 solo si dan precio > 0.
const NIVELES = [0, 0.236, 0.382, 0.5, 0.618, 0.786, 1, 1.618, 2.618, 3.618, 4.236];

// velas: [{marco, ts, h, l, c}] en cualquier orden; solo cuentan las diarias.
// Devuelve null si no hay ciclo, o {bajo, bajo_ts, alto, alto_ts, caida, niveles}.
function fibonacci(velas, o = {}) {
  const caida = o.caida === undefined ? 0.5 : o.caida;
  const dura = o.dura === undefined ? 365 : o.dura;
  const d = velas.filter(v => v.marco === '1d').sort((a, b) => a.ts - b.ts);
  if (!d.length) return null;
  // Indices de los maximos historicos: maximo POR ENCIMA de todos los anteriores.
  const ath = [];
  d.forEach((v, i) => { if (i === 0 || v.h > d[ath[ath.length - 1]].h) ath.push(i); });
  let fondo = null;
  for (let k = 0; k + 1 < ath.length; k++) {
    const a = ath[k], b = ath[k + 1];
    if (b - a < 2) continue; // sin velas entre los dos maximos
    if ((d[b].ts - d[a].ts) / 86400 < dura) continue; // se recupero antes de `dura` dias
    const tramo = d.slice(a + 1, b);
    const peor = Math.min(...tramo.map(v => v.c));
    // Con margen de 1e-12 para que el redondeo no deje fuera un cierre en el borde.
    if (1 - peor / d[a].h < caida - 1e-12) continue;
    const l = Math.min(...tramo.map(v => v.l));
    fondo = { bajo: l, bajo_ts: tramo.find(v => v.l === l).ts, caida: 1 - peor / d[a].h };
  }
  if (!fondo) return null;
  const top = d[ath[ath.length - 1]];
  const r = { ...fondo, alto: top.h, alto_ts: top.ts };
  r.niveles = NIVELES.map(n => ({ nivel: n, precio: r.bajo * n + r.alto * (1 - n) })).filter(x => x.precio > r.alto * 1e-12); // 0 exacto: fuera, con margen de redondeo
  return r;
}

// Compara filas guardadas ({nivel, precio, bajo_ts, bajo, alto_ts, alto, caida},
// ordenadas por nivel) con la referencia. Anclas exactas; precio y caida con
// error relativo 1e-12 (los precios, sobre el tamaño del tramo).
function compara(got, exp, max = 10) {
  const fallos = [];
  const filas = exp ? exp.niveles : [];
  if (got.length !== filas.length) fallos.push(`fibonacci: guardados ${got.length} niveles, esperados ${filas.length}`);
  const cerca = (a, b, escala) => Math.abs(a - b) <= 1e-12 * Math.max(1, Math.abs(escala));
  for (let i = 0; i < Math.min(got.length, filas.length) && fallos.length < max; i++) {
    const g = got[i], x = filas[i];
    if (g.nivel !== x.nivel) { fallos.push(`fibonacci fila ${i}: nivel ${g.nivel} en vez de ${x.nivel}`); continue; }
    if (!cerca(g.precio, x.precio, exp.alto)) fallos.push(`fibonacci ${x.nivel}: precio ${g.precio} != ${x.precio}`);
    for (const k of ['bajo_ts', 'bajo', 'alto_ts', 'alto']) if (g[k] !== exp[k]) fallos.push(`fibonacci ${x.nivel}: ${k} ${g[k]} != ${exp[k]}`);
    if (!cerca(g.caida, exp.caida, exp.caida)) fallos.push(`fibonacci ${x.nivel}: caida ${g.caida} != ${exp.caida}`);
  }
  if (exp) for (const n of [0, 1]) { // los extremos son las anclas, exactos
    const g = got.find(r => r.nivel === n);
    if (g && g.precio !== (n === 0 ? exp.alto : exp.bajo)) fallos.push(`fibonacci ${n}: precio ${g.precio} no es exactamente el ancla`);
  }
  return fallos;
}

const SQL = 'SELECT nivel,precio,bajo_ts,bajo,alto_ts,alto,caida,tramo FROM cripto_fibonacci WHERE producto=? ORDER BY nivel';
const deFila = a => ({ nivel: a[0], precio: a[1], bajo_ts: a[2], bajo: a[3], alto_ts: a[4], alto: a[5], caida: a[6], tramo: a[7] });

module.exports = { NIVELES, SQL, deFila, fibonacci, compara };

if (require.main === module) {
  const [fv, ff, ...extra] = process.argv.slice(2);
  const o = {};
  for (const p of extra) { const [k, v] = p.split('='); o[k] = +v; }
  const lee = f => fs.readFileSync(f, 'utf8').split('\n').filter(Boolean).map(l => l.split('\t'));
  const velas = lee(fv).map(a => ({ marco: a[0], ts: +a[1], h: +a[3], l: +a[4], c: +a[5] }));
  const got = lee(ff).map(a => ({ nivel: +a[0], precio: +a[1], bajo_ts: +a[2], bajo: +a[3], alto_ts: +a[4], alto: +a[5], caida: +a[6] }));
  const exp = fibonacci(velas, o);
  const f = compara(got, exp, 8);
  if (f.length) { console.log('NO COINCIDE: ' + f.join(' | ')); process.exit(1); }
  console.log(exp ? `coincide: ciclo ${exp.bajo} -> ${exp.alto}, ${got.length} niveles` : 'coincide: sin ciclo');
}
