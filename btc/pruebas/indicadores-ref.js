// Calculo de referencia de los indicadores (indicadores-calculo.awk), escrito
// aparte y con OTRAS formulas a proposito: la EMA como e + a(y - e), la
// regresion con las ecuaciones normales sin centrar la x. Si los dos coinciden,
// el awk esta bien. Lo usan las pruebas (comprueba.js) y la comprobacion con
// datos reales (contra-coinbase.js).
'use strict';
const fs = require('fs');
const path = require('path');

// La version del calculo se lee del propio awk: una fila de otra version es un fallo.
const VERSION = +fs.readFileSync(path.join(__dirname, '..', 'indicadores-calculo.awk'), 'utf8').match(/VERSION = (\d+)/)[1];
const COLUMNAS = ['ema100', 'ema200', 'bb_media', 'bb_sup', 'bb_inf', 'rl_centro', 'rl_sup', 'rl_inf', 'rl_pendiente', 'rl_r', 'rl_ruptura'];

function ema(ys, L) {
  const a = 2 / (L + 1), out = [];
  let e = null;
  ys.forEach((y, i) => {
    if (i + 1 < L) { out.push(null); return; }
    if (i + 1 === L) { let s = 0; for (let j = 0; j < L; j++) s += ys[j]; e = s / L; }
    else e = e + a * (y - e);
    out.push(e);
  });
  return out;
}

function bollinger(w, k) { // poblacional: divide por n
  const n = w.length, m = w.reduce((s, v) => s + v, 0) / n;
  const sd = Math.sqrt(w.reduce((s, v) => s + (v - m) * (v - m), 0) / n);
  return { m, sup: m + k * sd, inf: m - k * sd };
}

function regresion(w) { // x = 0..n-1; recta y = corte + pend x
  const n = w.length;
  let sx = 0, sy = 0, sxx = 0, sxy = 0, syy = 0;
  w.forEach((y, x) => { sx += x; sy += y; sxx += x * x; sxy += x * y; syy += y * y; });
  const den = n * sxx - sx * sx, num = n * sxy - sx * sy;
  const pend = num / den, corte = (sy - pend * sx) / n;
  let sse = 0;
  w.forEach((y, x) => { const r = y - (corte + pend * x); sse += r * r; });
  const vy = n * syy - sy * sy;
  return { centro: corte + pend * (n - 1), pend, sd: Math.sqrt(sse / (n - 1)), r: vy > 0 ? num / Math.sqrt(den * vy) : 0 };
}

// velas: [{marco, ts, c, hc, cerrada}] (en cualquier orden). Devuelve una fila por
// vela y base, ordenadas por marco, base y ts (como ORDER BY en SQLite).
function indicadores(velas, o = {}) {
  const LA = o.ema_a || 100, LB = o.ema_b || 200, BN = o.bb_n || 20, BK = o.bb_k || 2, RN = o.rl_n || 100, RK = o.rl_k || 2;
  const out = [];
  for (const marco of ['1d', '1w']) {
    const vs = velas.filter(v => v.marco === marco).sort((a, b) => a.ts - b.ts);
    for (const base of ['ha', 'real']) {
      const ys = vs.map(v => base === 'real' ? v.c : v.hc);
      const ea = ema(ys, LA), eb = ema(ys, LB);
      const canal = ys.map((_, i) => i + 1 >= RN ? regresion(ys.slice(i + 1 - RN, i + 1)) : null);
      vs.forEach((v, i) => {
        const bb = i + 1 >= BN ? bollinger(ys.slice(i + 1 - BN, i + 1), BK) : null;
        const c = canal[i], p = i >= RN ? canal[i - 1] : null;
        let ru = null;
        if (p) { const centro = p.centro + p.pend, d = RK * p.sd; ru = ys[i] > centro + d ? 1 : ys[i] < centro - d ? -1 : 0; }
        out.push({
          marco, base, ts: v.ts, ema100: ea[i], ema200: eb[i],
          bb_media: bb ? bb.m : null, bb_sup: bb ? bb.sup : null, bb_inf: bb ? bb.inf : null,
          rl_centro: c ? c.centro : null, rl_sup: c ? c.centro + RK * c.sd : null, rl_inf: c ? c.centro - RK * c.sd : null,
          rl_pendiente: c ? c.pend : null, rl_r: c ? c.r : null, rl_ruptura: ru, cerrada: v.cerrada,
        });
      });
    }
  }
  return out;
}

// Compara filas guardadas con las de referencia (mismo orden). Precios con
// error relativo 1e-9; rl_r con 1e-9 absoluto; la ruptura y cerrada, exactas.
function compara(got, exp, max = 10) {
  const fallos = [];
  if (got.length !== exp.length) fallos.push(`indicadores: guardadas ${got.length}, esperadas ${exp.length}`);
  const n = Math.min(got.length, exp.length);
  for (let i = 0; i < n && fallos.length < max; i++) {
    const g = got[i], x = exp[i], id = `${x.marco}/${x.base}/${x.ts}`;
    if (g.marco !== x.marco || g.base !== x.base || g.ts !== x.ts) { fallos.push(`fila ${i}: ${g.marco}/${g.base}/${g.ts} en vez de ${id}`); continue; }
    for (const k of COLUMNAS) {
      const a = g[k], b = x[k];
      if (a === null || b === null) { if (a !== b) fallos.push(`${id} ${k}: ${a} != ${b}`); continue; }
      const tol = k === 'rl_ruptura' ? 0 : k === 'rl_r' ? 1e-9 : 1e-9 * Math.max(1, Math.abs(b));
      if (!(Math.abs(a - b) <= tol)) fallos.push(`${id} ${k}: ${a} != ${b}`);
    }
    if (g.cerrada !== x.cerrada) fallos.push(`${id} cerrada: ${g.cerrada} != ${x.cerrada}`);
    if (g.version !== VERSION) fallos.push(`${id} version: ${g.version} != ${VERSION}`);
  }
  return fallos;
}

const SQL = 'SELECT marco,base,ts,' + COLUMNAS.join(',') + ',cerrada,version FROM cripto_indicador WHERE producto=? ORDER BY marco,base,ts';
const deFila = a => { const o = { marco: a[0], base: a[1], ts: a[2] }; COLUMNAS.forEach((k, i) => { o[k] = a[3 + i]; }); o.cerrada = a[3 + COLUMNAS.length]; o.version = a[4 + COLUMNAS.length]; return o; };

module.exports = { VERSION, COLUMNAS, SQL, deFila, indicadores, compara, regresion, ema, bollinger };
