# cloudflared — el túnel de sentinel014

Configuración del Cloudflare Tunnel `rpa-extron` que publica dos dashboards en
Internet sin abrir un solo puerto en el router. Corre en **sentinel014**
(node6, 192.168.1.250) como servicio systemd **de sistema**, no de usuario.

Rescatado el **2026-07-26**. Antes vivía solo en el nodo.

| Fichero | Origen en el nodo |
|---|---|
| `config.yml` | `/etc/cloudflared/config.yml` |
| `cloudflared.service` | `/etc/systemd/system/cloudflared.service` |

## Qué publica

| Hostname | Va a | Qué es |
|---|---|---|
| `extron.batchtoday.us` | `http://localhost:3008` | dashboard de RPA Monitor Extron, en el propio nodo |
| `ampronix.batchtoday.us` | `http://192.168.1.117:3013` | dashboard de Ampronix — **corre en la laptop**, no aquí |
| (resto) | `http_status:404` | catch-all obligatorio |

La segunda regla es la que sorprende: sentinel014 hace de **puerta de entrada
de la laptop**. Si este nodo se apaga, `ampronix.batchtoday.us` cae aunque
`rpa-ampronix-services-dashboard` siga corriendo perfectamente en pm2. Y si la laptop cambia
de IP en la LAN, hay que editar este `config.yml`, no nada del lado de Windows.

El túnel es saliente, así que es inmune a los cambios de IP residencial. La
autenticación de los dashboards no la hace Cloudflare: es Basic Auth dentro del
propio Express (`DASH_USER`/`DASH_PASS` en el `.env` del RPA).

## Lo que NO está aquí, a propósito

`config.yml` referencia
`/home/sentinel/.cloudflared/4f0a2058-2b9f-4f6e-9029-02c5ea22cf23.json`.
**Ese fichero es la credencial del túnel y no se copia a este disco.** Guardar
credenciales en claro dentro de `D:\` es exactamente lo que se limpió en la
Fase 1 del reordenamiento.

Consecuencia que hay que aceptar con los ojos abiertos: **con lo que hay en esta
carpeta se puede reconstruir la configuración del túnel, pero no el túnel.** Si
se pierde el nodo y la credencial a la vez, hay que emitirla de nuevo desde
Cloudflare:

```bash
cloudflared tunnel login
cloudflared tunnel token --cred-file ~/.cloudflared/4f0a2058-....json rpa-extron
```

El id del túnel (`4f0a2058-2b9f-4f6e-9029-02c5ea22cf23`) sí conviene tenerlo
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
