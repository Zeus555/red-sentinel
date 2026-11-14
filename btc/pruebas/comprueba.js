// Compara TODO lo que hay en cripto_vela, cripto_indicador y cripto_fibonacci
// (un producto, BTC-USD por defecto) con los calculos de referencia de
// serie-falsa.js, indicadores-ref.js y fibonacci-ref.js. Sale con 0 si coincide fila a fila.
// Uso: node comprueba.js <url-rqlite> <usuario:clave> <fichero-estado> [producto]
'use strict';
const { leeEstado, esperadasDe } = require('./serie-falsa');
const IR = require('./indicadores-ref');
const FR = require('./fibonacci-ref');

const [rq, cred, festado, producto = 'BTC-USD'] = process.argv.slice(2);
const e = leeEstado(festado);

(async () => {
  const q = [['SELECT marco,ts,apertura,maximo,minimo,cierre,volumen,ha_apertura,ha_maximo,ha_minimo,ha_cierre,cerrada,dias FROM cripto_vela WHERE producto=? ORDER BY marco,ts', producto], [IR.SQL, producto], [FR.SQL, producto]];
  const r = await fetch(rq + '/db/query?level=strong', { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Basic ' + Buffer.from(cred).toString('base64') }, body: JSON.stringify(q) });
  const j = await r.json();
  const got = (j.results[0].values || []).map(a => ({ marco: a[0], ts: a[1], o: a[2], h: a[3], l: a[4], c: a[5], v: a[6], ho: a[7], hh: a[8], hl: a[9], hc: a[10], cerrada: a[11], dias: a[12] }));
  const exp = esperadasDe(e, producto).sort((a, b) => a.marco < b.marco ? -1 : a.marco > b.marco ? 1 : a.ts - b.ts);
  const fallos = [];
  if (got.length !== exp.length) fallos.push(`filas: rqlite ${got.length}, esperadas ${exp.length}`);
  const n = Math.min(got.length, exp.length);
  for (let i = 0; i < n && fallos.length < 10; i++) {
    const g = got[i], x = exp[i];
    if (g.marco !== x.marco || g.ts !== x.ts) { fallos.push(`fila ${i}: ${g.marco}/${g.ts} en vez de ${x.marco}/${x.ts}`); continue; }
    // Lo que es copia de Coinbase tiene que ser EXACTO; lo calculado (HA y el
    // volumen semanal, que es una suma) admite 1e-6 absoluto.
    const exacto = k => ['o', 'h', 'l', 'c'].includes(k) || (k === 'v' && x.marco === '1d');
    for (const k of ['o', 'h', 'l', 'c', 'v', 'ho', 'hh', 'hl', 'hc'])
      if (exacto(k) ? g[k] !== x[k] : Math.abs(g[k] - x[k]) > 1e-6) fallos.push(`${x.marco} ${x.ts} ${k}: ${g[k]} != ${x[k]}`);
    if (g.cerrada !== x.cerrada) fallos.push(`${x.marco} ${x.ts} cerrada: ${g.cerrada} != ${x.cerrada}`);
    if (g.dias !== x.dias) fallos.push(`${x.marco} ${x.ts} dias: ${g.dias} != ${x.dias}`);
  }
  // Indicadores: sobre las velas de REFERENCIA, no sobre las guardadas.
  const iExp = IR.indicadores(exp.map(x => ({ marco: x.marco, ts: x.ts, c: x.c, hc: x.hc, cerrada: x.cerrada })));
  const iGot = (j.results[1].error ? [] : (j.results[1].values || [])).map(IR.deFila);
  if (j.results[1].error) fallos.push('cripto_indicador: ' + j.results[1].error);
  fallos.push(...IR.compara(iGot, iExp, 10));
  // Fibonacci: tambien sobre las velas de referencia.
  const fExp = FR.fibonacci(exp.map(x => ({ marco: x.marco, ts: x.ts, h: x.h, l: x.l, c: x.c })));
  const fGot = (j.results[2].error ? [] : (j.results[2].values || [])).map(FR.deFila);
  if (j.results[2].error) fallos.push('cripto_fibonacci: ' + j.results[2].error);
  if (fGot.some(g => g.tramo !== 'ciclo')) fallos.push('cripto_fibonacci: hay filas de un tramo que no es ciclo');
  fallos.push(...FR.compara(fGot, fExp, 10));
  const d = exp.filter(x => x.marco === '1d').length, w = exp.length - d;
  if (fallos.length) { console.log('NO COINCIDE (' + fallos.length + '):\n  ' + fallos.join('\n  ')); process.exit(1); }
  console.log(`coincide: ${d} diarias y ${w} semanales, y ${iExp.length} filas de indicadores, ${fExp ? fExp.niveles.length + ' niveles de Fibonacci' : 'sin ciclo de Fibonacci'}`);
})().catch(err => { console.log('ERROR ' + err.message); process.exit(2); });
