#!/usr/bin/env python3
# encoding: utf-8
# ssldispatcher.py — Dispatcher SSL inteligente
# ─────────────────────────────────────────────────────────────
# Recibe conexiones ya descifradas de Stunnel y detecta
# automáticamente si es SSH directo o HTTP/WebSocket,
# enrutando a Dropbear o al wsproxy según corresponda.
#
# Uso:
#   python3 ssldispatcher.py <puerto_listen> <ssh_host:port> <ws_host:port>
# Ejemplo:
#   python3 ssldispatcher.py 10443 127.0.0.1:143 127.0.0.1:80
#
# Flujo:
#   Stunnel (443/444/8443) → ssldispatcher (10443)
#       ├─ SSH raw   → Dropbear/OpenSSH (143 o 22)
#       └─ HTTP/WS   → wsproxy (80/8080/…)
# ─────────────────────────────────────────────────────────────

import socket, threading, select, sys, time

LISTENING_ADDR = '0.0.0.0'
BUFLEN         = 4096 * 4
TIMEOUT        = 60       # segundos sin datos → cerrar

# ── Argumentos ────────────────────────────────────────────────
try:    LISTEN_PORT  = int(sys.argv[1])
except: LISTEN_PORT  = 10443

try:    SSH_BACKEND  = sys.argv[2]   # e.g. 127.0.0.1:143
except: SSH_BACKEND  = '127.0.0.1:143'

try:    WS_BACKEND   = sys.argv[3]   # e.g. 127.0.0.1:80
except: WS_BACKEND   = '127.0.0.1:80'

# ── Prefijos de protocolo HTTP (métodos más comunes) ──────────
HTTP_METHODS = (
    b'GET ', b'POST', b'HEAD', b'OPTI', b'CONN',
    b'PUT ', b'DELE', b'PATC', b'TRAC',
)


def is_http(data: bytes) -> bool:
    """Devuelve True si el primer fragmento parece HTTP/WebSocket."""
    if not data:
        return False
    prefix = data[:4]
    return any(prefix.startswith(m[:len(prefix)]) for m in HTTP_METHODS)


def parse_host_port(hostport: str):
    i = hostport.rfind(':')
    if i == -1:
        return hostport, 22
    return hostport[:i], int(hostport[i+1:])


def relay(src, dst, stop_event):
    """Hilo bidireccional: reenvía datos entre dos sockets."""
    try:
        while not stop_event.is_set():
            r, _, e = select.select([src, dst], [], [src, dst], 3)
            if e:
                break
            for s in r:
                try:
                    data = s.recv(BUFLEN)
                    if not data:
                        stop_event.set(); return
                    other = dst if s is src else src
                    # envío completo con loop
                    while data:
                        sent = other.send(data)
                        data = data[sent:]
                except Exception:
                    stop_event.set(); return
    finally:
        stop_event.set()


class DispatchHandler(threading.Thread):
    """Maneja una conexión entrante: detecta protocolo y hace relay."""

    def __init__(self, client_sock, addr):
        super().__init__(daemon=True)
        self.client  = client_sock
        self.addr    = addr
        self.backend = None

    # ── Conectar al backend elegido ───────────────────────────
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
            # 1. Leer el primer bloque sin consumir demasiado
            self.client.settimeout(8)
            try:
                first_data = self.client.recv(BUFLEN)
            except socket.timeout:
                first_data = b''
            self.client.settimeout(None)

            if not first_data:
                return

            # 2. Decidir destino según contenido
            if is_http(first_data):
                target = WS_BACKEND
                label  = 'HTTP/WS'
            else:
                target = SSH_BACKEND
                label  = 'SSH'

            # 3. Conectar al backend
            backend_sock = self.connect_backend(target)

            # 4. Enviar el bloque inicial ya leído
            backend_sock.sendall(first_data)

            # 5. Relay bidireccional
            stop = threading.Event()
            t = threading.Thread(
                target=relay,
                args=(self.client, backend_sock, stop),
                daemon=True
            )
            t.start()

            # Esperar hasta que el relay termine
            while not stop.is_set():
                stop.wait(timeout=1)

        except Exception as e:
            pass
        finally:
            for s in (self.client, backend_sock):
                if s:
                    try: s.shutdown(socket.SHUT_RDWR)
                    except: pass
                    try: s.close()
                    except: pass


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
    print("\033[0;34m" + "━" * 8 + "\033[1;32m SSL DISPATCHER \033[0;34m" + "━" * 8)
    print("")
    print(f"\033[1;33mPUERTO LISTEN : \033[1;32m{LISTEN_PORT}")
    print(f"\033[1;33mSSH  BACKEND  : \033[1;32m{SSH_BACKEND}")
    print(f"\033[1;33mWS   BACKEND  : \033[1;32m{WS_BACKEND}")
    print("")
    print("\033[0;34m" + "━" * 8 + "\033[1;32m VPSMANAGER \033[0;34m" + "━" * 12 + "\033[0m")
    print("")
    print("\033[1;33mDetección automática de protocolo:\033[0m")
    print("\033[1;37m  HTTP/GET/CONNECT → \033[1;32m" + WS_BACKEND + " (WebSocket/HTTP)")
    print("\033[1;37m  SSH raw          → \033[1;32m" + SSH_BACKEND + " (SSH directo)")
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
