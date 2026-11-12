# Registra la tarea programada del respaldo de rqlite en sentinel020, con el mismo
# patron que "RPA <Marca> - *": usuario sentinel, logon S4U, RunLevel Limited,
# MultipleInstances=IgnoreNew.
#
# 03:45: despues de la poda de telemetria de sentinel001 (03:30), para no guardar
# lo que ya se va a borrar, y fuera de la franja 02:00-03:00 que el cambio de hora
# se salta o repite. StartWhenAvailable hace que, si el equipo estaba apagado a esa
# hora, la copia salga en cuanto vuelva.
# OJO (visto el 2026-11-11): -At '03:45' guarda el StartBoundary con el desfase horario y
# el Programador lo trata como "sincronizar entre zonas horarias": la tarea quedo atada a
# las 10:45 UTC (registrada el 30/10, en verano). En invierno sale a las 02:45, ANTES de
# la poda de las 03:30. Para que siga a la hora local habria que registrarla con un
# StartBoundary sin desfase.
$ErrorActionPreference = 'Stop'
$root = 'D:\RED Respaldo'
$nombre = 'RED Respaldo - rqlite'

$principal = New-ScheduledTaskPrincipal -UserId 'sentinel' -LogonType S4U -RunLevel Limited
$accion = New-ScheduledTaskAction -Execute "$root\Script\respaldo.cmd" -WorkingDirectory $root
$disparo = New-ScheduledTaskTrigger -Daily -At '03:45'
$ajustes = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName $nombre -Action $accion -Trigger $disparo `
    -Principal $principal -Settings $ajustes -Force | Out-Null

$t = Get-ScheduledTask -TaskName $nombre
$i = Get-ScheduledTaskInfo -TaskName $nombre
Write-Output "### $nombre  [$($t.State)]  proxima: $($i.NextRunTime)"
$t.Actions | ForEach-Object { "  exec: $($_.Execute)  wd: $($_.WorkingDirectory)" }
"  principal: $($t.Principal.UserId) $($t.Principal.LogonType) $($t.Principal.RunLevel)"
"  settings: limit=$($t.Settings.ExecutionTimeLimit) multi=$($t.Settings.MultipleInstances) startwhenavailable=$($t.Settings.StartWhenAvailable)"
