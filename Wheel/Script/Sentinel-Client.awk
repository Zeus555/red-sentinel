BEGIN {
	# Registros por defecto.
	IP_DEST=length(IP_DEST)==0 ? "localhost" : IP_DEST
	Port=length(Port)==0 ? 8081 : Port
	Tout=length(Tout)==0 ? 0 : Tout
	isImg=0

	while (1==1){
		# Servicio web a consumir.
		Service="/inet4/tcp/0/" IP_DEST "/" Port

		# Validar si es una imagen.
		if (tolower(CMD)~/\.(jpg|png|ico)/)	isImg=1

		PROCINFO[Service, "READ_TIMEOUT"]=Tout
		print CMD "\r\n" |& Service

		# Leemos la respuesta linea a linea.
		rStatus=0
		if (isImg==1){RS="^$"}else{RS="\n"}
		while ((Service |& getline line) > 0){
			# Redireccion a otro Clone para linea de comando.
			if (line~/^Redirect to port [0-9]+/){
				match(line,/port ([0-9]+)/,aF)
				Port=aF[1]
				#print "Redireccion a " Port
				break
			}
			
			# Validamos si es una imagen.
			if (isImg==1){
				# imprimir longitud de la respuesta.
				printf "Ok ... {lon: %s}", length(line)
			} else {
				print line
			}
			rStatus=1
		}

		# Cerramos la conexion del servicio leido.
		close(Service)
		
		# Si tengo una respuesta y no una redireccion, salir.
		if (rStatus==1) break
	}
}
