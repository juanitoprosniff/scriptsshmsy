#!/bin/bash
# lib.sh - Funciones comunes centralizadas para MSYVPN
# Todos los modulos hacen: source /etc/msyvpn/lib.sh
# Sin colores, sin adornos. Solo logica reutilizable.

BASE_DIR="/etc/msyvpn"
DATA_DIR="$BASE_DIR/data"
SENHA_DIR="$DATA_DIR/senha"
USERS_DB="$DATA_DIR/usuarios.db"
REPO_RAW="https://raw.githubusercontent.com/juanitoprosniff/scriptsshmsy/main/msyvpn"

WSPROXY_INTERNAL="8888"          # puerto interno del wsproxy (solo 127.0.0.1)
SSH_PORT="22"                    # backend SSH por defecto
HAPROXY_CFG="/etc/haproxy/haproxy.cfg"
CERT_PEM="$BASE_DIR/cert.pem"
ROUTES_CONF="$BASE_DIR/routes.conf"
MASTER_PUBKEY="$BASE_DIR/master_pubkey.pub"
APP_NAME="MSY VPN"

mkdir -p "$DATA_DIR" "$SENHA_DIR" 2>/dev/null

# ---------------------------------------------------------------
# Sistema / entorno
# ---------------------------------------------------------------
need_root() {
    [[ "$(id -u)" -eq 0 ]] || { echo "Debe ejecutarse como root."; exit 1; }
}

os_ver() {
    # Version mayor de Ubuntu/Debian (18, 20, 22, 24, 26...)
    local v
    v=$(. /etc/os-release 2>/dev/null; echo "$VERSION_ID")
    [[ -z "$v" ]] && v=$(lsb_release -rs 2>/dev/null)
    echo "${v%%.*}"
}

arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7*|armhf)  echo "arm"   ;;
        armv6*)        echo "armv6" ;;
        i386|i686)     echo "386"   ;;
        mips64*)       echo "mips64";;
        s390x)         echo "s390x" ;;
        riscv64)       echo "riscv64";;
        *)             echo "amd64" ;;
    esac
}

# Obtiene un binario segun la arquitectura.
# Uso: fetch_bin <nombre> <destino>
#   - amd64: usa el binario incluido en bin/ (o lo descarga del repo)
#   - otras: descarga del repo (bin/<nombre>-<arch>) si existe
fetch_bin() {
    local name="$1" dest="$2" a; a=$(arch)
    if [[ "$a" == "amd64" && -f "$BASE_DIR/bin/$name" ]]; then
        cp -f "$BASE_DIR/bin/$name" "$dest"
    elif [[ -f "$BASE_DIR/bin/$name-$a" ]]; then
        cp -f "$BASE_DIR/bin/$name-$a" "$dest"
    else
        wget -q "$REPO_RAW/bin/$name-$a" -O "$dest" 2>/dev/null || \
        wget -q "$REPO_RAW/bin/$name"    -O "$dest" 2>/dev/null
    fi
    [[ -s "$dest" ]] && chmod +x "$dest" && return 0
    return 1
}

get_ip() {
    local ip
    [[ -s /etc/msyvpn/ip ]] && ip=$(cat /etc/msyvpn/ip)
    [[ -z "$ip" ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$ip" ]] && ip=$(curl -s -4 --max-time 4 ifconfig.me 2>/dev/null)
    echo "${ip:-0.0.0.0}"
}

# Restaura el orden normal de IPv4/IPv6 del sistema (sin forzar nada)
net_reset_pref() {
    [[ -f /etc/gai.conf ]] && sed -i '/# MSYVPN-BEGIN/,/# MSYVPN-END/d' /etc/gai.conf
    rm -f "$BASE_DIR/prefer_ipv6" "$BASE_DIR/data/v6exit" 2>/dev/null
    # Quitar el desvio transparente de versiones anteriores
    if iptables -t nat -L MSYVPN_V6 >/dev/null 2>&1; then
        local r n=0
        while :; do
            r=$(iptables-save -t nat 2>/dev/null | grep -m1 -- '-A OUTPUT .*-j MSYVPN_V6' | sed 's/^-A //')
            [[ -z "$r" ]] && break
            iptables -t nat -D $r 2>/dev/null || break
            n=$((n+1)); [[ $n -ge 100 ]] && break
        done
        iptables -t nat -F MSYVPN_V6 2>/dev/null
        iptables -t nat -X MSYVPN_V6 2>/dev/null
    fi
}

# Instalar paquetes solo si faltan (idempotente)
ensure_pkg() {
    local missing=()
    local p
    for p in "$@"; do
        dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        apt-get update -y >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" >/dev/null 2>&1
    fi
}

# ---------------------------------------------------------------
# Puertos y firewall
# ---------------------------------------------------------------
port_in_use() {
    ss -tlnH "sport = :$1" 2>/dev/null | grep -q .
}

open_port() {
    local pt="$1" pr="${2:-tcp}"
    command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active && \
        ufw allow "${pt}/${pr}" >/dev/null 2>&1
    if command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p "$pr" --dport "$pt" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p "$pr" --dport "$pt" -j ACCEPT 2>/dev/null
    fi
}

# ---------------------------------------------------------------
# systemd
# ---------------------------------------------------------------
svc_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
svc_restart() { systemctl restart "$1" 2>/dev/null; }

# ---------------------------------------------------------------
# Interfaz minima (sin colores)
# ---------------------------------------------------------------
line()  { printf '%s\n' "------------------------------------------------"; }
title() { line; printf '  %s\n' "$1"; line; }
pause() { printf '\n'; read -rp "Enter para continuar..." _; }
ask()   { local p="$1"; local __v; read -rp "$p" __v; printf '%s' "$__v"; }
ok()    { printf '[OK] %s\n' "$1"; }
err()   { printf '[X]  %s\n' "$1"; }
info()  { printf '     %s\n' "$1"; }
