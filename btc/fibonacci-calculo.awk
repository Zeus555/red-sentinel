# Sentinel BTC - niveles de Fibonacci (retrocesos) del ciclo, desde las velas
# diarias de cripto_vela.
#
# Entrada: la salida tsv de velas-calculo.awk con desde=0 (TODA la historia de
# un producto), una vela por linea:
#   marco ts apertura maximo minimo cierre volumen ha_apertura ha_maximo
#   ha_minimo ha_cierre cerrada dias
# Solo se miran las diarias (1d): el maximo y el minimo de una semana son los
# de sus dias, asi que las semanales darian el mismo tramo con menos detalle.
# Entra tambien la vela de hoy aun abierta: su maximo y su minimo ya ocurrieron.
#
# EL TRAMO ("ciclo"): del fondo del ultimo mercado bajista al maximo historico
# (ATH). Hoy, del minimo de 2022 al ATH de 2025, como se traza a mano en
# TradingView. La regla, para que se mueva sola cuando llegue otro ciclo:
#   - maximo historico: una vela cuyo maximo supera al de TODAS las anteriores
#     (igualarlo no cuenta);
#   - la caida que le sigue son las velas desde la siguiente hasta la ultima
#     antes de la que lo supera;
#   - es un MERCADO BAJISTA si su peor CIERRE queda al menos un `caida` (50 %)
#     por debajo de ese maximo Y tardo al menos `dura` dias (365) en volver a
#     superarlo. Se mira el cierre y no la mecha para que un precio absurdo de
#     un instante no convierta en bajista una caida que no lo fue (Coinbase
#     tiene uno: 0,06 $ el 15/04/2017). La duracion separa los mercados
#     bajistas de las correcciones a mitad de ciclo, que pueden caer lo mismo:
#     en el spot, 2018 (cierre -84 %, 1.080 dias) y 2022 (-77 %, 846 dias) lo
#     son; la de 2021 (-54 %, 189 dias) no;
#   - el ciclo empieza en el MINIMO (la mecha; si se repite, el primero) del
#     ultimo mercado bajista ya superado con un maximo nuevo, y acaba en el
#     maximo historico.
# Una caida en curso, aun sin maximo nuevo, no mueve el tramo: si algun dia el
# precio supera el ATH, se mira entonces si fue un mercado bajista. Sin ninguno
# ya superado (el perpetuo, que nacio en julio de 2025) no hay ciclo y no se
# emite ningun nivel.
#
# LOS NIVELES: los de retroceso que TradingView pone por defecto trazando del
# minimo al maximo. Nivel 0 = el maximo, 1 = el minimo, y
#   precio = maximo - nivel x (maximo - minimo).
# Las extensiones por defecto (1,618, 2,618, 3,618 y 4,236) quedan por debajo
# del minimo: solo se emiten las que dan un precio positivo. Con el tramo de hoy
# no sale ninguna; con caida=0.5 el minimo queda siempre por debajo de la mitad
# del maximo, asi que como mucho sale el 1,618.
#
# Variables (-v):
#   producto     id de Coinbase
#   salida       "json" (sentencias para /db/execute de rqlite) o "tsv"
#   actualizado  segundos UTC de esta pasada
#   caida        fraccion minima de la caida de un mercado bajista (0.5)
#   dura         dias minimos de un mercado bajista (365)
#
# Salida json, una sentencia por linea: primero el DELETE de todo lo del
# producto y despues un INSERT por nivel. El script las manda juntas en UNA
# transaccion: nunca quedan niveles de dos tramos mezclados ni la tabla a medias.
# Salida tsv, un nivel por linea: nivel precio bajo_ts bajo alto_ts alto caida.
# En stderr, siempre: RESUMEN_FIB ciclo=0|1 ... Si la entrada no cuadra, una
# linea ERROR y sale con 2.

function num(x) { return sprintf("%.15g", x) }
function falla(msg) { printf "ERROR %s\n", msg > "/dev/stderr"; fallo = 1; exit 2 }

BEGIN {
  if (salida == "") salida = "json"
  if (salida != "json" && salida != "tsv") falla("salida debe ser json o tsv")
  if (caida == "") caida = 0.5
  if (dura == "") dura = 365
  caida += 0; dura += 0; actualizado += 0
  if (!(caida > 0 && caida < 1)) falla("caida tiene que estar entre 0 y 1")
  if (!(dura >= 0)) falla("dura no puede ser negativa")
  NIV = split("0 0.236 0.382 0.5 0.618 0.786 1 1.618 2.618 3.618 4.236", nivel, " ")
  hay_ath = 0; ciclo = 0; diarias = 0
}

{
  if (NF != 13) falla("linea " NR " con " NF " campos (se esperan 13)")
  m = $1; t = $2 + 0
  if (m != "1d" && m != "1w") falla("marco desconocido en la linea " NR ": " m)
  if ((m in ult) && t <= ult[m]) falla("entrada desordenada o repetida: " m " " t " despues de " ult[m])
  ult[m] = t
  if (m != "1d") next
  h = $4 + 0; l = $5 + 0; c = $6 + 0
  diarias++; cierre = c
  if (!hay_ath || h > ath) {
    # Maximo nuevo: se cierra la caida del anterior. Si fue un mercado bajista,
    # el ciclo pasa a empezar en su fondo. (El 1e-12 evita que el redondeo deje
    # fuera un cierre justo en el borde, p. ej. 90 x 0,7 = 62,99999...)
    if (hay_ath && en > 0 && c_min <= ath * (1 - caida) * (1 + 1e-12) && t - ath_ts >= dura * 86400) {
      ciclo = 1; bajo = l_min; bajo_ts = l_ts; prof = 1 - c_min / ath
    }
    hay_ath = 1; ath = h; ath_ts = t; en = 0
    next
  }
  # Una vela dentro de la caida que sigue al maximo historico.
  if (en == 0 || c < c_min) c_min = c
  if (en == 0 || l < l_min) { l_min = l; l_ts = t }
  en++
}

END {
  if (fallo) exit 2
  if (!ciclo) {
    printf "RESUMEN_FIB ciclo=0 diarias=%d\n", diarias > "/dev/stderr"
    if (salida == "json") printf "[\"DELETE FROM cripto_fibonacci WHERE producto=?\",\"%s\"]\n", producto
    exit 0
  }
  # El maximo historico de ahora es posterior al fondo (lo supero).
  alto = ath; alto_ts = ath_ts; rango = alto - bajo
  if (salida == "json") printf "[\"DELETE FROM cripto_fibonacci WHERE producto=?\",\"%s\"]\n", producto
  for (i = 1; i <= NIV; i++) {
    nv = nivel[i] + 0
    # Los extremos, exactos (sin el redondeo de alto - (alto - bajo)).
    p = (nv == 0) ? alto : ((nv == 1) ? bajo : alto - nv * rango)
    # Una extension que da 0 o menos no se emite. El margen evita que el
    # redondeo decida en un 0 exacto (309 -> 809: 809 - 1,618 x 500 = +-1e-13).
    if (p <= alto * 1e-12) continue
    if (salida == "json")
      printf "[\"INSERT INTO cripto_fibonacci(producto,tramo,nivel,precio,bajo_ts,bajo,alto_ts,alto,caida,actualizado) VALUES(?,?,?,?,?,?,?,?,?,?)\",\"%s\",\"ciclo\",%s,%s,%d,%s,%d,%s,%s,%d]\n", \
        producto, nivel[i], num(p), bajo_ts, num(bajo), alto_ts, num(alto), num(prof), actualizado
    else
      printf "%s\t%s\t%d\t%s\t%d\t%s\t%s\n", nivel[i], num(p), bajo_ts, num(bajo), alto_ts, num(alto), num(prof)
  }
  # Donde esta el ultimo cierre: 0 en el maximo, 1 en el minimo.
  printf "RESUMEN_FIB ciclo=1 bajo_ts=%d bajo=%s alto_ts=%d alto=%s caida=%s cierre=%s retroceso=%s diarias=%d\n", \
    bajo_ts, num(bajo), alto_ts, num(alto), num(prof), num(cierre), num((alto - cierre) / rango), diarias > "/dev/stderr"
}
