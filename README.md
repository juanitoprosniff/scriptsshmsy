# MSYVPN

Script VPN sencillo y liviano para instalar protocolos VPN en un VPS
(Ubuntu 18–26 / Debian 10–12, server y minimal).

## Arquitectura

Un solo camino de entrada, liviano y con auto-reinicio:

```
Cliente ─► HAProxy (puertos publicos, TLS)  ─►  wsproxy (async, 127.0.0.1:8888)
                                                   ├─ "SSH-..."      ► OpenSSH :22
                                                   ├─ saludo SOCKS5  ► SOCKS5  :1080
                                                   ├─ ruta /vless…   ► V2Ray  :10086+
                                                   ├─ handshake OVPN ► OpenVPN :1195+
                                                   └─ WebSocket/pay. ► segun el 1er paquete
```

SSH, SOCKS5 y OpenVPN comparten **los mismos puertos y los mismos payloads**: el
wsproxy mira el primer paquete del tunel y decide. No hay que abrir nada nuevo
ni configurar puertos distintos por protocolo.

- **HAProxy** termina el TLS y reparte todos los puertos (1 proceso en C).
- **wsproxy** (asyncio, 1 proceso, sin hilo por conexion) detecta SSH / SOCKS5 / OpenVPN / WebSocket / V2Ray.
- Todo corre bajo **systemd** con `Restart=always`, asi que ningun puerto se "muere".
- **OpenSSH** afinado + **BBR** para buen ping. **BadVPN** e **Hysteria** para UDP.

Sin stunnel, sin dispatcher, sin nginx: menos saltos, menos RAM.

## Instalacion

```bash
git clone https://github.com/juanitoprosniff/scriptsshmsy
cd scriptsshmsy/msyvpn
bash install.sh
```

Al terminar, escribe `menu` para administrar.

## Modulos (carpeta `msyvpn/`)

| Archivo       | Funcion                                   |
|---------------|-------------------------------------------|
| `install.sh`  | Instalador (activar todo automatico)      |
| `lib.sh`      | Funciones comunes centralizadas           |
| `menu`        | Menu principal                            |
| `proxy.sh`    | HAProxy + wsproxy + certificado           |
| `wsproxy.py`  | Proxy WebSocket/SSH/SOCKS5/OpenVPN/V2Ray (asyncio) |
| `socks5.sh`   | SOCKS5 (hev-socks5-server), cuentas compartidas con SSH |
| `v2ray.sh`    | Xray: VLESS (auto) + VMess/Trojan/SS/Reality/xhttp |
| `slowdns.sh`  | Tunel DNS SlowDNS                         |
| `hysteria.sh` | UDP Hysteria v1 y v2 (coexisten)          |
| `users.sh`    | Crear y administrar cuentas               |
| `monitor.sh`  | Usuarios online, ancho de banda, speedtest|
| `update.sh`   | Actualizar / desinstalar                  |
| `bin/`        | Binarios (badvpn-udpgw, dns-server, hev-socks5-server) |

## SOCKS5

Alternativa al SSH por el mismo camino: mismos puertos, mismo payload, mismo
SNI y **las mismas cuentas** (el auth se regenera solo al crear, borrar o
cambiar la contrasena de un usuario, y se recarga en caliente con `SIGUSR1`).

Frente al SSH gana en dos cosas: no lleva la capa de cifrado SSH por encima, y
saca **UDP de verdad encapsulado en el propio TCP** (juegos y llamadas) sin
depender de `badvpn-udpgw`, que ademas tiene tope de flujos por cliente.

En la app: modo Custom → Ajustes → **Motor de conexion** → SOCKS5.

El binario se instala desde `bin/hev-socks5-server-<arch>` si existe y, si no,
se compila desde el codigo fuente en la propia VPS.

## Actualizar

Desde el panel: `menu` → **8) Mantenimiento** → **1) Actualizar script**.
Descarga la ultima version, detiene los servicios, reinstala y arranca de
nuevo conservando usuarios, claves y certificados (hace respaldo en `/root/`).
