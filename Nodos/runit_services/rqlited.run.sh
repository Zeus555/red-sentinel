#!/data/data/com.termux/files/usr/bin/sh
# Servicio runit: $PREFIX/var/service/rqlited/run (desde 2026-07-05; 9 nodos Android a 2026-07-24)
# Plantilla — cada nodo lleva su node-id/IP.
# El node-id libre se comprueba EN VIVO (curl 'http://<ip>:4001/nodes?nonvoters&pretty'),
# no se deduce del número del host: sentinel019 es node11, no node19.
#
# SIN VOTO (2026-10-30): solo votan sentinel014, sentinel016 y sentinel005. Todos los
# demás llevan -raft-non-voter=true. El run de sentinel005 no lleva ese flag y su -join
# son los otros dos votantes. Ver "Servicio 2" en Nodos/README.md.
# Log: $PREFIX/var/service/rqlited/log/run -> svlogd -tt $PREFIX/var/log/sv/rqlited
#
# IMPORTANTE (2026-07-05): bind a 0.0.0.0 + advertised IP LAN. Antes se vinculaba
# directo a <IP>:4002; cuando Android reciclaba la IP del WiFi durante el doze, el
# socket de escucha (atado a esa IP) MORÍA y no se re-vinculaba: el proceso seguía
# vivo haciendo Raft saliente pero nadie podía conectarse a él → el nodo se caía del
# clúster. Bind a 0.0.0.0 sobrevive a que la IP desaparezca/regrese.
#
# TIEMPOS DE RAFT A 4 s (2026-10-16): con los de fábrica (latido y elección 1 s,
# lease del líder 500 ms) un teléfono por WiFi perdía el liderazgo con cualquier
# parón de medio segundo — 105 «failed to contact quorum, stepping down» en el log
# de un solo líder y ~550 cambios de líder al día. Los tres van juntos: con latido
# a 4 s los latidos salen cada 0,4-0,8 s y un lease de 500 ms haría dimitir al
# líder todavía más. Raft exige lease <= latido <= elección.
#
# CONTRASEÑA (2026-11-11): -auth y -join-as nodo, siempre antes del directorio de
# datos. ~/.config/rqlite/auth.json NO está en el repo (lleva las claves): se copia
# antes de arrancar, el de no votante (o el de votante en sentinel005), ver
# rqlite/auth/README.md. Sin el fichero rqlited no arranca; sin -join-as el join
# falla, el nodo muere a los ~12 s y runit lo relanza en bucle.
exec 2>&1
exec /data/data/com.termux/files/home/go/bin/rqlited -node-id nodeN -raft-non-voter=true -http-addr 0.0.0.0:4001 -http-adv-addr <IP>:4001 -raft-addr 0.0.0.0:4002 -raft-heartbeat-timeout=4s -raft-election-timeout=4s -raft-leader-lease-timeout=4s -raft-adv-addr <IP>:4002 -join 192.168.0.21:4002,192.168.0.159:4002,192.168.0.166:4002 -auth /data/data/com.termux/files/home/.config/rqlite/auth.json -join-as nodo /data/data/com.termux/files/home/rqlite-data
