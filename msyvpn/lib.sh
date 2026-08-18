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

# ---------------------------------------------------------------
# Por que familia SALE el trafico de la VPS
# ---------------------------------------------------------------
#
# Decide si, cuando el destino tiene IPv4 e IPv6 (Google, YouTube, casi todo lo
# grande), la VPS sale por una o por otra.
#
# ── POR QUE IMPORTA MUCHO MAS DE LO QUE PARECE ─────────────────────────────
#  Las bases de geolocalizacion NO tienen por que situar la IPv4 y la IPv6 de
#  la MISMA maquina en el mismo pais. Es habitual que un bloque IPv4 reasignado
#  siga mapeado al pais del dueno anterior durante meses, y cada base (la de
#  Google no es la de ipinfo) va por su cuenta.
#
#  Consecuencia practica: si Google situa tu IPv4 en otro pais, los resultados
#  y los ANUNCIOS salen de ese pais aunque la maquina este en Austria. Y el
#  match rate y el eCPM de AdMob cambian muchisimo de un pais a otro.
#
# ── EL DETALLE QUE LO ROMPIA ───────────────────────────────────────────────
#  Por defecto (RFC 6724) Linux ya prefiere IPv6. Lo que le da la vuelta es
#  esta linea, que muchas imagenes de VPS traen puesta:
#
#      precedence ::ffff:0:0/96  100
#
#  Ademas, hasta ahora install.sh llamaba a net_reset_pref() en cada
#  actualizacion, asi que cualquier preferencia configurada se perdia sola y
#  sin avisar. Por eso hay un marcador que sobrevive: net_pref_aplicar() lo
#  vuelve a poner despues de actualizar.
PREF_MARCA="$BASE_DIR/prefer_ipv6"

# ipv6 | ipv4 | sistema
net_pref_estado() {
    if [[ -f "$PREF_MARCA" ]]; then cat "$PREF_MARCA" 2>/dev/null || echo sistema
    else echo sistema; fi
}

_gai_limpiar() {
    [[ -f /etc/gai.conf ]] && sed -i '/# MSYVPN-BEGIN/,/# MSYVPN-END/d' /etc/gai.conf
    return 0
}

_gai_escribir() {   # $1 = contenido del bloque
    touch /etc/gai.conf
    _gai_limpiar
    printf '# MSYVPN-BEGIN\n%s\n# MSYVPN-END\n' "$1" >> /etc/gai.conf
}

# Salir por IPv6 cuando el destino la tenga (el comportamiento estandar).
net_pref_ipv6() {
    # Basta con NO degradar IPv6: se deja el bloque vacio de precedencias y se
    # anula cualquier "precedence ::ffff:0:0/96 100" que hubiera suelto.
    sed -i 's/^\s*precedence\s*::ffff:0:0\/96.*/#&/' /etc/gai.conf 2>/dev/null
    _gai_escribir "# Preferir IPv6 en las salidas: es el orden por defecto del
# RFC 6724. Solo hay que asegurarse de que nadie lo degrade."
    echo ipv6 > "$PREF_MARCA"
}

# Forzar salida por IPv4 aunque el destino tenga IPv6.
net_pref_ipv4() {
    _gai_escribir "precedence ::ffff:0:0/96  100"
    echo ipv4 > "$PREF_MARCA"
}

# Dejar exactamente lo que traiga el sistema.
net_pref_sistema() {
    _gai_limpiar
    rm -f "$PREF_MARCA" "$DATA_DIR/v6exit" 2>/dev/null
    return 0
}

# Reaplica la preferencia guardada. La llama install.sh en cada actualizacion.
net_pref_aplicar() {
    case "$(net_pref_estado)" in
        ipv6) net_pref_ipv6 ;;
        ipv4) net_pref_ipv4 ;;
        *)    return 0 ;;
    esac
}

# Por donde sale de verdad ahora mismo. Es la unica prueba que vale.
net_pref_probar() {
    local v4 v6 auto
    v4=$(curl -4 -s --max-time 6 https://ifconfig.me 2>/dev/null)
    v6=$(curl -6 -s --max-time 6 https://ifconfig.me 2>/dev/null)
    auto=$(curl -s --max-time 6 https://ifconfig.me 2>/dev/null)
    echo "  IPv4 de salida : ${v4:-(sin IPv4)}"
    echo "  IPv6 de salida : ${v6:-(sin IPv6)}"
    echo "  Se usa por defecto: ${auto:-(sin respuesta)}"
    if [[ -n "$auto" && "$auto" == "$v6" && -n "$v6" ]]; then
        ok "Sale por IPv6"
    elif [[ -n "$auto" && "$auto" == "$v4" ]]; then
        info "Sale por IPv4"
    fi
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
# Colores minimos (solo para resaltar estados y numeros)
C_G=$'\033[1;32m'   # verde
C_R=$'\033[1;31m'   # rojo
C_Y=$'\033[1;33m'   # amarillo
C_C=$'\033[1;36m'   # cyan
C_0=$'\033[0m'      # reset
g() { printf '%s%s%s' "$C_G" "$1" "$C_0"; }   # verde
r() { printf '%s%s%s' "$C_R" "$1" "$C_0"; }   # rojo
num() { printf '%s%s%s' "$C_C" "$1" "$C_0"; } # numero resaltado
# Devuelve "activo"/"inactivo" coloreado (acepta varios nombres de servicio)
svc_txt() { local s; for s in "$@"; do svc_active "$s" && { g "activo"; return; }; done; r "inactivo"; }

line()  { printf '%s\n' "------------------------------------------------"; }
title() { line; printf '  %s\n' "$1"; line; }
pause() { printf '\n'; read -rp "Enter para continuar..." _; }
ask()   { local p="$1"; local __v; read -rp "$p" __v; printf '%s' "$__v"; }
ok()    { printf '[OK] %s\n' "$1"; }
err()   { printf '[X]  %s\n' "$1"; }
info()  { printf '     %s\n' "$1"; }

# ---------------------------------------------------------------
# Menu: por donde sale el trafico de la VPS
# ---------------------------------------------------------------
net_pref_menu() {
    while true; do
        clear; title "SALIDA A INTERNET DE LA VPS  (IPv4 / IPv6)"
        echo "Preferencia guardada: $(net_pref_estado)"
        line
        echo "Esto decide por que familia sale el trafico cuando el destino"
        echo "tiene las dos. Importa porque las bases de geolocalizacion NO"
        echo "situan siempre la IPv4 y la IPv6 de la misma maquina en el mismo"
        echo "pais: si Google ubica tu IPv4 en otro sitio, los anuncios de"
        echo "AdMob salen de ese pais y el eCPM cambia."
        line
        echo "  1) Comprobar por donde sale AHORA"
        echo "  2) Preferir IPv6   (recomendado si tu IPv6 geolocaliza bien)"
        echo "  3) Forzar IPv4"
        echo "  4) Dejar lo que traiga el sistema"
        echo "  0) Volver"
        line
        case "$(ask 'Opcion: ')" in
            1) net_pref_probar; pause ;;
            2) net_pref_ipv6; ok "Se prefiere IPv6"; net_pref_probar; pause ;;
            3) net_pref_ipv4; ok "Se fuerza IPv4";  net_pref_probar; pause ;;
            4) net_pref_sistema; ok "Sin preferencia propia"; net_pref_probar; pause ;;
            0) return ;;
        esac
    done
}
