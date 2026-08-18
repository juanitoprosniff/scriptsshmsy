#!/usr/bin/env python3
# wsproxy.py - Proxy WebSocket/SSH/V2Ray sobre asyncio
# WSPROXY_VERSION: msyvpn-async-2
#
# Un solo proceso, un event loop. Sin hilo por conexion => poca RAM.
# Recibe trafico ya en texto plano (HAProxy termina el TLS) y decide:
#   - SSH directo : el buffer empieza con "SSH-"      -> tunel a SSH
#   - SOCKS5      : el buffer es un saludo SOCKS5     -> tunel al socks5
#   - V2Ray       : la ruta HTTP coincide con routes  -> forward crudo
#   - WebSocket   : cualquier otra cosa (payload)      -> responde 101 + tunel
#
# Uso:  python3 wsproxy.py <puerto_listen> [ssh_host:puerto]
# Config opcional de rutas V2Ray en /etc/msyvpn/routes.conf:
#   V2RAY_ENABLED=yes
#   ROUTE=/vless:127.0.0.1:10086
#   ROUTE=/vmess:127.0.0.1:10087
#   ROUTE=/trojan-ws:127.0.0.1:10088
#   SOCKS5=127.0.0.1:1080

import asyncio
import os
import sys

LISTEN_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8888
DEFAULT_SSH = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1:22"
if ":" not in DEFAULT_SSH:
    DEFAULT_SSH = "127.0.0.1:22"

# Respuesta al payload. Hay apps que solo conectan si reciben 101 y otras
# que solo conectan con 200, asi que NO se puede fijar una sola. Se elige
# segun lo que pide el cliente en su propia peticion:
#   - metodo CONNECT              -> 200 (es lo que define un proxy HTTP)
#   - la peticion empieza por HTTP/ -> 200 (payload de "respuesta falsa")
#   - hay cabecera Upgrade        -> 101 (handshake WebSocket)
#   - resto                       -> WSPROXY_CODE (por defecto 101)
# Asi los dos tipos de payload conviven en el mismo puerto.
APP   = os.environ.get("WSPROXY_NAME", "MSY VPN")
COLOR = os.environ.get("WSPROXY_COLOR", "green")
try:
    DEFAULT_CODE = int(os.environ.get("WSPROXY_CODE", "101"))
except ValueError:
    DEFAULT_CODE = 101

_REASON = {101: "Switching Protocols", 200: "Connection established"}


def _resp(code):
    return ('HTTP/1.1 %d <font color="%s">%s</font>\r\n\r\n'
            % (code, COLOR, APP)).encode()


RESP_101 = _resp(101)
RESP_200 = _resp(200)
RESP_DEF = _resp(DEFAULT_CODE)


def pick_response(buf):
    """Elige 101 o 200 segun lo que espera el cliente."""
    if not buf:
        return RESP_DEF
    head = buf[:512].upper()
    first = head.split(b"\r\n", 1)[0]
    # Payload que empieza con una linea de respuesta falsa: "HTTP/1.1 200"
    if first.startswith(b"HTTP/"):
        return RESP_200 if b"200" in first else RESP_101
    # CONNECT es un proxy HTTP clasico: espera 200
    if first.startswith(b"CONNECT"):
        return RESP_200
    # Handshake WebSocket explicito: espera 101
    if b"UPGRADE:" in head or b"WEBSOCKET" in head:
        return RESP_101
    return RESP_DEF

# Linea informativa que se envia ANTES del banner del servidor SSH.
# El RFC 4253 permite lineas previas al "SSH-..." y los clientes las
# ignoran, asi que la app muestra este texto sin romper el handshake.
# Guarda: si empieza por "SSH-" el cliente la tomaria como la version
# real del servidor y el intercambio de claves fallaria -> se descarta.
SSH_BANNER = os.environ.get("WSPROXY_SSH_BANNER", "").strip()
if SSH_BANNER.upper().startswith("SSH-"):
    SSH_BANNER = SSH_BANNER[4:].lstrip("-") or "MSY_VPN_SCRIPT"

BUFLEN = 65536
IDLE_TIMEOUT = 600          # segundos sin datos antes de cerrar
MAX_CONNS = 8000            # tope de conexiones simultaneas
HEADER_WAIT = 8             # segundos para leer la primera peticion

ROUTES_PATH = "/etc/msyvpn/routes.conf"
STATS_DIR = "/etc/msyvpn/data"
STATS_EVERY = 5             # segundos entre escrituras del archivo de stats

# Un proceso Python usa un solo nucleo. Con cientos de usuarios eso satura
# ese nucleo, asi que se levantan varios procesos que comparten el puerto
# con SO_REUSEPORT y el kernel reparte las conexiones entre ellos.
try:
    WORKERS = int(os.environ.get("WSPROXY_WORKERS", "0"))
except ValueError:
    WORKERS = 0
if WORKERS <= 0:
    WORKERS = min(os.cpu_count() or 1, 8)
_WORKER_ID = 0

_routes = []                # lista de (path, host, port)
_routes_mtime = 0
_ovpn = []                  # backends OpenVPN TCP [(host, port), ...]
_ovpn_rr = 0                # reparto por turnos entre instancias
_socks5 = None              # backend SOCKS5 (host, port) o None
_sem = None                 # se crea dentro del loop (compat 3.6+)

# Conteo exacto: por categoria, {ip: nº de conexiones abiertas}
_live = {"ssh": {}, "v2ray": {}, "ovpn": {}, "socks5": {}}


def _track(cat, ip, delta):
    """Suma/resta una conexion de esa IP en la categoria indicada."""
    if not ip:
        return
    d = _live.get(cat)
    if d is None:
        return
    n = d.get(ip, 0) + delta
    if n > 0:
        d[ip] = n
    else:
        d.pop(ip, None)


def read_proxy_header(buf):
    """Extrae la IP real del header PROXY (v1) que envia HAProxy.

    Devuelve (ip, resto_del_buffer). Si no hay header, (None, buf), asi
    que el proxy sigue funcionando aunque HAProxy no lo mande.
    """
    if not buf.startswith(b"PROXY "):
        return None, buf
    i = buf.find(b"\r\n")
    if i == -1:
        return None, buf
    parts = buf[:i].split(b" ")
    rest = buf[i + 2:]
    if len(parts) >= 3:
        try:
            return parts[2].decode("latin-1"), rest
        except Exception:
            return None, rest
    return None, rest


def is_openvpn(buf):
    """Detecta el primer paquete de OpenVPN sobre TCP.

    Formato: 2 bytes de longitud (big-endian) + 1 byte de opcode. El
    opcode son los 5 bits altos; los handshakes de cliente son
    HARD_RESET_CLIENT V1/V2/V3 = 1, 7 y 10.
    """
    if len(buf) < 3 or buf[0] != 0:
        return False
    ln = (buf[0] << 8) | buf[1]
    if ln < 10 or ln > 1600:
        return False
    return (buf[2] >> 3) in (1, 7, 10)


def is_socks5(buf):
    """Detecta el saludo SOCKS5 del cliente (RFC 1928).

    Formato: 0x05 <nmetodos> <metodo>...  — nada mas, el cliente se calla y
    espera respuesta. Por eso se exige la longitud EXACTA: cualquier otra cosa
    que empiece por 0x05 (un payload binario, un trozo de TLS) no cuadra y no
    se confunde con esto.

    No choca con los demas protocolos: los payloads son texto ASCII, el banner
    SSH empieza por "SSH-" y el primer byte de OpenVPN sobre TCP es 0x00.
    """
    if len(buf) < 3 or buf[0] != 5:
        return False
    n = buf[1]
    if n < 1:
        return False
    return len(buf) == 2 + n


def ovpn_backend():
    """Devuelve la siguiente instancia OpenVPN (reparto por turnos).

    OpenVPN es de un solo hilo por proceso, asi que repartir entre varias
    instancias es lo que permite aprovechar todos los nucleos.
    """
    global _ovpn_rr
    if not _ovpn:
        return None
    b = _ovpn[_ovpn_rr % len(_ovpn)]
    _ovpn_rr += 1
    return b


def load_routes():
    """Recarga las rutas V2Ray si el archivo cambio (barato)."""
    global _routes, _routes_mtime, _ovpn, _socks5
    try:
        mt = os.stat(ROUTES_PATH).st_mtime
    except OSError:
        _routes, _routes_mtime, _ovpn, _socks5 = [], 0, [], None
        return
    if mt == _routes_mtime:
        return
    _routes_mtime = mt
    enabled = False
    routes = []
    ovpn = []
    socks5 = None
    try:
        with open(ROUTES_PATH) as f:
            for ln in f:
                ln = ln.strip()
                if not ln or ln.startswith("#") or "=" not in ln:
                    continue
                k, v = ln.split("=", 1)
                k, v = k.strip().upper(), v.strip()
                if k == "V2RAY_ENABLED":
                    enabled = v.lower() in ("yes", "1", "true", "on")
                elif k == "OPENVPN":
                    for item in v.split(","):
                        item = item.strip()
                        if ":" in item:
                            h, _, pt = item.rpartition(":")
                            try:
                                ovpn.append((h, int(pt)))
                            except ValueError:
                                pass
                elif k == "SOCKS5":
                    if ":" in v:
                        h, _, pt = v.rpartition(":")
                        try:
                            socks5 = (h or "127.0.0.1", int(pt))
                        except ValueError:
                            socks5 = None
                elif k == "ROUTE":
                    parts = v.split(":")
                    if len(parts) < 3:
                        continue
                    p = parts[0]
                    if p and not p.startswith("/"):
                        p = "/" + p
                    routes.append((p, parts[1], int(parts[2])))
    except OSError:
        pass
    routes.sort(key=lambda r: -len(r[0]))     # ruta mas larga primero
    _routes = routes if enabled else []
    _ovpn = ovpn
    _socks5 = socks5


def match_route(buf):
    """Devuelve (host, port) si la primera linea HTTP coincide con una ruta."""
    if not _routes:
        return None
    try:
        head = buf[:512].decode("latin-1", "ignore")
    except Exception:
        return None
    first = head.split("\r\n", 1)[0].split(" ")
    if len(first) < 2 or first[0].upper() not in (
            "GET", "POST", "PUT", "HEAD", "OPTIONS", "CONNECT"):
        return None
    path = first[1]
    for p, host, port in _routes:
        if path == p or path.startswith(p + "?") or path.startswith(p + "/"):
            return (host, port)
    return None


def find_header(buf, name):
    try:
        text = buf.decode("latin-1", "ignore")
    except Exception:
        return ""
    key = name + ": "
    i = text.find(key)
    if i == -1:
        return ""
    j = text.find("\r\n", i)
    return text[i + len(key):j] if j != -1 else ""


def parse_hp(hp):
    if ":" in hp:
        h, p = hp.rsplit(":", 1)
        return (h or "127.0.0.1"), int(p)
    return hp, 22


async def pipe(reader, writer):
    """Copia un sentido del tunel hasta EOF o error."""
    try:
        while True:
            data = await asyncio.wait_for(reader.read(BUFLEN), IDLE_TIMEOUT)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except Exception:
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def relay(cr, cw, tr, tw):
    await asyncio.gather(pipe(cr, tw), pipe(tr, cw))


async def handle(cr, cw):
    if _sem.locked():
        cw.close()
        return
    async with _sem:
        tw = None
        cat = ip = None
        tracked = False
        try:
            load_routes()
            try:
                buf = await asyncio.wait_for(cr.read(BUFLEN), HEADER_WAIT)
            except asyncio.TimeoutError:
                buf = b""

            # IP real del cliente (HAProxy la envia con send-proxy)
            ip, buf = read_proxy_header(buf)
            if not buf:
                try:
                    buf = await asyncio.wait_for(cr.read(BUFLEN), HEADER_WAIT)
                except asyncio.TimeoutError:
                    buf = b""

            is_ssh = False
            if buf.startswith(b"SSH-"):
                host, port = parse_hp(DEFAULT_SSH)          # SSH directo
                first = buf
                is_ssh = True
            elif _socks5 and is_socks5(buf):
                # SOCKS5 sin payload. Es el caso de los modos "SSL con SNI" y
                # "directo sin payload" de la app: ahi el disfraz es el propio
                # TLS y el cliente habla SOCKS5 desde el primer byte, sin
                # cabecera HTTP que responder.
                host, port = _socks5
                first = buf
                cat = "socks5"
            elif _ovpn and is_openvpn(buf):
                host, port = ovpn_backend()                 # OpenVPN directo
                first = buf
                cat = "ovpn"
            else:
                route = match_route(buf)
                if route:
                    host, port = route                       # V2Ray crudo
                    first = buf
                    cat = "v2ray"
                else:
                    target = find_header(buf, "X-Real-Host") # WebSocket/payload
                    cw.write(pick_response(buf))
                    await cw.drain()
                    if find_header(buf, "X-Split"):
                        try:
                            await asyncio.wait_for(cr.read(BUFLEN), HEADER_WAIT)
                        except Exception:
                            pass
                    first = b""
                    if target:
                        host, port = parse_hp(target)
                    elif _ovpn or _socks5:
                        # Con OpenVPN o SOCKS5 activos hay que mirar el primer
                        # paquete del tunel para saber que habla el cliente:
                        # asi los tres conviven en el mismo puerto y con el
                        # mismo payload, que es justo lo que se busca.
                        try:
                            first = await asyncio.wait_for(cr.read(BUFLEN), 3)
                        except asyncio.TimeoutError:
                            first = b""
                        if _socks5 and is_socks5(first):
                            host, port = _socks5
                            cat = "socks5"
                        elif _ovpn and is_openvpn(first):
                            host, port = ovpn_backend()
                            cat = "ovpn"
                        else:
                            host, port = parse_hp(DEFAULT_SSH)
                            is_ssh = True
                    else:
                        host, port = parse_hp(DEFAULT_SSH)
                        is_ssh = True

            if cat is None and is_ssh:
                cat = "ssh"

            tr, tw = await asyncio.wait_for(
                asyncio.open_connection(host, port), 10)
            _track(cat, ip, 1)
            tracked = True
            if first:
                tw.write(first)
                await tw.drain()
            if is_ssh and SSH_BANNER:
                cw.write(SSH_BANNER.encode() + b"\r\n")
                await cw.drain()
            await relay(cr, cw, tr, tw)
        except Exception:
            pass
        finally:
            if tracked:
                _track(cat, ip, -1)
            for w in (cw, tw):
                try:
                    if w:
                        w.close()
                except Exception:
                    pass


async def stats_writer():
    """Escribe las IPs vivas de este worker: '<categoria> <ip> <conns>'.

    Cada worker usa su propio archivo; el menu junta todos y cuenta las
    IPs unicas, asi el total es correcto aunque haya varios procesos.
    """
    path = os.path.join(STATS_DIR, "stats.%d" % _WORKER_ID)
    tmp = path + ".tmp"
    while True:
        await asyncio.sleep(STATS_EVERY)
        try:
            lines = []
            for cat, d in _live.items():
                for ip, n in d.items():
                    lines.append("%s %s %d" % (cat, ip, n))
            os.makedirs(STATS_DIR, exist_ok=True)
            with open(tmp, "w") as f:
                f.write("\n".join(lines) + ("\n" if lines else ""))
            os.rename(tmp, path)
        except Exception:
            pass


def serve():
    # Patron portable (Python 3.6 -> 3.13): sin asyncio.run ni serve_forever
    global _sem
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    _sem = asyncio.Semaphore(MAX_CONNS)
    load_routes()
    loop.create_task(stats_writer())
    server = loop.run_until_complete(asyncio.start_server(
        handle, "127.0.0.1", LISTEN_PORT, reuse_port=True))
    try:
        loop.run_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.close()
        loop.run_until_complete(server.wait_closed())
        loop.close()


def run():
    global _WORKER_ID
    # Limpiar stats de ejecuciones anteriores
    try:
        for f in os.listdir(STATS_DIR):
            if f.startswith("stats."):
                os.remove(os.path.join(STATS_DIR, f))
    except Exception:
        pass
    print("wsproxy async en 127.0.0.1:%d -> %s (%d procesos)"
          % (LISTEN_PORT, DEFAULT_SSH, WORKERS))
    children = []
    for i in range(1, WORKERS):
        try:
            pid = os.fork()
        except Exception:
            break
        if pid == 0:                 # proceso hijo
            _WORKER_ID = i
            try:
                serve()
            finally:
                os._exit(0)
        children.append(pid)
    try:
        serve()                      # el padre tambien atiende
    finally:
        for pid in children:
            try:
                os.kill(pid, 15)
            except Exception:
                pass


if __name__ == "__main__":
    run()
