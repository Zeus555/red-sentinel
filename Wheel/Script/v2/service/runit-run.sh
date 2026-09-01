#!/data/data/com.termux/files/usr/bin/sh
# Sentinel v2 - Servicio runit para nodos Android/Termux.
# Se instala en $PREFIX/var/service/sentinel-v2/run (755).
#
# runit lo relanza solo si muere: v2 NO necesita el watchdog por cron que tenia
# el v1 (Sentinel-Clone.sh cada minuto), porque ya no hay 20 procesos que vigilar
# ni puertos que reasignar. Un proceso, un supervisor.
#
# Toda la logica de arranque (token de flota, freno termico, purga) vive en el
# lanzador COMUN, que systemd usa igual en los nodos Ubuntu: asi las dos
# plataformas se comportan igual y no hay que arreglar nada dos veces.

exec 2>&1

# Suelo entre reintentos. runit relanza AL INSTANTE: sin esto, un fallo
# persistente (puerto ocupado, conf mala) da un bucle cerrado que calienta el
# telefono y llena el log.
sleep 2

exec sh "$HOME/PRC_Sentinel/v2/sentinel-start.sh"
