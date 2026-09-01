@echo off
setlocal enabledelayedexpansion

rem Script para prueba de estres en la red Sentinel usando curl.exe version Windows Batch
rem Autor: Propuesta generada por Grok
rem Descripcion:
rem - Usa DB_PATH fijo: D:\RED Sentinel\Wheel\Datos\Hot.db con tabla dwd_wheels y columna ip
rem - Distribuye NUM_REQUESTS equitativamente entre todos los nodos excluyendo el IP del equipo actual
rem - Envia consultas concurrentes a todos los nodos al endpoint /sentinel/var/name usando curl.exe en puertos 8081 a 8100
rem - Registra solicitudes exitosas con codigo HTTP 200 y fallidas por nodo en archivos temporales
rem - Mide tiempo total, throughput en requests por segundo y tiempo promedio por request basandose en solicitudes completadas
rem - Parametrizable: numero total de consultas con -n, concurrencia por nodo con -c, delay entre lotes con -d
rem - Registra resultados en un archivo de log
rem - Asume nodos escuchan en puertos 8081 a 8100, con puerto 8081 limitado a concurrencia 1 y otros puertos hasta 19
rem - Requiere: sqlite3.exe disponible en https://www.sqlite.org/download.html y curl.exe incluido en Windows 10 o superior
rem - Uso: sentinel_stress_test.bat -n 150 -c 10 -d 2

rem Definir directorios de trabajo
set "DIR_RAIZ=D:\RED Sentinel\Wheel"
set "DIR_SCRIPT=%DIR_RAIZ%\Script"
set "DIR_TEMPORAL=%DIR_RAIZ%\Temporal"
set "DIR_DATOS=%DIR_RAIZ%\Datos"
set "DIR_LOG=%DIR_RAIZ%\Log"

rem Inicializar variables
set "DB_PATH=%DIR_DATOS%\Hot.db"
set "NUM_REQUESTS=150"
set "CONCURRENCY=10"
set "DELAY=2"
set "PORT_START=8081"
set "PORT_END=8100"

:parse
if "%~1"=="" goto doneparse
if /i "%~1"=="-n" set "NUM_REQUESTS=%~2"& shift& shift& goto parse
if /i "%~1"=="-c" set "CONCURRENCY=%~2"& shift& shift& goto parse
if /i "%~1"=="-d" set "DELAY=%~2"& shift& shift& goto parse
echo Opcion invalida: %~1
exit 1
:doneparse

rem Verificar existencia de la base de datos
if not exist "%DB_PATH%" (
  echo Error: Archivo %DB_PATH% no encontrado.
  exit 1
)

rem Verificar si curl.exe esta disponible
where curl.exe >nul 2>&1
if %ERRORLEVEL% neq 0 (
  echo Error: curl.exe no encontrado. Asegúrate de que esté en el PATH o en Windows 10 o superior.
  exit 1
)

rem Obtener el IP local del equipo actual, tomando la última IPv4 encontrada
set "LOCAL_IP="
for /f "tokens=2 delims=:" %%i in ('ipconfig ^| findstr /R "IPv4.*Address"') do (
  set "LOCAL_IP=%%i"
  set "LOCAL_IP=!LOCAL_IP:~1!"
  for /f "tokens=*" %%j in ("!LOCAL_IP!") do set "LOCAL_IP=%%j"
)
if not defined LOCAL_IP (
  echo Error: No se pudo obtener el IP local.
  exit 1
)
echo IP local del equipo: %LOCAL_IP%

rem Configurar archivo de log
set "LOG_FILE=%DIR_LOG%\sentinel_stress_results_%date:~10,4%%date:~4,2%%date:~7,2%_%time:~0,2%%time:~3,2%%time:~6,2%.log"
echo Iniciando prueba de estres: %date% %time% > "%LOG_FILE%"
echo Parametros: DB=%DB_PATH%, Total Requests=%NUM_REQUESTS%, Concurrencia por nodo=%CONCURRENCY%, Delay entre lotes=%DELAY% >> "%LOG_FILE%"
echo IP local excluido: %LOCAL_IP% >> "%LOG_FILE%"
echo. >> "%LOG_FILE%"

rem Extraer lista de IPs unicas desde Hot.db excluyendo el IP local
set "IPS="
set "NODE_COUNT=0"
for /f "tokens=*" %%i in ('sqlite3 "%DB_PATH%" "SELECT DISTINCT ip FROM dwd_wheels;"') do (
  set "CURRENT_IP=%%i"
  for /f "tokens=*" %%j in ("!CURRENT_IP!") do set "CURRENT_IP=%%j"
  if "!CURRENT_IP!" neq "%LOCAL_IP%" if "!CURRENT_IP!" neq "" (
    set "IPS=!IPS! !CURRENT_IP!"
    set /a NODE_COUNT+=1
  )
)

if not defined IPS (
  echo Error: No se encontraron nodos en la BD excluyendo IP local. >> "%LOG_FILE%"
  exit 1
)

echo Nodos encontrados: %NODE_COUNT% >> "%LOG_FILE%"
echo IPs: %IPS% >> "%LOG_FILE%"
echo. >> "%LOG_FILE%"

rem Calcular requests por nodo
set /a REQ_PER_NODE=NUM_REQUESTS / NODE_COUNT
set /a REMAINDER=NUM_REQUESTS %% NODE_COUNT
if %REMAINDER% neq 0 set /a REQ_PER_NODE+=1
echo Requests por nodo: %REQ_PER_NODE% >> "%LOG_FILE%"

rem Calcular requests por puerto concurrente, limitando concurrencia a 20
if %CONCURRENCY% GTR 20 set /a CONCURRENCY=20
set /a REQ_PER_PORT=REQ_PER_NODE / CONCURRENCY
set /a PORT_REMAINDER=REQ_PER_NODE %% CONCURRENCY
if %PORT_REMAINDER% neq 0 set /a REQ_PER_PORT+=1
echo Requests por puerto concurrente: %REQ_PER_PORT% >> "%LOG_FILE%"
echo. >> "%LOG_FILE%"

rem Medir tiempo de inicio
set "START_TIME=%time%"

rem Inicializar contador global de solicitudes completadas
set "TOTAL_COMPLETED=0"

rem Lanzar consultas concurrentes a todos los nodos usando curl.exe
set BATCH_COUNT=0
:batch
set /a BATCH_COUNT+=1
echo Iniciando lote %BATCH_COUNT%: %date% %time% >> "%LOG_FILE%"

for %%i in (%IPS%) do (
  set "IP=%%i"
  if "!IP!" neq "" (
    set "TEMP_FILE=%DIR_TEMPORAL%\temp_curl_!IP!.txt"
    set "COMPLETED_COUNT=0"
    echo Probando !IP! con %CONCURRENCY% puertos concurrentes y %REQ_PER_PORT% solicitudes cada uno >> "%LOG_FILE%"
    
    rem Lanzar procesos concurrentes para diferentes puertos
    del "!TEMP_FILE!" 2>nul
    set /a PORT=PORT_START
    for /L %%j in (1,1,%CONCURRENCY%) do (
      set "CURRENT_PORT=!PORT!"
      start /b cmd /c "for /l %%k in ^(1,1,!REQ_PER_PORT!^) do ^(curl -s -o nul -w "%%{http_code}\n" "http://!IP!:!CURRENT_PORT!/sentinel/var/name" -H "Connection: close" >> "!TEMP_FILE!"^)"
      set /a PORT+=1
    )
    
    rem Esperar a que los procesos terminen usando subrutina
    call :wait_for_curl
    
    rem Contar solicitudes exitosas con codigo HTTP 200
    if exist "!TEMP_FILE!" (
      for /f %%k in ('find /c "200" "!TEMP_FILE!"') do set "COMPLETED_COUNT=%%k"
      echo Solicitudes completadas en !IP!: !COMPLETED_COUNT! >> "%LOG_FILE%"
      set /a TOTAL_COMPLETED+=COMPLETED_COUNT
      del "!TEMP_FILE!" 2>nul
    ) else (
      echo No se completaron solicitudes en !IP! >> "%LOG_FILE%"
    )
  )
)

rem Medir tiempo de fin
set "END_TIME=%time%"

rem Calcular duracion en segundos manejando formato HH:MM:SS
set /a START_SEC=(1!START_TIME:~0,2!-100)*3600 + (1!START_TIME:~3,2!-100)*60 + (1!START_TIME:~6,2!-100)
set /a END_SEC=(1!END_TIME:~0,2!-100)*3600 + (1!END_TIME:~3,2!-100)*60 + (1!END_TIME:~6,2!-100)
set /a DURATION=END_SEC - START_SEC
if !DURATION! lss 0 set /a DURATION+=86400
rem Evitar division por cero
if !DURATION! equ 0 set /a DURATION=1

rem Calcular metricas basadas en solicitudes completadas
rem Evitar division por cero
if !TOTAL_COMPLETED! equ 0 set /a TOTAL_COMPLETED=1
set /a THROUGHPUT=TOTAL_COMPLETED / DURATION
rem Calcular tiempo promedio en milisegundos
set /a AVG_TIME=DURATION * 1000 / TOTAL_COMPLETED

echo Resumen para lote %BATCH_COUNT%: >> "%LOG_FILE%"
echo   Duracion total: %DURATION% segundos >> "%LOG_FILE%"
echo   Solicitudes completadas: %TOTAL_COMPLETED% >> "%LOG_FILE%"
echo   Throughput: %THROUGHPUT% requests/segundo >> "%LOG_FILE%"
echo   Tiempo promedio por request: %AVG_TIME% ms >> "%LOG_FILE%"
echo. >> "%LOG_FILE%"

rem Verificar si se necesitan mas lotes si hay remainder
set /a TOTAL_SENT=BATCH_COUNT * REQ_PER_NODE * NODE_COUNT
if %TOTAL_SENT% lss %NUM_REQUESTS% (
  timeout /t %DELAY% /nobreak > nul
  goto batch
)

echo Prueba completada: %date% %time% >> "%LOG_FILE%"
echo Total solicitudes completadas: %TOTAL_COMPLETED% de %NUM_REQUESTS% >> "%LOG_FILE%"
echo Resultados guardados en %LOG_FILE%
endlocal
exit 0

rem Subrutina para esperar a que los procesos curl terminen
:wait_for_curl
set /a WAIT_TIMEOUT=30
set /a WAIT_START=%time:~0,2%*3600 + %time:~3,2%*60 + %time:~6,2%
:wait_loop
set /a WAIT_CURRENT=%time:~0,2%*3600 + %time:~3,2%*60 + %time:~6,2%
set /a WAIT_ELAPSED=WAIT_CURRENT - WAIT_START
if !WAIT_ELAPSED! lss 0 set /a WAIT_ELAPSED+=86400
if !WAIT_ELAPSED! lss !WAIT_TIMEOUT! (
  tasklist | findstr /i "curl.exe" >nul
  if !ERRORLEVEL! equ 0 (
    timeout /t 1 /nobreak >nul
    goto wait_loop
  )
)
goto :eof