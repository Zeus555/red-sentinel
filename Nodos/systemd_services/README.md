# systemd_services — arranque de los nodos Ubuntu

Espejo de **solo lectura** de las unidades systemd que arrancan y supervisan los
servicios en los dos nodos Ubuntu de la flota. Es el equivalente de
[`runit_services/`](../runit_services), que cubre los nodos Android/Termux.

Rescatado el **2026-07-26**. Hasta esa fecha estos ficheros existían únicamente
dentro de los nodos: si uno se reinstalaba, el arranque había que reconstruirlo
de memoria.

**Editar aquí no cambia nada en los nodos.** Hay que copiar por `scp` y recargar.

| Nodo | Unidad | Estado en el rescate |
|---|---|---|
| `sentinel014` (node6, 192.168.0.21) | `rqlited.service` | enabled |
| | `rpa-extron-cycle.service` | static — lo dispara el timer |
| | `rpa-extron-cycle.timer` | enabled |
| | `rpa-extron-dashboard.service` | enabled |
| `sentinel016` (node7, 192.168.0.159) | `rqlited.service` | enabled |

Todas son unidades de **usuario** (`~/.config/systemd/user/`), no de sistema.

## Los dos detalles que no se pueden perder

**1. `Linger=yes`.** Está activado en `sentinel` en ambos nodos. Sin linger, las
unidades de usuario mueren al cerrar la sesión SSH y no arrancan en el boot: el
nodo se caería del clúster en cada reinicio. Al reinstalar:

```bash
sudo loginctl enable-linger sentinel
```

**2. El bind en `0.0.0.0`.** Los dos `rqlited.service` llevan
`-http-addr 0.0.0.0:4001 -http-adv-addr <IP>:4001` y lo mismo para Raft en 4002.
No es cosmético: es el fix del 2026-07-05. Atado a la IP concreta, el socket de
escucha muere cuando el WiFi recicla la IP y el nodo queda vivo pero
inalcanzable. **No simplificar a `-http-addr <IP>:4001`.** El detalle completo
está en el [README de la flota](../README.md), sección rqlite.

Lo que sí cambia por nodo: `-node-id` y las dos `-adv-addr`. La lista de `-join`
apunta a los otros dos votantes y basta con que uno responda.

**3. `-auth` y `-join-as nodo`** (desde el 2026-11-11). rqlited pide contraseña y
el nodo hace el join con el usuario `nodo`, cuya clave sale del propio
`~/.config/rqlite/auth.json`. Ese fichero **no está aquí** (lleva las claves): se
copia antes de arrancar, con el de votante, como explica
[`rqlite/auth/README.md`](../../rqlite/auth/README.md). Sin él, rqlited no arranca;
sin `-join-as`, el join falla y el nodo muere a los ~12 s y entra en bucle.

## Restaurar

```bash
# antes: ~/.config/rqlite/auth.json (fichero de votante) y sentinel.curlrc, en 600
scp rqlited.service sentinel014:~/.config/systemd/user/
ssh sentinel014 'systemctl --user daemon-reload && systemctl --user enable --now rqlited'
```

Para el timer de Extron, `enable --now rpa-extron-cycle.timer`; el `.service`
es `static` a propósito y no se habilita: lo dispara el timer, que corre a las
06:00 y 18:00 hora local del nodo con `Persistent=true` (recupera la corrida si
el nodo estaba apagado) y 300 s de dispersión aleatoria.

Comprobar después:

```bash
ssh sentinel014 'systemctl --user list-timers --no-pager; curl -s -K ~/.config/rqlite/sentinel.curlrc localhost:4001/status?pretty | head'
```

## Dependencia externa que estas unidades dan por hecha

`rpa-extron-*` invoca Node por ruta absoluta a una versión concreta de nvm:
`~/.nvm/versions/node/v20.20.2/bin/node`. Si esa versión desaparece del nodo,
las unidades fallan sin decir por qué. Es deliberado — systemd no carga el
entorno de nvm — pero hay que recordarlo al actualizar Node.

Ambas leen su configuración de `~/RPA_Monitor_Extron/.env`, que **no está aquí**:
contiene el token de Bright Data, el de Telegram y el Basic Auth del dashboard.
