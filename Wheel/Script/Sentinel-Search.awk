function SearchForSentinel(vIP,vNetMask,vSO){
	if (vNetMask=="255.255.255.0"){
		couSentinel=0;IPWheel=""

		for (i=1;i<=255;i++){
			# Registros por defecto.
			split(vIP,aIP,".")
			IP_SEARCH= aIP[1] "." aIP[2] "." aIP[3] "." i

			cmd="curl -s --max-time 0.5 http://" IP_SEARCH ":8081/sentinelversion"
			# PROCINFO[cmd,"READ_TIMEOUT"]=100
			while((cmd | getline line) >0){
				couSentinel++
				aSentinel[IP_SEARCH]=line
				if (line~/.\042Version\042: \042Sentinel Super .+\042./){
					IPWheel =IP_SEARCH
					printf "\r %s with Sentinel eyes (Wheel).           \n", IP_SEARCH
				} else {
					printf "\r %s with Sentinel eyes.                   \n", IP_SEARCH
				}
			}

			#if (i==254){
			#	printf "\r ... %s scanned for Sentinel eyes.", i
			#} else {
			#	printf "\r ... %s scanning for Sentinel eyes.", i
			#}
		}
		printf "\n"
	}

	return sprintf("%s/%s",couSentinel,IPWheel)
}

function SearchIPsRed(vIP,vNetMask,vSO){
	if (vNetMask=="255.255.255.0"){
		coured=0

		for (i=1;i<255;i++){
			# Registros por defecto.
			split(vIP,aIP,".")
			IP_SEARCH= aIP[1] "." aIP[2] "." aIP[3] "." i

			if (vSO=="Windows"){
				cmd="ping -n 1 -l 32 -w 1 " IP_SEARCH
			} else {
				cmd="ping -c 1 -s 32 -W 1 " IP_SEARCH
			}

			# Leemos la respuesta linea a linea.
			send=0
			PROCINFO[cmd,"READ_TIMEOUT"]=100
			while ((cmd | getline xline) >0){
				if (vSO=="Windows" && xline~/Packets: Sent . 1, Received . 1, Lost . 0 .0. loss../) send=1
				if (vSO=="Termux" && xline~/1 packets transmitted, 1 received, 0. packet loss, time.+ms/) send=1
				# if (vSO=="Termux") print send, xline
			}
			close(cmd)

			# Guardar todos los ip encontrados en la red.
			if (send ==1){
				coured++
				aSearchInNet[IP_SEARCH]++
				printf "\r %s active                           \n", IP_SEARCH
			}

			#if (i % 10 == 0)
			printf "\r ... %s scanned for active addresses.", i
		}
		printf "\n"
	}

	return coured
}

function GetIPsAvailable(vSO){
	cmd="arp -a 2>&1"
	while((cmd | getline line) >0){
		couIPsAvail++
		n= match(line,/([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}).+(.{2}-.{2}-.{2}-.{2}-.{2}-.{2}).+((static)|(dynamic))/,aField)
		if (n>0){
			vIP =aField[1]
			vMAC =aField[2]
			vTYPE =aField[3]
			aIPsAvail[vIP]=vMAC OFS vTYPE
		}
	}
	close(cmd)
	return couIPsAvail
}

function GetIP(vSO){
	# Obtener IP publica, tanto en Windows como en Termux.
	cmd="curl -s ifconfig.me"
	while((cmd | getline line) > 0){
		IP_Publica=line
	}
	close(cmd)

	# Leemos la respuesta linea a linea.
	cmd="";line="";IP="";n=0;SUBNETMASK=""

	if (vSO=="Windows"){
		cmd="ipconfig 2>&1"
	} else {
		cmd="ifconfig 2>&1"
	}

	PROCINFO[cmd,"READ_TIMEOUT"]=100
	while ((cmd | getline line) > 0){
		if (vSO=="Windows"){
			n= match(line,/IPv4 Address. . . . . . . . . . . : (.+)/,aField)
			if (n>0){
				IP =aField[1]
			}

			m= match(line,/Subnet Mask . . . . . . . . . . . : (.+)/,aField)
			if (m>0){
				SUBNETMASK =aField[1]
			}
		} else {
			n= match(line,/inet addr:(.+) Bcast:.+Mask:(.+)/,aField)
			if (n==0){ n= match(line,/inet (.+)  netmask (.+)  broadcast.+/,aField) }
			if (n>0){
				IP =aField[1]
				SUBNETMASK =aField[2]
			}
		}
	}
	close(cmd)

	return sprintf("%s/%s/%s",IP,SUBNETMASK,IP_Publica)
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

function UpdateProfile(xVar,xVal){
	if (OS=="Windows"){
		for (a in aProfile){
			xVar=a
			xVal=aProfile[a]
			cmd="setx " xVar " \042" xVal "\042 >Nul"
			system(cmd);close(cmd)
		}
	} else {
		# Validar si existe la variable de entorno en el perfil.
		RSOLD=RS
		ORSOLD=ORS
		RS="\n"
		ORS=RS
		Home=ENVIRON["HOME"]

		# Fichero con variables de entorno.
		FchProfile=Home "/.profile"
		FchNewProfile=DirTemporal "profile_" systime() ".txt"

		xExiste=0;xRowNum
		while((getline < FchProfile)>0){
			n=match($0, "export (.+)=\042(.?*)\042", aField)
			if (n >0){
				xVar=aField[1]
				xVal=aField[2]
				aProfileIdx[xVar]=1
				
				if (xVar in aProfile){
					aProfileIdx[xVar]=2
					xVal=aProfile[xVar]
					print "export " xVar "=\042" xVal "\042" >> FchNewProfile
				} else {
					print $0 >> FchNewProfile
				}
			} else {
				print $0 >> FchNewProfile
			}
		}
		close(FchProfile)

		# Si no existe variable de ambiente la insertamos al final del archivo.
		for(z in aProfile){
			if (z in aProfileIdx){  } else {
				print "export " z "=\042" aProfile[z] "\042" >> FchNewProfile
			}
		}
		close(FchNewProfile)	

		# Reescribir perfil.
		cmd="mv \042" FchNewProfile "\042 \042" FchProfile "\042"
		system(cmd);close(cmd)

		RS=RSOLD
		ORS=ORSOLD
	}
}

# Obtiene el UserAgent correspondiente al ultimo disponible.
function GetUserAgent(){
	cmd="curl -s http://" IpWheel ":8081/useragent"
	resp=""
	cmd | getline xUserAgent
	close(cmd)

	n=match(xUserAgent,/.\042UserAgent\042: \042(.+)\042./, aField)
	if (n>0){
		resp=aField[1]
	}

	return resp
}

BEGIN {
	FS=","
	OFS=";"

	# Obtener los directorios de trabajo.
	LoadWorkDir()

	# En caso que no este levantado el servicio.
	ServiceActive=0
	cmd="curl -s --max-time 0.5 http://127.0.0.1:8081/sentinelversion"
	while((cmd | getline line) >0){
		if(line~/Sentinel.+/){ ServiceActive=1 }
	}
	close(cmd)

	# Levantar servicio, en caso no este levantado el servicio.
	if (ServiceActive==0){
		if (OS~/Windows/){
			cmd1="start \042\042 /B gawk -v Port=8081 -v LastPort=8100 -f \042" DirScript "Sentinel-Server.awk\042 2>&1 >\042" DirLog "Sentinel_8081.log\042"
			system(cmd1)
			close(cmd1)
		} else {
			cmd1="gawk -v Port=8081 -v LastPort=8100 -f \042" DirScript "Sentinel-Server.awk\042 2>&1 >\042" DirLog "Sentinel_8081.log\042 &"
			system(cmd1)
			close(cmd1)			
		}
	}

	# Service of DB.
    ServiceDB ="sqlite3 \042" DirDatos "Hot.db\042 \042.timeout 15000\042 "

	# Obtener el nombre del SO.
	print "OS: " OS

	# Obtener variable de ambiente del nombre de la device de la red sentinel,
	# esta variable esta configurada manualmente en cada una de las device.
	NAME=ENVIRON["Name"]

	# Obtener la IP desde el SO.
	IDRED =GetIP(OS)

	split(IDRED,aRed,"/")
	IP =aRed[1]
	SUBNETMASK =aRed[2]
	IP_PUBLICA =aRed[3]
	printf "ip: %s name: %s netmask: %s public: %s\n", IP, NAME, SUBNETMASK, IP_PUBLICA

	IDSentinel =SearchForSentinel(IP,SUBNETMASK,SO)
	split(IDSentinel,aField,"/")
	CntNodosSentinel =aField[1]
	IpWheel =aField[2]
	
	printf "IpWheel: %s\n", IpWheel
	printf "%s Sentinel eyes found.\n", CntNodosSentinel
	for (a in aSentinel){
		NetSentinel= NetSentinel "'" a "',"
	}
	# Eliminar la ultima coma de la lista.
	sub(/,$/,"",NetSentinel)

	data="IP:'" IP "',NAME:'" NAME "',NETMASK:'" SUBNETMASK "',PUBLIC:'" IP_PUBLICA "',OS:'" OS "',WHEEL:'" IpWheel "',NETSENTINEL:{" NetSentinel "}"
	cmd="curl -s -X POST -d \042" data "\042 http://" IpWheel ":8081/addeye"
	while((cmd | getline line) >0){
		print line
	}
	close(cmd)
	
	# Obtener el UserAgent que usaremos.
	UserAgent=GetUserAgent()

	# Actualizar variable de ambiente.
	aProfile["IpWheel"]=IpWheel
	aProfile["OS"]=OS
	aProfile["PathSentinel"]=DirRaiz
	aProfile["MyIP"]=IP
	aProfile["UserAgent"]=UserAgent
	# if (OS~/Ubuntu/){
	# 	# Obtener el nodoname
	# 	cmd="uname -n"
	# 	while((cmd | getline)>0) Name=$0
	# 	close(cmd)
	# 	if (length(Name)>0) aProfile["Name"]=Name
	# }
	# if (OS~/Windows/){
	# 	# Obtener el nombre de la pc.
	# 	cmd="echo %COMPUTERNAME%"
	# 	while((cmd | getline)>0) Name=$0
	# 	close(cmd)
	# 	if (length(Name)>0) aProfile["Name"]=Name
	# }
	UpdateProfile()

	# Fichero temporal SQL;
	gsub(/'/,"",NetSentinel)
	split(NetSentinel,aNetSent,",")
	FchSQL= DirTemporal "SentinelSearch_"strftime("%G%m%d_%H%M%S") ".sql"
	print "BEGIN TRANSACTION;" > FchSQL
	printf "delete from dwd_wheels where ip='%s';\n", IP >> FchSQL
	printf "delete from dwd_eyes where ip='%s';\n", IP >> FchSQL
	printf "insert into dwd_wheels(ip,sentinelname,netmask,public,so,wheel) values ('%s','%s','%s','%s','%s','%s');\n", IP, NAME, SUBNETMASK, IP_PUBLICA, OS, IpWheel >> FchSQL
	for (a in aNetSent){
		printf "insert into dwd_eyes(IP,EYE) values ('%s','%s');\n", IP, aNetSent[a] >> FchSQL
	}
	print "COMMIT;" >> FchSQL
	close(FchSQL) # Espera a que termine de escribir el fichero y libera cuando el fichero esta disponible para lectura.

	# Actualizar la BD con Wheels y Eyes en segundo plano.
	if (OS=="Windows"){
		cmd ="start \042\042 /B " ServiceDB "\042.read '" FchSQL "'\042"
	} else {
		cmd =ServiceDB "\042.read '" FchSQL "'\042 &"
	}
	system(cmd);close(cmd)			
}
