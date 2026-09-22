# cloudflared — el túnel de sentinel014

Configuración del Cloudflare Tunnel `rpa-extron` que publica dos dashboards en
Internet sin abrir un solo puerto en el router. Corre en **sentinel014**
(node6, 192.168.1.250) como servicio systemd **de sistema**, no de usuario.

Rescatado el **2026-07-26**. Antes vivía solo en el nodo.
**Reconciliado con el nodo el 2026-09-22**: el `config.yml` de este espejo se
había quedado en la versión de julio y ya no describía a dónde iba el tráfico.

| Fichero | Origen en el nodo |
|---|---|
| `config.yml` | `/etc/cloudflared/config.yml` |
| `cloudflared.service` | `/etc/systemd/system/cloudflared.service` |

## Qué publica

| Hostname | Va a | Qué es |
|---|---|---|
| `extron.batchtoday.us` | `http://192.168.1.99:3008` | dashboard de RPA Monitor Extron, **en sentinel020** |
| `ampronix.batchtoday.us` + `path: ^/api/agent/` | `http://192.168.1.99:3013` | solo la API del agente de Ampronix, **en sentinel020** |
| `ampronix.batchtoday.us` (resto) | `http_status:404` | segunda barrera (decisión de 2026-09-16) |
| (resto) | `http_status:404` | catch-all obligatorio |

**Ninguno de los dos destinos vive ya en sentinel014.** Los dos apuntan a
sentinel020 (192.168.1.99), que es donde se concentran los RPA Monitor — ver
[Servicio 8](../README.md#servicio-8-rpa-monitor-en-sentinel020). sentinel014 se
quedó únicamente como **puerta de entrada**: solo corre el `cloudflared`, no
sirve ninguno de los dos dashboards. Si este nodo se apaga, ambos hostnames caen
aunque los paneles sigan perfectamente vivos en sentinel020. Y si sentinel020
cambia de IP en la LAN, hay que editar este `config.yml`, no nada del lado de
Windows.

La regla de Ampronix tiene dos entradas por orden: la de `path` primero, y el
`http_status:404` después para el resto del hostname. Invertirlas dejaría la API
inalcanzable.

**Verificado en vivo el 2026-09-22:** `cloudflared` `active` en sentinel014;
`https://extron.batchtoday.us` responde **401** con
`www-authenticate: Basic realm="RPA Extron"` y `x-powered-by: Express` (o sea, la
petición llega al Express real); `https://ampronix.batchtoday.us/` responde
**404**, que es el comportamiento buscado. En sentinel014 no escucha nada en
3008; en sentinel020 sí, junto con 3013.

El túnel es saliente, así que es inmune a los cambios de IP residencial. La
autenticación de los dashboards no la hace Cloudflare: es Basic Auth dentro del
propio Express (`DASH_USER`/`DASH_PASS` en el `.env` del RPA).

## Lo que NO está aquí, a propósito

`config.yml` referencia
`/home/sentinel/.cloudflared/<TUNNEL-UUID>.json`.
**Ese fichero es la credencial del túnel y no se copia a este disco.** Guardar
credenciales en claro dentro de `D:\` es exactamente lo que se limpió en la
Fase 1 del reordenamiento.

Consecuencia que hay que aceptar con los ojos abiertos: **con lo que hay en esta
carpeta se puede reconstruir la configuración del túnel, pero no el túnel.** Si
se pierde el nodo y la credencial a la vez, hay que emitirla de nuevo desde
Cloudflare:

```bash
cloudflared tunnel login
cloudflared tunnel token --cred-file ~/.cloudflared/<TUNNEL-UUID>json rpa-extron
```

El id del túnel (`<TUNNEL-UUID>`) sí conviene tenerlo
aquí: sin él no se sabe cuál de los túneles de la cuenta hay que recuperar.

## Restaurar

```bash
scp config.yml cloudflared.service sentinel014:/tmp/
ssh sentinel014 'sudo mv /tmp/config.yml /etc/cloudflared/ && sudo mv /tmp/cloudflared.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now cloudflared'
```

Comprobar:

```bash
ssh sentinel014 'systemctl status cloudflared --no-pager'
curl -sI https://extron.batchtoday.us | head -1
```

Estado en el momento del rescate: `enabled` y `active`. El nodo guarda además
un `config.yml.bak-20260723` de la versión anterior a añadir la regla de
Ampronix.
