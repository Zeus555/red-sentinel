// Calculo de referencia de las señales (avisos-calculo.awk), escrito aparte y de
// OTRA forma a proposito: el awk evalua cada vela candidata; aqui se saca primero,
// para cada producto, señal y vela, un "estado" (lado de la EMA, valor de la
// ruptura, lado de cada nivel, color con arrastre) y la señal es un cambio de
// estado entre dos velas seguidas. Los textos tambien se rehacen aqui, con otras
// funciones de formato. Si los dos coinciden, el awk esta bien.
//
// Suelto: node avisos-ref.js <corriente> <salida-tsv-del-awk> <orden> <desde>
'use strict';
const fs = require('fs');

const DUR = { '1d': 86400, '1w': 604800 };
const FAMILIAS = ['canal', 'ema100', 'ema200', 'emas', 'fib', 'ha'];

// La misma corriente que lee el awk.
function lee(texto) {
  const p = {};
  // fib: { ts de la vela candidata: [niveles vigentes antes de ella] }
  const de = id => p[id] || (p[id] = { velas: { '1d': [], '1w': [] }, ind: {}, fib: {} });
  for (const l of texto.split('\n')) {
    if (!l) continue;
    const a = l.split('\t');
    const x = de(a[0]);
    const n = v => (v === 'null' || v === '' ? null : +v);
    if (a[1] === 'V') { if (a[13] === '1') x.velas[a[2]].push({ ts: +a[3], c: +a[7], ho: +a[9], hc: +a[12] }); }
    else if (a[1] === 'I') { if (a[3] === 'real') x.ind[a[2] + '/' + a[4]] = { e1: n(a[5]), e2: n(a[6]), rc: n(a[10]), rs: n(a[11]), rp: n(a[13]), ru: n(a[15]) }; }
    else if (a[1] === 'F') (x.fib[a[2]] || (x.fib[a[2]] = [])).push({ nivel: +a[3], precio: +a[4], bajo: +a[6], alto: +a[8] });
  }
  for (const x of Object.values(p)) for (const m of ['1d', '1w']) x.velas[m].sort((u, v) => u.ts - v.ts);
  return p;
}

// Estado de una señal en la vela k de la lista vs (null = sin dato). Para
// Fibonacci, con los niveles de la vela candidata `cand` (los dos lados se miden
// contra las mismas lineas).
function estado(f, x, m, vs, k, cand) {
  const v = vs[k];
  if (f === 'fib') { const n = x.fib[cand]; return n && n.length ? n.map(l => v.c > l.precio) : null; }
  if (f === 'ha') { // color con arrastre: el de la ultima vela que tuvo color
    for (let j = k; j >= 0; j--) { const d = Math.sign(vs[j].hc - vs[j].ho); if (d !== 0) return d; }
    return null;
  }
  const r = x.ind[m + '/' + v.ts];
  if (!r) throw new Error(`faltan los indicadores de ${m} ${v.ts}`);
  if (f === 'ema100') return r.e1 === null ? null : v.c > r.e1;
  if (f === 'ema200') return r.e2 === null ? null : v.c > r.e2;
  if (f === 'emas') return r.e1 === null || r.e2 === null ? null : r.e1 > r.e2;
  if (f === 'canal') return r.ru;
}

const miles = x => Math.round(x).toLocaleString('de-DE');
const pct = n => { const s = (Math.round(n * 1000) / 10).toFixed(1).replace(/\.0$/, ''); return s.replace('.', ',') + ' %'; };
const fecha = ts => { const d = new Date(ts * 1000).toISOString(); return d.slice(8, 10) + '/' + d.slice(5, 7); };
const nombre = id => (id.startsWith('BIP-') ? 'Perpetuo' : id === 'BTC-USD' ? 'Spot' : id);
const cab = (id, m, ts) => `${nombre(id)}, ${m === '1d' ? 'diaria' : 'semanal'} del ${fecha(ts)}: `;
const flecha = s => (s > 0 ? '📈 ' : '📉 ');

// Señales de la corriente, en el orden del awk: marco, ts, señal.
function senales(prods, orden, desde) {
  const out = [];
  for (const m of ['1d', '1w']) {
    const tss = new Set();
    for (const id of orden) for (const v of (prods[id] ? prods[id].velas[m] : [])) if (v.ts + DUR[m] > desde) tss.add(v.ts);
    for (const ts of [...tss].sort((a, b) => a - b)) {
      for (const f of FAMILIAS) {
        for (const id of orden) {
          const x = prods[id]; if (!x) continue;
          const vs = x.velas[m]; const k = vs.findIndex(v => v.ts === ts);
          if (k < 1) continue;
          let ant = estado(f, x, m, vs, k - 1, ts), hoy = estado(f, x, m, vs, k, ts);
          if (f === 'ha') { const d = Math.sign(vs[k].hc - vs[k].ho); hoy = d === 0 ? null : d; if (ant === null) continue; }
          else if (ant === null || hoy === null) continue;
          if (f === 'canal') { const r = x.ind[m + '/' + vs[k - 1].ts]; if (r.rc === null || r.rs === null || r.rp === null) continue; }
          // Este producto tiene el dato: decide el, haya señal o no.
          const e = cambio(f, x, m, vs, k, ant, hoy, id);
          if (e) out.push(e);
          break;
        }
      }
    }
  }
  return out;
}

function cambio(f, x, m, vs, k, ant, hoy, id) {
  const v = vs[k], u = vs[k - 1], r = x.ind[m + '/' + v.ts], ts = v.ts;
  const fila = (s, nivel, texto) => ({ marco: m, ts, tipo: f, producto: id, sentido: s, precio: v.c, nivel, texto });
  if (f === 'ema100' || f === 'ema200') {
    if (ant === hoy) return null;
    const s = hoy ? 1 : -1, e = f === 'ema100' ? r.e1 : r.e2;
    return fila(s, e, `${flecha(s)}${cab(id, m, ts)}cierra por ${s > 0 ? 'encima' : 'debajo'} de la EMA ${f.slice(3)}: cierre ${miles(v.c)}, EMA ${miles(e)}`);
  }
  if (f === 'emas') {
    if (ant === hoy) return null;
    const s = hoy ? 1 : -1;
    return fila(s, r.e2, `${flecha(s)}${cab(id, m, ts)}la EMA 100 cruza por ${s > 0 ? 'encima de la EMA 200 (cruce dorado)' : 'debajo de la EMA 200 (cruce de la muerte)'}: EMA 100 ${miles(r.e1)}, EMA 200 ${miles(r.e2)}`);
  }
  if (f === 'canal') {
    if (hoy === 0 || hoy === ant) return null;
    const p = x.ind[m + '/' + u.ts];
    const borde = p.rc + p.rp + hoy * (p.rs - p.rc);
    return fila(hoy, borde, `${flecha(hoy)}${cab(id, m, ts)}rompe el canal de regresión hacia ${hoy > 0 ? 'arriba' : 'abajo'}: cierre ${miles(v.c)}, borde ${hoy > 0 ? 'superior' : 'inferior'} ${miles(borde)}`);
  }
  if (f === 'fib') {
    const niveles = x.fib[ts];
    let cruzados = niveles.filter((n, j) => ant[j] !== hoy[j]);
    if (!cruzados.length) return null;
    const s = v.c > u.c ? 1 : -1;
    // En el orden en que los cruza el precio: bajando, de mas alto a mas bajo.
    cruzados = cruzados.sort((a, b) => (s < 0 ? b.precio - a.precio : a.precio - b.precio));
    const nom = n => (n.nivel === 0 ? `el máximo del ciclo (${miles(n.precio)})` : n.nivel === 1 ? `el mínimo del ciclo (${miles(n.precio)})` : `el ${pct(n.nivel)} (${miles(n.precio)})`);
    const lista = cruzados.map(nom).join(' y ');
    const verbo = s < 0 ? 'pierde' : cruzados.some(n => n.nivel === 0) ? 'supera' : 'recupera';
    const n0 = niveles[0];
    return fila(s, cruzados[0].precio, `📐 ${cab(id, m, ts)}${verbo} ${lista} de Fibonacci (ciclo ${miles(n0.bajo)} → ${miles(n0.alto)}); cierre ${miles(v.c)}`);
  }
  if (f === 'ha') {
    if (hoy === null || hoy === ant) return null;
    return fila(hoy, v.hc, `${hoy > 0 ? '🟢 ' : '🔴 '}${cab(id, m, ts)}la vela Heikin Ashi pasa a ${hoy > 0 ? 'verde' : 'roja'}`);
  }
  return null;
}

// Compara con la salida tsv del awk. Precio y nivel con error relativo 1e-9; lo
// demas, exacto (tambien el texto).
function compara(lineas, exp, max = 8) {
  const fallos = [];
  const got = lineas.filter(Boolean).map(l => { const a = l.split('\t'); return { marco: a[0], ts: +a[1], tipo: a[2], producto: a[3], sentido: +a[4], precio: +a[5], nivel: +a[6], texto: a[7] }; });
  if (got.length !== exp.length) fallos.push(`señales: el awk da ${got.length}, la referencia ${exp.length}`);
  const cerca = (a, b) => Math.abs(a - b) <= 1e-9 * Math.max(1, Math.abs(b));
  for (let i = 0; i < Math.min(got.length, exp.length) && fallos.length < max; i++) {
    const g = got[i], x = exp[i], id = `${x.marco}/${x.ts}/${x.tipo}`;
    for (const k of ['marco', 'ts', 'tipo', 'producto', 'sentido', 'texto']) if (g[k] !== x[k]) fallos.push(`${id} ${k}: [${g[k]}] != [${x[k]}]`);
    for (const k of ['precio', 'nivel']) if (!cerca(g[k], x[k])) fallos.push(`${id} ${k}: ${g[k]} != ${x[k]}`);
  }
  return fallos;
}

module.exports = { lee, senales, compara };

if (require.main === module) {
  const [fc, fs2, orden, desde] = process.argv.slice(2);
  const exp = senales(lee(fs.readFileSync(fc, 'utf8')), orden.split(' ').filter(Boolean), +desde);
  const f = compara(fs.readFileSync(fs2, 'utf8').split('\n'), exp);
  if (f.length) { console.log('NO COINCIDE: ' + f.join(' | ')); process.exit(1); }
  console.log(`coincide: ${exp.length} señales`);
}
