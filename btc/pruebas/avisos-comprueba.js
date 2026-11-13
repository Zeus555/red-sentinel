// Compara las señales guardadas en cripto_aviso con las que salen de los calculos
// de REFERENCIA (serie-falsa.js -> indicadores-ref.js y fibonacci-ref.js ->
// avisos-ref.js), sin pasar por ningun awk. Mira solo las velas que la pasada de
// `ahora` tiene por candidatas: las cerradas en los ultimos 7 dias.
// Uso: node avisos-comprueba.js <url-rqlite> <usuario:clave> <fichero-estado> "<orden>"
// Sale con 0 y "coincide: N señales" si coinciden fila a fila.
'use strict';
const { leeEstado, velas, esperadas } = require('./serie-falsa');
const IR = require('./indicadores-ref');
const FR = require('./fibonacci-ref');
const AR = require('./avisos-ref');

const [rq, cred, festado, ordenTxt] = process.argv.slice(2);
const e = leeEstado(festado);
const orden = ordenTxt.split(' ').filter(Boolean);
const DUR = { '1d': 86400, '1w': 604800 };

// La misma estructura que AR.lee() saca de la corriente, pero desde la referencia.
function producto(id, desde) {
  const filas = esperadas(velas(e, id), e.ahora);
  const x = { velas: { '1d': [], '1w': [] }, ind: {}, fib: {} };
  for (const f of filas) if (f.cerrada === 1) x.velas[f.marco].push({ ts: f.ts, c: f.c, ho: f.ho, hc: f.hc });
  for (const r of IR.indicadores(filas.map(f => ({ marco: f.marco, ts: f.ts, c: f.c, hc: f.hc, cerrada: f.cerrada }))))
    if (r.base === 'real') x.ind[r.marco + '/' + r.ts] = { e1: r.ema100, e2: r.ema200, rc: r.rl_centro, rs: r.rl_sup, rp: r.rl_pendiente, ru: r.rl_ruptura };
  // Fibonacci de cada vela candidata: con las diarias cerradas anteriores a ella.
  const diarias = filas.filter(f => f.marco === '1d' && f.cerrada === 1);
  for (const f of filas) {
    if (f.cerrada !== 1 || f.ts + DUR[f.marco] <= desde) continue;
    const fib = FR.fibonacci(diarias.filter(d => d.ts < f.ts).map(d => ({ marco: '1d', ts: d.ts, h: d.h, l: d.l, c: d.c })));
    if (fib) x.fib[f.ts] = fib.niveles.map(n => ({ nivel: n.nivel, precio: n.precio, bajo: fib.bajo, alto: fib.alto }));
  }
  return x;
}

(async () => {
  const desde = e.ahora - 7 * 86400;
  const prods = {};
  for (const id of orden) prods[id] = producto(id, desde);
  const exp = AR.senales(prods, orden, desde);
  const q = [['SELECT marco,ts,tipo,producto,sentido,precio,nivel,texto FROM cripto_aviso ORDER BY marco,ts,tipo']];
  const r = await fetch(rq + '/db/query?level=strong', { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Basic ' + Buffer.from(cred).toString('base64') }, body: JSON.stringify(q) });
  const j = await r.json();
  if (j.results[0].error) { console.log('ERROR cripto_aviso: ' + j.results[0].error); process.exit(2); }
  const lineas = (j.results[0].values || []).filter(a => a[1] + DUR[a[0]] > desde).map(a => a.join('\t'));
  const fallos = AR.compara(lineas, exp, 10);
  if (fallos.length) { console.log('NO COINCIDE: ' + fallos.join(' | ')); process.exit(1); }
  console.log(`coincide: ${exp.length} señales`);
})().catch(err => { console.log('ERROR ' + err.message); process.exit(2); });
