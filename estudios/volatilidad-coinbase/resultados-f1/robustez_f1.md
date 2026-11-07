# F1 — Diagnóstico de robustez de los "pasa" (posterior, NO cambia la regla)

Hecho el 2026-11-06 después de ver el informe. La regla preregistrada (v2) da
PASA en intro para BIRB-USD a 5 y 15 min y ALIGN-USD a 15 min, y solo por el
factor empírico. Aquí se mide cuánto dependen esos "pasa" de unos pocos
movimientos extremos. Script: diagnostico_colas.py (solo lectura).

ρ_req en intro; "sin m" = recalculado quitando los m retornos de mayor |valor|
de unas ~2.880 ventanas de 15 min (o ~8.600 de 5 min).

| Combinación | Curtosis | Factor emp. | ρ TT | ρ MT | Sin 1: TT / MT | Sin 3 | Sin 10 | Sin el 1 % |
|---|---|---|---|---|---|---|---|---|
| BIRB 15 min | 117 | 11,0 | 0,08 | 0,06 | 0,10 / 0,07 | 0,16 / 0,12 | 0,35 / 0,27 | 0,45 / 0,35 |
| BIRB 5 min | 138 | 8,1 | 0,20 | 0,16 | 0,24 / 0,18 | 0,30 / 0,23 | 0,35 / 0,27 | 0,77 / 0,60 |
| ALIGN 15 min | 64 | 6,9 | 0,21 | 0,17 | 0,26 / 0,20 | 0,34 / 0,27 | 0,49 / 0,38 | 0,60 / 0,46 |
| WLD 15 min (no pasa) | 425 | 6,3 | 0,32 | 0,25 | 1,14 / 0,88 | — | — | — |
| ZEC 15 min (referencia) | 8 | 3,0 | 1,03 | 0,80 | 1,04 / 0,81 | 1,04 / 0,81 | 1,12 / 0,87 | 1,24 / 0,96 |

- **BIRB:** sus cinco mayores subidas a 15 min (+26 % a +40 %) caen todas entre
  el 23/10 15:28 y el 24/10 03:28 UTC: un solo episodio de bombeo. El precio pasó
  de 0,0587 a 0,1035 en la ventana. Quitando las 10 ventanas más extremas de
  2.874, deja de pasar en todos los modos.
- **ALIGN:** +20 %, +17 %, +11 % y −17 % entre el 05/11 17:09 y 17:54 UTC: un
  bombeo y desplome de 45 min. Quitando la ventana más extrema, deja de pasar.
- **WLD:** una sola aguja (+27 % y −22 % el 29/10 22:24-22:39) le sube el factor
  de 2,2 a 6,3.
- **Mediana del factor empírico** en los 51 activos: 2,97 (15 min) y 2,99 (5 min),
  un 12 % por encima del normal (2,665). Los factores de 6 a 11 son solo de
  activos con episodios aislados.
- **Liquidez:** BIRB y ALIGN pasan el 69 % y el 81 % de los minutos sin un solo
  trade, con spread mediano de 32 y 22 pb. El monto máximo de ALIGN es $66.

**Lectura:** con la regla escrita, la F1 pasa. Pero ese "pasa" equivale a "una
señal que hubiera cazado el bombeo de BIRB del 23-24/10 o el de ALIGN del 05/11".
Son uno o dos episodios en 30 días, y ninguna prueba estadística puede validar
eso en un piloto de semanas. En los otros 49 activos, incluidos todos los
líquidos, es NO-GO en intro y en advanced_1.
