#!/usr/bin/env python3
# encoding: utf-8
# ssldispatcher.py — Dispatcher SSL inteligente MULTI-BACKEND
# ─────────────────────────────────────────────────────────────
# Recibe conexiones ya descifradas de Stunnel y detecta
# automáticamente el protocolo:
#   - SSH raw         → Dropbear / OpenSSH
#   - V2Ray VMess/VLess TCP puro → V2Ray core
#   - HTTP / WebSocket (incluye V2Ray WS) → wsproxy / v2ray bridge
#
# Uso:
#   python3 ssldispatcher.py <puerto_listen> <ssh_host:port> <ws_host:port> [v2ray_host:port]
# Ejemplo:
#   python3 ssldispatcher.py 10443 127.0.0.1:143 127.0.0.1:80 127.0.0.1:10085
#
# Flujo:
#   Stunnel (443/444/8443) → ssldispatcher (10443)
#       ├─ SSH raw       → Dropbear/OpenSSH (143 o 22)
#       ├─ V2Ray WS      → wsproxy/v2ray bridge (80/8080/…) *detectado por path*
#       ├─ V2Ray TCP     → V2Ray core (10085)  *tráfico no-HTTP no-SSH*
#       └─ HTTP/WS SSH   → wsproxy (80/8080/…)
# ─────────────────────────────────────────────────────────────

import socket, threading, select, sys, time

LISTENING_ADDR = '0.0.0.0'
BUFLEN         = 4096 * 4
TIMEOUT        = 60

# ── Argumentos ────────────────────────────────────────────────
try:    LISTEN_PORT   = int(sys.argv[1])
except: LISTEN_PORT   = 10443

try:    SSH_BACKEND   = sys.argv[2]   # e.g. 127.0.0.1:143
except: SSH_BACKEND   = '127.0.0.1:143'

try:    WS_BACKEND    = sys.argv[3]   # e.g. 127.0.0.1:80
except: WS_BACKEND    = '127.0.0.1:80'

try:    V2RAY_BACKEND = sys.argv[4]   # e.g. 127.0.0.1:10085
except: V2RAY_BACKEND = ''           # vacío = desactivado

# ── Rutas WebSocket que usa V2Ray (configurables) ─────────────
# El dispatcher detecta si el path del WebSocket upgrade
# corresponde a V2Ray para enviarlo al backend correcto.
V2RAY_WS_PATHS = ['/v2ray', '/vmess', '/vless', '/ws', '/graphql', '/api']

# ── Prefijos HTTP conocidos ───────────────────────────────────
HTTP_METHODS = (
    b'GET ', b'POST', b'HEAD', b'OPTI', b'CONN',
    b'PUT ', b'DELE', b'PATC', b'TRAC',
)


# ─────────────────────────────────────────────────────────────
# Funciones de detección de protocolo
# ─────────────────────────────────────────────────────────────

def is_http(data: bytes) -> bool:
    """Devuelve True si el primer fragmento parece HTTP/WebSocket."""
    if not data:
        return False
    prefix = data[:4]
    return any(prefix.startswith(m[:len(prefix)]) for m in HTTP_METHODS)


def is_websocket_upgrade(data: bytes) -> bool:
    """Devuelve True si es un HTTP Upgrade: websocket."""
    try:
        text = data.decode('utf-8', errors='ignore').lower()
        return 'upgrade: websocket' in text
    except:
        return False


def get_ws_path(data: bytes) -> str:
    """Extrae el path del request HTTP/WS. Ej: 'GET /v2ray HTTP/1.1' → '/v2ray'"""
    try:
        text = data.decode('utf-8', errors='ignore')
        first_line = text.split('\r\n')[0]
        parts = first_line.split(' ')
        if len(parts) >= 2:
            return parts[1].split('?')[0]  # strip query string
    except:
        pass
    return '/'


def is_v2ray_ws(data: bytes) -> bool:
    """True si es WebSocket upgrade hacia una ruta conocida de V2Ray."""
    if not V2RAY_BACKEND:
        return False
    if not is_websocket_upgrade(data):
        return False
    path = get_ws_path(data)
    return any(path.startswith(p) for p in V2RAY_WS_PATHS)


def is_v2ray_tcp(data: bytes) -> bool:
    """
    True si es tráfico VMess/VLess TCP puro (no HTTP, no SSH).
    VMess empieza con 16 bytes de UUID cifrado — no tiene patrón ASCII legible.
    VLess TCP también es tráfico binario.
    """
    if not V2RAY_BACKEND:
        return False
    if not data:
        return False
    if data.startswith(b'SSH-'):
        return False
    if is_http(data):
        return False
    # Si el primer byte no es ASCII imprimible → probablemente V2Ray TCP
    return data[0] < 0x20 or data[0] > 0x7e


def parse_host_port(hostport: str):
    i = hostport.rfind(':')
    if i == -1:
        return hostport, 22
    return hostport[:i], int(hostport[i+1:])


# ─────────────────────────────────────────────────────────────
# Relay bidireccional
# ─────────────────────────────────────────────────────────────

def relay(src, dst, stop_event):
    try:
        while not stop_event.is_set():
            r, _, e = select.select([src, dst], [], [src, dst], 3)
            if e:
                break
            for s in r:
                try:
                    data = s.recv(BUFLEN)
                    if not data:
                        stop_event.set()
                        return
                    other = dst if s is src else src
                    while data:
                        sent = other.send(data)
                        data = data[sent:]
                except Exception:
                    stop_event.set()
                    return
    finally:
        stop_event.set()


# ─────────────────────────────────────────────────────────────
# Handler de conexión
# ─────────────────────────────────────────────────────────────

class DispatchHandler(threading.Thread):
    def __init__(self, client_sock, addr):
        super().__init__(daemon=True)
        self.client  = client_sock
        self.addr    = addr

    def connect_backend(self, hostport: str):
        host, port = parse_host_port(hostport)
        fam, typ, proto, _, address = socket.getaddrinfo(host, port)[0]
        s = socket.socket(fam, typ, proto)
        s.settimeout(10)
        s.connect(address)
        s.settimeout(None)
        return s

    def run(self):
        backend_sock = None
        try:
            # 1. Leer primer bloque
            self.client.settimeout(8)
            try:
                first_data = self.client.recv(BUFLEN)
            except socket.timeout:
                first_data = b''
            self.client.settimeout(None)

            if not first_data:
                return

            # 2. Decidir destino
            if first_data.startswith(b'SSH-'):
                target = SSH_BACKEND
                label  = 'SSH'

            elif is_v2ray_ws(first_data):
                # WebSocket a ruta V2Ray → v2ray bridge (que a su vez va al core)
                target = V2RAY_BACKEND if V2RAY_BACKEND else WS_BACKEND
                label  = 'V2RAY-WS'

            elif is_v2ray_tcp(first_data):
                # Tráfico binario no-HTTP → V2Ray TCP
                target = V2RAY_BACKEND if V2RAY_BACKEND else SSH_BACKEND
                label  = 'V2RAY-TCP'

            elif is_http(first_data):
                # HTTP/WS normal → wsproxy
                target = WS_BACKEND
                label  = 'HTTP/WS'

            else:
                # Fallback: SSH
                target = SSH_BACKEND
                label  = 'SSH-fallback'

            # 3. Conectar backend
            backend_sock = self.connect_backend(target)

            # 4. Enviar el bloque inicial
            backend_sock.sendall(first_data)

            # 5. Relay bidireccional
            stop = threading.Event()
            t = threading.Thread(
                target=relay,
                args=(self.client, backend_sock, stop),
                daemon=True
            )
            t.start()
            while not stop.is_set():
                stop.wait(timeout=1)

        except Exception:
            pass
        finally:
            for s in (self.client, backend_sock):
                if s:
                    try: s.shutdown(socket.SHUT_RDWR)
                    except: pass
                    try: s.close()
                    except: pass


# ─────────────────────────────────────────────────────────────
# Servidor principal
# ─────────────────────────────────────────────────────────────

class DispatchServer(threading.Thread):
    def __init__(self):
        super().__init__(daemon=True)
        self.running = False

    def run(self):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        self.sock.settimeout(2)
        self.sock.bind((LISTENING_ADDR, LISTEN_PORT))
        self.sock.listen(256)
        self.running = True
        while self.running:
            try:
                client, addr = self.sock.accept()
                client.setblocking(True)
                DispatchHandler(client, addr).start()
            except socket.timeout:
                continue
            except Exception:
                break
        self.sock.close()

    def stop(self):
        self.running = False


def main():
    v2ray_status = V2RAY_BACKEND if V2RAY_BACKEND else '\033[1;31mDESACTIVADO'

    print("\033[0;34m" + "━" * 8 + "\033[1;32m SSL DISPATCHER MULTI-BACKEND \033[0;34m" + "━" * 4)
    print("")
    print(f"\033[1;33mPUERTO LISTEN  : \033[1;32m{LISTEN_PORT}")
    print(f"\033[1;33mSSH  BACKEND   : \033[1;32m{SSH_BACKEND}")
    print(f"\033[1;33mWS   BACKEND   : \033[1;32m{WS_BACKEND}")
    print(f"\033[1;33mV2RAY BACKEND  : \033[1;32m{v2ray_status}\033[0m")
    print("")
    print("\033[0;34m" + "━" * 8 + "\033[1;32m VPSMANAGER \033[0;34m" + "━" * 12 + "\033[0m")
    print("")
    print("\033[1;33mDetección automática de protocolo:\033[0m")
    print("\033[1;37m  SSH raw           → \033[1;32m" + SSH_BACKEND + " (SSH directo)")
    print("\033[1;37m  V2Ray WS          → \033[1;35m" + (V2RAY_BACKEND or WS_BACKEND) + " (VMess/VLess WS)")
    print("\033[1;37m  V2Ray TCP         → \033[1;35m" + (V2RAY_BACKEND or "desactivado") + " (VMess/VLess TCP)")
    print("\033[1;37m  HTTP/WebSocket    → \033[1;32m" + WS_BACKEND + " (SSH WebSocket)")
    print(f"\033[1;37m  V2Ray WS paths    : \033[1;35m{', '.join(V2RAY_WS_PATHS)}\033[0m")
    print("")

    srv = DispatchServer()
    srv.start()
    print(f"\033[1;32m[✓] Dispatcher activo en puerto \033[1;37m{LISTEN_PORT}\033[0m\n")

    while True:
        try:
            time.sleep(2)
        except KeyboardInterrupt:
            print('\n\033[1;31mParando dispatcher...\033[0m')
            srv.stop()
            break


if __name__ == '__main__':
    main()
