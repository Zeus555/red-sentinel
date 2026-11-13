// Coinbase falso para las pruebas: sirve /products/<id>/candles?granularity=ONE_DAY
// con la serie de serie-falsa.js. Lee el estado (ahora, dias quitados o
// cambiados, fallos forzados) de un fichero JSON en CADA peticion, para que la
// prueba lo cambie entre pasadas.
// Uso: node cb-falso.js <puerto> <fichero-estado>
'use strict';
const http = require('http');
const { leeEstado, velas, PRODUCTOS } = require('./serie-falsa');

const [puerto, festado] = process.argv.slice(2);
let peticiones = 0, conClave = 0;
// Telegram falso (las señales): POST /bot<token>/sendMessage. Guarda cada intento
// con su token y su chat; con "tgFalla" en el estado contesta 500 y ok:false.
// No cuenta en /_peticiones, que es solo Coinbase.
const telegram = [];

http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  if (u.pathname === '/_peticiones') { res.end(String(peticiones)); return; }
  // Ninguna peticion a Coinbase puede llevar credenciales (las de rqlite).
  if (u.pathname === '/_conclave') { res.end(String(conClave)); return; }
  if (u.pathname === '/_telegram') { res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify(telegram)); return; }
  const tg = u.pathname.match(/^\/bot([^/]*)\/sendMessage$/);
  if (tg) {
    let cuerpo = '';
    req.on('data', d => { cuerpo += d; });
    req.on('end', () => {
      const f = new URLSearchParams(cuerpo), e = leeEstado(festado);
      telegram.push({ token: tg[1], chat: f.get('chat_id'), texto: f.get('text'), ok: !e.tgFalla, metodo: req.method, auth: !!req.headers.authorization });
      if (e.tgFalla) { res.writeHead(500); res.end('{"ok":false,"description":"falla a proposito"}'); return; }
      res.writeHead(200, { 'Content-Type': 'application/json' }); res.end('{"ok":true,"result":{"message_id":1}}');
    });
    return;
  }
  peticiones++;
  if (req.headers.authorization) conClave++;
  const e = leeEstado(festado);
  const m = u.pathname.match(/^\/products\/([A-Z0-9-]+)\/candles$/);
  if (e.fallo500 || (m && e.fallaProducto === m[1])) { res.writeHead(500); res.end('{"error":"INTERNAL"}'); return; }
  if (!m || !PRODUCTOS[m[1]]) { res.writeHead(404); res.end('{"error":"NOT_FOUND"}'); return; }
  if (u.searchParams.get('granularity') !== 'ONE_DAY') { res.writeHead(400); res.end('{"error":"granularity"}'); return; }
  const ini = +u.searchParams.get('start'), fin = +u.searchParams.get('end');
  if (!(fin > ini) || (fin - ini) / 86400 > 350) { res.writeHead(400); res.end('{"error":"INVALID_ARGUMENT","message":"too many candles"}'); return; }
  // Coinbase: velas con start en [start, end], la mas nueva primero.
  let vs = velas(e, m[1]).filter(v => v.t >= ini && v.t <= fin).reverse();
  // Fallos puntuales: todo vacio, o vacia solo la ventana que contiene un dia.
  if (e.vacio) vs = [];
  if (e.ventanaVacia && e.ventanaVacia >= ini && e.ventanaVacia <= fin) vs = [];
  const candles = vs.map(v => ({ start: String(v.t), low: String(v.l), high: String(v.h), open: String(v.o), close: String(v.c), volume: String(v.v) }));
  if (e.invalida && candles.length) candles[0].high = String(+candles[0].close - 1);
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ candles }));
}).listen(+puerto, '127.0.0.1', () => console.log('cb-falso escuchando en ' + puerto));
