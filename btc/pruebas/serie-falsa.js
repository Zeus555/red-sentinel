// Serie diaria falsa y determinista para las pruebas, y el calculo de
// referencia (Heikin Ashi diaria, semana de lunes y Heikin Ashi semanal) escrito
// aparte del awk a proposito: si los dos coinciden, el awk esta bien.
'use strict';
const fs = require('fs');

const DIA = 86400;
const INICIO = 1672617600; // 2023-01-02, lunes

function lcg(seed) { let s = seed >>> 0; return () => { s = (Math.imul(s, 1664525) + 1013904223) >>> 0; return s / 4294967296; }; }
const r2 = x => Math.round(x * 100) / 100;

// estado: { ahora, quitar: [ts], cambiar: { ts: {o,h,l,c,v} }, cambiarEn: { producto: { ts: {...} } },
//           fallo500, fallaProducto, invalida, vacio, ventanaVacia, tgFalla }
// quitar y cambiar solo se aplican a BTC-USD; cambiarEn, al producto que diga.
function leeEstado(f) { try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch { return {}; } }

// Productos que sirve el Coinbase falso. El perpetuo imita al de verdad
// (BIP-20DEC30-CDE): precios en saltos de $5 y volumen en contratos enteros.
const PRODUCTOS = {
  'BTC-USD': { inicio: INICIO, semilla: 12345, p0: 95000, tick: 0.01, vol: 1e8 },
  'BIP-20DEC30-CDE': { inicio: 1752796800, semilla: 777, p0: 118000, tick: 5, vol: 1 }, // 18/07/2025, viernes
};

// Velas diarias con ts <= ahora; la del dia de "ahora" va a medias.
function velas(estado, producto = 'BTC-USD') {
  const cfg = PRODUCTOS[producto];
  if (!cfg) return [];
  const ahora = estado.ahora;
  const rnd = lcg(cfg.semilla);
  // Redondeo al tick: con 0,01 se usa r2 (dos decimales exactos); con 5, enteros.
  const rt = cfg.tick === 0.01 ? r2 : x => Math.round(x / cfg.tick) * cfg.tick;
  const rv = x => Math.round(x * cfg.vol) / cfg.vol;
  const out = [];
  // Precios realistas (como BTC hoy): con precios bajos un fallo de precision
  // en las cifras decimales pasaria inadvertido.
  let prev = cfg.p0;
  for (let t = cfg.inicio; t <= ahora; t += DIA) {
    let r = (rnd() - 0.5) * 0.08; const u1 = rnd(), u2 = rnd(), u3 = rnd();
    if (prev * (1 + r) < 10000) r = Math.abs(r);
    const o = rt(prev);
    let c = rt(o * (1 + r));
    let h = rt(Math.max(o, c) + u1 * 0.02 * o);
    let l = rt(Math.max(cfg.tick, Math.min(o, c) - u2 * 0.02 * o));
    let v = rv(1000 + u3 * 500);
    prev = c;
    if (t + DIA > ahora) {            // vela en curso
      const fr = (ahora - t) / DIA;
      c = rt(o + (c - o) * fr); h = rt(Math.max(o, c, o + (h - Math.max(o, c)) * fr)); l = rt(Math.min(o, c, o - (Math.min(o, c) - l) * fr));
      h = Math.max(h, o, c); l = Math.min(l, o, c);
      v = rv(v * fr);
    }
    let vela = { t, o, h, l, c, v };
    const camEn = ((estado.cambiarEn || {})[producto] || {})[String(t)];
    if (camEn) vela = Object.assign(vela, camEn);
    if (producto === 'BTC-USD') {
      const cam = (estado.cambiar || {})[String(t)];
      if (cam) vela = Object.assign(vela, cam);
      if ((estado.quitar || []).includes(t)) continue;
    }
    out.push(vela);
  }
  return out;
}

// Calculo de referencia: filas esperadas en cripto_vela.
function esperadas(vs, ahora) {
  const filas = [];
  let ao, ac;
  vs.forEach((v, i) => {
    const hc = (v.o + v.h + v.l + v.c) / 4;
    const ho = i === 0 ? (v.o + v.c) / 2 : (ao + ac) / 2;
    filas.push({ marco: '1d', ts: v.t, o: v.o, h: v.h, l: v.l, c: v.c, v: v.v, ho, hh: Math.max(v.h, ho, hc), hl: Math.min(v.l, ho, hc), hc, cerrada: v.t + DIA <= ahora ? 1 : 0, dias: null });
    ao = ho; ac = hc;
  });
  // Semanas: lunes 00:00 UTC.
  const sem = new Map();
  for (const v of vs) {
    const d = new Date(v.t * 1000); const dow = (d.getUTCDay() + 6) % 7; // lunes = 0
    const w = v.t - dow * DIA;
    if (!sem.has(w)) sem.set(w, { t: w, o: v.o, h: v.h, l: v.l, c: v.c, v: 0, n: 0 });
    const s = sem.get(w); s.h = Math.max(s.h, v.h); s.l = Math.min(s.l, v.l); s.c = v.c; s.v += v.v; s.n++;
  }
  let wo, wc, k = 0;
  for (const s of [...sem.values()].sort((a, b) => a.t - b.t)) {
    const hc = (s.o + s.h + s.l + s.c) / 4;
    const ho = k === 0 ? (s.o + s.c) / 2 : (wo + wc) / 2;
    filas.push({ marco: '1w', ts: s.t, o: s.o, h: s.h, l: s.l, c: s.c, v: s.v, ho, hh: Math.max(s.h, ho, hc), hl: Math.min(s.l, ho, hc), hc, cerrada: s.t + 7 * DIA <= ahora ? 1 : 0, dias: s.n });
    wo = ho; wc = hc; k++;
  }
  return filas;
}

module.exports = { DIA, INICIO, PRODUCTOS, leeEstado, velas, esperadas };
