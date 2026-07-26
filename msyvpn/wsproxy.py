#!/usr/bin/env python3
# wsproxy.py - Proxy WebSocket/SSH/V2Ray sobre asyncio
# WSPROXY_VERSION: msyvpn-async-1
#
# Un solo proceso, un event loop. Sin hilo por conexion => poca RAM.
# Recibe trafico ya en texto plano (HAProxy termina el TLS) y decide:
#   - SSH directo : el buffer empieza con "SSH-"      -> tunel a SSH
#   - V2Ray       : la ruta HTTP coincide con routes  -> forward crudo
#   - WebSocket   : cualquier otra cosa (payload)      -> responde 101 + tunel
#
# Uso:  python3 wsproxy.py <puerto_listen> [ssh_host:puerto]
# Config opcional de rutas V2Ray en /etc/msyvpn/routes.conf:
#   V2RAY_ENABLED=yes
#   ROUTE=/vless:127.0.0.1:10086
#   ROUTE=/vmess:127.0.0.1:10087
#   ROUTE=/trojan-ws:127.0.0.1:10088

import asyncio
import os
import sys

LISTEN_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8888
DEFAULT_SSH = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1:22"
if ":" not in DEFAULT_SSH:
    DEFAULT_SSH = "127.0.0.1:22"

# Banner: siempre 101 (lo que esperan los payloads) con el nombre de la
# app coloreado. Cambiar el codigo rompia los metodos normales, por eso
# se responde 101 a todo.
APP   = os.environ.get("WSPROXY_NAME", "MSY VPN")
COLOR = os.environ.get("WSPROXY_COLOR", "green")

RESPONSE = ('HTTP/1.1 101 <font color="%s">%s</font>\r\n\r\n'
            % (COLOR, APP)).encode()

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
_routes = []                # lista de (path, host, port)
_routes_mtime = 0
_sem = None                 # se crea dentro del loop (compat 3.6+)


def load_routes():
    """Recarga las rutas V2Ray si el archivo cambio (barato)."""
    global _routes, _routes_mtime
    try:
        mt = os.stat(ROUTES_PATH).st_mtime
    except OSError:
        _routes, _routes_mtime = [], 0
        return
    if mt == _routes_mtime:
        return
    _routes_mtime = mt
    enabled = False
    routes = []
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
        try:
            load_routes()
            try:
                buf = await asyncio.wait_for(cr.read(BUFLEN), HEADER_WAIT)
            except asyncio.TimeoutError:
                buf = b""

            is_ssh = False
            if buf.startswith(b"SSH-"):
                host, port = parse_hp(DEFAULT_SSH)          # SSH directo
                first = buf
                is_ssh = True
            else:
                route = match_route(buf)
                if route:
                    host, port = route                       # V2Ray crudo
                    first = buf
                else:
                    target = find_header(buf, "X-Real-Host") # WebSocket/payload
                    if target:
                        host, port = parse_hp(target)
                    else:
                        host, port = parse_hp(DEFAULT_SSH)
                        is_ssh = True
                    cw.write(RESPONSE)
                    await cw.drain()
                    if find_header(buf, "X-Split"):
                        try:
                            await asyncio.wait_for(cr.read(BUFLEN), HEADER_WAIT)
                        except Exception:
                            pass
                    first = b""

            tr, tw = await asyncio.wait_for(
                asyncio.open_connection(host, port), 10)
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
            for w in (cw, tw):
                try:
                    if w:
                        w.close()
                except Exception:
                    pass


def run():
    # Patron portable (Python 3.6 -> 3.13): sin asyncio.run ni serve_forever
    global _sem
    loop = asyncio.get_event_loop()
    _sem = asyncio.Semaphore(MAX_CONNS)
    load_routes()
    server = loop.run_until_complete(
        asyncio.start_server(handle, "127.0.0.1", LISTEN_PORT))
    print("wsproxy async en 127.0.0.1:%d -> %s" % (LISTEN_PORT, DEFAULT_SSH))
    try:
        loop.run_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.close()
        loop.run_until_complete(server.wait_closed())
        loop.close()


if __name__ == "__main__":
    run()
