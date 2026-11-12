// Compara TODO lo que hay en cripto_vela (producto BTC-USD) con el calculo de
// referencia de serie-falsa.js. Sale con 0 si coincide fila a fila.
// Uso: node comprueba.js <url-rqlite> <usuario:clave> <fichero-estado>
'use strict';
const { leeEstado, velas, esperadas } = require('./serie-falsa');

const [rq, cred, festado] = process.argv.slice(2);
const e = leeEstado(festado);

(async () => {
  const q = [['SELECT marco,ts,apertura,maximo,minimo,cierre,volumen,ha_apertura,ha_maximo,ha_minimo,ha_cierre,cerrada,dias FROM cripto_vela WHERE producto=? ORDER BY marco,ts', 'BTC-USD']];
  const r = await fetch(rq + '/db/query?level=strong', { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Basic ' + Buffer.from(cred).toString('base64') }, body: JSON.stringify(q) });
  const j = await r.json();
  const got = (j.results[0].values || []).map(a => ({ marco: a[0], ts: a[1], o: a[2], h: a[3], l: a[4], c: a[5], v: a[6], ho: a[7], hh: a[8], hl: a[9], hc: a[10], cerrada: a[11], dias: a[12] }));
  const exp = esperadas(velas(e), e.ahora).sort((a, b) => a.marco < b.marco ? -1 : a.marco > b.marco ? 1 : a.ts - b.ts);
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
  const d = exp.filter(x => x.marco === '1d').length, w = exp.length - d;
  if (fallos.length) { console.log('NO COINCIDE (' + fallos.length + '):\n  ' + fallos.join('\n  ')); process.exit(1); }
  console.log(`coincide: ${d} diarias y ${w} semanales`);
})().catch(err => { console.log('ERROR ' + err.message); process.exit(2); });
