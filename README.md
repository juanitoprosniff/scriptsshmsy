# MSYVPN

Script VPN sencillo y liviano para instalar protocolos VPN en un VPS
(Ubuntu 18–26 / Debian 10–12, server y minimal).

## Arquitectura

Un solo camino de entrada, liviano y con auto-reinicio:

```
Cliente ─► HAProxy (puertos publicos, TLS)  ─►  wsproxy (async, 127.0.0.1:8888)
                                                   ├─ "SSH-..."      ► OpenSSH :22
                                                   ├─ ruta /vless…   ► V2Ray  :10086+
                                                   └─ WebSocket/pay. ► SSH (101 + tunel)
```

- **HAProxy** termina el TLS y reparte todos los puertos (1 proceso en C).
- **wsproxy** (asyncio, 1 proceso, sin hilo por conexion) detecta SSH / WebSocket / V2Ray.
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
| `wsproxy.py`  | Proxy WebSocket/SSH/V2Ray (asyncio)       |
| `v2ray.sh`    | Xray: VLESS (auto) + VMess/Trojan/SS/Reality/xhttp |
| `slowdns.sh`  | Tunel DNS SlowDNS                         |
| `hysteria.sh` | UDP Hysteria v1 y v2 (coexisten)          |
| `users.sh`    | Crear y administrar cuentas               |
| `monitor.sh`  | Usuarios online, ancho de banda, speedtest|
| `update.sh`   | Actualizar / desinstalar                  |
| `bin/`        | Binarios (badvpn-udpgw, dns-server)       |

## Actualizar

Desde el panel: `menu` → **8) Mantenimiento** → **1) Actualizar script**.
Descarga la ultima version, detiene los servicios, reinstala y arranca de
nuevo conservando usuarios, claves y certificados (hace respaldo en `/root/`).
