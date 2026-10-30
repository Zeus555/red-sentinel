@echo off
REM ---------------------------------------------------------------------------
REM Lanzador de Sentinel-Respaldo.sh para el Programador de tareas (sentinel020).
REM
REM Lo arranca la tarea "RED Respaldo - rqlite". HOME se fija aqui porque con logon
REM S4U no siempre llega, y sin el ssh no encuentra el alias de la EC2 ni su llave.
REM ---------------------------------------------------------------------------
setlocal

set "GITBASH=C:\Program Files\Git\usr\bin\bash.exe"
if not exist "%GITBASH%" (
    echo No se encontro Git Bash.
    exit /b 9009
)
set "HOME=%USERPROFILE%"

"%GITBASH%" --noprofile --norc "%~dp0Sentinel-Respaldo.sh"
exit /b %ERRORLEVEL%
