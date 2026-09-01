@echo off

:: Codificacion UTF8
chcp 65001 >Nul

:: Seteamos ambiente para usar variables retrasadas.
SETLOCAL ENABLEDELAYEDEXPANSION

:: Directorios de trabajo.
set DirRaiz=D:\RED Sentinel\UserAgent\
set DirScript=%DirRaiz%Script\
set DirTemporal=%DirRaiz%Temporal\
set DirRun=%DirRaiz%Run\
set DirDatos=%DirRaiz%Datos\
set DirLog=%DirRaiz%Log\


:: Creamos unidad virtual para que use directorio Temporal donde se creara el fichero HTML.
pushd "%DirScript%"

rem for /F "tokens=*" %%a in ('curl -s http://127.0.0.1:9222/json/version ^| gawk -F: "/User-Agent/{gsub(/ \042/,\"\");gsub(/\042,$/,\"\");print $2}"') do (
rem	set UserAgent=%%a
	rem echo !User-Agent!
rem	setx UserAgent "!UserAgent!"
rem )

start "" /B /WAIT gawk -f "Get Last UserAgent.awk" > "%DirLog%UserAgent.log"
echo Test:%UserAgent% >> "%DirLog%UserAgent.log"

:: Eliminamos unidad virtual.
popd

exit 0