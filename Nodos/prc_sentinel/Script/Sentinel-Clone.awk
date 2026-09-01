function GetCloneStatus(xP,lP){
	FS="\n"
	RS="^$"
	for (i=xP;i<=lP;i++){
		# Comando a consultar version.
		cmd="curl -w \042%{time_total}\\n\042 -s --connect-timeout 0.325 --max-time 0.35 http://localhost:" i "/sentinelversion"
		if (OS=="Windows"){ cmd=cmd " 2>&1 >Nul" } else { cmd=cmd " 2>&1 >dev/null" }

		# Estado por defecto.
		CloneStatus[i]="Error"
		while((cmd | getline)>0){
			if ($1~/Sentinel/){
				CloneStatus[i]="Ok"
			} else {
				CloneStatus[i]="Error"
			}

			# Tiempo al obtener una respuesta.
			aCurlTiming[i]=$2
		}
		close(cmd)
	}
	RS="\r\n"
}

function GetProcessWin(){
	if (OS=="Windows"){
		cmd="Wmic process where \042(commandline like '%gawk%Port%Sentinel%')\042 get creationdate, commandline, processid, parentprocessid /format:csv"
		FS=","
		RS="\r\n"
		while((cmd | getline)>0){
			pid =$5
			n =match($2,/gawk.+ Port=([0-9]+) -v LastPort.+/,aField)
			if (n>0){
				cmdPort =aField[1]
				if (cmdPort in aProcess){
					printf "... duplicado: %s %s\n", cmdPort, pid
					aProcDuplic[pid]++
				} else {
					aProcess[cmdPort]=pid
				}
			} #else { printf "No coincide:'%s'\n", $0 }
		} close(cmd)
	} else {
		cmd="ps -fea"
		FS=" "
		RS="\n"
		while((cmd | getline)>0){
			pid = OS=="Tiny" ? $1 : $2
			rPort= OS=="Tiny" ? $5 : $10
			n =match(rPort,/^Port.([0-9]+)$/,aField)
			if (n>0){
				cmdPort =aField[1]
				if (cmdPort in aProcess){
					printf "... duplicado: %s %s\n", cmdPort, pid
					aProcDuplic[pid]++
				} else {
					aProcess[cmdPort]=pid
				}
			}
		} close(cmd)
	}
}

function LoadWorkDir(){
	# Validar que sistema operativo esta en ejecucion.
	cmd="uname -a 2>&1"
	cmd | getline OS
	if (OS~/Android/){
		OS="Termux"
	} else if (OS~/Ubuntu/){
		OS="Ubuntu"
	} else if (OS~/Raspbian/){
		OS="Raspberry"
	} else if (OS~/tinycore/){
		OS="Tiny"
	} else {
		OS="Windows"
	}

	# Obtener el directorio actual o directorio de ejecucion.
	if (OS=="Windows"){
		cmd="cd"
	} else {
		cmd="pwd"
	}
	cmd | getline CurrentDir
	close(cmd)


	# Directorios de trabajo segun el SO.
	# Del directorio actual obtener el nombre de cada una de sus carpetas que lo componen.
	n=0
	if (OS=="Windows"){
		n=split(CurrentDir, aCrrDir, "\\")
		for (i=1;i<n;i++){	DirRaiz=i==1 ? aCrrDir[i] : DirRaiz "\\" aCrrDir[i] }
		# Directorios de trabajo.
		DirScript=DirRaiz "\\Script\\"
		DirTemporal=DirRaiz "\\Temporal\\"
		DirDatos=DirRaiz "\\Datos\\"
		DirRun=DirRaiz "\\Run\\"
		DirLog=DirRaiz "\\Log\\"
	} else {
		n=split(CurrentDir, aCrrDir, "/")
		for (i=1;i<n;i++){	DirRaiz=i==1 ? aCrrDir[i] : DirRaiz "/" aCrrDir[i] }
		# Directorios de trabajo.
		DirScript=DirRaiz "/Script/"
		DirTemporal=DirRaiz "/Temporal/"
		DirDatos=DirRaiz "/Datos/"
		DirRun=DirRaiz "/Run/"
		DirLog=DirRaiz "/Log/"
	}
}

function kill(xpid){
	if (OS=="Windows"){
		cmd="start \042\042 /B TASKKILL /F /T /PID " xpid " 2>&1"
	} else {
		cmd="kill " xpid " 2>&1 &"
	}
	xn=system(cmd); close(cmd)
	return xn
}

function GetListClone(){
	RSOLD=RS
	FSOLD=FS
	FS=" "
	RS=";"
	cmd="curl -s http://localhost:8081/listclone?out=csv"
	while((cmd | getline)>0){
		CloneElapsed[$1]=systime()-$3
		if ($2==0) CloneAvailable[$1]=$2
	}
	RS=RSOLD
	FS=FSOLD
}

BEGIN{
	# Rango de puertos a verificar.
	Port=8081
	LastPort=8100

	# Obtener los directorios de trabajo.
	LoadWorkDir()

	# Obtiene lista de procesos del SO.
	GetProcessWin()

	# Eliminar procesos de Clones duplicados para un mismo Clone.
	for (a in aProcDuplic){
		print a, aProcDuplic[a]
		kill(a)
	}

	# Obtiene estado de clones.
	GetCloneStatus(Port, LastPort)

	# Obtiene estado de clones del EYE.
	GetListClone()

	PROCINFO["sorted_in"] ="@ind_num_asc"
	# Recorrer cada uno de los Clones.
	for (b in CloneStatus){
		CouTot++
		ss=0
		# En caso que un clone sobrepase el timeout y este no este en ejecucion, volvemos a ejecutarlo.
		stClone=CloneStatus[b]
		enProcess=b in aProcess ? 1 : 0
		pid=aProcess[b]
		esAvailable=b in CloneAvailable ? 1 : 0
		elap=CloneElapsed[b]
		if (stClone=="Error" && enProcess==0) ss=1
		# En caso que el estado del Clone(que no sea el EYE) en lista este disponible, pero dio timeout al consultarlo, volver a ejecutarlo.
		if (stClone=="Error" && esAvailable==0 && b!=Port) ss=2
		# En caso que el Clone tenga mas de 5 minutos ejecutandose.
		if (elap>=300){
			ss=3
			kill(pid) # Eliminar el proceso del Clone colgado.
		}

		# Volver a ejecutarlos.
		if (ss>0){
			CouErr++
			print CouErr, b, ss
			if (OS=="Windows"){
				#cmd="start \042\042 /B gawk -v Port=" b " -v LastPort=" LastPort " -f \042" DirScript "Sentinel-Server.awk\042 2>&1 >nul"
				cmd="start \042\042 /B gawk -v Port=" b " -v LastPort=" LastPort " -f \042" DirScript "Sentinel-Server.awk\042 2>&1 >\042" DirLog "Sentinel_" b ".log\042"
			} else {
				#cmd="gawk -v Port=" b " -v LastPort=" LastPort " -f \042" DirScript "Sentinel-Server.awk\042 2>&1 >/dev/null &"
				cmd="gawk -v Port=" b " -v LastPort=" LastPort " -f \042" DirScript "Sentinel-Server.awk\042 2>&1 >" DirLog "Sentinel_" b ".log &"
			}
			system(cmd); close(cmd)

			# Habilitar el estado del clone en el EYE.
			cmd="curl -s --connect-timeout 0.900 --max-time 1 http://localhost:" Port "/enableclone/" b
			if (OS=="Windows"){ cmd=cmd " 2>&1 >nul" } else { cmd=cmd " 2>&1 >/dev/null" }
			system(cmd); close(cmd)
		}
	}
	CouErr =CouErr +0
	printf "CouTot:%s CouErr:%s\n", CouTot, CouErr
	exit 0
}
