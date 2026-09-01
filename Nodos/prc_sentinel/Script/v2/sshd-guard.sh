#!/data/data/com.termux/files/usr/bin/sh
# Sentinel v2 - Guardian del acceso SSH (nodos Termux).
#
# POR QUE EXISTE: sshd es el UNICO servicio de estos nodos que nadie supervisa.
# Lleva fichero 'down' en runit y lo arranca directamente el script de arranque,
# asi que cuando muere no lo levanta nadie. sentinel019 ya perdio SSH dos veces y
# la segunda hubo que arrancarlo a mano desde el telefono.
#
# POR QUE NO BASTABA LO QUE HABIA: el arranque usaba
#     pgrep -x sshd >/dev/null || sshd
# y en Android 10+ `pgrep`, `ps` y `netstat` devuelven respuestas FALSAS a las
# apps sin privilegios. Preguntar "hay un proceso sshd?" no sirve en esta flota.
#
# QUE HACE DISTINTO: pregunta por el PUERTO, que es lo unico que no miente. Y lo
# pregunta CONECTANDOSE de verdad, no leyendo tablas del kernel: en este Pixel
# /proc/net/tcp da "Permission denied" (Android lo bloquea a las apps sin
# privilegios), asi que la via documentada de leer la tabla TCP no sirve aqui.
# Se usa /dev/tcp de bash, que es una prueba funcional y no depende de permisos.
# Si nadie acepta conexiones, arranca sshd. Si ya las acepta, no hace nada.
#
# NO TOCA RUNIT a proposito. Es una red de seguridad puramente aditiva: no cambia
# el estado de ningun servicio supervisado, asi que no puede dejar el nodo peor de
# como estaba. Si algun dia sshd pasa a estar bajo runit, este script sigue siendo
# correcto (vera el puerto ocupado y saldra sin hacer nada).
#
# CUIDADO AL LLAMARLO DESDE EL AGENTE: el worker lee la salida del comando por una
# tuberia (`command | getline`). Un demonio que herede stdout deja la tuberia
# abierta y el job se cuelga PARA SIEMPRE, ocupando una ranura de MAXJOBS. Por eso
# sshd se lanza con los tres descriptores redirigidos.
#
# Invocacion: por cron cada minuto.
#   * * * * * /data/data/com.termux/files/usr/bin/sshd-guard >/dev/null 2>&1
set -u

PX=/data/data/com.termux/files/usr
export PATH="$PX/bin:$PATH"
LOG="$PX/var/log/sshd-guard.log"

# El puerto sale de sshd_config. Si no hay directiva Port —que es el caso en toda
# esta flota— Termux usa 8022. Se deduce en vez de fijarlo para que el guardian
# siga siendo correcto si algun dia se cambia el puerto de un nodo.
PUERTO=$(grep -iE "^[[:space:]]*Port[[:space:]]+[0-9]+" "$PX/etc/ssh/sshd_config" 2>/dev/null | head -1 | tr -dc "0-9")
[ -n "$PUERTO" ] || PUERTO=8022

# Unica fuente de verdad: .acepta alguien conexiones en el 8022?
# Prueba funcional con /dev/tcp (bash). NO usar /proc/net/tcp: Android lo bloquea.
# NO usar pgrep/ps/netstat: mienten en estos telefonos.
escucha() {
	timeout 4 "$PX/bin/bash" -c "exec 3<>/dev/tcp/127.0.0.1/$PUERTO" >/dev/null 2>&1
}

anota() {
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG" 2>/dev/null
	# Diario, no auditoria: con las ultimas 200 lineas sobra.
	if [ -f "$LOG" ]; then
		tail -n 200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
	fi
}

if escucha; then
	echo "ok: sshd ya escucha en 8022"
	exit 0
fi

# Descriptores redirigidos: si no, un sshd demonizado hereda la tuberia del worker
# y cuelga el job del agente.
"$PX/bin/sshd" </dev/null >/dev/null 2>&1
sleep 3

if escucha; then
	anota "sshd no escuchaba; arrancado por sshd-guard"
	echo "rescatado: sshd arrancado"
	exit 0
fi

anota "FALLO: sshd sigue sin escuchar tras intentar arrancarlo"
echo "FALLO: sshd sigue sin escuchar"
exit 1
