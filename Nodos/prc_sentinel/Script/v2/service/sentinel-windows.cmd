@echo off
REM Sentinel v2 - Vigilante y arranque para el Wheel Windows (sentinel013).
REM
REM Windows no tiene runit ni systemd, asi que la supervision la hace el propio
REM Programador de tareas llamando a este script cada pocos minutos: si el agente
REM no responde, lo levanta. Es el mismo patron que el watchdog del v1, pero para
REM UN proceso en vez de 20.
setlocal
set BASE=%USERPROFILE%\PRC_Sentinel\v2
set SH=C:\Program Files\Git\bin\sh.exe

REM ¿Responde ya? Entonces no hay nada que hacer.
curl -s -m 3 -o NUL "http://127.0.0.1:8181/version" >NUL 2>&1
if not errorlevel 1 goto :fin

REM Levantarlo en segundo plano y sin ventana.
start "" /B "%SH%" -c "exec sh \"$HOME/PRC_Sentinel/v2/sentinel-start.sh\" >> \"$HOME/PRC_Sentinel/v2/server.log\" 2>&1"

:fin
endlocal
exit /b 0
