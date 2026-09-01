const express = require('express');
const qrcode = require('qrcode');
const pino = require('pino');
const {
    default: makeWASocket,
    useMultiFileAuthState,
    DisconnectReason,
    fetchLatestBaileysVersion
} = require('@whiskeysockets/baileys');

const PORT = process.env.PORT || 8002;

let sock = null;
let isReady = false;
let lastQr = null;

// Configurar logger para silenciar logs excesivos de Baileys
const logger = pino({ level: 'warn' });

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
        }
    });
}

// Iniciar socket de WhatsApp
startSock().catch(err => console.error('[FATAL] Error iniciando socket:', err));

const app = express();
app.use(express.json());

// Endpoint de salud / estado
app.get('/', (req, res) => {
    res.json({ service: 'WhatsApp_Checker', ready: isReady, awaitingQr: !!lastQr });
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

app.listen(PORT, () => {
    console.log(`[HTTP] Escuchando en :${PORT}`);
});
