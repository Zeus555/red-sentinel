#!/bin/bash

# Directorios de trabajo.
DirRaiz="${HOME}/PRC_Sentinel/"
DirScript="${DirRaiz}Script/"
DirTemporal="${DirRaiz}Temporal/"
DirDatos="${DirRaiz}Datos/"
DirLog="${DirRaiz}Log/"

# Obtener la fecha de hoy.
Hoy=$(date +%Y%m%d)
IdExec=$(date +%s)

# Ficheros LOG.
FchStart="${DirLog}${Hoy}_Sentinel-Start.log"
FchServer="${DirLog}${Hoy}_Sentinel-Server.log"

# Difinir rango de puertos de ejecucion.
Port=8081
LastPort=8100

echo "[$(date '+%Y%m%d %H:%M:%S')][Sentinel Start] ... Start." >> "${FchStart}"

# Iniciar servicio SSH si no esta activo.
#nohup sshd -o "${FchStart}" &
#sshd

# Iniciar servicio CRONTAB si no esta activo.
#nohup crond -o "${FchStart}" &
#crond

# Version actual de sentinel.
# Version1=$(gawk -v CMD="CMD: Sentinel Version" -f "${DirScript}Sentinel-Client.awk")
Version1=$(curl -s http://localhost:${Port}/sentinelversion 2>&1)

# En caso no este en ejecucion, ejecutarlo en segundo plano.
if [ "$Version1" == "" ]; then
	echo "[$(date '+%Y%m%d %H:%M:%S')][Sentinel Start] ... Levantar servicio Sentinel." >> "${FchStart}"
	for (( i=${Port}; i<=${LastPort}; i+=1 )); do
		gawk -v Port=$i -v LastPort=${LastPort} -f "${DirScript}Sentinel-Server.awk" >> "${FchStart}" &
	done
else
	echo "[$(date '+%Y%m%d %H:%M:%S')][Sentinel Start] ... Reiniciando servicio Sentinel." >> "${FchStart}"
	for (( i=${Port}; i<=${LastPort}; i+=1 )); do
		curl -s http://localhost:${i}/sentinelshutdown 2>&1 >> "${FchStart}"
		gawk -v Port=$i -v LastPort=${LastPort} -f "${DirScript}Sentinel-Server.awk" >> "${FchStart}" &
	done
fi

Version1=$(curl -s http://localhost:${Port}/sentinelversion 2>&1)
echo "[$(date '+%Y%m%d %H:%M:%S')][Sentinel Start] ... Service up with version: $Version1." >> "${FchStart}"

fin=$(date +%s)
dif=$((${fin}-${IdExec}))

# Salimos reportando ejecución Ok
echo "[$(date '+%Y%m%d %H:%M:%S')][Sentinel Start] ... End ... Elapsed: ${dif}s." >> "${FchStart}"

exit 0
