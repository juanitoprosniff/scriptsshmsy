#!/bin/bash
# ============================================================
# Instalador UDP Hysteria v1 — MSYVPN-SCRIPT
# Referencia: https://github.com/apernet/hysteria/tree/hy1
# Auth: per-usuario via password field "usuario:contraseña"
# Obfs:  fijo (global) — requerido por el protocolo QUIC obfuscado
# ============================================================

_HYST_DIR="/etc/hysteria"
_HYST_BIN="/usr/local/bin/hysteria"
_HYST_CONFIG="$_HYST_DIR/config.json"
_HYST_DB="$_HYST_DIR/udpusers.db"
_HYST_CERT="$_HYST_DIR/hysteria.crt"
_HYST_KEY="$_HYST_DIR/hysteria.key"
_HYST_SERVICE="/etc/systemd/system/hysteria-server.service"
_HYST_PORT="${1:-36712}"
_HYST_OBFS="${2:-agnudp}"

# Usuario por defecto para pruebas rápidas
_DEF_USER="udptest"
_DEF_PASS="1234msy"

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

echo -e "\033[1;33m[Hysteria v1] Arquitectura: $_ARCH | Puerto: $_HYST_PORT | Obfs: $_HYST_OBFS\033[0m"

# Dependencias
apt-get install -y curl jq sqlite3 openssl >/dev/null 2>&1
mkdir -p "$_HYST_DIR"

# Detener servicio antes de tocar binario
systemctl stop hysteria-server 2>/dev/null

# Descarga Hysteria v1.3.5 (tag oficial v1 — branch hy1 de apernet/hysteria)
# Se fuerza la descarga para evitar binarios viejos o de v2 dejados por
# instalaciones previas.
_HYST_VER="v1.3.5"
_HYST_URL="https://github.com/apernet/hysteria/releases/download/${_HYST_VER}/hysteria-linux-${_ARCH}"
echo -e "\033[1;33m[Hysteria v1] Descargando binario ${_HYST_VER} (${_ARCH})...\033[0m"
curl -fsSL --max-time 120 "$_HYST_URL" -o "$_HYST_BIN" 2>/dev/null
if [[ ! -s "$_HYST_BIN" ]]; then
    echo -e "\033[1;31m[Hysteria v1] ✗ No se pudo descargar binario\033[0m"
    exit 1
fi
chmod +x "$_HYST_BIN"
echo -e "\033[1;32m[Hysteria v1] ✓ Binario descargado\033[0m"

# IP pública (para SAN del certificado)
_IP=$(cat /etc/IP 2>/dev/null | tr -d '\n')
[[ -z "$_IP" ]] && _IP=$(hostname -I | awk '{print $1}')

# Certificado TLS self-signed con IP como SAN
# (Hysteria v1 corre sobre QUIC y QUIC siempre necesita TLS;
# los clientes se conectan con insecure=true para aceptar self-signed)
if [[ ! -s "$_HYST_CERT" || ! -s "$_HYST_KEY" ]]; then
    echo -e "\033[1;33m[Hysteria v1] Generando certificado TLS self-signed...\033[0m"
    _san="DNS:msyvpn.local"
    [[ -n "$_IP" ]] && _san="${_san},IP:${_IP}"
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -subj "/C=CO/ST=Colombia/L=Bogota/O=MSYVPN/CN=msyvpn.local" \
        -addext "subjectAltName=${_san}" \
        -keyout "$_HYST_KEY" -out "$_HYST_CERT" >/dev/null 2>&1
    chmod 600 "$_HYST_KEY" "$_HYST_CERT"
    echo -e "\033[1;32m[Hysteria v1] ✓ Certificado generado (SAN: $_san)\033[0m"
fi

# Inicializar BD de usuarios
if [[ ! -f "$_HYST_DB" ]]; then
    sqlite3 "$_HYST_DB" "CREATE TABLE IF NOT EXISTS users (username TEXT PRIMARY KEY, password TEXT NOT NULL);" 2>/dev/null
    echo -e "\033[1;32m[Hysteria v1] ✓ Base de datos creada\033[0m"
fi

# Asegurar usuario de prueba en BD
sqlite3 "$_HYST_DB" \
    "INSERT OR IGNORE INTO users (username, password) VALUES ('$_DEF_USER', '$_DEF_PASS');" 2>/dev/null

# Construir auth.config desde BD
_arr=""
while IFS='|' read -r _u _p; do
    [[ -z "$_u" ]] && continue
    [[ -n "$_arr" ]] && _arr+=","
    _arr+="\"${_u}:${_p}\""
done < <(sqlite3 "$_HYST_DB" "SELECT username, password FROM users;" 2>/dev/null)
[[ -z "$_arr" ]] && _arr="\"${_DEF_USER}:${_DEF_PASS}\""

# Escribir config.json con obfs + cert + auth completos
# (sobrescribimos para corregir cualquier config rota de instalaciones previas)
cat > "$_HYST_CONFIG" <<JSON
{
  "listen": ":${_HYST_PORT}",
  "cert": "${_HYST_CERT}",
  "key": "${_HYST_KEY}",
  "obfs": "${_HYST_OBFS}",
  "auth": {
    "mode": "passwords",
    "config": [${_arr}]
  },
  "up_mbps": 2000,
  "down_mbps": 2000
}
JSON
echo -e "\033[1;32m[Hysteria v1] ✓ Config escrita: $_HYST_CONFIG\033[0m"

# Crear/actualizar servicio systemd
cat > "$_HYST_SERVICE" <<SERVICE
[Unit]
Description=Hysteria UDP Tunnel Server v1 — MSYVPN
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

# Acceso rápido: escribir 'agnudp' abre el manager directamente
cp -f /usr/local/bin/hysteria-manager /usr/local/bin/agnudp 2>/dev/null
chmod +x /usr/local/bin/agnudp 2>/dev/null

# Firewall — abrir puerto UDP
command -v ufw &>/dev/null && ufw allow "${_HYST_PORT}/udp" >/dev/null 2>&1
command -v iptables &>/dev/null && {
    iptables -C INPUT -p udp --dport "${_HYST_PORT}" -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p udp --dport "${_HYST_PORT}" -j ACCEPT 2>/dev/null
}

# Arrancar servicio
systemctl restart hysteria-server 2>/dev/null
sleep 2

echo ""
if systemctl is-active --quiet hysteria-server 2>/dev/null; then
    echo -e "\033[1;32m[Hysteria v1] ✓ Servicio ACTIVO en UDP $_HYST_PORT\033[0m"
    echo ""
    echo -e "\033[1;33m  ── Datos en la app (test rápido) ──\033[0m"
    echo -e "\033[1;32m  Servidor   : \033[1;37m${_IP}\033[0m"
    echo -e "\033[1;32m  Puerto UDP : \033[1;37m${_HYST_PORT}\033[0m"
    echo -e "\033[1;32m  Obfs       : \033[1;37m${_HYST_OBFS}     \033[1;33m← fijo, igual para todos\033[0m"
    echo -e "\033[1;32m  Password   : \033[1;37m${_DEF_USER}:${_DEF_PASS}\033[0m"
    echo -e "\033[1;33m  Importante : Activar 'Insecure' / 'Allow self-signed' en la app\033[0m"
    echo ""
    echo -e "\033[1;37m  Gestionar usuarios: hysteria-manager   (o: agnudp)\033[0m"
else
    echo -e "\033[1;31m[Hysteria v1] ✗ El servicio no arrancó.\033[0m"
    echo -e "\033[1;37m  journalctl -u hysteria-server -n 20\033[0m"
fi
echo ""
