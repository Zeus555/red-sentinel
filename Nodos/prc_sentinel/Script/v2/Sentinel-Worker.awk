# Sentinel v2 - Worker desprendido.
# Ejecuta UNA accion de la lista blanca y escribe el resultado en el spool.
# NO escucha ningun puerto. El aceptador lo lanza en segundo plano y sigue libre.
# Invocacion:
#   gawk -v job=ID -v jobs=DIR -v Port=P -v action=A -v param=V -v run=DIR_Run \
#        -v allow=CONF -f Sentinel-Worker.awk

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

# Detecta el shell que usa gawk system(): "cmd" o "posix".
function DetectShell(   r,c){
	c="echo p=$0"; r=""; c | getline r; close(c)
	return (r ~ /\$0/) ? "cmd" : "posix"
}
function PlatClass(sh){ return (sh=="cmd") ? "win" : "nix" }

function IsNum(s){ if (s ~ /[[:cntrl:]]/) return 0; return (s ~ /^[0-9]+$/) }
function IsIP(s,   a,i,n){
	if (s ~ /[[:cntrl:]]/) return 0
	if (s !~ /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/) return 0
	n=split(s,a,"."); if (n!=4) return 0
	for (i=1;i<=4;i++){ if (a[i]+0>255) return 0 }
	return 1
}

function LoadAllow(path,   saveFS,saveRS,line,f){
	saveFS=FS; saveRS=RS; FS="|"; RS="\n"
	while ((getline line < path) > 0){
		if (line ~ /^[ \t]*#/ || line ~ /^[ \t]*$/) continue
		split(line,f,"|")
		aType[f[1]] = f[2]
		aCmd[f[1] SUBSEP f[3]] = f[4]
	}
	close(path)
	FS=saveFS; RS=saveRS
}

# En el texto de reemplazo de gsub, '&' significa "lo que caso" — un valor con &
# se expandiria a la propia marca ({run}) y corromperia el comando. Hay que
# escaparlo para que se inserte literal.
function EscAmp(s){ gsub(/&/,"\\\\&",s); return s }

# Construye el comando final desde la plantilla. {p}=param {p1}=param+1 {run}=DirRun.
# Ningun byte crudo del cliente: param ya fue tipado por el aceptador y re-validado aqui.
function BuildCmd(action,param,sh,   tpl,cls){
	cls=PlatClass(sh)
	tpl=aCmd[action SUBSEP cls]
	if (tpl=="") return ""
	gsub(/\{run\}/, EscAmp(RunDir), tpl)
	gsub(/\{p1\}/,  EscAmp(param+1), tpl)
	gsub(/\{p\}/,   EscAmp(param),   tpl)
	return tpl
}

function WriteStatus(id,a,p,st,rc,res,   f){
	gsub(/[\r\n\t]/," ",res)
	f = JobsDir id ".status"
	printf "id\t%s\naction\t%s\nparam\t%s\nstatus\t%s\nrc\t%s\nresult\t%s\nts\t%s\n", id,a,p,st,rc,res,systime() > f
	close(f)
}

function Callback(   cb,u){
	if (Port=="") return
	u = "http://127.0.0.1:" Port "/done/" job
	# El token se hereda del entorno del servidor (SENTINEL_TOKEN): no viaja por
	# argv para no quedar visible en la lista de procesos. -v token= sigue valiendo.
	Tok = (length(token)>0) ? token : ENVIRON["SENTINEL_TOKEN"]
	if (Tok!="") u = u "?token=" Tok
	if (Shell=="cmd"){ cb = "curl -s \042" u "\042 >NUL 2>&1" }
	else             { cb = "curl -s '" u "' >/dev/null 2>&1" }
	system(cb); close(cb)
}

# Re-valida el parametro contra el tipo declarado (defensa en profundidad).
function ParamOk(action,param,   t){
	t=aType[action]
	if (t=="none") return (param=="")
	if (t=="num")  return IsNum(param)
	if (t=="ip")   return IsIP(param)
	return 0
}

BEGIN {
	OS    = LoadOS()
	Shell = DetectShell()
	RunDir= run
	JobsDir = jobs
	if (JobsDir !~ /[\/\\]$/) JobsDir = JobsDir "/"

	LoadAllow(allow)

	if (!(action in aType)){
		WriteStatus(job,action,param,"rejected","","accion no permitida"); Callback(); exit 0
	}
	if (!ParamOk(action,param)){
		WriteStatus(job,action,param,"rejected","","parametro invalido para el tipo"); Callback(); exit 0
	}

	command = BuildCmd(action,param,Shell)
	if (command==""){
		WriteStatus(job,action,param,"rejected","","sin plantilla para esta plataforma"); Callback(); exit 0
	}

	WriteStatus(job,action,param,"running","","")

	RS="\n"; res=""
	while ((command | getline l) > 0){ res = (res=="") ? l : res " " l }
	rc = close(command)

	WriteStatus(job,action,param,"done",rc,res)
	Callback()
	exit 0
}
