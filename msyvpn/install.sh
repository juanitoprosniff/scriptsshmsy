#!/bin/bash
# install.sh - Instalador unico MSYVPN (activar todo automatico)
# Compatible Ubuntu 18-26 (server y minimal) / Debian 10-12
# Instala: HAProxy + wsproxy(async) + OpenSSH afinado + BBR + BadVPN
set -o pipefail

[[ "$(id -u)" -eq 0 ]] || { echo "Ejecuta como root."; exit 1; }

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="/etc/msyvpn"
REPO_RAW="https://raw.githubusercontent.com/juanitoprosniff/scriptsshmsy/main/msyvpn"

echo "=== INSTALANDO MSYVPN ==="

# --- 1. Dependencias -------------------------------------------------
echo "[1/9] Dependencias..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null 2>&1
apt-get install -y haproxy python3 openssl curl wget iproute2 iptables \
    cron jq conntrack net-tools ca-certificates >/dev/null 2>&1

# --- 2. Copiar modulos a /etc/msyvpn --------------------------------
echo "[2/9] Copiando modulos..."
mkdir -p "$BASE_DIR/bin" "$BASE_DIR/data/senha"
MODS="lib.sh wsproxy.py proxy.sh v2ray.sh slowdns.sh hysteria.sh users.sh monitor.sh update.sh menu master_pubkey.pub"
for m in $MODS; do
    if [[ -f "$SRC_DIR/$m" ]]; then
        cp -f "$SRC_DIR/$m" "$BASE_DIR/$m"
    else
        wget -q "$REPO_RAW/$m" -O "$BASE_DIR/$m"
    fi
done
# Binarios incluidos (amd64) — para otras arquitecturas fetch_bin descarga
for b in badvpn-udpgw dns-server; do
    [[ -f "$SRC_DIR/bin/$b" ]] && cp -f "$SRC_DIR/bin/$b" "$BASE_DIR/bin/$b"
    chmod +x "$BASE_DIR/bin/$b" 2>/dev/null
done
chmod +x "$BASE_DIR"/*.sh "$BASE_DIR"/wsproxy.py "$BASE_DIR"/menu 2>/dev/null

# shellcheck source=/dev/null
source "$BASE_DIR/lib.sh"

# Binario badvpn segun arquitectura -> /usr/bin
fetch_bin badvpn-udpgw /usr/bin/badvpn-udpgw || err "badvpn no disponible para $(arch)"

# Guardar IP publica
get_ip > "$BASE_DIR/ip"

# Salida a internet: si la VPS tiene IPv6 se prefiere (geolocalizacion
# correcta). Se puede cambiar luego en: menu -> Proxy/SSL
if [[ ! -f "$IPV6_PREF_FILE" ]]; then
    if has_ipv6; then
        net_apply_pref 6
        echo "    Salida preferente: IPv6 ($(get_ip6))"
    else
        net_apply_pref 4
    fi
fi

# --- 3. Afinar OpenSSH (buen ping) ----------------------------------
echo "[3/9] Afinando OpenSSH..."
grep -qx '/bin/false' /etc/shells 2>/dev/null || echo '/bin/false' >> /etc/shells
grep -qx '/usr/sbin/nologin' /etc/shells 2>/dev/null || echo '/usr/sbin/nologin' >> /etc/shells
SSH_BASE='UseDNS no
Compression no
TCPKeepAlive yes
ClientAliveInterval 30
ClientAliveCountMax 3
IPQoS lowdelay throughput
AllowTcpForwarding yes
GatewayPorts yes
PubkeyAuthentication yes
PasswordAuthentication yes
MaxStartups 200:30:2000
MaxSessions 50'

# Compatibilidad con apps VPN y claves RSA antiguas: OpenSSH 8.8+
# desactiva las firmas ssh-rsa (SHA-1) y eso rompe la clave maestra y
# muchos clientes. El nombre de la directiva cambio en OpenSSH 8.5, por
# eso se prueban dos variantes y se valida antes de aplicar.
SSH_LEGACY_NEW='DebianBanner no
PubkeyAcceptedAlgorithms +ssh-rsa,rsa-sha2-256,rsa-sha2-512
CASignatureAlgorithms +ssh-rsa
HostKeyAlgorithms +ssh-rsa
KexAlgorithms +diffie-hellman-group14-sha1,diffie-hellman-group-exchange-sha1,diffie-hellman-group1-sha1
Ciphers +aes128-cbc,aes256-cbc,3des-cbc
MACs +hmac-sha1,hmac-sha1-96'

SSH_LEGACY_OLD='PubkeyAcceptedKeyTypes +ssh-rsa
HostKeyAlgorithms +ssh-rsa
KexAlgorithms +diffie-hellman-group14-sha1,diffie-hellman-group1-sha1
Ciphers +aes128-cbc,aes256-cbc,3des-cbc
MACs +hmac-sha1'

_ssh_write() {   # $1 = contenido completo
    if [[ -d /etc/ssh/sshd_config.d ]] && \
       grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d' /etc/ssh/sshd_config 2>/dev/null; then
        printf '%s\n' "$1" > /etc/ssh/sshd_config.d/00-msyvpn.conf
    else
        sed -i '/# MSYVPN-BEGIN/,/# MSYVPN-END/d' /etc/ssh/sshd_config 2>/dev/null
        printf '# MSYVPN-BEGIN\n%s\n# MSYVPN-END\n' "$1" >> /etc/ssh/sshd_config
    fi
}
_ssh_clear() {
    rm -f /etc/ssh/sshd_config.d/00-msyvpn.conf 2>/dev/null
    sed -i '/# MSYVPN-BEGIN/,/# MSYVPN-END/d' /etc/ssh/sshd_config 2>/dev/null
}

SSHD_BIN=$(command -v sshd || echo /usr/sbin/sshd)
_sshd_ok() { [[ -x "$SSHD_BIN" ]] && "$SSHD_BIN" -t 2>/dev/null; }

# Se valida con "sshd -t" y se retrocede si la config no sirve, para no
# dejar nunca el servidor SSH sin arrancar (quedarias fuera de la VPS).
_ssh_clear
if [[ ! -x "$SSHD_BIN" ]]; then
    # Sin binario para validar: solo directivas estandar, seguras en
    # cualquier version.
    _ssh_write "$SSH_BASE"
    echo "    SSH: ajustes basicos (sshd no encontrado para validar)"
elif _ssh_write "$SSH_BASE
$SSH_LEGACY_NEW" && _sshd_ok; then
    echo "    SSH: compatibilidad RSA activada (formato nuevo)"
elif _ssh_write "$SSH_BASE
$SSH_LEGACY_OLD" && _sshd_ok; then
    echo "    SSH: compatibilidad RSA activada (formato antiguo)"
elif _ssh_write "$SSH_BASE" && _sshd_ok; then
    echo "    SSH: ajustes basicos (sin bloque de compatibilidad)"
else
    _ssh_clear
    echo "    SSH: se conservo la configuracion original (no se pudo validar)"
fi
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null

# --- 4. Kernel: BBR + baja latencia + forwarding --------------------
echo "[4/9] Optimizando kernel (BBR)..."
modprobe tcp_bbr 2>/dev/null
sed -i '/# MSYVPN-BEGIN/,/# MSYVPN-END/d' /etc/sysctl.conf 2>/dev/null
cat >> /etc/sysctl.conf <<'EOF'
# MSYVPN-BEGIN
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_low_latency=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.core.somaxconn=8192
net.core.netdev_max_backlog=5000
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.ip_forward=1
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.default.disable_ipv6=0
net.ipv6.conf.all.forwarding=1
net.core.rmem_max=8388608
net.core.wmem_max=8388608
net.ipv4.tcp_rmem=4096 87380 8388608
net.ipv4.tcp_wmem=4096 65536 8388608
# MSYVPN-END
EOF
sysctl -p >/dev/null 2>&1

# --- 5. Certificado TLS (HAProxy) -----------------------------------
echo "[5/9] Generando certificado..."
source "$BASE_DIR/proxy.sh"
proxy_gen_cert

# --- 6. wsproxy como servicio (auto-reinicio) -----------------------
echo "[6/9] Servicio wsproxy..."
# WSPROXY_SSH_BANNER: linea mostrada antes del banner SSH.
# NO puede empezar con "SSH-" (el cliente la tomaria como la version real).
[[ -s "$BASE_DIR/wsproxy.env" ]] || printf 'WSPROXY_NAME=MSY VPN\nWSPROXY_COLOR=green\nWSPROXY_SSH_BANNER=MSY_VPN_SCRIPT\n' > "$BASE_DIR/wsproxy.env"
cat > /etc/systemd/system/msyvpn-wsproxy.service <<EOF
[Unit]
Description=MSYVPN WebSocket Proxy (async)
After=network.target

[Service]
EnvironmentFile=-$BASE_DIR/wsproxy.env
ExecStart=/usr/bin/python3 $BASE_DIR/wsproxy.py $WSPROXY_INTERNAL 127.0.0.1:$SSH_PORT
Restart=always
RestartSec=2
MemoryMax=300M
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
EOF

# --- 7. BadVPN UDP gateway (juegos/streaming) -----------------------
echo "[7/9] Servicio BadVPN (UDP)..."
cat > /etc/systemd/system/msyvpn-badvpn.service <<'EOF'
[Unit]
Description=MSYVPN BadVPN UDP Gateway
After=network.target

[Service]
ExecStart=/usr/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 2000 --max-connections-for-client 12 --client-socket-sndbuf 65536
Restart=always
RestartSec=2
MemoryMax=150M

[Install]
WantedBy=multi-user.target
EOF

# --- 8. HAProxy con puertos por defecto -----------------------------
echo "[8/9] Configurando HAProxy..."
proxy_write_config

# --- 9. Habilitar y arrancar ----------------------------------------
echo "[9/9] Arrancando servicios..."
systemctl daemon-reload
systemctl enable --now msyvpn-wsproxy msyvpn-badvpn >/dev/null 2>&1
systemctl enable --now haproxy >/dev/null 2>&1
systemctl restart msyvpn-wsproxy msyvpn-badvpn haproxy >/dev/null 2>&1

# Comando 'menu'
ln -sf "$BASE_DIR/menu" /usr/bin/menu
chmod +x /usr/bin/menu
touch /usr/lib/msyvpn

# --- Auto-activar Hysteria v1 y v2 (UDP) ----------------------------
echo "[+] Activando Hysteria UDP (v1 y v2)..."
source "$BASE_DIR/hysteria.sh"
hy_install 1 >/dev/null 2>&1 && echo "    Hysteria v1 activo en UDP :$(hy_port 1)" \
    || echo "    (Hysteria v1 se puede activar luego desde el menu)"
hy_install 2 >/dev/null 2>&1 && echo "    Hysteria v2 activo en UDP :$(hy_port 2)" \
    || echo "    (Hysteria v2 se puede activar luego desde el menu)"

# En una actualizacion no se vuelve a preguntar nada
if [[ -z "$MSYVPN_UPDATE" ]]; then
    read -rp "Activar TLS con tu dominio ahora? [s/N]: " _tls
    if [[ "$_tls" =~ ^[sS]$ ]]; then
        source "$BASE_DIR/v2ray.sh"
        read -rp "Dominio (debe apuntar a esta IP): " _dom
        _dom=$(echo "$_dom" | tr 'A-Z' 'a-z' | xargs)
        if [[ -n "$_dom" ]]; then
            echo "$_dom" > "$DATA_DIR/domain"
            if v2_check_domain "$_dom"; then proxy_cert_real "$_dom"
            else echo "    Reintenta luego en: menu -> V2Ray -> Activar TLS"; fi
        fi
    fi
    read -rp "Configurar SlowDNS ahora? (necesita un NS delegado) [s/N]: " _sd
    if [[ "$_sd" =~ ^[sS]$ ]]; then
        source "$BASE_DIR/slowdns.sh"; sd_install
    fi
fi

echo ""
echo "=== MSYVPN INSTALADO ==="
echo "IP        : $(cat "$BASE_DIR/ip")"
[[ -s "$MASTER_PUBKEY" ]] && echo "Clave RSA : instalada (auth por llave activo)"
echo "Escribe 'menu' para administrar."
echo ""
