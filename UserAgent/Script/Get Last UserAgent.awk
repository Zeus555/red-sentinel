function GetURL(vUrl){
	RSOLD=RS
	RS="^$"	

	cmdCurl="curl -s " vUrl 
	cmdCurl=length(UserAgent)>0 ? cmdCurl " -A \042" UserAgent "\042 2>Nul" : cmdCurl

	cmdCurl |& getline vLine
	close(cmdCurl)
	RS=RSOLD
	return vLine
}

BEGIN{
	OFS=";"

	# Directorios de trabajo.
	DirRaiz ="D:\\RED Sentinel\\UserAgent\\"
	DirScript =DirRaiz "Script\\"
	DirDatos =DirRaiz "Datos\\"

	# Service of DB.
	ServiceDB="sqlite3 \042" DirDatos "UserAgent.db\042 \042.timeout 15000\042 "

	# Default User Agent.
	URL="https://www.useragents.me/#most-common-desktop-useragents-json-csv"

	# Establecemos el user agent del buscador que intentamos simular.
	UserAgent=ENVIRON["UserAgent"]

	# Obtener la pagina HTML.
	Data=GetURL(URL)

	# Parsear la URL.
	n=split(Data,aDat,".textarea class=.form-control. rows=.8.>")
	for (i=1;i<=n;i++){
		# Dividir el JSON.
		m=split(aDat[i],aDat2,"{\042ua\042: \042")
		for (j=1;j<=m;j++){
			# Limpiar el nombre del useragent.
			if (match(aDat2[j], /^(([A-Z][a-z]+\/[0-9].[0-9][0-9]?) .+)\042, \042pct\042. .+}[,\]]/,aDat3)){
				couUA++
				UserAgent=aDat3[1]
				# Agregar cero al final si termina con un punto.
				if (substr(UserAgent,length(UserAgent),1)==".") UserAgent= UserAgent "0"
				
				# Exportar a variable de ambiente.
				if (UserAgent ~/Edg/ && defaultAG==""){
					defaultAG=UserAgent
					cmd="setx UserAgent \042" UserAgent "\042"
					system(cmd);close(cmd)
				}
				
				SQL="\042BEGIN TRANSACTION;"
				SQL=SQL "insert or ignore into dwd_user_agent(name) values ('" UserAgent "');"
				SQL =SQL "COMMIT;\042"
				cmd =ServiceDB SQL;
				system(cmd);close(cmd)
			}
		}
	}
	print "{\"status\":\"Ok\",\"message\":\"" couUA" user-agent insertados.\"}"
}

