#!/usr/bin/env python3
"""F1b: informe para el dueno a partir de los CSV que deja f1b_analisis.py.

Lee de la carpeta de datos f1b_*.csv (trades, rejilla de 1 s) y f1b_velas_*.csv
(velas de 1 min de la F1) y escribe informe_f1b.md. No calcula nada nuevo: solo
ordena y resume.

Uso:  python3 f1b_informe.py --datos ~/estudio-coinbase/f1b
"""
import argparse
import csv
import json
import math
import os
import re
from datetime import datetime, timezone

import cb_comun as cb
import f1_analisis as fa

AQUI = os.path.dirname(os.path.abspath(__file__))
f, pc = fa.f, fa.pc
REPRESENTATIVOS = ['BTC-USD', 'ETH-USD', 'SOL-USD', 'NEAR-USD', 'ZEC-USD', 'ENA-USD', 'HYPE-USD', 'BIRB-USD', 'ALIGN-USD']


def leer(ruta):
    if not os.path.exists(ruta):
        return []
    with open(ruta, encoding='utf-8') as fh:
        return list(csv.DictReader(fh))


def num(x):
    try:
        v = float(x)
        return None if math.isnan(v) else v
    except (TypeError, ValueError):
        return None


def plazo_txt(s):
    if s in (None, '', 'None'):
        return 'sin plazo'
    s = int(float(s))
    if s < 60:
        return f'{s} s'
    if s < 3600:
        return f'{s // 60} min'
    return f'{s // 3600} h'


def dinero(x):
    if x is None:
        return '—'
    if x < 0.01:
        return '≈ $0'
    if x < 10:
        return '$' + f(x, 2)
    return '$' + f(x, 0)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--datos', required=True)
    ap.add_argument('--parametros', default=os.path.join(AQUI, 'parametros.json'))
    a = ap.parse_args()
    par = cb.cargar_parametros(a.parametros)
    tg = par['f1b']['toma_ganancia']
    d = os.path.expanduser(a.datos)
    res_t = json.load(open(os.path.join(d, 'f1b_resumen.json'), encoding='utf-8')) \
        if os.path.exists(os.path.join(d, 'f1b_resumen.json')) else None
    res_v = json.load(open(os.path.join(d, 'f1b_velas_resumen.json'), encoding='utf-8')) \
        if os.path.exists(os.path.join(d, 'f1b_velas_resumen.json')) else None
    A = leer(os.path.join(d, 'f1b_puerta_segundos.csv'))
    B = leer(os.path.join(d, 'f1b_toma_ganancia.csv'))
    C = leer(os.path.join(d, 'f1b_tiempos.csv'))
    D = leer(os.path.join(d, 'f1b_impulso.csv'))
    ACT = leer(os.path.join(d, 'f1b_activos.csv'))
    BV = leer(os.path.join(d, 'f1b_velas_toma_ganancia.csv'))
    CV = leer(os.path.join(d, 'f1b_velas_tiempos.csv'))
    nivel = (res_t or res_v or {}).get('nivel_evaluado', 'intro')
    confirmado = (res_t or res_v or {}).get('nivel_confirmado')
    ventana = (res_t or res_v or {}).get('ventana_utc')

    L = []
    w = L.append
    dt = lambda t: datetime.fromtimestamp(t, timezone.utc).strftime('%Y-%m-%d %H:%M')
    w('# F1b — Segundos y toma de ganancia\n')
    if ventana:
        w(f'- Ventana: {dt(ventana[0])} → {dt(ventana[1])} UTC, la misma de la F1; mismo universo de 51 activos.')
    w(f'- Nivel de comisión evaluado: **{nivel}** ({"confirmado" if confirmado else "SUPUESTO, sin confirmar por el dueño"}). '
      f'Parámetros v{par["version"]}, sección f1b congelada antes de descargar un solo trade.')
    if res_t:
        df = res_t.get('descarga_fin') or {}
        w(f'- Trades: {res_t["activos"]} activos analizados'
          + (f', {f(df.get("trades"), 0)} trades descargados, {df.get("stats", {}).get("http429", "?")} respuestas 429' if df else '')
          + (f'; fuera: {", ".join(res_t["fuera"])}' if res_t.get('fuera') else '') + '.')
        if not df:
            w('- **OJO: la descarga de trades no había terminado al escribir este informe.**')
    else:
        w('- **Todavía no hay resultados con trades:** este informe solo tiene la parte de velas.')
    w('')

    # ---------------- respuesta corta
    w('## Respuesta corta\n')
    if res_t and res_t.get('puerta_segundos'):
        ps = res_t['puerta_segundos']
        partes = []
        for m, e in ps.items():
            partes.append(f'{m}: pasan {e["pasan"]} de {e["combinaciones"]} ({e["robustas"]} robustas), mejor ρ_req '
                          f'{f(e["mejor"]["rho_decide"], 2)} ({e["mejor"]["product_id"]} a {e["mejor"]["h_s"]} s)')
        w(f'- **Horizonte fijo de 5 a 60 s ({nivel}):** ' + '; '.join(partes) + '.')
    for etiqueta, res in (('trades, de 5 s a sin plazo', res_t), ('velas de 1 min, de 1 min a sin plazo', res_v)):
        if not res:
            continue
        p = res['toma_ganancia_pasan']
        c = res['toma_ganancia_combinaciones']
        w(f'- **Comprar, dejar la venta y esperar ({etiqueta}, {nivel}):** pasan '
          + ', '.join(f'{p[m]} de {c[m]} en {m}' for m in p)
          + (f' (con la variante que exige ≥ $1000 en un segundo para llenar: {res["toma_ganancia_pasan_variante_volumen"]})'
             if res.get('toma_ganancia_pasan_variante_volumen') is not None and res is res_t else '') + '.')
    w('')

    # ---------------- C: tiempo hasta el objetivo
    def tabla_tiempos(filas, titulo, cortes):
        sel = [x for x in filas if x['nivel'] == nivel and x['modo'] == 'TM' and x['margen_bps'] == '10']
        if not sel:
            return
        w(f'### {titulo}\n')
        w(f'Venta límite con ganancia neta de 10 pb (el objetivo queda a ~{f(num(sel[0]["objetivo_bps"]), 0)} pb de la '
          f'entrada por la comisión). "Llega antes de" = fracción de entradas cuyo objetivo se toca antes de ese plazo. '
          f'"Más denso" = el tramo entre cortes con más llegadas por segundo: si de verdad fuera más probable en menos '
          f'tiempo, sería el primero.\n')
        vol = [c for c in (20, 300) if f'p_{c}s_vol' in sel[0]]
        w('| Activo | ' + ' | '.join(f'≤ {plazo_txt(c)}' for c in cortes) + ' | Tramo más denso |'
          + ''.join(f' ≤ {plazo_txt(c)} con ≥ $1000 en un segundo |' for c in vol))
        w('|---|' + '---|' * (len(cortes) + 1 + len(vol)))
        primero = 0
        rapidos = []
        fracs = []
        orden = sorted(sel, key=lambda x: (x['product_id'] not in REPRESENTATIVOS, x['product_id']))
        # El tramo mas denso se busca entre TODOS los cortes preregistrados que trae
        # el CSV, no solo entre las columnas que se muestran.
        # Solo densidad_{N}s: las columnas densidad_{N}s_vol son la variante con volumen.
        todos = sorted(int(m.group(1)) for m in (re.fullmatch(r'densidad_(\d+)s', k) for k in sel[0]) if m)
        for x in orden:
            dens = [(num(x.get(f'densidad_{c}s')) or 0, c) for c in todos]
            mejor = max(dens)[1] if any(v for v, _ in dens) else None
            if mejor == todos[0]:
                primero += 1
            if mejor and mejor <= 60:
                rapidos.append(x['product_id'])
            p60, p5h = num(x.get('p_60s')), num(x.get('p_18000s'))
            if p60 is not None and p5h:
                fracs.append((p60 / p5h, x['product_id']))
            if x['product_id'] in REPRESENTATIVOS:
                idx = todos.index(mejor) if mejor else None
                tramo = '—' if mejor is None else (f'0-{plazo_txt(mejor)}' if idx == 0 else
                                                   f'{plazo_txt(todos[idx - 1])}-{plazo_txt(mejor)}')
                w(f'| {x["product_id"]} | ' + ' | '.join(pc(num(x.get(f"p_{c}s"))) for c in cortes) + f' | {tramo} |'
                  + ''.join(f' {pc(num(x.get(f"p_{c}s_vol")))} |' for c in vol))
        w(f'\nDe {len(sel)} activos, **{primero}** {"tiene" if primero == 1 else "tienen"} el tramo más denso en el primero ({plazo_txt(todos[0])} o menos)'
          + (f' y **{len(rapidos)}** dentro del primer minuto ({", ".join(sorted(rapidos))}).' if todos[0] < 60 else '.'))
        if fracs:
            fracs.sort()
            med = fracs[len(fracs) // 2][0]
            top = ', '.join(f'{p} {pc(v, 1)}' for v, p in fracs[::-1][:3])
            w(f'De las entradas que llegan al objetivo dentro de 5 h, la parte que llega en el primer minuto es, en el '
              f'activo mediano, **{pc(med, 2)}**; las más altas: {top}.')
        w('')

    w('## ¿Es más probable en menos tiempo?\n')
    tabla_tiempos(C, 'Con trades (rejilla de 1 s)', [5, 20, 60, 300, 3600, 18000])
    tabla_tiempos(CV, 'Con velas de 1 min', [60, 300, 900, 3600, 10800, 18000])

    # ---------------- B: toma de ganancia
    def tabla_toma(filas, titulo):
        sel = [x for x in filas if x['nivel'] == nivel and x['modo'] == 'TM' and x['margen_bps'] == '10']
        if not sel:
            return
        w(f'### {titulo}\n')
        w('Comprar al ask (taker), dejar la venta límite (maker) con 10 pb de ganancia neta y esperar hasta el plazo; si '
          'no se llena, vender a mercado. "Acierto" y "media" con entradas cada 10 s (solapadas). "Capital" = simulación '
          'secuencial con $1000 en los 30 días, una operación detrás de otra reinvirtiendo todo. "Comprar y mantener" = '
          'comprar el primer día y vender el último.\n')
        w('| Activo | Plazo | Acierto | Media por operación | Operaciones | Capital tras 30 días | Comprar y mantener |')
        w('|---|---|---|---|---|---|---|')
        for pid in REPRESENTATIVOS:
            for x in [y for y in sel if y['product_id'] == pid]:
                w(f'| {pid} | {plazo_txt(x["plazo_s"])} | {pc(num(x.get("acierto_solapado")), 1)} | '
                  f'{f((num(x.get("media_solapada")) or 0) * 1e4, 0)} pb | {f(num(x["operaciones"]), 0)} | '
                  f'{dinero(num(x["capital"]))} | {dinero(num(x["comprar_mantener"]))} |')
        w('')
        mejores = sorted([x for x in filas if x['nivel'] == nivel], key=lambda x: -(num(x['capital']) or 0))[:10]
        w(f'Las 10 mejores combinaciones de {nivel} (cualquier activo, modo, margen y plazo), por capital final:\n')
        w('| Activo | Modo | Margen | Plazo | Capital 30 días | 1.ª mitad (CyM) | 2.ª mitad (CyM) | Pasa |')
        w('|---|---|---|---|---|---|---|---|')
        for x in mejores:
            w(f'| {x["product_id"]} | {x["modo"]} | {x["margen_bps"]} pb | {plazo_txt(x["plazo_s"])} | '
              f'{dinero(num(x["capital"]))} | {dinero(num(x["capital_m1"]))} ({dinero(num(x["cym_m1"]))}) | '
              f'{dinero(num(x["capital_m2"]))} ({dinero(num(x["cym_m2"]))}) | {"sí" if x["pasa"] == "1" else "no"} |')
        w('')

    w('## Comprar, dejar la venta y esperar\n')
    w(f'Regla preregistrada: pasa si en **cada mitad** de la ventana, empezando con $1000, el capital final supera $1000 '
      f'y supera a comprar y mantener esa mitad, con al menos {tg["min_operaciones_por_mitad"]} operaciones.\n')
    tabla_toma(B, 'Con trades')
    tabla_toma(BV, 'Con velas de 1 min')

    # Nivel necesario (toma de ganancia, TM, trades si hay; si no, velas)
    for etiqueta, res in (('trades', res_t), ('velas', res_v)):
        if not res:
            continue
        nec = res.get('toma_ganancia_nivel_necesario') or {}
        w(f'**Nivel de comisión necesario ({etiqueta}, TM):** '
          + (f'{len(nec)} combinaciones pasan en algún nivel hasta vip_1. ' if nec else
             f'ninguna combinación pasa en ningún nivel hasta vip_1. '))
        if nec:
            por_nivel = {}
            for k, v in nec.items():
                por_nivel.setdefault(v, []).append(k)
            for v in tg['niveles']:
                if v in por_nivel:
                    ej = ', '.join(sorted(por_nivel[v])[:6])
                    w(f'  - {v}: {len(por_nivel[v])} (p. ej. {ej.replace("|", " · ")})')
        w('')

    # ---------------- A: puerta en segundos
    if A:
        w('## Horizonte fijo de 5 a 60 segundos (puerta ρ de la F1)\n')
        w('ρ_req es la correlación que tendría que tener una señal con el movimiento a h segundos para cubrir la comisión '
          'operando solo el 1 % de momentos más prometedores; la puerta pide ≤ 0,20. "Veces al día" = ventanas de h '
          'segundos en que el precio subió al menos lo que cuesta la comisión.\n')
        hs = sorted({int(x['h_s']) for x in A})
        w('| Activo | ' + ' | '.join(f'σ {h} s' for h in hs) + ' | ' + ' | '.join(f'ρ TM {h} s' for h in hs) +
          ' | Veces/día que sube ≥ U a 20 s |')
        w('|---|' + '---|' * (2 * len(hs) + 1))
        idx = {(x['product_id'], int(x['h_s']), x['nivel'], x['modo']): x for x in A}
        vistos = set()
        for pid in REPRESENTATIVOS + sorted({x['product_id'] for x in A if x.get('pasa') == '1' and x['nivel'] == nivel}):
            if pid in vistos or not any((pid, h, nivel, 'TM') in idx for h in hs):
                continue
            vistos.add(pid)
            sig = ' | '.join(f(num(idx[(pid, h, nivel, "TM")]["sigma_bps"]), 1) + ' pb' if (pid, h, nivel, 'TM') in idx
                             else '—' for h in hs)
            rho = ' | '.join(f(num(idx[(pid, h, nivel, "TM")]["rho_decide"]), 2) if (pid, h, nivel, 'TM') in idx
                             else '—' for h in hs)
            v20 = idx.get((pid, 20, nivel, 'TT'))
            w(f'| {pid} | {sig} | {rho} | {f(num(v20["veces_dia"]) if v20 else None, 2)} |')
        w('')

    # ---------------- D: impulso
    if D:
        w('## Exploratorio: entrar solo cuando ya empezó a subir\n')
        w('NO decide (con muchas variantes alguna sale bien por azar). Disparo: el ask subió al menos X pb en 5 s y hubo una compra taker en ese '
          'segundo; cuenta solo el primer segundo de cada subida (episodio). Luego la misma venta límite con 10 pb netos y plazo de 20 s, 60 s o 5 min.\n')
        w('| Activo | Subida en 5 s | Episodios/día | Acierto 20 s | Media 20 s | Acierto 5 min | Media 5 min |')
        w('|---|---|---|---|---|---|---|')
        sel = [x for x in D if x['margen_bps'] == '10' and (num(x['disparos']) or 0) > 0]
        claves = sorted({(x['product_id'], x['subida_bps']) for x in sel},
                        key=lambda k: (-(num(next(y['episodios_dia'] for y in sel if (y['product_id'], y['subida_bps']) == k)) or 0)))
        for pid, sub in claves[:20]:
            r20 = next((x for x in sel if x['product_id'] == pid and x['subida_bps'] == sub and x['plazo_s'] == '20'), None)
            r300 = next((x for x in sel if x['product_id'] == pid and x['subida_bps'] == sub and x['plazo_s'] == '300'), None)
            w(f'| {pid} | {sub} pb | {f(num(r20["episodios_dia"]) if r20 else None, 1)} | '
              f'{pc(num(r20["acierto"]) if r20 else None, 1)} | {f((num(r20["media_neta"]) or 0) * 1e4 if r20 else None, 0)} pb | '
              f'{pc(num(r300["acierto"]) if r300 else None, 1)} | {f((num(r300["media_neta"]) or 0) * 1e4 if r300 else None, 0)} pb |')
        w('')

    # ---------------- lados
    if ACT:
        tot = {'compra_sube': 0, 'compra_baja': 0, 'venta_baja': 0, 'venta_sube': 0}
        for x in ACT:
            try:
                for k, v in json.loads(x.get('lados') or '{}').items():
                    tot[k] = tot.get(k, 0) + v
            except (ValueError, AttributeError):
                pass
        w('## Comprobaciones\n')
        ok = tot['compra_sube'] > 20 * max(1, tot['compra_baja']) and tot['venta_baja'] > 20 * max(1, tot['venta_sube'])
        w(f'- Lados de Exchange, por barridos (trades seguidos del mismo lado en el mismo milisegundo, una orden que '
          f'recorre el libro): los que el código toma por compras taker suben el precio {f(tot["compra_sube"], 0)} veces '
          f'y lo bajan {f(tot["compra_baja"], 0)}; los que toma por ventas lo bajan {f(tot["venta_baja"], 0)} y lo suben '
          f'{f(tot["venta_sube"], 0)}. '
          + ('Confirma que side=sell es un taker comprador.' if ok else '**NO confirma el mapeo de lados: revisar.**'))
        fo = sum(int(float(x.get('fuera_orden') or 0)) for x in ACT)
        w(f'- Compras taker que llegaron fuera de orden de tiempo (no cuentan en la variante con volumen): {f(fo, 0)}.')
        w('')

    w('## Sesgos y límites (declarados antes de mirar)\n')
    w('- Llenado de la venta límite: basta con que algún taker comprador pague el objetivo o más, de cualquier tamaño; '
      'en la realidad habría cola delante y la compra tendría que cubrir ~$1000. Favorable a la estrategia. La variante '
      'con volumen (≥ $1000 en un mismo segundo) es la cota contraria: la verdad queda entre las dos.')
    w('- Con velas: entrada al cierre y salida al cierre, sin spread, y llenado con el máximo de la vela. Favorable.')
    w('- Con trades: ask y bid salen del último taker de cada lado; el lado que no opera se mueve con el que sí, y si '
      'lleva más de 60 s sin operar se reancla al otro con el spread mediano. Si nadie operó en 60 s, último trade ± '
      'medio spread.')
    w('- Se entra sin señal, en cualquier momento. Una señal real tendría que ser muy buena: eso es lo que mide la '
      'puerta ρ. El exploratorio de impulso prueba la señal más obvia.')
    w('- Supervivencia: el universo es el de hoy mirando 30 días atrás.')
    with open(os.path.join(d, 'informe_f1b.md'), 'w', encoding='utf-8') as fh:
        fh.write('\n'.join(L) + '\n')
    print(os.path.join(d, 'informe_f1b.md'))


if __name__ == '__main__':
    main()
