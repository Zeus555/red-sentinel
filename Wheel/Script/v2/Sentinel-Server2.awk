# Sentinel v2 - Aceptador de UN SOLO PUERTO con workers en paralelo.
# Reemplaza el modelo de 20 puertos (GetClone/enableclone/Redirect to port NNNN).
# El aceptador NO ejecuta tareas: valida, despacha un worker desprendido y responde
# 202 al instante. El paralelismo son N workers, no N puertos.
#
# Invocacion:
#   gawk -v Port=8181 -v jobs=DIR -v worker=RUTA_Worker.awk -v allow=CONF -v run=DIR_Run \
#        -v dbhot=RUTA_Hot.db -v dbsim=RUTA_SimuladorOnLine.db -v token=SECRETO \
#        -v maxjobs=8 -v maxqueue=64 -v jobttl=300 -v spoolttl=86400 \
#        -v role=Super -v debug=1 -f Sentinel-Server2.awk
#
# Rutas:
#   POST /task?action=<a>&param=<v>    -> 202 {job:ID}   (accion de la lista blanca)
#   GET  /job/<id>                     -> estado + resultado del job
#   GET  /done/<id>?token=<t>          -> callback del worker (exige token + job vivo)
#   POST /ingest/eye?ip=&name=&...     -> alta de nodo (SQL escapado, en 2do plano)
#   POST /ingest/operation?idtrade=&...-> info pre-compra Monitor Price (SQL escapado)
#   GET  /version /health /peers ; GET /stop
#
# TODAS las rutas exigen ?token=<token de flota>: es la credencial de pertenencia
# a la red. Un agente sin el no obtiene ni la version. Tras 3 fallos, 30 s de
# castigo (un token valido sigue pasando durante el castigo, para que el bloqueo
# no sirva para dejar fuera a los nodos legitimos).
#
# SEGURIDAD: ningun byte crudo del cliente llega al shell ni al SQL. Acciones de
# lista blanca fija; parametros tipados (none|num|ip); campos de ingesta tipados y
# cadenas escapadas (SqlEsc). Los metodos se exigen por ruta (las que cambian
# estado son POST, para que una pagina web no las dispare con <img>). /stop y
# /done exigen token: gawk NO expone la IP del peer, asi que no se puede filtrar
# por origen. El contador de carga solo se libera para jobs realmente vivos, y un
# reaper recupera los que murieron sin reportar.

function LoadOS(   o,c){
	if (ENVIRON["OS"] ~ /Windows/) return "Windows"
	o=""; c="uname -a"; c | getline o; close(c)
	if (o ~ /Android/)  return "Termux"
	if (o ~ /Ubuntu/)   return "Ubuntu"
	if (o ~ /Raspbian/) return "Raspberry"
	if (o ~ /tinycore/) return "Tiny"
	if (o == "")        return "Windows"
	return "Linux"
}

# Detecta el shell que usa gawk system(): "cmd" o "posix". Decide la SINTAXIS de
# spawn/redireccion, no el OS (Windows bajo git-bash usa sh; .bat bajo cmd usa cmd).
function DetectShell(   r,c){
	c="echo p=$0"; r=""; c | getline r; close(c)
	return (r ~ /\$0/) ? "cmd" : "posix"
}

function LoadAllow(path,   saveFS,saveRS,line,f){
	saveFS=FS; saveRS=RS; FS="|"; RS="\n"
	while ((getline line < path) > 0){
		if (line ~ /^[ \t]*#/ || line ~ /^[ \t]*$/) continue
		split(line,f,"|")
		aType[f[1]] = f[2]
	}
	close(path)
	FS=saveFS; RS=saveRS
}

# ---- Validadores y saneadores ----
# Guarda contra caracteres de control (incluye \0 \r \n \t): independiza el
# resultado de si el motor gawk casa '$' antes de un salto de linea final.
function IsNum(s){ if (s ~ /[[:cntrl:]]/) return 0; return (s ~ /^[0-9]+$/) }
function IsDec(s){ if (s ~ /[[:cntrl:]]/) return 0; return (s ~ /^[0-9]+(\.[0-9]+)?$/) }
function IsIP(s,   a,i,n){
	if (s ~ /[[:cntrl:]]/) return 0
	if (s !~ /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/) return 0
	n=split(s,a,"."); if (n!=4) return 0
	for (i=1;i<=4;i++){ if (a[i]+0>255) return 0 }
	return 1
}
# Escape para literal SQL: duplica comillas simples y elimina TODO caracter de
# control (impide breakout de cadena y dot-commands de .read en linea nueva).
function SqlEsc(s){ gsub(/'/,"''",s); gsub(/[[:cntrl:]]/," ",s); return s }

function UrlDecode(s,   r,i,L,c,hx){
	gsub(/\+/," ",s); r=""; L=length(s); i=1
	while (i<=L){
		c=substr(s,i,1)
		if (c=="%" && i+2<=L){
			hx=substr(s,i+1,2)
			if (hx ~ /^[0-9A-Fa-f][0-9A-Fa-f]$/){ r=r sprintf("%c",strtonum("0x" hx)); i+=3; continue }
		}
		r=r c; i++
	}
	return r
}

function JsonE(s){ gsub(/\\/,"\\\\",s); gsub(/\042/,"\\\042",s); gsub(/[[:cntrl:]]/," ",s); return s }

function Reply(code,body,ctype,extra,   first,resp){
	if (code==200) first="HTTP/1.1 200 OK"
	else if (code==202) first="HTTP/1.1 202 Accepted"
	else if (code==401) first="HTTP/1.1 401 Unauthorized"
	else if (code==404) first="HTTP/1.1 404 Not Found"
	else if (code==405) first="HTTP/1.1 405 Method Not Allowed"
	else if (code==429) first="HTTP/1.1 429 Too Many Requests"
	else if (code==503) first="HTTP/1.1 503 Service Unavailable"
	else first="HTTP/1.1 400 Bad Request"
	body = body "\n"
	resp = first ORS "Connection: close" ORS "Server: " Ver() ORS \
	       (extra=="" ? "" : extra ORS) \
	       "Content-Type: " ctype ORS "Content-Length: " length(body) ORS ORS body
	return resp
}
function Json(code,body){ return Reply(code,body,"application/json","") }

# ---- Rol de Wheel, decidido por eleccion y no por configuracion --------
# El Wheel es el coordinador de la red. En el v1 se fijaba a mano en la
# laptop; ahora lo elige la red por aptitud (ver Sentinel-Wheel.awk) y el
# resultado se deja en un fichero. Aqui solo se LEE: si dice mi nombre, me
# anuncio como Super. Asi el relevo no exige reiniciar nada.
function AmIWheel(   f,w,now){
	if (WheelState=="" || NodeName=="") return 0
	now=systime()
	if (now - WheelRead < 2) return WheelIs        # cache corta
	WheelRead=now; WheelIs=0
	if ((getline w < WheelState) > 0){
		gsub(/[[:space:]]/,"",w)
		if (w==NodeName) WheelIs=1
	}
	close(WheelState)
	return WheelIs
}
function Ver(){ return AmIWheel() ? "Sentinel Super 2.0.0" : "Sentinel 2.0.0" }

# Temperatura y carga: solo se consultan para /fitness, y con cache, porque
# lanzar procesos por peticion en un telefono modesto se nota.
function Metricas(   now,c,t,l,resp,m){
	now=systime()
	if (now - MetRead < 10) return
	MetRead=now
	MetTemp=-1; MetTempSrc="ninguna"

	# El JSON de termux-battery-status puede venir en UNA sola linea. Hay que
	# extraer el campo, no limpiar la linea entera: si no, "percentage":100 y
	# "temperature":35 se pegan y sale 10035 (visto en sentinel002).
	resp=""
	c="termux-battery-status 2>/dev/null"
	while ((c | getline t) > 0) resp = resp t "\n"
	close(c)
	if (match(resp, /"temperature"[ ]*:[ ]*([0-9.]+)/, m)){
		MetTemp=int(m[1]); MetTempSrc="bateria"
	}
	if (MetTemp<0){
		if ((getline t < "/sys/class/thermal/thermal_zone0/temp") > 0){ MetTemp=int(t/1000); MetTempSrc="cpu" }
		close("/sys/class/thermal/thermal_zone0/temp")
	}

	MetLoad=0
	if ((getline l < "/proc/loadavg") > 0){ split(l,ll," "); MetLoad=ll[1]+0 }
	close("/proc/loadavg")
}

# ---- Control de acceso a la red Sentinel ----------------------------------
# El token es UNO SOLO para toda la flota y es la credencial de pertenencia: un
# agente instalado en la LAN que no lo tenga no obtiene NADA, ni siquiera la
# version. Devuelve "ok" | "bad" | "locked".
#
# Tras LockTries fallos se penaliza LockSecs segundos. gawk NO expone la IP del
# peer, asi que el bloqueo no puede ser por origen: es global. Para que eso no
# se convierta en una forma de dejar fuera a los nodos legitimos, DURANTE el
# bloqueo un token valido sigue pasando; lo que se frena es el intento a ciegas.
function AuthState(   now){
	if (Token=="") return "sin-token"           # FALLA CERRADO (ver Denegado)
	now=systime()
	if (now < LockUntil){
		if (Q["token"]==Token){ return "ok" }
		return "locked"
	}
	if (Q["token"]==Token){ BadCount=0; return "ok" }
	BadCount++
	AuthFail++
	if (BadCount>=LockTries){
		BadCount=0
		LockUntil=now+LockSecs
		if (debug==1) printf "[%s] %d fallos de token: bloqueo %ds\n", strftime("%H:%M:%S"), LockTries, LockSecs
		return "locked"
	}
	return "bad"
}
function Denegado(st,   left){
	if (st=="locked"){
		left = LockUntil - systime(); if (left<1) left=1
		return Reply(429,"{\042error\042:\042demasiados intentos fallidos\042,\042reintentar_en\042:" left "}", \
		             "application/json","Retry-After: " left)
	}
	if (st=="sin-token")
		# Sin token configurado NO se sirve NADA. Antes esto devolvia "ok", asi que
		# un arranque sin token dejaba el agente ABIERTO a toda la LAN, en silencio.
		# Falla cerrado: es preferible un nodo mudo que un nodo abierto.
		return Json(503,"{\042error\042:\042agente sin token de flota configurado\042}")
	return Json(401,"{\042error\042:\042token de flota requerido\042}")
}

# Registra un fichero del spool para poder purgarlo por edad.
function Spooled(f){ Spool[f]=systime() }

function Unlink(f){
	if (Shell=="cmd") system("del /f /q \042" f "\042 >NUL 2>&1")
	else              system("rm -f '" f "' >/dev/null 2>&1")
}

function WriteStatus(id,a,p,st,rc,res,   f){
	gsub(/[[:cntrl:]]/," ",res)
	f = JobsDir id ".status"
	printf "id\t%s\naction\t%s\nparam\t%s\nstatus\t%s\nrc\t%s\nresult\t%s\nts\t%s\n", id,a,p,st,rc,res,systime() > f
	close(f)
	Spooled(f)
}
function ReadStatus(id,J,   f,saveFS,saveRS,n){
	delete J
	f = JobsDir id ".status"
	saveFS=FS; saveRS=RS; FS="\t"; RS="\n"; n=0
	while ((getline < f) > 0){ if (NF>=1){ J[$1] = (NF>=2)? $2 : ""; n++ } }
	close(f); FS=saveFS; RS=saveRS
	return n
}

# Lanza un worker desprendido. action=[a-z0-9_-], param ya tipado: sin metacaracteres.
function SpawnJob(id,action,param,   c){
	if (Shell=="cmd"){
		c = "start \042\042 /B gawk -v job=" id " -v jobs=\042" JobsDir "\042 -v Port=" Port \
		    " -v action=" action " -v param=\042" param "\042 -v run=\042" RunDir "\042" \
		    " -v allow=\042" AllowConf "\042 -f \042" WorkerPath "\042"
	} else {
		c = "gawk -v job=" id " -v jobs='" JobsDir "' -v Port=" Port \
		    " -v action=" action " -v param='" param "' -v run='" RunDir "'" \
		    " -v allow='" AllowConf "' -f '" WorkerPath "' >/dev/null 2>&1 &"
	}
	Running[id]=systime()
	system(c)
	if (debug==1) printf "[%s] spawn job=%s action=%s param=%s inflight=%s\n", strftime("%H:%M:%S"), id, action, param, Inflight+1
}

# Arranca pendientes mientras haya cupo.
function DrainQueue(   rec,pp){
	while (Inflight < MaxJobs && pTail > pHead){
		rec=Pending[pHead]; delete Pending[pHead]; pHead++
		split(rec,pp,"\t")
		SpawnJob(pp[1],pp[2],pp[3]); Inflight++
	}
}

# Recupera cupo de workers muertos sin reportar y purga ficheros viejos del spool.
# Sin esto un worker que Android mate (phantom process killer) dejaria el cupo
# ocupado para siempre, que es justo el fallo del tClone del v1.
function Reap(   id,f,now){
	now=systime()
	if (now - LastReap < 1) return
	LastReap=now
	for (id in Running){
		if (now - Running[id] > JobTTL){
			delete Running[id]
			if (Inflight>0) Inflight--
			WriteStatus(id,"","","expired","","el worker no reporto en " JobTTL "s")
			ExpiredCou++
		}
	}
	for (f in Spool){
		if (now - Spool[f] > SpoolTTL){ Unlink(f); delete Spool[f] }
	}
	DrainQueue()
}

function NewId(){ JobSeq++; return strftime("%Y%m%d%H%M%S") "-" PROCINFO["pid"] "-" JobSeq }

# Dispara la eleccion de Wheel cada ElectSecs, en segundo plano y desde el propio
# bucle del aceptador: asi no hace falta cron en los telefonos ni un timer en los
# Ubuntu, y el relevo funciona igual en las dos plataformas.
function Elegir(   now,c){
	# ElectSecs<=0 desactiva la eleccion (se usa en el banco de pruebas).
	if (Elector=="" || WheelState=="" || NodeName=="" || ElectSecs<=0) return
	now=systime()
	if (now - LastElect < ElectSecs) return
	LastElect=now
	if (Shell=="cmd"){
		c = "start \042\042 /B gawk -v self=\042" NodeName "\042 -v port=" Port " -v token=\042" Token "\042" \
		    " -v peers=\042" PeersFile "\042 -v state=\042" WheelState "\042" \
		    " -v rqlite=\042" RqliteURL "\042 -v discover=\042" DiscoverPath "\042 -v cidr=\042" Cidr "\042 -v spool=\042" JobsDir "\042" \
		    " -f \042" Elector "\042"
	} else {
		c = "gawk -v self='" NodeName "' -v port=" Port " -v token='" Token "'" \
		    " -v peers='" PeersFile "' -v state='" WheelState "'" \
		    " -v rqlite='" RqliteURL "' -v discover='" DiscoverPath "' -v cidr='" Cidr "' -v spool='" JobsDir "'" \
		    " -f '" Elector "' >/dev/null 2>&1 &"
	}
	system(c)
	if (debug==1) printf "[%s] eleccion de Wheel lanzada\n", strftime("%H:%M:%S")
}

# Lee peers.tsv (ip TAB version TAB rol TAB epoch) y lo devuelve como JSON.
# Se relee en cada peticion: el descubrimiento corre aparte y reescribe el fichero.
function PeersJson(   saveFS,saveRS,line,f,s,n){
	if (PeersFile=="") return ""
	saveFS=FS; saveRS=RS; FS="\t"; RS="\n"; s=""; n=0
	while ((getline line < PeersFile) > 0){
		if (split(line,f,"\t") < 1 || f[1]=="") continue
		if (n++) s = s ","
		s = s "{\042ip\042:\042" JsonE(f[1]) "\042,\042version\042:\042" JsonE(f[2]) "\042,\042role\042:\042" JsonE(f[3]) "\042}"
	}
	close(PeersFile)
	FS=saveFS; RS=saveRS
	return s
}

# Rellena Q[] con los pares clave=valor de la query, con URL-decode en los valores.
function ParseQuery(qs,   np,i,eq,k,v,pairs){
	delete Q
	np=split(qs,pairs,"&")
	for (i=1;i<=np;i++){
		eq=index(pairs[i],"="); if (eq==0){ continue }
		k=substr(pairs[i],1,eq-1); v=substr(pairs[i],eq+1)
		Q[k]=UrlDecode(v)
	}
}

BEGIN {
	RS="\r\n"; ORS=RS; FS=";"; OFS=";"

	OS    = LoadOS()
	Shell = DetectShell()
	Version  = (role=="Super") ? "Sentinel Super 2.0.0" : "Sentinel 2.0.0"
	Port     = (length(Port)==0)     ? 8181  : Port
	MaxJobs  = (length(maxjobs)==0)  ? 8     : maxjobs+0
	MaxQueue = (length(maxqueue)==0) ? 64    : maxqueue+0
	JobTTL   = (length(jobttl)==0)   ? 300   : jobttl+0
	SpoolTTL = (length(spoolttl)==0) ? 86400 : spoolttl+0
	MaxHdr   = 100      # tope de lineas por peticion
	MaxLine  = 8192     # tope de longitud de la linea de peticion
	AllowConf= allow
	WorkerPath= worker
	RunDir   = run
	DbHot    = dbhot
	DbSim    = dbsim
	# El token llega por el ENTORNO, no por -v: la linea de comandos de un proceso
	# es legible por otros (world-readable en /proc de Linux) y este token es la
	# UNICA defensa del puerto en claro. Se sigue aceptando -v token= por
	# compatibilidad, para poder desplegar este awk con el lanzador viejo.
	Token    = (length(token)>0) ? token : ENVIRON["SENTINEL_TOKEN"]
	NodeName = name
	WheelState= wheelstate
	Eligible = (eligible=="no") ? 0 : 1
	StartTime= systime()
	ElectSecs= (length(electsecs)==0) ? 300 : electsecs+0
	Elector  = elector
	DiscoverPath = discoverer
	RqliteURL = rqliteurl
	Cidr     = cidr
	# Primera eleccion a los ~15 s de arrancar: lo justo para que el nodo este
	# listo y el descubrimiento haya corrido, sin esperar un ciclo entero.
	LastElect= systime() - ElectSecs + 15
	WheelRead=0; WheelIs=0; MetRead=0; MetTemp=-1; MetLoad=0; MetTempSrc="ninguna"
	PeersFile= peers

	JobsDir = jobs
	if (JobsDir !~ /[\/\\]$/) JobsDir = JobsDir "/"

	# Puerta de la red: 3 fallos -> 30 s de castigo (configurables para pruebas).
	LockTries = (length(locktries)==0) ? 3  : locktries+0
	LockSecs  = (length(locksecs)==0)  ? 30 : locksecs+0
	BadCount=0; LockUntil=0; AuthFail=0

	LoadAllow(AllowConf)
	Inflight=0; pHead=0; pTail=0; LastReap=0; ExpiredCou=0

	Service = "/inet4/tcp/" Port "/0/0"
	PROCINFO[Service,"READ_TIMEOUT"] = 200

	printf "[%s] Sentinel v2 '%s' OS=%s shell=%s puerto=%s maxjobs=%s cola=%s token=%s acciones=%s\n", \
		strftime("%G-%m-%d %H:%M:%S"), Version, OS, Shell, Port, MaxJobs, MaxQueue, (Token==""?"no":"si"), length(aType)

	while (1) {
		Reap()
		Elegir()

		FirstLine=""; Metodo=""; Path=""; QS=""; NumLine=0; out=""; TooBig=0
		while ((Service |& getline line) > 0){
			NumLine++
			if (NumLine > MaxHdr){ TooBig=1; break }
			if (NumLine==1){
				if (length(line) > MaxLine){ TooBig=1; break }
				FirstLine=line
				if (match(line,/^(POST|GET) (\/[^ ]*) (HTTP\/1\.[0-1])/,r)){
					Metodo=r[1]; raw=r[2]
					qi=index(raw,"?")
					if (qi>0){ Path=tolower(substr(raw,1,qi-1)); QS=substr(raw,qi+1) }
					else     { Path=tolower(raw); QS="" }
				}
			} else if (line==""){ break }   # fin de encabezados; params van en la query
		}
		if (TooBig){
			print Json(400,"{\042error\042:\042peticion demasiado grande\042}") |& Service
			close(Service); continue
		}
		if (FirstLine==""){ close(Service); continue }
		if (debug==1) printf "[%s] req %s %s\n", strftime("%H:%M:%S"), Metodo, Path

		ParseQuery(QS)

		# ---- Puerta de la red: sin token de flota no se entra a NADA ----
		# Incluye /version y /peers: un agente ajeno que aparezca en la LAN no
		# puede ni descubrir que aqui hay un Sentinel, asi que no puede unirse.
		Auth = AuthState()
		if (Auth != "ok"){
			print Denegado(Auth) |& Service
			close(Service)
			continue
		}

		# ---- Enrutado (sobre Path; los valores de la query NO se pasan a minusculas) ----
		if (Path=="/" || Path==""){
			out = Json(400,"{\042error\042:\042ruta raiz no permitida\042}")

		} else if (Path=="/version"){
			out = Json(200,"{\042version\042:\042" Ver() "\042,\042os\042:\042" OS "\042,\042wheel\042:" AmIWheel() "}")

		} else if (Path=="/health"){
			out = Json(200,"{\042version\042:\042" Ver() "\042,\042os\042:\042" OS "\042,\042wheel\042:" AmIWheel() ",\042inflight\042:" Inflight ",\042running\042:" length(Running) ",\042queued\042:" (pTail-pHead) ",\042maxjobs\042:" MaxJobs ",\042maxqueue\042:" MaxQueue ",\042expired\042:" ExpiredCou ",\042auth_fallidos\042:" AuthFail ",\042bloqueado\042:" (systime()<LockUntil?1:0) ",\042actions\042:" length(aType) "}")

		} else if (Path=="/fitness"){
			# Lo que este nodo aporta a la eleccion de Wheel. No decide nada: solo
			# publica sus numeros para que el elector los compare (ver
			# Sentinel-Wheel.awk). 'estable' distingue un equipo siempre encendido
			# de un telefono con bateria, que es el factor que mas pesa en la
			# disponibilidad real.
			Metricas()
			out = Json(200,"{\042nombre\042:\042" JsonE(NodeName) "\042,\042os\042:\042" OS "\042" \
				",\042elegible\042:" Eligible \
				",\042wheel\042:" AmIWheel() \
				",\042uptime\042:" (systime()-StartTime) \
				",\042temp\042:" MetTemp \
				",\042fuente_temp\042:\042" MetTempSrc "\042" \
				",\042carga\042:" MetLoad \
				",\042inflight\042:" Inflight ",\042maxjobs\042:" MaxJobs \
				",\042queued\042:" (pTail-pHead) ",\042maxqueue\042:" MaxQueue \
				",\042estable\042:" ((OS=="Ubuntu"||OS=="Debian"||OS=="Linux") ? 1 : 0) "}")

		} else if (Path=="/peers"){
			# Gossip: publica los vecinos que dejo el descubrimiento (peers.tsv).
			# Abierto a proposito, igual que /version: es como se encuentran entre si.
			out = Json(200,"{\042peers\042:[" PeersJson() "]}")

		} else if (Path=="/stop"){
			# Exige token SIEMPRE: sin token configurado la ruta no existe, para que
			# ningun peer de la LAN pueda apagar el nodo.
			if (Token=="" || Q["token"]!=Token){
				out = Json(404,"{\042error\042:\042ruta desconocida\042}")
			} else {
				out = Json(200,"{\042status\042:\042stopping\042}")
				print out |& Service; close(Service)
				printf "[%s] stop solicitado, bye.\n", strftime("%H:%M:%S")
				exit 0
			}

		} else if (Path=="/task"){
			if (Metodo!="POST"){
				out = Json(405,"{\042error\042:\042usar POST\042}")
			} else {
				action=Q["action"]; param=Q["param"]
				if (action !~ /^[a-z][a-z0-9_-]{0,32}$/){
					out = Json(400,"{\042error\042:\042accion con formato invalido\042}")
				} else if (!(action in aType)){
					out = Json(400,"{\042error\042:\042accion no esta en la lista blanca\042}")
				} else if (aType[action]=="none" && param!=""){
					out = Json(400,"{\042error\042:\042esta accion no admite parametro\042}")
				} else if (aType[action]=="num" && !IsNum(param)){
					out = Json(400,"{\042error\042:\042esta accion requiere parametro entero\042}")
				} else if (aType[action]=="ip" && !IsIP(param)){
					out = Json(400,"{\042error\042:\042esta accion requiere una IP valida\042}")
				} else if (Inflight >= MaxJobs && (pTail-pHead) >= MaxQueue){
					out = Json(429,"{\042error\042:\042cola llena\042,\042maxqueue\042:" MaxQueue "}")
				} else {
					id = NewId()
					WriteStatus(id,action,param,"queued","","")
					if (Inflight < MaxJobs){
						SpawnJob(id,action,param); Inflight++
						out = Json(202,"{\042job\042:\042" id "\042,\042queued\042:0}")
					} else {
						Pending[pTail++] = id "\t" action "\t" param
						out = Json(202,"{\042job\042:\042" id "\042,\042queued\042:1}")
					}
				}
			}

		} else if (Path=="/ingest/eye"){
			if (Metodo!="POST"){
				out = Json(405,"{\042error\042:\042usar POST\042}")
			} else if (!IsIP(Q["ip"])){
				out = Json(400,"{\042error\042:\042ip invalida\042}")
			} else if (DbHot==""){
				out = Json(400,"{\042error\042:\042db no configurada (dbhot)\042}")
			} else {
				bad=0
				ns=Q["netsentinel"]; nn=split(ns,arr,",")
				for (i=1;i<=nn;i++){ if (arr[i]!="" && !IsNum(arr[i])) bad=1 }
				if (bad){
					out = Json(400,"{\042error\042:\042netsentinel debe ser lista de enteros\042}")
				} else {
					fch = JobsDir "eye_" NewId() ".sql"
					print "BEGIN TRANSACTION;" > fch
					printf "delete from dwd_wheels where ip='%s';\n", Q["ip"] >> fch
					printf "delete from dwd_eyes where ip='%s';\n", Q["ip"] >> fch
					printf "insert into dwd_wheels(ip,sentinelname,netmask,public,so,wheel) values ('%s','%s','%s','%s','%s','%s');\n", \
						Q["ip"], SqlEsc(Q["name"]), SqlEsc(Q["netmask"]), SqlEsc(Q["public"]), SqlEsc(Q["os"]), SqlEsc(Q["wheel"]) >> fch
					for (i=1;i<=nn;i++){ if (arr[i]!="") printf "insert into dwd_eyes(ip,eye) values ('%s',%s);\n", Q["ip"], arr[i] >> fch }
					print "COMMIT;" >> fch
					close(fch)
					Spooled(fch)
					SpawnBg(SqliteRead(DbHot,fch))
					out = Json(202,"{\042status\042:\042eye encolado\042,\042ip\042:\042" JsonE(Q["ip"]) "\042}")
				}
			}

		} else if (Path=="/ingest/operation"){
			if (Metodo!="POST"){
				out = Json(405,"{\042error\042:\042usar POST\042}")
			} else if (!IsNum(Q["idtrade"])){
				out = Json(400,"{\042error\042:\042idtrade debe ser entero\042}")
			} else if (!IsDec(Q["price_entry"]) || !IsDec(Q["price_liquidation"]) || !IsDec(Q["total_fee"]) || !IsDec(Q["deposit"])){
				out = Json(400,"{\042error\042:\042price_entry/price_liquidation/total_fee/deposit deben ser numericos\042}")
			} else if (DbSim==""){
				out = Json(400,"{\042error\042:\042db no configurada (dbsim)\042}")
			} else {
				dm = strftime("%Y-%m-%d %H:%M:%S", systime())
				fch = JobsDir "op_" NewId() ".sql"
				print "BEGIN TRANSACTION;" > fch
				printf "insert into dwd_operations(idtrade,operation,price_entry,price_liquidation,Total_Fee,deposit,datemaxmin) values (%s,'%s','%s','%s','%s',%s,'%s');\n", \
					Q["idtrade"], SqlEsc(Q["operation"]), Q["price_entry"], Q["price_liquidation"], Q["total_fee"], Q["deposit"], dm >> fch
				print "COMMIT;" >> fch
				close(fch)
				Spooled(fch)
				SpawnBg(SqliteRead(DbSim,fch))
				out = Json(202,"{\042status\042:\042operacion encolada\042,\042idtrade\042:\042" JsonE(Q["idtrade"]) "\042}")
			}

		} else if (match(Path,/^\/job\/([a-z0-9_-]+)$/,m)){
			# El resultado puede llevar la salida del comando: exige token.
			if (ReadStatus(m[1],J) > 0){
				out = Json(200,"{\042id\042:\042" JsonE(J["id"]) "\042,\042action\042:\042" JsonE(J["action"]) "\042,\042param\042:\042" JsonE(J["param"]) "\042,\042status\042:\042" JsonE(J["status"]) "\042,\042rc\042:\042" JsonE(J["rc"]) "\042,\042result\042:\042" JsonE(J["result"]) "\042,\042ts\042:\042" JsonE(J["ts"]) "\042}")
			} else {
				out = Json(404,"{\042error\042:\042job no encontrado\042}")
			}

		} else if (match(Path,/^\/done\/([a-z0-9_-]+)$/,m)){
			# El token ya se valido en la puerta. Aqui solo se libera cupo si el
			# job existe y esta realmente vivo: si no, un peer podria
			# desincronizar el contador y saltarse MaxJobs.
			if (!(m[1] in Running)){
				out = Json(404,"{\042error\042:\042job no esta en ejecucion\042}")
			} else {
				delete Running[m[1]]
				if (Inflight>0) Inflight--
				DrainQueue()
				out = Json(200,"{\042status\042:\042ok\042}")
			}

		} else {
			out = Json(404,"{\042error\042:\042ruta desconocida\042}")
		}

		print out |& Service
		close(Service)
	}
}

# Ejecuta un comando construido por el SERVIDOR (sin bytes del cliente) en 2do plano.
function SpawnBg(cmd){
	if (Shell=="cmd") system("start \042\042 /B " cmd)
	else system(cmd " >/dev/null 2>&1 &")
}
function SqliteRead(db,fch){ return "sqlite3 \042" db "\042 \042.read '" fch "'\042" }
