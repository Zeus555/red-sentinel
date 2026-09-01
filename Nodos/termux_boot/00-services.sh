#!/data/data/com.termux/files/usr/bin/sh
# Arranque automatico tras reboot del telefono (Termux:Boot) - 2026-07-05
# 1. wake-lock para que Android no duerma los procesos.
# 2. sshd y crond arrancan directo (tienen archivo down en runit).
# 3. service-daemon levanta runsvdir -> rqlited, whatsapp_checker y telegram_bridge.
termux-wake-lock
pgrep -x sshd >/dev/null || sshd
pgrep -x crond >/dev/null || crond
. /data/data/com.termux/files/usr/etc/profile.d/start-services.sh
