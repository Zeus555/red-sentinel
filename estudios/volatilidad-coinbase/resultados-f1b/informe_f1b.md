# F1b — Segundos y toma de ganancia

- Ventana: 2026-10-07 18:39 → 2026-11-06 18:39 UTC, la misma de la F1; mismo universo de 51 activos.
- Nivel de comisión evaluado: **intro** (SUPUESTO, sin confirmar por el dueño). Parámetros v3.1, sección f1b congelada antes de descargar un solo trade.
- Trades: 51 activos analizados, 51 166 000 trades descargados, 0 respuestas 429.

## Respuesta corta

- **Horizonte fijo de 5 a 60 s (intro):** TT: pasan 0 de 255 (0 robustas), mejor ρ_req 0,50 (BIRB-USD a 60 s); MT: pasan 0 de 255 (0 robustas), mejor ρ_req 0,39 (BIRB-USD a 60 s); TM: pasan 0 de 255 (0 robustas), mejor ρ_req 0,39 (BIRB-USD a 60 s).
- **Comprar, dejar la venta y esperar (trades, de 5 s a sin plazo, intro):** pasan 0 de 2244 en TM, 0 de 2244 en TT (con la variante que exige ≥ $1000 en un segundo para llenar: 0).
- **Comprar, dejar la venta y esperar (velas de 1 min, de 1 min a sin plazo, intro):** pasan 0 de 1428 en TM, 0 de 1428 en TT.

## ¿Es más probable en menos tiempo?

### Con trades (rejilla de 1 s)

Venta límite con ganancia neta de 10 pb (el objetivo queda a ~151 pb de la entrada por la comisión). "Llega antes de" = fracción de entradas cuyo objetivo se toca antes de ese plazo. "Más denso" = el tramo entre cortes con más llegadas por segundo: si de verdad fuera más probable en menos tiempo, sería el primero.

| Activo | ≤ 5 s | ≤ 20 s | ≤ 1 min | ≤ 5 min | ≤ 1 h | ≤ 5 h | Tramo más denso | ≤ 20 s con ≥ $1000 en un segundo | ≤ 5 min con ≥ $1000 en un segundo |
|---|---|---|---|---|---|---|---|---|---|
| ALIGN-USD | 0,61 % | 2,38 % | 5,84 % | 15,64 % | 41,56 % | 61,45 % | 5 s-10 s | 0,30 % | 5,06 % |
| BIRB-USD | 0,36 % | 2,08 % | 5,73 % | 17,94 % | 55,05 % | 75,87 % | 5 s-10 s | 0,91 % | 11,03 % |
| BTC-USD | 0,00 % | 0,00 % | 0,00 % | 0,00 % | 0,56 % | 5,71 % | 3 h-5 h | 0,00 % | 0,00 % |
| ENA-USD | 0,00 % | 0,01 % | 0,04 % | 0,71 % | 20,46 % | 53,39 % | 15 min-1 h | 0,00 % | 0,54 % |
| ETH-USD | 0,00 % | 0,00 % | 0,00 % | 0,02 % | 1,18 % | 11,20 % | 1 h-3 h | 0,00 % | 0,02 % |
| HYPE-USD | 0,00 % | 0,00 % | 0,02 % | 0,22 % | 6,45 % | 26,19 % | 15 min-1 h | 0,00 % | 0,22 % |
| NEAR-USD | 0,00 % | 0,00 % | 0,03 % | 0,74 % | 19,82 % | 51,51 % | 15 min-1 h | 0,00 % | 0,68 % |
| SOL-USD | 0,00 % | 0,00 % | 0,00 % | 0,03 % | 2,44 % | 14,44 % | 1 h-3 h | 0,00 % | 0,03 % |
| ZEC-USD | 0,00 % | 0,00 % | 0,02 % | 0,57 % | 17,24 % | 47,39 % | 15 min-1 h | 0,00 % | 0,55 % |

De 51 activos, **1** tiene el tramo más denso en el primero (5 s o menos) y **7** dentro del primer minuto (ALIGN-USD, BIRB-USD, CBETH-USD, CLANKER-USD, DRV-USD, ICNT-USD, WLFI-USD).
De las entradas que llegan al objetivo dentro de 5 h, la parte que llega en el primer minuto es, en el activo mediano, **0,08 %**; las más altas: ALIGN-USD 9,5 %, BIRB-USD 7,6 %, CLANKER-USD 4,2 %.

### Con velas de 1 min

Venta límite con ganancia neta de 10 pb (el objetivo queda a ~151 pb de la entrada por la comisión). "Llega antes de" = fracción de entradas cuyo objetivo se toca antes de ese plazo. "Más denso" = el tramo entre cortes con más llegadas por segundo: si de verdad fuera más probable en menos tiempo, sería el primero.

| Activo | ≤ 1 min | ≤ 5 min | ≤ 15 min | ≤ 1 h | ≤ 3 h | ≤ 5 h | Tramo más denso |
|---|---|---|---|---|---|---|---|
| ALIGN-USD | 4,75 % | 13,21 % | 22,52 % | 38,35 % | 53,19 % | 60,94 % | 0-1 min |
| BIRB-USD | 4,48 % | 14,68 % | 28,63 % | 51,85 % | 67,89 % | 74,43 % | 0-1 min |
| BTC-USD | 0,00 % | 0,00 % | 0,04 % | 0,56 % | 3,07 % | 5,71 % | 3 h-5 h |
| ENA-USD | 0,04 % | 0,61 % | 3,74 % | 19,26 % | 42,11 % | 52,86 % | 15 min-1 h |
| ETH-USD | 0,00 % | 0,02 % | 0,17 % | 1,18 % | 6,39 % | 11,22 % | 1 h-3 h |
| HYPE-USD | 0,02 % | 0,17 % | 0,92 % | 5,05 % | 15,55 % | 23,91 % | 15 min-1 h |
| NEAR-USD | 0,04 % | 0,64 % | 3,51 % | 19,11 % | 41,19 % | 51,22 % | 15 min-1 h |
| SOL-USD | 0,00 % | 0,03 % | 0,28 % | 2,42 % | 8,55 % | 14,44 % | 1 h-3 h |
| ZEC-USD | 0,01 % | 0,52 % | 3,05 % | 16,60 % | 36,63 % | 46,79 % | 15 min-1 h |

De 51 activos, **3** tienen el tramo más denso en el primero (1 min o menos).
De las entradas que llegan al objetivo dentro de 5 h, la parte que llega en el primer minuto es, en el activo mediano, **0,07 %**; las más altas: ALIGN-USD 7,8 %, BIRB-USD 6,0 %, CLANKER-USD 2,9 %.

## Comprar, dejar la venta y esperar

Regla preregistrada: pasa si en **cada mitad** de la ventana, empezando con $1000, el capital final supera $1000 y supera a comprar y mantener esa mitad, con al menos 30 operaciones.

### Con trades

Comprar al ask (taker), dejar la venta límite (maker) con 10 pb de ganancia neta y esperar hasta el plazo; si no se llena, vender a mercado. "Acierto" y "media" con entradas cada 10 s (solapadas). "Capital" = simulación secuencial con $1000 en los 30 días, una operación detrás de otra reinvirtiendo todo. "Comprar y mantener" = comprar el primer día y vender el último.

| Activo | Plazo | Acierto | Media por operación | Operaciones | Capital tras 30 días | Comprar y mantener |
|---|---|---|---|---|---|---|
| BTC-USD | 5 s | 0,0 % | -178 pb | 418 227 | ≈ $0 | $894 |
| BTC-USD | 10 s | 0,0 % | -178 pb | 231 250 | ≈ $0 | $894 |
| BTC-USD | 20 s | 0,0 % | -178 pb | 122 197 | ≈ $0 | $894 |
| BTC-USD | 30 s | 0,0 % | -179 pb | 83 046 | ≈ $0 | $894 |
| BTC-USD | 1 min | 0,0 % | -179 pb | 42 348 | ≈ $0 | $894 |
| BTC-USD | 5 min | 0,0 % | -179 pb | 8 606 | ≈ $0 | $894 |
| BTC-USD | 15 min | 0,0 % | -179 pb | 2 877 | ≈ $0 | $894 |
| BTC-USD | 1 h | 0,6 % | -180 pb | 722 | ≈ $0 | $894 |
| BTC-USD | 3 h | 3,1 % | -182 pb | 246 | $11 | $894 |
| BTC-USD | 5 h | 5,7 % | -183 pb | 148 | $66 | $894 |
| BTC-USD | sin plazo | 77,1 % | -174 pb | 2 | $881 | $894 |
| ETH-USD | 5 s | 0,0 % | -179 pb | 366 827 | ≈ $0 | $857 |
| ETH-USD | 10 s | 0,0 % | -179 pb | 214 405 | ≈ $0 | $857 |
| ETH-USD | 20 s | 0,0 % | -179 pb | 117 237 | ≈ $0 | $857 |
| ETH-USD | 30 s | 0,0 % | -179 pb | 80 741 | ≈ $0 | $857 |
| ETH-USD | 1 min | 0,0 % | -179 pb | 41 807 | ≈ $0 | $857 |
| ETH-USD | 5 min | 0,0 % | -179 pb | 8 580 | ≈ $0 | $857 |
| ETH-USD | 15 min | 0,2 % | -179 pb | 2 874 | ≈ $0 | $857 |
| ETH-USD | 1 h | 1,2 % | -181 pb | 725 | ≈ $0 | $857 |
| ETH-USD | 3 h | 6,4 % | -184 pb | 252 | $9,98 | $857 |
| ETH-USD | 5 h | 11,2 % | -187 pb | 155 | $57 | $857 |
| ETH-USD | sin plazo | 80,9 % | -196 pb | 1 | $857 | $857 |
| SOL-USD | 5 s | 0,0 % | -180 pb | 343 298 | ≈ $0 | $762 |
| SOL-USD | 10 s | 0,0 % | -180 pb | 205 812 | ≈ $0 | $762 |
| SOL-USD | 20 s | 0,0 % | -180 pb | 114 592 | ≈ $0 | $762 |
| SOL-USD | 30 s | 0,0 % | -180 pb | 79 471 | ≈ $0 | $762 |
| SOL-USD | 1 min | 0,0 % | -180 pb | 41 405 | ≈ $0 | $762 |
| SOL-USD | 5 min | 0,0 % | -180 pb | 8 566 | ≈ $0 | $762 |
| SOL-USD | 15 min | 0,3 % | -180 pb | 2 876 | ≈ $0 | $762 |
| SOL-USD | 1 h | 2,4 % | -182 pb | 727 | ≈ $0 | $762 |
| SOL-USD | 3 h | 8,6 % | -188 pb | 258 | $8,08 | $762 |
| SOL-USD | 5 h | 14,4 % | -192 pb | 161 | $47 | $762 |
| SOL-USD | sin plazo | 76,9 % | -341 pb | 1 | $762 | $762 |
| NEAR-USD | 5 s | 0,0 % | -182 pb | 236 353 | ≈ $0 | $705 |
| NEAR-USD | 10 s | 0,0 % | -182 pb | 158 724 | ≈ $0 | $705 |
| NEAR-USD | 20 s | 0,0 % | -182 pb | 97 314 | ≈ $0 | $705 |
| NEAR-USD | 30 s | 0,0 % | -182 pb | 70 517 | ≈ $0 | $705 |
| NEAR-USD | 1 min | 0,0 % | -182 pb | 38 728 | ≈ $0 | $705 |
| NEAR-USD | 5 min | 0,7 % | -182 pb | 8 461 | ≈ $0 | $705 |
| NEAR-USD | 15 min | 3,9 % | -182 pb | 2 903 | ≈ $0 | $705 |
| NEAR-USD | 1 h | 19,8 % | -178 pb | 808 | ≈ $0 | $705 |
| NEAR-USD | 3 h | 41,6 % | -177 pb | 332 | $2,86 | $705 |
| NEAR-USD | 5 h | 51,5 % | -181 pb | 224 | $19 | $705 |
| NEAR-USD | sin plazo | 85,6 % | -316 pb | 9 | $624 | $705 |
| ZEC-USD | 5 s | 0,0 % | -181 pb | 271 979 | ≈ $0 | $1 010 |
| ZEC-USD | 10 s | 0,0 % | -181 pb | 175 280 | ≈ $0 | $1 010 |
| ZEC-USD | 20 s | 0,0 % | -181 pb | 103 695 | ≈ $0 | $1 010 |
| ZEC-USD | 30 s | 0,0 % | -181 pb | 73 863 | ≈ $0 | $1 010 |
| ZEC-USD | 1 min | 0,0 % | -181 pb | 39 757 | ≈ $0 | $1 010 |
| ZEC-USD | 5 min | 0,6 % | -181 pb | 8 505 | ≈ $0 | $1 010 |
| ZEC-USD | 15 min | 3,3 % | -180 pb | 2 900 | ≈ $0 | $1 010 |
| ZEC-USD | 1 h | 17,2 % | -174 pb | 792 | ≈ $0 | $1 010 |
| ZEC-USD | 3 h | 37,4 % | -174 pb | 325 | $4,55 | $1 010 |
| ZEC-USD | 5 h | 47,4 % | -177 pb | 229 | $25 | $1 010 |
| ZEC-USD | sin plazo | 100,0 % | 10 pb | 4 | $967 | $1 010 |
| ENA-USD | 5 s | 0,0 % | -182 pb | 165 764 | ≈ $0 | $729 |
| ENA-USD | 10 s | 0,0 % | -182 pb | 119 711 | ≈ $0 | $729 |
| ENA-USD | 20 s | 0,0 % | -182 pb | 79 412 | ≈ $0 | $729 |
| ENA-USD | 30 s | 0,0 % | -182 pb | 59 941 | ≈ $0 | $729 |
| ENA-USD | 1 min | 0,0 % | -182 pb | 35 046 | ≈ $0 | $729 |
| ENA-USD | 5 min | 0,7 % | -182 pb | 8 256 | ≈ $0 | $729 |
| ENA-USD | 15 min | 4,3 % | -181 pb | 2 880 | ≈ $0 | $729 |
| ENA-USD | 1 h | 20,5 % | -177 pb | 795 | ≈ $0 | $729 |
| ENA-USD | 3 h | 42,8 % | -174 pb | 325 | $3,10 | $729 |
| ENA-USD | 5 h | 53,4 % | -179 pb | 228 | $19 | $729 |
| ENA-USD | sin plazo | 92,1 % | -132 pb | 7 | $668 | $729 |
| HYPE-USD | 5 s | 0,0 % | -180 pb | 167 997 | ≈ $0 | $880 |
| HYPE-USD | 10 s | 0,0 % | -180 pb | 120 920 | ≈ $0 | $880 |
| HYPE-USD | 20 s | 0,0 % | -180 pb | 79 610 | ≈ $0 | $880 |
| HYPE-USD | 30 s | 0,0 % | -180 pb | 60 157 | ≈ $0 | $880 |
| HYPE-USD | 1 min | 0,0 % | -180 pb | 35 014 | ≈ $0 | $880 |
| HYPE-USD | 5 min | 0,2 % | -180 pb | 8 231 | ≈ $0 | $880 |
| HYPE-USD | 15 min | 1,3 % | -180 pb | 2 847 | ≈ $0 | $880 |
| HYPE-USD | 1 h | 6,4 % | -180 pb | 745 | ≈ $0 | $880 |
| HYPE-USD | 3 h | 17,8 % | -180 pb | 273 | $7,83 | $880 |
| HYPE-USD | 5 h | 26,2 % | -181 pb | 175 | $46 | $880 |
| HYPE-USD | sin plazo | 84,7 % | -170 pb | 8 | $801 | $880 |
| BIRB-USD | 5 s | 0,4 % | -209 pb | 45 308 | ≈ $0 | $1 726 |
| BIRB-USD | 10 s | 1,0 % | -208 pb | 34 510 | ≈ $0 | $1 726 |
| BIRB-USD | 20 s | 2,1 % | -208 pb | 25 351 | ≈ $0 | $1 726 |
| BIRB-USD | 30 s | 3,1 % | -207 pb | 20 875 | ≈ $0 | $1 726 |
| BIRB-USD | 1 min | 5,7 % | -206 pb | 14 371 | ≈ $0 | $1 726 |
| BIRB-USD | 5 min | 17,9 % | -202 pb | 5 331 | ≈ $0 | $1 726 |
| BIRB-USD | 15 min | 32,9 % | -198 pb | 2 518 | ≈ $0 | $1 726 |
| BIRB-USD | 1 h | 55,0 % | -185 pb | 1 020 | ≈ $0 | $1 726 |
| BIRB-USD | 3 h | 70,0 % | -185 pb | 543 | $0,09 | $1 726 |
| BIRB-USD | 5 h | 75,9 % | -175 pb | 411 | $1,10 | $1 726 |
| BIRB-USD | sin plazo | 98,6 % | -34 pb | 66 | $516 | $1 726 |
| ALIGN-USD | 5 s | 0,6 % | -202 pb | 36 109 | ≈ $0 | $790 |
| ALIGN-USD | 10 s | 1,2 % | -201 pb | 24 640 | ≈ $0 | $790 |
| ALIGN-USD | 20 s | 2,4 % | -200 pb | 16 853 | ≈ $0 | $790 |
| ALIGN-USD | 30 s | 3,3 % | -199 pb | 13 572 | ≈ $0 | $790 |
| ALIGN-USD | 1 min | 5,8 % | -197 pb | 9 400 | ≈ $0 | $790 |
| ALIGN-USD | 5 min | 15,6 % | -191 pb | 4 016 | ≈ $0 | $790 |
| ALIGN-USD | 15 min | 25,4 % | -186 pb | 2 087 | ≈ $0 | $790 |
| ALIGN-USD | 1 h | 41,6 % | -178 pb | 822 | ≈ $0 | $790 |
| ALIGN-USD | 3 h | 54,5 % | -163 pb | 381 | $0,89 | $790 |
| ALIGN-USD | 5 h | 61,5 % | -154 pb | 272 | $5,73 | $790 |
| ALIGN-USD | sin plazo | 99,5 % | 1 pb | 7 | $713 | $790 |

Las 10 mejores combinaciones de intro (cualquier activo, modo, margen y plazo), por capital final:

| Activo | Modo | Margen | Plazo | Capital 30 días | 1.ª mitad (CyM) | 2.ª mitad (CyM) | Pasa |
|---|---|---|---|---|---|---|---|
| ICNT-USD | TM | 100 pb | sin plazo | $1 412 | $967 ($1 887) | $1 123 ($1 593) | no |
| ICNT-USD | TT | 100 pb | sin plazo | $1 265 | $876 ($1 887) | $1 058 ($1 593) | no |
| ICNT-USD | TM | 50 pb | sin plazo | $1 186 | $832 ($1 887) | $1 021 ($1 593) | no |
| ICNT-USD | TT | 50 pb | sin plazo | $1 098 | $767 ($1 887) | $998 ($1 593) | no |
| ICNT-USD | TM | 25 pb | sin plazo | $1 049 | $742 ($1 887) | $973 ($1 593) | no |
| ICNT-USD | TT | 25 pb | sin plazo | $1 011 | $715 ($1 887) | $957 ($1 593) | no |
| PEPE-USD | TM | 100 pb | sin plazo | $1 007 | $974 ($1 068) | $966 ($1 129) | no |
| PEPE-USD | TT | 100 pb | sin plazo | $987 | $965 ($1 068) | $958 ($1 129) | no |
| ZEC-USD | TM | 100 pb | sin plazo | $980 | $887 ($900) | $1 011 ($1 102) | no |
| ZEC-USD | TT | 50 pb | sin plazo | $974 | $883 ($900) | $985 ($1 102) | no |

### Con velas de 1 min

Comprar al ask (taker), dejar la venta límite (maker) con 10 pb de ganancia neta y esperar hasta el plazo; si no se llena, vender a mercado. "Acierto" y "media" con entradas cada 10 s (solapadas). "Capital" = simulación secuencial con $1000 en los 30 días, una operación detrás de otra reinvirtiendo todo. "Comprar y mantener" = comprar el primer día y vender el último.

| Activo | Plazo | Acierto | Media por operación | Operaciones | Capital tras 30 días | Comprar y mantener |
|---|---|---|---|---|---|---|
| BTC-USD | 1 min | 0,0 % | -178 pb | 21 599 | ≈ $0 | $894 |
| BTC-USD | 5 min | 0,0 % | -178 pb | 7 200 | ≈ $0 | $894 |
| BTC-USD | 15 min | 0,0 % | -179 pb | 2 701 | ≈ $0 | $894 |
| BTC-USD | 1 h | 0,6 % | -180 pb | 710 | ≈ $0 | $894 |
| BTC-USD | 3 h | 3,1 % | -182 pb | 244 | $12 | $894 |
| BTC-USD | 5 h | 5,7 % | -183 pb | 146 | $67 | $894 |
| BTC-USD | sin plazo | 77,1 % | -174 pb | 2 | $882 | $894 |
| ETH-USD | 1 min | 0,0 % | -178 pb | 21 599 | ≈ $0 | $857 |
| ETH-USD | 5 min | 0,0 % | -179 pb | 7 201 | ≈ $0 | $857 |
| ETH-USD | 15 min | 0,2 % | -179 pb | 2 702 | ≈ $0 | $857 |
| ETH-USD | 1 h | 1,2 % | -180 pb | 714 | ≈ $0 | $857 |
| ETH-USD | 3 h | 6,4 % | -184 pb | 249 | $11 | $857 |
| ETH-USD | 5 h | 11,2 % | -187 pb | 158 | $57 | $857 |
| ETH-USD | sin plazo | 81,0 % | -195 pb | 1 | $857 | $857 |
| SOL-USD | 1 min | 0,0 % | -178 pb | 21 599 | ≈ $0 | $763 |
| SOL-USD | 5 min | 0,0 % | -179 pb | 7 201 | ≈ $0 | $763 |
| SOL-USD | 15 min | 0,3 % | -179 pb | 2 702 | ≈ $0 | $763 |
| SOL-USD | 1 h | 2,4 % | -181 pb | 716 | ≈ $0 | $763 |
| SOL-USD | 3 h | 8,6 % | -187 pb | 256 | $8,33 | $763 |
| SOL-USD | 5 h | 14,4 % | -191 pb | 159 | $48 | $763 |
| SOL-USD | sin plazo | 77,1 % | -338 pb | 1 | $763 | $763 |
| NEAR-USD | 1 min | 0,0 % | -178 pb | 21 452 | ≈ $0 | $706 |
| NEAR-USD | 5 min | 0,6 % | -178 pb | 7 194 | ≈ $0 | $706 |
| NEAR-USD | 15 min | 3,5 % | -178 pb | 2 733 | ≈ $0 | $706 |
| NEAR-USD | 1 h | 19,1 % | -174 pb | 785 | ≈ $0 | $706 |
| NEAR-USD | 3 h | 41,2 % | -174 pb | 329 | $3,36 | $706 |
| NEAR-USD | 5 h | 51,2 % | -178 pb | 229 | $20 | $706 |
| NEAR-USD | sin plazo | 84,8 % | -319 pb | 11 | $630 | $706 |
| ZEC-USD | 1 min | 0,0 % | -178 pb | 21 554 | ≈ $0 | $1 011 |
| ZEC-USD | 5 min | 0,5 % | -178 pb | 7 204 | ≈ $0 | $1 011 |
| ZEC-USD | 15 min | 3,0 % | -177 pb | 2 731 | ≈ $0 | $1 011 |
| ZEC-USD | 1 h | 16,6 % | -172 pb | 779 | ≈ $0 | $1 011 |
| ZEC-USD | 3 h | 36,6 % | -172 pb | 325 | $5,05 | $1 011 |
| ZEC-USD | 5 h | 46,8 % | -175 pb | 228 | $27 | $1 011 |
| ZEC-USD | sin plazo | 100,0 % | 10 pb | 4 | $964 | $1 011 |
| ENA-USD | 1 min | 0,0 % | -178 pb | 20 506 | ≈ $0 | $729 |
| ENA-USD | 5 min | 0,6 % | -178 pb | 7 083 | ≈ $0 | $729 |
| ENA-USD | 15 min | 3,7 % | -178 pb | 2 715 | ≈ $0 | $729 |
| ENA-USD | 1 h | 19,3 % | -174 pb | 786 | ≈ $0 | $729 |
| ENA-USD | 3 h | 42,1 % | -172 pb | 326 | $3,33 | $729 |
| ENA-USD | 5 h | 52,9 % | -177 pb | 229 | $20 | $729 |
| ENA-USD | sin plazo | 92,0 % | -132 pb | 7 | $669 | $729 |
| HYPE-USD | 1 min | 0,0 % | -178 pb | 20 461 | ≈ $0 | $879 |
| HYPE-USD | 5 min | 0,2 % | -178 pb | 7 056 | ≈ $0 | $879 |
| HYPE-USD | 15 min | 0,9 % | -178 pb | 2 690 | ≈ $0 | $879 |
| HYPE-USD | 1 h | 5,0 % | -179 pb | 726 | ≈ $0 | $879 |
| HYPE-USD | 3 h | 15,5 % | -180 pb | 266 | $8,48 | $879 |
| HYPE-USD | 5 h | 23,9 % | -181 pb | 176 | $46 | $879 |
| HYPE-USD | sin plazo | 87,0 % | -141 pb | 7 | $808 | $879 |
| BIRB-USD | 1 min | 4,5 % | -177 pb | 8 725 | ≈ $0 | $1 731 |
| BIRB-USD | 5 min | 14,7 % | -173 pb | 4 237 | ≈ $0 | $1 731 |
| BIRB-USD | 15 min | 28,6 % | -171 pb | 2 187 | ≈ $0 | $1 731 |
| BIRB-USD | 1 h | 51,8 % | -160 pb | 920 | ≈ $0 | $1 731 |
| BIRB-USD | 3 h | 67,9 % | -158 pb | 488 | $0,27 | $1 731 |
| BIRB-USD | 5 h | 74,4 % | -147 pb | 363 | $2,00 | $1 731 |
| BIRB-USD | sin plazo | 99,2 % | -12 pb | 41 | $514 | $1 731 |
| ALIGN-USD | 1 min | 4,7 % | -176 pb | 5 604 | ≈ $0 | $787 |
| ALIGN-USD | 5 min | 13,2 % | -172 pb | 3 137 | ≈ $0 | $787 |
| ALIGN-USD | 15 min | 22,5 % | -169 pb | 1 793 | ≈ $0 | $787 |
| ALIGN-USD | 1 h | 38,3 % | -167 pb | 745 | ≈ $0 | $787 |
| ALIGN-USD | 3 h | 53,2 % | -154 pb | 357 | $2,27 | $787 |
| ALIGN-USD | 5 h | 60,9 % | -144 pb | 265 | $9,82 | $787 |
| ALIGN-USD | sin plazo | 99,6 % | 4 pb | 7 | $739 | $787 |

Las 10 mejores combinaciones de intro (cualquier activo, modo, margen y plazo), por capital final:

| Activo | Modo | Margen | Plazo | Capital 30 días | 1.ª mitad (CyM) | 2.ª mitad (CyM) | Pasa |
|---|---|---|---|---|---|---|---|
| ICNT-USD | TM | 100 pb | sin plazo | $1 436 | $1 023 ($1 891) | $1 131 ($1 589) | no |
| ICNT-USD | TT | 100 pb | sin plazo | $1 380 | $993 ($1 891) | $1 120 ($1 589) | no |
| ICNT-USD | TM | 50 pb | sin plazo | $1 196 | $882 ($1 891) | $1 035 ($1 589) | no |
| ICNT-USD | TT | 50 pb | sin plazo | $1 160 | $860 ($1 891) | $1 014 ($1 589) | no |
| ICNT-USD | TM | 25 pb | sin plazo | $1 074 | $812 ($1 891) | $980 ($1 589) | no |
| ICNT-USD | TT | 25 pb | sin plazo | $1 027 | $781 ($1 891) | $963 ($1 589) | no |
| PEPE-USD | TM | 100 pb | sin plazo | $1 019 | $966 ($1 072) | $999 ($1 134) | no |
| PEPE-USD | TT | 100 pb | sin plazo | $999 | $962 ($1 072) | $970 ($1 134) | no |
| ZEC-USD | TM | 100 pb | sin plazo | $981 | $890 ($901) | $1 015 ($1 102) | no |
| ZEC-USD | TT | 100 pb | sin plazo | $975 | $882 ($901) | $1 000 ($1 102) | no |

**Nivel de comisión necesario (trades, TM):** ninguna combinación pasa en ningún nivel hasta vip_1. 

**Nivel de comisión necesario (velas, TM):** ninguna combinación pasa en ningún nivel hasta vip_1. 

## Horizonte fijo de 5 a 60 segundos (puerta ρ de la F1)

ρ_req es la correlación que tendría que tener una señal con el movimiento a h segundos para cubrir la comisión operando solo el 1 % de momentos más prometedores; la puerta pide ≤ 0,20. "Veces al día" = ventanas de h segundos en que el precio subió al menos lo que cuesta la comisión.

| Activo | σ 5 s | σ 10 s | σ 20 s | σ 30 s | σ 60 s | ρ TM 5 s | ρ TM 10 s | ρ TM 20 s | ρ TM 30 s | ρ TM 60 s | Veces/día que sube ≥ U a 20 s |
|---|---|---|---|---|---|---|---|---|---|---|---|
| BTC-USD | 1,4 pb | 2,0 pb | 2,8 pb | 3,5 pb | 5,0 pb | 26,76 | 19,94 | 13,61 | 11,64 | 8,00 | 0,00 |
| ETH-USD | 2,0 pb | 2,8 pb | 3,9 pb | 4,8 pb | 6,9 pb | 18,34 | 13,42 | 9,56 | 8,14 | 5,40 | 0,00 |
| SOL-USD | 2,4 pb | 3,4 pb | 4,7 pb | 5,8 pb | 8,1 pb | 16,60 | 12,48 | 8,68 | 7,17 | 4,68 | 0,00 |
| NEAR-USD | 5,4 pb | 7,5 pb | 10,4 pb | 12,8 pb | 17,8 pb | 7,54 | 5,74 | 4,05 | 3,38 | 2,29 | 0,00 |
| ZEC-USD | 4,7 pb | 6,6 pb | 9,3 pb | 11,5 pb | 16,0 pb | 8,43 | 6,19 | 4,44 | 3,63 | 2,62 | 0,00 |
| ENA-USD | 5,3 pb | 7,4 pb | 10,6 pb | 12,6 pb | 17,5 pb | 6,85 | 5,34 | 3,95 | 3,34 | 2,40 | 0,03 |
| HYPE-USD | 2,8 pb | 4,1 pb | 5,8 pb | 7,2 pb | 10,2 pb | 12,15 | 9,23 | 6,36 | 5,21 | 3,41 | 0,00 |
| BIRB-USD | 15,5 pb | 21,1 pb | 29,8 pb | 35,9 pb | 51,8 pb | 1,37 | 1,07 | 0,74 | 0,63 | 0,39 | 9,32 |
| ALIGN-USD | 13,0 pb | 17,1 pb | 23,0 pb | 27,8 pb | 38,7 pb | 1,43 | 1,12 | 0,88 | 0,76 | 0,52 | 5,87 |

## Exploratorio: entrar solo cuando ya empezó a subir

NO decide (con muchas variantes alguna sale bien por azar). Disparo: el ask subió al menos X pb en 5 s y hubo una compra taker en ese segundo; cuenta solo el primer segundo de cada subida (episodio). Luego la misma venta límite con 10 pb netos y plazo de 20 s, 60 s o 5 min.

| Activo | Subida en 5 s | Episodios/día | Acierto 20 s | Media 20 s | Acierto 5 min | Media 5 min |
|---|---|---|---|---|---|---|
| ICNT-USD | 25 pb | 258,2 | 1,6 % | -194 pb | 18,5 % | -189 pb |
| BIRB-USD | 25 pb | 212,8 | 6,2 % | -200 pb | 34,4 % | -192 pb |
| STRK-USD | 25 pb | 184,9 | 1,3 % | -185 pb | 19,8 % | -173 pb |
| ALIGN-USD | 25 pb | 116,9 | 7,3 % | -202 pb | 31,6 % | -188 pb |
| CLANKER-USD | 25 pb | 106,1 | 2,0 % | -191 pb | 20,9 % | -186 pb |
| USELESS-USD | 25 pb | 106,1 | 0,2 % | -191 pb | 6,4 % | -188 pb |
| BIRB-USD | 50 pb | 105,8 | 10,1 % | -203 pb | 43,0 % | -199 pb |
| ZRO-USD | 25 pb | 102,3 | 0,2 % | -188 pb | 6,4 % | -187 pb |
| LIGHTER-USD | 25 pb | 97,0 | 0,3 % | -187 pb | 7,9 % | -185 pb |
| PONS-USD | 25 pb | 95,1 | 0,1 % | -184 pb | 4,1 % | -185 pb |
| ICNT-USD | 50 pb | 92,5 | 3,0 % | -197 pb | 24,4 % | -185 pb |
| DRV-USD | 25 pb | 90,1 | 1,3 % | -204 pb | 13,2 % | -194 pb |
| ALIGN-USD | 50 pb | 67,9 | 10,2 % | -207 pb | 38,0 % | -198 pb |
| PEPE-USD | 25 pb | 67,6 | 0,3 % | -190 pb | 9,1 % | -185 pb |
| VVV-USD | 25 pb | 63,2 | 0,1 % | -189 pb | 4,2 % | -188 pb |
| FET-USD | 25 pb | 58,7 | 0,1 % | -200 pb | 2,8 % | -202 pb |
| INJ-USD | 25 pb | 57,4 | 0,1 % | -186 pb | 3,3 % | -186 pb |
| ENA-USD | 25 pb | 51,7 | 0,2 % | -188 pb | 7,1 % | -187 pb |
| QNT-USD | 25 pb | 51,3 | 0,4 % | -184 pb | 5,3 % | -181 pb |
| AERO-USD | 25 pb | 47,6 | 0,3 % | -191 pb | 3,0 % | -191 pb |

## Comprobaciones

- Lados de Exchange, por barridos (trades seguidos del mismo lado en el mismo milisegundo, una orden que recorre el libro): los que el código toma por compras taker suben el precio 3 852 279 veces y lo bajan 13 538; los que toma por ventas lo bajan 3 883 030 y lo suben 12 694. Confirma que side=sell es un taker comprador.
- Compras taker que llegaron fuera de orden de tiempo (no cuentan en la variante con volumen): 0.

## Sesgos y límites (declarados antes de mirar)

- Llenado de la venta límite: basta con que algún taker comprador pague el objetivo o más, de cualquier tamaño; en la realidad habría cola delante y la compra tendría que cubrir ~$1000. Favorable a la estrategia. La variante con volumen (≥ $1000 en un mismo segundo) es la cota contraria: la verdad queda entre las dos.
- Con velas: entrada al cierre y salida al cierre, sin spread, y llenado con el máximo de la vela. Favorable.
- Con trades: ask y bid salen del último taker de cada lado; el lado que no opera se mueve con el que sí, y si lleva más de 60 s sin operar se reancla al otro con el spread mediano. Si nadie operó en 60 s, último trade ± medio spread.
- Se entra sin señal, en cualquier momento. Una señal real tendría que ser muy buena: eso es lo que mide la puerta ρ. El exploratorio de impulso prueba la señal más obvia.
- Supervivencia: el universo es el de hoy mirando 30 días atrás.
