# Sentinel v2 - Descubrimiento de la red (Fase 4).
#
# Sustituye al barrido del v1, que era secuencial (0,5 s por host => ~127 s en un
# /24) y ademas SOLO funcionaba con mascara 255.255.255.0.
#
# Tres fuentes, en orden (modelo hibrido decidido para el v2):
#   1. rqlite  -v rqlite=http://<ip>:4001   consulta el registro del cluster
#   2. gossip  -v gossip=<ip>[,<ip>...]     pide /peers a vecinos conocidos
#   3. barrido de red                       arranque en frio / autocuracion
# Las tres se fusionan; ninguna es obligatoria. Un nodo fuera del cluster sigue
# descubriendo por gossip o barrido.
#
# El barrido es PARALELO por lotes: lanza `batch` sondas en segundo plano contra
# un spool y despues cosecha, en vez de esperar host por host.
#
# Invocacion:
#   gawk -v cidr=192.168.1.0/24 -v port=8181 -v spool=DIR -v out=peers.tsv \
#        [-v batch=32] [-v maxhosts=512] [-v timeout=0.5] \
#        [-v rqlite=URL] [-v gossip=IP,IP] [-v debug=1] -f Sentinel-Discover.awk
#
# Sin -v cidr lo deduce del sistema (ipconfig/ifconfig).
# Salida: fichero TSV  ip <TAB> version <TAB> rol(wheel|eye) <TAB> epoch
# y por stdout un resumen  "encontrados=N wheel=IP".

function DetectShell(   r,c){
	c="echo p=$0"; r=""; c | getline r; close(c)
	return (r ~ /\$0/) ? "cmd" : "posix"
}
function Dormir(s){
	if (Shell=="cmd") system("ping -n " int(s+1) " 127.0.0.1 >NUL 2>&1")
	else              system("sleep " s)
}
function Devnull(){ return (Shell=="cmd") ? ">NUL 2>&1" : ">/dev/null 2>&1" }

# ---- Aritmetica de red: generaliza cualquier mascara, no solo /24 ----
function Ip2Num(ip,   a){
	if (split(ip,a,".")!=4) return -1
	return a[1]*16777216 + a[2]*65536 + a[3]*256 + a[4]
}
function Num2Ip(n){
	return sprintf("%d.%d.%d.%d", int(n/16777216)%256, int(n/65536)%256, int(n/256)%256, n%256)
}
# Convierte 255.255.254.0 -> 23. Devuelve -1 si no es una mascara contigua valida.
function Mask2Bits(m,   n,b,i,seen0){
	n=Ip2Num(m); if (n<0) return -1
	b=0; seen0=0
	for (i=31;i>=0;i--){
		if (int(n / (2^i)) % 2 == 1){ if (seen0) return -1; b++ } else seen0=1
	}
	return b
}
function BitsToSize(bits){ return 2^(32-bits) }

# ---- Descubrir IP y mascara propias ----
function GetSelf(   cmd,line,n,f){
	SelfIP=""; SelfMask=""
	if (Shell=="cmd" || OSName=="Windows"){
		cmd="ipconfig"
		while((cmd | getline line)>0){
			if (match(line,/IPv4[^:]*: *([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/,f) && SelfIP=="") SelfIP=f[1]
			if (match(line,/Mask[^:]*: *([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/,f) && SelfMask=="") SelfMask=f[1]
			if (SelfIP!="" && SelfMask!="") break
		}
		close(cmd)
	}
	if (SelfIP=="" ){
		cmd="ifconfig 2>/dev/null || ip -o -f inet addr show 2>/dev/null"
		while((cmd | getline line)>0){
			# ifconfig BSD/moderno:  inet 192.168.1.5 netmask 0xffffff00 | netmask 255.255.255.0
			if (match(line,/inet (addr:)?([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+).*(netmask|Mask:) *(0x[0-9a-fA-F]+|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/,f)){
				if (f[2] !~ /^127\./ && SelfIP==""){
					SelfIP=f[2]; SelfMask=f[4]
					if (SelfMask ~ /^0x/) SelfMask=HexMask(SelfMask)
				}
			}
			# ip -o -f inet:  "2: wlan0    inet 192.168.1.5/24 brd ..."
			else if (match(line,/inet ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\/([0-9]+)/,f)){
				if (f[1] !~ /^127\./ && SelfIP==""){ SelfIP=f[1]; SelfBits=f[2]+0 }
			}
		}
		close(cmd)
	}
}
function HexMask(h,   v){ v=strtonum(h); return Num2Ip(v) }

# ---- Sonda: lanza una peticion a /version en segundo plano contra el spool ----
function Probe(ip,   f,c){
	f = SpoolDir ip ".out"
	if (Shell=="cmd"){
		c = "start \042\042 /B curl -s -m " Tout " -o \042" f "\042 \042http://" ip ":" Port "/version" TokQS "\042"
	} else {
		c = "curl -s -m " Tout " -o '" f "' 'http://" ip ":" Port "/version" TokQS "' >/dev/null 2>&1 &"
	}
	system(c)
}

# Lee un resultado del spool y lo registra si es un Sentinel.
function Harvest(ip,   f,line,got,ver){
	f = SpoolDir ip ".out"
	got=0; ver=""
	while((getline line < f)>0){
		if (line ~ /Sentinel/){
			got=1
			if (match(line,/\042version\042 *: *\042([^\042]+)\042/,vv)) ver=vv[1]
			else if (match(line,/\042Version\042 *: *\042([^\042]+)\042/,vv)) ver=vv[1]
			else ver="Sentinel"
		}
	}
	close(f)
	system((Shell=="cmd" ? "del /f /q \042" f "\042 " : "rm -f '" f "' ") Devnull())
	if (got){
		AddPeer(ip, ver, (ver ~ /Super/) ? "wheel" : "eye")
		return 1
	}
	return 0
}

function AddPeer(ip,ver,rol){
	if (ip in Peers) return 0
	Peers[ip]=ver; Role[ip]=rol
	if (rol=="wheel") Wheel=ip
	return 1
}

# ---- Fuente 1: rqlite (si el nodo pertenece al cluster) ----
function FromRqlite(   c,line,n,f){
	if (RqliteURL=="") return 0
	c = "curl -s -m 3 -G '" RqliteURL "/db/query' --data-urlencode 'level=none' " \
	    "--data-urlencode 'q=select ip from dwd_wheels' 2>/dev/null"
	n=0
	while((c | getline line)>0){
		while (match(line,/([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/,f)){
			if (AddPeer(f[1],"(rqlite)","eye")) n++
			line=substr(line,RSTART+RLENGTH)
		}
	}
	close(c)
	if (debug==1) printf "[discover] rqlite aporto %d\n", n
	return n
}

# ---- Fuente 2: gossip (pedir /peers a vecinos conocidos) ----
function FromGossip(   i,k,c,line,f,n,lst){
	if (GossipList=="") return 0
	n=0; k=split(GossipList,lst,",")
	for (i=1;i<=k;i++){
		if (lst[i]=="") continue
		c = "curl -s -m 3 'http://" lst[i] ":" Port "/peers" TokQS "' 2>/dev/null"
		while((c | getline line)>0){
			while (match(line,/([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/,f)){
				if (AddPeer(f[1],"(gossip)","eye")) n++
				line=substr(line,RSTART+RLENGTH)
			}
		}
		close(c)
	}
	if (debug==1) printf "[discover] gossip aporto %d\n", n
	return n
}

# ---- Fuente 3: barrido paralelo por lotes ----
function Sweep(   net,bits,size,first,last,i,ip,inbatch,found,total,pend,j){
	if (Cidr==""){ if (debug==1) print "[discover] sin rango que barrer"; return 0 }
	split(Cidr,cc,"/")
	net=Ip2Num(cc[1]); bits=cc[2]+0
	if (net<0 || bits<0 || bits>32){ print "[discover] CIDR invalido: " Cidr; return 0 }
	size=BitsToSize(bits)
	net = net - (net % size)                  # direccion de red
	if (bits>=31){ first=net; last=net+size-1 } # /31 y /32 no tienen red/broadcast
	else         { first=net+1; last=net+size-2 }

	total = last-first+1
	if (total > MaxHosts){
		# Nunca truncar en silencio: se dice cuanto se deja fuera.
		printf "[discover] AVISO: %d hosts en %s supera maxhosts=%d; se barren los primeros %d\n", \
			total, Cidr, MaxHosts, MaxHosts
		last = first + MaxHosts - 1
		total = MaxHosts
	}
	if (debug==1) printf "[discover] barriendo %s: %d hosts, lotes de %d, timeout %s\n", Cidr, total, Batch, Tout
	# dryrun: calcula el rango y no envia ni una sonda (util para comprobar que se
	# va a barrer lo que uno cree, sin tocar la red).
	if (dryrun==1){ printf "[discover] dryrun: %s .. %s\n", Num2Ip(first), Num2Ip(last); return 0 }

	found=0; inbatch=0
	for (i=first;i<=last;i++){
		ip=Num2Ip(i)
		if (ip==SelfIP) continue
		Probe(ip); Pending[++pend]=ip; inbatch++
		if (inbatch>=Batch){
			Dormir(Tout+0.4)                    # margen sobre el --max-time de curl
			for (j=1;j<=pend;j++) found += Harvest(Pending[j])
			delete Pending; pend=0; inbatch=0
		}
	}
	if (pend>0){
		Dormir(Tout+0.4)
		for (j=1;j<=pend;j++) found += Harvest(Pending[j])
	}
	if (debug==1) printf "[discover] barrido aporto %d\n", found
	return found
}

BEGIN {
	Shell = DetectShell()
	Port  = (length(port)==0)     ? 8181 : port
	Batch = (length(batch)==0)    ? 32   : batch+0
	MaxHosts=(length(maxhosts)==0)? 512  : maxhosts+0
	if (MaxHosts<=0) MaxHosts=4294967296          # <=0 significa sin limite
	Tout  = (length(timeout)==0)  ? 0.5  : timeout
	# El token de flota viaja en cada sonda: sin el, los nodos no responden ni la
	# version, que es justo lo que impide a un agente ajeno descubrir la red.
	TokQS = (length(token)==0) ? "" : "?token=" token
	RqliteURL = rqlite
	GossipList= gossip
	OutFile   = out
	Cidr      = cidr

	SpoolDir = (length(spool)==0) ? "." : spool
	if (SpoolDir !~ /[\/\\]$/) SpoolDir = SpoolDir "/"

	# Si no dieron rango, deducirlo del sistema.
	if (Cidr==""){
		GetSelf()
		if (SelfIP!=""){
			if (SelfBits=="" && SelfMask!="") SelfBits=Mask2Bits(SelfMask)
			if (SelfBits=="" || SelfBits<0){
				print "[discover] no se pudo determinar la mascara; usa -v cidr=..."
			} else {
				Cidr = SelfIP "/" SelfBits
				if (debug==1) printf "[discover] propio: %s mascara %s => %s\n", SelfIP, SelfMask, Cidr
			}
		}
	}

	Wheel=""
	FromRqlite()
	FromGossip()
	Sweep()

	n=0
	if (OutFile!=""){
		for (ip in Peers){
			printf "%s\t%s\t%s\t%d\n", ip, Peers[ip], Role[ip], systime() > OutFile
			n++
		}
		close(OutFile)
	} else { for (ip in Peers) n++ }

	printf "encontrados=%d wheel=%s\n", n, (Wheel==""?"-":Wheel)
	exit 0
}
