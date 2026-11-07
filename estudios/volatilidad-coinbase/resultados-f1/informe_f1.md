# F1 — Puerta barata: velas de 1 min

- Ventana: 2026-10-07 18:39 → 2026-11-06 18:39 UTC (30 días).
- Universo: 51 activos (USD con ≥ $1M/día el día de la descarga, más controles); 51 completos y con ≥ 7 días de datos. Embudo de los productos SPOT: {'universo': 51, 'alias_usdc': 408, 'otra_moneda': 107, 'estable': 1, 'limit_only': 20, 'volumen_bajo': 338, 'no_operable': 4}.
- Nivel de comisión evaluado: **intro** (SUPUESTO, sin confirmar por el dueño); región US. Parámetros v2.
- Descarga terminada 2026-11-06T20:30:45Z: 1 638 439 velas, 0 tramos con error, 4 997 peticiones, 0 respuestas 429.

## Decisión de la puerta

Regla preregistrada: un modo pasa en un nivel si alguna combinación activo × horizonte tiene ρ_req ≤ 0,20 con q = 1 %. ρ_req es la correlación que haría falta entre una señal y el retorno para cubrir la comisión operando solo el 1 % de ventanas más prometedoras. Se calcula con el factor normal y con el empírico (colas reales del activo) y decide el más favorable a la estrategia.

- **TT en intro: PASA**. Pasan 1 de 204 combinaciones. Mejor caso: BIRB-USD a 15 min, ρ_req = 0,08 (normal 0,34, empírico 0,08; U = 182 pb, σ = 203 pb).
- **MT en intro: PASA**. Pasan 3 de 204 combinaciones. Mejor caso: BIRB-USD a 15 min, ρ_req = 0,06 (normal 0,26, empírico 0,06; U = 141 pb, σ = 203 pb).
- **TM en intro: PASA**. Pasan 3 de 204 combinaciones. Mejor caso: BIRB-USD a 15 min, ρ_req = 0,06 (normal 0,26, empírico 0,06; U = 141 pb, σ = 203 pb).

| Nivel | TT pasan | Mejor ρ_req TT | MT pasan | Mejor ρ_req MT | TM pasan | Mejor ρ_req TM | MM pasan (informativo) |
|---|---|---|---|---|---|---|---|
| intro | 1/204 | 0,08 (BIRB-USD, 15 min) | 3/204 | 0,06 (BIRB-USD, 15 min) | 3/204 | 0,06 (BIRB-USD, 15 min) | 7/204 |
| advanced_1 | 3/204 | 0,07 (BIRB-USD, 15 min) | 5/204 | 0,05 (BIRB-USD, 15 min) | 5/204 | 0,05 (BIRB-USD, 15 min) | 10/204 |
| advanced_2 | 13/204 | 0,03 (BIRB-USD, 15 min) | 21/204 | 0,02 (BIRB-USD, 15 min) | 21/204 | 0,02 (BIRB-USD, 15 min) | 44/204 |
| advanced_3 | 44/204 | 0,01 (BIRB-USD, 15 min) | 55/204 | 0,01 (BIRB-USD, 15 min) | 55/204 | 0,01 (BIRB-USD, 15 min) | 77/204 |
| vip_1 | 77/204 | 0,01 (BIRB-USD, 15 min) | 99/204 | 0,01 (BIRB-USD, 15 min) | 99/204 | 0,01 (BIRB-USD, 15 min) | 132/204 |
| vip_2 | 132/204 | 0,01 (BIRB-USD, 15 min) | 152/204 | 0,00 (BIRB-USD, 15 min) | 152/204 | 0,00 (BIRB-USD, 15 min) | 176/204 |
| vip_3 | 152/204 | 0,00 (BIRB-USD, 15 min) | 193/204 | 0,00 (BIRB-USD, 15 min) | 193/204 | 0,00 (BIRB-USD, 15 min) | 204/204 |
| intro_coinbase_one | 3/204 | 0,06 (BIRB-USD, 15 min) | 7/204 | 0,05 (BIRB-USD, 15 min) | 7/204 | 0,05 (BIRB-USD, 15 min) | 10/204 |

## Top 10

### Literal: volatilidad de las últimas 24 h

| # | Activo | rv 5 min (pb) | Cambio 24 h | Sin trade | Spread mediano | Operable |
|---|---|---|---|---|---|---|
| 1 | ALIGN-USD | 198,3 | -7,1 % | 80,7 % | 22,0 pb | no |
| 2 | BIRB-USD | 142,4 | 8,2 % | 68,6 % | 31,7 pb | no |
| 3 | ICNT-USD | 100,4 | 38,2 % | 54,8 % | 17,0 pb | no |
| 4 | CLANKER-USD | 98,1 | -5,8 % | 82,3 % | 18,5 pb | no |
| 5 | PONS-USD | 63,1 | 2,9 % | 52,6 % | 10,3 pb | no |
| 6 | LIGHTER-USD | 60,8 | -1,2 % | 44,9 % | 12,1 pb | no |
| 7 | USELESS-USD | 58,2 | 5,6 % | 40,4 % | 14,8 pb | no |
| 8 | ZEC-USD | 52,7 | 8,9 % | 0,4 % | 3,5 pb | sí |
| 9 | TRUMP-USD | 45,2 | 2,7 % | 22,8 % | 8,2 pb | no |
| 10 | VVV-USD | 42,9 | 0,7 % | 29,2 % | 10,6 pb | no |

### Literal: volatilidad de los 30 días

| # | Activo | rv 5 min (pb) | Cambio 24 h | Sin trade | Spread mediano | Operable |
|---|---|---|---|---|---|---|
| 1 | BIRB-USD | 110,0 | 8,2 % | 68,6 % | 31,7 pb | no |
| 2 | ICNT-USD | 81,9 | 38,2 % | 54,8 % | 17,0 pb | no |
| 3 | ALIGN-USD | 75,8 | -7,1 % | 80,7 % | 22,0 pb | no |
| 4 | STRK-USD | 62,3 | 1,8 % | 14,2 % | 9,7 pb | no |
| 5 | CLANKER-USD | 55,8 | -5,8 % | 82,3 % | 18,5 pb | no |
| 6 | PONS-USD | 49,9 | 2,9 % | 52,6 % | 10,3 pb | no |
| 7 | USELESS-USD | 49,7 | 5,6 % | 40,4 % | 14,8 pb | no |
| 8 | WLD-USD | 49,1 | 0,3 % | 28,0 % | 11,6 pb | no |
| 9 | ZRO-USD | 44,9 | -1,3 % | 15,8 % | 9,8 pb | no |
| 10 | LIGHTER-USD | 44,2 | -1,2 % | 44,9 % | 12,1 pb | no |

### Operable: movimiento típico a 5 min ÷ coste real a $1000

Filtros: spread mediano ≤ 30 pb, ≤ 10 % de minutos sin trade y ≥ $2000 por lado a ±25 pb. El coste incluye comisión taker de intro y el libro en las dos patas.

| # | Activo | σ 5 min (pb) | Coste ida y vuelta $1000 (pb) | Movimiento ÷ coste |
|---|---|---|---|---|
| 1 | NEAR-USD | 38,4 | 187,3 | 0,21 |
| 2 | ENA-USD | 38,1 | 190,5 | 0,20 |
| 3 | ZEC-USD | 34,8 | 186,9 | 0,19 |
| 4 | UNI-USD | 29,6 | 187,9 | 0,16 |
| 5 | ONDO-USD | 28,5 | 187,9 | 0,15 |
| 6 | SUI-USD | 25,1 | 185,6 | 0,14 |
| 7 | HYPE-USD | 23,0 | 184,2 | 0,12 |
| 8 | ADA-USD | 22,5 | 185,5 | 0,12 |
| 9 | AVAX-USD | 22,8 | 188,0 | 0,12 |
| 10 | HBAR-USD | 22,2 | 186,1 | 0,12 |

## Detalle por activo en intro

P(fija) = fracción de minutos en que comprar y vender a h habría cubierto la comisión. P(MFE) = lo mismo vendiendo en el máximo de las velas siguientes (cota optimista). Oráculo = techo de minutos operables sin perder en media acertando siempre los mejores, con posiciones solapadas (capital repartido). ρ_req es el que decide (el menor entre normal y empírico).

| Activo | h | σ_h (pb) | U TT (pb) | P(fija) TT | P(MFE) TT | Oráculo TT | ρ_req TT | ρ_req MT | ρ_req TM | Nivel mínimo TT | Nivel mínimo MT/TM |
|---|---|---|---|---|---|---|---|---|---|---|---|
| ADA-USD | 1 min | 10,5 | 182 | 0,00 % | 0,00 % | 0,00 % | 4,92 | 3,82 | 3,81 | ninguno | vip_3 |
| ADA-USD | 2 min | 14,4 | 182 | 0,00 % | 0,00 % | 0,00 % | 4,03 | 3,14 | 3,12 | ninguno | vip_3 |
| ADA-USD | 5 min | 22,5 | 182 | 0,00 % | 0,03 % | 0,01 % | 2,98 | 2,32 | 2,31 | vip_2 | vip_2 |
| ADA-USD | 15 min | 39,5 | 182 | 0,13 % | 0,27 % | 0,37 % | 1,66 | 1,29 | 1,28 | vip_1 | vip_1 |
| ALIGN-USD | 1 min | 35,0 | 182 | 1,80 % | 3,45 % | 5,25 % | 0,74 | 0,58 | 0,57 | advanced_3 | advanced_2 |
| ALIGN-USD | 2 min | 46,7 | 182 | 2,70 % | 5,91 % | 9,09 % | 0,58 | 0,45 | 0,45 | advanced_2 | advanced_2 |
| ALIGN-USD | 5 min | 77,3 | 182 | 4,98 % | 10,74 % | 16,96 % | 0,31 | 0,24 | 0,24 | advanced_2 | advanced_1 |
| ALIGN-USD | 15 min | 124,0 | 182 | 8,57 % | 19,32 % | 33,66 % | 0,21 | 0,17 | 0,16 | advanced_1 | intro |
| AVAX-USD | 1 min | 10,3 | 182 | 0,00 % | 0,00 % | 0,00 % | 5,16 | 4,01 | 4,00 | ninguno | vip_3 |
| AVAX-USD | 2 min | 14,3 | 182 | 0,00 % | 0,00 % | 0,00 % | 4,07 | 3,16 | 3,15 | ninguno | vip_3 |
| AVAX-USD | 5 min | 22,8 | 182 | 0,01 % | 0,01 % | 0,01 % | 2,95 | 2,29 | 2,29 | vip_2 | vip_2 |
| AVAX-USD | 15 min | 39,8 | 182 | 0,11 % | 0,18 % | 0,31 % | 1,71 | 1,33 | 1,33 | vip_1 | vip_1 |
| BIRB-USD | 1 min | 49,9 | 182 | 1,82 % | 3,18 % | 6,22 % | 0,56 | 0,44 | 0,44 | advanced_2 | advanced_2 |
| BIRB-USD | 2 min | 70,7 | 182 | 3,14 % | 5,74 % | 11,06 % | 0,34 | 0,27 | 0,27 | advanced_2 | advanced_2 |
| BIRB-USD | 5 min | 112,1 | 182 | 6,20 % | 11,65 % | 23,78 % | 0,20 | 0,16 | 0,16 | advanced_1 | intro |
| BIRB-USD | 15 min | 202,8 | 182 | 12,56 % | 24,30 % | 48,84 % | 0,08 | 0,06 | 0,06 | intro | intro |
| BTC-USD | 1 min | 5,0 | 182 | 0,00 % | 0,00 % | 0,00 % | 9,75 | 7,58 | 7,55 | ninguno | ninguno |
| BTC-USD | 2 min | 7,0 | 182 | 0,00 % | 0,00 % | 0,00 % | 7,71 | 6,00 | 5,98 | ninguno | ninguno |
| BTC-USD | 5 min | 10,9 | 182 | 0,00 % | 0,00 % | 0,00 % | 5,33 | 4,15 | 4,13 | ninguno | vip_3 |
| BTC-USD | 15 min | 18,9 | 182 | 0,01 % | 0,03 % | 0,03 % | 2,73 | 2,12 | 2,12 | vip_2 | vip_2 |
| CLANKER-USD | 1 min | 25,3 | 182 | 0,48 % | 1,13 % | 1,75 % | 1,31 | 1,02 | 1,02 | vip_1 | advanced_3 |
| CLANKER-USD | 2 min | 35,1 | 182 | 1,26 % | 2,68 % | 3,97 % | 1,09 | 0,84 | 0,84 | advanced_3 | advanced_3 |
| CLANKER-USD | 5 min | 55,6 | 182 | 3,40 % | 7,36 % | 10,67 % | 0,64 | 0,50 | 0,49 | advanced_3 | advanced_2 |
| CLANKER-USD | 15 min | 93,6 | 182 | 9,31 % | 18,53 % | 27,18 % | 0,45 | 0,35 | 0,35 | advanced_2 | advanced_2 |
| ENA-USD | 1 min | 17,6 | 182 | 0,00 % | 0,01 % | 0,00 % | 3,04 | 2,37 | 2,36 | vip_3 | vip_2 |
| ENA-USD | 2 min | 24,3 | 182 | 0,03 % | 0,06 % | 0,06 % | 2,42 | 1,88 | 1,87 | vip_2 | vip_2 |
| ENA-USD | 5 min | 38,1 | 182 | 0,15 % | 0,31 % | 0,40 % | 1,69 | 1,32 | 1,31 | vip_1 | vip_1 |
| ENA-USD | 15 min | 65,0 | 182 | 1,04 % | 2,19 % | 2,87 % | 0,99 | 0,77 | 0,77 | advanced_3 | advanced_3 |
| ETH-USD | 1 min | 7,0 | 182 | 0,00 % | 0,00 % | 0,00 % | 6,90 | 5,37 | 5,35 | ninguno | ninguno |
| ETH-USD | 2 min | 9,7 | 182 | 0,00 % | 0,00 % | 0,00 % | 5,72 | 4,45 | 4,43 | ninguno | vip_3 |
| ETH-USD | 5 min | 15,4 | 182 | 0,00 % | 0,01 % | 0,01 % | 3,33 | 2,59 | 2,58 | vip_3 | vip_2 |
| ETH-USD | 15 min | 26,5 | 182 | 0,06 % | 0,11 % | 0,16 % | 2,03 | 1,58 | 1,57 | vip_2 | vip_1 |
| HBAR-USD | 1 min | 10,2 | 182 | 0,00 % | 0,00 % | 0,00 % | 5,17 | 4,02 | 4,01 | ninguno | vip_3 |
| HBAR-USD | 2 min | 14,1 | 182 | 0,00 % | 0,00 % | 0,00 % | 4,27 | 3,32 | 3,31 | ninguno | vip_3 |
| HBAR-USD | 5 min | 22,2 | 182 | 0,01 % | 0,02 % | 0,03 % | 2,90 | 2,26 | 2,25 | vip_2 | vip_2 |
| HBAR-USD | 15 min | 38,1 | 182 | 0,14 % | 0,25 % | 0,37 % | 1,66 | 1,29 | 1,29 | vip_1 | vip_1 |
| HYPE-USD | 1 min | 10,3 | 182 | 0,00 % | 0,01 % | 0,01 % | 4,26 | 3,31 | 3,30 | ninguno | vip_3 |
| HYPE-USD | 2 min | 14,4 | 182 | 0,02 % | 0,03 % | 0,04 % | 2,82 | 2,20 | 2,19 | vip_2 | vip_2 |
| HYPE-USD | 5 min | 23,0 | 182 | 0,07 % | 0,11 % | 0,20 % | 1,75 | 1,36 | 1,36 | vip_1 | vip_1 |
| HYPE-USD | 15 min | 38,7 | 182 | 0,30 % | 0,60 % | 0,94 % | 1,14 | 0,89 | 0,88 | advanced_3 | advanced_3 |
| ICNT-USD | 1 min | 37,9 | 182 | 0,59 % | 1,00 % | 1,70 % | 1,12 | 0,87 | 0,87 | advanced_3 | advanced_3 |
| ICNT-USD | 2 min | 52,7 | 182 | 1,31 % | 2,37 % | 3,96 % | 0,84 | 0,65 | 0,65 | advanced_3 | advanced_3 |
| ICNT-USD | 5 min | 82,0 | 182 | 3,42 % | 6,77 % | 10,58 % | 0,54 | 0,42 | 0,42 | advanced_2 | advanced_2 |
| ICNT-USD | 15 min | 136,0 | 182 | 9,37 % | 18,91 % | 27,97 % | 0,34 | 0,27 | 0,26 | advanced_2 | advanced_2 |
| LIGHTER-USD | 1 min | 19,6 | 182 | 0,03 % | 0,07 % | 0,10 % | 2,47 | 1,92 | 1,91 | vip_2 | vip_2 |
| LIGHTER-USD | 2 min | 27,6 | 182 | 0,10 % | 0,21 % | 0,31 % | 1,76 | 1,37 | 1,36 | vip_1 | vip_1 |
| LIGHTER-USD | 5 min | 44,3 | 182 | 0,51 % | 0,91 % | 1,54 % | 0,95 | 0,74 | 0,74 | advanced_3 | advanced_3 |
| LIGHTER-USD | 15 min | 74,8 | 182 | 2,18 % | 4,40 % | 6,93 % | 0,62 | 0,48 | 0,48 | advanced_3 | advanced_2 |
| NEAR-USD | 1 min | 17,9 | 182 | 0,01 % | 0,01 % | 0,02 % | 2,91 | 2,27 | 2,26 | vip_2 | vip_2 |
| NEAR-USD | 2 min | 25,0 | 182 | 0,04 % | 0,05 % | 0,09 % | 2,14 | 1,66 | 1,65 | vip_2 | vip_1 |
| NEAR-USD | 5 min | 38,4 | 182 | 0,14 % | 0,34 % | 0,39 % | 1,58 | 1,23 | 1,23 | vip_1 | vip_1 |
| NEAR-USD | 15 min | 64,8 | 182 | 0,95 % | 1,94 % | 2,76 % | 0,88 | 0,68 | 0,68 | advanced_3 | advanced_3 |
| ONDO-USD | 1 min | 12,9 | 182 | 0,00 % | 0,00 % | 0,00 % | 4,15 | 3,23 | 3,22 | ninguno | vip_3 |
| ONDO-USD | 2 min | 17,8 | 182 | 0,00 % | 0,01 % | 0,01 % | 3,13 | 2,44 | 2,43 | vip_3 | vip_2 |
| ONDO-USD | 5 min | 28,5 | 182 | 0,03 % | 0,06 % | 0,08 % | 2,21 | 1,72 | 1,71 | vip_2 | vip_1 |
| ONDO-USD | 15 min | 48,6 | 182 | 0,36 % | 0,66 % | 1,11 % | 1,08 | 0,84 | 0,84 | advanced_3 | advanced_3 |
| PONS-USD | 1 min | 22,3 | 182 | 0,03 % | 0,06 % | 0,08 % | 2,20 | 1,71 | 1,70 | vip_2 | vip_1 |
| PONS-USD | 2 min | 31,6 | 182 | 0,07 % | 0,16 % | 0,22 % | 1,64 | 1,27 | 1,27 | vip_1 | vip_1 |
| PONS-USD | 5 min | 49,9 | 182 | 0,51 % | 0,98 % | 1,46 % | 1,00 | 0,78 | 0,78 | advanced_3 | advanced_3 |
| PONS-USD | 15 min | 85,5 | 182 | 2,89 % | 5,70 % | 8,37 % | 0,64 | 0,50 | 0,50 | advanced_3 | advanced_2 |
| STRK-USD | 1 min | 27,7 | 182 | 0,12 % | 0,25 % | 0,40 % | 1,38 | 1,07 | 1,07 | vip_1 | advanced_3 |
| STRK-USD | 2 min | 38,4 | 182 | 0,37 % | 0,73 % | 1,07 % | 1,08 | 0,84 | 0,84 | advanced_3 | advanced_3 |
| STRK-USD | 5 min | 62,4 | 182 | 1,23 % | 2,48 % | 3,66 % | 0,63 | 0,49 | 0,49 | advanced_3 | advanced_2 |
| STRK-USD | 15 min | 104,7 | 182 | 4,00 % | 8,14 % | 12,68 % | 0,47 | 0,36 | 0,36 | advanced_2 | advanced_2 |
| SUI-USD | 1 min | 11,7 | 182 | 0,00 % | 0,00 % | 0,00 % | 4,63 | 3,60 | 3,59 | ninguno | vip_3 |
| SUI-USD | 2 min | 15,9 | 182 | 0,00 % | 0,01 % | 0,00 % | 3,83 | 2,98 | 2,97 | ninguno | vip_3 |
| SUI-USD | 5 min | 25,1 | 182 | 0,00 % | 0,04 % | 0,01 % | 2,63 | 2,05 | 2,04 | vip_2 | vip_2 |
| SUI-USD | 15 min | 44,1 | 182 | 0,21 % | 0,44 % | 0,54 % | 1,44 | 1,12 | 1,11 | vip_1 | advanced_3 |
| TRUMP-USD | 1 min | 13,4 | 182 | 0,02 % | 0,03 % | 0,04 % | 3,16 | 2,46 | 2,45 | vip_3 | vip_2 |
| TRUMP-USD | 2 min | 18,6 | 182 | 0,03 % | 0,08 % | 0,08 % | 2,51 | 1,95 | 1,94 | vip_2 | vip_2 |
| TRUMP-USD | 5 min | 29,4 | 182 | 0,11 % | 0,26 % | 0,32 % | 1,94 | 1,51 | 1,51 | vip_2 | vip_1 |
| TRUMP-USD | 15 min | 51,2 | 182 | 0,53 % | 1,08 % | 1,62 % | 1,01 | 0,79 | 0,78 | advanced_3 | advanced_3 |
| UNI-USD | 1 min | 13,5 | 182 | 0,00 % | 0,00 % | 0,01 % | 3,99 | 3,10 | 3,09 | ninguno | vip_3 |
| UNI-USD | 2 min | 18,9 | 182 | 0,00 % | 0,01 % | 0,00 % | 3,19 | 2,48 | 2,47 | vip_3 | vip_2 |
| UNI-USD | 5 min | 29,6 | 182 | 0,03 % | 0,11 % | 0,08 % | 2,18 | 1,70 | 1,69 | vip_2 | vip_1 |
| UNI-USD | 15 min | 51,6 | 182 | 0,41 % | 0,89 % | 1,14 % | 1,21 | 0,94 | 0,94 | advanced_3 | advanced_3 |
| USELESS-USD | 1 min | 22,2 | 182 | 0,04 % | 0,10 % | 0,09 % | 2,27 | 1,77 | 1,76 | vip_2 | vip_2 |
| USELESS-USD | 2 min | 31,0 | 182 | 0,08 % | 0,23 % | 0,21 % | 1,71 | 1,33 | 1,32 | vip_1 | vip_1 |
| USELESS-USD | 5 min | 49,7 | 182 | 0,52 % | 1,11 % | 1,39 % | 1,24 | 0,97 | 0,96 | vip_1 | advanced_3 |
| USELESS-USD | 15 min | 85,9 | 182 | 2,90 % | 5,93 % | 8,37 % | 0,66 | 0,52 | 0,51 | advanced_3 | advanced_2 |
| VVV-USD | 1 min | 17,1 | 182 | 0,00 % | 0,02 % | 0,01 % | 3,09 | 2,41 | 2,40 | vip_3 | vip_2 |
| VVV-USD | 2 min | 24,0 | 182 | 0,02 % | 0,08 % | 0,08 % | 2,38 | 1,85 | 1,84 | vip_2 | vip_2 |
| VVV-USD | 5 min | 38,1 | 182 | 0,19 % | 0,45 % | 0,54 % | 1,59 | 1,24 | 1,23 | vip_1 | vip_1 |
| VVV-USD | 15 min | 66,5 | 182 | 1,32 % | 2,75 % | 3,85 % | 0,87 | 0,68 | 0,68 | advanced_3 | advanced_3 |
| WLD-USD | 1 min | 19,6 | 182 | 0,02 % | 0,04 % | 0,10 % | 2,62 | 2,04 | 2,03 | vip_2 | vip_2 |
| WLD-USD | 2 min | 28,8 | 182 | 0,03 % | 0,07 % | 0,23 % | 1,88 | 1,46 | 1,45 | vip_2 | vip_1 |
| WLD-USD | 5 min | 48,5 | 182 | 0,15 % | 0,28 % | 0,78 % | 0,90 | 0,70 | 0,70 | advanced_3 | advanced_3 |
| WLD-USD | 15 min | 90,2 | 182 | 0,83 % | 1,90 % | 3,29 % | 0,32 | 0,25 | 0,25 | advanced_2 | advanced_1 |
| ZEC-USD | 1 min | 16,1 | 182 | 0,00 % | 0,00 % | 0,00 % | 3,22 | 2,51 | 2,50 | vip_3 | vip_2 |
| ZEC-USD | 2 min | 22,4 | 182 | 0,03 % | 0,04 % | 0,05 % | 2,47 | 1,92 | 1,91 | vip_2 | vip_2 |
| ZEC-USD | 5 min | 34,8 | 182 | 0,14 % | 0,28 % | 0,37 % | 1,70 | 1,32 | 1,32 | vip_1 | vip_1 |
| ZEC-USD | 15 min | 59,5 | 182 | 0,86 % | 1,87 % | 2,47 % | 1,03 | 0,80 | 0,80 | advanced_3 | advanced_3 |
| ZRO-USD | 1 min | 20,7 | 182 | 0,01 % | 0,05 % | 0,06 % | 2,38 | 1,85 | 1,84 | vip_2 | vip_2 |
| ZRO-USD | 2 min | 28,7 | 182 | 0,06 % | 0,15 % | 0,17 % | 1,97 | 1,53 | 1,52 | vip_2 | vip_1 |
| ZRO-USD | 5 min | 44,9 | 182 | 0,32 % | 0,75 % | 0,96 % | 1,26 | 0,98 | 0,98 | vip_1 | advanced_3 |
| ZRO-USD | 15 min | 78,6 | 182 | 2,07 % | 4,34 % | 5,98 % | 0,77 | 0,60 | 0,60 | advanced_3 | advanced_2 |

## Curva de monto (fotos del libro, mediana)

Coste de ida y vuelta en pb con comisión taker de intro y el libro en las dos patas. Monto máximo = el menor de: capital menos comisión, lo que llena el libro al comprar y al vender antes de que el precio marginal se aleje 25 pb del mejor precio, y la banda de protección de precio del producto en los dos lados.

| Activo | Fotos | Spread | $10 | $50 | $100 | $250 | $500 | $750 | $1000 | Monto máx. |
|---|---|---|---|---|---|---|---|---|---|---|
| ADA-USD | 7 | 2,2 | 184 | 184 | 184 | 184 | 185 | 185 | 186 | $991 |
| ALIGN-USD | 7 | 22,0 | 205 | 230 | 235 | 256 | 265 | 277 | 284 | $66 |
| AVAX-USD | 7 | 2,4 | 184 | 184 | 185 | 186 | 187 | 187 | 188 | $991 |
| BIRB-USD | 7 | 31,7 | 214 | 215 | 215 | 215 | 216 | 218 | 219 | $991 |
| BTC-USD | 7 | 0,0 | 182 | 182 | 182 | 182 | 182 | 182 | 182 | $991 |
| CLANKER-USD | 7 | 18,5 | 201 | 201 | 201 | 206 | 212 | 217 | 220 | $991 |
| ENA-USD | 7 | 3,6 | 188 | 188 | 188 | 189 | 189 | 190 | 190 | $991 |
| ETH-USD | 7 | 0,5 | 182 | 182 | 182 | 182 | 182 | 182 | 182 | $991 |
| HBAR-USD | 7 | 4,4 | 186 | 186 | 186 | 186 | 186 | 186 | 186 | $991 |
| HYPE-USD | 7 | 2,6 | 184 | 184 | 184 | 184 | 184 | 184 | 184 | $991 |
| ICNT-USD | 7 | 17,0 | 199 | 199 | 199 | 204 | 207 | 213 | 218 | $832 |
| LIGHTER-USD | 7 | 12,1 | 194 | 194 | 197 | 197 | 199 | 202 | 205 | $991 |
| NEAR-USD | 7 | 4,8 | 187 | 187 | 187 | 187 | 187 | 187 | 187 | $991 |
| ONDO-USD | 7 | 3,2 | 187 | 187 | 187 | 187 | 187 | 188 | 188 | $991 |
| PONS-USD | 7 | 10,3 | 192 | 192 | 194 | 197 | 197 | 199 | 202 | $991 |
| STRK-USD | 7 | 9,7 | 192 | 192 | 192 | 193 | 194 | 197 | 199 | $991 |
| SUI-USD | 7 | 3,4 | 185 | 185 | 185 | 185 | 185 | 185 | 186 | $991 |
| TRUMP-USD | 7 | 8,2 | 191 | 191 | 192 | 192 | 193 | 193 | 194 | $991 |
| UNI-USD | 7 | 3,3 | 185 | 185 | 185 | 186 | 187 | 188 | 188 | $991 |
| USELESS-USD | 7 | 14,8 | 197 | 197 | 197 | 198 | 198 | 199 | 200 | $991 |
| VVV-USD | 7 | 10,6 | 192 | 192 | 192 | 193 | 194 | 195 | 196 | $991 |
| WLD-USD | 7 | 11,6 | 193 | 193 | 193 | 193 | 194 | 195 | 195 | $991 |
| ZEC-USD | 7 | 3,5 | 185 | 185 | 185 | 186 | 186 | 187 | 187 | $991 |
| ZRO-USD | 7 | 9,8 | 192 | 192 | 193 | 195 | 197 | 199 | 202 | $991 |

## Sesgos y límites (declarados antes de mirar)

- Las cifras de oportunidad (P, MFE, oráculo) son cotas favorables: coste solo comisión, salida en el máximo de vela. La puerta usa el más favorable de dos factores (normal y colas reales). Un no-go es robusto en ese sentido; un "pasa" solo justifica la F2.
- El factor empírico supone una señal "con ruido de medida" sobre el retorno; si la relación fuera lineal con colas gruesas en el ruido, el factor normal sería el exacto. Por eso se toma el mejor de los dos.
- Supervivencia: el universo es el de HOY mirando 30 días atrás; los activos deslistados no están.
- Velas = trades, no bid/ask: con velas no se puede evaluar maker (MM); MM pasa siempre a la F2.
- Segundos (5-30 s): las velas de 1 min no los ven; se miden en la F2 con el WebSocket.
- El monto sale de pocas fotos de un solo día: la variación por hora y fin de semana es de la F2.
