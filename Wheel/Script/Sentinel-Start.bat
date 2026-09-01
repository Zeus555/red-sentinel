@echo off

:: Codificacion UTF8
chcp 65001 >Nul

:: Seteamos ambiente para usar variables retrasadas.
SETLOCAL ENABLEDELAYEDEXPANSION

:: Directorio donde se encuenta funciones de EPOC
set DirEpoch=D:\Librerias\FUN Epoch\Script\

:: Obtenemos fecha y hora actual.
call :ObtieneFecha
call :Epoch

:: Directorios de trabajo.
set DirRaiz=D:\RED Sentinel\Wheel\
set DirScript=%DirRaiz%Script\
set DirTemporal=%DirRaiz%Temporal\
set DirRun=%DirRaiz%Run\
set DirDatos=%DirRaiz%Datos\
set DirLog=%DirRaiz%Log\

:: Directorio por defecto del servicio.
D:
cd %DirRun%

:: Obtener la fecha de hoy.
set Hoy=%YYYYMMDD%
set /a IdExec=%Epoch%

:: Ficheros LOG.
set FchStart=%DirLog%%Hoy%_Sentinel-Start.log
set FchServer=%DirLog%%Hoy%_Sentinel-Server.log

:: Difinir rango de puertos de ejecucion.
set /a Port=8081
set /a LastPort=8100

echo [%YYYYMMDD_HH24_MI_SS_ML%][Sentinel Start] ... Start. >> "%FchStart%"

:: Version actual de sentinel.
for /F "tokens=*" %%a in ('"curl -s --connect-timeout 0.325 --max-time 0.35 http://localhost:%Port%/sentinelversion"') do (set Version1=%%a)

:: En caso no este en ejecucion, ejecutarlo en segundo plano.
call :ObtieneFecha
if !Version1! == "" (	
	echo [%YYYYMMDD_HH24_MI_SS_ML%][Sentinel Start] ... Levantar servicio Sentinel. >> "%FchStart%"
	for /L %%a in (%Port%,1,%LastPort%) do (
		start "" /b gawk -v Port=%%a -v LastPort=%LastPort% -f "%DirScript%Sentinel-Server.awk"
	)
) else (
	echo [%YYYYMMDD_HH24_MI_SS_ML%][Sentinel Start] ... Reiniciando servicio Sentinel. >> "%FchStart%"
	for /L %%a in (%Port%,1,%LastPort%) do (
		curl -s --connect-timeout 0.325 --max-time 0.35 http://localhost:%%a/sentinelshutdown
		start "" /b gawk -v Port=%%a -v LastPort=%LastPort% -f "%DirScript%Sentinel-Server.awk"
	)
)

call :ObtieneFecha
for /F "tokens=*" %%a in ('"curl -s --connect-timeout 0.325 --max-time 0.35 http://localhost:%Port%/sentinelversion"') do (set Version1=%%a)
echo [%YYYYMMDD_HH24_MI_SS_ML%][Sentinel Start] ... Service up with version: !Version1!. >> "%FchStart%"

call :ObtieneFecha
call :Epoch
set /a fin=%Epoch%
set /a dif=%fin% - %IdExec%

:: Salimos reportando ejecución Ok
echo [%YYYYMMDD_HH24_MI_SS_ML%][Sentinel Start] ... End ... Elapsed: !dif!. >> "%FchStart%"

exit 0

:Epoch
	for /f "tokens=1,2 delims=;" %%a in ('gawk -f "%DirEpoch%Epoch.awk"') do set %%a=%%b
goto :eof

:ObtieneFecha
	for /f "tokens=2 delims==" %%a in ('wmic OS Get localdatetime /value') do set "dt=%%a"
	set "YY=%dt:~2,2%" & set "YYYY=%dt:~0,4%" & set "MM=%dt:~4,2%" & set "DD=%dt:~6,2%"
	set "HH24=%dt:~8,2%" & set "MIN=%dt:~10,2%" & set "SEG=%dt:~12,2%" & set "CENT=%dt:~15,2%" & set "MIL=%dt:~15,3%"

	if !HH24! GTR 12 (set HH12=!HH24!-12) else (set HH12=!HH24!)
	if !HH12! LSS 10 (set HH12=0!HH12!)

	set YYYYMM=%YYYY%%MM%
	set YYYYMMDD=%YYYY%%MM%%DD%
	set YYYYMMDDHH24MISS=%YYYY%%MM%%DD%%HH24%%MIN%%SEG%
	set YYYYMMDDHH24MISSCE=%YYYY%%MM%%DD%%HH24%%MIN%%SEG%%CENT%
	set YYYYMMDDHH24MISSML=%YYYY%%MM%%DD%%HH24%%MIN%%SEG%%MIL%
	set YYYYMMDD_HH24_MI_SS=%YYYY%-%MM%-%DD% %HH24%:%MIN%:%SEG%
	set YYYYMMDD_HH24_MI_SS_ML=%YYYY%%MM%%DD% %HH24%:%MIN%:%SEG%.%MIL%
goto :eof