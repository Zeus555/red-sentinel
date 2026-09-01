const express = require('express');
const qrcode = require('qrcode');
const pino = require('pino');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const {
    default: makeWASocket,
    useMultiFileAuthState,
    DisconnectReason,
    fetchLatestBaileysVersion,
    jidNormalizedUser,
    isJidGroup,
    isJidUser
} = require('@whiskeysockets/baileys');

const PORT = process.env.PORT || 8002;

let sock = null;
let isReady = false;
let lastQr = null;

// Configurar logger para silenciar logs excesivos de Baileys
const logger = pino({ level: 'warn' });

// ---- API para el reloj (PRC Watch) ------------------------------------------
// Cliente Wear OS 2 en la LAN. Token compartido en watch_token.txt (chmod 600),
// junto a este archivo; sin token el API responde 503 (cerrado por defecto).
// El almacén guarda solo los últimos mensajes por chat, en disco local del nodo
// (NUNCA en rqlite — misma decisión que con Sentinel SMS: el texto de los
// mensajes no se replica a la flota).
const TOKEN_FILE = path.join(__dirname, 'watch_token.txt');
let WATCH_TOKEN = '';
try { WATCH_TOKEN = fs.readFileSync(TOKEN_FILE, 'utf-8').trim(); } catch (_) {}

const STORE_FILE = path.join(__dirname, 'watch_store.json');
const AUDIT_FILE = path.join(__dirname, 'watch_audit.log');
const MAX_MSGS_POR_CHAT = 60;
const MAX_CHATS = 40;

let store = { chats: {}, contacts: {}, messages: {} };
try {
    if (fs.existsSync(STORE_FILE)) {
        const loaded = JSON.parse(fs.readFileSync(STORE_FILE, 'utf-8'));
        store.chats = loaded.chats || {};
        store.contacts = loaded.contacts || {};
        store.messages = loaded.messages || {};
        console.log(`[WATCH] almacén cargado: ${Object.keys(store.chats).length} chats`);
    }
} catch (e) { console.warn('[WATCH] no se pudo leer watch_store.json:', e.message); }

let storeTimer = null;
function saveStore() {
    clearTimeout(storeTimer);
    storeTimer = setTimeout(() => {
        try { fs.writeFileSync(STORE_FILE, JSON.stringify(store)); } catch (e) { console.warn('[WATCH] no se pudo guardar:', e.message); }
    }, 2000);
}

function tsNum(t) {
    if (typeof t === 'number') return t;
    if (t && typeof t.toNumber === 'function') return t.toNumber();
    const n = parseInt(String(t), 10);
    return isNaN(n) ? Math.floor(Date.now() / 1000) : n;
}

// Chats que no interesan en el reloj
function esJidIgnorado(jid) {
    return !jid || jid === 'status@broadcast' || jid.endsWith('@newsletter') || jid.endsWith('@broadcast');
}

function unwrap(m) {
    if (!m) return m;
    if (m.ephemeralMessage) return unwrap(m.ephemeralMessage.message);
    if (m.viewOnceMessage) return unwrap(m.viewOnceMessage.message);
    if (m.viewOnceMessageV2) return unwrap(m.viewOnceMessageV2.message);
    if (m.documentWithCaptionMessage) return unwrap(m.documentWithCaptionMessage.message);
    return m;
}

// Devuelve el texto a mostrar, o null si el mensaje no es representable (p.ej.
// reacciones y mensajes de protocolo, que no deben aparecer como burbuja).
function extraerTexto(message) {
    const m = unwrap(message);
    if (!m) return null;
    if (m.conversation) return m.conversation;
    if (m.extendedTextMessage && m.extendedTextMessage.text) return m.extendedTextMessage.text;
    if (m.imageMessage) return m.imageMessage.caption ? '📷 ' + m.imageMessage.caption : '📷 [imagen]';
    if (m.videoMessage) return m.videoMessage.caption ? '🎬 ' + m.videoMessage.caption : '🎬 [video]';
    if (m.audioMessage) return '🎤 [audio]';
    if (m.stickerMessage) return '[sticker]';
    if (m.documentMessage) return '📄 [' + (m.documentMessage.fileName || 'documento') + ']';
    if (m.locationMessage || m.liveLocationMessage) return '📍 [ubicación]';
    if (m.contactMessage || m.contactsArrayMessage) return '👤 [contacto]';
    if (m.pollCreationMessage) return '📊 ' + (m.pollCreationMessage.name || '[encuesta]');
    return null;
}

// Alias manuales: WhatsApp NO expone la agenda del teléfono, así que para los
// contactos sin nombre público este fichero es la única forma de ver un nombre
// en vez de un número. Formato: {"14085551234": "Mamá", "1203...@g.us": "Casa"}.
// Se relee en caliente (mtime) para poder editarlo sin reiniciar el servicio.
const ALIAS_FILE = path.join(__dirname, 'contactos.json');
let aliases = {};
let aliasMtime = 0;
function cargarAliases() {
    try {
        const st = fs.statSync(ALIAS_FILE);
        if (st.mtimeMs === aliasMtime) return;
        aliases = JSON.parse(fs.readFileSync(ALIAS_FILE, 'utf-8')) || {};
        aliasMtime = st.mtimeMs;
        console.log(`[ALIAS] ${Object.keys(aliases).length} nombres cargados`);
    } catch (_) { /* sin fichero: no pasa nada */ }
}
cargarAliases();
setInterval(cargarAliases, 30000);

function nombreDe(jid, fallback) {
    if (!jid) return '';
    // 1) Alias manual, por jid completo o por los dígitos del número.
    const digitos = String(jid).split('@')[0].replace(/[^0-9]/g, '');
    if (aliases[jid]) return aliases[jid];
    if (digitos && aliases[digitos]) return aliases[digitos];
    // 2) Nombre aprendido (pushName, título de grupo, sync de contactos).
    const c = store.chats[jid];
    if (c && c.name) return c.name;
    if (store.contacts[jid]) return store.contacts[jid];
    if (fallback) return fallback;
    // 3) Último recurso: el número, formateado para que se lea algo mejor.
    return digitos ? '+' + digitos : String(jid).split('@')[0];
}

// Los grupos llegan con un jid tipo 12036...@g.us y sin título: hay que pedirlo.
// Solo se consulta lo que falta, para no gastar llamadas de más.
async function resolverNombresGrupos() {
    if (!sock || !isReady) return;
    for (const jid of Object.keys(store.chats)) {
        if (!jid.endsWith('@g.us')) continue;
        if (store.chats[jid].name) continue;
        try {
            const meta = await sock.groupMetadata(jid);
            if (meta && meta.subject) {
                store.chats[jid].name = meta.subject;
                saveStore();
                console.log(`[GRUPO] ${jid} -> ${meta.subject}`);
            }
        } catch (e) {
            console.warn(`[GRUPO] no se pudo resolver ${jid}: ${e.message}`);
        }
    }
}

function registrarContacto(jid, name) {
    if (!jid || !name) return;
    store.contacts[jid] = name;
    saveStore();
}

function registrarMensaje(jid, entry, esEntrante, nombreChat) {
    if (esJidIgnorado(jid)) return;
    if (!store.chats[jid]) store.chats[jid] = { name: nombreChat || null, lastTs: 0, unread: 0 };
    const chat = store.chats[jid];
    if (nombreChat && !chat.name) chat.name = nombreChat;
    chat.lastTs = Math.max(chat.lastTs, entry.ts);
    chat.lastText = entry.text;
    chat.lastFromMe = !!entry.fromMe;
    if (esEntrante) chat.unread = (chat.unread || 0) + 1;

    if (!store.messages[jid]) store.messages[jid] = [];
    const arr = store.messages[jid];
    if (entry.id && arr.some(m => m.id === entry.id)) return; // dedupe (append + notify)
    arr.push(entry);
    arr.sort((a, b) => a.ts - b.ts);
    while (arr.length > MAX_MSGS_POR_CHAT) arr.shift();

    // Poda de chats viejos para que el almacén no crezca sin límite
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

function procesarMensajes(messages) {
    for (const msg of messages) {
        try {
            if (!msg.message) continue;
            const jid = msg.key.remoteJid || '';
            if (esJidIgnorado(jid)) continue;
            const texto = extraerTexto(msg.message);
            if (texto == null) continue;
            const fromMe = !!msg.key.fromMe;
            const esGrupo = jid.endsWith('@g.us');
            let sender = 'yo';
            if (!fromMe) {
                const pJid = esGrupo ? (msg.key.participant || '') : jid;
                sender = nombreDe(pJid, msg.pushName || null);
                if (msg.pushName) registrarContacto(pJid, msg.pushName);
            }
            registrarMensaje(jid, {
                id: msg.key.id || null,
                fromMe,
                ts: tsNum(msg.messageTimestamp),
                text: String(texto).slice(0, 1000),
                sender
            }, !fromMe, esGrupo ? null : (!fromMe && msg.pushName ? msg.pushName : null));
        } catch (e) { console.warn('[WATCH] error procesando mensaje:', e.message); }
    }
}

function watchAuth(req, res, next) {
    if (!WATCH_TOKEN) return res.status(503).json({ error: 'watch_token.txt no configurado en el servidor' });
    const t = Buffer.from(String(req.headers['x-watch-token'] || req.query.token || ''));
    const b = Buffer.from(WATCH_TOKEN);
    if (t.length !== b.length || !crypto.timingSafeEqual(t, b)) return res.status(401).json({ error: 'token inválido' });
    next();
}

// Límite de envíos: 20 por 10 minutos, y todo envío queda en watch_audit.log
const envios = [];
function puedeEnviar() {
    const corte = Date.now() - 600000;
    while (envios.length && envios[0] < corte) envios.shift();
    return envios.length < 20;
}
// -----------------------------------------------------------------------------

async function startSock() {
    console.log('[INIT] Inicializando cliente de WhatsApp (WebSockets)...');

    const { state, saveCreds } = await useMultiFileAuthState('auth_info_baileys');

    // Obtener la versión de WhatsApp Web más reciente para evitar error 405
    let version = [2, 3000, 1017531287]; // versión de respaldo
    try {
        const { version: latestVersion, isLatest } = await fetchLatestBaileysVersion();
        console.log(`[INIT] Usando versión de WhatsApp Web v${latestVersion.join('.')}. ¿Es la última?: ${isLatest}`);
        version = latestVersion;
    } catch (err) {
        console.warn('[INIT] Error consultando la versión web más reciente, usando versión por defecto:', err.message);
    }

    sock = makeWASocket({
        version,
        auth: state,
        logger: logger,
        browser: ['Ubuntu', 'Chrome', '20.0.04']
    });

    sock.ev.on('creds.update', saveCreds);

    // ---- Alimentación del almacén del reloj ----
    sock.ev.on('messages.upsert', ({ messages, type }) => {
        procesarMensajes(messages); // 'notify' y 'append' (offline)
        // Si llegó de un grupo que aún no tiene título, se resuelve ahora.
        if (messages.some(m => String(m.key && m.key.remoteJid || '').endsWith('@g.us'))) {
            resolverNombresGrupos().catch(() => {});
        }
    });
    sock.ev.on('messaging-history.set', ({ chats, contacts, messages }) => {
        try {
            (contacts || []).forEach(c => registrarContacto(c.id, c.name || c.notify || null));
            (chats || []).forEach(c => {
                if (esJidIgnorado(c.id) || !c.name) return;
                if (!store.chats[c.id]) store.chats[c.id] = { name: c.name, lastTs: tsNum(c.conversationTimestamp || 0), unread: 0 };
                else store.chats[c.id].name = c.name;
            });
            procesarMensajes(messages || []);
            console.log(`[WATCH] history sync: ${(chats || []).length} chats, ${(messages || []).length} mensajes`);
        } catch (e) { console.warn('[WATCH] error en history sync:', e.message); }
    });
    sock.ev.on('contacts.upsert', (cs) => (cs || []).forEach(c => registrarContacto(c.id, c.name || c.notify || null)));
    sock.ev.on('contacts.update', (cs) => (cs || []).forEach(c => registrarContacto(c.id, c.name || c.notify || null)));
    sock.ev.on('groups.upsert', (gs) => (gs || []).forEach(g => {
        if (!g.id || !g.subject) return;
        if (!store.chats[g.id]) store.chats[g.id] = { name: g.subject, lastTs: 0, unread: 0 };
        else store.chats[g.id].name = g.subject;
        saveStore();
    }));

    sock.ev.on('connection.update', (update) => {
        const { connection, lastDisconnect, qr } = update;

        if (qr) {
            lastQr = qr;
            isReady = false;
            console.log('[QR] Nuevo código QR generado. Escanéalo en: http://<host>:' + PORT + '/qr');
        }

        if (connection === 'close') {
            isReady = false;
            lastQr = null;
            const statusCode = lastDisconnect?.error?.output?.statusCode;
            const shouldReconnect = statusCode !== DisconnectReason.loggedOut;
            console.log(`[CONNECTION] Conexión cerrada. Código: ${statusCode}. Reconectando: ${shouldReconnect}`);

            if (shouldReconnect) {
                // Pequeño retardo antes de reconectar para evitar bucles rápidos
                setTimeout(startSock, 5000);
            } else {
                console.log('[CONNECTION] Dispositivo desvinculado. Esperando nuevo escaneo de QR.');
                // Volver a inicializar para poder escanear un nuevo QR
                setTimeout(startSock, 2000);
            }
        } else if (connection === 'open') {
            isReady = true;
            lastQr = null;
            console.log('[READY] WhatsApp conectado por WebSockets. Servicio listo en :' + PORT);
            // Los títulos de grupo no vienen con los mensajes: se piden aparte.
            setTimeout(() => { resolverNombresGrupos().catch(() => {}); }, 4000);
        }
    });
}

// Iniciar socket de WhatsApp
startSock().catch(err => console.error('[FATAL] Error iniciando socket:', err));

const app = express();
app.use(express.json());

// Endpoint de salud / estado
app.get('/', (req, res) => {
    res.json({ service: 'WhatsApp_Checker', ready: isReady, awaitingQr: !!lastQr, watch: { configurado: !!WATCH_TOKEN, chats: Object.keys(store.chats).length } });
});

// Renderizar código QR en formato PNG
app.get('/qr', async (req, res) => {
    if (isReady) return res.status(200).send('Ya está vinculado. No hay QR pendiente.');
    if (!lastQr) return res.status(503).send('QR aún no disponible, espera unos segundos y recarga.');
    try {
        const png = await qrcode.toBuffer(lastQr, { width: 350, margin: 2 });
        res.setHeader('Content-Type', 'image/png');
        res.send(png);
    } catch (e) {
        res.status(500).send('Error generando QR: ' + e.message);
    }
});

// Vinculación por código de 8 dígitos (Pairing Code)
app.get('/pair', async (req, res) => {
    const number = String(req.query.number || '').replace(/[^0-9]/g, '');
    if (isReady) return res.json({ status: 'already_linked' });
    if (!number) return res.status(400).json({ error: 'Falta ?number=<dígitos con código de país>' });
    try {
        if (!sock) throw new Error('Cliente de WhatsApp no inicializado.');
        const code = await sock.requestPairingCode(number);
        console.log('[PAIR] Código solicitado para ' + number + ': ' + code);
        res.json({
            number,
            pairingCode: code,
            instrucciones: 'WhatsApp -> Dispositivos vinculados -> Vincular con número de teléfono -> introduce este código.'
        });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

// Interfaz web para escaneo simple de QR
app.get('/scan', (req, res) => {
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    res.send(`<!doctype html><html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Vincular WhatsApp — WhatsApp_Checker</title>
<style>body{font-family:Segoe UI,Arial,sans-serif;text-align:center;padding:24px;color:#222}
img{border:1px solid #ccc;border-radius:8px;margin:12px}.ok{color:#128c5a;font-weight:bold;font-size:1.3rem}</style></head>
<body>
<h2>Vincular WhatsApp</h2>
<p id="st">Cargando QR…</p>
<img id="qr" width="350" height="350" alt="QR"/>
<p>En el teléfono: WhatsApp → <b>Dispositivos vinculados</b> → <b>Vincular un dispositivo</b> → escanea.</p>
<script>
async function tick(){
  try{
    const j = await (await fetch('/',{cache:'no-store'})).json();
    if(j.ready){document.getElementById('st').innerHTML='<span class="ok">✅ Vinculado y listo</span>';document.getElementById('qr').style.display='none';return;}
    if(j.awaitingQr){
      document.getElementById('st').textContent='Esperando escaneo… (el QR se renueva solo, no recargues)';
      document.getElementById('qr').src='/qr?t='+Date.now();
      document.getElementById('qr').style.display='inline';
    } else {
      document.getElementById('st').textContent='Cargando QR…';
      document.getElementById('qr').style.display='none';
    }
  }catch(e){document.getElementById('st').textContent='Error: '+e.message;}
  setTimeout(tick,5000);
}
tick();
</script></body></html>`);
});

// Endpoint compatible con el validador AWK
app.post('/checkNumberStatus', async (req, res) => {
    const contactId =
        (req.body && req.body.args && req.body.args.contactId) || (req.body && req.body.contactId) || '';
    const number = String(contactId).replace(/@c\.us$/i, '').replace(/[^0-9]/g, '');

    if (!isReady) {
        return res.status(503).json({ id: contactId, status: 503, error: 'WhatsApp no está listo (escanea el QR).' });
    }
    if (!number) {
        return res.status(400).json({ id: contactId, status: 400, error: 'contactId inválido.' });
    }

    try {
        // En baileys, onWhatsApp valida si el número existe y nos da su JID oficial
        const [result] = await sock.onWhatsApp(number);

        if (!result || !result.exists) {
            // Si el número no existe en WhatsApp, respondemos con status 404
            return res.json({ id: contactId, status: 404, isBusiness: false });
        }

        // Comprobamos si el JID corresponde a una cuenta Business
        let isBusiness = false;
        try {
            const profile = await sock.getBusinessProfile(result.jid);
            if (profile) {
                isBusiness = true;
            }
        } catch (_) {
            // getBusinessProfile puede fallar si no es business o no hay datos, lo ignoramos y dejamos isBusiness en false
        }

        // Estructura idéntica esperada por el parseador AWK:
        // La regex busca la secuencia exacta: c.us","status":200,"isBusiness
        return res.json({ id: contactId, status: 200, isBusiness, canReceiveMessage: true });
    } catch (e) {
        console.error('[ERROR] Error verificando número:', e.message);
        return res.status(500).json({ id: contactId, status: 500, error: e.message });
    }
});

// ---- Endpoints del reloj -----------------------------------------------------

app.get('/watch/health', watchAuth, (req, res) => {
    res.json({ ready: isReady, chats: Object.keys(store.chats).length, ts: Date.now() });
});

// Lista de chats recientes, más nuevo primero
app.get('/watch/chats', watchAuth, (req, res) => {
    const lista = Object.entries(store.chats)
        .map(([jid, c]) => ({
            jid,
            name: nombreDe(jid),
            lastText: c.lastText || '',
            lastTs: c.lastTs || 0,
            lastFromMe: !!c.lastFromMe,
            unread: c.unread || 0,
            group: jid.endsWith('@g.us')
        }))
        .sort((a, b) => b.lastTs - a.lastTs);
    res.json({ ready: isReady, chats: lista });
});

// Mensajes de un chat (ascendente). Resetea el contador local de no-leídos.
// NO envía confirmaciones de lectura a WhatsApp: el teléfono sigue mostrando
// el chat como no leído (decisión deliberada de privacidad).
app.get('/watch/messages', watchAuth, (req, res) => {
    const jid = String(req.query.jid || '');
    if (!jid || esJidIgnorado(jid)) return res.status(400).json({ error: 'Falta ?jid= válido' });
    const limit = Math.min(parseInt(req.query.limit, 10) || MAX_MSGS_POR_CHAT, MAX_MSGS_POR_CHAT);
    const msgs = (store.messages[jid] || []).slice(-limit);
    if (store.chats[jid]) { store.chats[jid].unread = 0; saveStore(); }
    res.json({ jid, name: nombreDe(jid), messages: msgs });
});

// Bandeja plana para el reloj: los mensajes recientes de TODOS los chats
// mezclados, más nuevo primero. El reloj los muestra de uno en uno, así que
// necesita la lista de mensajes, no la de conversaciones.
app.get('/watch/feed', watchAuth, (req, res) => {
    const limit = Math.min(parseInt(req.query.limit, 10) || 30, 100);
    const soloAjenos = req.query.mine === '0';
    const out = [];
    for (const jid of Object.keys(store.messages)) {
        if (esJidIgnorado(jid)) continue;
        for (const m of store.messages[jid]) {
            if (soloAjenos && m.fromMe) continue;
            out.push({
                id: m.id, jid, chatName: nombreDe(jid), fromMe: !!m.fromMe,
                ts: m.ts, text: m.text, sender: m.sender,
                group: jid.endsWith('@g.us'), service: 'whatsapp'
            });
        }
    }
    out.sort((a, b) => b.ts - a.ts);
    res.json({ ready: isReady, messages: out.slice(0, limit) });
});

// Marcar como leído SOLO en local: pone a cero el contador de este servidor.
// NO envía confirmación de lectura a WhatsApp — el remitente no ve el doble
// check azul (decisión explícita del usuario).
app.post('/watch/read', watchAuth, (req, res) => {
    const jid = String((req.body && req.body.jid) || '');
    if (!jid) return res.status(400).json({ error: 'Falta jid' });
    if (store.chats[jid]) { store.chats[jid].unread = 0; saveStore(); }
    res.json({ ok: true, solo_local: true });
});

/**
 * Bloquear a un remitente. Body: {jid}.
 *
 * Baileys 6.7.x NO valida ni normaliza nada: manda el jid crudo al servidor.
 * Por eso aquí se normaliza y se comprueba a mano antes de llamar, y después
 * se verifica contra la lista real de bloqueados — `updateBlockStatus` no
 * devuelve confirmación, así que sin ese repaso no se sabe si funcionó.
 *
 * Bloquear se propaga a la cuenta entera (también al teléfono del usuario) y
 * es reversible con action 'unblock'. Al bloqueado no le llega ningún aviso.
 */
app.post('/watch/block', watchAuth, async (req, res) => {
    let jid = String((req.body && req.body.jid) || '').trim();
    if (!jid) return res.status(400).json({ error: 'Falta jid' });
    if (!isReady) return res.status(503).json({ error: 'WhatsApp no está listo' });

    if (/^[0-9]+$/.test(jid)) jid = jid + '@s.whatsapp.net';

    // WhatsApp no permite bloquear grupos. La librería tampoco lo comprueba:
    // el servidor devolvería un error poco descriptivo.
    if (isJidGroup(jid)) {
        return res.status(400).json({ error: 'no_se_puede_bloquear_grupo' });
    }
    // Muchos chats llegan como @lid (identificador oculto) en vez de con el
    // número, y ahí es justo donde suele estar el spam. La propia lista de
    // bloqueados devuelve entradas @lid, así que el servidor los entiende:
    // se intenta igual y se comprueba el resultado, en vez de rechazarlos.
    const esLid = jid.endsWith('@lid');

    try {
        if (!esLid) {
            jid = jidNormalizedUser(jid);
            if (!isJidUser(jid)) return res.status(400).json({ error: 'jid inválido: ' + jid });
        }

        // Foto de la lista ANTES: `updateBlockStatus` no devuelve confirmación
        // y la lista guarda @lid, así que comparar por pertenencia no basta.
        let antes = [];
        try { antes = await sock.fetchBlocklist() || []; } catch (_) {}

        await sock.updateBlockStatus(jid, 'block');

        let verificado = false;
        try {
            const despues = await sock.fetchBlocklist() || [];
            verificado = despues.includes(jid) || despues.length > antes.length;
        } catch (e) {
            console.warn('[BLOCK] no se pudo verificar la lista:', e.message);
        }

        try { fs.appendFileSync(AUDIT_FILE, `${new Date().toISOString()} watch block ${jid} verificado=${verificado}\n`); } catch (_) {}
        console.log(`[BLOCK] ${jid} bloqueado (verificado=${verificado})`);
        res.json({ ok: true, jid, verificado });
    } catch (e) {
        console.error('[BLOCK] error:', e.message);
        res.status(500).json({ error: e.message });
    }
});

// Deshacer un bloqueo. Mismo método con action 'unblock'.
app.post('/watch/unblock', watchAuth, async (req, res) => {
    let jid = String((req.body && req.body.jid) || '').trim();
    if (!jid) return res.status(400).json({ error: 'Falta jid' });
    if (!isReady) return res.status(503).json({ error: 'WhatsApp no está listo' });
    if (/^[0-9]+$/.test(jid)) jid = jid + '@s.whatsapp.net';
    try {
        jid = jidNormalizedUser(jid);
        await sock.updateBlockStatus(jid, 'unblock');
        try { fs.appendFileSync(AUDIT_FILE, `${new Date().toISOString()} watch unblock ${jid}\n`); } catch (_) {}
        res.json({ ok: true, jid });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

// Lista de bloqueados, para poder comprobarla desde fuera.
app.get('/watch/blocklist', watchAuth, async (req, res) => {
    if (!isReady) return res.status(503).json({ error: 'WhatsApp no está listo' });
    try {
        res.json({ bloqueados: await sock.fetchBlocklist() });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

// Enviar texto. Body: {jid, text}. jid puede ser dígitos pelados (se normaliza).
app.post('/watch/send', watchAuth, async (req, res) => {
    let jid = String((req.body && req.body.jid) || '').trim();
    const text = String((req.body && req.body.text) || '').trim();
    if (!jid || !text) return res.status(400).json({ error: 'Faltan jid y/o text' });
    if (text.length > 4096) return res.status(400).json({ error: 'Texto demasiado largo (máx 4096)' });
    if (/^[0-9]+$/.test(jid)) jid = jid + '@s.whatsapp.net';
    if (!/@(s\.whatsapp\.net|g\.us|lid)$/.test(jid)) return res.status(400).json({ error: 'jid inválido' });
    if (!isReady) return res.status(503).json({ error: 'WhatsApp no está listo' });
    if (!puedeEnviar()) return res.status(429).json({ error: 'Límite de envíos alcanzado (20 / 10 min)' });
    try {
        const result = await sock.sendMessage(jid, { text });
        envios.push(Date.now());
        try { fs.appendFileSync(AUDIT_FILE, `${new Date().toISOString()} watch send ${jid} ${text.length} chars\n`); } catch (_) {}
        registrarMensaje(jid, {
            id: (result && result.key && result.key.id) || null,
            fromMe: true,
            ts: Math.floor(Date.now() / 1000),
            text: text.slice(0, 1000),
            sender: 'yo'
        }, false, null);
        console.log(`[WATCH] enviado a ${jid} (${text.length} chars)`);
        res.json({ ok: true, id: (result && result.key && result.key.id) || null });
    } catch (e) {
        console.error('[WATCH] error enviando:', e.message);
        res.status(500).json({ error: e.message });
    }
});

app.listen(PORT, () => {
    console.log(`[HTTP] Escuchando en :${PORT}`);
});
