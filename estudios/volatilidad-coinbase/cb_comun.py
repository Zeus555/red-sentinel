"""Piezas comunes del estudio de volatilidad en Coinbase: cliente HTTP lento y
educado, recorrido del libro y utilidades numericas. Solo biblioteca estandar:
sentinel014 tiene Python 3.12 pero no Node ni pip.

SOLO LECTURA: endpoints publicos, sin claves ni ordenes. El User-Agent es
generico a proposito (no lleva correo ni nada que identifique al dueno).
"""
import http.client
import json
import math
import random
import threading
import time
import urllib.error
import urllib.request

AT = 'https://api.coinbase.com/api/v3/brokerage/market'
EX = 'https://api.exchange.coinbase.com'
UA = 'RED-Sentinel-estudio/1.0 (datos publicos, baja frecuencia)'


def cargar_parametros(ruta):
    with open(ruta, encoding='utf-8') as f:
        return json.load(f)


class Cliente:
    """Una sola cola global: como mucho `rps` peticiones por segundo.

    POR QUE TAN LENTO: los limites de la REST publica de Advanced Trade no estan
    documentados (comprobado 2026-11-02). Un 429 a media descarga no rompe nada
    (se reintenta), pero ser bloqueado desde la IP de casa si: es la misma IP de
    toda la flota.
    """

    def __init__(self, rps, log):
        self.intervalo = 1.0 / rps
        self.siguiente = 0.0
        self.log = log
        self.stats = {'peticiones': 0, 'reintentos': 0, 'http429': 0, 'errores': 0}
        # Varios hilos pueden compartir el cliente (F1b): el turno se reparte con un
        # cerrojo, asi el tope de peticiones por segundo es global.
        self._cerrojo = threading.Lock()

    def _turno(self):
        with self._cerrojo:
            ahora = time.monotonic()
            mio = max(ahora, self.siguiente)
            self.siguiente = mio + self.intervalo
        if mio > ahora:
            time.sleep(mio - ahora)

    def get(self, url, intentos=6, sin_cache=False):
        """JSON de la respuesta, o None si es un error definitivo (4xx) o se agotan
        los reintentos. 429 y 5xx se reintentan con espera exponencial."""
        cab = {'User-Agent': UA, 'Accept': 'application/json'}
        # La REST de Advanced Trade sale de una cache de ~1 s (Cloudflare). Para el
        # libro interesa la foto fresca; para velas viejas da igual.
        if sin_cache:
            cab['Cache-Control'] = 'no-cache'
        for intento in range(intentos):
            self._turno()
            self.stats['peticiones'] += 1
            try:
                with urllib.request.urlopen(urllib.request.Request(url, headers=cab), timeout=20) as r:
                    return json.loads(r.read().decode('utf-8'))
            except urllib.error.HTTPError as e:
                if e.code == 429 or e.code >= 500:
                    self.stats['reintentos'] += 1
                    if e.code == 429:
                        self.stats['http429'] += 1
                    try:
                        ra = float(e.headers.get('Retry-After') or 0)
                    except ValueError:
                        ra = 0
                    time.sleep(ra if ra > 0 else min(60, 2 ** intento) + random.random())
                    continue
                cuerpo = e.read()[:200].decode('utf-8', 'replace')
                self.stats['errores'] += 1
                self.log(f'HTTP {e.code} {url} {cuerpo}')
                return None
            # urllib solo envuelve en URLError los fallos al ENVIAR. Lo que falla al
            # leer la respuesta sube tal cual (IncompleteRead, SSLEOFError, OSError,
            # UnicodeDecodeError): sin esto, un corte TLS a mitad de cuerpo mataba
            # la descarga entera (revision del 2026-11-06).
            except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError) as e:
                self.stats['reintentos'] += 1
                self.log(f'reintento {intento + 1}/{intentos} {url}: {e}')
                time.sleep(min(60, 2 ** intento) + random.random())
        self.stats['errores'] += 1
        self.log(f'agotados los reintentos: {url}')
        return None


def niveles(lado):
    """[{price,size}] de la API -> [(precio, tamano)] en float, descartando basura."""
    out = []
    for n in lado or []:
        try:
            p, s = float(n['price']), float(n['size'])
        except (KeyError, TypeError, ValueError):
            continue
        if p > 0 and s > 0:
            out.append((p, s))
    return out


def vwap(nivs, nocional):
    """Precio medio al recorrer `nivs` (mejor primero) hasta gastar `nocional` USD.

    None si el libro devuelto no cubre el monto: un None se ve, un cero se
    promedia y contamina (misma regla que Sentinel-Profundidad.sh)."""
    usd = qty = 0.0
    for p, s in nivs:
        if usd + p * s >= nocional:
            qty += (nocional - usd) / p
            return nocional / qty
        usd += p * s
        qty += s
    return None


def profundidad_hasta(nivs, limite, comprar):
    """USD disponibles a precio <= limite (comprando, en asks) o >= limite (vendiendo, en bids)."""
    usd = 0.0
    for p, s in nivs:
        if (comprar and p > limite) or (not comprar and p < limite):
            break
        usd += p * s
    return usd


def bps(x):
    return None if x is None else x * 1e4


def media(xs):
    return sum(xs) / len(xs) if xs else None


def desviacion(xs):
    if len(xs) < 2:
        return None
    m = sum(xs) / len(xs)
    return math.sqrt(sum((x - m) ** 2 for x in xs) / (len(xs) - 1))


def percentil(ordenados, p):
    """Interpolacion lineal sobre una lista YA ordenada de menor a mayor."""
    if not ordenados:
        return None
    i = (len(ordenados) - 1) * p
    lo, hi = math.floor(i), math.ceil(i)
    return ordenados[lo] + (ordenados[hi] - ordenados[lo]) * (i - lo)


def mediana(xs):
    xs = sorted(x for x in xs if x is not None)
    return percentil(xs, 0.5)
