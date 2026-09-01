const express = require('express');
const qrcode = require('qrcode');
const pino = require('pino');
const fs = require('fs');
const path = require('path');
const {
    default: makeWASocket,
    useMultiFileAuthState,
    DisconnectReason,
    fetchLatestBaileysVersion
} = require('@whiskeysockets/baileys');

const PORT = process.env.PORT || 8002;

// ---- Chatbot IA (Gemini) ----------------------------------------------------
const GEMINI_KEY = process.env.GEMINI_API_KEY || '';
const OWNER_NUMBER = (process.env.OWNER_NUMBER || '14088410157').replace(/[^0-9]/g, '');
const RQLITE_API = process.env.RQLITE_API || 'http://localhost:4001';

// WhatsApp usa "LID" (@lid) para ocultar el numero real del remitente. Aceptamos
// tanto el numero (@s.whatsapp.net) como el LID. Los LID permitidos vienen de la
// env OWNER_LID (coma-separada) y ademas se resuelven via onWhatsApp() al conectar.
const allowedIds = new Set([OWNER_NUMBER]);
(process.env.OWNER_LID || '').split(',').map(s => s.replace(/[^0-9]/g, '')).filter(Boolean).forEach(x => allowedIds.add(x));
function isAllowedSender(jid) {
    if (!jid) return false;
    if (!jid.endsWith('@s.whatsapp.net') && !jid.endsWith('@lid')) return false;
    const digits = jid.split('@')[0].replace(/[^0-9]/g, '');
    return allowedIds.has(digits);
}

// ---- Estado persistente: historial de conversacion + preferencias -----------
const STATE_FILE = path.join(__dirname, 'chat_state.json');
const HISTORY_MAX = 12; // ultimos 6 intercambios por remitente
let state = { histories: {}, preferences: {} };
try {
    if (fs.existsSync(STATE_FILE)) {
        const loaded = JSON.parse(fs.readFileSync(STATE_FILE, 'utf-8'));
        state.histories = loaded.histories || {};
        state.preferences = loaded.preferences || {};
        console.log(`[STATE] cargado: ${Object.keys(state.preferences).length} usuarios con preferencias`);
    }
} catch (e) { console.warn('[STATE] no se pudo leer chat_state.json:', e.message); }
let saveTimer = null;
function saveState() {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(() => {
        try { fs.writeFileSync(STATE_FILE, JSON.stringify(state)); } catch (e) { console.warn('[STATE] no se pudo guardar:', e.message); }
    }, 300);
}

const SYSTEM_BASE =
    'Eres un asistente de infraestructura por WhatsApp para la flota Sentinel: 11 nodos (9 telefonos Android con Termux ' +
    'y 2 servidores Ubuntu: sentinel001, 002, 003, 005, 009, 010, 017, 018, 019, 014, 016) que forman un cluster rqlite (SQLite distribuido con Raft). ' +
    'OJO: los node-id de Raft NO siguen el numero del host (sentinel003=node2, sentinel017=node8, sentinel002=node9, sentinel018=node10, sentinel019=node11); usa siempre el nombre del host al responder. ' +
    'Las tablas sentinel_temp y sentinel_disk guardan telemetria (temperatura de bateria/CPU y espacio en disco) de cada nodo cada minuto, con retencion de 90 dias. ' +
    'IMPORTANTE: para cualquier pregunta sobre nodos combinando estado + temperatura + almacenamiento, usa SIEMPRE la VISTA v_sentinel_estado con consultar_bd. ' +
    'Ya trae UNA fila por nodo con todo combinado, no hagas JOIN manual entre sentinel_temp y sentinel_disk (te dara filas duplicadas o vacias). ' +
    'Columnas de v_sentinel_estado: node, raft_node_id, activo (1 si escribio en los ultimos 3 min, 0 si no), temp_c, nivel_temp, fuente_temp, libre_gb, total_gb, pct_libre, sd_libre_gb (null si no tiene SD), ultima_lectura. ' +
    'Ejemplo: "nodos activos con temperatura y disco" -> SELECT node, temp_c, libre_gb, pct_libre FROM v_sentinel_estado WHERE activo=1 ORDER BY temp_c DESC. ' +
    'Los nombres de nodo en la BD estan SIEMPRE en minusculas (sentinel001, sentinel017...). La herramienta estado_red da el estado de Raft en vivo (lider/quorum), que NO esta en la BD: no intentes cruzarla por SQL. ' +
    'Puedes consultar el estado de la red de nodos y la base de datos rqlite usando las herramientas disponibles. ' +
    'Responde SIEMPRE en espanol, breve y claro para leer en WhatsApp (evita markdown pesado; emojis moderados estan bien). ' +
    'Cuando pregunten por datos o estado, USA las herramientas; nunca inventes cifras.';

function buildSystem(senderId, schemaText) {
    const prefs = state.preferences[senderId] || [];
    const prefText = prefs.length ? prefs.map((p, i) => `  ${i + 1}. ${p}`).join('\n') : '  (ninguna registrada)';
    return SYSTEM_BASE +
        '\n\n### Esquema ACTUAL de la base de datos rqlite (usa estos nombres exactos de columnas):\n' + schemaText +
        '\n\n### Preferencias guardadas de este usuario (respetalas SIEMPRE sin que las repita):\n' + prefText +
        '\n\n### Reglas de datos:\n' +
        '- El usuario escribe en espanol y usa nombres en espanol; MAPEA sus terminos a las columnas reales del esquema de arriba ' +
        '(titulo=title, empresa=company, ubicacion=location, salario=salary, descripcion=description, estado=status, etc.). ' +
        'NUNCA digas que una columna no existe sin mirar el esquema; no le pidas al usuario los nombres de columnas.\n' +
        '- La columna salary es TEXTO libre (ej. "$23 - $29 an hour", "$50,000 a year"), NO numero. Para filtrar por sueldo por hora, ' +
        'trae filas candidatas (p.ej. status=\'active\' y salary con "hour", columnas minimas y LIMIT razonable) y razona sobre el texto para aplicar el umbral.\n' +
        '- Selecciona solo las columnas necesarias; NUNCA traigas description ni link salvo que las pidan (son enormes). Usa LIMIT al explorar.\n' +
        '- No hagas repetir al usuario lo que ya dijo antes en la conversacion; recuerda el contexto.\n' +
        '- Cuando el usuario exprese una preferencia duradera (campos favoritos, filtros por defecto, formato de respuesta), guardala con la herramienta guardar_preferencia para no volver a pedirla.';
}

const TOOLS = [{
    function_declarations: [
        { name: 'estado_red', description: 'Estado de la red de nodos rqlite: cuantos alcanzables, quien es el lider y si hay quorum. Sin argumentos.', parameters: { type: 'object', properties: {} } },
        { name: 'esquema_bd', description: 'Refresca y devuelve el esquema completo (tablas, columnas, filas). El esquema ya viene en el system prompt; usa esto solo si necesitas refrescarlo. Sin argumentos.', parameters: { type: 'object', properties: {} } },
        { name: 'consultar_bd', description: 'Ejecuta una consulta SQL de SOLO LECTURA (SELECT/PRAGMA/WITH) sobre la base de datos rqlite y devuelve las filas.', parameters: { type: 'object', properties: { sql: { type: 'string', description: 'La consulta SQL de lectura a ejecutar' } }, required: ['sql'] } },
        { name: 'guardar_preferencia', description: 'Guarda de forma permanente una preferencia del usuario (campos favoritos, filtros por defecto, formato de respuesta, etc.) para no tener que repetirla.', parameters: { type: 'object', properties: { texto: { type: 'string', description: 'La preferencia a recordar, en una frase clara' } }, required: ['texto'] } },
        { name: 'olvidar_preferencia', description: 'Elimina una preferencia guardada por su numero (1-based) o por texto.', parameters: { type: 'object', properties: { referencia: { type: 'string', description: 'Numero o texto de la preferencia a olvidar' } }, required: ['referencia'] } }
    ]
}];

const sleep = (ms) => new Promise(r => setTimeout(r, ms));

async function geminiGenerate(contents, systemText) {
    let model = 'gemini-2.5-flash';
    for (let attempt = 1; attempt <= 3; attempt++) {
        const url = `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${GEMINI_KEY}`;
        let response;
        try {
            response = await fetch(url, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ system_instruction: { parts: [{ text: systemText }] }, contents, tools: TOOLS })
            });
        } catch (e) { if (attempt === 3) throw e; await sleep(4000); continue; }
        if (response.status === 429) { model = 'gemini-2.0-flash'; await sleep(4000); continue; }
        if (!response.ok) {
            const t = await response.text();
            if (/quota|rate limit|429/i.test(t)) { model = 'gemini-2.0-flash'; await sleep(4000); continue; }
            throw new Error('Gemini API: ' + t);
        }
        return await response.json();
    }
    throw new Error('Gemini sin respuesta tras reintentos');
}

// --- Herramientas rqlite -----------------------------------------------------
async function rqliteQuery(sql) {
    if (!sql || typeof sql !== 'string') return { error: 'falta sql' };
    const s = sql.trim();
    if (!/^(select|pragma|with)\b/i.test(s)) return { error: 'solo se permiten consultas de lectura (SELECT/PRAGMA/WITH)' };
    for (const level of ['weak', 'none']) {
        try {
            const url = `${RQLITE_API}/db/query?level=${level}&q=${encodeURIComponent(s)}`;
            const r = await fetch(url, { signal: AbortSignal.timeout(8000) });
            const j = await r.json();
            const res = j.results && j.results[0];
            if (res && res.error) { if (level === 'weak') continue; return { error: res.error }; }
            return { columnas: (res && res.columns) || [], filas: (res && res.values) || [], num_filas: ((res && res.values) || []).length, nivel: level };
        } catch (e) { if (level === 'none') return { error: e.message }; }
    }
    return { error: 'no se pudo consultar la base de datos' };
}

const NODE_MAP = {
    node1: { n: 'sentinel001', ip: '192.168.1.69' }, node2: { n: 'sentinel003', ip: '192.168.1.94' },
    node3: { n: 'sentinel005', ip: '192.168.1.252' }, node4: { n: 'sentinel009', ip: '192.168.1.124' },
    node5: { n: 'sentinel010', ip: '192.168.1.190' }, node6: { n: 'sentinel014', ip: '192.168.1.250' },
    node7: { n: 'sentinel016', ip: '192.168.1.91' },
    node8: { n: 'sentinel017', ip: '192.168.1.212' }, node9: { n: 'sentinel002', ip: '192.168.1.65' },
    node10: { n: 'sentinel018', ip: '192.168.1.211' },
    node11: { n: 'sentinel019', ip: '192.168.1.210' }
};
async function toolEstadoRed() {
    const r = await fetch(`${RQLITE_API}/nodes?pretty`, { signal: AbortSignal.timeout(8000) });
    const j = await r.json();
    const nodos = Object.entries(j).map(([id, v]) => ({
        id, nombre: (NODE_MAP[id] && NODE_MAP[id].n) || id, ip: (NODE_MAP[id] && NODE_MAP[id].ip) || v.addr,
        alcanzable: !!v.reachable, lider: !!v.leader
    }));
    const alcanzables = nodos.filter(n => n.alcanzable).length;
    const lider = nodos.find(n => n.lider);
    return { total: nodos.length, alcanzables, hay_quorum: alcanzables >= Math.floor(nodos.length / 2) + 1, lider: lider ? lider.nombre : 'ninguno', nodos };
}

// Esquema cacheado (columnas + filas) que se inyecta en el system prompt.
let schemaCache = '';
let schemaCacheAt = 0;
async function getSchemaText(force) {
    if (!force && schemaCache && (Date.now() - schemaCacheAt < 300000)) return schemaCache;
    try {
        const t = await rqliteQuery("SELECT name FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%'");
        if (t.error) { schemaCache = '(no se pudo leer el esquema: ' + t.error + ')'; schemaCacheAt = Date.now(); return schemaCache; }
        if (!t.filas.length) { schemaCache = '(la base de datos aun no tiene tablas)'; schemaCacheAt = Date.now(); return schemaCache; }
        const lines = [];
        for (const row of t.filas) {
            const name = String(row[0]).replace(/"/g, '');
            const info = await rqliteQuery('PRAGMA table_info("' + name + '")');
            const cnt = await rqliteQuery('SELECT COUNT(*) FROM "' + name + '"');
            const cols = (info.filas || []).map(r => `${r[1]}(${r[2] || '?'})`).join(', ');
            const n = (cnt.filas && cnt.filas[0] && cnt.filas[0][0]) != null ? cnt.filas[0][0] : '?';
            lines.push(`- ${name} (${n} filas): ${cols}`);
        }
        schemaCache = lines.join('\n'); schemaCacheAt = Date.now();
    } catch (e) { schemaCache = '(error leyendo esquema: ' + e.message + ')'; schemaCacheAt = Date.now(); }
    return schemaCache;
}
async function toolEsquemaBd() { const txt = await getSchemaText(true); return { esquema: txt }; }

async function runTool(name, args, ctx) {
    try {
        if (name === 'estado_red') return await toolEstadoRed();
        if (name === 'esquema_bd') return await toolEsquemaBd();
        if (name === 'consultar_bd') return await rqliteQuery(args && args.sql);
        if (name === 'guardar_preferencia') {
            const txt = String((args && args.texto) || '').trim();
            if (!txt) return { error: 'texto vacio' };
            if (!state.preferences[ctx.senderId]) state.preferences[ctx.senderId] = [];
            state.preferences[ctx.senderId].push(txt); saveState();
            return { ok: true, guardado: txt, total: state.preferences[ctx.senderId].length };
        }
        if (name === 'olvidar_preferencia') {
            const arr = state.preferences[ctx.senderId] || [];
            const ref = String((args && args.referencia) || '').trim();
            let idx = parseInt(ref, 10);
            idx = !isNaN(idx) ? idx - 1 : arr.findIndex(p => p.toLowerCase().includes(ref.toLowerCase()));
            if (idx < 0 || idx >= arr.length) return { error: 'preferencia no encontrada' };
            const rm = arr.splice(idx, 1)[0]; saveState();
            return { ok: true, olvidado: rm };
        }
        return { error: 'herramienta desconocida: ' + name };
    } catch (e) { return { error: e.message }; }
}

async function agentAnswer(userText, senderId) {
    const schemaText = await getSchemaText(false);
    const systemText = buildSystem(senderId, schemaText);
    const hist = (state.histories[senderId] || []).slice();
    const contents = [...hist, { role: 'user', parts: [{ text: userText }] }];
    for (let step = 0; step < 8; step++) {
        const resp = await geminiGenerate(contents, systemText);
        const cand = resp.candidates && resp.candidates[0];
        const parts = (cand && cand.content && cand.content.parts) || [];
        const fcPart = parts.find(p => p.functionCall);
        if (fcPart) {
            contents.push({ role: 'model', parts });
            const result = await runTool(fcPart.functionCall.name, fcPart.functionCall.args || {}, { senderId });
            contents.push({ role: 'user', parts: [{ functionResponse: { name: fcPart.functionCall.name, response: result } }] });
            continue;
        }
        const text = parts.map(p => p.text).filter(Boolean).join('\n').trim() || 'No pude generar una respuesta.';
        const h = state.histories[senderId] || (state.histories[senderId] = []);
        h.push({ role: 'user', parts: [{ text: userText }] });
        h.push({ role: 'model', parts: [{ text }] });
        while (h.length > HISTORY_MAX) h.shift();
        saveState();
        return text;
    }
    return 'La consulta requirio demasiados pasos; reformulala mas simple, por favor.';
}
// -----------------------------------------------------------------------------

let sock = null;
let isReady = false;
let lastQr = null;
const logger = pino({ level: 'warn' });

async function startSock() {
    console.log('[INIT] Inicializando cliente de WhatsApp (WebSockets)...');
    const { state: authState, saveCreds } = await useMultiFileAuthState('auth_info_baileys');

    let version = [2, 3000, 1017531287];
    try {
        const { version: latestVersion, isLatest } = await fetchLatestBaileysVersion();
        console.log(`[INIT] Usando versión de WhatsApp Web v${latestVersion.join('.')}. ¿Es la última?: ${isLatest}`);
        version = latestVersion;
    } catch (err) { console.warn('[INIT] Error consultando versión web, usando por defecto:', err.message); }

    sock = makeWASocket({ version, auth: authState, logger, browser: ['Ubuntu', 'Chrome', '20.0.04'] });
    sock.ev.on('creds.update', saveCreds);

    // ---- Handler del chatbot: SOLO responde a OWNER ----
    sock.ev.on('messages.upsert', async ({ messages, type }) => {
        console.log(`[MSG] upsert type=${type} count=${messages.length}`);
        for (const msg of messages) {
            try {
                const jid = msg.key.remoteJid || '';
                const text = (msg.message && (msg.message.conversation || (msg.message.extendedTextMessage && msg.message.extendedTextMessage.text))) || '';
                if (!msg.message || msg.key.fromMe) continue;
                if (!isAllowedSender(jid)) { console.log(`[MSG]   ignorado (${jid} no autorizado)`); continue; }
                if (!String(text).trim()) continue;
                const senderId = jid.split('@')[0].replace(/[^0-9]/g, '');
                console.log(`[CHATBOT] de ${senderId}: ${String(text).trim().slice(0, 80)}`);
                if (!GEMINI_KEY) { await sock.sendMessage(jid, { text: '⚠️ GEMINI_API_KEY no configurada.' }); continue; }
                const answer = await agentAnswer(String(text).trim(), senderId);
                await sock.sendMessage(jid, { text: answer });
                console.log(`[CHATBOT] respondido (${answer.length} chars)`);
            } catch (e) {
                console.error('[CHATBOT] error:', e.message);
                try { await sock.sendMessage(msg.key.remoteJid, { text: '⚠️ Error procesando tu mensaje: ' + e.message }); } catch (_) {}
            }
        }
    });

    sock.ev.on('connection.update', (update) => {
        const { connection, lastDisconnect, qr } = update;
        if (qr) { lastQr = qr; isReady = false; console.log('[QR] Nuevo código QR. Escanéalo en :' + PORT + '/qr'); }
        if (connection === 'close') {
            isReady = false; lastQr = null;
            const statusCode = lastDisconnect?.error?.output?.statusCode;
            const shouldReconnect = statusCode !== DisconnectReason.loggedOut;
            console.log(`[CONNECTION] Cerrada. Código: ${statusCode}. Reconectando: ${shouldReconnect}`);
            setTimeout(startSock, shouldReconnect ? 5000 : 2000);
        } else if (connection === 'open') {
            isReady = true; lastQr = null;
            console.log('[READY] WhatsApp conectado. Servicio listo en :' + PORT);
            getSchemaText(true).then(() => console.log('[INIT] esquema de BD precargado')).catch(() => {});
            (async () => {
                try {
                    const res = await sock.onWhatsApp(OWNER_NUMBER);
                    const lid = res && res[0] && res[0].lid;
                    if (lid) {
                        const d = String(lid).split('@')[0].replace(/[^0-9]/g, '');
                        if (d) { allowedIds.add(d); console.log(`[INIT] LID del owner autorizado: ${d}`); }
                    }
                } catch (e) { console.warn('[INIT] no se pudo resolver LID del owner:', e.message); }
            })();
        }
    });
}

startSock().catch(err => console.error('[FATAL] Error iniciando socket:', err));

const app = express();
app.use(express.json());

app.get('/', (req, res) => res.json({ service: 'WhatsApp_Checker+Chatbot', ready: isReady, awaitingQr: !!lastQr, chatbot: { owner: OWNER_NUMBER, gemini: !!GEMINI_KEY, usuarios_con_memoria: Object.keys(state.preferences).length } }));

app.get('/qr', async (req, res) => {
    if (isReady) return res.status(200).send('Ya está vinculado.');
    if (!lastQr) return res.status(503).send('QR aún no disponible.');
    try { res.setHeader('Content-Type', 'image/png'); res.send(await qrcode.toBuffer(lastQr, { width: 350, margin: 2 })); }
    catch (e) { res.status(500).send('Error generando QR: ' + e.message); }
});

app.get('/pair', async (req, res) => {
    const number = String(req.query.number || '').replace(/[^0-9]/g, '');
    if (isReady) return res.json({ status: 'already_linked' });
    if (!number) return res.status(400).json({ error: 'Falta ?number=' });
    try { const code = await sock.requestPairingCode(number); res.json({ number, pairingCode: code }); }
    catch (e) { res.status(500).json({ error: e.message }); }
});

// Prueba del chatbot sin WhatsApp. Body: {q, from?}. 'from' fija el senderId (memoria).
app.post('/ask', async (req, res) => {
    const q = (req.body && req.body.q) || '';
    const from = String((req.body && req.body.from) || 'ask-test');
    if (!q.trim()) return res.status(400).json({ error: 'Falta q' });
    if (!GEMINI_KEY) return res.status(500).json({ error: 'GEMINI_API_KEY no configurada' });
    try { res.json({ q, from, answer: await agentAnswer(q.trim(), from) }); }
    catch (e) { res.status(500).json({ error: e.message }); }
});

app.post('/checkNumberStatus', async (req, res) => {
    const contactId = (req.body && req.body.args && req.body.args.contactId) || (req.body && req.body.contactId) || '';
    const number = String(contactId).replace(/@c\.us$/i, '').replace(/[^0-9]/g, '');
    if (!isReady) return res.status(503).json({ id: contactId, status: 503, error: 'WhatsApp no está listo.' });
    if (!number) return res.status(400).json({ id: contactId, status: 400, error: 'contactId inválido.' });
    try {
        const [result] = await sock.onWhatsApp(number);
        if (!result || !result.exists) return res.json({ id: contactId, status: 404, isBusiness: false });
        let isBusiness = false;
        try { if (await sock.getBusinessProfile(result.jid)) isBusiness = true; } catch (_) {}
        return res.json({ id: contactId, status: 200, isBusiness, canReceiveMessage: true });
    } catch (e) { return res.status(500).json({ id: contactId, status: 500, error: e.message }); }
});

app.listen(PORT, () => console.log(`[HTTP] Escuchando en :${PORT} (checker + chatbot IA con memoria, owner=${OWNER_NUMBER})`));
