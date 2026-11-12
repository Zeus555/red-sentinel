// Compara las velas guardadas en cripto_vela (BTC-USD) con fuentes de Coinbase
// que el script NO usa:
//   - diarias: la API Exchange (api.exchange.coinbase.com, granularity=86400),
//     desde el 20/07/2015 aunque la tabla empiece despues (asi se ve una historia
//     recortada);
//   - Heikin Ashi diaria y semanal: recalculada aqui desde las velas de Exchange;
//   - semanales: ONE_WEEK de Advanced Trade (no documentada). Tiene fallos propios
//     conocidos (p. ej. la semana del 02/04/2018 cierra en 5.200), asi que sus
//     diferencias se informan pero no hacen fallar la comprobacion.
// Solo lee (endpoints publicos, ≤ 1 peticion por segundo).
// Sale con 0 si las diarias y la Heikin Ashi cuadran; con 1 si no.
// Uso: node contra-coinbase.js <url-rqlite> <fichero curlrc>
'use strict';
const fs = require('fs');
const [rq, curlrc] = process.argv.slice(2);
const cred = fs.readFileSync(curlrc, 'utf8').match(/user\s*=\s*"([^"]+)"/)[1];
const H = { 'User-Agent': 'sentinel-btc-velas/1.0' };
const DIA = 86400;
const INICIO_CB = 1437350400; // 20/07/2015, primera vela diaria de BTC-USD
const espera = ms => new Promise(r => setTimeout(r, ms));
const f = t => new Date(t * 1000).toISOString().slice(0, 10);

async function filas(marco) {
  const r = await fetch(rq + '/db/query?level=strong', { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Basic ' + Buffer.from(cred).toString('base64') },
    body: JSON.stringify([['SELECT ts,apertura,maximo,minimo,cierre,volumen,cerrada,dias,ha_apertura,ha_maximo,ha_minimo,ha_cierre FROM cripto_vela WHERE producto=? AND marco=? ORDER BY ts', 'BTC-USD', marco]]) });
  const j = await r.json();
  return new Map((j.results[0].values || []).map(a => [a[0], { o: a[1], h: a[2], l: a[3], c: a[4], v: a[5], cerrada: a[6], dias: a[7], ho: a[8], hh: a[9], hl: a[10], hc: a[11] }]));
}
function heikin(velas) { // velas en orden -> Map ts -> {ho,hh,hl,hc}
  const out = new Map(); let ao, ac;
  velas.forEach((v, i) => {
    const hc = (v.o + v.h + v.l + v.c) / 4, ho = i === 0 ? (v.o + v.c) / 2 : (ao + ac) / 2;
    out.set(v.t, { ho, hh: Math.max(v.h, ho, hc), hl: Math.min(v.l, ho, hc), hc }); ao = ho; ac = hc;
  });
  return out;
}

(async () => {
  const d = await filas('1d'), w = await filas('1w');
  const ahora = Math.floor(Date.now() / 1000);
  let fallo = 0;
  if (!d.size) { console.log('la tabla no tiene velas diarias de BTC-USD'); process.exit(1); }

  // Diarias contra la API Exchange: [time, low, high, open, close, volume], hasta 300 por peticion.
  const ex = new Map();
  const primera = Math.min(INICIO_CB, ...d.keys());
  for (let ini = primera; ini < ahora; ini += 300 * DIA) {
    const fin = Math.min(ini + 299 * DIA, ahora);
    const r = await fetch(`https://api.exchange.coinbase.com/products/BTC-USD/candles?granularity=86400&start=${new Date(ini * 1000).toISOString()}&end=${new Date(fin * 1000).toISOString()}`, { headers: H });
    if (r.status !== 200) throw new Error('Exchange http ' + r.status);
    for (const a of await r.json()) ex.set(a[0], { t: a[0], l: a[1], h: a[2], o: a[3], c: a[4], v: a[5] });
    await espera(1100);
  }
  const exOrden = [...ex.values()].sort((a, b) => a.t - b.t);
  console.log(`primera vela: nuestra ${f(Math.min(...d.keys()))}, Exchange ${f(exOrden[0].t)}`);
  let dOk = 0, dMalN = 0, dMal = [], soloNuestra = 0, soloEx = 0, volMax = 0;
  for (const [t, x] of d) {
    if (!x.cerrada) continue;
    const e = ex.get(t);
    if (!e) { soloNuestra++; continue; }
    if (['o', 'h', 'l', 'c'].every(k => Math.abs(x[k] - e[k]) < 0.005)) dOk++;
    else { dMalN++; if (dMal.length < 5) dMal.push(`${f(t)} nuestra ${x.o}/${x.h}/${x.l}/${x.c} Exchange ${e.o}/${e.h}/${e.l}/${e.c}`); }
    if (e.v > 0) volMax = Math.max(volMax, Math.abs(x.v - e.v) / e.v);
  }
  for (const t of ex.keys()) if (t + DIA <= ahora && !d.has(t)) soloEx++;
  console.log(`diarias cerradas: ${dOk} iguales a la API Exchange; ${dMalN} distintas; ${soloNuestra} solo nuestras; ${soloEx} solo en Exchange; volumen difiere hasta ${(volMax * 100).toFixed(4)} %`);
  dMal.forEach(s => console.log('  distinta: ' + s));
  if (dMalN || soloNuestra || soloEx) fallo = 1;

  // Heikin Ashi recalculada desde Exchange (diaria y semanal de lunes).
  const haD = heikin(exOrden);
  const semanas = new Map();
  for (const v of exOrden) {
    const wts = v.t - ((new Date(v.t * 1000).getUTCDay() + 6) % 7) * DIA;
    if (!semanas.has(wts)) semanas.set(wts, { t: wts, o: v.o, h: v.h, l: v.l, c: v.c });
    const s = semanas.get(wts); s.h = Math.max(s.h, v.h); s.l = Math.min(s.l, v.l); s.c = v.c;
  }
  const haW = heikin([...semanas.values()].sort((a, b) => a.t - b.t));
  let haMal = 0, haVistas = 0; const haEj = [];
  for (const [mapa, ref, marco] of [[d, haD, '1d'], [w, haW, '1w']])
    for (const [t, x] of mapa) {
      if (!x.cerrada) continue;
      const e = ref.get(t); if (!e) continue; haVistas++;
      if (['ho', 'hh', 'hl', 'hc'].some(k => Math.abs(x[k] - e[k]) > 1e-6)) { haMal++; if (haEj.length < 5) haEj.push(`${marco} ${f(t)} nuestra ${x.ho}/${x.hc} esperada ${e.ho}/${e.hc}`); }
    }
  console.log(`Heikin Ashi cerradas: ${haVistas - haMal} de ${haVistas} iguales a la recalculada desde Exchange`);
  haEj.forEach(s => console.log('  distinta: ' + s));
  if (haMal || !haVistas) fallo = 1;

  // Semanales contra ONE_WEEK (informativo).
  const ow = new Map();
  const pw = Math.min(...w.keys());
  for (let ini = pw; ini < ahora; ini += 300 * 7 * DIA) {
    const fin = Math.min(ini + 300 * 7 * DIA, ahora);
    const r = await fetch(`https://api.coinbase.com/api/v3/brokerage/market/products/BTC-USD/candles?granularity=ONE_WEEK&start=${ini}&end=${fin}`, { headers: H });
    if (r.status !== 200) { console.log('ONE_WEEK no disponible: http ' + r.status); break; }
    for (const c of (await r.json()).candles || []) ow.set(+c.start, { o: +c.open, h: +c.high, l: +c.low, c: +c.close, v: +c.volume });
    await espera(1100);
  }
  let wOk = 0, wMalN = 0, wMal = [], wFalta = 0;
  for (const [t, x] of w) {
    if (!x.cerrada) continue;
    const e = ow.get(t);
    if (!e) { wFalta++; continue; }
    if (['o', 'h', 'l', 'c'].every(k => Math.abs(x[k] - e[k]) < 0.005)) wOk++;
    else { wMalN++; if (wMal.length < 5) wMal.push(`${f(t)} nuestra ${x.o}/${x.h}/${x.l}/${x.c} ONE_WEEK ${e.o}/${e.h}/${e.l}/${e.c}`); }
  }
  const incompletas = [...w.entries()].filter(([, x]) => x.cerrada && x.dias !== 7).map(([t, x]) => `${f(t)} (${x.dias} dias)`);
  console.log(`semanales cerradas: ${wOk} iguales a ONE_WEEK; ${wMalN} distintas (informativo); ${wFalta} sin ONE_WEEK`);
  wMal.forEach(s => console.log('  distinta: ' + s));
  console.log('semanas cerradas con menos de 7 dias: ' + (incompletas.length ? incompletas.join(', ') : 'ninguna'));
  console.log(fallo ? 'RESULTADO: NO cuadra' : 'RESULTADO: cuadra');
  process.exit(fallo);
})().catch(e => { console.log('ERROR ' + e.message); process.exit(2); });
