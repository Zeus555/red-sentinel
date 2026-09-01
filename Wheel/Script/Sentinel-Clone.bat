@echo off

:: Codificacion UTF8
chcp 65001 >Nul

:: Seteamos ambiente para usar variables retrasadas.
SETLOCAL ENABLEDELAYEDEXPANSION

:: Directorios de trabajo.
set DirRaiz=D:\RED Sentinel\Wheel\
set DirScript=%DirRaiz%Script\
set DirTemporal=%DirRaiz%Temporal\
set DirRun=%DirRaiz%Run\
set DirDatos=%DirRaiz%Datos\
set DirLog=%DirRaiz%Log\


:: Creamos unidad virtual para que use directorio Temporal donde se creara el fichero HTML.
pushd "%DirScript%"

start "" /B gawk -f "Sentinel-Clone.awk" >"%DirLog%Salida.txt"

:: Eliminamos unidad virtual.
popd

exit 0