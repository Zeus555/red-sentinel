// Comprueba lo guardado en cripto_vela para un producto, en dos partes:
//
// 1. NUESTRO CALCULO (estricto): la semana de lunes y la Heikin Ashi diaria y
//    semanal se rehacen aqui desde las velas diarias guardadas y tienen que dar
//    exactamente lo mismo que lo guardado. Los indicadores (cripto_indicador)
//    se rehacen con indicadores-ref.js desde las velas guardadas y tambien
//    tienen que coincidir todos. Y los niveles de Fibonacci (cripto_fibonacci),
//    con fibonacci-ref.js.
//
// 2. LOS DATOS DE COINBASE, contra fuentes que el script NO usa:
//    - BTC-USD (spot): la API Exchange (api.exchange.coinbase.com,
//      granularity=86400). Estricto: tiene que coincidir dia a dia.
//    - Otros (el perpetuo de futuros, que no esta en Exchange): la vela diaria
//      armada juntando las 24 velas ONE_HOUR de Advanced Trade. Informativo: el
//      historico de futuros de Coinbase tiene incoherencias PROPIAS entre
//      granularidades (comprobado el 12/11/2026: el 10/03/2026 la diaria dice
//      maximo 71.790 y las de 1 h, 15 min y 5 min 71.845; el 17/09/2025 es la
//      horaria la que da otra apertura; el volumen difiere entre todas). Solo
//      falla si faltan dias o si las distintas pasan del 2 %.
//    - Semanales contra ONE_WEEK (no documentada): siempre informativo; tiene
//      fallos propios (spot: la semana del 02/04/2018 cierra en 5.200).
//    Siempre desde el primer dia del producto aunque la tabla empiece despues:
//    asi se ve una historia recortada.
//
// Solo lee (endpoints publicos, ≤ 1 peticion por segundo). Sale con 0 si todo
// lo estricto cuadra; con 1 si no.
// Uso: node contra-coinbase.js <url-rqlite> <fichero curlrc> [producto]   (BTC-USD por defecto)
'use strict';
const fs = require('fs');
const IR = require('./indicadores-ref');
const FR = require('./fibonacci-ref');
const [rq, curlrc, producto = 'BTC-USD'] = process.argv.slice(2);
const cred = fs.readFileSync(curlrc, 'utf8').match(/user\s*=\s*"([^"]+)"/)[1];
const H = { 'User-Agent': 'sentinel-btc-velas/1.0' };
const DIA = 86400;
const SPOT = producto === 'BTC-USD';
// Primer dia de cada producto en Coinbase.
const INICIO_CB = { 'BTC-USD': 1437350400, 'BIP-20DEC30-CDE': 1752796800 }[producto];
const ADV = 'https://api.coinbase.com/api/v3/brokerage/market/products/' + producto + '/candles';
const FUENTE = SPOT ? 'la API Exchange' : 'las velas horarias juntadas';
const espera = ms => new Promise(r => setTimeout(r, ms));
const f = t => new Date(t * 1000).toISOString().slice(0, 10);
const lunes = t => t - ((new Date(t * 1000).getUTCDay() + 6) % 7) * DIA;

async function filas(marco) {
  const r = await fetch(rq + '/db/query?level=strong', { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Basic ' + Buffer.from(cred).toString('base64') },
    body: JSON.stringify([['SELECT ts,apertura,maximo,minimo,cierre,volumen,cerrada,dias,ha_apertura,ha_maximo,ha_minimo,ha_cierre FROM cripto_vela WHERE producto=? AND marco=? ORDER BY ts', producto, marco]]) });
  const j = await r.json();
  return new Map((j.results[0].values || []).map(a => [a[0], { t: a[0], o: a[1], h: a[2], l: a[3], c: a[4], v: a[5], cerrada: a[6], dias: a[7], ho: a[8], hh: a[9], hl: a[10], hc: a[11] }]));
}
function heikin(velas) { // velas en orden -> Map ts -> {ho,hh,hl,hc}
  const out = new Map(); let ao, ac;
  velas.forEach((v, i) => {
    const hc = (v.o + v.h + v.l + v.c) / 4, ho = i === 0 ? (v.o + v.c) / 2 : (ao + ac) / 2;
    out.set(v.t, { ho, hh: Math.max(v.h, ho, hc), hl: Math.min(v.l, ho, hc), hc }); ao = ho; ac = hc;
  });
  return out;
}
function semanas(diarias) { // diarias en orden -> semanas de lunes en orden
  const m = new Map();
  for (const v of diarias) {
    const w = lunes(v.t);
    if (!m.has(w)) m.set(w, { t: w, o: v.o, h: v.h, l: v.l, c: v.c, v: 0, n: 0 });
    const s = m.get(w); s.h = Math.max(s.h, v.h); s.l = Math.min(s.l, v.l); s.c = v.c; s.v += v.v; s.n++;
  }
  return [...m.values()].sort((a, b) => a.t - b.t);
}
const igualOHLC = (a, b) => ['o', 'h', 'l', 'c'].every(k => Math.abs(a[k] - b[k]) < 0.005);

(async () => {
  const d = await filas('1d'), w = await filas('1w');
  const ahora = Math.floor(Date.now() / 1000);
  let fallo = 0;
  if (!d.size) { console.log('la tabla no tiene velas diarias de ' + producto); process.exit(1); }
  console.log(`${producto}: ${d.size} diarias y ${w.size} semanales guardadas`);

  // ---- 1. Nuestro calculo, desde lo guardado ----
  const dOrden = [...d.values()].sort((a, b) => a.t - b.t);
  const sem = semanas(dOrden);
  let wMal = 0; const wEj = [];
  if (sem.length !== w.size) { wMal++; wEj.push(`hay ${w.size} semanas guardadas y salen ${sem.length}`); }
  for (const s of sem) {
    const x = w.get(s.t);
    if (!x || !igualOHLC(x, s) || x.dias !== s.n || Math.abs(x.v - s.v) > 1e-6) { wMal++; if (wEj.length < 5) wEj.push(`${f(s.t)} guardada ${x ? `${x.o}/${x.h}/${x.l}/${x.c} dias ${x.dias}` : 'NO'} esperada ${s.o}/${s.h}/${s.l}/${s.c} dias ${s.n}`); }
  }
  const haD = heikin(dOrden), haW = heikin(sem);
  let haMal = 0, haVistas = 0; const haEj = [];
  for (const [mapa, ref, marco] of [[d, haD, '1d'], [w, haW, '1w']])
    for (const [t, x] of mapa) {
      const e = ref.get(t); if (!e) continue; haVistas++;
      if (['ho', 'hh', 'hl', 'hc'].some(k => Math.abs(x[k] - e[k]) > 1e-6)) { haMal++; if (haEj.length < 5) haEj.push(`${marco} ${f(t)} guardada ${x.ho}/${x.hc} esperada ${e.ho}/${e.hc}`); }
    }
  console.log(`calculo: ${sem.length - wMal} de ${sem.length} semanas y ${haVistas - haMal} de ${haVistas} Heikin Ashi iguales a las rehechas desde las diarias guardadas`);
  wEj.concat(haEj).forEach(s => console.log('  distinta: ' + s));
  if (wMal || haMal || !haVistas) fallo = 1;

  // Indicadores, rehechos desde las velas guardadas.
  const ri = await fetch(rq + '/db/query?level=strong', { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Basic ' + Buffer.from(cred).toString('base64') }, body: JSON.stringify([[IR.SQL, producto]]) });
  const ji = (await ri.json()).results[0];
  if (ji.error) { console.log('indicadores: ' + ji.error); fallo = 1; } else {
    const iGot = (ji.values || []).map(IR.deFila);
    const vs = [];
    for (const [mapa, marco] of [[d, '1d'], [w, '1w']]) for (const x of mapa.values()) vs.push({ marco, ts: x.t, c: x.c, hc: x.hc, cerrada: x.cerrada });
    const iExp = IR.indicadores(vs);
    const iMal = IR.compara(iGot, iExp, 5);
    const ultima = iExp.filter(x => x.marco === '1d' && x.base === 'real' && x.cerrada).pop();
    console.log(`indicadores: ${iGot.length} guardados, ${iExp.length} rehechos desde las velas guardadas, ${iMal.length ? 'NO coinciden' : 'todos iguales'}`);
    iMal.forEach(s => console.log('  distinto: ' + s));
    if (ultima) console.log(`  ultima diaria cerrada (${f(ultima.ts)}, real): EMA100 ${ultima.ema100?.toFixed(2)}, EMA200 ${ultima.ema200?.toFixed(2)}, Bollinger ${ultima.bb_inf?.toFixed(2)}-${ultima.bb_sup?.toFixed(2)}, canal ${ultima.rl_inf?.toFixed(2)}-${ultima.rl_sup?.toFixed(2)} (pendiente ${ultima.rl_pendiente?.toFixed(2)}/dia), ruptura ${ultima.rl_ruptura}`);
    if (iMal.length || !iGot.length) fallo = 1;
  }

  // Fibonacci, rehecho desde las velas diarias guardadas.
  const rf = await fetch(rq + '/db/query?level=strong', { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Basic ' + Buffer.from(cred).toString('base64') }, body: JSON.stringify([[FR.SQL, producto]]) });
  const jf = (await rf.json()).results[0];
  if (jf.error) { console.log('fibonacci: ' + jf.error); fallo = 1; } else {
    const fGot = (jf.values || []).map(FR.deFila);
    const fExp = FR.fibonacci([...d.values()].map(x => ({ marco: '1d', ts: x.t, h: x.h, l: x.l, c: x.c })));
    const fMal = FR.compara(fGot, fExp, 5);
    if (fGot.some(g => g.tramo !== 'ciclo')) fMal.push('hay filas de un tramo que no es ciclo');
    console.log(`fibonacci: ${fGot.length} niveles guardados, ${fExp ? `ciclo ${fExp.bajo} (${f(fExp.bajo_ts)}) -> ${fExp.alto} (${f(fExp.alto_ts)}), caida ${(100 * fExp.caida).toFixed(1)} %` : 'sin ciclo'} rehecho desde las velas guardadas, ${fMal.length ? 'NO coinciden' : 'todo igual'}`);
    fMal.forEach(s => console.log('  distinto: ' + s));
    if (fExp) {
      const hoy = [...d.values()].pop();
      console.log('  niveles: ' + fExp.niveles.map(n => `${(100 * n.nivel).toFixed(1)} % ${n.precio.toFixed(2)}`).join(', ') + `; ultimo cierre ${hoy.c} (${f(hoy.t)}) en el ${(100 * (fExp.alto - hoy.c) / (fExp.alto - fExp.bajo)).toFixed(1)} %`);
    }
    if (fMal.length) fallo = 1;
  }

  // ---- 2. Datos de Coinbase contra otra fuente ----
  const ref = new Map();
  const primera = Math.min(INICIO_CB || Infinity, ...d.keys());
  if (SPOT) {
    // API Exchange: [time, low, high, open, close, volume], hasta 300 por peticion.
    for (let ini = primera; ini < ahora; ini += 300 * DIA) {
      const fin = Math.min(ini + 299 * DIA, ahora);
      const r = await fetch(`https://api.exchange.coinbase.com/products/BTC-USD/candles?granularity=86400&start=${new Date(ini * 1000).toISOString()}&end=${new Date(fin * 1000).toISOString()}`, { headers: H });
      if (r.status !== 200) throw new Error('Exchange http ' + r.status);
      for (const a of await r.json()) ref.set(a[0], { t: a[0], l: a[1], h: a[2], o: a[3], c: a[4], v: a[5] });
      await espera(1100);
    }
  } else {
    // Velas de una hora (hasta 350 por peticion; se piden 300) juntadas por dia UTC.
    const horas = new Map();
    for (let ini = primera; ini < ahora; ini += 300 * 3600) {
      const fin = Math.min(ini + 300 * 3600, ahora);
      const r = await fetch(`${ADV}?granularity=ONE_HOUR&start=${ini}&end=${fin}`, { headers: H });
      if (r.status !== 200) throw new Error('ONE_HOUR http ' + r.status);
      for (const c of (await r.json()).candles || []) horas.set(+c.start, { t: +c.start, o: +c.open, h: +c.high, l: +c.low, c: +c.close, v: +c.volume });
      await espera(1100);
    }
    for (const x of [...horas.values()].sort((a, b) => a.t - b.t)) {
      const t = Math.floor(x.t / DIA) * DIA;
      if (!ref.has(t)) ref.set(t, { t, o: x.o, h: x.h, l: x.l, c: x.c, v: 0 });
      const e = ref.get(t); e.h = Math.max(e.h, x.h); e.l = Math.min(e.l, x.l); e.c = x.c; e.v += x.v;
    }
  }
  const refOrden = [...ref.values()].sort((a, b) => a.t - b.t);
  console.log(`primera vela: nuestra ${f(dOrden[0].t)}, en ${FUENTE} ${f(refOrden[0].t)}`);
  let dOk = 0, dMalN = 0, soloNuestra = 0, soloRef = 0, volMax = 0; const dEj = [];
  for (const x of dOrden) {
    if (!x.cerrada) continue;
    const e = ref.get(x.t);
    if (!e) { soloNuestra++; continue; }
    if (igualOHLC(x, e)) dOk++; else { dMalN++; if (dEj.length < 5) dEj.push(`${f(x.t)} nuestra ${x.o}/${x.h}/${x.l}/${x.c} referencia ${e.o}/${e.h}/${e.l}/${e.c}`); }
    if (e.v > 0) volMax = Math.max(volMax, Math.abs(x.v - e.v) / e.v);
  }
  for (const t of ref.keys()) if (t + DIA <= ahora && !d.has(t)) soloRef++;
  const cerradas = dOk + dMalN;
  console.log(`diarias cerradas: ${dOk} iguales a ${FUENTE}; ${dMalN} distintas${SPOT ? '' : ' (incoherencias de Coinbase; informativo)'}; ${soloNuestra} solo nuestras; ${soloRef} solo en la referencia; volumen difiere hasta ${(volMax * 100).toFixed(4)} %`);
  dEj.forEach(s => console.log('  distinta: ' + s));
  if (soloNuestra || soloRef) fallo = 1;
  if (SPOT ? dMalN > 0 : dMalN > 0.02 * cerradas) fallo = 1;

  // Semanales contra ONE_WEEK (informativo).
  const ow = new Map();
  for (let ini = Math.min(...w.keys()); ini < ahora; ini += 300 * 7 * DIA) {
    const fin = Math.min(ini + 300 * 7 * DIA, ahora);
    const r = await fetch(`${ADV}?granularity=ONE_WEEK&start=${ini}&end=${fin}`, { headers: H });
    if (r.status !== 200) { console.log('ONE_WEEK no disponible: http ' + r.status); break; }
    for (const c of (await r.json()).candles || []) ow.set(+c.start, { o: +c.open, h: +c.high, l: +c.low, c: +c.close });
    await espera(1100);
  }
  let wOk = 0, wDis = 0, wFalta = 0; const owEj = [];
  for (const [t, x] of w) {
    if (!x.cerrada) continue;
    const e = ow.get(t);
    if (!e) { wFalta++; continue; }
    if (igualOHLC(x, e)) wOk++; else { wDis++; if (owEj.length < 5) owEj.push(`${f(t)} nuestra ${x.o}/${x.h}/${x.l}/${x.c} ONE_WEEK ${e.o}/${e.h}/${e.l}/${e.c}`); }
  }
  const incompletas = [...w.values()].filter(x => x.cerrada && x.dias !== 7).map(x => `${f(x.t)} (${x.dias} dias)`);
  console.log(`semanales cerradas: ${wOk} iguales a ONE_WEEK; ${wDis} distintas (informativo); ${wFalta} sin ONE_WEEK`);
  owEj.forEach(s => console.log('  distinta: ' + s));
  console.log('semanas cerradas con menos de 7 dias: ' + (incompletas.length ? incompletas.join(', ') : 'ninguna'));
  console.log(fallo ? 'RESULTADO: NO cuadra' : 'RESULTADO: cuadra');
  process.exit(fallo);
})().catch(e => { console.log('ERROR ' + e.message); process.exit(2); });
