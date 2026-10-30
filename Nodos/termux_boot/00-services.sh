#!/data/data/com.termux/files/usr/bin/sh
# Arranque automatico tras reboot del telefono (Termux:Boot) - 2026-07-05
# 1. wake-lock para que Android no duerma los procesos.
# 2. sshd y crond arrancan directo (tienen archivo down en runit).
# 3. service-daemon levanta runsvdir -> rqlited, whatsapp_checker y telegram_bridge.
termux-wake-lock
pgrep -x sshd >/dev/null || sshd
# crond hereda su entorno a los trabajos. Sin termux-exec precargado los scripts
# con "#!/usr/bin/env sh" fallan con "not found" (en Termux no existe /usr/bin/env)
# y la eleccion, las alertas y el vigilante dejan de correr tras cada reinicio.
TE=/data/data/com.termux/files/usr/lib/libtermux-exec-ld-preload.so
[ -f "$TE" ] || TE=/data/data/com.termux/files/usr/lib/libtermux-exec.so
pgrep -x crond >/dev/null || LD_PRELOAD="$TE" crond
. /data/data/com.termux/files/usr/etc/profile.d/start-services.sh
