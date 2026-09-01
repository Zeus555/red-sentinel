# ESTRUCTURA del repositorio (2026-09-01)

Árbol comentado de **primer y segundo nivel**, solo con lo **versionado** en el
primer commit. Lo que no aparece aquí (bases `*.db`, `Log/`, `Temporal/`,
`Wheel/Run/`, `Wheel/OLD/`, `Wheel/Script/v2/_test/`, llaves/certs PKI, tokens
y los dos XLSX de costos) queda excluido por `.gitignore` — el porqué de cada
exclusión está en la sección «Qué NO está en este repo» del `README.md` raíz.

```text
RED Sentinel/
├── .gitignore                  # Exclusiones del repo: secretos, datos, OLD
├── .cbmignore                  # Exclusiones del índice de codebase-memory (no afecta a git)
├── README.md                   # Qué es RED Sentinel, paquetes, arquitectura, despliegue
├── HISTORIA_CRIPTO.md          # Las 5 generaciones del proyecto y el trabajo cripto
├── PROPUESTA_Mejora.md         # Propuesta de mejora del sistema
├── ROAMING_sentinel019.md      # Diseño del roaming del móvil personal (Tailscale/CGNAT)
├── ROLLOUT_v2.md               # Despliegue de la v2 en la flota
│
├── docs/
│   ├── ADR.md                  # Decisiones de arquitectura (exportado del knowledge graph)
│   └── ESTRUCTURA.md           # Este árbol
│
├── Wheel/                      # El nodo Wheel de la laptop (sentinel013)
│   └── Script/                 # Servidor v1: Sentinel-Server.awk, Client, Clone,
│       │                       #   Search, Publish, Start/Test/Stress (.bat/.sh),
│       │                       #   iconos «Sentinel Eye» y HTML de prueba
│       └── v2/                 # Servidor v2: Sentinel-Server2.awk, Wheel, Worker,
│                               #   Discover, PKI/TLS/Token, Alert, Bateria, Cripto,
│                               #   Libro, Profundidad, Roam, Selftest, Install,
│                               #   sshd-guard, Sentinel-Node.conf.example, service/
│
├── Nodos/                      # Espejo de SOLO LECTURA del código de los 11 nodos
│   ├── README.md               # Mapa completo de la flota (nodos, roles, procedimientos)
│   ├── prc_sentinel/           # Servidores gawk v1+v2 + instalación, PKI, TLS, token,
│   │                           #   unidades runit/systemd/Windows
│   ├── whatsapp_chatbot/       # Chatbot WhatsApp Baileys + Gemini (server.js, .env.example)
│   ├── whatsapp_checker/       # Checker WhatsApp + API para reloj Wear OS (:8002)
│   ├── telegram_bridge/        # Puente Telegram MTProto (teleproto, sesión de usuario)
│   ├── prc_thermal/            # Guardián térmico (thermal-guard.sh + .conf.example)
│   ├── cloudflared/            # Túnel rpa-extron rescatado de sentinel014
│   │                           #   (config.yml, cloudflared.service, README)
│   ├── runit_services/         # Unidades runit de los nodos Termux
│   ├── systemd_services/       # Unidades systemd de sentinel014/016 (+ README)
│   └── termux_boot/            # Scripts de arranque Termux:Boot
│
├── UserAgent/                  # Alimenta la variable UserAgent de toda la red
│   └── Script/                 # Ejecuta User-Agent.bat, Get Last UserAgent.awk,
│                               #   User-Agent.bat (Prompt_GetSpec_Grok.bat queda
│                               #   fuera: lleva una API key hardcodeada)
│
└── rqlite/                     # El clúster como código
    ├── esquema.sql             # DDL de sentinel_temp, sentinel_disk, v_sentinel_estado…
    └── README.md               # Cómo restaurar el esquema en el clúster
```

Notas:

- `Wheel/` y `Nodos/prc_sentinel/` son **dos roles distintos** del mismo
  sistema, no copias divergentes: `Wheel` responde `Sentinel Super 1.0.0` y los
  nodos `Sentinel 1.0.0`. No fusionar (ver README raíz).
- Dentro de `Wheel/` existen además `Datos/`, `Log/`, `Temporal/`, `Run/` y
  `OLD/` (366 MB históricos), y dentro de `UserAgent/` un `Datos/` y `Log/`:
  todos excluidos del repo por ser datos/estado de ejecución, no fuente.
- Nada de este árbol se ejecuta desde aquí: se despliega por `scp` al nodo y se
  recarga a mano.
