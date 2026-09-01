@echo off

:: Codificacion UTF-8
chcp 65001 >Nul

:: Seteamos ambiente para usar variables retrasadas.
SETLOCAL ENABLEDELAYEDEXPANSION

:: Directorios de trabajo.
set DirRaiz=D:\RED Sentinel\Wheel\
set DirScript=%DirRaiz%Script\
set DirTemporal=%DirRaiz%Temporal\
set DirDatos=%DirRaiz%Datos\
set DirLog=%DirRaiz%Log\

:: BD Sentinel
set SentinelDB=sqlite3 "%DirDatos%Hot.db"

:: Comando para obtener lista de IP's de cada uno de los Eye's.
set cmdGetList=%SentinelDB% "select * from dwv_eyes_curr;"

:: Extraer las versiones y variables de ambiente de los EYES.
for /F "tokens=*" %%j in ('%cmdGetList%') do (
	:: Version de todos los EYES.
	for /F "tokens=*" %%a in ('curl -s --connect-timeout 0.7 --max-time 1 http://%%j:8081/sentinelversion') do (
		rem echo %%j --^> %%a
		set %%j_version=%%a
	)

	for %%r in (PathSentinel MyIP UserAgent IpWheel OS Name IP_Simulador) do (
		for /F "tokens=* delims=: " %%a in ('curl -s --connect-timeout 0.7 --max-time 1 http://%%j:8081/sentinel/var/%%r') do (
			set var=%%j_%%r
			set val=%%a
			set "!var!=!val!"
			rem if defined !var! ( echo !var! --^> !val! )
		)
	)
)

:: Imprimir en pantalla todos las variables.
echo ######################################################
echo #################### VARIABLES #######################
for %%r in (version PathSentinel MyIP UserAgent IpWheel OS Name IP_Simulador) do (
	set Imp=..... %%r .....................................................................
	echo !Imp:~0,52!
	for /F "tokens=*" %%z in ('%cmdGetList%') do (
		set var=%%z_%%r
		set val=!%%z_%%r!
		
		if defined !var! ( echo !var! --^> !val! )
	)
)

:: Extraer el CRONTAB de cada uno de los EYES en caso que no sean Windows.
echo.
echo ####################################################
echo #################### CRONTAB #######################
for /F "tokens=*" %%y in ('%cmdGetList%') do (
	rem echo !%%y_OS!
	set xOS=!%%y_OS!
	set xOS=!xOS:{"OS": "=!
	set xOS=!xOS:"}=!
	set xName=!%%y_Name!
	set Imp=Eye: !xName!^(%%y^) OS:!xOS! ..............................................................

	if defined xOS if NOT "!xOS!"=="Windows" (
		echo !Imp!
		cd "%DirScript%"
		for /F "tokens=*" %%b in ('gawk -v Tout^=2000 -v Port^=8081 -v IP_DEST^=%%y -v CMD^="CMD: crontab -l" -f Sentinel-Client.awk') do (
			set line=%%b
			set ln1=!line:~0,1!

			if NOT "!ln1!"=="#" echo %%y ... !line!
		)
	)
)

exit 0