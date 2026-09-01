# Sentinel v2 - Eleccion automatica del Wheel.
#
# El Wheel es el coordinador de la red. En el v1 se fijaba a mano (era siempre la
# laptop) y si ese equipo se apagaba, la red se quedaba sin cabeza. Aqui lo elige
# la propia red por APTITUD, y el relevo no exige tocar nada: el ganador se
# escribe en un fichero y cada nodo, al leerlo, se anuncia o no como
# "Sentinel Super" en /version.
#
# Invocacion (la lanza el propio aceptador cada ElectSecs):
#   gawk -v self=<nombre> -v port=8181 -v token=<token> -v peers=peers.tsv \
#        -v state=wheel.state [-v debug=1] -f Sentinel-Wheel.awk
#
# No hay consenso ni votacion: todos los nodos puntuan con la MISMA formula sobre
# los MISMOS datos publicos (/fitness), asi que convergen solos al mismo ganador.
# Los empates se rompen por nombre, que es estable. Es suficiente para coordinar
# una LAN domestica y no arrastra la complejidad de un Raft (que ya aporta rqlite
# para lo que de verdad necesita consenso: los datos).
#
# CRITERIO: gana el nodo con mayor DISPONIBILIDAD, no el mas potente. Por eso
# pesa tanto llevar tiempo en pie y no depender de bateria, y penalizan el calor,
# la carga, la ocupacion y la lentitud. La idea es que el Wheel cambie poco: un
# relevo constante seria peor que un Wheel mediocre.

function Sondeo(ip,tout,   c,line,resp){
	c = "curl -s -m " tout " -w '\\nRTT:%{time_total}' 'http://" ip ":" Port "/fitness?token=" Token "'"
	resp=""
	while ((c | getline line) > 0){ resp = resp line "\n" }
	close(c)
	return resp
}

function Prueba(ip,   r){
	# Devuelve el JSON de /fitness del nodo. Si el primer intento vuelve vacio se
	# reintenta UNA vez con el doble de paciencia: un telefono en doze o un hipo
	# de WiFi puede perder un sondeo de 3 s estando perfectamente sano, y dar por
	# ausente a un nodo por eso es justo lo que provocaba relevos de Wheel
	# fantasma. Solo se paga el reintento con los que de verdad no contestan.
	r = Sondeo(ip, Tout)
	if (r ~ /nombre/) return r
	return Sondeo(ip, Tout*2)
}

function WheelAlcanzable(ip,   c,resp,l,n,i,tr){
	# ¿Lo alcanza el clúster rqlite? Raft habla por el 4002 y nuestro sondeo por
	# el 8181: son caminos INDEPENDIENTES. Si yo no veo al Wheel pero Raft si lo
	# alcanza, la ceguera es mia (WiFi del telefono) y no del coordinador, asi
	# que no hay nada que relevar. Vale -1 cuando no hay fuente fiable: en ese
	# caso no opina y se decide como antes.
	if (Rqlite=="" || ip=="") return -1
	c = "curl -s -m " ToutRq " '" Rqlite "/nodes?timeout=5s'"
	resp=""
	while ((c | getline l) > 0) resp = resp l
	close(c)
	if (resp=="") return -1
	n = split(resp, tr, "}")
	for (i=1;i<=n;i++){
		# 'ip ":"' y no solo 'ip': sin los dos puntos, 192.168.1.9 casaria dentro
		# de 192.168.1.91 y se leeria la salud del nodo equivocado.
		if (index(tr[i], ip ":") > 0){
			if (tr[i] ~ /"reachable"[ ]*:[ ]*true/) return 1
			return 0
		}
	}
	return -1
}

function Campo(txt,clave,   m){
	if (match(txt, "\042" clave "\042[ ]*:[ ]*\042([^\042]*)\042", m)) return m[1]
	if (match(txt, "\042" clave "\042[ ]*:[ ]*(-?[0-9.]+)", m)) return m[1]
	return ""
}

# Puntuacion. Mas alta = mejor Wheel. Explicada termino a termino para que se
# pueda ajustar sin adivinar.
function Puntuar(n,   s,up,tmp,car,ocu,col,rtt,lim,base){
	if (Elegible[n]!=1) return -1                    # excluido por configuracion
	# El umbral depende de DONDE se mide: 50 C es el limite de BATERIA que usa
	# thermal-guard en los telefonos, pero la CPU de un mini-PC ronda los 60-70 C
	# en reposo y estaria sana. Aplicar el umbral de bateria a un sensor de CPU
	# descalificaba injustamente a los Ubuntu (visto con sentinel016 a 68 C).
	lim = (Fuente[n]=="cpu") ? CritCpu : CritBat
	if (Temp[n] >= lim && Temp[n] > 0) return -1
	if (Queued[n] >= MaxQ[n] && MaxQ[n] > 0) return -1 # saturado: fuera

	s = 100

	# Disponibilidad: lo que mas pesa. Se satura a una semana para que un nodo
	# con meses de uptime no sea inamovible pase lo que pase.
	up = Uptime[n] / 3600
	if (up > 168) up = 168
	s += up * 0.5                                     # hasta +84

	# Equipo siempre encendido (mini-PC) frente a telefono con bateria: es el
	# factor practico que mas distingue la disponibilidad real en esta flota.
	if (Estable[n] == 1) s += 40

	# Calor: penaliza a partir de 35 C y descalifica en CRIT.
	tmp = Temp[n]
	base = (Fuente[n]=="cpu") ? 60 : 35        # a partir de aqui penaliza
	if (tmp > base) s -= (tmp - base) * 2

	# Carga del sistema y ocupacion del propio agente.
	car = Carga[n];  if (car > 0) s -= car * 5
	ocu = (MaxJ[n] > 0) ? (Inflight[n] / MaxJ[n]) : 0
	s -= ocu * 20
	col = Queued[n]; if (col > 0) s -= col * 2

	# Lentitud en responder, medida por quien puntua.
	rtt = Rtt[n]; if (rtt > 0) s -= rtt / 50

	# Histeresis: el Wheel actual parte con ventaja. Sin esto, dos nodos
	# parecidos se turnarian el mando cada pocos minutos, que es justo lo que
	# hay que evitar.
	if (EsWheel[n] == 1) s += 15

	return s
}

BEGIN {
	Port     = (length(port)==0)     ? 8181 : port
	Tout     = (length(timeout)==0)  ? 3    : timeout
	CritBat  = (length(critbat)==0)  ? 50 : critbat+0   # bateria (thermal-guard)
	CritCpu  = (length(critcpu)==0)  ? 85 : critcpu+0   # CPU (limite tipico)
	Self     = self
	State    = state
	Token    = token          # sin esto se sondea sin credencial y todo responde 401
	Discover = discover       # ruta a Sentinel-Discover.awk (para no elegir a ciegas)
	Cidr     = cidr
	Spool    = (length(spool)==0) ? "/tmp" : spool
	Rqlite   = rqlite         # el cluster ya sabe que nodos hay: sale mas barato que barrer
	# Rondas seguidas que el Wheel reinante puede faltar antes de relevarlo.
	MaxMiss  = (length(maxmiss)==0) ? 2 : maxmiss+0
	MissFile = State ".miss"
	# IP del Wheel, recordada mientras responde: cuando deja de hacerlo ya no hay
	# forma de averiguarla, y hace falta para preguntarle a rqlite por el.
	IpFile   = State ".ip"
	# Paciencia con rqlite al pedirle la segunda opinion. Generosa a proposito:
	# /nodes NO responde de memoria: sondea a todos los peers en vivo, asi que
	# tarda MAS justo cuando la red va mal, que es exactamente cuando se le
	# pregunta. Con 4 s se perdio una corroboracion (sentinel005, 17/08 19:15,
	# "sin segunda opinion") y ese nodo relevo al Wheel por su propia ceguera.
	# Solo se paga esta espera cuando ya se iba a destronar al coordinador.
	ToutRq   = (length(toutrq)==0) ? 10 : toutrq+0

	# Lista de candidatos SIN barrer la red. Un barrido /24 lanza cientos de
	# curl y en Android eso despierta al phantom process killer, que se llevo por
	# delante al propio aceptador (se reiniciaba cada 5 min, justo al elegir).
	# El clúster rqlite ya sabe que nodos existen: preguntarselo cuesta UNA
	# peticion. El barrido queda para Sentinel-Discover.awk, que se ejecuta
	# aparte y con calma.
	nrq=0
	if (Rqlite != ""){
		c = "curl -s -m 6 '" Rqlite "/nodes?timeout=2s'"
		resp=""
		while ((c | getline l) > 0) resp = resp l
		close(c)
		nrq=0
		while (match(resp, /([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/, mm)){
			Cand[mm[1]] = 1; DeRqlite[mm[1]] = 1; nrq++
			resp = substr(resp, RSTART+RLENGTH)
		}
		if (debug==1) printf "[wheel] rqlite aporto %d candidatos\n", nrq
	}

	# Candidatos: los vecinos que conozca el descubrimiento, mas uno mismo.
	n=0
	if (peers != ""){
		FS="\t"
		while ((getline line < peers) > 0){
			split(line, f, "\t")
			if (f[1] != "") { Cand[f[1]] = 1 }
		}
		close(peers)
	}
	Cand["127.0.0.1"] = 1                 # siempre se puntua a uno mismo

	# Quien manda ahora y cuantas rondas seguidas lleva sin dar señales. Se lee
	# ANTES de sondear porque de ello depende si se le puede relevar.
	anterior=""
	if ((getline anterior < State) > 0) gsub(/[[:space:]]/,"",anterior)
	close(State)
	fallos=0
	if ((getline lm < MissFile) > 0) fallos = lm+0
	close(MissFile)

	# Recoger /fitness de cada candidato.
	vivos=0
	for (ip in Cand){
		t0 = systime()
		txt = Prueba(ip)
		if (txt !~ /nombre/) { if (debug==1) printf "[wheel] %s no responde\n", ip; SinResp = SinResp " " ip; continue }
		nm = Campo(txt,"nombre")
		if (nm=="") continue
		# El RTT se saca del propio curl (-w). Si no llega, se estima con systime.
		if (match(txt,/RTT:([0-9.]+)/,mm)) Rtt[nm] = mm[1] * 1000
		else Rtt[nm] = (systime() - t0) * 1000
		Ip[nm]       = ip
		Vivo[ip]     = nm
		Elegible[nm] = Campo(txt,"elegible") + 0
		EsWheel[nm]  = Campo(txt,"wheel") + 0
		Uptime[nm]   = Campo(txt,"uptime") + 0
		Temp[nm]     = Campo(txt,"temp") + 0
		Carga[nm]    = Campo(txt,"carga") + 0
		Inflight[nm] = Campo(txt,"inflight") + 0
		MaxJ[nm]     = Campo(txt,"maxjobs") + 0
		Queued[nm]   = Campo(txt,"queued") + 0
		MaxQ[nm]     = Campo(txt,"maxqueue") + 0
		Estable[nm]  = Campo(txt,"estable") + 0
		Fuente[nm]   = Campo(txt,"fuente_temp")
		vivos++
	}


	# Quien no contesto esta ronda. Una linea solo cuando falta alguien, y sirve
	# para distinguir "se me cayo la radio" (faltan varios) de "no llego a UNO"
	# (falta uno concreto). Sin esto solo se sabia que faltaba el Wheel, que es
	# justo el dato que no permite decidir de quien es la culpa.
	if (SinResp != "") printf "sin respuesta:%s\n", SinResp
	if (vivos==0){
		# Sin datos no se decide nada: dejar el Wheel como estaba es mas seguro
		# que nombrar uno a ciegas.
		print "sin candidatos que puntuar; no se toca el Wheel actual"
		exit 0
	}

	# --- QUORUM: no coronar a nadie con una vision parcial de la red ---------
	# Sin esto, un nodo que solo alcanza a unos pocos (telefono cargado, WiFi
	# regular, sondeos que expiran) elige "al mejor de los que ve"... que suele
	# ser el mismo, y se autoproclama. Pasa justo despues de un reinicio masivo
	# del estado: varios nodos se coronaron a la vez y llegaron avisos duplicados
	# de cuatro "Wheels" distintos (visto el 2026-08-15).
	totalCand=0
	for (ip in Cand) if (ip != "127.0.0.1") totalCand++

	# Caso peor: no veo a NADIE mas que a mi. Es indistinguible de estar aislado,
	# asi que solo me corono si la red aun no tiene Wheel (arranque en frio). Si
	# ya habia uno, se respeta: un nodo incomunicado no puede quitarle el mando a
	# quien probablemente siga sano.
	if (vivos<=1 && anterior!="" && anterior!=Self){
		printf "solo me veo a mi mismo y ya hay Wheel (%s): no lo toco\n", anterior
		exit 0
	}
	# Caso general: hace falta ver a la MAYORIA de los candidatos conocidos.
	if (totalCand >= 3 && vivos*2 <= totalCand){
		printf "solo veo %d de %d nodos: vision parcial, no me corono y dejo el Wheel como esta\n", vivos, totalCand
		exit 0
	}

	# --- EL WHEEL REINANTE NO CAE POR UN SONDEO PERDIDO ----------------------
	# El quorum de arriba solo salta ante una particion grande: perder de vista a
	# UN nodo pasa por debajo del radar. Pero si ese nodo es justamente el Wheel,
	# cualquiera coronaba a otro al instante y la red se quedaba con dos
	# coordinadores avisando a la vez (pasaba varias veces al dia: sentinel002 el
	# 17/08 a las 07:05, sentinel005 a las 08:40, sentinel010 el 16/08).
	# Ahora hace falta que falte en MaxMiss rondas SEGUIDAS. Cuesta un relevo mas
	# lento cuando el Wheel muere de verdad (~10 min), a cambio de no relevarlo
	# por un hipo de WiFi, que es lo que pasaba casi siempre.
	if (anterior != "" && !(anterior in Ip)){
		fallos++
		if (fallos < MaxMiss){
			print fallos > MissFile
			close(MissFile)
			printf "el Wheel (%s) no responde (ronda %d de %d): no lo relevo todavia\n", anterior, fallos, MaxMiss
			exit 0
		}
		# Antes de destronarlo, una segunda opinion por OTRO camino de red. Sin
		# esto, un nodo con mal enlace se queda ciego el solo y relega al Wheel
		# aunque el resto de la flota lo vea perfectamente (le paso a sentinel005
		# el 17/08 a las 11:45: corono a sentinel014 durante 10 min mientras los
		# otros nueve nodos seguian viendo a sentinel016 sin problema).
		ipw=""
		if ((getline ipw < IpFile) > 0) gsub(/[[:space:]]/,"",ipw)
		close(IpFile)
		alc = WheelAlcanzable(ipw)
		if (alc == 1){
			print 0 > MissFile
			close(MissFile)
			printf "no alcanzo al Wheel (%s) por HTTP, pero rqlite SI lo ve: la ceguera es mia, no lo relevo\n", anterior
			exit 0
		}
		printf "el Wheel (%s) lleva %d rondas sin responder%s: procede el relevo\n", anterior, fallos, \
			(alc==0 ? " y rqlite tampoco lo alcanza" : " (sin segunda opinion)")
	} else if (anterior != ""){
		if (fallos != 0){
			print 0 > MissFile      # volvio a dar señales: contador a cero
			close(MissFile)
		}
		if (anterior in Ip){        # recordar donde vive, para poder preguntar por el
			print Ip[anterior] > IpFile
			close(IpFile)
		}
	}

	# --- Refresco de peers.tsv -----------------------------------------------
	# peers.tsv es el plan B cuando rqlite no contesta, asi que se reescribe justo
	# cuando SI contesta: guarda la ultima foto buena. Antes solo lo escribia el
	# descubrimiento, que no estaba programado en ningun sitio, y los ficheros
	# llevaban 4 dias congelados, incompletos (a sentinel005 le faltaban 5 nodos,
	# incluido el propio Wheel) y marcando como Wheel a uno que ya no lo era.
	#
	# Se guardan los del cluster MAS los que hayan respondido, y NADA de lo que ya
	# hubiera en el fichero: si se copiara a si mismo, una IP retirada seguiria
	# ahi para siempre, y ademas inflaria el recuento del quorum.
	#
	# Solo se toca si rqlite contesto (nrq>0): sin autoridad no se pisa la ultima
	# foto buena, que es justo para lo que existe este fichero.
	if (peers != "" && nrq > 0 && vivos > 1){
		for (ip in DeRqlite) Guardar[ip] = 1
		for (ip in Vivo) if (ip != "127.0.0.1") Guardar[ip] = 1
		Tmp = peers ".tmp"
		ne = 0; ahora = systime()
		for (ip in Guardar){
			nm = Vivo[ip]
			if (nm == ""){ ver = "(sin respuesta)"; rol = "eye" }
			else {
				rol = (EsWheel[nm]==1) ? "wheel" : "eye"
				# Misma cadena que devolveria /version, por la misma regla.
				ver = (rol=="wheel") ? "Sentinel Super 2.0.0" : "Sentinel 2.0.0"
			}
			printf "%s\t%s\t%s\t%d\n", ip, ver, rol, ahora > Tmp
			ne++
		}
		close(Tmp)
		# Se deja en .tmp a proposito: quien lo pone en su sitio es elect.sh, que
		# tiene mv de verdad. Escribir encima del fichero bueno desde awk abriria
		# una ventana en la que otro proceso podria leerlo a medias, y media IP se
		# convierte en un candidato fantasma que descuadra el quorum.
		if (debug==1) printf "[wheel] peers.tsv.tmp con %d nodos\n", ne
	}

	# Elegir por puntuacion; empate por nombre para que todos coincidan.
	mejor=""; mejorPts=-1
	for (nm in Ip){
		p = Puntuar(nm)
		if (debug==1) printf "[wheel] %-14s pts=%.1f up=%ds temp=%s carga=%s ocup=%s/%s cola=%s estable=%s eleg=%s\n", \
			nm, p, Uptime[nm], Temp[nm] "(" Fuente[nm] ")", Carga[nm], Inflight[nm], MaxJ[nm], Queued[nm], Estable[nm], Elegible[nm]
		if (p < 0) continue
		if (p > mejorPts || (p == mejorPts && nm < mejor)){ mejor=nm; mejorPts=p }
	}

	if (mejor==""){
		print "ningun candidato apto (calor, saturacion o no elegibles); no se toca el Wheel actual"
		exit 0
	}

	# Escribir el resultado solo si cambia, para no reescribir el fichero cada
	# ciclo ni ensuciar el log con relevos que no existen. 'anterior' ya se leyo
	# arriba, al comprobar el quorum.
	if (anterior != mejor){
		print mejor > State
		close(State)
		print 0 > MissFile          # empieza mandato nuevo: contador limpio
		close(MissFile)
		printf "Wheel: %s -> %s (%.1f puntos)\n", (anterior==""?"(ninguno)":anterior), mejor, mejorPts
	} else {
		printf "Wheel sigue siendo %s (%.1f puntos)\n", mejor, mejorPts
	}
	exit 0
}
