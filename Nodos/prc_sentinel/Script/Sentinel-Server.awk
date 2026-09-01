# Mensaje de respuesta http para pagina por defecto.
function Message200(msg,type,num){
	num =num==202 ? 202 : (num==204 ? 204 : 200)
	firstline =num==200 ? "HTTP/1.1 200 OK" : (num==204 ? "HTTP/1.1 204 No Content" : "HTTP/1.1 202 Accepted")
	msgResp =sprintf("%s\n",msg)
	len =length(msgResp)

	# En el caso que no se encuentre el tipo en contenidos disponibles, devolver no encontrado.
	if (type in aContentType){
		contenttype=aContentType[type]
		response=	firstline ORS \
					"Connection: close" ORS \
					strftime("Date: %a, %d %b %G %H:%M:%S GMT", systime(),1) ORS \
					"Server: " Sentinel["Version"] ORS \
					contenttype ORS \
					"Content-length: " len ORS ORS \
					msgResp
	} else { 
		response =Message400()
	}

	return response
}

function Message301(NewURL){
	response=	"HTTP/1.1 301 Moved Permanently" ORS \
				"Location: " NewURL
	return response
}

function Message400(){
	response=	"HTTP/1.1 400 Bad Request" ORS \
				"Connection: close" ORS \
				strftime("Date: %a, %d %b %G %H:%M:%S GMT", systime(),1) ORS \
				"Server: " Sentinel["Version"] ORS \
				"Pragma: no-cache" ORS \
				"Content-Length: 51" ORS \
				"Content-Type: text/html" ORS ORS \
				"<html>" ORS \
				"<body><h1>400 Bad Request.</h1></body>" ORS \
				"</html>"
	return response
}

function Message500(msg){
	msgResp="<html><body><h1>" msg "</h1></body></html>\n"
	len =length(msgResp)
	
	response=	"HTTP/1.1 500 Internal Server Error" ORS \
				"Connection: close" ORS \
				strftime("Date: %a, %d %b %G %H:%M:%S GMT", systime(),1) ORS \
				"Server: " Sentinel["Version"] ORS \
				"Pragma: no-cache" ORS \
				"Content-Type: text/html" ORS \
				"Content-Length: " len ORS ORS \
				msgResp
	return response
}

function GetFavicon(){
	BINMODE=3 # Carga de lectura en modo binario. (1=lectura 2=escritura 3=ambos).
	# Leemos cuerpo html.
	ORSSave = ORS
	RS="^$"
	ORS = RS
	# Subimos a memoria el contenido de la imagen.
	fchMedia =DirScript "Sentinel Eye.ico"
	dat=""
	while((getline img < fchMedia)>0){
		dat=img
	}
	close(fchMedia)
	# Restauramos separador de registros.
	RS="\r\n"
	ORS=ORSSave
	
	if (length(dat)>0){
		out =Message200(dat,"ico")
	} else {
		out =Message400()
	}
}

function LoadWorkDir(){
	# Validar que sistema operativo esta en ejecucion.
	cmd="uname -a 2>&1"
	print cmd
	while((cmd | getline line)>0) OS=line
	close(cmd)
	
	print OS
	
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

# Obtiene el UserAgent correspondiente al ultimo disponible.
function GetUserAgent(){
	if (Sentinel["Version"]~/Super/){
		resp=ENVIRON["UserAgent"]
	} else {
		cmd="curl -s http://" IpWheel ":" Port "/useragent"
		resp=""
		cmd | getline xUserAgent
		close(cmd)

		n=match(xUserAgent,/.\042UserAgent\042: \042(.+)\042./, aField)
		if (n>0){
			resp=aField[1]
		}
	}

	return resp
}

function GetMyIP(){
	if (OS=="Windows"){
		cmd="ipconfig"
	} else {
		cmd="ifconfig 2>/dev/null"
	}
	
	RSOLD=RS;RS="\n";flag=0
	while((cmd | getline)>0){
		n=0
		if (OS=="Windows"){
			# Buscar IPv4 luego de aparecer el nombre del adaptador wifi.
			if ($0~/^Wireless LAN adapter Wi-Fi.+/) flag=1
			if (flag==1){
				n=match($0,/IPv4 Address. . . . . . . . . . . : (.+).*/,aField)
				if (n>0){ 
					xMyIP=aField[1]
					break
				}
			} # Para Termux y Raspberry
		} else if (OS~/["Termux"|"Raspberry"]/){
			n=match($0,/inet (.+[0-9]) .+netmask.+broadcast.+/,aField)
			if (n>0){ 
				xMyIP=aField[1] 
				break
			} # Para TinyCore Linux
		} else if (OS=="Tiny"){
			n=match($0,/inet addr:(.+)  Bcast:.+  Mask:.+$/,aField)
			if (n>0){ 
				xMyIP=aField[1] 
				break
			}
		}
	} close(cmd)
	RS=RSOLD
	return xMyIP
}

function GetClone(){
	# En el caso que no se haya especificado inicialmente.
	if (LastPort in aClone){} else { for(i=Port+1;i<=LastPort;i++){ aClone[i]=0; tClone[i]=systime() } }

	if (xClone==""){ xClone=Port+1; aClone[xClone]=1; tClone[xClone]=systime(); return xClone }

	xClone++
	if (xClone>LastPort) xClone=Port+1
	
	for(l=xClone;l<=LastPort;l++){
		#xClone++
		#if (xClone>LastPort){ xClone=Port+1; aClone[xClone]=1; return xClone }
		#aClone[xClone]=1
		if (l in aClone){
			if (aClone[l]==0){ xClone=l; aClone[l]=1; tClone[l]=systime(); return xClone }
		}
	}

	for(k=Port+1;k<=xClone;k++){
		#xClone++
		#if (xClone>LastPort){ xClone=Port+1; aClone[xClone]=1; return xClone }
		#aClone[xClone]=1
		if (k in aClone){
			if (aClone[k]==0){ xClone=k; aClone[k]=1; tClone[k]=systime(); return xClone }
		}
	}

	return -1
}

function Dormir(n){
	if (OS=="Windows"){
		system("timeout " n " >Nul")
	} else {
		system("sleep " n)
	}
}

BEGIN {
	FS=";"
	OFS=";"
	RS="\r\n"
	ORS=RS

	# Version del sistema.
	Sentinel["Version"]="Sentinel 1.0.0"

	# Obtener los directorios de trabajo.
	LoadWorkDir()

	# Lista de variables de ambiente configuradas para servicio sentinel.
	ListVar["useragent"]="UserAgent"
	ListVar["name"]="Name"
	ListVar["myip"]="MyIP"
	ListVar["os"]="OS"
	ListVar["ipwheel"]="IpWheel"
	ListVar["pathsentinel"]="PathSentinel"

	# Service of DB.
    ServiceDB ="sqlite3 \042" DirDatos "Hot.db\042 \042.timeout 15000\042 "
	
	# Servicio de BD para Monitor Price.
	MonitorPriceDB ="sqlite3 \042${HOME}//PRC_Monitor_Price//Datos//Jupiter_Hot.db\042 \042.timeout 15000\042 "

	# Servicio de BD para Monitor Price.
	SimuladorDB ="sqlite3 \042${HOME}//PRC_Monitor_Price//Datos//Simulador.db\042 \042.timeout 15000\042 "

	# Directorios de trabajo de otros proyectos.
	aDirScript="D:\\PRC Copiar Disco\\Script\\"
	aDirDataLake="D:\\PRC Copiar Disco\\DataLake\\"

	# Registros por defecto.
	Port=length(Port)==0 ? 8081 : Port
	Service = "/inet4/tcp/" Port "/0/0"

	# Servicio para comunicarse con su Clone raiz.
	ServiceWheel="/inet4/tcp/0/localhost/8081"

	# Habilidar estados de Clones.
	Clone=GetClone()

	# Obteniendo variables de ambiente.
	MyIP=ENVIRON["MyIP"]
	PathSentinel=ENVIRON["PathSentinel"]
	
	# Validar que exista el IpWheel.
	if (Sentinel["Version"]~/Super/){
		IpWheel=GetMyIP()
	} else {
		IpWheel=ENVIRON["IpWheel"]
	}
	
	if (IpWheel==""){
		print "ERROR: no se puedo encontrar el IPWheel.\n"
		print "   Ejecute Sentinel-Search.awk para buscar la red Sentinel."
		exit 1
	}

	# Validar que exista el UserAgent.
	UserAgent=ENVIRON["UserAgent"]
	if (UserAgent==""){
		print "ERROR: no se puedo encontrar el UserAgent.\n"
		print "   Ejecute Sentinel-Search.awk para buscar la red Sentinel."
		exit 1
	}

	# Tiempo maximo de espera por respuesta.
	PROCINFO[Service,"READ_TIMEOUT"]=100

	# Tipos de content-type
	aContentType["html"]="Content-type: text/html"
	aContentType["css"]="Content-type: text/css"
	aContentType["js"]="Content-type: application/javascript;charset=utf-8"
	aContentType["json"]="Content-Type: application/json"
	aContentType["jpg"]="Content-type: image/jpeg"
	aContentType["png"]="Content-type: image/png"
	aContentType["ico"]="Content-type: image/png"

	printf "[%s] ... PathSentinel:'%s'.\n", strftime("%G-%m-%d %H:%M:%S"), PathSentinel
	printf "[%s] ... UserAgent:'%s'.\n", strftime("%G-%m-%d %H:%M:%S"), UserAgent
	printf "[%s] ... IpWheel:'%s'.\n", strftime("%G-%m-%d %H:%M:%S"), IpWheel
	printf "[%s] ... MyIP:'%s'.\n", strftime("%G-%m-%d %H:%M:%S"), MyIP
	printf "[%s] ... OS:'%s'.\n", strftime("%G-%m-%d %H:%M:%S"), OS
	printf "[%s] ... esperando en puerto %s.\n", strftime("%G-%m-%d %H:%M:%S"), Port

	while (1 != 0) {
		# Limpiar linea solicitada.
		line="";cmd="";Comando="";NumLine=0;FirstLine="";Metodo="";URL="";Proto="";out="Empty";IsData=0;delete Request;delete aData
		while ((Service |& getline line) > 0){
			NumLine++

			# Obtener la primera linea de los encabezados.
			if (NumLine ==1){
				FirstLine =line
				n= match(line, /^(POST|GET) (\/.*) (HTTP\/1.[0-1])/,aReq)
				if (n>0){
					Metodo =aReq[1]
					URL =tolower(aReq[2])
					Proto =aReq[3]
				} else if (line~/^CMD:/){
					Metodo="CMD"
					Comando=line
					gsub(/^CMD: /,"",Comando)
				}
				
				# No se permiten llamados de raiz.
				if (URL =="/"){
					FirstLine=""
					out =Message400()
					print out |& Service
					continue
				}
			}

			# Obtener los datos enviados en el body del request.
			if (Metodo =="POST" && line=="" && IsData==0){
				out =Message200("{\042status\042:\042received\042}\n","json",202)
				print out |& Service
				IsData++
			}

			# Obtener solo la primera linea, saltar todos los demas encabezados.
			if (Metodo =="GET" && NumLine>1) continue

			# Registrar por separado los datos recibidos.
			if (IsData>=1){
				if (IsData>1){
					aData[IsData-1]=line
				}
				IsData++
			}
		}

		# Respuesta por defecto a solicitudes sin encabezados.
		if (FirstLine==""){
			# printf "[%s] ... h1 'Headers Empty'.\n", strftime("%G-%m-%d %H:%M:%S")
			close(Service)
			continue
		}

		# Imprimir en consola la primera linea de la solicitud.
		gsub(/\n/," ",FirstLine) # Eliminar saltos de linea y retorno de carro.
		if (debug==1) printf "[%s] ... h1 '%s'.\n", strftime("%G-%m-%d %H:%M:%S"), FirstLine

		if (Metodo =="CMD"){
			# Ejecutar en el SO la linea solicitada, y obtener la respuesta en una variable.
			RSOLD=RS;RS="^$"
			gsub(/^(CMD: )/,"",Comando)

			if (Comando~/^Sentinel Shutdown/){ # Comando para bajar el servicio.
				RS=RSOLD
				out="data: {\042status\042:\042Sentinel shutting down.\042}"
				print out |& Service
				close(Service)
				if (debug==1) printf "[%s] ... bajando servicio Sentinel, bye.\n", strftime("%G-%m-%d %H:%M:%S")
				exit 0
			} else if (Comando~/^Sentinel Version/){ # Comando para obtener la version del servicio.
				out =Sentinel["Version"]
				if (debug==1) printf "[%s] ... version del servicio '%s'.\n", strftime("%G-%m-%d %H:%M:%S"), Sentinel["Version"]
			} else if (Port==8081){ # Cualquier comando solicitado al Clone raiz, se redirecciona a un Clone.
				Clone=GetClone()
				out="Redirect to port " Clone
			} else {
				if (OS!="Windows"){
					# Ejecuciones en segundo plano.
					if (Comando~/&$/ || Comando~/^\./){
						gsub(/( &)$/,"",Comando)
						cmd ="cd " DirRun " && " Comando " 2>&1 &"
					} else {
						# Esperar por la respuesta.
						cmd ="cd " DirRun " && " Comando
					}
				}

				if (OS=="Windows"){ # Para Windows, redireccionas a la salida estandar cualquier error.
					# Ejecuciones en segundo plano.
					if (Comando~/^start /){
						cmd ="cd \042" DirRun "\042 && " Comando " 2>&1"
					} else {
						# Esperar por la respuesta.
						cmd ="cd \042" DirRun "\042 && " Comando
					}
				}

				if (Comando~/^ *(del|delete|rm|remove) .+/){
					out ="ERROR: is not permit delete file or directories."
				} else {
					cmd | getline out
					RS=RSOLD
					close(cmd)
				}

			}
			# Restaurar el separador de registros.
			RS=RSOLD
		}

		if (Metodo =="GET"){
			# Validar formato de la solcitid.
			if (URL~/^\/favicon.ico$/){
				GetFavicon()
			} else if (URL~/^\/sentinelversion$/){ # Si solicita la version del servicio.
				out =Message200("{\042Version\042: \042" Sentinel["Version"] "\042}","json",200)
			} else if (URL~/^\/sentinel\/var\/.+/){ # Si solicita la version del servicio.
				n =match(URL,/^\/sentinel\/var\/(.+)/,aField)
				var=aField[1]
				if (var in ListVar){
					var=ListVar[var]
					value=ENVIRON[var]
					if(length(value)>0){
						msg="{\042" var "\042: \042" value "\042}\n"
						out =Message200(msg,"json",202)
					} else {
						out =Message200("{\042Error\042: \042Variable is not found in environment.\042}\n","json",202)
					}
				} else {
					out =Message200("{\042Error\042: \042Variable is not exist in Sentinel.\042}\n","json",202)
				}
			} else if (URL~/^\/useragent$/){ # El useragent a utilizar en todas las solicitudes.
				if (length(UserAgent)>10){
					out =Message200("{\042UserAgent\042: \042" UserAgent "\042}\n","json",200)
				} else if (length(ENVIRON["UserAgent"])>10){
					UserAgent=ENVIRON["UserAgent"]
					out =Message200("{\042UserAgent\042: \042" ENVIRON["UserAgent"] "\042}\n","json",200)
				} else {
					UserAgent=GetUserAgent()
					if (length(UserAgent)>0){
						out =Message200("{\042UserAgent\042: \042" UserAgent "\042}\n","json",200)
					} else {
						out =Message500("No se pudo obtener el UserAgent desde Wheel.")
					}
				}
			} else if (URL~/^\/monitorprice\/.+/){ # Comando para bajar el servicio.
				if (URL~/^\/monitorprice\/tradeopen$/){ # Comando para bajar el servicio.
					tc_resp=""
					cmdMP=SimuladorDB "\042.mode json\042 \042select * from dwv_trade_open_full;\042"
					while((cmdMP | getline)>0){
						tc_resp=$0
					}
					close(cmdMP)
					if (length(tc_resp)>0){
						out=Message200(tc_resp,"json",200)
					}
					if (length(tc_resp)==0){
						out=Message200("{\042status\042:\042no hay trade abierto.\042}","json",200)
					}
				} else if (URL~/^\/monitorprice\/tradecreated\/.+/){ # Comando para bajar el servicio.
					n =match(URL,/^\/monitorprice\/tradecreated\/([0-9]+)/,aField)
					if (n>0){
						tc_idtrade=aField[1]
						tc_resp=""
						cmdMP=SimuladorDB "\042.mode json\042 \042select price_entry from dwd_operations where idtrade=" tc_idtrade " and operation='Trade Create' order by datemaxmin desc limit 1;\042"
						while((cmdMP | getline)>0){
							tc_resp=$0
						}
						close(cmdMP)
						
						# En caso se encuentre el idtrade.
						if (tc_resp~/price_entry/){
							out=Message200(tc_resp,"json",200)
						} else {
							out=Message200("{\042status\042:\042no hay operacion 'Trade Create' para este id.\042}","json",200)
						}
					}
					if (n==0) {
						out =Message200("{\042Error\042: \042el idtrade debe ser un numero.\042}\n","json",200)
					}
				} else if (URL~/^\/monitorprice\/movetpsl\/.+/){ # Comando para bajar el servicio.
					n =match(URL,/^\/monitorprice\/movetpsl\/([0-9]+)/,aField)
					if (n>0){
						tc_idtrade=aField[1]
						tc_resp=""
						cmdMP=SimuladorDB "\042.mode json\042 \042select price_liquidation, price_TP from dwd_operations where idtrade=" tc_idtrade " and operation='Move TP' order by datemaxmin desc limit 1;\042"
						while((cmdMP | getline)>0){
							tc_resp=$0
						}
						close(cmdMP)
						
						# En caso se encuentre el idtrade.
						if (tc_resp~/price_liquidation/){
							out=Message200(tc_resp,"json",200)
						} else {
							out=Message200("{\042status\042:\042no hay una operacion 'Move TP' para este id.\042}","json",200)
						}
					}
					if (n==0) {
						out =Message200("{\042Error\042: \042el idtrade debe ser un numero.\042}\n","json",200)
					}
				} else {
					out =Message200("{\042Error\042: \042no es un comando valido para Monitor Price.\042}\n","json",200)
				}
			} else if (URL~/^\/sentinelshutdown$/){ # Comando para bajar el servicio.
				out=Message200("data: {\042status\042:\042Sentinel shutting down in port " Port ".\042}","json",200)
				print out |& Service
				close(Service)
				if (debug==1) printf "[%s] ... bajando servicio Sentinel en puerto %s, bye.\n", strftime("%G-%m-%d %H:%M:%S"), Port
				exit 0
			} else if (URL~/^\/enableclone\/[0-9]*/){ # Comando para bajar el servicio.
				n =match(URL,/^\/enableclone\/([0-9]*)/,aField)
				yClone=aField[1]
				if (yClone in aClone){
					if (aClone[yClone]!=0) aClone[yClone]=0
					tClone[yClone]=systime()
					out=Message200("data: {\042status\042:\042Sentinel enabled Clone.\042}","json",200)
				} else {
					out =Message500("No se pudo habilitar el Clone.")
				}
			} else if (URL~/^\/listclone.*/ && Port==8081){ # Comando listar puertos y sus estados.
				msg=""
				if (URL~/^\/listclone.out.csv/){
					for (a in aClone){ msg=msg a " " aClone[a] " " tClone[a] ";" }
					out=Message200(msg,"html",200)
				} else {
					for (a in aClone){ msg=msg "<div>" a " " aClone[a] " " tClone[a] "</div>" }
					out=Message200(msg,"html",200)
				}
			} else if (URL~/^\/datalake\/am[0-9]+.+/){ # Obtener lista html de fotos del datalake paginados.
				n =match(URL,/^\/datalake\/(am[0-9]+.+)/,aField)
				
				if (n>0){
					filename=aField[1]
					m=split(filename,aFileN,".")
					if (m==2){ 
						ext= tolower(aFileN[m])
						
						# En caso que sea Wheel, delegue la solicitud.
						if (Sentinel["Version"]~/Super/ && Port==8081){
							Clone=GetClone()
							if (Clone==-1){
								out =Message500("No se pudo extraer el puerto a re-direccionar.")
							} else {
								out =Message301("http://" IpWheel ":" Clone "/DataLake/" filename)
							}

						} else {
							BINMODE=3 # Carga de lectura en modo binario. (1=lectura 2=escritura 3=ambos).
							# Leemos cuerpo html.
							ORSSave = ORS
							RS="^$"
							ORS = RS
							# Subimos a memoria el contenido de la imagen.
							ty=0
							fchMedia =aDirDataLake filename
							dat=""
							while((getline img < fchMedia)>0){
								dat=img
							}
							close(fchMedia)
							# Restauramos separador de registros.
							RS="\r\n"
							ORS=ORSSave
							
							if (length(dat)>0){
								out =Message200(dat,ext)
							} else {
								out =Message400()
							}
						}
					} else {
						out =Message400()
					}				
				} else {
					out =Message400()
				}
			} else if (URL~/^\/medialake*/ && Port==8081){ # Obtener datos del explorador multimedia.
				fchMediaLake=""
				if (URL=="/medialake"){fchMediaLake=aDirScript "MediaLake.html";ext="html"}
				if (URL=="/medialake.css"){fchMediaLake=aDirScript "MediaLake.css";ext="css"}
				if (URL=="/medialake.js"){fchMediaLake=aDirScript "MediaLake.js";ext="js"}
				#if (URL=="/medialake.json"){fchMediaLake=aDirScript "MediaLake.json";ext="json"}

				if (URL~/\/medialake.json\?pag=[0-9]*/){
					n=match(URL,/\/medialake.json\?pag=([0-9]*)/,aField)
					if (n>0){
						pag=aField[1]
						pag =(pag-1)*100
						cmd="start \042\042 /B /WAIT \042" aDirScript "MediaLake_PagPhoto.bat\042 " pag
						resp=""
						while((cmd | getline)>0){
							resp =sprintf("%s\n%s",resp,$0)
						}
						close(cmd)
						out =Message200(resp,"json",200)
					} else {
						out =Message400()
					}				
				} else if (length(fchMediaLake)>0){
					resp=""
					while((getline < fchMediaLake)>0){
						resp =sprintf("%s\n%s",resp,$0)
					}
					close(fchMediaLake)
					out =Message200(resp,ext,200)
				} else {
					out =Message400()
				}
			} else { # Toda solicitud que no encaje con la version especificadas, se envia mensaje por defecto 404.
				out =Message400()
			}
		}

		if (Metodo =="POST"){
			# Validar formato de la solcitid.
			if (URL~/^\/addeye$/){ # Agregar un nuevo ojo Sentinel.
				vIP="";vNAME="";vNETMASK="";vPUBLIC="";vOS="";vWHEEL="";vNETSENTINEL="";SENDBD=0
				z= match(aData[1],/IP:'(.+)',NAME:'(.+)',NETMASK:'(.+)',PUBLIC:'(.+)',OS:'(.+)',WHEEL:'(.+)',NETSENTINEL:{(.+)}/,aField)
				if (z>0){
					SENDBD=1
					vIP =aField[1]
					vNAME =aField[2]
					vNETMASK =aField[3]
					vPUBLIC =aField[4]
					vOS =aField[5]
					vWHEEL =aField[6]
					vNETSENTINEL =aField[7]
				} else {
					out =Message400()
				}
			} else if (URL~/^\/addprice$/){ # Agregar un nuevo precio segun el mercado.
				IP=""
				n= match(aData[1],/^IP='(.+)'$/,aField)
				if (n>0){
					IP=aField[1]
					if (OS=="Windows"){
						cmd="start \042\042 /B \042" DirRun "ADD_Price_UP\042 " IP
						system(cmd);close(cmd)
					} else {
						cmd="./ADD_Price_UP " IP
						system(cmd);close(cmd)
					}
				}
			} else if (URL~/^\/addproducts$/){ # Agregar un nuevo producto segun el mercado.
				IP=""
				n= match(aData[1],/^IP='(.+)'$/,aField)
				if (n>0){
					IP=aField[1]
					if (OS=="Windows"){
						cmd="start \042\042 /B \042" DirRun "ADD_Products_UP\042 " IP
						system(cmd);close(cmd)
					} else {
						cmd="./ADD_Products_UP " IP
						system(cmd);close(cmd)
					}
				}
			} else if (URL~/^\/monitorprice\/addoperation$/){ # Agregar info de trade pre-compra referente al fee, price_entry, price_liquidation, price_TP, y deposito a usar.
				tc_deposit=0;tc_idtrade=0;tc_operation="";tc_price_entry=0;tc_price_liquidation=0;tc_total_fee=0;tc_datemaxmin="";tc_SENDBD=0
				z= match(aData[1],/^..deposit...(.+),..idtrade...(.+),..operation....(.+).,..price_entry....(.+).,..price_liquidation....(.+).,..Total_Fee....(.+)../, aField)
				if (z>0){
					tc_SENDBD=1
					tc_deposit =aField[1]
					tc_idtrade =aField[2]
					tc_operation =aField[3]
					tc_price_entry =aField[4]
					tc_price_liquidation =aField[5]
					tc_total_fee =aField[6]
					tc_datemaxmin =strftime("%Y-%m-%d %H:%M:%S", systime())
				} else {
					out =Message400()
				}
			} else { # Toda solicitud que no encaje con la version especificadas, se envia mensaje por defecto 404.
				out =Message400()
			}
		}

		# Informar la respuesta del comando al cliente.
		print out |& Service

		# Cerrar conexion.
		close(Service)
		
		# Hacer disponible al Clone nuevamente.
		if (Port!=8081){
			cou=0
			while (1==1){
				cou++
				cmd="GET /enableclone/" Port " HTTP/1.1"
				print cmd "\r\n" |& ServiceWheel
				rStatus=0
				while ((ServiceWheel |& getline eline) > 0){
					if (eline~/Sentinel enabled Clone.+/){
						rStatus=1
					}
				} close(ServiceWheel)
				# Esperar o detener la actualizacion del servicio.
				if (rStatus==1){ break } else { Dormir(1) }
				# En caso de mas de 5 ciclos, dejar de intentar actualizar estado del servicio.
				if (cou>5) break
			}
		}

		# Registrar un nuevo EYE.
		if(SENDBD==1){
			SENDBD=0
			# Fichero temporal SQL;
			FchSQL= DirTemporal strftime("%G%m%d_%H%M%S") "_AddEyes.sql"
			split(vNETSENTINEL,aNetSent,",")
			print "BEGIN TRANSACTION;" > FchSQL
			printf "delete from dwd_wheels where ip='%s';\n", vIP >> FchSQL
			printf "delete from dwd_eyes where ip='%s';\n", vIP >> FchSQL
			printf "insert into dwd_wheels(ip,sentinelname,netmask,public,so,wheel) values ('%s','%s','%s','%s','%s','%s');\n", vIP, vNAME, vNETMASK, vPUBLIC, vOS, vWHEEL >> FchSQL
			for (a in aNetSent){
				printf "insert into dwd_eyes(IP,EYE) values ('%s',%s);\n", vIP, aNetSent[a] >> FchSQL
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
		
		# Registrar en simulador de monitor price la info pre-compra del trade a realizar.
		if(tc_SENDBD==1){
			tc_SENDBD=0
			# Fichero temporal SQL;
			FchSQL= DirTemporal strftime("%G%m%d_%H%M%S") "_InfoPreBuy.sql"
			print "BEGIN TRANSACTION;" > FchSQL
			printf "insert into dwd_operations(idtrade,operation,price_entry,price_liquidation,Total_Fee,deposit,datemaxmin) values (%s,'%s','%s','%s','%s',%s,'%s');\n", tc_idtrade, tc_operation, tc_price_entry, tc_price_liquidation, tc_total_fee, tc_deposit, tc_datemaxmin >> FchSQL
			print "COMMIT;" >> FchSQL
			close(FchSQL) # Espera a que termine de escribir el fichero y libera cuando el fichero esta disponible para lectura.

			# Actualizar la BD en segundo plano.
			if (OS=="Windows"){
				cmd ="start \042\042 /B " SimuladorDB "\042.read '" FchSQL "'\042"
			} else {
				cmd =SimuladorDB "\042.read '" FchSQL "'\042 &"
			}
			system(cmd);close(cmd)			
		}
	}
}
