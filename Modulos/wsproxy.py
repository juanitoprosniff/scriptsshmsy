#!/usr/bin/env python3
# encoding: utf-8
# wsproxy.py — WebSocket Proxy (Multi-Puerto)
# FIX: soporte multi-puerto (80, 8080, 8880, 8888, 444, etc.)
# FIX: DEFAULT_HOST apunta a 127.0.0.1 (no 0.0.0.0)
# FIX: lógica 403 corregida — PASS vacío acepta cualquier destino
import socket, threading, select, sys, time, getopt

PASS = ''
LISTENING_ADDR = '0.0.0.0'

# ── Puertos a escuchar ──────────────────────────────────────
# Si se pasa argumento se usa ese puerto, si no, multi-puerto
if len(sys.argv) > 1 and sys.argv[1].isdigit():
    PORTS = [int(sys.argv[1])]
else:
    PORTS = [80, 8080, 8880, 8888]

BUFLEN = 4096 * 4
TIMEOUT = 60
MSG = ''
COR = '<font color="null">'
FTAG = '</font>'
DEFAULT_HOST = "127.0.0.1:22"
RESPONSE = ("HTTP/1.1 101 " + str(COR) + str(MSG) + str(FTAG) + "\r\n\r\n").encode()


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
        self.soc.settimeout(2)
        self.soc.bind((self.host, self.port))
        self.soc.listen(0)
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
            hostPort = self.findHeader(self.client_buffer, 'X-Real-Host')
            if hostPort == '':
                hostPort = DEFAULT_HOST

            split = self.findHeader(self.client_buffer, 'X-Split')
            if split != '':
                self.client.recv(BUFLEN)

            if hostPort != '':
                passwd = self.findHeader(self.client_buffer, 'X-Pass')
                if len(PASS) != 0 and passwd == PASS:
                    self.method_CONNECT(hostPort)
                elif len(PASS) != 0 and passwd != PASS:
                    self.client.send(b'HTTP/1.1 400 WrongPass!\r\n\r\n')
                else:
                    # PASS vacío = sin autenticación, conectar directo
                    self.method_CONNECT(hostPort)
            else:
                self.client.send(b'HTTP/1.1 400 NoXRealHost!\r\n\r\n')

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
            port = 80
        # Normalizar: 0.0.0.0 o vacío → 127.0.0.1
        if host in ('0.0.0.0', ''):
            host = '127.0.0.1'
        (soc_family, soc_type, proto, _, address) = socket.getaddrinfo(host, port)[0]
        self.target = socket.socket(soc_family, soc_type, proto)
        self.targetClosed = False
        self.target.connect(address)

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


def print_usage():
    print('Uso: wsproxy.py [puerto]')
    print('     wsproxy.py 80          → solo puerto 80')
    print('     wsproxy.py             → multi-puerto: 80, 8080, 8880, 8888')


def main():
    print("\033[0;34m" + "━" * 8 + "\033[1;32m PROXY WEBSOCKET \033[0;34m" + "━" * 8)
    print("")
    print("\033[1;33mIP:\033[1;32m " + LISTENING_ADDR)
    print("\033[1;33mPUERTOS:\033[1;32m " + ", ".join(str(p) for p in PORTS))
    print("\033[1;33mDEFAULT HOST:\033[1;32m " + DEFAULT_HOST)
    print("")
    print("\033[0;34m" + "━" * 10 + "\033[1;32m VPSMANAGER \033[0;34m" + "━" * 11 + "\033[0m")
    print("")

    servers = []
    for port in PORTS:
        try:
            s = Server(LISTENING_ADDR, port)
            s.start()
            servers.append(s)
            print("\033[1;32m[✓] Escuchando en puerto \033[1;37m" + str(port) + "\033[0m")
        except Exception as e:
            print("\033[1;31m[✗] Error en puerto " + str(port) + ": " + str(e) + "\033[0m")

    print("")
    while True:
        try:
            time.sleep(2)
        except KeyboardInterrupt:
            print('\n\033[1;31mParando...\033[0m')
            for s in servers:
                s.close()
            break


if __name__ == '__main__':
    main()
