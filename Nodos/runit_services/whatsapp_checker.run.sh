#!/data/data/com.termux/files/usr/bin/sh
# Servicio runit: $PREFIX/var/service/whatsapp_checker/run (solo sentinel001, desplegado 2026-07-05)
# Log: $PREFIX/var/service/whatsapp_checker/log/run -> svlogd -tt $PREFIX/var/log/sv/whatsapp_checker
exec 2>&1
cd /data/data/com.termux/files/home/Herramientas/WhatsApp_Checker
exec /data/data/com.termux/files/usr/bin/node server.js
