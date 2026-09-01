' Sentinel v2 - Envoltorio silencioso para el Programador de tareas de Windows.
' Ejecuta el vigilante sin abrir ventana: la tarea corre cada pocos minutos y sin
' esto parpadearia una consola en la cara del usuario cada vez.
Set sh = CreateObject("WScript.Shell")
sh.Run """" & sh.ExpandEnvironmentStrings("%USERPROFILE%") & "\PRC_Sentinel\v2\sentinel-windows.cmd""", 0, False
