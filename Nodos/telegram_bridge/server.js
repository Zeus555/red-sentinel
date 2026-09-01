// Puente Telegram (MTProto) para el reloj — flota Sentinel.
// Expone la MISMA forma de API que el puente de WhatsApp (whatsapp_checker
// /watch/*) en otro puerto, para que la app del reloj muestre una bandeja
// unificada consultando dos endpoints idénticos.
//
// Sesión de USUARIO (no bot): los bots no pueden leer los chats personales.
// Telegram permite clientes de terceros con api_id propio; la sesión aparece
// en Ajustes > Dispositivos y se puede revocar desde ahí.

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const express = require('express');
const { TelegramClient, Api } = require('teleproto');
const { StringSession } = require('teleproto/sessions');
const { NewMessage } = require('teleproto/events');

const PORT = process.env.PORT || 8003;
const DIR = __dirname;

// ---- Credenciales y secretos (todos 600, fuera del mirror) ------------------
function leerConf(archivo) {
    const out = {};
    try {
        for (const linea of fs.readFileSync(path.join(DIR, archivo), 'utf-8').split('\n')) {
            const m = linea.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$/);
            if (m) out[m[1]] = m[2].trim();
        }
    } catch (e) { console.warn(`[CONF] no se pudo leer ${archivo}: ${e.message}`); }
    return out;
}
const conf = leerConf('api.txt');
const API_ID = parseInt(conf.api_id, 10);
const API_HASH = conf.api_hash || '';

const TOKEN_FILE = path.join(DIR, 'watch_token.txt');
let WATCH_TOKEN = '';
try { WATCH_TOKEN = fs.readFileSync(TOKEN_FILE, 'utf-8').trim(); } catch (_) {}

// Dos procesos hablando con la MISMA auth key hacen que Telegram la invalide
// (AUTH_KEY_DUPLICATED) y obligan a re-loguear. Un lock con PID vivo evita el
// solapamiento clásico: runit relanzando encima de un arranque manual.
const LOCK_FILE = path.join(DIR, 'bridge.pid');
try {
    if (fs.existsSync(LOCK_FILE)) {
        const viejo = parseInt(fs.readFileSync(LOCK_FILE, 'utf-8').trim(), 10);
        if (viejo && viejo !== process.pid) {
            let vivo = false;
            try { process.kill(viejo, 0); vivo = true; } catch (_) {}
            if (vivo) {
                console.error(`[FATAL] ya hay otro puente vivo (pid ${viejo}). Abortando para no invalidar la sesión.`);
                process.exit(1);
            }
        }
    }
    fs.writeFileSync(LOCK_FILE, String(process.pid));
} catch (e) { console.warn('[LOCK] no se pudo gestionar el lock:', e.message); }
process.on('exit', () => { try { if (parseInt(fs.readFileSync(LOCK_FILE, 'utf-8').trim(), 10) === process.pid) fs.unlinkSync(LOCK_FILE); } catch (_) {} });

const SESSION_FILE = path.join(DIR, 'session.txt');
let sessionString = '';
try { sessionString = fs.readFileSync(SESSION_FILE, 'utf-8').trim(); } catch (_) {}

const STORE_FILE = path.join(DIR, 'watch_store.json');
const AUDIT_FILE = path.join(DIR, 'watch_audit.log');
const MAX_MSGS_POR_CHAT = 60;
const MAX_CHATS = 40;

let store = { chats: {}, messages: {} };
try {
    if (fs.existsSync(STORE_FILE)) {
        const l = JSON.parse(fs.readFileSync(STORE_FILE, 'utf-8'));
        store.chats = l.chats || {};
        store.messages = l.messages || {};
        console.log(`[STORE] cargado: ${Object.keys(store.chats).length} chats`);
    }
} catch (e) { console.warn('[STORE] no se pudo leer:', e.message); }

let storeTimer = null;
function saveStore() {
    clearTimeout(storeTimer);
    storeTimer = setTimeout(() => {
        try { fs.writeFileSync(STORE_FILE, JSON.stringify(store)); } catch (e) { console.warn('[STORE] no se pudo guardar:', e.message); }
    }, 2000);
}

// ---- Estado del cliente ------------------------------------------------------
let client = null;
let isReady = false;
let loginState = 'desconectado'; // desconectado | esperando_codigo | esperando_password | conectado | error
let loginError = null;
let miId = null;

// Promesas diferidas: client.start() pide el código por callback, pero aquí el
// código llega por HTTP, así que el callback espera a que /login/code lo entregue.
function diferida() {
    let resolver, rechazar;
    const promesa = new Promise((res, rej) => { resolver = res; rechazar = rej; });
    return { promesa, resolver, rechazar };
}
let esperaCodigo = null;
let esperaPassword = null;
let telefonoLogin = null;

function textoDeMensaje(msg) {
    if (!msg) return null;
    if (msg.message) return String(msg.message);
    const m = msg.media;
    if (!m) return null;
    const cls = m.className || '';
    if (cls.includes('Photo')) return '📷 [imagen]';
    if (cls.includes('Document')) {
        const attrs = (m.document && m.document.attributes) || [];
        if (attrs.some(a => (a.className || '').includes('Audio'))) return '🎤 [audio]';
        if (attrs.some(a => (a.className || '').includes('Video'))) return '🎬 [video]';
        if (attrs.some(a => (a.className || '').includes('Sticker'))) return '[sticker]';
        return '📄 [documento]';
    }
    if (cls.includes('GeoPoint') || cls.includes('Geo')) return '📍 [ubicación]';
    if (cls.includes('Contact')) return '👤 [contacto]';
    if (cls.includes('Poll')) return '📊 [encuesta]';
    return '[adjunto]';
}

function tsDe(msg) {
    const d = msg && msg.date;
    if (typeof d === 'number') return d;
    if (d instanceof Date) return Math.floor(d.getTime() / 1000);
    return Math.floor(Date.now() / 1000);
}

function nombreRemitente(msg) {
    try {
        const s = msg.sender;
        if (!s) return null;
        if (s.firstName || s.lastName) return [s.firstName, s.lastName].filter(Boolean).join(' ');
        if (s.title) return s.title;
        if (s.username) return s.username;
    } catch (_) {}
    return null;
}

function registrarMensaje(chatId, entrada, esEntrante, nombreChat) {
    const jid = 'tg:' + chatId;
    if (!store.chats[jid]) store.chats[jid] = { name: nombreChat || null, lastTs: 0, unread: 0, group: false };
    const chat = store.chats[jid];
    if (nombreChat) chat.name = nombreChat;
    chat.lastTs = Math.max(chat.lastTs || 0, entrada.ts);
    chat.lastText = entrada.text;
    chat.lastFromMe = !!entrada.fromMe;
    if (esEntrante) chat.unread = (chat.unread || 0) + 1;

    if (!store.messages[jid]) store.messages[jid] = [];
    const arr = store.messages[jid];
    if (entrada.id && arr.some(m => m.id === entrada.id)) return;
    arr.push(entrada);
    arr.sort((a, b) => a.ts - b.ts);
    while (arr.length > MAX_MSGS_POR_CHAT) arr.shift();

    const jids = Object.keys(store.chats);
    if (jids.length > MAX_CHATS) {
        jids.sort((a, b) => (store.chats[a].lastTs || 0) - (store.chats[b].lastTs || 0));
        for (const viejo of jids.slice(0, jids.length - MAX_CHATS)) {
            delete store.chats[viejo];
            delete store.messages[viejo];
        }
    }
    saveStore();
}

// getDialogs es caro y sin límite trae TODO: nunca dispararlo por cada petición
// del reloj (FLOOD_WAIT + pico de RAM). Se cachea y se refresca como mucho cada
// REFRESH_MIN_MS; entre medias, los eventos NewMessage mantienen el almacén vivo.
const REFRESH_MIN_MS = 60000;
let ultimoRefresco = 0;
let refrescoEnCurso = null;

async function refrescarDialogos(limite = MAX_CHATS, forzar = false) {
    if (!client || !isReady) return 0;
    if (refrescoEnCurso) return refrescoEnCurso;
    if (!forzar && Date.now() - ultimoRefresco < REFRESH_MIN_MS) return 0;
    ultimoRefresco = Date.now();
    refrescoEnCurso = _refrescarDialogos(limite).finally(() => { refrescoEnCurso = null; });
    return refrescoEnCurso;
}

// Si Telegram dice que la auth key no está registrada, la sesión fue revocada
// (el usuario terminó la sesión en Ajustes > Dispositivos, o Telegram la mató).
// Hay que reflejarlo en el estado: si no, /watch/* sigue sirviendo la caché y
// aparenta salud mientras el puente está muerto.
function detectarRevocacion(e) {
    const m = String((e && e.message) || e);
    if (/AUTH_KEY_UNREGISTERED|authorization key is not registered|SESSION_REVOKED|USER_DEACTIVATED|AUTH_KEY_DUPLICATED/i.test(m)) {
        isReady = false;
        loginState = 'revocado';
        loginError = m;
        console.error('[AUTH] sesión revocada o inválida. Hace falta volver a vincular con /login/start');
        return true;
    }
    return false;
}

async function _refrescarDialogos(limite) {
    const dialogos = await client.getDialogs({ limit: limite }).catch(e => { detectarRevocacion(e); throw e; });
    let n = 0;
    for (const d of dialogos) {
        try {
            const id = d.id && d.id.toString ? d.id.toString() : String(d.id);
            if (!id) continue;
            const jid = 'tg:' + id;
            const msg = d.message;
            if (!store.chats[jid]) store.chats[jid] = { name: null, lastTs: 0, unread: 0, group: false };
            const chat = store.chats[jid];
            chat.name = d.title || d.name || chat.name || id;
            chat.group = !!(d.isGroup || d.isChannel);
            chat.unread = d.unreadCount || 0;
            if (msg) {
                chat.lastTs = tsDe(msg);
                chat.lastText = textoDeMensaje(msg) || '';
                chat.lastFromMe = !!msg.out;
            }
            n++;
        } catch (e) { console.warn('[DIALOGS] error en un diálogo:', e.message); }
    }
    saveStore();
    console.log(`[DIALOGS] refrescados ${n} chats`);
    return n;
}

async function arrancarCliente() {
    if (!API_ID || !API_HASH) {
        console.error('[FATAL] falta api_id/api_hash en api.txt');
        loginState = 'error';
        loginError = 'api.txt sin api_id/api_hash';
        return;
    }
    client = new TelegramClient(new StringSession(sessionString), API_ID, API_HASH, {
        connectionRetries: 5,
        // reconnectRetries es Infinity por defecto: acotarlo para que, si la red
        // muere de verdad, el proceso salga y runit lo relance limpio.
        reconnectRetries: 10,
        retryDelay: 5000,
        keepAliveInterval: 30000, // NAT móvil agresivo
        useWSS: false,
        deviceModel: 'PRC Watch Bridge',
        systemVersion: 'sentinel001 / Termux',
        appVersion: '1.0.0'
    });

    client.addEventHandler(async (evento) => {
        try {
            const msg = evento.message;
            if (!msg) return;
            const chatId = msg.chatId && msg.chatId.toString ? msg.chatId.toString() : String(msg.chatId || '');
            if (!chatId) return;
            const texto = textoDeMensaje(msg);
            if (texto == null) return;
            const fromMe = !!msg.out;
            let nombreChat = null;
            try { const c = await msg.getChat(); if (c) nombreChat = c.title || [c.firstName, c.lastName].filter(Boolean).join(' ') || null; } catch (_) {}
            registrarMensaje(chatId, {
                id: msg.id != null ? String(msg.id) : null,
                fromMe,
                ts: tsDe(msg),
                text: String(texto).slice(0, 1000),
                sender: fromMe ? 'yo' : (nombreRemitente(msg) || 'alguien')
            }, !fromMe, nombreChat);
        } catch (e) { console.warn('[EVENT] error:', e.message); }
    }, new NewMessage({}));

    if (sessionString) {
        try {
            await client.connect();
            if (await client.isUserAuthorized()) {
                isReady = true;
                loginState = 'conectado';
                const yo = await client.getMe();
                miId = yo && yo.id ? yo.id.toString() : null;
                console.log(`[READY] Telegram conectado (id=${miId})`);
                // Recupera lo perdido mientras el proceso estuvo caído. Si el hueco
                // es demasiado grande Telegram responde UpdatesTooLong: entonces el
                // refresco de diálogos de abajo es el que rellena el agujero.
                try { await client.catchUp(); } catch (e) { console.warn('[CATCHUP]', e.message); }
                refrescarDialogos(MAX_CHATS, true).catch(e => console.warn('[DIALOGS] fallo inicial:', e.message));
                return;
            }
            console.log('[LOGIN] sesión guardada no autorizada; hace falta login nuevo');
        } catch (e) {
            console.warn('[LOGIN] no se pudo reusar la sesión:', e.message);
        }
    }
    console.log('[LOGIN] sin sesión. Usa POST /login/start {"phone":"+1..."}');
    loginState = 'desconectado';
}

async function hacerLogin(telefono) {
    telefonoLogin = telefono;
    esperaCodigo = diferida();
    esperaPassword = diferida();
    loginError = null;
    try {
        await client.start({
            phoneNumber: async () => telefono,
            phoneCode: async () => {
                loginState = 'esperando_codigo';
                console.log('[LOGIN] esperando código en POST /login/code');
                return await esperaCodigo.promesa;
            },
            password: async () => {
                loginState = 'esperando_password';
                console.log('[LOGIN] 2FA: esperando contraseña en POST /login/password');
                return await esperaPassword.promesa;
            },
            onError: (err) => { console.error('[LOGIN] error:', err && err.message); loginError = String(err && err.message || err); }
        });
        sessionString = client.session.save();
        fs.writeFileSync(SESSION_FILE, sessionString, { mode: 0o600 });
        try { fs.chmodSync(SESSION_FILE, 0o600); } catch (_) {}
        isReady = true;
        loginState = 'conectado';
        const yo = await client.getMe();
        miId = yo && yo.id ? yo.id.toString() : null;
        console.log(`[READY] Telegram vinculado y sesión guardada (id=${miId})`);
        refrescarDialogos().catch(e => console.warn('[DIALOGS] fallo:', e.message));
    } catch (e) {
        loginState = 'error';
        loginError = e.message;
        console.error('[LOGIN] fallo:', e.message);
    }
}

// ---- API ---------------------------------------------------------------------
function watchAuth(req, res, next) {
    if (!WATCH_TOKEN) return res.status(503).json({ error: 'watch_token.txt no configurado' });
    const t = Buffer.from(String(req.headers['x-watch-token'] || req.query.token || ''));
    const b = Buffer.from(WATCH_TOKEN);
    if (t.length !== b.length || !crypto.timingSafeEqual(t, b)) return res.status(401).json({ error: 'token inválido' });
    next();
}

const envios = [];
function puedeEnviar() {
    const corte = Date.now() - 600000;
    while (envios.length && envios[0] < corte) envios.shift();
    return envios.length < 20;
}

const app = express();
app.use(express.json());

app.get('/', (req, res) => res.json({
    service: 'Telegram_Bridge', ready: isReady, login: loginState, error: loginError,
    watch: { configurado: !!WATCH_TOKEN, chats: Object.keys(store.chats).length }
}));

// --- Login (solo desde la LAN/ssh; requiere el token del reloj) ---
app.post('/login/start', watchAuth, async (req, res) => {
    const phone = String((req.body && req.body.phone) || '').trim();
    if (!phone) return res.status(400).json({ error: 'Falta phone (formato +<país><número>)' });
    if (isReady && loginState === 'conectado') return res.json({ status: 'ya_vinculado' });
    if (!client) return res.status(503).json({ error: 'cliente no inicializado' });
    hacerLogin(phone); // en segundo plano; el código llega por /login/code
    setTimeout(() => res.json({ status: loginState, mensaje: 'Telegram te enviará un código. Envíalo a POST /login/code {"code":"12345"}' }), 6000);
});

app.post('/login/code', watchAuth, (req, res) => {
    const code = String((req.body && req.body.code) || '').replace(/[^0-9]/g, '');
    if (!code) return res.status(400).json({ error: 'Falta code' });
    if (!esperaCodigo) return res.status(409).json({ error: 'No hay login en curso; llama antes a /login/start' });
    esperaCodigo.resolver(code);
    setTimeout(() => res.json({ status: loginState, ready: isReady, error: loginError }), 8000);
});

app.post('/login/password', watchAuth, (req, res) => {
    const pw = String((req.body && req.body.password) || '');
    if (!pw) return res.status(400).json({ error: 'Falta password' });
    if (!esperaPassword) return res.status(409).json({ error: 'No hay login en curso' });
    esperaPassword.resolver(pw);
    setTimeout(() => res.json({ status: loginState, ready: isReady, error: loginError }), 8000);
});

// --- Endpoints del reloj (misma forma que el puente de WhatsApp) ---
app.get('/watch/health', watchAuth, (req, res) => {
    res.json({ ready: isReady, login: loginState, chats: Object.keys(store.chats).length, ts: Date.now() });
});

app.get('/watch/chats', watchAuth, async (req, res) => {
    if (isReady && req.query.refresh !== '0') {
        // Throttled: como mucho un getDialogs por minuto (ver REFRESH_MIN_MS).
        try { await refrescarDialogos(); } catch (e) { console.warn('[CHATS] refresco falló:', e.message); }
    }
    const lista = Object.entries(store.chats).map(([jid, c]) => ({
        jid, name: c.name || jid, lastText: c.lastText || '', lastTs: c.lastTs || 0,
        lastFromMe: !!c.lastFromMe, unread: c.unread || 0, group: !!c.group, service: 'telegram'
    })).sort((a, b) => b.lastTs - a.lastTs);
    res.json({ ready: isReady, chats: lista });
});

app.get('/watch/messages', watchAuth, async (req, res) => {
    const jid = String(req.query.jid || '');
    if (!jid.startsWith('tg:')) return res.status(400).json({ error: 'Falta ?jid=tg:<id>' });
    const id = jid.slice(3);
    const limit = Math.min(parseInt(req.query.limit, 10) || 40, MAX_MSGS_POR_CHAT);
    if (isReady) {
        try {
            const msgs = await client.getMessages(id, { limit });
            for (const m of msgs) {
                const texto = textoDeMensaje(m);
                if (texto == null) continue;
                registrarMensaje(id, {
                    id: m.id != null ? String(m.id) : null,
                    fromMe: !!m.out, ts: tsDe(m),
                    text: String(texto).slice(0, 1000),
                    sender: m.out ? 'yo' : (nombreRemitente(m) || 'alguien')
                }, false, null);
            }
        } catch (e) { console.warn('[MESSAGES] no se pudo traer historial:', e.message); }
    }
    if (store.chats[jid]) { store.chats[jid].unread = 0; saveStore(); }
    res.json({ jid, name: (store.chats[jid] && store.chats[jid].name) || jid, messages: (store.messages[jid] || []).slice(-limit) });
});

// Bandeja plana: mensajes recientes de todos los chats, más nuevo primero.
// Misma forma que el puente de WhatsApp para que el reloj mezcle las dos.
app.get('/watch/feed', watchAuth, (req, res) => {
    const limit = Math.min(parseInt(req.query.limit, 10) || 30, 100);
    const soloAjenos = req.query.mine === '0';
    const out = [];
    for (const jid of Object.keys(store.messages)) {
        const chat = store.chats[jid] || {};
        for (const m of store.messages[jid]) {
            if (soloAjenos && m.fromMe) continue;
            out.push({
                id: m.id, jid, chatName: chat.name || jid, fromMe: !!m.fromMe,
                ts: m.ts, text: m.text, sender: m.sender,
                group: !!chat.group, service: 'telegram'
            });
        }
    }
    out.sort((a, b) => b.ts - a.ts);
    res.json({ ready: isReady, messages: out.slice(0, limit) });
});

// Marcar como leído SOLO en local. NO llama a messages.readHistory, así que en
// Telegram el remitente no ve que se leyó (decisión explícita del usuario).
app.post('/watch/read', watchAuth, (req, res) => {
    const jid = String((req.body && req.body.jid) || '');
    if (!jid) return res.status(400).json({ error: 'Falta jid' });
    if (store.chats[jid]) { store.chats[jid].unread = 0; saveStore(); }
    res.json({ ok: true, solo_local: true });
});

/**
 * Bloquear a un remitente en Telegram. Body: {jid} con prefijo tg:.
 *
 * OJO con `myStoriesFrom`: pasarlo a true NO bloquea de verdad, solo mete al
 * contacto en la lista de bloqueo de historias. Aquí se omite a propósito.
 *
 * El bloqueo es de cuenta (se ve también en el teléfono del usuario) y
 * reversible con contacts.Unblock. Al bloqueado no le llega ningún aviso.
 */
app.post('/watch/block', watchAuth, async (req, res) => {
    const jid = String((req.body && req.body.jid) || '').trim();
    if (!jid) return res.status(400).json({ error: 'Falta jid' });
    if (!isReady) return res.status(503).json({ error: 'Telegram no está vinculado' });

    const id = jid.startsWith('tg:') ? jid.slice(3) : jid;
    const chat = store.chats['tg:' + id];
    // En un grupo o canal el remitente es un participante: bloquear el chat
    // entero no es lo que nadie espera. Se deja al reloj ocultarlo en local.
    if (chat && chat.group) {
        return res.status(400).json({ error: 'no_se_puede_bloquear_grupo' });
    }

    try {
        // getInputEntity primero: pasar el id pelado solo funciona si la
        // entidad ya está en la caché de la sesión.
        const entidad = await client.getInputEntity(id);
        await client.invoke(new Api.contacts.Block({ id: entidad }));

        let verificado = false;
        try {
            const bloqueados = await client.invoke(new Api.contacts.GetBlocked({ offset: 0, limit: 100 }));
            const lista = (bloqueados && (bloqueados.blocked || bloqueados.users)) || [];
            verificado = JSON.stringify(lista).includes(String(id).replace('-100', ''));
        } catch (e) {
            console.warn('[BLOCK] no se pudo verificar:', e.message);
        }

        try { fs.appendFileSync(AUDIT_FILE, `${new Date().toISOString()} watch block tg:${id} verificado=${verificado}\n`); } catch (_) {}
        console.log(`[BLOCK] tg:${id} bloqueado (verificado=${verificado})`);
        res.json({ ok: true, jid: 'tg:' + id, verificado });
    } catch (e) {
        console.error('[BLOCK] error:', e.message);
        res.status(500).json({ error: e.message });
    }
});

app.post('/watch/unblock', watchAuth, async (req, res) => {
    const jid = String((req.body && req.body.jid) || '').trim();
    if (!jid) return res.status(400).json({ error: 'Falta jid' });
    if (!isReady) return res.status(503).json({ error: 'Telegram no está vinculado' });
    const id = jid.startsWith('tg:') ? jid.slice(3) : jid;
    try {
        const entidad = await client.getInputEntity(id);
        await client.invoke(new Api.contacts.Unblock({ id: entidad }));
        try { fs.appendFileSync(AUDIT_FILE, `${new Date().toISOString()} watch unblock tg:${id}\n`); } catch (_) {}
        res.json({ ok: true, jid: 'tg:' + id });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

app.post('/watch/send', watchAuth, async (req, res) => {
    let jid = String((req.body && req.body.jid) || '').trim();
    const text = String((req.body && req.body.text) || '').trim();
    if (!jid || !text) return res.status(400).json({ error: 'Faltan jid y/o text' });
    if (text.length > 4096) return res.status(400).json({ error: 'Texto demasiado largo (máx 4096)' });
    if (!isReady) return res.status(503).json({ error: 'Telegram no está vinculado' });
    if (!puedeEnviar()) return res.status(429).json({ error: 'Límite de envíos alcanzado (20 / 10 min)' });
    const id = jid.startsWith('tg:') ? jid.slice(3) : jid;
    try {
        const enviado = await client.sendMessage(id, { message: text });
        envios.push(Date.now());
        try { fs.appendFileSync(AUDIT_FILE, `${new Date().toISOString()} watch send tg:${id} ${text.length} chars\n`); } catch (_) {}
        registrarMensaje(id, {
            id: enviado && enviado.id != null ? String(enviado.id) : null,
            fromMe: true, ts: Math.floor(Date.now() / 1000),
            text: text.slice(0, 1000), sender: 'yo'
        }, false, null);
        console.log(`[WATCH] enviado a tg:${id} (${text.length} chars)`);
        res.json({ ok: true, id: enviado && enviado.id != null ? String(enviado.id) : null });
    } catch (e) {
        console.error('[WATCH] error enviando:', e.message);
        res.status(500).json({ error: e.message });
    }
});

app.listen(PORT, () => console.log(`[HTTP] Puente Telegram escuchando en :${PORT}`));
arrancarCliente().catch(e => console.error('[FATAL]', e.message));
