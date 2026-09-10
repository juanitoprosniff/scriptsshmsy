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

# ============================================================================
#  DESCARGAS: POR QUE ANTES FALLABAN "A VECES"
# ============================================================================
#  El sintoma clasico era: instalas o actualizas y sale "no se descargo V2Ray"
#  o "no se compilo SOCKS5"; le das otra vez y funciona. La causa era que la
#  descarga se hacia de UN SOLO INTENTO:
#
#      wget -q "$REPO_RAW/bin/$name-$a" -O "$dest" 2>/dev/null || \
#      wget -q "$REPO_RAW/bin/$name"    -O "$dest" 2>/dev/null
#
#  Sin reintentos, sin tiempo limite y con la salida tirada a /dev/null. Un
#  parpadeo de red, un corte de DNS o un limite de github durante dos segundos
#  dejaban ese binario fuera para siempre — y como el error no se veia, la
#  instalacion seguia adelante como si nada y el servicio no arrancaba.
#
#  Ademas no se comprobaba QUE se habia descargado: si github devolvia una
#  pagina de error, el archivo no estaba vacio, pasaba el "-s", se le hacia
#  chmod +x y el servicio moria luego con "Exec format error" — que no se
#  parece en nada a un fallo de descarga.
#
#  Ahora: 3 intentos con espera creciente, tiempo limite, curl como respaldo si
#  no hay wget, y se comprueba que lo bajado sea de verdad un ejecutable.

# descargar <url> <destino> — 3 intentos. Deja el destino intacto si falla.
descargar() {
    local url="$1" dest="$2" tmp="$2.dl.$$" intento
    for intento in 1 2 3; do
        rm -f "$tmp"
        if command -v wget >/dev/null 2>&1; then
            wget -q --timeout=20 --tries=1 "$url" -O "$tmp" 2>/dev/null
        elif command -v curl >/dev/null 2>&1; then
            curl -fsSL --max-time 20 "$url" -o "$tmp" 2>/dev/null
        else
            rm -f "$tmp"; return 1
        fi
        if [[ -s "$tmp" ]]; then
            mv -f "$tmp" "$dest"
            return 0
        fi
        # Espera creciente: 2 s, 4 s. Un limite de github se pasa solo.
        [[ $intento -lt 3 ]] && sleep $((intento * 2))
    done
    rm -f "$tmp"
    return 1
}

# ¿Esto es un ejecutable de verdad, o la pagina de error de github?
es_ejecutable() {
    [[ -s "$1" ]] || return 1
    # ELF empieza por 0x7F 'E' 'L' 'F'. Un script empieza por "#!".
    local m; m=$(head -c 4 "$1" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
    [[ "$m" == "7f454c46" ]] && return 0
    head -c 2 "$1" 2>/dev/null | grep -q '#!' && return 0
    return 1
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
        descargar "$REPO_RAW/bin/$name-$a" "$dest" || \
        descargar "$REPO_RAW/bin/$name"    "$dest" || {
            msy_anotar_fallo "descarga de $name ($a)"
            return 1
        }
    fi
    if ! es_ejecutable "$dest"; then
        rm -f "$dest"
        msy_anotar_fallo "$name descargado pero no es un ejecutable valido"
        return 1
    fi
    chmod +x "$dest"
    return 0
}

# ---------------------------------------------------------------
# El parte de averias
# ---------------------------------------------------------------
#
# Casi todo el instalador corre con ">/dev/null 2>&1" para que la salida sea
# legible. El precio era que un fallo desaparecia sin dejar rastro y el usuario
# solo veia "(se puede activar luego desde el menu)" sin saber por que.
#
# Esto lo apunta en un archivo. Al final de la instalacion se resume, y queda
# ahi para consultarlo despues.
MSY_FALLOS="$DATA_DIR/fallos.log"

msy_anotar_fallo() {
    echo "$(date '+%Y-%m-%d %H:%M:%S')  $*" >> "$MSY_FALLOS" 2>/dev/null
}

msy_reset_fallos() { : > "$MSY_FALLOS" 2>/dev/null; }

msy_resumen_fallos() {
    [[ -s "$MSY_FALLOS" ]] || return 0
    echo ""
    echo "  ATENCION: algo no quedo bien"
    echo "  ------------------------------------------------------------"
    sed 's/^/  /' "$MSY_FALLOS"
    echo "  ------------------------------------------------------------"
    echo "  Casi siempre es un corte de red pasajero. Reintentar suele"
    echo "  bastar: menu -> el protocolo que falte -> Instalar."
    echo "  Este parte queda en $MSY_FALLOS"
    echo ""
}

get_ip() {
    local ip
    [[ -s /etc/msyvpn/ip ]] && ip=$(cat /etc/msyvpn/ip)
    [[ -z "$ip" ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$ip" ]] && ip=$(curl -s -4 --max-time 4 ifconfig.me 2>/dev/null)
    echo "${ip:-0.0.0.0}"
}

# ---------------------------------------------------------------
# Por que familia salen las conexiones que NACEN en la VPS
# ---------------------------------------------------------------
#
# OJO CON EL ALCANCE, que es la parte que se malinterpreta:
#
#   SI afecta  -> a lo que la VPS inicia por su cuenta: curl, apt, acme.sh,
#                 las consultas del propio script...
#   NO afecta  -> al trafico de los usuarios del tunel.
#
# El motivo es que el trafico del tunel no lo INICIA la VPS: llega ya dirigido
# a una IP concreta y la VPS solo lo reenvia (NAT). Quien decidio si esa IP era
# la v4 o la v6 de Google fue EL TELEFONO, al resolver el nombre, y lo decidio
# segun lo que su propio tunel le ofrezca.
#
# Consecuencia: si el tunel del telefono es IPv4 puro, TODO sale por la IPv4 de
# la VPS haga lo que haga este archivo. Para que un usuario salga por IPv6 hay
# que llevar IPv6 DENTRO del tunel (en la app: "IPv6 dentro del tunel"), no
# tocar gai.conf.
#
# Aun asi esto se mantiene porque decide con que IP se ve la VPS a si misma
# frente a servicios externos, y porque el diagnostico de abajo es la forma mas
# rapida de saber si la maquina tiene IPv6 util y donde la situan.
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
# Pais de una IP, segun un servicio publico. Vacio si no se puede saber.
_geo_de() {
    [[ -z "$1" ]] && return 0
    # sed y no "grep -P": -P no esta en todos los grep (busybox, y en algunas
    # locales GNU lo rechaza). Aqui hace falta que funcione en cualquier VPS.
    curl -s --max-time 8 "https://ipinfo.io/$1/json" 2>/dev/null \
        | sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -1
}

net_pref_probar() {
    local v4 v6 auto g4 g6
    v4=$(curl -4 -s --max-time 6 https://ifconfig.me 2>/dev/null)
    v6=$(curl -6 -s --max-time 6 https://ifconfig.me 2>/dev/null)
    auto=$(curl -s --max-time 6 https://ifconfig.me 2>/dev/null)

    g4=$(_geo_de "$v4"); g6=$(_geo_de "$v6")

    echo "  IPv4 de la VPS : ${v4:-(sin IPv4)}   pais: ${g4:-?}"
    echo "  IPv6 de la VPS : ${v6:-(SIN IPv6)}   pais: ${g6:-?}"
    echo "  La VPS sale por: ${auto:-(sin respuesta)}"
    line
    if [[ -z "$v6" ]]; then
        err "Esta VPS NO tiene IPv6 util."
        info "Entonces todos tus usuarios saldran por la IPv4 pase lo que pase,"
        info "y el unico camino es cambiar de IPv4 o pedir la correccion de su"
        info "geolocalizacion. Llevar IPv6 al tunel no serviria de nada."
    elif [[ -n "$g4" && -n "$g6" && "$g4" != "$g6" ]]; then
        info "Tu IPv4 y tu IPv6 estan en PAISES DISTINTOS ($g4 vs $g6)."
        info "Para que un usuario salga por la IPv6 hay que activar en la app"
        info "'IPv6 dentro del tunel'. Con el tunel en IPv4 puro siempre saldra"
        info "por $g4."
    elif [[ -n "$g4" ]]; then
        ok "Las dos familias geolocalizan igual ($g4): el pais no depende de esto."
    fi
    info "Ojo: Google usa SU base, que puede no coincidir con la de aqui."
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
        clear; title "DIAGNOSTICO IPv4 / IPv6"
        echo "Preferencia de la propia VPS: $(net_pref_estado)"
        line
        echo "La opcion 1 es la util: dice que IPs tiene esta VPS y en que"
        echo "pais las situan. Si la IPv4 y la IPv6 estan en paises distintos,"
        echo "eso explica el pais que ven Google y AdMob."
        echo ""
        echo "OJO: las opciones 2 y 3 solo afectan a lo que la VPS inicia por"
        echo "su cuenta (curl, apt...), NO al trafico de los usuarios. Para que"
        echo "un usuario salga por IPv6 hay que activar 'IPv6 dentro del tunel'"
        echo "en la app: es el telefono quien elige, no la VPS."
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
