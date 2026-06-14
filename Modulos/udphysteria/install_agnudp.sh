#!/bin/bash
# ============================================================
# Instalador UDP Hysteria v1 — MSYVPN-SCRIPT
# Basado en el instalador funcional AGN-UDP
# Auth: per-usuario via "usuario:contraseña" desde criarusuario
# ============================================================

_HYST_DIR="/etc/hysteria"
_HYST_BIN="/usr/local/bin/hysteria"
_HYST_CONFIG="$_HYST_DIR/config.json"
_HYST_DB="$_HYST_DIR/udpusers.db"
_HYST_SERVICE="/etc/systemd/system/hysteria-server.service"
_HYST_SERVICE_X="/etc/systemd/system/hysteria-server@.service"
_HYST_PORT="${1:-36712}"
_HYST_OBFS="${2:-agnudp}"

# Protocolo y certificados (igual que el ejemplo funcional)
_PROTOCOL="udp"
_CERT="/etc/hysteria/hysteria.server.crt"
_KEY="/etc/hysteria/hysteria.server.key"

# Dominio/IP para el certificado y config.json
_IP=$(cat /etc/IP 2>/dev/null | tr -d '\n')
[[ -z "$_IP" ]] && _IP=$(hostname -I | awk '{print $1}')
_DOMAIN="${_IP}"

# Usuario de prueba por si no hay ninguno del sistema
_DEF_USER="udptest"
_DEF_PASS="1234msy"

# ── Colores ──────────────────────────────────────────────────
_R='\033[1;31m'; _G='\033[1;32m'; _Y='\033[1;33m'; _N='\033[0m'

# ── Detectar arquitectura ────────────────────────────────────
_detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)        echo "amd64" ;;
        aarch64|arm64)       echo "arm64" ;;
        armv7*|armhf)        echo "arm"   ;;
        'i386'|'i686')       echo "386"   ;;
        *)                   echo "amd64" ;;
    esac
}
_ARCH=$(_detect_arch)

echo -e "${_Y}[Hysteria v1] Arquitectura: $_ARCH | Puerto: $_HYST_PORT | Obfs: $_HYST_OBFS${_N}"

# ── Dependencias ─────────────────────────────────────────────
apt-get install -y curl jq sqlite3 openssl iptables-persistent 2>/dev/null
debconf-set-selections <<< "iptables-persistent iptables-persistent/autosave_v4 boolean true" 2>/dev/null
debconf-set-selections <<< "iptables-persistent iptables-persistent/autosave_v6 boolean true" 2>/dev/null

mkdir -p "$_HYST_DIR"

# ── Detener servicio antes de actualizar binario ─────────────
systemctl stop hysteria-server 2>/dev/null

# ── Descarga Hysteria v1.3.5 ─────────────────────────────────
_HYST_VER="v1.3.5"
_HYST_URL="https://github.com/apernet/hysteria/releases/download/${_HYST_VER}/hysteria-linux-${_ARCH}"

echo -e "${_Y}[Hysteria v1] Descargando binario ${_HYST_VER} (${_ARCH})...${_N}"
curl -R -L -f -q --retry 5 --retry-delay 10 --retry-max-time 120 \
    -H 'Cache-Control: no-cache' \
    "$_HYST_URL" -o "$_HYST_BIN"

if [[ ! -s "$_HYST_BIN" ]]; then
    echo -e "${_R}[Hysteria v1] ✗ No se pudo descargar el binario${_N}"
    exit 1
fi
chmod +x "$_HYST_BIN"
echo -e "${_G}[Hysteria v1] ✓ Binario descargado${_N}"

# ── Generar certificados SSL (igual que el ejemplo funcional) ─
# Hysteria v1 necesita TLS. Con "insecure":true en el config del
# servidor, acepta self-signed; los clientes también lo omiten.
echo -e "${_Y}[Hysteria v1] Generando certificados SSL...${_N}"

openssl genrsa -out /etc/hysteria/hysteria.ca.key 2048 2>/dev/null

openssl req -new -x509 -days 3650 \
    -key /etc/hysteria/hysteria.ca.key \
    -subj "/C=CN/ST=GD/L=SZ/O=Hysteria,Inc./CN=HysteriaRootCA" \
    -out /etc/hysteria/hysteria.ca.crt 2>/dev/null

openssl req -newkey rsa:2048 -nodes \
    -keyout "$_KEY" \
    -subj "/C=CN/ST=GD/L=SZ/O=Hysteria,Inc./CN=${_DOMAIN}" \
    -out /etc/hysteria/hysteria.server.csr 2>/dev/null

openssl x509 -req \
    -extfile <(printf "subjectAltName=DNS:${_DOMAIN},IP:${_IP}") \
    -days 3650 \
    -in  /etc/hysteria/hysteria.server.csr \
    -CA  /etc/hysteria/hysteria.ca.crt \
    -CAkey /etc/hysteria/hysteria.ca.key \
    -CAcreateserial \
    -out "$_CERT" 2>/dev/null

if [[ ! -s "$_CERT" || ! -s "$_KEY" ]]; then
    echo -e "${_R}[Hysteria v1] ✗ Error generando certificados${_N}"
    exit 1
fi
chmod 600 "$_KEY"
echo -e "${_G}[Hysteria v1] ✓ Certificados generados${_N}"

# ── Inicializar BD de usuarios ───────────────────────────────
sqlite3 "$_HYST_DB" \
    "CREATE TABLE IF NOT EXISTS users (username TEXT PRIMARY KEY, password TEXT NOT NULL);" 2>/dev/null
echo -e "${_G}[Hysteria v1] ✓ Base de datos lista${_N}"

# ── Leer usuarios desde el sistema MSYVPN ───────────────────
# criarusuario.sh guarda la contraseña real de cada usuario en
# /etc/SSHPlus/senha/<usuario>. Esos son los que se usan en Hysteria.
_fetch_msyvpn_users() {
    local _out="" _u _p
    if [[ -d /etc/SSHPlus/senha ]]; then
        for _f in /etc/SSHPlus/senha/*; do
            [[ -f "$_f" ]] || continue
            _u=$(basename "$_f")
            _p=$(cat "$_f" 2>/dev/null | tr -d '\n')
            [[ -z "$_u" || -z "$_p" ]] && continue
            id "$_u" &>/dev/null || continue
            [[ -n "$_out" ]] && _out+=","
            _out+="\"${_u}:${_p}\""
            # También sincronizar en la BD SQLite
            sqlite3 "$_HYST_DB" \
                "INSERT OR REPLACE INTO users (username,password) VALUES ('$_u','$_p');" 2>/dev/null
        done
    fi
    echo "$_out"
}

_arr=$(_fetch_msyvpn_users)

# Si no hay usuarios del sistema, caer a BD SQLite
if [[ -z "$_arr" ]]; then
    while IFS='|' read -r _u _p; do
        [[ -z "$_u" ]] && continue
        [[ -n "$_arr" ]] && _arr+=","
        _arr+="\"${_u}:${_p}\""
    done < <(sqlite3 "$_HYST_DB" "SELECT username,password FROM users;" 2>/dev/null)
fi

# Si sigue vacío, usuario de prueba por defecto
if [[ -z "$_arr" ]]; then
    sqlite3 "$_HYST_DB" \
        "INSERT OR IGNORE INTO users (username,password) VALUES ('$_DEF_USER','$_DEF_PASS');" 2>/dev/null
    _arr="\"${_DEF_USER}:${_DEF_PASS}\""
fi

# ── Escribir config.json ──────────────────────────────────────
# IMPORTANTE: "insecure":true en el servidor es lo que permite
# que los clientes con certificados self-signed puedan conectar
# independientemente de si tienen allowInsecure activo o no en la app.
cat > "$_HYST_CONFIG" <<JSON
{
  "server": "${_DOMAIN}",
  "listen": ":${_HYST_PORT}",
  "protocol": "${_PROTOCOL}",
  "cert": "${_CERT}",
  "key": "${_KEY}",
  "up": "2000 Mbps",
  "up_mbps": 2000,
  "down": "2000 Mbps",
  "down_mbps": 2000,
  "disable_udp": false,
  "insecure": true,
  "obfs": "${_HYST_OBFS}",
  "auth": {
    "mode": "passwords",
    "config": [${_arr}]
  }
}
JSON
echo -e "${_G}[Hysteria v1] ✓ Config escrita${_N}"

# ── Servicio systemd (igual que el ejemplo funcional) ────────
cat > "$_HYST_SERVICE" <<SERVICE
[Unit]
Description=AGN-UDP Service
After=network.target

[Service]
User=root
Group=root
WorkingDirectory=/etc/hysteria
Environment="PATH=/usr/local/bin/hysteria"
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.json

[Install]
WantedBy=multi-user.target
SERVICE

cat > "$_HYST_SERVICE_X" <<SERVICE
[Unit]
Description=AGN-UDP Service (%i)
After=network.target

[Service]
User=root
Group=root
WorkingDirectory=/etc/hysteria
Environment="PATH=/usr/local/bin/hysteria"
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/%i.json

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload 2>/dev/null
systemctl enable hysteria-server 2>/dev/null

# ── Acceso rápido 'agnudp' ────────────────────────────────────
[[ -f /usr/local/bin/agnudp_manager.sh ]] && \
    ln -sf /usr/local/bin/agnudp_manager.sh /usr/local/bin/agnudp 2>/dev/null

# ── Firewall — abrir puerto UDP ───────────────────────────────
command -v ufw &>/dev/null && ufw allow "${_HYST_PORT}/udp" >/dev/null 2>&1
iptables -C INPUT -p udp --dport "${_HYST_PORT}" -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p udp --dport "${_HYST_PORT}" -j ACCEPT 2>/dev/null

# ── Reglas iptables para port hopping (10000-65000 → puerto UDP) ─
_IFACE=$(ip -4 route ls | grep default | grep -oP '(?<=dev )(\S+)' | head -1)
iptables -t nat -A PREROUTING -i "$_IFACE" -p udp \
    --dport 10000:65000 -j DNAT --to-destination ":${_HYST_PORT}" 2>/dev/null
ip6tables -t nat -A PREROUTING -i "$_IFACE" -p udp \
    --dport 10000:65000 -j DNAT --to-destination ":${_HYST_PORT}" 2>/dev/null

sysctl net.ipv4.ip_forward=1 >/dev/null 2>&1
sysctl net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1
sysctl net.ipv4.conf.${_IFACE}.rp_filter=0 >/dev/null 2>&1

# Persistir reglas iptables
iptables-save  > /etc/iptables/rules.v4 2>/dev/null
ip6tables-save > /etc/iptables/rules.v6 2>/dev/null

# ── Arrancar servicio ─────────────────────────────────────────
systemctl restart hysteria-server 2>/dev/null
sleep 2

echo ""
if systemctl is-active --quiet hysteria-server 2>/dev/null; then
    echo -e "${_G}[Hysteria v1] ✓ Servicio ACTIVO en UDP :${_HYST_PORT}${_N}"
    echo ""
    echo -e "${_Y}  ── Datos para la app ──${_N}"
    echo -e "${_G}  Servidor   : ${_N}${_IP}"
    echo -e "${_G}  Puerto UDP : ${_N}${_HYST_PORT}"
    echo -e "${_G}  Obfs       : ${_N}${_HYST_OBFS}${_Y}  ← igual para todos los usuarios${_N}"
    echo -e "${_G}  Password   : ${_N}usuario:contraseña  (el que creaste en criarusuario)"
    echo -e "${_Y}  Insecure   : puede estar ON u OFF — funciona igual${_N}"
    echo ""
    echo -e "  Gestionar: ${_G}agnudp${_N}"
else
    echo -e "${_R}[Hysteria v1] ✗ El servicio no arrancó.${_N}"
    echo -e "  Ver logs: journalctl -u hysteria-server -n 30"
fi
echo ""
