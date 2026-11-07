# Diagnostico (solo lectura) de los "pasa" de la F1: cuanto dependen de unos
# pocos movimientos extremos. Se ejecuta en sentinel014 con: python3 - < este_fichero
import json, math, sqlite3, sys
from datetime import datetime, timezone
sys.path.insert(0, '/home/sentinel/estudio-coinbase/codigo')
import cb_comun as cb
import f1_analisis as fa

par = cb.cargar_parametros('/home/sentinel/estudio-coinbase/codigo/parametros.json')
p1 = par['f1']
db = sqlite3.connect('file:/home/sentinel/estudio-coinbase/f1/f1.sqlite?mode=ro', uri=True)
ini, fin = json.loads(db.execute("SELECT valor FROM corrida WHERE clave='ventana'").fetchone()[0])
U_TT, U_MT = fa.umbral(0.009, 0.009), fa.umbral(0.005, 0.009)
q, rho = p1['q_puerta'], p1['rho_umbral']
sem = p1['semillas_factor_empirico']
d = lambda t: datetime.fromtimestamp(t, timezone.utc).strftime('%m-%d %H:%M')

def no_solapados(c, i0, h):
    n = len(c); cff, u = [None] * n, None
    for i in range(i0, n):
        u = c[i] if c[i] is not None else u; cff[i] = u
    idx = list(range(i0, n - h, h))
    return [cff[i + h] / cff[i] - 1 for i in idx], [ini + i * 60 for i in idx], cff

def curtosis(xs):
    m = cb.media(xs); s = cb.desviacion(xs)
    return sum(((x - m) / s) ** 4 for x in xs) / len(xs)

out = {}
for pid, h in [('BIRB-USD', 15), ('BIRB-USD', 5), ('ALIGN-USD', 15), ('ICNT-USD', 15), ('WLD-USD', 15), ('ZEC-USD', 15)]:
    c, hi, lo, i0 = fa.serie(db, pid, ini, fin)
    xs, ts, cff = no_solapados(c, i0, h)
    sig = cb.desviacion(xs)
    k = max(1, round(q * len(xs)))
    orden = sorted(range(len(xs)), key=lambda j: -xs[j])
    top = orden[:k]
    dias_top = sorted({datetime.fromtimestamp(ts[j], timezone.utc).strftime('%m-%d') for j in top})
    f_full = fa.factor_empirico(xs, q, rho, sem)
    # Quitar los m retornos de mayor |z| (en los dos sentidos) y recalcular.
    por_abs = sorted(range(len(xs)), key=lambda j: -abs(xs[j]))
    res = {'n': len(xs), 'sigma_bps': round(sig * 1e4, 1), 'curtosis': round(curtosis(xs), 1),
           'precio_ini': cff[i0], 'precio_fin': cff[-1], 'primera_vela': d(ini + i0 * 60),
           'top5_bps': [(round(xs[j] * 1e4), d(ts[j])) for j in orden[:5]],
           'peores5_bps': [(round(xs[j] * 1e4), d(ts[j])) for j in sorted(range(len(xs)), key=lambda j: xs[j])[:5]],
           'k_top1pct': k, 'dias_distintos_en_top1pct': len(dias_top), 'dias_top': dias_top,
           'factor_emp': round(f_full, 2), 'rho_TT_emp': round(U_TT / (sig * f_full), 3),
           'rho_MT_emp': round(U_MT / (sig * f_full), 3), 'rho_TT_normal': round(U_TT / (sig * fa.factor_oraculo(q)), 3)}
    for m in (1, 3, 10, k):
        quitar = set(por_abs[:m])
        ys = [x for j, x in enumerate(xs) if j not in quitar]
        s2 = cb.desviacion(ys); f2 = fa.factor_empirico(ys, q, rho, sem)
        res[f'sin_{m}_mayores'] = {'sigma_bps': round(s2 * 1e4, 1), 'factor_emp': round(f2, 2),
                                   'rho_TT': round(U_TT / (s2 * f2), 3), 'rho_MT': round(U_MT / (s2 * f2), 3)}
    # Cuantos minutos con trade hay en los 15 min que siguen a cada entrada top
    res['minutos_con_trade_tras_top5'] = [sum(1 for t in range((ts[j] - ini) // 60 + 1, (ts[j] - ini) // 60 + 1 + h)
                                              if t < len(c) and c[t] is not None) for j in orden[:5]]
    out[f'{pid}|{h}'] = res
    print(pid, h, json.dumps(res, ensure_ascii=False), flush=True)

# Distribucion del factor empirico a 15 min en los 51 activos (del CSV ya calculado)
import csv
fs = {}
for r in csv.DictReader(open('/home/sentinel/estudio-coinbase/f1/f1_combinaciones.csv')):
    if r['nivel'] == 'intro' and r['modo'] == 'TT' and r['h_min'] in ('5', '15'):
        fs[(r['product_id'], r['h_min'])] = float(r['factor_empirico'])
for h in ('5', '15'):
    v = sorted(((f, p) for (p, hh), f in fs.items() if hh == h), reverse=True)
    print('factor_emp h=%s: mediana %.2f, top: %s' % (h, v[len(v) // 2][0], [(p, round(f, 2)) for f, p in v[:6]]))
