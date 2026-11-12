#!/data/data/com.termux/files/usr/bin/sh
# Servicio runit: $PREFIX/var/service/whatsapp_checker/run (desplegado 2026-07-05; hoy corre en sentinel005)
# --env-file carga el .env (GEMINI_API_KEY, OWNER_NUMBER, RQLITE_USER/RQLITE_PASSWORD...): sin el, el
# chatbot arranca sin claves. Igual que el run desplegado (comprobado el 2026-11-11).
# Log: $PREFIX/var/service/whatsapp_checker/log/run -> svlogd -tt $PREFIX/var/log/sv/whatsapp_checker
exec 2>&1
cd /data/data/com.termux/files/home/Herramientas/WhatsApp_Checker
exec /data/data/com.termux/files/usr/bin/node --env-file=.env server.js
