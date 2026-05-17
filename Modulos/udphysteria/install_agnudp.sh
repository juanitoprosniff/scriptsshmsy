#!/bin/bash
# ============================================================
# Instalador UDP Hysteria — MSYVPN-SCRIPT
# ============================================================

_HYST_DIR="/etc/hysteria"
_HYST_BIN="/usr/local/bin/hysteria"
_HYST_CONFIG="$_HYST_DIR/config.json"
_HYST_DB="$_HYST_DIR/udpusers.db"
_HYST_SERVICE="/etc/systemd/system/hysteria-server.service"
_HYST_PORT="${1:-36712}"
_HYST_OBFS="${2:-agnudp}"

_detect_arch() {
    local _a; _a=$(uname -m)
    case "$_a" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7*|armhf)  echo "arm"   ;;
        *)             echo "amd64" ;;
    esac
}
_ARCH=$(_detect_arch)

echo -e "\033[1;33m[Hysteria] Detectando arquitectura: $_ARCH\033[0m"

# Instalar dependencias
apt-get install -y curl jq sqlite3 >/dev/null 2>&1

mkdir -p "$_HYST_DIR"

# Descargar binario Hysteria v1 (compatible con protocolo agnudp)
_hyst_download() {
    local _ver="v1.3.5"
    local _url="https://github.com/apernet/hysteria/releases/download/${_ver}/hysteria-linux-${_ARCH}"
    echo -e "\033[1;33m[Hysteria] Descargando binario $_ver ($_ARCH)...\033[0m"
    curl -fsSL --max-time 120 "$_url" -o "$_HYST_BIN" 2>/dev/null
    if [[ -s "$_HYST_BIN" ]]; then
        chmod +x "$_HYST_BIN"
        echo -e "\033[1;32m[Hysteria] ✓ Binario descargado\033[0m"
        return 0
    fi
    echo -e "\033[1;31m[Hysteria] ✗ No se pudo descargar el binario\033[0m"
    return 1
}

if [[ ! -x "$_HYST_BIN" ]]; then
    _hyst_download || exit 1
fi

# Obtener IP pública
_IP=$(cat /etc/IP 2>/dev/null | tr -d '\n' || hostname -I | awk '{print $1}')

# Crear configuración base
if [[ ! -f "$_HYST_CONFIG" ]]; then
    cat > "$_HYST_CONFIG" <<JSON
{
  "listen": ":${_HYST_PORT}",
  "protocol": "udp",
  "obfs": "${_HYST_OBFS}",
  "auth": {
    "mode": "passwords",
    "config": []
  },
  "disable_udp": false,
  "up_mbps": 100,
  "down_mbps": 100,
  "recv_window_conn": 15728640,
  "recv_window_client": 67108864,
  "max_conn_client": 4096,
  "insecure": true,
  "cert": "",
  "key": ""
}
JSON
    echo -e "\033[1;32m[Hysteria] ✓ Configuración creada (puerto UDP: $_HYST_PORT, obfs: $_HYST_OBFS)\033[0m"
fi

# Inicializar base de datos de usuarios
if [[ ! -f "$_HYST_DB" ]]; then
    sqlite3 "$_HYST_DB" "CREATE TABLE IF NOT EXISTS users (username TEXT PRIMARY KEY, password TEXT NOT NULL);" 2>/dev/null
    echo -e "\033[1;32m[Hysteria] ✓ Base de datos de usuarios creada\033[0m"
fi

# Crear servicio systemd
if [[ ! -f "$_HYST_SERVICE" ]]; then
    cat > "$_HYST_SERVICE" <<SERVICE
[Unit]
Description=Hysteria UDP Tunnel Server — MSYVPN
After=network.target

[Service]
Type=simple
ExecStart=$_HYST_BIN server --config $_HYST_CONFIG
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SERVICE
    systemctl daemon-reload 2>/dev/null
    systemctl enable hysteria-server 2>/dev/null
    echo -e "\033[1;32m[Hysteria] ✓ Servicio systemd creado y habilitado\033[0m"
fi

# Crear symlink agnudp → hysteria-manager
[[ ! -L /usr/local/bin/agnudp && ! -f /usr/local/bin/agnudp ]] && \
    ln -sf /usr/local/bin/hysteria-manager /usr/local/bin/agnudp 2>/dev/null

# Abrir puerto UDP en firewall
command -v ufw &>/dev/null && ufw allow ${_HYST_PORT}/udp >/dev/null 2>&1
command -v iptables &>/dev/null && {
    iptables -C INPUT -p udp --dport ${_HYST_PORT} -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p udp --dport ${_HYST_PORT} -j ACCEPT 2>/dev/null
}

# Iniciar servicio
systemctl start hysteria-server 2>/dev/null
sleep 2

if systemctl is-active --quiet hysteria-server 2>/dev/null; then
    echo -e "\033[1;32m[Hysteria] ✓ Hysteria UDP activo en puerto $_HYST_PORT (UDP)\033[0m"
    echo -e "\033[1;32m[Hysteria]   Obfs: $_HYST_OBFS\033[0m"
    echo -e "\033[1;32m[Hysteria]   Manager: hysteria-manager o agnudp\033[0m"
else
    echo -e "\033[1;33m[Hysteria] ⚠ Hysteria instalado pero no pudo iniciar automáticamente.\033[0m"
    echo -e "\033[1;33m[Hysteria]   Verifique: journalctl -u hysteria-server -n 30\033[0m"
    echo -e "\033[1;33m[Hysteria]   Nota: Se requiere un certificado TLS válido para producción.\033[0m"
fi
