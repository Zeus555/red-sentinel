@echo off
REM Sentinel v2 - Vigilante y arranque para el Wheel Windows (sentinel013).
REM
REM Windows no tiene runit ni systemd, asi que la supervision la hace el propio
REM Programador de tareas llamando a este script cada pocos minutos: si el agente
REM no responde, lo levanta. Es el mismo patron que el watchdog del v1, pero para
REM UN proceso en vez de 20.
REM
REM Toda la decision vive en sentinel-windows.sh. Antes estaba aqui: un curl de
REM 3 s a /version y, si fallaba, "start" de otro agente SIN mirar si ya habia
REM uno. El viejo seguia vivo y se juntaron 10 copias turnandose el 8181
REM (10/11/2026). El .sh garantiza una sola: quita la colgada por PID y no lanza
REM mientras quede otra viva.
setlocal
set SH=C:\Program Files\Git\bin\sh.exe

"%SH%" -c "exec sh \"$HOME/PRC_Sentinel/v2/sentinel-windows.sh\" >> \"$HOME/PRC_Sentinel/v2/server.log\" 2>&1"

endlocal
exit /b 0
