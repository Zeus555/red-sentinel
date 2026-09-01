# Mensaje de respuesta http para pagina por defecto.
function Message200(msg,type){
	if (type=="html"){
		msgResp="<html><body><h1>" msg "</h1></body></html>"
	} else {
		msgResp=msg
	}
	len=length(msgResp)

	# En el caso que no se encuentre el tipo en contenidos disponibles, devolver no encontrado.
	if (type in aContentType){
		contenttype=aContentType[type]
		response=	"HTTP/1.0 200 OK" ORS \
					"Connection: Close" ORS \
					strftime("Date: %a, %d %b %G %H:%M:%S GMT", systime()+3600*8) ORS \
					"Server: Sentinel 1.0" ORS \
					contenttype ORS \
					"Content-length: " len ORS ORS \
					msgResp
	} else { 
		response=Message404NotFound()
	}

	return response
}

function Message404NotFound(){
	response=	"HTTP/1.0 404 Not Found" ORS \
				"Connection: close" ORS \
				strftime("Date: %a, %d %b %G %H:%M:%S GMT", systime()+3600*8) ORS \
				"Server: Sentinel 1.0" ORS \
				"Pragma: no-cache" ORS \
				"Content-Length: 58" ORS \
				"Content-Type: text/html" ORS ORS \
				"<html>" ORS \
				"<body><h1>404 file not found.</h1></body>" ORS \
				"</html>"
	return response
}

BEGIN {
	FS=";"
	OFS=";"
	RS="\r\n"
	ORS=RS
	# Registros por defecto.
	Port=length(Port)==0 ? 8081 : Port

	Service = "/inet4/tcp/" Port "/0/0"

	# Tiempo maximo de espera por respuesta.
	#PROCINFO[Service,"READ_TIMEOUT"]=5000

	# Tipos de content-type
	aContentType["html"]="Content-type: text/html"
	aContentType["css"]="Content-type: text/css"
	aContentType["javascript"]="Content-type: application/javascript;charset=utf-8"
	aContentType["json"]="Content-Type: application/json"

	printf "[%s] ... esperando en puerto %s.\n", strftime("%G-%m-%d %H:%M:%S", systime()), Port

	while((Service |& getline line) > 0){
		print line
		if (line~/Content-type/) contt=linea ORS
		# Fin de encabezados.
		if(line==""){
			out =Message200("{\nRecivied!!!\n}\n","json")
			print out |& Service
			Service |& getline line
			print "Data:" line
		}
	}

	# Informar la respuesta del comando al cliente.
	print out |& Service

	# Cerrar conexion.
	close(Service)
}
