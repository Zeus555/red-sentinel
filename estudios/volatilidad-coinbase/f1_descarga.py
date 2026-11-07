#!/usr/bin/env python3
"""F1 del estudio de volatilidad en Coinbase: descarga de datos.

Que guarda (en una SQLite LOCAL, nunca en rqlite: una base que crece por WiFi
fue la causa de la tormenta del 15-16/10):
  - producto: los ~900 productos SPOT tal como los lista Coinbase hoy, con el
    motivo por el que cada uno entra o no al universo. El universo se congela en
    la primera ejecucion; reanudar no lo recalcula.
  - vela: velas de 1 min de los ultimos `dias` dias para el universo + controles.
  - libro: fotos del libro (hasta 1000 niveles por lado) del universo cada
    `fotos_libro_cada_min`, para la curva monto -> coste.

Reanudable: cada tramo de 350 velas queda anotado en `tramo`; si se corta, se
vuelve a lanzar igual y sigue donde estaba. La ventana de tiempo tambien se
congela en la primera ejecucion.

Uso:  python3 f1_descarga.py --datos ~/estudio-coinbase/f1 [--parametros parametros.json]
      python3 f1_descarga.py --datos DIR --dias 1 --solo BTC-USD,ZEC-USD   (prueba corta)
"""
import argparse
import json
import os
import sqlite3
import sys
import time
import zlib
from datetime import datetime, timezone

import cb_comun as cb

AQUI = os.path.dirname(os.path.abspath(__file__))
# 350 es el maximo de velas por peticion (400 da HTTP 400, medido 2026-11-02).
TRAMO = 350

ESQUEMA = """
CREATE TABLE IF NOT EXISTS corrida (clave TEXT PRIMARY KEY, valor TEXT);
CREATE TABLE IF NOT EXISTS producto (
  product_id TEXT PRIMARY KEY, base TEXT, quote TEXT, vol24h_usd REAL, precio REAL,
  base_min_size TEXT, base_increment TEXT, quote_min_size TEXT, quote_increment TEXT,
  max_slippage REAL, en_universo INTEGER NOT NULL, es_control INTEGER NOT NULL, motivo TEXT, json TEXT);
CREATE TABLE IF NOT EXISTS vela (
  product_id TEXT NOT NULL, t INTEGER NOT NULL, o REAL, h REAL, l REAL, c REAL, v REAL,
  PRIMARY KEY (product_id, t)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS tramo (
  product_id TEXT NOT NULL, ini INTEGER NOT NULL, fin INTEGER NOT NULL, n INTEGER, estado TEXT,
  PRIMARY KEY (product_id, ini));
CREATE TABLE IF NOT EXISTS libro (
  product_id TEXT NOT NULL, ts REAL NOT NULL, ronda INTEGER, json_z BLOB,
  PRIMARY KEY (product_id, ts));
"""


def ahora_iso():
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def listar_productos(cli):
    prods, cursor = [], ''
    for _ in range(20):
        url = f'{cb.AT}/products?product_type=SPOT' + (f'&cursor={cursor}' if cursor else '')
        j = cli.get(url)
        if j is None:
            raise SystemExit('no se pudo listar los productos')
        prods += j.get('products') or []
        pag = j.get('pagination') or {}
        cursor = pag.get('next_cursor') if pag.get('has_next') else ''
        if not cursor:
            break
    return prods


def motivo_exclusion(p, par_u):
    """None si el producto entra al universo; si no, por que se queda fuera."""
    quote = p.get('quote_currency_id')
    # Los X-USDC con alias son el MISMO libro que X-USD: contarlos seria duplicar.
    if not (quote == par_u['quote'] or (quote == 'USDC' and not p.get('alias'))):
        return 'otra_moneda' if quote != 'USDC' else 'alias_usdc'
    if p.get('status') != 'online' or p.get('trading_disabled') or p.get('is_disabled') or p.get('view_only'):
        return 'no_operable'
    for k in ('cancel_only', 'limit_only', 'post_only', 'auction_mode'):
        if p.get(k):
            return k
    base = (p.get('base_currency_id') or '').upper()
    precio, hi, lo = num(p.get('price')), num(p.get('high_24h')), num(p.get('low_24h'))
    # Heuristica para estables que no esten en la lista: cotiza a ~1 USD y casi no se mueve.
    pegada = precio and 0.97 < precio < 1.03 and hi and lo and (hi - lo) / precio < 0.01
    if base in par_u['estables'] or pegada:
        return 'estable'
    if (num(p.get('approximate_quote_24h_volume')) or 0) < par_u['volumen_min_usd']:
        return 'volumen_bajo'
    return None


def congelar_universo(db, cli, par, log):
    if db.execute("SELECT valor FROM corrida WHERE clave='universo_congelado'").fetchone():
        return
    par_u = par['universo']
    prods = listar_productos(cli)
    # max_slippage_percentage solo lo da la API de Exchange: es la banda de
    # proteccion de precio por producto (2 % en BTC, 3 % en la mayoria, hasta 10 %).
    ex = cli.get(f'{cb.EX}/products') or []
    banda = {e.get('id'): num(e.get('max_slippage_percentage')) for e in ex if isinstance(e, dict)}
    filas, cuenta = [], {}
    for p in prods:
        pid = p.get('product_id')
        m = motivo_exclusion(p, par_u)
        control = pid in par_u['controles']
        cuenta[m or 'universo'] = cuenta.get(m or 'universo', 0) + 1
        filas.append((pid, p.get('base_currency_id'), p.get('quote_currency_id'),
                      num(p.get('approximate_quote_24h_volume')), num(p.get('price')),
                      p.get('base_min_size'), p.get('base_increment'), p.get('quote_min_size'),
                      p.get('quote_increment'), banda.get(pid), 1 if m is None else 0,
                      1 if control else 0, m, json.dumps(p, separators=(',', ':'))))
    db.executemany('INSERT OR REPLACE INTO producto VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)', filas)
    db.execute("INSERT OR REPLACE INTO corrida VALUES ('universo_congelado', ?)", (ahora_iso(),))
    db.execute("INSERT OR REPLACE INTO corrida VALUES ('embudo', ?)", (json.dumps(cuenta),))
    db.commit()
    log(f'universo congelado: {len(prods)} productos SPOT; embudo {cuenta}')


def congelar_ventana(db, dias):
    fila = db.execute("SELECT valor FROM corrida WHERE clave='ventana'").fetchone()
    if fila:
        return tuple(json.loads(fila[0]))
    # Fin = inicio del minuto en curso (exclusivo): solo velas ya cerradas.
    fin = int(time.time()) // 60 * 60
    ini = fin - dias * 86400
    db.execute("INSERT OR REPLACE INTO corrida VALUES ('ventana', ?)", (json.dumps([ini, fin]),))
    db.commit()
    return ini, fin


def ronda_libros(db, cli, ids, ronda, log):
    ok = 0
    for pid in ids:
        j = cli.get(f'{cb.AT}/product_book?product_id={pid}&limit=1000', sin_cache=True)
        # Misma trampa que siempre: comprobar que la respuesta es del producto pedido.
        if not j or (j.get('pricebook') or {}).get('product_id') != pid:
            continue
        db.execute('INSERT OR IGNORE INTO libro VALUES (?,?,?,?)',
                   (pid, time.time(), ronda, zlib.compress(json.dumps(j, separators=(',', ':')).encode(), 6)))
        ok += 1
    db.commit()
    log(f'ronda de libros {ronda}: {ok}/{len(ids)}')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--datos', required=True, help='carpeta de datos (fuera del repo)')
    ap.add_argument('--parametros', default=os.path.join(AQUI, 'parametros.json'))
    ap.add_argument('--dias', type=int, help='sobrescribe f1.dias (solo para pruebas)')
    ap.add_argument('--solo', help='lista de product_id separada por comas (solo para pruebas)')
    a = ap.parse_args()

    par = cb.cargar_parametros(a.parametros)
    p1 = par['f1']
    datos = os.path.expanduser(a.datos)
    os.makedirs(datos, exist_ok=True)
    flog = open(os.path.join(datos, 'f1_descarga.log'), 'a', encoding='utf-8')

    def log(msg):
        linea = f'{ahora_iso()} {msg}'
        print(linea, flush=True)
        flog.write(linea + '\n')
        flog.flush()

    db = sqlite3.connect(os.path.join(datos, 'f1.sqlite'))
    db.execute('PRAGMA journal_mode=WAL')
    db.executescript(ESQUEMA)
    cli = cb.Cliente(p1['peticiones_por_segundo'], log)

    db.execute("INSERT OR IGNORE INTO corrida VALUES ('parametros', ?)", (json.dumps(par),))
    congelar_universo(db, cli, par, log)
    ini, fin = congelar_ventana(db, a.dias or p1['dias'])
    if a.solo:
        ids = [x.strip() for x in a.solo.split(',') if x.strip()]
    else:
        ids = [r[0] for r in db.execute(
            'SELECT product_id FROM producto WHERE en_universo=1 OR es_control=1 ORDER BY vol24h_usd DESC')]
    log(f'ventana {datetime.fromtimestamp(ini, timezone.utc):%Y-%m-%d %H:%M} -> '
        f'{datetime.fromtimestamp(fin, timezone.utc):%Y-%m-%d %H:%M} UTC; {len(ids)} productos')

    hechos = {(r[0], r[1]) for r in db.execute("SELECT product_id, ini FROM tramo WHERE estado='ok'")}
    pendientes = [(pid, t) for pid in ids for t in range(ini, fin, TRAMO * 60) if (pid, t) not in hechos]
    total = len(ids) * len(range(ini, fin, TRAMO * 60))
    log(f'tramos: {total - len(pendientes)} hechos, {len(pendientes)} pendientes '
        f'(~{len(pendientes) / p1["peticiones_por_segundo"] / 60:.0f} min)')

    ronda = (db.execute('SELECT MAX(ronda) FROM libro').fetchone()[0] or 0) + 1
    ronda_libros(db, cli, ids, ronda, log)
    ultima_ronda = time.monotonic()
    t0, hechos_ahora = time.monotonic(), 0

    for pid, t in pendientes:
        # end = un segundo antes del siguiente tramo: asi da igual si Coinbase trata
        # `end` como inclusivo o exclusivo, y nunca se piden mas de 350 velas.
        tfin = min(t + TRAMO * 60, fin) - 1
        j = cli.get(f'{cb.AT}/products/{pid}/candles?start={t}&end={tfin}&granularity=ONE_MINUTE&limit={TRAMO}')
        if j is None:
            db.execute('INSERT OR REPLACE INTO tramo VALUES (?,?,?,?,?)', (pid, t, tfin, None, 'error'))
        else:
            filas = []
            for c in j.get('candles') or []:
                try:
                    ts = int(c['start'])
                    fila = (pid, ts, float(c['open']), float(c['high']), float(c['low']),
                            float(c['close']), float(c['volume']))
                except (KeyError, TypeError, ValueError):
                    continue
                if t <= ts <= tfin:
                    filas.append(fila)
            db.executemany('INSERT OR IGNORE INTO vela VALUES (?,?,?,?,?,?,?)', filas)
            # Un tramo con 0 velas es valido: producto listado despues o minutos sin trades.
            db.execute('INSERT OR REPLACE INTO tramo VALUES (?,?,?,?,?)', (pid, t, tfin, len(filas), 'ok'))
        db.commit()
        hechos_ahora += 1
        if hechos_ahora % 100 == 0:
            vel = hechos_ahora / (time.monotonic() - t0)
            log(f'{hechos_ahora}/{len(pendientes)} tramos; {pid}; '
                f'faltan ~{(len(pendientes) - hechos_ahora) / vel / 60:.0f} min; {cli.stats}')
        if time.monotonic() - ultima_ronda >= p1['fotos_libro_cada_min'] * 60:
            ronda += 1
            ronda_libros(db, cli, ids, ronda, log)
            ultima_ronda = time.monotonic()

    ronda_libros(db, cli, ids, ronda + 1, log)
    errores = db.execute("SELECT COUNT(*) FROM tramo WHERE estado='error'").fetchone()[0]
    resumen = {'fin': ahora_iso(), 'tramos_error': errores, 'stats': cli.stats,
               'velas': db.execute('SELECT COUNT(*) FROM vela').fetchone()[0]}
    db.execute("INSERT OR REPLACE INTO corrida VALUES ('descarga_fin', ?)", (json.dumps(resumen),))
    db.commit()
    log(f'descarga terminada: {resumen}')
    if errores:
        log(f'OJO: {errores} tramos con error; volver a lanzar el mismo comando los reintenta')
        sys.exit(2)
    with open(os.path.join(datos, 'descarga.ok'), 'w', encoding='utf-8') as f:
        json.dump(resumen, f)


if __name__ == '__main__':
    main()
