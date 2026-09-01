#!/data/data/com.termux/files/usr/bin/sh
exec 2>&1
cd /data/data/com.termux/files/home/Herramientas/Telegram_Bridge
exec /data/data/com.termux/files/usr/bin/node --max-old-space-size=192 server.js
