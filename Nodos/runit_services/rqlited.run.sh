#!/data/data/com.termux/files/usr/bin/sh
# Servicio runit: $PREFIX/var/service/rqlited/run (desde 2026-07-05; 9 nodos Android a 2026-07-24)
# Plantilla — cada nodo lleva su node-id/IP. node1 (sentinel001) NO lleva -join.
# El node-id libre se comprueba EN VIVO (curl 'http://<ip>:4001/nodes?pretty'), no
# se deduce del número del host: sentinel019 es node11, no node19.
# Log: $PREFIX/var/service/rqlited/log/run -> svlogd -tt $PREFIX/var/log/sv/rqlited
#
# IMPORTANTE (2026-07-05): bind a 0.0.0.0 + advertised IP LAN. Antes se vinculaba
# directo a <IP>:4002; cuando Android reciclaba la IP del WiFi durante el doze, el
# socket de escucha (atado a esa IP) MORÍA y no se re-vinculaba: el proceso seguía
# vivo haciendo Raft saliente pero nadie podía conectarse a él → el nodo se caía del
# clúster. Bind a 0.0.0.0 sobrevive a que la IP desaparezca/regrese.
exec 2>&1
exec /data/data/com.termux/files/home/go/bin/rqlited -node-id nodeN -http-addr 0.0.0.0:4001 -http-adv-addr <IP>:4001 -raft-addr 0.0.0.0:4002 -raft-adv-addr <IP>:4002 -join 192.168.1.69:4002 /data/data/com.termux/files/home/rqlite-data
