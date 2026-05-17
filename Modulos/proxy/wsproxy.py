#!/usr/bin/env python3
# encoding: utf-8
# wsproxy.py — WebSocket + SSH Directo Proxy + Ruteo V2Ray multi-protocolo
# WSPROXY_VERSION: msyvpn-v2ray-3
#
# Uso desde conexao:
#   python3 wsproxy.py <puerto> [host:puerto_destino]
#
# MODO TRIPLE:
#   - V2RAY routes → primera línea HTTP coincide con un path V2Ray → forward raw
#                    (V2Ray hace su propio 101 Switching Protocols)
#   - SSH DIRECTO  → buffer empieza con "SSH-" → tunnel sin HTTP
#   - WEBSOCKET    → resto → responde 101 y tunnel a DEFAULT_HOST
#
# Config V2Ray (opcional): /etc/SSHPlus/v2ray-route.conf
#   V2RAY_ENABLED=yes|no
#   # Una línea ROUTE por protocolo:
#   ROUTE=/vless:127.0.0.1:10086
#   ROUTE=/vmess:127.0.0.1:10087
#   ROUTE=/trojan-ws:127.0.0.1:10088
#
# Compatibilidad: también acepta V2RAY_PATH/V2RAY_HOST legacy (1 ruta).

import socket, threading, select, sys, time, os

LISTENING_ADDR = '0.0.0.0'

try:
    LISTENING_PORT = int(sys.argv[1])
except:
    LISTENING_PORT = 80

try:
    DEFAULT_HOST = sys.argv[2]
    if ':' not in DEFAULT_HOST:
        DEFAULT_HOST = '127.0.0.1:22'
except:
    DEFAULT_HOST = '127.0.0.1:22'

BUFLEN = 4096 * 4
TIMEOUT = 60
MSG = ''
COR = '<font color="null">'
FTAG = '</font>'
RESPONSE = ("HTTP/1.1 101 " + str(COR) + str(MSG) + str(FTAG) + "\r\n\r\n").encode()

# ── Configuración V2Ray (leída al inicio y cacheada por mtime) ─
V2RAY_CONF_PATH = '/etc/SSHPlus/v2ray-route.conf'
V2RAY_ENABLED = False
V2RAY_ROUTES = []  # lista de tuplas (path, "host:port"), ordenada por path más largo
_V2RAY_MTIME = 0


def _v2ray_reload():
    """Releer el archivo de ruteo V2Ray si cambió en disco."""
    global V2RAY_ENABLED, V2RAY_ROUTES, _V2RAY_MTIME
    try:
        st = os.stat(V2RAY_CONF_PATH)
    except OSError:
        V2RAY_ENABLED = False
        V2RAY_ROUTES = []
        _V2RAY_MTIME = 0
        return
    if st.st_mtime == _V2RAY_MTIME:
        return
    _V2RAY_MTIME = st.st_mtime
    enabled = False
    routes = []
    # Compat legacy
    legacy_path = None
    legacy_host = None
    try:
        with open(V2RAY_CONF_PATH, 'r') as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#') or '=' not in line:
                    continue
                k, v = line.split('=', 1)
                k = k.strip().upper()
                v = v.strip()
                if k == 'V2RAY_ENABLED':
                    enabled = v.lower() in ('yes', 'true', '1', 'on')
                elif k == 'ROUTE':
                    # Formato: /path:host:port
                    if ':' not in v:
                        continue
                    parts = v.split(':')
                    if len(parts) < 3:
                        continue
                    p = parts[0]
                    if p and not p.startswith('/'):
                        p = '/' + p
                    target = ':'.join(parts[1:])
                    routes.append((p, target))
                elif k == 'V2RAY_PATH':
                    if v and not v.startswith('/'):
                        v = '/' + v
                    legacy_path = v
                elif k == 'V2RAY_HOST':
                    if ':' in v:
                        legacy_host = v
    except OSError:
        pass
    if not routes and legacy_path and legacy_host:
        routes = [(legacy_path, legacy_host)]
    # Ordenar por path más largo primero (para que /vless-grpc no matche /vless)
    routes.sort(key=lambda r: -len(r[0]))
    V2RAY_ENABLED = enabled
    V2RAY_ROUTES = routes


def _match_v2ray_route(buf):
    """Devuelve (host_port, path_matched) si la request matchea alguna ruta V2Ray."""
    if not V2RAY_ENABLED or not buf or not V2RAY_ROUTES:
        return None
    try:
        head = buf[:512].decode('latin-1', errors='ignore')
    except Exception:
        return None
    eol = head.find('\r\n')
    first = head[:eol] if eol != -1 else head
    parts = first.split(' ')
    if len(parts) < 2:
        return None
    method, path = parts[0].upper(), parts[1]
    if method not in ('GET', 'POST', 'CONNECT', 'OPTIONS', 'HEAD'):
        return None
    for p, target in V2RAY_ROUTES:
        if path == p or path.startswith(p + '?') or path.startswith(p + '/'):
            return (target, p)
    return None


class Server(threading.Thread):
    def __init__(self, host, port):
        threading.Thread.__init__(self)
        self.running = False
        self.host = host
        self.port = port
        self.threads = []
        self.threadsLock = threading.Lock()
        self.logLock = threading.Lock()

    def run(self):
        self.soc = socket.socket(socket.AF_INET)
        self.soc.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.soc.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        self.soc.settimeout(2)
        self.soc.bind((self.host, self.port))
        self.soc.listen(128)
        self.running = True
        try:
            while self.running:
                try:
                    c, addr = self.soc.accept()
                    c.setblocking(1)
                except socket.timeout:
                    continue
                conn = ConnectionHandler(c, self, addr)
                conn.start()
                self.addConn(conn)
        finally:
            self.running = False
            self.soc.close()

    def printLog(self, log):
        self.logLock.acquire()
        print(log)
        self.logLock.release()

    def addConn(self, conn):
        try:
            self.threadsLock.acquire()
            if self.running:
                self.threads.append(conn)
        finally:
            self.threadsLock.release()

    def removeConn(self, conn):
        try:
            self.threadsLock.acquire()
            self.threads.remove(conn)
        finally:
            self.threadsLock.release()

    def close(self):
        try:
            self.running = False
            self.threadsLock.acquire()
            threads = list(self.threads)
            for c in threads:
                c.close()
        finally:
            self.threadsLock.release()


class ConnectionHandler(threading.Thread):
    def __init__(self, socClient, server, addr):
        threading.Thread.__init__(self)
        self.clientClosed = False
        self.targetClosed = True
        self.client = socClient
        self.client_buffer = b''
        self.server = server
        self.log = 'Connection: ' + str(addr)

    def close(self):
        try:
            if not self.clientClosed:
                self.client.shutdown(socket.SHUT_RDWR)
                self.client.close()
        except:
            pass
        finally:
            self.clientClosed = True
        try:
            if not self.targetClosed:
                self.target.shutdown(socket.SHUT_RDWR)
                self.target.close()
        except:
            pass
        finally:
            self.targetClosed = True

    def run(self):
        try:
            self.client_buffer = self.client.recv(BUFLEN)

            # Releer config V2Ray si cambió (barato: stat + abrir si mtime cambió)
            _v2ray_reload()

            # ── DETECCIÓN DE MODO ────────────────────────────────
            # 1) SSH directo: banner "SSH-..."   → tunnel puro
            # 2) V2Ray WS   : path coincide ruta → forward raw a V2Ray
            # 3) WebSocket  : resto              → respuesta 101 + tunnel
            v2_match = _match_v2ray_route(self.client_buffer)
            if self.client_buffer.startswith(b'SSH-'):
                self.log += ' - SSH-DIRECT'
                self.method_DIRECT(DEFAULT_HOST)
            elif v2_match is not None:
                target, path_matched = v2_match
                self.log += ' - V2RAY ' + path_matched
                self.method_FORWARD(target)
            else:
                # MODO WEBSOCKET/HTTP — comportamiento original
                hostPort = self.findHeader(self.client_buffer, 'X-Real-Host')
                if hostPort == '':
                    hostPort = DEFAULT_HOST

                split = self.findHeader(self.client_buffer, 'X-Split')
                if split != '':
                    self.client.recv(BUFLEN)

                if hostPort != '':
                    self.method_CONNECT(hostPort)
                else:
                    self.client.send(b'HTTP/1.1 400 NoHost!\r\n\r\n')

        except Exception as e:
            self.log += ' - error: ' + str(e)
            self.server.printLog(self.log)
        finally:
            self.close()
            self.server.removeConn(self)

    def findHeader(self, head, header):
        if isinstance(head, bytes):
            head = head.decode('utf-8', errors='ignore')
        aux = head.find(header + ': ')
        if aux == -1:
            return ''
        aux = head.find(':', aux)
        head = head[aux + 2:]
        aux = head.find('\r\n')
        if aux == -1:
            return ''
        return head[:aux]

    def connect_target(self, host):
        i = host.find(':')
        if i != -1:
            port = int(host[i + 1:])
            host = host[:i]
        else:
            port = 22
        if host in ('0.0.0.0', ''):
            host = '127.0.0.1'
        (soc_family, soc_type, proto, _, address) = socket.getaddrinfo(host, port)[0]
        self.target = socket.socket(soc_family, soc_type, proto)
        self.targetClosed = False
        self.target.connect(address)

    def method_DIRECT(self, path):
        # SSH directo: conectar al backend y reenviar el buffer SSH
        # que ya recibimos (el banner del cliente) sin respuesta HTTP
        self.log += ' - DIRECT ' + path
        self.connect_target(path)
        # Reenviar el banner SSH que ya leímos al backend
        self.target.sendall(self.client_buffer)
        self.client_buffer = b''
        self.server.printLog(self.log)
        self.doCONNECT()

    def method_FORWARD(self, path):
        # V2Ray: NO enviamos 101 — V2Ray habla WebSocket directamente.
        # Solo reenviamos el handshake completo y dejamos que V2Ray responda.
        self.log += ' - FORWARD ' + path
        self.connect_target(path)
        self.target.sendall(self.client_buffer)
        self.client_buffer = b''
        self.server.printLog(self.log)
        self.doCONNECT()

    def method_CONNECT(self, path):
        self.log += ' - CONNECT ' + path
        self.connect_target(path)
        self.client.sendall(RESPONSE)
        self.client_buffer = b''
        self.server.printLog(self.log)
        self.doCONNECT()

    def doCONNECT(self):
        socs = [self.client, self.target]
        count = 0
        error = False
        while True:
            count += 1
            (recv, _, err) = select.select(socs, [], socs, 3)
            if err:
                error = True
            if recv:
                for in_ in recv:
                    try:
                        data = in_.recv(BUFLEN)
                        if data:
                            if in_ is self.target:
                                self.client.send(data)
                            else:
                                while data:
                                    byte = self.target.send(data)
                                    data = data[byte:]
                            count = 0
                        else:
                            break
                    except:
                        error = True
                        break
            if count == TIMEOUT:
                error = True
            if error:
                break


def main():
    _v2ray_reload()
    print("\033[0;34m" + "━" * 8 + "\033[1;32m PROXY WEBSOCKET \033[0;34m" + "━" * 8)
    print("")
    print("\033[1;33mPUERTO :\033[1;32m " + str(LISTENING_PORT))
    print("\033[1;33mDESTINO:\033[1;32m " + DEFAULT_HOST)
    if V2RAY_ENABLED and V2RAY_ROUTES:
        for p, t in V2RAY_ROUTES:
            print("\033[1;33mV2RAY  :\033[1;32m " + p + " → " + t)
        print("\033[1;33mMODO   :\033[1;32m TRIPLE (SSH directo + WebSocket + V2Ray)")
    else:
        print("\033[1;33mMODO   :\033[1;32m DUAL (SSH directo + WebSocket)")
    print("")
    print("\033[0;34m" + "━" * 10 + "\033[1;32m VPSMANAGER \033[0;34m" + "━" * 11 + "\033[0m")
    print("")

    server = Server(LISTENING_ADDR, LISTENING_PORT)
    server.start()
    print("\033[1;32m[✓] Puerto \033[1;37m" + str(LISTENING_PORT) +
          "\033[1;32m → \033[1;37m" + DEFAULT_HOST + "\033[0m")
    print("")

    while True:
        try:
            time.sleep(2)
        except KeyboardInterrupt:
            print('\n\033[1;31mParando...\033[0m')
            server.close()
            break


if __name__ == '__main__':
    main()
