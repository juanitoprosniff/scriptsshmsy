#!/usr/bin/env python3
# encoding: utf-8
# v2ray_manager.py — Proxy WebSocket bridge para V2Ray
# ─────────────────────────────────────────────────────────────
# Actúa como intermediario entre clientes V2Ray (VMess/VLess)
# y el core de V2Ray local. Comparte puertos con wsproxy:
#   Sin TLS : 80, 8080, 8880, 8888  (wsproxy detecta y reenvía aquí)
#   Con TLS : 443, 444, 8443        (stunnel → ssldispatcher → aquí)
#
# Modos SNI soportados:
#   - Default SNI  : bug en Host/SNI header, destino es el VPS
#   - Reverse SNI  : bug/SNI como dirección real de destino
#
# Uso:
#   python3 v2ray_manager.py <puerto> [v2ray_host:puerto]
# Ejemplo:
#   python3 v2ray_manager.py 1080 127.0.0.1:10085
# ─────────────────────────────────────────────────────────────

import socket, threading, select, sys, time

LISTENING_ADDR = '0.0.0.0'

try:
    LISTENING_PORT = int(sys.argv[1])
except:
    LISTENING_PORT = 1080

try:
    DEFAULT_HOST = sys.argv[2]
    if ':' not in DEFAULT_HOST:
        DEFAULT_HOST = '127.0.0.1:10085'
except:
    DEFAULT_HOST = '127.0.0.1:10085'

BUFLEN  = 4096 * 4
TIMEOUT = 60
MSG     = ''
COR     = '<font color="null">'
FTAG    = '</font>'
RESPONSE = ("HTTP/1.1 101 " + str(COR) + str(MSG) + str(FTAG) + "\r\n\r\n").encode()


class Server(threading.Thread):
    def __init__(self, host, port):
        threading.Thread.__init__(self)
        self.running      = False
        self.host         = host
        self.port         = port
        self.threads      = []
        self.threadsLock  = threading.Lock()
        self.logLock      = threading.Lock()

    def run(self):
        self.soc = socket.socket(socket.AF_INET)
        self.soc.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.soc.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        self.soc.settimeout(2)
        self.soc.bind((self.host, self.port))
        self.soc.listen(256)
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
        self.client       = socClient
        self.client_buffer = b''
        self.server       = server
        self.log          = 'V2RAY Connection: ' + str(addr)

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

            # ── DETECCIÓN DE MODO ────────────────────────────
            # V2Ray VMess/VLess sobre WebSocket llega como HTTP GET
            # con cabeceras Upgrade: websocket
            # También puede llegar como tráfico crudo (VLess TCP)
            first = self.client_buffer

            if first.startswith(b'SSH-'):
                # SSH directo — reenviar al backend SSH, no V2Ray
                self.log += ' - SSH-DIRECT (redirigido)'
                self.method_DIRECT('127.0.0.1:22')
                return

            # V2Ray WebSocket: detectar Upgrade: websocket
            if self._is_websocket_upgrade(first):
                self.log += ' - V2RAY-WS'
                hostPort = self.findHeader(first, 'X-Real-Host')
                if hostPort == '':
                    hostPort = DEFAULT_HOST
                self.method_CONNECT(hostPort)

            # V2Ray VMess/VLess TCP puro (tráfico no-HTTP)
            elif not self._is_http(first):
                self.log += ' - V2RAY-TCP'
                self.method_DIRECT(DEFAULT_HOST)

            # HTTP normal — pasar al backend V2Ray igual
            else:
                self.log += ' - V2RAY-HTTP'
                hostPort = self.findHeader(first, 'X-Real-Host')
                if hostPort == '':
                    hostPort = DEFAULT_HOST
                self.method_CONNECT(hostPort)

        except Exception as e:
            self.log += ' - error: ' + str(e)
            self.server.printLog(self.log)
        finally:
            self.close()
            self.server.removeConn(self)

    def _is_http(self, data: bytes) -> bool:
        HTTP_METHODS = (b'GET ', b'POST', b'HEAD', b'OPTI', b'CONN',
                        b'PUT ', b'DELE', b'PATC', b'TRAC')
        prefix = data[:4]
        return any(prefix == m for m in HTTP_METHODS)

    def _is_websocket_upgrade(self, data: bytes) -> bool:
        try:
            text = data.decode('utf-8', errors='ignore').lower()
            return 'upgrade: websocket' in text
        except:
            return False

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
            port = 10085
        if host in ('0.0.0.0', ''):
            host = '127.0.0.1'
        (soc_family, soc_type, proto, _, address) = socket.getaddrinfo(host, port)[0]
        self.target = socket.socket(soc_family, soc_type, proto)
        self.targetClosed = False
        self.target.connect(address)

    def method_DIRECT(self, path):
        self.log += ' - DIRECT ' + path
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
        socs  = [self.client, self.target]
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
    print("\033[0;34m" + "━" * 8 + "\033[1;35m V2RAY BRIDGE \033[0;34m" + "━" * 8)
    print("")
    print("\033[1;33mPUERTO :\033[1;32m " + str(LISTENING_PORT))
    print("\033[1;33mDESTINO:\033[1;32m " + DEFAULT_HOST)
    print("\033[1;33mMODO   :\033[1;32m VMess/VLess WS + TCP")
    print("")
    print("\033[0;34m" + "━" * 10 + "\033[1;32m VPSMANAGER \033[0;34m" + "━" * 11 + "\033[0m")
    print("")

    server = Server(LISTENING_ADDR, LISTENING_PORT)
    server.start()
    print("\033[1;32m[✓] V2Ray Bridge puerto \033[1;37m" + str(LISTENING_PORT) +
          "\033[1;32m → \033[1;37m" + DEFAULT_HOST + "\033[0m")
    print("")

    while True:
        try:
            time.sleep(2)
        except KeyboardInterrupt:
            print('\n\033[1;31mParando V2Ray bridge...\033[0m')
            server.close()
            break


if __name__ == '__main__':
    main()
