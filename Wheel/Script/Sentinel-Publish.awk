BEGIN{
	FS="|"
	OFS="\r\n"

	# Directorios de trabajo.
	DirRaiz="D:\\RED Sentinel\\Wheel\\"
	DirScript=DirRaiz "Script\\"
	DirTemporal=DirRaiz "Temporal\\"
	DirDatos=DirRaiz "Datos\\"
	DirLog=DirRaiz "Log\\"

	# Service of DB.
    ServiceDB ="sqlite3 \042" DirDatos "Hot.db\042 \042.timeout 15000\042 \042.mode list\042 "

	sql="select b.ip, b.netmask,b.public,b.so,b.wheel, group_concat(a.eye,',') as eyes from (select distinct eye from dwd_eyes where eye not in (select wheel from dwv_iswheel) order by eye) a, dwd_wheels b where b.wheel=b.ip;"
	cmd =ServiceDB "\042" sql "\042"
	print cmd
	while((cmd | getline)>0){
		IP=$1
		SUBNETMASK=$2
		IP_PUBLICA=$3
		OS=$4
		IPWheel=$5
		NetSentinel=$6
	}
	close(cmd)

	# Recorrer a quienes enviaremos la publicacion.
	split(NetSentinel,aEYES,",")
	PROCINFO["sorted_in"]="@val_num_asc"
	for(a in aEYES){
		# A quien se lo enviamos.
		IPv4=aEYES[a]
		gsub(/'/,"",IPv4)
		
		# En caso que sea WHEEL, no modificar.
		if (IPv4==IPWheel) continue
		
		data =sprintf("IP:'%s',NETMASK:'%s',PUBLIC:'%s',OS:'%s',WHEEL:'%s',NETSENTINEL:{%s}", IP, SUBNETMASK, IP_PUBLICA, OS, IPWheel, NetSentinel)

		# Enviar los datos a todos los EYES.
		cmdCurl="curl -s -X POST -d \042" data "\042 http://" IPv4 ":8081/addeye"
		#print cmdCurl
		while((cmdCurl | getline line) >0){
			print IPv4 " -> " line
		}
		close(cmdCurl)
	}
}