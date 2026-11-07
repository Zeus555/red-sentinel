#!/usr/bin/env python3
"""F1 del estudio de volatilidad en Coinbase: analisis y decision de la puerta.

Lee la SQLite que deja f1_descarga.py y escribe en la misma carpeta:
  informe_f1.md          el informe para el dueno
  f1_combinaciones.csv   activo x horizonte x nivel x modo, todas las cifras
  f1_activos.csv         volatilidad, huecos y libro por activo
  f1_monto.csv           curva monto -> coste por activo
  f1_resumen.json        la decision de la puerta en formato maquina

LAS CIFRAS DE OPORTUNIDAD SON COTAS FAVORABLES A LA ESTRATEGIA, a proposito:
  - coste = solo comision (spread y slippage se miden aparte, en la curva de monto);
  - "MFE" = vender en el maximo de las velas siguientes, que ademas suele ser
    un trade al ask, no al bid al que venderias;
  - sigma sale de cierres de trades, que el rebote bid-ask infla en los libros
    anchos (GIGA, BEAM, PEPE...). A 15 min ese rebote ya casi no pesa.

LA PUERTA (preregistrada en parametros.json, no se toca despues de ver datos):
  rho_req = U / (sigma_h * factor)
es la correlacion que tendria que tener una senal con el retorno a h para que,
operando solo el q % de ventanas donde la senal es mas alta, el retorno medio
cubra el umbral U. Se calcula con DOS factores y decide el mas favorable:
  - normal: phi(z_q)/q = 2,665 con q = 1 %;
  - empirico: el mismo factor medido con los retornos reales del activo. La
    revision del 2026-11-06 midio que, con curtosis de 8-33, una senal de
    rho = 0,2 rinde un 15-75 % mas que en la normal: el factor normal solo era
    pesimista para la estrategia.
Si rho_decide > rho_umbral en TODAS las combinaciones de un modo, ese modo es
no-go en ese nivel de comision.

Uso:  python3 f1_analisis.py --datos ~/estudio-coinbase/f1 [--parametros parametros.json]
"""
import argparse
import csv
import heapq
import json
import math
import os
import random
import sqlite3
import zlib
from bisect import bisect_left
from collections import deque
from datetime import datetime, timezone
from statistics import NormalDist

import cb_comun as cb

AQUI = os.path.dirname(os.path.abspath(__file__))
ND = NormalDist()
TRAMO = 350          # velas por peticion: el mismo valor que f1_descarga.py


def factor_oraculo(q):
    """E[Z | Z > z_q] = phi(z_q) / q para una normal estandar."""
    return ND.pdf(ND.inv_cdf(1 - q)) / q


def factor_empirico(xs, q, rho, sem):
    """El factor de la puerta medido con las colas reales de `xs`.

    Senal simulada S = rho*Z + sqrt(1-rho^2)*N(0,1) sobre Z = xs estandarizados;
    factor = E[Z | S en el q superior] / rho. Se divide por el mismo calculo con
    Z normal y el mismo n, y se multiplica por el valor teorico: asi se quita el
    sesgo de muestra finita y solo queda el efecto de las colas."""
    n = len(xs)
    k = max(1, round(q * n))
    m, sd = cb.media(xs), cb.desviacion(xs)
    if not sd:
        return None
    z = [(x - m) / sd for x in xs]
    a = math.sqrt(1 - rho * rho)
    semillas = int(min(sem['max'], max(sem['min'], round(sem['objetivo'] / k))))

    def una(zz, rng):
        s = [rho * zi + a * rng.gauss(0.0, 1.0) for zi in zz]
        top = heapq.nlargest(k, range(n), key=s.__getitem__)
        return sum(zz[i] for i in top) / k / rho

    real = cb.media([una(z, random.Random(1000 + i)) for i in range(semillas)])
    ctrl = []
    for i in range(semillas):
        rng = random.Random(5000 + i)
        ctrl.append(una([rng.gauss(0.0, 1.0) for _ in range(n)], rng))
    return real / cb.media(ctrl) * factor_oraculo(q)


def umbral(f_compra, f_venta):
    """Subida minima del precio para no perder: (1+r)(1-f_v)/(1+f_c) >= 1."""
    return (1 + f_compra) / (1 - f_venta) - 1


def niveles_comision(par):
    """[(nombre, maker, taker)] de mas caro a mas barato, mas la variante Coinbase One."""
    out = [(n['nivel'], n['maker'], n['taker']) for n in par['comisiones']['niveles']]
    r = par['comisiones']['coinbase_one_reembolso']
    intro = out[0]
    out.append((intro[0] + '_coinbase_one', intro[1] * (1 - r), intro[2] * (1 - r)))
    return out


def fees_modo(modo, maker, taker):
    return [maker if pata == 'maker' else taker for pata in modo]


def max_ventana(hv, h):
    """mx[i] = max(hv[i+1 .. i+h]) con una cola monotona; -inf si no hay velas."""
    n = len(hv)
    mx = [float('-inf')] * n
    dq = deque()
    for e in range(n):
        while dq and hv[dq[-1]] <= hv[e]:
            dq.pop()
        dq.append(e)
        s = e - h + 1
        while dq[0] < s:
            dq.popleft()
        if s - 1 >= 0:
            mx[s - 1] = hv[dq[0]]
    return mx


def q_estrella(desc, pref, u):
    """Mayor fraccion q de ventanas cuyo retorno medio (las mejores primero) sigue >= u.

    Es el techo de un oraculo perfecto con posiciones solapadas (capital
    repartido): ni acertando siempre las mejores ventanas se puede operar mas a
    menudo que esto sin perder en media."""
    lo, hi = 0, len(desc)
    while lo < hi:
        k = (lo + hi + 1) // 2
        if pref[k] / k >= u:
            lo = k
        else:
            hi = k - 1
    return lo / len(desc) if desc else None


def campos_combinacion(p1):
    return (['product_id', 'h_min', 'nivel', 'modo', 'decide', 'U_bps', 'sigma_bps', 'p_fija', 'p_mfe',
             'e_neto_bps', 'veces_dia', 'q_oraculo_fija', 'q_oraculo_mfe', 'n_entradas', 'n_no_solapadas']
            + [f'rho_q{q:g}' for q in p1['q_oraculo']]
            + ['factor_empirico', 'rho_normal', 'rho_empirico', 'rho_decide', 'pasa'])


def serie(db, pid, ini, fin):
    n = (fin - ini) // 60
    c, hi, lo = [None] * n, [None] * n, [None] * n
    for t, h, l, cc in db.execute('SELECT t, h, l, c FROM vela WHERE product_id=? AND t>=? AND t<?', (pid, ini, fin)):
        i = (t - ini) // 60
        c[i], hi[i], lo[i] = cc, h, l
    i0 = next((i for i, x in enumerate(c) if x is not None), None)
    return c, hi, lo, i0


def analizar_activo(pid, c, hi, lo, i0, p1, niveles, modos):
    n = len(c)
    act = {'product_id': pid, 'sigma': {}}
    if i0 is None:
        act['dias_datos'] = 0
        return act, []
    # Un minuto sin trades no tiene vela: el precio sigue siendo el ultimo cierre.
    cff, ultimo = [None] * n, None
    for i in range(i0, n):
        ultimo = c[i] if c[i] is not None else ultimo
        cff[i] = ultimo
    span = n - i0
    act['dias_datos'] = span / 1440
    act['minutos_sin_trade'] = 1 - sum(1 for i in range(i0, n) if c[i] is not None) / span
    act['rv_1m_bps'] = cb.bps(cb.desviacion([math.log(cff[i] / cff[i - 1]) for i in range(i0 + 1, n)]))
    act['rv_5m_bps'] = cb.bps(cb.desviacion([math.log(cff[i] / cff[i - 5]) for i in range(i0 + 5, n, 5)]))
    # Ultimas 24 h: es el ranking "literal" comparable al sondeo del 2026-11-02.
    a24 = max(i0, n - 1440)
    act['rv_5m_24h_bps'] = cb.bps(cb.desviacion([math.log(cff[i] / cff[i - 5]) for i in range(a24 + 5, n, 5)]))
    act['cambio_24h_pct'] = (cff[n - 1] / cff[a24] - 1) * 100
    pk = [math.log(hi[i] / lo[i]) ** 2 for i in range(i0, n) if c[i] is not None and lo[i] > 0]
    act['parkinson_1m_bps'] = cb.bps(math.sqrt(cb.media(pk) / (4 * math.log(2)))) if pk else None

    hv = [x if x is not None else float('-inf') for x in hi]
    filas = []
    for h in p1['horizontes_min']:
        mx = max_ventana(hv, h)
        r, mfe = [], []
        for i in range(i0, n - h):
            if c[i] is None:          # solo se entra en un minuto con trade real
                continue
            ri = cff[i + h] / c[i] - 1
            r.append(ri)
            mfe.append(max(ri, mx[i] / c[i] - 1))
        no_solapados = [cff[i + h] / cff[i] - 1 for i in range(i0, n - h, h)]
        sig = cb.desviacion(no_solapados)
        if not r or not sig:
            continue
        act['sigma'][h] = sig
        f_emp = factor_empirico(no_solapados, p1['q_puerta'], p1['rho_umbral'], p1['semillas_factor_empirico'])
        f_norm = factor_oraculo(p1['q_puerta'])
        media_r = cb.media(r)
        r_asc, m_asc, ns_asc = sorted(r), sorted(mfe), sorted(no_solapados)
        r_desc, m_desc = r_asc[::-1], m_asc[::-1]
        pref_r, pref_m = [0.0], [0.0]
        for x in r_desc:
            pref_r.append(pref_r[-1] + x)
        for x in m_desc:
            pref_m.append(pref_m[-1] + x)
        for nivel, maker, taker in niveles:
            for modo, patas in modos.items():
                fc, fv = fees_modo(patas, maker, taker)
                u = umbral(fc, fv)
                fila = {
                    'product_id': pid, 'h_min': h, 'nivel': nivel, 'modo': modo,
                    'decide': 1 if modo in p1['modos_que_deciden'] else 0,
                    'U_bps': u * 1e4, 'sigma_bps': sig * 1e4,
                    'p_fija': (len(r_asc) - bisect_left(r_asc, u)) / len(r_asc),
                    'p_mfe': (len(m_asc) - bisect_left(m_asc, u)) / len(m_asc),
                    'e_neto_bps': ((1 + media_r) * (1 - fv) / (1 + fc) - 1) * 1e4,
                    'veces_dia': (len(ns_asc) - bisect_left(ns_asc, u)) / act['dias_datos'],
                    'q_oraculo_fija': q_estrella(r_desc, pref_r, u),
                    'q_oraculo_mfe': q_estrella(m_desc, pref_m, u),
                    'n_entradas': len(r), 'n_no_solapadas': len(no_solapados),
                }
                for q in p1['q_oraculo']:
                    fila[f'rho_q{q:g}'] = u / (sig * factor_oraculo(q))
                fila['factor_empirico'] = f_emp
                fila['rho_normal'] = u / (sig * f_norm)
                fila['rho_empirico'] = u / (sig * f_emp) if f_emp else None
                fila['rho_decide'] = min(x for x in (fila['rho_normal'], fila['rho_empirico']) if x is not None)
                fila['pasa'] = 1 if fila['rho_decide'] <= p1['rho_umbral'] else 0
                filas.append(fila)
    return act, filas


def analizar_libros(db, pid, p1, f_taker, banda):
    """Curva monto -> coste con las fotos del libro (mediana entre fotos)."""
    montos = p1['montos_usd']
    pres = p1['presupuesto_slip_bps'] / 1e4
    banda_op = p1['filtros_operable']['profundidad_banda_bps'] / 1e4
    tope_capital = p1['capital_usd'] / (1 + f_taker)
    fotos = []
    for (jz,) in db.execute('SELECT json_z FROM libro WHERE product_id=? ORDER BY ts', (pid,)):
        pb = json.loads(zlib.decompress(jz)).get('pricebook') or {}
        bids, asks = cb.niveles(pb.get('bids')), cb.niveles(pb.get('asks'))
        if not bids or not asks:
            continue
        bid, ask = bids[0][0], asks[0][0]
        mid = (bid + ask) / 2
        # El monto tiene que caber al ENTRAR (asks) y al SALIR (bids): un libro
        # asimetrico como el de ALIGN (~$670 en asks frente a ~$110 en bids a 25 pb)
        # no deja salir con lo que dejo entrar.
        limites = [tope_capital,
                   cb.profundidad_hasta(asks, ask * (1 + pres), True),
                   cb.profundidad_hasta(bids, bid * (1 - pres), False)]
        if banda:
            # La banda de proteccion corta la orden a mid*(1 +/- max_slippage).
            limites += [cb.profundidad_hasta(asks, mid * (1 + banda), True),
                        cb.profundidad_hasta(bids, mid * (1 - banda), False)]
        foto = {'spread_bps': (ask - bid) / mid * 1e4,
                'prof_banda_usd': min(cb.profundidad_hasta(asks, mid * (1 + banda_op), True),
                                      cb.profundidad_hasta(bids, mid * (1 - banda_op), False)),
                'prof_presupuesto_compra_usd': limites[1], 'prof_presupuesto_venta_usd': limites[2],
                'monto_max_usd': min(limites)}
        for N in montos:
            vc, vv = cb.vwap(asks, N), cb.vwap(bids, N)
            foto[f'slip_compra_{N}'] = (vc - mid) / mid if vc else None
            foto[f'slip_venta_{N}'] = (mid - vv) / mid if vv else None
        fotos.append(foto)
    if not fotos:
        return {'fotos': 0}
    res = {'fotos': len(fotos)}
    for k in fotos[0]:
        res[k] = cb.mediana([fo[k] for fo in fotos])
    res['spread_max_bps'] = max(fo['spread_bps'] for fo in fotos)
    for N in montos:
        sc, sv = res[f'slip_compra_{N}'], res[f'slip_venta_{N}']
        # Lo que tiene que subir el MID para no perder pagando comision taker y
        # el libro en las dos patas.
        res[f'U_tt_{N}_bps'] = (((1 + f_taker) * (1 + sc) / ((1 - f_taker) * (1 - sv)) - 1) * 1e4
                                if sc is not None and sv is not None else None)
    return res


def f(x, d=1):
    """Numero a la espanola: miles con espacio, decimales con coma."""
    if x is None:
        return '—'
    return f'{x:,.{d}f}'.replace(',', ' ').replace('.', ',')


def pc(x, d=2):
    return '—' if x is None else f(x * 100, d) + ' %'


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--datos', required=True)
    ap.add_argument('--parametros', default=os.path.join(AQUI, 'parametros.json'))
    a = ap.parse_args()
    par = cb.cargar_parametros(a.parametros)
    p1 = par['f1']
    datos = os.path.expanduser(a.datos)
    db = sqlite3.connect(os.path.join(datos, 'f1.sqlite'))

    ini, fin = json.loads(db.execute("SELECT valor FROM corrida WHERE clave='ventana'").fetchone()[0])
    embudo = json.loads(db.execute("SELECT valor FROM corrida WHERE clave='embudo'").fetchone()[0])
    fin_desc = db.execute("SELECT valor FROM corrida WHERE clave='descarga_fin'").fetchone()
    niveles = niveles_comision(par)
    nombres_niveles = [n[0] for n in niveles]
    cuenta = par['cuenta']
    nivel_eval = cuenta.get('nivel_real') or cuenta['nivel_supuesto']
    maker_eval, taker_eval = next((m, t) for n, m, t in niveles if n == nivel_eval)
    modos = p1['modos']

    # Un producto con tramos que faltan o dieron error tendria minutos rellenados
    # con el ultimo cierre: sigma desinflada y un no-go falso. Queda fuera.
    esperados = len(range(ini, fin, TRAMO * 60))
    ok_por = dict(db.execute("SELECT product_id, COUNT(*) FROM tramo WHERE estado='ok' GROUP BY product_id"))

    prods = {r[0]: r for r in db.execute(
        'SELECT product_id, vol24h_usd, max_slippage, en_universo, es_control, quote_min_size FROM producto '
        'WHERE en_universo=1 OR es_control=1')}
    activos, combos = [], []
    for pid in sorted(prods, key=lambda k: -(prods[k][1] or 0)):
        c, hi, lo, i0 = serie(db, pid, ini, fin)
        act, filas = analizar_activo(pid, c, hi, lo, i0, p1, niveles, modos)
        act['vol24h_usd'], act['es_control'], act['quote_min_size'] = prods[pid][1], prods[pid][4], prods[pid][5]
        act['libro'] = analizar_libros(db, pid, p1, taker_eval, prods[pid][2])
        act['completo'] = ok_por.get(pid, 0) >= esperados
        act['valido'] = act['completo'] and act.get('dias_datos', 0) >= p1['dias_minimos_por_activo']
        activos.append(act)
        if act['valido']:
            combos += filas
        print(f"{pid}: {act.get('dias_datos', 0):.1f} dias, rv5m {f(act.get('rv_5m_bps'))} pb"
              f"{'' if act['completo'] else ' INCOMPLETO'}", flush=True)
    incompletos = [x['product_id'] for x in activos if not x['completo']]

    # ---- La puerta, por nivel de comision y modo ----
    puerta = {}
    for nivel in nombres_niveles:
        puerta[nivel] = {}
        for modo in modos:
            fl = [x for x in combos if x['nivel'] == nivel and x['modo'] == modo]
            mejor = min(fl, key=lambda x: x['rho_decide']) if fl else None
            pasan = [x for x in fl if x['pasa']]
            puerta[nivel][modo] = {
                'combinaciones': len(fl), 'pasan': len(pasan),
                'mejor': None if not mejor else {k: mejor[k] for k in (
                    'product_id', 'h_min', 'rho_decide', 'rho_normal', 'rho_empirico', 'U_bps', 'sigma_bps')},
                'lista_pasan': sorted([(x['product_id'], x['h_min'], round(x['rho_decide'], 3)) for x in pasan],
                                      key=lambda t: t[2])}
    eval_ = puerta[nivel_eval]
    no_go = {m: eval_[m]['pasan'] == 0 for m in p1['modos_que_deciden']}

    # Nivel minimo con el que cada activo y horizonte pasaria la puerta (f*).
    necesario = {}
    for x in combos:
        if x['modo'] not in p1['modos_que_deciden'] or x['nivel'].endswith('_coinbase_one'):
            continue
        k = (x['product_id'], x['h_min'], x['modo'])
        if x['pasa'] and k not in necesario:     # niveles van de mas caro a mas barato
            necesario[k] = x['nivel']

    # ---- Rankings ----
    validos = [x for x in activos if x['valido']]
    lit24 = sorted([x for x in validos if x.get('rv_5m_24h_bps')], key=lambda x: -x['rv_5m_24h_bps'])[:10]
    lit30 = sorted([x for x in validos if x.get('rv_5m_bps')], key=lambda x: -x['rv_5m_bps'])[:10]
    fo = p1['filtros_operable']

    def operable(x):
        lb = x['libro']
        return (lb.get('fotos') and lb.get('spread_bps') is not None and lb['spread_bps'] <= fo['spread_mediano_max_bps']
                and x['minutos_sin_trade'] <= fo['minutos_sin_trade_max']
                and (lb.get('prof_banda_usd') or 0) >= fo['profundidad_min_usd'])
    for x in activos:
        u_full = x['libro'].get(f"U_tt_{p1['capital_usd']}_bps")
        s5 = x['sigma'].get(5)
        x['ratio_mov_coste_5m'] = (s5 * 1e4 / u_full) if (u_full and s5) else None
        x['operable'] = bool(x['valido'] and operable(x))
    oper = sorted([x for x in validos if x['operable'] and x['ratio_mov_coste_5m']],
                  key=lambda x: -x['ratio_mov_coste_5m'])[:10]

    # ---- Salidas ----
    with open(os.path.join(datos, 'f1_combinaciones.csv'), 'w', newline='', encoding='utf-8') as fh:
        w = csv.DictWriter(fh, fieldnames=campos_combinacion(p1))
        w.writeheader()
        w.writerows(combos)
    campos_act = ['product_id', 'es_control', 'completo', 'valido', 'operable', 'vol24h_usd', 'dias_datos',
                  'minutos_sin_trade', 'rv_1m_bps', 'rv_5m_bps', 'rv_5m_24h_bps', 'cambio_24h_pct',
                  'parkinson_1m_bps', 'ratio_mov_coste_5m']
    campos_lib = ['fotos', 'spread_bps', 'spread_max_bps', 'prof_banda_usd', 'prof_presupuesto_compra_usd',
                  'prof_presupuesto_venta_usd', 'monto_max_usd']
    with open(os.path.join(datos, 'f1_activos.csv'), 'w', newline='', encoding='utf-8') as fh:
        w = csv.writer(fh)
        w.writerow(campos_act + [f'sigma_{h}m_bps' for h in p1['horizontes_min']] + campos_lib)
        for x in activos:
            w.writerow([x.get(k) for k in campos_act]
                       + [cb.bps(x['sigma'].get(h)) for h in p1['horizontes_min']]
                       + [x['libro'].get(k) for k in campos_lib])
    with open(os.path.join(datos, 'f1_monto.csv'), 'w', newline='', encoding='utf-8') as fh:
        w = csv.writer(fh)
        w.writerow(['product_id', 'monto_usd', 'slip_compra_bps', 'slip_venta_bps', f'U_tt_{nivel_eval}_bps'])
        for x in activos:
            lb = x['libro']
            if not lb.get('fotos'):
                continue
            for N in p1['montos_usd']:
                w.writerow([x['product_id'], N, cb.bps(lb.get(f'slip_compra_{N}')),
                            cb.bps(lb.get(f'slip_venta_{N}')), lb.get(f'U_tt_{N}_bps')])
    resumen = {'generado': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
               'ventana_utc': [ini, fin], 'descarga_terminada': bool(fin_desc), 'incompletos': incompletos,
               'nivel_evaluado': nivel_eval, 'nivel_confirmado': bool(cuenta.get('nivel_real')),
               'no_go': no_go, 'puerta': puerta,
               'top10_literal_24h': [x['product_id'] for x in lit24],
               'top10_literal_30d': [x['product_id'] for x in lit30],
               'top10_operable': [x['product_id'] for x in oper],
               'nivel_necesario': {f'{k[0]}|{k[1]}|{k[2]}': v for k, v in necesario.items()}}
    with open(os.path.join(datos, 'f1_resumen.json'), 'w', encoding='utf-8') as fh:
        json.dump(resumen, fh, indent=1, ensure_ascii=False)

    escribir_informe(os.path.join(datos, 'informe_f1.md'), par, p1, ini, fin, embudo, fin_desc, activos,
                     combos, puerta, nivel_eval, no_go, necesario, lit24, lit30, oper, nombres_niveles, incompletos)
    print(json.dumps({'nivel_evaluado': nivel_eval, 'no_go': no_go, 'incompletos': len(incompletos),
                      'mejor': {m: eval_[m]['mejor'] for m in p1['modos_que_deciden']}}, ensure_ascii=False))


def escribir_informe(ruta, par, p1, ini, fin, embudo, fin_desc, activos, combos, puerta, nivel_eval, no_go,
                     necesario, lit24, lit30, oper, nombres_niveles, incompletos):
    d = lambda t: datetime.fromtimestamp(t, timezone.utc).strftime('%Y-%m-%d %H:%M')
    L = []
    w = L.append
    validos = [x for x in activos if x['valido']]
    decide = p1['modos_que_deciden']
    w('# F1 — Puerta barata: velas de 1 min\n')
    w(f'- Ventana: {d(ini)} → {d(fin)} UTC ({(fin - ini) / 86400:.0f} días).')
    w(f'- Universo: {len(activos)} activos (USD con ≥ ${par["universo"]["volumen_min_usd"] / 1e6:.0f}M/día el día '
      f'de la descarga, más controles); {len(validos)} completos y con ≥ {p1["dias_minimos_por_activo"]} días de '
      f'datos. Embudo de los productos SPOT: {embudo}.')
    nivel_txt = 'confirmado' if par['cuenta'].get('nivel_real') else 'SUPUESTO, sin confirmar por el dueño'
    w(f'- Nivel de comisión evaluado: **{nivel_eval}** ({nivel_txt}); región {par["cuenta"]["region"]}. '
      f'Parámetros v{par["version"]}.')
    if fin_desc:
        fd = json.loads(fin_desc[0])
        w(f'- Descarga terminada {fd["fin"]}: {f(fd["velas"], 0)} velas, {fd["tramos_error"]} tramos con error, '
          f'{f(fd["stats"]["peticiones"], 0)} peticiones, {fd["stats"]["http429"]} respuestas 429.')
    else:
        w('- **OJO: la descarga NO ha terminado.** Este informe es provisional.')
    if incompletos:
        w(f'- **OJO: {len(incompletos)} activos con tramos que faltan quedan fuera de la puerta:** '
          f'{", ".join(incompletos)}.')
    w('')
    w('## Decisión de la puerta\n')
    w(f'Regla preregistrada: un modo pasa en un nivel si alguna combinación activo × horizonte tiene '
      f'ρ_req ≤ {f(p1["rho_umbral"], 2)} con q = {pc(p1["q_puerta"], 0)}. ρ_req es la correlación que haría falta '
      f'entre una señal y el retorno para cubrir la comisión operando solo el {pc(p1["q_puerta"], 0)} de ventanas '
      f'más prometedoras. Se calcula con el factor normal y con el empírico (colas reales del activo) y decide el '
      f'más favorable a la estrategia.\n')
    for m in decide:
        e = puerta[nivel_eval][m]
        mj = e['mejor']
        if not mj:
            w(f'- {m}: sin datos')
            continue
        w(f'- **{m} en {nivel_eval}: {"NO-GO" if no_go[m] else "PASA"}**. Pasan {e["pasan"]} de {e["combinaciones"]} '
          f'combinaciones. Mejor caso: {mj["product_id"]} a {mj["h_min"]} min, ρ_req = {f(mj["rho_decide"], 2)} '
          f'(normal {f(mj["rho_normal"], 2)}, empírico {f(mj["rho_empirico"], 2)}; U = {f(mj["U_bps"], 0)} pb, '
          f'σ = {f(mj["sigma_bps"], 0)} pb).')
    w('\n| Nivel | ' + ' | '.join(f'{m} pasan | Mejor ρ_req {m}' for m in decide) + ' | MM pasan (informativo) |')
    w('|---|' + '---|---|' * len(decide) + '---|')
    for n in nombres_niveles:
        p = puerta[n]

        def mejor(m):
            mj = p[m]['mejor']
            return f'{f(mj["rho_decide"], 2)} ({mj["product_id"]}, {mj["h_min"]} min)' if mj else '—'
        celdas = ' | '.join(f'{p[m]["pasan"]}/{p[m]["combinaciones"]} | {mejor(m)}' for m in decide)
        w(f'| {n} | {celdas} | {p["MM"]["pasan"]}/{p["MM"]["combinaciones"]} |' if 'MM' in p else f'| {n} | {celdas} | — |')
    w('')

    def tabla_ranking(titulo, lista, clave):
        w(f'### {titulo}\n')
        w('| # | Activo | rv 5 min (pb) | Cambio 24 h | Sin trade | Spread mediano | Operable |')
        w('|---|---|---|---|---|---|---|')
        for i, x in enumerate(lista, 1):
            w(f'| {i} | {x["product_id"]} | {f(x.get(clave))} | {f(x.get("cambio_24h_pct"))} % | '
              f'{pc(x["minutos_sin_trade"], 1)} | {f(x["libro"].get("spread_bps"))} pb | '
              f'{"sí" if x.get("operable") else "no"} |')
        w('')
    w('## Top 10\n')
    tabla_ranking('Literal: volatilidad de las últimas 24 h', lit24, 'rv_5m_24h_bps')
    tabla_ranking('Literal: volatilidad de los 30 días', lit30, 'rv_5m_bps')
    w('### Operable: movimiento típico a 5 min ÷ coste real a $1000\n')
    fo = p1['filtros_operable']
    w(f'Filtros: spread mediano ≤ {fo["spread_mediano_max_bps"]} pb, ≤ {pc(fo["minutos_sin_trade_max"], 0)} de '
      f'minutos sin trade y ≥ ${fo["profundidad_min_usd"]} por lado a ±{fo["profundidad_banda_bps"]} pb. El coste '
      f'incluye comisión taker de {nivel_eval} y el libro en las dos patas.\n')
    w('| # | Activo | σ 5 min (pb) | Coste ida y vuelta $1000 (pb) | Movimiento ÷ coste |')
    w('|---|---|---|---|---|')
    for i, x in enumerate(oper, 1):
        w(f'| {i} | {x["product_id"]} | {f(cb.bps(x["sigma"].get(5)))} | '
          f'{f(x["libro"].get("U_tt_" + str(p1["capital_usd"]) + "_bps"))} | {f(x["ratio_mov_coste_5m"], 2)} |')
    w('')

    # Se detallan los rankings, los controles y TODO lo que la puerta nombra
    # (lo que pasa y los mejores casos), aunque no salga en ningun ranking.
    mostrar = {x['product_id'] for x in lit24 + lit30 + oper} | {x['product_id'] for x in validos if x['es_control']}
    for m in decide:
        e = puerta[nivel_eval][m]
        if e['mejor']:
            mostrar.add(e['mejor']['product_id'])
        mostrar |= {t[0] for t in e['lista_pasan']}
    w(f'## Detalle por activo en {nivel_eval}\n')
    w('P(fija) = fracción de minutos en que comprar y vender a h habría cubierto la comisión. '
      'P(MFE) = lo mismo vendiendo en el máximo de las velas siguientes (cota optimista). '
      'Oráculo = techo de minutos operables sin perder en media acertando siempre los mejores, con posiciones '
      'solapadas (capital repartido). ρ_req es el que decide (el menor entre normal y empírico).\n')
    w('| Activo | h | σ_h (pb) | U TT (pb) | P(fija) TT | P(MFE) TT | Oráculo TT | ρ_req TT | ρ_req MT | ρ_req TM | '
      'Nivel mínimo TT | Nivel mínimo MT/TM |')
    w('|---|---|---|---|---|---|---|---|---|---|---|---|')
    idx = {(x['product_id'], x['h_min'], x['nivel'], x['modo']): x for x in combos}
    for pid in sorted(mostrar):
        for h in p1['horizontes_min']:
            tt = idx.get((pid, h, nivel_eval, 'TT'))
            if not tt:
                continue
            mt, tm = idx.get((pid, h, nivel_eval, 'MT')), idx.get((pid, h, nivel_eval, 'TM'))
            mixto = necesario.get((pid, h, 'TM')) or necesario.get((pid, h, 'MT')) or 'ninguno'
            w(f'| {pid} | {h} min | {f(tt["sigma_bps"])} | {f(tt["U_bps"], 0)} | {pc(tt["p_fija"])} | '
              f'{pc(tt["p_mfe"])} | {pc(tt["q_oraculo_fija"])} | {f(tt["rho_decide"], 2)} | '
              f'{f(mt["rho_decide"], 2) if mt else "—"} | {f(tm["rho_decide"], 2) if tm else "—"} | '
              f'{necesario.get((pid, h, "TT"), "ninguno")} | {mixto} |')
    w('')

    w('## Curva de monto (fotos del libro, mediana)\n')
    w(f'Coste de ida y vuelta en pb con comisión taker de {nivel_eval} y el libro en las dos patas. '
      f'Monto máximo = el menor de: capital menos comisión, lo que llena el libro al comprar y al vender antes de '
      f'que el precio marginal se aleje {p1["presupuesto_slip_bps"]} pb del mejor precio, y la banda de protección '
      f'de precio del producto en los dos lados.\n')
    cab = ' | '.join(f'${N}' for N in p1['montos_usd'])
    w(f'| Activo | Fotos | Spread | {cab} | Monto máx. |')
    w('|' + '---|' * (4 + len(p1['montos_usd'])))
    for x in sorted([x for x in validos if x['product_id'] in mostrar], key=lambda x: x['product_id']):
        lb = x['libro']
        if not lb.get('fotos'):
            continue
        celdas = ' | '.join(f(lb.get(f'U_tt_{N}_bps'), 0) for N in p1['montos_usd'])
        w(f'| {x["product_id"]} | {lb["fotos"]} | {f(lb.get("spread_bps"))} | {celdas} | ${f(lb.get("monto_max_usd"), 0)} |')
    w('')
    w('## Sesgos y límites (declarados antes de mirar)\n')
    w('- Las cifras de oportunidad (P, MFE, oráculo) son cotas favorables: coste solo comisión, salida en el máximo '
      'de vela. La puerta usa el más favorable de dos factores (normal y colas reales). Un no-go es robusto en ese '
      'sentido; un "pasa" solo justifica la F2.')
    w('- El factor empírico supone una señal "con ruido de medida" sobre el retorno; si la relación fuera lineal con '
      'colas gruesas en el ruido, el factor normal sería el exacto. Por eso se toma el mejor de los dos.')
    w('- Supervivencia: el universo es el de HOY mirando 30 días atrás; los activos deslistados no están.')
    w('- Velas = trades, no bid/ask: con velas no se puede evaluar maker (MM); MM pasa siempre a la F2.')
    w('- Segundos (5-30 s): las velas de 1 min no los ven; se miden en la F2 con el WebSocket.')
    w('- El monto sale de pocas fotos de un solo día: la variación por hora y fin de semana es de la F2.')
    with open(ruta, 'w', encoding='utf-8') as fh:
        fh.write('\n'.join(L) + '\n')


if __name__ == '__main__':
    main()
