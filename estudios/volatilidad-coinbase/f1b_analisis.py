#!/usr/bin/env python3
"""F1b del estudio de volatilidad en Coinbase: segundos y toma de ganancia.

Responde a lo que el dueno pidio despues de la F1: su ventana real es <= 1 min
(normalmente ~20 s), a veces se alargo hasta 5 h, y "el suceso es mas probable
en menos tiempo". Con los trades de f1b_descarga.py se arma una rejilla de 1 s:

  last  ultimo trade del segundo
  ask   ultimo precio pagado por un taker COMPRADOR (side=sell en Exchange)
  bid   ultimo precio cobrado por un taker VENDEDOR (side=buy)
  (si el lado tiene mas de lado_fresco_max_s: ultimo trade +/- medio spread)

y se mide, todo con los parametros congelados en parametros.json -> f1b:

  A. puerta_segundos: la misma puerta rho de la F1 a 5-60 s, mas robustez.
  B. toma_ganancia: comprar al ask, dejar una venta en el objetivo y esperar
     hasta un plazo (5 s ... 5 h, o sin plazo); si no se llena, vender al bid.
     Decide una simulacion secuencial con $1000 en cada mitad de la ventana.
  C. tiempo hasta el objetivo: fraccion que llega antes de cada corte y la
     densidad por segundo en cada tramo (la prueba de "mas probable en menos
     tiempo").
  D. exploratorio: entrar solo despues de una subida rapida (no decide).

B tambien se corre sobre las velas de 1 min de la F1 (--solo-velas) como
adelanto y control cruzado: entrada al cierre, llenado con el maximo de la vela.

Uso:  python3 f1b_analisis.py --datos ~/estudio-coinbase/f1b --f1 ~/estudio-coinbase/f1/f1.sqlite
      python3 f1b_analisis.py ... --solo-velas          (solo B con velas, sin trades)
      python3 f1b_analisis.py ... --solo ZEC-USD,BIRB-USD
"""
import argparse
import csv
import hashlib
import json
import math
import os
import sqlite3
import sys
import time
import zlib
from array import array
from bisect import bisect_left, bisect_right
from datetime import datetime, timezone

import cb_comun as cb
import f1_analisis as fa
import f1b_descarga as fd
from f1b_descarga import pagina_valida

AQUI = os.path.dirname(os.path.abspath(__file__))
NAN = float('nan')
NO = -1          # "nunca llega" en los arrays de tiempos


# ---------------------------------------------------------------- rejillas

class Rejilla:
    """Una serie a paso fijo (1 s con trades, 60 s con velas).

    entrada[i]  precio al que se COMPRA como taker en el paso i (NaN si no se entra)
    salida[i]   precio al que se VENDE como taker en el paso i (siempre definido
                desde el primer paso con datos)
    llena_tm[i] mayor precio pagado por un taker comprador en el paso i: si es >= la
                venta limite, esta se habria llenado (cota favorable: sin cola)
    llena_tt[i] mayor precio cobrado por un taker vendedor en el paso i: si es >=
                objetivo, vender a mercado ahi cobra el objetivo
    precio[i]   ultimo trade, arrastrado (para sigma y la puerta rho)
    activo[i]   hubo al menos un trade en el paso i
    """

    def __init__(self, n, paso):
        self.n, self.paso = n, paso
        self.entrada = array('d', [NAN]) * n
        self.salida = array('d', [NAN]) * n
        self.llena_tm = array('d', [NAN]) * n
        self.llena_tt = array('d', [NAN]) * n
        self.precio = array('d', [NAN]) * n
        self.activo = bytearray(n)

    def preparar(self):
        """i0 = primer paso con datos; sig_activo[i] = primer paso activo >= i (n si no hay)."""
        self.i0 = next((i for i in range(self.n) if self.activo[i]), None)
        sig = array('i', [self.n]) * (self.n + 1)
        nxt = self.n
        for i in range(self.n - 1, -1, -1):
            if self.activo[i]:
                nxt = i
            sig[i] = nxt
        self.sig_activo = sig
        return self


def rejilla_trades(db, pid, ini, fin, medio_spread, fresco_s, paso_ids, nocional_vol):
    n = fin - ini
    i0_id, i1_id = db.execute('SELECT id_ini, id_fin FROM producto WHERE product_id=?', (pid,)).fetchone()
    pasos = set(range(i1_id, i0_id, -paso_ids))
    g = Rejilla(n, 1)
    last_id = array('q', [-1]) * n
    tb_id = array('q', [-1]) * n
    ts_id = array('q', [-1]) * n
    tb_last = array('d', [NAN]) * n
    ts_last = array('d', [NAN]) * n
    g.llena_vol = array('d', [NAN]) * n
    g.ask = array('d', [NAN]) * n
    # Comprobacion de lados por BARRIDOS: trades seguidos (ids consecutivos) del
    # mismo lado en el mismo milisegundo son una orden que barre el libro; si
    # side=sell es de verdad un taker comprador, en esos barridos el precio sube.
    barrido = {'compra_sube': 0, 'compra_baja': 0, 'venta_baja': 0, 'venta_sube': 0}
    ntr = fuera_orden = 0
    ini_ms, fin_ms = ini * 1000, fin * 1000
    cur, buf, prev = -1, [], None

    def cerrar(i, buf):
        """llena_vol[i] = el precio mas alto al que, en el segundo i, los takers
        compradores pagaron en conjunto >= nocional_vol (se recorren de mayor a menor
        precio). Una venta limite de ~$1000 a ese precio o por debajo se habria
        llenado entera en ese segundo, sin contar cola delante."""
        buf.sort(reverse=True)
        acc = 0.0
        for p, q in buf:
            acc += p * q
            if acc >= nocional_vol:
                g.llena_vol[i] = p
                return

    # Las paginas en orden de ids crecientes (cada una solo con su tramo
    # [after-paso, after): con huecos en los ids las paginas se solapan).
    for after, z in db.execute('SELECT after_id, datos_z FROM pagina WHERE product_id=? ORDER BY after_id', (pid,)):
        if after not in pasos:
            continue
        piso = max(after - paso_ids, i0_id)
        filas = json.loads(zlib.decompress(z))
        filas.reverse()
        for tid, t, p, s, tb in filas:
            if tid < piso or tid >= after:
                continue
            if prev is not None and tid == prev[0] + 1 and t == prev[1] and tb == prev[2] and p != prev[3]:
                barrido[('compra_sube' if p > prev[3] else 'compra_baja') if tb else
                        ('venta_baja' if p < prev[3] else 'venta_sube')] += 1
            prev = (tid, t, tb, p)
            if t < ini_ms or t >= fin_ms or not p > 0:
                continue
            i = t // 1000 - ini
            ntr += 1
            if tid > last_id[i]:
                last_id[i] = tid
                g.precio[i] = p
            if tb:
                if not g.llena_tm[i] >= p:
                    g.llena_tm[i] = p
                if tid > tb_id[i]:
                    tb_id[i], tb_last[i] = tid, p
                if i > cur:
                    if buf:
                        cerrar(cur, buf)
                    cur, buf = i, []
                if i == cur:
                    buf.append((p, s))
                else:
                    fuera_orden += 1
            else:
                if not g.llena_tt[i] >= p:
                    g.llena_tt[i] = p
                if tid > ts_id[i]:
                    ts_id[i], ts_last[i] = tid, p
    if buf:
        cerrar(cur, buf)

    # ask/bid coherentes (revision del 2026-11-06, parametros v3.1): cada lado se
    # observa cuando opera un taker de ese lado; el lado que NO opero se mueve en
    # la misma proporcion que el que si (conserva el ultimo spread visto) y, si su
    # ultima observacion real tiene mas de fresco_s, se reancla al lado fresco con
    # el spread mediano completo. Nunca quedan cruzados. Si nadie opero en fresco_s,
    # ultimo trade +/- medio spread, como antes.
    s2 = 2 * medio_spread
    ult = A = B = NAN
    ta = tb_ = -10 ** 9
    for i in range(n):
        if last_id[i] >= 0:
            g.activo[i] = 1
            ult = g.precio[i]
        else:
            g.precio[i] = ult
        oa, ob = tb_id[i] >= 0, ts_id[i] >= 0
        if oa and ob:
            a_, b_ = tb_last[i], ts_last[i]
            if a_ < b_:                    # el precio se movio dentro del segundo
                if tb_id[i] > ts_id[i]:
                    b_ = a_ * (1 - s2)
                else:
                    a_ = b_ * (1 + s2)
            A, B, ta, tb_ = a_, b_, i, i
        elif oa:
            a_ = tb_last[i]
            if A == A and B == B:
                B = B * a_ / A
            A, ta = a_, i
        elif ob:
            b_ = ts_last[i]
            if A == A and B == B:
                A = A * b_ / B
            B, tb_ = b_, i
        if ult != ult:
            continue
        if i - max(ta, tb_) > fresco_s:
            ask, bid = ult * (1 + medio_spread), ult * (1 - medio_spread)
        else:
            ask, bid = A, B
            if ta < tb_ and (ask != ask or i - ta > fresco_s):
                ask = bid * (1 + s2)
            elif tb_ < ta and (bid != bid or i - tb_ > fresco_s):
                bid = ask * (1 - s2)
            if ask < bid:
                if ta >= tb_:
                    bid = ask * (1 - s2)
                else:
                    ask = bid * (1 + s2)
        g.ask[i] = ask
        g.salida[i] = bid
        if g.activo[i]:
            g.entrada[i] = ask
    g.trades, g.lados, g.fuera_orden = ntr, barrido, fuera_orden
    return g.preparar()


def rejilla_velas(f1db, pid, ini, fin):
    """Rejilla de 1 min con las velas de la F1: cota favorable (sin spread)."""
    c, hi, lo, i0 = fa.serie(f1db, pid, ini, fin)
    n = len(c)
    g = Rejilla(n, 60)
    ult = NAN
    for i in range(n):
        if c[i] is not None:
            g.activo[i] = 1
            ult = c[i]
            g.entrada[i] = c[i]
            g.llena_tm[i] = g.llena_tt[i] = hi[i]
        g.precio[i] = ult
        g.salida[i] = ult
    g.trades, g.lados = sum(g.activo), (0, 0)
    return g.preparar()


def medio_spread_f1(f1db, pid):
    """Medio spread mediano (fraccion) de las fotos del libro de la F1."""
    sp = []
    for (jz,) in f1db.execute('SELECT json_z FROM libro WHERE product_id=?', (pid,)):
        pb = json.loads(zlib.decompress(jz)).get('pricebook') or {}
        b, a = cb.niveles(pb.get('bids')), cb.niveles(pb.get('asks'))
        if b and a:
            mid = (a[0][0] + b[0][0]) / 2
            sp.append((a[0][0] - b[0][0]) / mid)
    m = cb.mediana(sp)
    return (m / 2) if m is not None else None


def completo_trades(db, pid, paso_ids):
    """Estan todas las paginas de la rejilla de ids id_fin, id_fin-paso, ... > id_ini,
    y cada una llega al piso de su tramo (si no, faltarian trades en medio)."""
    r = db.execute('SELECT id_ini, id_fin, estado FROM producto WHERE product_id=?', (pid,)).fetchone()
    if not r or r[2] != 'hecho' or r[0] is None:
        return False
    i0, i1 = r[0], r[1]
    tiene = dict((a, (n, m, x)) for a, n, m, x in db.execute(
        'SELECT after_id, n, id_min, id_max FROM pagina WHERE product_id=?', (pid,)))
    for a in range(i1, i0, -paso_ids):
        # Misma validacion que la descarga: ids < a y el tramo [a-paso, a) cubierto.
        if a not in tiene or not pagina_valida(*tiene[a], a, paso_ids, i0):
            return False
    return True


# ---------------------------------------------------------------- B: tiempos hasta el objetivo

def primer_llenado(g, llena, ratio):
    """tau[i] = primer paso j > i con llena[j] >= entrada[i]*ratio, o NO.

    Pasada hacia atras con una escalera de maximos: en cada i la pila guarda los
    maximos estrictos de llena[i+1..] (el mas cercano arriba). El primer j que
    cumple es siempre uno de esos maximos, y se encuentra con biseccion."""
    n = g.n
    tau = array('i', [NO]) * n
    neg, pos = [], []
    entrada, activo = g.entrada, g.activo
    for i in range(n - 1, -1, -1):
        if activo[i]:
            e = entrada[i]
            if e == e and neg:
                k = bisect_right(neg, -e * ratio)
                if k:
                    tau[i] = pos[k - 1]
        f = llena[i]
        if f == f:
            nf = -f
            while neg and neg[-1] >= nf:
                neg.pop()
                pos.pop()
            neg.append(nf)
            pos.append(i)
    return tau


def secuencial(g, tau, a, b, plazo, margen, mult_salida):
    """$1000, una posicion a la vez en los pasos [a, b), reinvirtiendo todo.

    Devuelve dict con capital final, operaciones, aciertos, peor operacion,
    atascadas (cerradas por fin de tramo sin plazo vencido) y pasos en mercado."""
    log_k, n_op, aciertos, peor, atasc, en_merc, suma = 0.0, 0, 0, 0.0, 0, 0, 0.0
    lg = math.log1p(margen)
    sig, entrada, salida = g.sig_activo, g.entrada, g.salida
    i = sig[a] if a < g.n else g.n
    while i < b - 1:
        e = entrada[i]
        lim = b - 1 if plazo is None else min(i + plazo, b - 1)
        t = tau[i]
        if t != NO and t <= lim:
            log_k += lg
            suma += margen
            aciertos += 1
            fuera = t
        else:
            fuera = lim
            r = salida[fuera] / e * mult_salida
            log_k += math.log(r) if r > 0 else -50.0
            suma += r - 1
            if r - 1 < peor:
                peor = r - 1
            if plazo is None or fuera < i + plazo:
                atasc += 1
        n_op += 1
        en_merc += fuera - i
        i = sig[fuera + 1] if fuera + 1 < b else b
    # El capital en dolares se recorta en ~1e-301 (ruina total) para que quepa en un
    # double; log10_capital guarda el valor exacto (revision del 2026-11-06).
    return {'capital': 1000 * math.exp(max(-700.0, min(700.0, log_k))),
            'log10_capital': 3 + log_k / math.log(10), 'operaciones': n_op, 'aciertos': aciertos,
            'peor': peor, 'atascadas': atasc, 'media_neta': (suma / n_op) if n_op else None,
            'frac_en_mercado': en_merc / max(1, b - a)}


def comprar_y_mantener(g, a, b, f_taker):
    i = g.sig_activo[a]
    if i >= b - 1:
        return None
    return 1000 * g.salida[b - 1] / g.entrada[i] * (1 - f_taker) / (1 + f_taker)


def entradas_solapadas(g, cada, reserva):
    """Pasos activos, uno cada `cada` pasos, dejando `reserva` pasos al final para
    que todos los cortes de tiempo se puedan observar sin censura."""
    out, ultimo = [], -1
    if g.i0 is None:
        return out
    for s in range(g.i0, g.n - reserva, cada):
        i = g.sig_activo[s]
        if i < g.n - reserva and i != ultimo:
            out.append(i)
            ultimo = i
    return out


# ---------------------------------------------------------------- A: puerta rho en segundos

def no_solapados(precio, i0, h, a=None, b=None):
    a = i0 if a is None else max(i0, a)
    b = len(precio) if b is None else b
    return [precio[i + h] / precio[i] - 1 for i in range(a, b - h, h)]


def puerta_rho(xs, p1, sem):
    sig = cb.desviacion(xs)
    if not sig:
        return None, None
    return sig, fa.factor_empirico(xs, p1['q_puerta'], p1['rho_umbral'], sem)


# ---------------------------------------------------------------- un activo

def analizar(pid, g, par, niveles, nivel_eval, pasos_plazo, cortes_pasos, con_puerta_a, log):
    p1, pb = par['f1'], par['f1b']
    tg = pb['toma_ganancia']
    fees = {n: (m, t) for n, m, t in niveles}
    res = {'product_id': pid, 'paso_s': g.paso, 'trades': g.trades, 'lados': json.dumps(g.lados),
           'fuera_orden': getattr(g, 'fuera_orden', 0)}
    if g.i0 is None:
        res['dias_datos'] = 0
        return res, [], [], [], []
    n = g.n
    res['dias_datos'] = (n - g.i0) * g.paso / 86400
    res['frac_pasos_con_trade'] = sum(g.activo[g.i0:]) / (n - g.i0)
    mitad = n // 2
    tramos = [(g.i0, mitad), (mitad, n)]

    # ---- A: puerta rho a horizontes fijos ----
    filas_a = []
    if con_puerta_a:
        sem = p1['semillas_factor_empirico']
        f_norm = fa.factor_oraculo(p1['q_puerta'])
        pf = list(g.precio)
        for h in pb['puerta_segundos']['horizontes_s']:
            xs = no_solapados(pf, g.i0, h)
            if len(xs) < 100:
                continue
            sig, f_emp = puerta_rho(xs, p1, sem)
            if not sig:
                continue
            rob = None
            xs_sorted = sorted(xs)
            for nivel, maker, taker in niveles:
                for modo, patas in p1['modos'].items():
                    fc, fv = fa.fees_modo(patas, maker, taker)
                    u = fa.umbral(fc, fv)
                    rn, re_ = u / (sig * f_norm), (u / (sig * f_emp) if f_emp else None)
                    rd = min(x for x in (rn, re_) if x is not None)
                    fila = {'product_id': pid, 'h_s': h, 'nivel': nivel, 'modo': modo,
                            'decide': 1 if modo in p1['modos_que_deciden'] else 0, 'U_bps': u * 1e4,
                            'sigma_bps': sig * 1e4, 'factor_empirico': f_emp, 'rho_normal': rn,
                            'rho_empirico': re_, 'rho_decide': rd, 'pasa': 1 if rd <= p1['rho_umbral'] else 0,
                            'veces_dia': (len(xs_sorted) - bisect_left(xs_sorted, u)) / res['dias_datos'],
                            'n_no_solapadas': len(xs)}
                    if fila['pasa'] and fila['decide'] and nivel in tg['niveles']:
                        if rob is None:
                            rob = robustez(xs, pf, g, h, tramos, p1, sem, pb['puerta_segundos']['quitar_extremos'])
                        fila.update(rob_detalle(rob, u, f_norm, p1['rho_umbral']))
                    filas_a.append(fila)
            log(f'  {pid} A h={h}s sigma {sig * 1e4:.1f} pb factor {f_emp:.2f}')

    # ---- B y C: toma de ganancia ----
    filas_b, filas_c, filas_d = [], [], []
    reserva = cortes_pasos[-1]
    entradas = entradas_solapadas(g, max(1, tg['entradas_solapadas_cada_s'] // g.paso), reserva)
    combos = [(nv, 'TM', m) for nv in tg['niveles'] for m in tg['margen_neto_bps']]
    combos += [(nivel_eval, 'TT', m) for m in tg['margen_neto_bps']]
    taus_impulso = {}
    imp = par['f1b']['exploratorio_impulso']
    con_vol = hasattr(g, 'llena_vol')
    for nivel, modo, mb in combos:
        maker, taker = fees[nivel]
        f_venta = maker if modo == 'TM' else taker
        margen = mb / 1e4
        ratio = (1 + margen) * (1 + taker) / (1 - f_venta)
        mult_salida = (1 - taker) / (1 + taker)
        tau = primer_llenado(g, g.llena_tm if modo == 'TM' else g.llena_tt, ratio)
        # Variante informativa (revision del 2026-11-06): la venta limite solo cuenta
        # como llenada si en un mismo segundo los takers compradores pagan >= objetivo
        # por al menos nocional_vol en total. No decide: la regla preregistrada es la
        # de cualquier tamano.
        tau_v = (primer_llenado(g, g.llena_vol, ratio)
                 if con_vol and nivel == nivel_eval and modo == 'TM' else None)
        if nivel == nivel_eval and modo == 'TM' and mb in imp['margen_neto_bps'] and g.paso == 1:
            taus_impulso[mb] = tau
        # C: tiempos hasta el objetivo, entradas solapadas
        fila_c = {'product_id': pid, 'paso_s': g.paso, 'nivel': nivel, 'modo': modo, 'margen_bps': mb,
                  'objetivo_bps': (ratio - 1) * 1e4, 'entradas': len(entradas)}
        for suf, tt in (('', tau), ('_vol', tau_v)):
            if tt is not None and entradas:
                fila_c.update(tiempos(tt, entradas, cortes_pasos, g.paso, n, suf))
        if entradas:
            filas_c.append(fila_c)
        # B: simulacion secuencial por plazo, en la ventana entera y en cada mitad
        for plazo_s, plazo in pasos_plazo:
            fila = {'product_id': pid, 'paso_s': g.paso, 'nivel': nivel, 'modo': modo, 'margen_bps': mb,
                    'objetivo_bps': (ratio - 1) * 1e4, 'plazo_s': plazo_s}
            for suf, tt in (('', tau), ('_vol', tau_v)):
                if tt is None:
                    continue
                fila.update(evaluar_b(g, tt, plazo, margen, mult_salida, taker, tramos,
                                      tg['min_operaciones_por_mitad'], entradas if nivel == nivel_eval else None, suf))
            filas_b.append(fila)
    # D: exploratorio, entrar tras una subida rapida (solo trades). Revision del
    # 2026-11-06: el disparo mira el ASK (el lado al que se compra) y exige una
    # compra taker en el mismo segundo, para que la entrada sea un ask fresco; y
    # solo cuenta el PRIMER disparo de cada episodio (disparos separados por mas de
    # ventana_s), para no promediar muchas veces la misma subida.
    if taus_impulso:
        w = imp['ventana_s']
        maker, taker = fees[nivel_eval]
        mult_salida = (1 - taker) / (1 + taker)
        ask, llena = g.ask, g.llena_tm
        for sub in imp['subida_bps']:
            umbral_r = 1 + sub / 1e4
            disparos = [i for i in range(g.i0 + w, n - max(imp['plazos_s']) - 1)
                        if g.activo[i] and llena[i] == llena[i] and ask[i - w] == ask[i - w]
                        and ask[i] >= ask[i - w] * umbral_r]
            primeros = [i for k, i in enumerate(disparos) if k == 0 or i - disparos[k - 1] > w]
            for mb, tau in taus_impulso.items():
                margen = mb / 1e4
                for plazo in imp['plazos_s']:
                    suma = ac = 0
                    for i in primeros:
                        t = tau[i]
                        if t != NO and t <= i + plazo:
                            suma += margen
                            ac += 1
                        else:
                            suma += g.salida[i + plazo] / g.entrada[i] * mult_salida - 1
                    filas_d.append({'product_id': pid, 'subida_bps': sub, 'ventana_s': w, 'margen_bps': mb,
                                    'plazo_s': plazo, 'disparos': len(disparos), 'episodios': len(primeros),
                                    'episodios_dia': len(primeros) / res['dias_datos'],
                                    'acierto': (ac / len(primeros)) if primeros else None,
                                    'media_neta': (suma / len(primeros)) if primeros else None})
    return res, filas_a, filas_b, filas_c, filas_d


def tiempos(tau, entradas, cortes_pasos, paso, n, suf):
    """C: fraccion de entradas que llegan al objetivo antes de cada corte y densidad
    por segundo en cada tramo entre cortes."""
    d = sorted((tau[i] - i) if tau[i] != NO else 10 ** 12 for i in entradas)
    ne = len(d)
    out, prev_c, prev_p = {}, 0, 0.0
    for c in cortes_pasos:
        p = bisect_right(d, c) / ne
        seg = c * paso
        out[f'p_{seg}s{suf}'] = p
        out[f'densidad_{seg}s{suf}'] = (p - prev_p) / ((c - prev_c) * paso)
        prev_c, prev_p = c, p
    out[f'p_nunca{suf}'] = 1 - bisect_right(d, n) / ne
    return out


def evaluar_b(g, tau, plazo, margen, mult_salida, taker, tramos, min_ops, entradas, suf):
    """B para un plazo: simulacion secuencial en la ventana entera y en cada mitad,
    la regla de pase y, si se pasan `entradas`, el resultado medio solapado."""
    n = g.n
    out = {}
    tot = secuencial(g, tau, g.i0, n, plazo, margen, mult_salida)
    out.update({f'{k}{suf}': v for k, v in tot.items()})
    out[f'comprar_mantener{suf}'] = comprar_y_mantener(g, g.i0, n, taker)
    pasa = True
    for j, (a, b) in enumerate(tramos, 1):
        s = secuencial(g, tau, a, b, plazo, margen, mult_salida)
        bh = comprar_y_mantener(g, a, b, taker)
        out[f'capital_m{j}{suf}'], out[f'operaciones_m{j}{suf}'], out[f'cym_m{j}{suf}'] = \
            s['capital'], s['operaciones'], bh
        if not (s['capital'] > 1000 and bh is not None and s['capital'] > bh and s['operaciones'] >= min_ops):
            pasa = False
    out[f'pasa{suf}'] = 1 if pasa else 0
    if entradas:
        suma, ac = 0.0, 0
        lim_n = n - 1
        salida, entrada = g.salida, g.entrada
        for i in entradas:
            t = tau[i]
            lim = lim_n if plazo is None else min(i + plazo, lim_n)
            if t != NO and t <= lim:
                suma += margen
                ac += 1
            else:
                suma += salida[lim] / entrada[i] * mult_salida - 1
        out[f'media_solapada{suf}'] = suma / len(entradas)
        out[f'acierto_solapado{suf}'] = ac / len(entradas)
    return out


def robustez(xs, pf, g, h, tramos, p1, sem, quitar):
    """sigma y factor quitando las `quitar` ventanas de mayor |retorno|, y en cada mitad."""
    orden = sorted(range(len(xs)), key=lambda j: -abs(xs[j]))
    fuera = set(orden[:quitar])
    ys = [x for j, x in enumerate(xs) if j not in fuera]
    out = {'sin_extremos': puerta_rho(ys, p1, sem)}
    for k, (a, b) in enumerate(tramos, 1):
        out[f'm{k}'] = puerta_rho(no_solapados(pf, g.i0, h, a, b), p1, sem)
    return out


def rob_detalle(rob, u, f_norm, umbral):
    d, ok = {}, True
    for k, (sig, fe) in rob.items():
        if not sig:
            d[f'rho_{k}'] = None
            ok = False
            continue
        r = min(u / (sig * f_norm), u / (sig * fe) if fe else float('inf'))
        d[f'rho_{k}'] = r
        ok = ok and r <= umbral
    d['robusto'] = 1 if ok else 0
    return d


# ---------------------------------------------------------------- informe

def escribir_csv(ruta, filas):
    if not filas:
        return
    campos = []
    for x in filas:
        for k in x:
            if k not in campos:
                campos.append(k)
    with open(ruta, 'w', newline='', encoding='utf-8') as fh:
        w = csv.DictWriter(fh, fieldnames=campos)
        w.writeheader()
        w.writerows(filas)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--datos', required=True, help='carpeta de f1b (f1b.sqlite); ahi se escriben los resultados')
    ap.add_argument('--f1', required=True, help='f1.sqlite de la F1 (solo lectura)')
    ap.add_argument('--parametros', default=os.path.join(AQUI, 'parametros.json'))
    ap.add_argument('--solo-velas', action='store_true', help='solo la toma de ganancia con las velas de la F1')
    ap.add_argument('--solo', help='lista de product_id separada por comas (pruebas)')
    ap.add_argument('--esperar', action='store_true',
                    help='ir analizando cada activo cuando su descarga termine, hasta que termine toda')
    a = ap.parse_args()
    t0 = time.monotonic()
    par = cb.cargar_parametros(a.parametros)
    pb, tg = par['f1b'], par['f1b']['toma_ganancia']
    datos = os.path.expanduser(a.datos)
    os.makedirs(datos, exist_ok=True)
    f1db = sqlite3.connect(f'file:{os.path.expanduser(a.f1)}?mode=ro', uri=True)
    ini, fin = json.loads(f1db.execute("SELECT valor FROM corrida WHERE clave='ventana'").fetchone()[0])
    universo = [r[0] for r in f1db.execute(
        'SELECT product_id FROM producto WHERE en_universo=1 OR es_control=1 ORDER BY vol24h_usd DESC')]
    ids = [x.strip() for x in a.solo.split(',') if x.strip()] if a.solo else universo
    niveles = fa.niveles_comision(par)
    cuenta = par['cuenta']
    nivel_eval = cuenta.get('nivel_real') or cuenta['nivel_supuesto']

    def log(msg):
        print(f'{time.monotonic() - t0:7.0f}s {msg}', flush=True)

    fuente = 'velas' if a.solo_velas else 'trades'
    pref = 'f1b_velas' if a.solo_velas else 'f1b'
    if a.solo_velas:
        paso = 60
        pasos_plazo = [(None if m is None else m * 60, None if m is None else m) for m in tg['plazos_min_velas']]
        cortes = sorted({max(1, c // 60) for c in tg['cortes_tiempo_s'] if c >= 60})
    else:
        paso = 1
        db = sqlite3.connect(f'file:{os.path.join(datos, "f1b.sqlite")}?mode=ro', uri=True)
        pasos_plazo = [(p, p) for p in tg['plazos_s']]
        cortes = list(tg['cortes_tiempo_s'])

    # Cache por activo: el analisis de un activo con trades tarda ~3 min, y con
    # --esperar se va haciendo a medida que la descarga termina cada uno. La firma
    # cambia si cambian los parametros o este codigo: entonces se recalcula.
    cache = os.path.join(datos, 'por_activo')
    os.makedirs(cache, exist_ok=True)
    # La firma incluye todos los modulos del estudio que entran en el calculo
    # (revision del 2026-11-06: antes solo este fichero).
    h = hashlib.sha256()
    for m in (__file__, fa.__file__, cb.__file__, fd.__file__):
        with open(os.path.abspath(m), 'rb') as fh:
            h.update(fh.read())
    h.update(json.dumps([par['f1'], pb, par['comisiones'], par['cuenta']], sort_keys=True).encode())
    firma = h.hexdigest()[:16]

    activos, A, B, C, D, fuera = [], [], [], [], [], []
    pendientes = list(ids)
    while pendientes:
        avance = False
        for pid in list(pendientes):
            ruta = os.path.join(cache, f'{pid}.{fuente}.json')
            r = None
            if os.path.exists(ruta):
                with open(ruta, encoding='utf-8') as fh:
                    r = json.load(fh)
                if r.get('firma') != firma:
                    r = None
            if r is None:
                if a.solo_velas:
                    g = rejilla_velas(f1db, pid, ini, fin)
                else:
                    if not completo_trades(db, pid, pb['trades_por_peticion']):
                        continue
                    ms = medio_spread_f1(f1db, pid)
                    if ms is None:
                        r = {'firma': firma, 'fuera': 'sin fotos del libro en la F1'}
                    else:
                        g = rejilla_trades(db, pid, ini, fin, ms, pb['lado_fresco_max_s'], pb['trades_por_peticion'],
                                           tg['nocional_variante_volumen_usd'])
                if r is None:
                    log(f'{pid}: rejilla {fuente} lista ({g.trades:,} trades/velas)')
                    res, fa_, fb_, fc_, fd_ = analizar(pid, g, par, niveles, nivel_eval, pasos_plazo, cortes,
                                                       not a.solo_velas, log)
                    del g
                    r = {'firma': firma, 'res': res, 'A': fa_, 'B': fb_, 'C': fc_, 'D': fd_}
                    if res.get('dias_datos', 0) < par['f1']['dias_minimos_por_activo']:
                        r['fuera'] = f'menos de {par["f1"]["dias_minimos_por_activo"]} dias de datos'
                with open(ruta + '.tmp', 'w', encoding='utf-8') as fh:
                    json.dump(r, fh)
                os.replace(ruta + '.tmp', ruta)
            pendientes.remove(pid)
            avance = True
            if r.get('fuera'):
                fuera.append(pid)
                log(f'{pid}: fuera ({r["fuera"]})')
                continue
            activos.append(r['res'])
            A += r['A']
            B += r['B']
            C += r['C']
            D += r['D']
            log(f'{pid}: listo ({len(r["B"])} combinaciones de toma de ganancia)')
        if pendientes and not avance:
            terminada = (not a.solo_velas and
                         db.execute("SELECT valor FROM corrida WHERE clave='descarga_fin'").fetchone() is not None)
            if not a.esperar or terminada:
                for pid in pendientes:
                    fuera.append(pid)
                    log(f'{pid}: trades incompletos, fuera')
                break
            time.sleep(120)
    if not a.solo_velas:
        fin_desc = db.execute("SELECT valor FROM corrida WHERE clave='descarga_fin'").fetchone()

    escribir_csv(os.path.join(datos, f'{pref}_activos.csv'), activos)
    escribir_csv(os.path.join(datos, f'{pref}_puerta_segundos.csv'), A)
    escribir_csv(os.path.join(datos, f'{pref}_toma_ganancia.csv'), B)
    escribir_csv(os.path.join(datos, f'{pref}_tiempos.csv'), C)
    escribir_csv(os.path.join(datos, f'{pref}_impulso.csv'), D)
    resumen = resumir(par, A, B, C, D, nivel_eval, activos, fuera, fuente)
    resumen['ventana_utc'] = [ini, fin]
    if not a.solo_velas:
        resumen['descarga_fin'] = json.loads(fin_desc[0]) if fin_desc else None
    with open(os.path.join(datos, f'{pref}_resumen.json'), 'w', encoding='utf-8') as fh:
        json.dump(resumen, fh, indent=1, ensure_ascii=False)
    print(json.dumps({k: resumen[k] for k in ('fuente', 'nivel_evaluado', 'puerta_segundos', 'toma_ganancia_pasan')},
                     ensure_ascii=False))
    log('fin')


def resumir(par, A, B, C, D, nivel_eval, activos, fuera, fuente):
    p1, tg = par['f1'], par['f1b']['toma_ganancia']
    out = {'fuente': fuente, 'nivel_evaluado': nivel_eval, 'nivel_confirmado': bool(par['cuenta'].get('nivel_real')),
           'activos': len(activos), 'fuera': fuera}
    # A
    pa = {}
    for modo in p1['modos_que_deciden']:
        fl = [x for x in A if x['nivel'] == nivel_eval and x['modo'] == modo]
        if not fl:
            continue
        mejor = min(fl, key=lambda x: x['rho_decide'])
        pa[modo] = {'combinaciones': len(fl), 'pasan': sum(x['pasa'] for x in fl),
                    'robustas': sum(x.get('robusto', 0) for x in fl),
                    'mejor': {k: mejor[k] for k in ('product_id', 'h_s', 'rho_decide', 'sigma_bps', 'U_bps')},
                    'lista': sorted([(x['product_id'], x['h_s'], round(x['rho_decide'], 3), x.get('robusto'))
                                     for x in fl if x['pasa']], key=lambda t: t[2])}
    out['puerta_segundos'] = pa
    # B
    ev = [x for x in B if x['nivel'] == nivel_eval]
    out['toma_ganancia_pasan'] = {m: sum(x['pasa'] for x in ev if x['modo'] == m) for m in tg['modos']}
    out['toma_ganancia_pasan_variante_volumen'] = sum(x.get('pasa_vol', 0) for x in ev if x['modo'] == 'TM')
    out['toma_ganancia_combinaciones'] = {m: sum(1 for x in ev if x['modo'] == m) for m in tg['modos']}
    out['toma_ganancia_lista'] = sorted([(x['product_id'], x['modo'], x['margen_bps'], x['plazo_s'],
                                          round(x['capital_m1']), round(x['capital_m2'])) for x in ev if x['pasa']])
    # Nivel necesario = el MAS CARO (para TM) con el que la combinacion pasa.
    # intro_coinbase_one es mas barato que advanced_1 para TM: se ordena por coste.
    coste = {n: fa.umbral(t, m) for n, m, t in fa.niveles_comision(par)}
    nec = {}
    for x in B:
        if x['modo'] != 'TM' or not x['pasa']:
            continue
        k = f"{x['product_id']}|{x['margen_bps']}|{x['plazo_s']}"
        if k not in nec or coste[x['nivel']] > coste[nec[k]]:
            nec[k] = x['nivel']
    out['toma_ganancia_nivel_necesario'] = nec
    return out


if __name__ == '__main__':
    main()
