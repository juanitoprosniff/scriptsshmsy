#!/bin/bash
# ============================================================
# Instalador UDP Hysteria — MSYVPN-SCRIPT
# Auth: "usuario:contraseña" (campo Obfs en app = usuario)
# ============================================================

_HYST_DIR="/etc/hysteria"
_HYST_BIN="/usr/local/bin/hysteria"
_HYST_CONFIG="$_HYST_DIR/config.json"
_HYST_DB="$_HYST_DIR/udpusers.db"
_HYST_CERT="$_HYST_DIR/hysteria.crt"
_HYST_KEY="$_HYST_DIR/hysteria.key"
_HYST_SERVICE="/etc/systemd/system/hysteria-server.service"
_HYST_PORT="${1:-36712}"

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

echo -e "\033[1;33m[Hysteria] Detectando arquitectura: $_ARCH\033[0m"

# Instalar dependencias
apt-get install -y curl jq sqlite3 openssl >/dev/null 2>&1

mkdir -p "$_HYST_DIR"

# Descargar binario Hysteria v1 (UDP/QUIC)
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

# Generar certificado TLS self-signed (QUIC/Hysteria lo requiere internamente)
if [[ ! -s "$_HYST_CERT" || ! -s "$_HYST_KEY" ]]; then
    echo -e "\033[1;33m[Hysteria] Generando certificado TLS self-signed...\033[0m"
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -subj "/C=CO/ST=Colombia/L=Bogota/O=MSYVPN/CN=msyvpn.local" \
        -keyout "$_HYST_KEY" -out "$_HYST_CERT" >/dev/null 2>&1
    chmod 600 "$_HYST_KEY" "$_HYST_CERT"
    echo -e "\033[1;32m[Hysteria] ✓ Certificado generado\033[0m"
fi

# Crear o corregir config.json
# Si ya existe pero tiene cert/key vacíos o rutas incorrectas, se parchea
_need_new_config=0
if [[ ! -f "$_HYST_CONFIG" ]]; then
    _need_new_config=1
else
    # Verificar que el cert referenciado en config existe y no es vacío
    _cfg_cert=$(jq -r '.cert // ""' "$_HYST_CONFIG" 2>/dev/null)
    _cfg_key=$(jq -r '.key // ""' "$_HYST_CONFIG" 2>/dev/null)
    if [[ -z "$_cfg_cert" || -z "$_cfg_key" || ! -s "$_cfg_cert" || ! -s "$_cfg_key" ]]; then
        echo -e "\033[1;33m[Hysteria] Corrigiendo rutas de certificado en config.json...\033[0m"
        jq ".cert = \"$_HYST_CERT\" | .key = \"$_HYST_KEY\"" \
            "$_HYST_CONFIG" > "${_HYST_CONFIG}.tmp" 2>/dev/null \
            && mv "${_HYST_CONFIG}.tmp" "$_HYST_CONFIG"
        echo -e "\033[1;32m[Hysteria] ✓ Config corregida\033[0m"
    fi
fi

if [[ "$_need_new_config" -eq 1 ]]; then
    cat > "$_HYST_CONFIG" <<JSON
{
  "listen": ":${_HYST_PORT}",
  "cert": "${_HYST_CERT}",
  "key": "${_HYST_KEY}",
  "auth": {
    "mode": "passwords",
    "config": ["${_DEF_USER}:${_DEF_PASS}"]
  },
  "up_mbps": 100,
  "down_mbps": 100
}
JSON
    echo -e "\033[1;32m[Hysteria] ✓ Configuración creada (puerto UDP: $_HYST_PORT)\033[0m"
fi

# Inicializar base de datos de usuarios
if [[ ! -f "$_HYST_DB" ]]; then
    sqlite3 "$_HYST_DB" "CREATE TABLE IF NOT EXISTS users (username TEXT PRIMARY KEY, password TEXT NOT NULL);" 2>/dev/null
    echo -e "\033[1;32m[Hysteria] ✓ Base de datos de usuarios creada\033[0m"
fi

# Asegurar que el usuario por defecto exista en la BD y en la config
sqlite3 "$_HYST_DB" \
    "INSERT OR IGNORE INTO users (username, password) VALUES ('$_DEF_USER', '$_DEF_PASS');" 2>/dev/null

# Reconstruir auth.config desde la BD (sincroniza BD → config.json)
_arr=""
while IFS='|' read -r _u _p; do
    [[ -z "$_u" ]] && continue
    [[ -n "$_arr" ]] && _arr+=","
    _arr+="\"${_u}:${_p}\""
done < <(sqlite3 "$_HYST_DB" "SELECT username, password FROM users;" 2>/dev/null)
if [[ -n "$_arr" ]]; then
    jq ".auth.config = [${_arr}]" "$_HYST_CONFIG" > "${_HYST_CONFIG}.tmp" 2>/dev/null \
        && mv "${_HYST_CONFIG}.tmp" "$_HYST_CONFIG"
fi
# Quitar obfs heredado de instalaciones previas
jq 'del(.obfs)' "$_HYST_CONFIG" > "${_HYST_CONFIG}.tmp" 2>/dev/null \
    && mv "${_HYST_CONFIG}.tmp" "$_HYST_CONFIG"

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

# Crear symlinks de acceso rápido
[[ ! -L /usr/local/bin/agnudp && ! -f /usr/local/bin/agnudp ]] && \
    ln -sf /usr/local/bin/hysteria-manager /usr/local/bin/agnudp 2>/dev/null

# Abrir puerto UDP en firewall
command -v ufw &>/dev/null && ufw allow "${_HYST_PORT}/udp" >/dev/null 2>&1
command -v iptables &>/dev/null && {
    iptables -C INPUT -p udp --dport "${_HYST_PORT}" -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p udp --dport "${_HYST_PORT}" -j ACCEPT 2>/dev/null
}

# Iniciar/reiniciar servicio
systemctl daemon-reload 2>/dev/null
systemctl restart hysteria-server 2>/dev/null
sleep 2

_IP=$(cat /etc/IP 2>/dev/null | tr -d '\n')
[[ -z "$_IP" ]] && _IP=$(hostname -I | awk '{print $1}')

if systemctl is-active --quiet hysteria-server 2>/dev/null; then
    echo -e "\033[1;32m[Hysteria] ✓ Hysteria UDP activo en puerto $_HYST_PORT\033[0m"
    echo ""
    echo -e "\033[1;33m  ── Usuario de prueba por defecto ──\033[0m"
    echo -e "\033[1;32m  Servidor    : \033[1;37m${_IP}:${_HYST_PORT}\033[0m"
    echo -e "\033[1;32m  App Obfs    : \033[1;37m${_DEF_USER}\033[0m"
    echo -e "\033[1;32m  App Pass    : \033[1;37m${_DEF_PASS}\033[0m"
    echo -e "\033[1;33m  Gestionar   : \033[1;37mhysteria-manager  (o: agnudp)\033[0m"
    echo ""
else
    echo -e "\033[1;33m[Hysteria] ⚠ Hysteria no pudo iniciar.\033[0m"
    echo -e "\033[1;37m  journalctl -u hysteria-server -n 20\033[0m"
fi
