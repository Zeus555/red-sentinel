#!/usr/bin/env python3
"""F1b del estudio de volatilidad en Coinbase: descarga de TRADES historicos.

Por que: las velas de 1 min de la F1 no ven horizontes de 20 s ni el lado
(bid/ask) de cada precio. Exchange da el historial publico de trades paginado
hacia atras por trade_id, con el lado del maker. Con eso se reconstruye una
rejilla de 1 s con ask (ultimo taker comprador) y bid (ultimo taker vendedor).

Misma ventana y mismo universo que la F1: se leen de su f1.sqlite (solo
lectura). Los datos van a una SQLite LOCAL nueva (f1b.sqlite), nunca a rqlite.

Fases:
  1. Para cada producto busca el primer trade_id >= inicio y >= fin de la
     ventana (busqueda por interpolacion, ~15 peticiones) y lo congela.
  2. Pagina hacia atras desde el fin hasta el inicio, 1000 trades por peticion.
     Cada pagina se guarda comprimida y se confirma: si se corta, el mismo
     comando sigue donde estaba.

Uso:  python3 f1b_descarga.py --datos ~/estudio-coinbase/f1b --f1 ~/estudio-coinbase/f1/f1.sqlite [--contar]
      python3 f1b_descarga.py --datos /tmp/prueba ... --solo ZEC-USD --max-paginas 20   (prueba corta,
                                                       en OTRA carpeta: nunca en la de la descarga real)
"""
import argparse
import json
import os
import sqlite3
import sys
import threading
import time
import zlib
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

import cb_comun as cb

AQUI = os.path.dirname(os.path.abspath(__file__))

ESQUEMA = """
CREATE TABLE IF NOT EXISTS corrida (clave TEXT PRIMARY KEY, valor TEXT);
CREATE TABLE IF NOT EXISTS producto (
  product_id TEXT PRIMARY KEY, id_ini INTEGER, id_fin INTEGER, estado TEXT, nota TEXT);
CREATE TABLE IF NOT EXISTS pagina (
  product_id TEXT NOT NULL, after_id INTEGER NOT NULL, n INTEGER, id_min INTEGER, id_max INTEGER,
  t_min_ms INTEGER, t_max_ms INTEGER, datos_z BLOB, UNIQUE (product_id, after_id));
"""


def ahora_iso():
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def a_ms(iso):
    """'2026-11-06T22:02:15.333241Z' -> milisegundos UNIX (tambien sin fraccion)."""
    return int(datetime.fromisoformat(iso.replace('Z', '+00:00')).timestamp() * 1000)


class Trades:
    def __init__(self, cli, pid, por_pagina):
        self.cli, self.pid, self.por_pagina = cli, pid, por_pagina

    def pagina(self, after=None, limite=None):
        """Trades con trade_id < after (los mas nuevos primero), como
        [(id, t_ms, precio, tamano, taker_compra)]. None si la API falla."""
        url = f'{cb.EX}/products/{self.pid}/trades?limit={limite or self.por_pagina}'
        if after is not None:
            url += f'&after={after}'
        j = self.cli.get(url)
        if not isinstance(j, list):
            return None
        out = []
        for tr in j:
            try:
                # side es el lado del MAKER: 'sell' = el taker compro (pago el ask).
                out.append((int(tr['trade_id']), a_ms(tr['time']), float(tr['price']), float(tr['size']),
                            1 if tr['side'] == 'sell' else 0))
            except (KeyError, TypeError, ValueError):
                # Un trade ilegible no se salta en silencio: la pagina entera cuenta
                # como fallo y se vuelve a pedir (revision del 2026-11-06).
                return None
        return out

    def en(self, x):
        """(id, t_ms) del trade con mayor id <= x, o None si no hay ninguno."""
        p = self.pagina(after=x + 1, limite=1)
        if p is None:
            raise RuntimeError(f'{self.pid}: la API no respondio al buscar el id {x}')
        return (p[0][0], p[0][1]) if p else None

    def primer_id(self, t_obj, ultimo, ritmo):
        """Menor id x tal que el trade con mayor id <= x tiene t >= t_obj.

        Busqueda por interpolacion con un paso de biseccion cada dos, para que
        converja aunque el ritmo de trades cambie mucho dentro de la ventana."""
        hi, t_hi = ultimo
        if t_hi < t_obj:
            return hi + 1
        paso = max(1000, int(ritmo * (t_hi - t_obj) * 1.2))
        while True:
            lo = max(1, hi - paso)
            r = self.en(lo)
            if r is None or r[1] < t_obj:
                t_lo = r[1] if r else float('-inf')
                break
            if lo == 1:
                return 1
            hi, t_hi = lo, r[1]
            paso *= 4
        vuelta = 0
        while hi - lo > 1:
            vuelta += 1
            if vuelta % 2 and t_lo != float('-inf') and t_hi > t_lo:
                g = lo + int((hi - lo) * (t_obj - t_lo) / (t_hi - t_lo))
            else:
                g = (lo + hi) // 2
            g = min(hi - 1, max(lo + 1, g))
            r = self.en(g)
            if r is None or r[1] < t_obj:
                lo, t_lo = g, (r[1] if r else float('-inf'))
            else:
                hi, t_hi = g, r[1]
        return hi


def pagina_valida(n, id_min, id_max, after, paso, id_ini):
    """Una pagina 'after' sirve si todos sus ids son < after y cubre su tramo
    [after-paso, after): llena (paso ids distintos < after llegan por fuerza a
    after-paso) o, si es corta, llegando hasta el piso. Una vacia nunca sirve:
    id_ini < after es un trade real que tendria que haber salido."""
    if not n:
        return False
    if id_max is None or id_max >= after:
        return False
    return n >= paso or id_min <= max(after - paso, id_ini)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--datos', required=True, help='carpeta de datos (fuera del repo)')
    ap.add_argument('--f1', required=True, help='f1.sqlite de la F1 (ventana y universo, solo lectura)')
    ap.add_argument('--parametros', default=os.path.join(AQUI, 'parametros.json'))
    ap.add_argument('--contar', action='store_true', help='solo la fase 1: cuantos trades hay y cuanto tardaria')
    ap.add_argument('--solo', help='lista de product_id separada por comas (solo para pruebas)')
    ap.add_argument('--max-paginas', type=int, help='corta cada producto tras N paginas (solo para pruebas)')
    a = ap.parse_args()

    par = cb.cargar_parametros(a.parametros)
    pb = par['f1b']
    datos = os.path.expanduser(a.datos)
    os.makedirs(datos, exist_ok=True)
    flog = open(os.path.join(datos, 'f1b_descarga.log'), 'a', encoding='utf-8')
    cerrojo_log = threading.Lock()

    def log(msg):
        linea = f'{ahora_iso()} {msg}'
        with cerrojo_log:
            print(linea, flush=True)
            flog.write(linea + '\n')
            flog.flush()

    f1 = sqlite3.connect(f'file:{os.path.expanduser(a.f1)}?mode=ro', uri=True)
    ini, fin = json.loads(f1.execute("SELECT valor FROM corrida WHERE clave='ventana'").fetchone()[0])
    universo = [r[0] for r in f1.execute(
        'SELECT product_id FROM producto WHERE en_universo=1 OR es_control=1 ORDER BY vol24h_usd DESC')]
    f1.close()
    ids = [x.strip() for x in a.solo.split(',') if x.strip()] if a.solo else universo

    db = sqlite3.connect(os.path.join(datos, 'f1b.sqlite'))
    db.execute('PRAGMA journal_mode=WAL')
    db.executescript(ESQUEMA)
    db.execute("INSERT OR IGNORE INTO corrida VALUES ('ventana', ?)", (json.dumps([ini, fin]),))
    db.execute("INSERT OR IGNORE INTO corrida VALUES ('parametros', ?)", (json.dumps(par),))
    v = json.loads(db.execute("SELECT valor FROM corrida WHERE clave='ventana'").fetchone()[0])
    if v != [ini, fin]:
        raise SystemExit(f'la ventana de f1b.sqlite {v} no es la de la F1 {[ini, fin]}')
    db.commit()
    cli = cb.Cliente(pb['peticiones_por_segundo'], log)
    log(f'ventana {datetime.fromtimestamp(ini, timezone.utc):%Y-%m-%d %H:%M} -> '
        f'{datetime.fromtimestamp(fin, timezone.utc):%Y-%m-%d %H:%M} UTC; {len(ids)} productos')

    # ---- Fase 1: limites de trade_id por producto (se congelan) ----
    hechos = {r[0]: r for r in db.execute('SELECT product_id, id_ini, id_fin, estado, nota FROM producto')}
    for pid in ids:
        if pid in hechos:
            continue
        tr = Trades(cli, pid, pb['trades_por_peticion'])
        ult = tr.pagina()
        if ult is None:
            # Fallo de la API, no "sin datos": no se congela nada y la ejecucion
            # acaba con error para que systemd la relance.
            log(f'{pid}: la API no respondio al pedir el ultimo trade; se reintenta en la proxima ejecucion')
            continue
        if not ult:
            db.execute('INSERT OR REPLACE INTO producto VALUES (?,?,?,?,?)', (pid, None, None, 'sin_datos',
                                                                             'Exchange no devolvio trades'))
            db.commit()
            log(f'{pid}: sin trades en Exchange')
            continue
        ritmo = (len(ult) - 1) / max(1, ult[0][1] - ult[-1][1])        # trades por ms, ahora
        try:
            id_fin = tr.primer_id(fin * 1000, (ult[0][0], ult[0][1]), ritmo)
            id_ini = tr.primer_id(ini * 1000, (id_fin, fin * 1000), ritmo)
        except RuntimeError as e:
            log(f'{e}; se reintenta en la proxima ejecucion')
            continue
        db.execute('INSERT OR REPLACE INTO producto VALUES (?,?,?,?,?)', (pid, id_ini, id_fin, 'pendiente', None))
        db.commit()
        log(f'{pid}: trade_id {id_ini} -> {id_fin} (~{id_fin - id_ini} trades)')

    prods = [r for r in db.execute('SELECT product_id, id_ini, id_fin, estado FROM producto ORDER BY id_fin - id_ini')
             if r[0] in ids]
    total = sum(r[2] - r[1] for r in prods if r[1] is not None)
    falta = 0
    estado = {}
    for pid, i0, i1, est in prods:
        if i0 is None:
            continue
        m = db.execute('SELECT MIN(id_min) FROM pagina WHERE product_id=?', (pid,)).fetchone()[0]
        estado[pid] = m if m is not None else i1
        falta += max(0, estado[pid] - i0) if est != 'hecho' else 0
    pags = falta / pb['trades_por_peticion']
    log(f'fase 1 lista: {len(prods)} productos, ~{total:,} trades en la ventana; faltan ~{pags:,.0f} paginas '
        f'(~{pags / pb["peticiones_por_segundo"] / 3600:.1f} h a {pb["peticiones_por_segundo"]}/s)')
    if a.contar:
        return

    # ---- Fase 2: paginas a paso fijo, en paralelo ----
    # La pagina 'after=X' trae los 1000 trades con id < X. Con ids consecutivos las
    # paginas X, X-1000, X-2000... encajan justo; si hay huecos se solapan, pero
    # nunca dejan un agujero: cada pagina cubre al menos [X-1000, X). El analisis
    # usa de cada pagina solo los ids de su tramo [X-1000, X), asi no hay
    # duplicados. Como las paginas no dependen unas de otras, se piden en paralelo
    # (la latencia, ~0,5 s, limitaba a 1 pagina/s en serie).
    paso, hilos = pb['trades_por_peticion'], pb['hilos']
    tareas, pend, malas = [], {}, 0
    for pid, i0, i1, est in prods:
        if i0 is None:
            continue
        # Una pagina guardada que no pasa la validacion cuenta como no pedida.
        tienen = set()
        for af, n, mn, mx in db.execute('SELECT after_id, n, id_min, id_max FROM pagina WHERE product_id=?', (pid,)):
            if pagina_valida(n, mn, mx, af, paso, i0):
                tienen.add(af)
            elif i0 < af <= i1 and (i1 - af) % paso == 0:
                malas += 1
        faltan = [x for x in range(i1, i0, -paso) if x not in tienen]
        if a.max_paginas:
            faltan = faltan[:a.max_paginas]
        tareas += [(pid, x, i0) for x in faltan]
        pend[pid] = len(faltan)
        nuevo = 'hecho' if not faltan and not a.max_paginas else 'pendiente'
        if nuevo != est:
            db.execute('UPDATE producto SET estado=? WHERE product_id=?', (nuevo, pid))
    db.commit()
    log(f'fase 2: {len(tareas):,} paginas por pedir ({malas} guardadas no validas) con {hilos} hilos a '
        f'{pb["peticiones_por_segundo"]}/s (~{len(tareas) / pb["peticiones_por_segundo"] / 3600:.1f} h)')

    def bajar(t):
        pid, after, i0 = t
        tr = Trades(cli, pid, paso)
        for intento in range(3):
            p = tr.pagina(after=after)
            if p is not None and pagina_valida(len(p), min((x[0] for x in p), default=None),
                                               max((x[0] for x in p), default=None), after, paso, i0):
                return pid, after, p
            log(f'{pid}: pagina after={after} {"fallo" if p is None else "no valida (" + str(len(p)) + " trades)"}; '
                f'espera 30 s')
            time.sleep(30)
        return pid, after, None

    t0, hechas = time.monotonic(), 0
    with ThreadPoolExecutor(max_workers=hilos) as ex:
        for k in range(0, len(tareas), 300):
            fallos = 0
            for pid, after, p in ex.map(bajar, tareas[k:k + 300]):
                if p is None:
                    fallos += 1
                    continue
                datos_z = zlib.compress(json.dumps(p, separators=(',', ':')).encode(), 6)
                db.execute('INSERT OR REPLACE INTO pagina (product_id, after_id, n, id_min, id_max, t_min_ms, '
                           't_max_ms, datos_z) VALUES (?,?,?,?,?,?,?,?)',
                           (pid, after, len(p), min((x[0] for x in p), default=None),
                            max((x[0] for x in p), default=None), min((x[1] for x in p), default=None),
                            max((x[1] for x in p), default=None), datos_z))
                hechas += 1
                pend[pid] -= 1
                if pend[pid] == 0 and not a.max_paginas:
                    db.execute("UPDATE producto SET estado='hecho' WHERE product_id=?", (pid,))
                    n = db.execute('SELECT SUM(n), COUNT(*) FROM pagina WHERE product_id=?', (pid,)).fetchone()
                    log(f'{pid}: hecho, {n[0]:,} trades en {n[1]} paginas')
            db.commit()
            if fallos:
                raise SystemExit(f'{fallos} paginas sin respuesta; volver a lanzar las pide de nuevo')
            vel = hechas / (time.monotonic() - t0)
            if (k // 300) % 10 == 9:
                log(f'{hechas:,}/{len(tareas):,} paginas; {vel:.1f}/s; faltan ~{(len(tareas) - hechas) / vel / 3600:.1f} h; '
                    f'{cli.stats}')

    # Pendiente = cualquier producto pedido que no este 'hecho' ni sea 'sin_datos' de
    # verdad, incluidos los que no tienen fila porque la fase 1 fallo.
    est = dict(db.execute('SELECT product_id, estado FROM producto'))
    pend = sum(1 for pid in ids if est.get(pid) not in ('hecho', 'sin_datos'))
    resumen = {'fin': ahora_iso(), 'pendientes': pend, 'stats': cli.stats,
               'trades': db.execute('SELECT SUM(n) FROM pagina').fetchone()[0]}
    if a.solo or a.max_paginas:
        # Una prueba corta no marca la descarga como terminada: el analisis con
        # --esperar lo tomaria como el final y dejaria fuera lo que falta.
        log(f'prueba corta terminada: {resumen}')
        return
    if pend:
        log(f'descarga incompleta: {resumen}; se relanza')
        sys.exit(2)
    db.execute("INSERT OR REPLACE INTO corrida VALUES ('descarga_fin', ?)", (json.dumps(resumen),))
    db.commit()
    log(f'descarga terminada: {resumen}')
    with open(os.path.join(datos, 'descarga.ok'), 'w', encoding='utf-8') as fh:
        json.dump(resumen, fh)


if __name__ == '__main__':
    main()
