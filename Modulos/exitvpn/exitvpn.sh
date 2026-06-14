#!/bin/bash
# ============================================================
# * Creado y modificado por t:me/JuanitoProSniff
# ============================================================
# EXITVPN_MODULE_VERSION: msyvpn-exitvpn-2
#
# MÓDULO SALIDA REMOTA (DOBLE VPN) — MSYVPN-SCRIPT
# ------------------------------------------------------------
# Hace que TODO el tráfico de SALIDA del VPS (y por lo tanto el
# de tus clientes SSH / V2Ray / wsproxy / stunnel / Hysteria /
# slowdns) salga por un servidor V2Ray remoto (ej. Austria) vía
# VLESS-Reality. El mundo ve la IP y geolocalización de Austria.
#
# - Cliente: Xray-core (soporta VLESS Reality + xtls-rprx-vision)
# - Redirección transparente: TPROXY (iptables mangle) + fwmark
#   sobre el tráfico generado localmente (cadena OUTPUT). Las
#   conexiones ENTRANTES de tus clientes NO se tocan (ctdir REPLY),
#   por lo que el acceso a tu VPN nunca se rompe.
# - Failover HÍBRIDO anti-parpadeo: si Austria cae, tras ~30s
#   reintentando se pasa solo a la IP normal del VPS; cuando
#   Austria vuelve y está estable, regresa la salida por Austria.
# - El propio Xray y las respuestas a clientes quedan EXCLUIDOS
#   (mark 255 + ctdir REPLY) para evitar bucles y cortes.
#
# Compatible: Ubuntu/Debian — amd64 / arm64 / arm
# ============================================================

_EV_DIR="/etc/SSHPlus/exitvpn"
_EV_BIN="/usr/local/bin/xray"
_EV_CONFIG="$_EV_DIR/config.json"
_EV_URI="$_EV_DIR/uri.txt"
_EV_VARS="$_EV_DIR/vars"
_EV_NETUP="$_EV_DIR/netup.sh"
_EV_NETDOWN="$_EV_DIR/netdown.sh"
_EV_WATCHDOG="$_EV_DIR/watchdog.sh"
_EV_SVC="msy-exitvpn"
_EV_SVC_WD="msy-exitvpn-watchdog"
_EV_TPROXY_PORT="12345"
_EV_SOCKS_PORT="10808"
_EV_MARK="1"
_EV_SELF_MARK="255"
_EV_TABLE="100"

# ── Detección de arquitectura (independiente del core) ────────
_ev_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "amd64" ;;
        aarch64|arm64)  echo "arm64" ;;
        armv7*|armhf)   echo "arm"   ;;
        armv6*)         echo "arm"   ;;
        *)              echo "amd64" ;;
    esac
}

_ev_xray_installed() { [[ -x "$_EV_BIN" ]]; }
_ev_xray_active()    { systemctl is-active --quiet "$_EV_SVC" 2>/dev/null; }
_ev_wd_active()      { systemctl is-active --quiet "$_EV_SVC_WD" 2>/dev/null; }
_ev_rules_on()       { iptables -t mangle -C OUTPUT -j XRAY_SELF 2>/dev/null; }
_ev_has_uri()        { [[ -s "$_EV_URI" ]]; }

# IP pública real del VPS (salida directa, sin túnel)
_ev_vps_ip() {
    local ip
    [[ -f /etc/IP ]] && ip=$(cat /etc/IP 2>/dev/null | tr -d '[:space:]')
    [[ -z "$ip" ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "${ip:-?}"
}

# ── Resolver host → IPv4 (sin depender de un solo método) ─────
_ev_resolve() {
    local host="$1" ip=""
    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "$host"; return; fi
    ip=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | head -1)
    [[ -z "$ip" ]] && ip=$(dig +short A "$host" 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
    [[ -z "$ip" ]] && ip=$(python3 -c "import socket;print(socket.gethostbyname('$host'))" 2>/dev/null)
    echo "$ip"
}

_ev_urldecode() {
    local s="${1//+/ }"
    printf '%b' "${s//%/\\x}"
}

# ============================================================
# PARSEAR URI VLESS  → variables EV_*
# ============================================================
_ev_parse_uri() {
    local uri; uri=$(echo "$1" | xargs)
    [[ "$uri" != vless://* ]] && return 2
    uri="${uri#vless://}"
    uri="${uri%%#*}"
    local main="${uri%%\?*}" query=""
    [[ "$uri" == *\?* ]] && query="${uri#*\?}"

    EV_UUID="${main%%@*}"
    local hostport="${main#*@}"
    EV_HOST="${hostport%:*}"
    EV_PORT="${hostport##*:}"

    EV_SEC="";  EV_ENC="none"; EV_PBK=""; EV_SID=""; EV_SNI=""
    EV_FP="";   EV_SPX="";     EV_TYPE=""; EV_FLOW=""; EV_PATH=""
    EV_HOSTHDR=""; EV_SVCNAME=""

    local IFS='&' kv k v
    for kv in $query; do
        k="${kv%%=*}"; v="${kv#*=}"; v="$(_ev_urldecode "$v")"
        case "$k" in
            security)    EV_SEC="$v" ;;
            encryption)  EV_ENC="$v" ;;
            pbk)         EV_PBK="$v" ;;
            sid)         EV_SID="$v" ;;
            sni)         EV_SNI="$v" ;;
            fp)          EV_FP="$v" ;;
            spx)         EV_SPX="$v" ;;
            type)        EV_TYPE="$v" ;;
            flow)        EV_FLOW="$v" ;;
            path)        EV_PATH="$v" ;;
            host)        EV_HOSTHDR="$v" ;;
            serviceName) EV_SVCNAME="$v" ;;
        esac
    done

    [[ -z "$EV_TYPE" ]] && EV_TYPE="tcp"
    [[ -z "$EV_SEC"  ]] && EV_SEC="none"
    [[ -z "$EV_FP"   ]] && EV_FP="chrome"
    [[ -z "$EV_SNI"  ]] && EV_SNI="$EV_HOST"
    [[ -z "$EV_SPX"  ]] && EV_SPX="/"

    if ! [[ "$EV_UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
        return 3
    fi
    [[ -z "$EV_HOST" || -z "$EV_PORT" ]] && return 3
    [[ ! "$EV_PORT" =~ ^[0-9]+$ ]] && return 3
    return 0
}

# ============================================================
# INSTALAR Xray-core (binario oficial XTLS, multi-arch)
# ============================================================
_ev_install_xray() {
    _ev_xray_installed && return 0
    echo -e "\n\033[1;33m  Instalando dependencias...\033[0m"
    apt-get update -y >/dev/null 2>&1
    apt-get install -y unzip curl wget iptables iproute2 ca-certificates >/dev/null 2>&1

    local zip
    case "$(_ev_arch)" in
        amd64) zip="Xray-linux-64.zip" ;;
        arm64) zip="Xray-linux-arm64-v8a.zip" ;;
        arm)   zip="Xray-linux-arm32-v7a.zip" ;;
        *)     zip="Xray-linux-64.zip" ;;
    esac
    local url="https://github.com/XTLS/Xray-core/releases/latest/download/${zip}"
    local tmp="/tmp/xray_$$.zip" ext="/tmp/xray_ext_$$"

    echo -e "\033[1;33m  Descargando Xray-core ($zip)...\033[0m"
    wget -q --timeout=90 "$url" -O "$tmp" 2>/dev/null
    [[ ! -s "$tmp" ]] && curl -fsSL --max-time 90 "$url" -o "$tmp" 2>/dev/null
    if [[ ! -s "$tmp" ]]; then
        echo -e "\033[1;31m  ✗ No se pudo descargar Xray-core.\033[0m"
        rm -f "$tmp"; return 1
    fi
    rm -rf "$ext"; mkdir -p "$ext" /usr/local/share/xray
    unzip -o "$tmp" -d "$ext" >/dev/null 2>&1
    if [[ ! -x "$ext/xray" ]]; then
        echo -e "\033[1;31m  ✗ Paquete Xray inválido.\033[0m"
        rm -rf "$tmp" "$ext"; return 1
    fi
    install -m 755 "$ext/xray" "$_EV_BIN"
    cp -f "$ext"/*.dat /usr/local/share/xray/ 2>/dev/null
    rm -rf "$tmp" "$ext"
    echo -e "\033[1;32m  ✓ Xray-core instalado: $_EV_BIN\033[0m"
    _ev_xray_installed
}

# ============================================================
# ESCRIBIR config.json de Xray a partir de las variables EV_*
# Address = IP resuelta (sin DNS), serverName = SNI (Reality).
# ============================================================
_ev_write_config() {
    local flowval=""
    if [[ "$EV_TYPE" == "tcp" && ( "$EV_SEC" == "reality" || "$EV_SEC" == "tls" ) && -n "$EV_FLOW" ]]; then
        flowval="$EV_FLOW"
    fi
    local user_json="\"id\": \"${EV_UUID}\", \"encryption\": \"none\""
    [[ -n "$flowval" ]] && user_json="${user_json}, \"flow\": \"${flowval}\""

    local net_json
    case "$EV_TYPE" in
        ws)
            local hdr=""
            [[ -n "$EV_HOSTHDR" ]] && hdr=", \"headers\": {\"Host\": \"${EV_HOSTHDR}\"}"
            net_json="\"network\": \"ws\", \"wsSettings\": {\"path\": \"${EV_PATH:-/}\"${hdr}}"
            ;;
        grpc)
            net_json="\"network\": \"grpc\", \"grpcSettings\": {\"serviceName\": \"${EV_SVCNAME}\"}"
            ;;
        *)
            net_json="\"network\": \"tcp\""
            ;;
    esac

    local sec_json
    case "$EV_SEC" in
        reality)
            sec_json="\"security\": \"reality\", \"realitySettings\": {\"show\": false, \"fingerprint\": \"${EV_FP}\", \"serverName\": \"${EV_SNI}\", \"publicKey\": \"${EV_PBK}\", \"shortId\": \"${EV_SID}\", \"spiderX\": \"${EV_SPX}\"}"
            ;;
        tls)
            sec_json="\"security\": \"tls\", \"tlsSettings\": {\"serverName\": \"${EV_SNI}\", \"fingerprint\": \"${EV_FP}\", \"allowInsecure\": false}"
            ;;
        *)
            sec_json="\"security\": \"none\""
            ;;
    esac

    mkdir -p "$_EV_DIR"
    cat > "$_EV_CONFIG" <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "tproxy-in",
      "listen": "127.0.0.1",
      "port": ${_EV_TPROXY_PORT},
      "protocol": "dokodemo-door",
      "settings": { "network": "tcp,udp", "followRedirect": true },
      "streamSettings": { "sockopt": { "tproxy": "tproxy" } },
      "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"], "routeOnly": false }
    },
    {
      "tag": "socks-probe",
      "listen": "127.0.0.1",
      "port": ${_EV_SOCKS_PORT},
      "protocol": "socks",
      "settings": { "udp": false }
    }
  ],
  "outbounds": [
    {
      "tag": "austria",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${_EV_SERVER_IP}",
            "port": ${EV_PORT},
            "users": [ { ${user_json} } ]
          }
        ]
      },
      "streamSettings": { ${net_json}, ${sec_json}, "sockopt": { "mark": ${_EV_SELF_MARK} } }
    },
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {},
      "streamSettings": { "sockopt": { "mark": ${_EV_SELF_MARK} } }
    },
    { "tag": "block", "protocol": "blackhole", "settings": {} }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "ip": ["0.0.0.0/8","10.0.0.0/8","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.168.0.0/16","100.64.0.0/10","224.0.0.0/4","240.0.0.0/4"], "outboundTag": "direct" },
      { "type": "field", "network": "tcp,udp", "outboundTag": "austria" }
    ]
  }
}
JSON
    chmod 600 "$_EV_CONFIG"
}

# ============================================================
# ESCRIBIR vars + scripts de red (netup/netdown) + watchdog
# ============================================================
_ev_write_vars() {
    mkdir -p "$_EV_DIR"
    cat > "$_EV_VARS" <<VARS
AUSTRIA_IP=${_EV_SERVER_IP}
AUSTRIA_PORT=${EV_PORT}
AUSTRIA_HOST=${EV_HOST}
TPROXY_PORT=${_EV_TPROXY_PORT}
SOCKS_PORT=${_EV_SOCKS_PORT}
MARK=${_EV_MARK}
SELF_MARK=${_EV_SELF_MARK}
TABLE=${_EV_TABLE}
VARS
    chmod 600 "$_EV_VARS"
}

_ev_write_netscripts() {
    mkdir -p "$_EV_DIR"

    cat > "$_EV_NETUP" <<'NETUP'
#!/bin/bash
# Activa la redirección transparente del egress local hacia Xray (Austria).
D="/etc/SSHPlus/exitvpn"
. "$D/vars" 2>/dev/null
TP="${TPROXY_PORT:-12345}"; M="${MARK:-1}"; SM="${SELF_MARK:-255}"
T="${TABLE:-100}"; SIP="${AUSTRIA_IP}"

sysctl -w net.ipv4.ip_forward=1            >/dev/null 2>&1
sysctl -w net.ipv4.conf.all.rp_filter=0    >/dev/null 2>&1
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1
sysctl -w net.ipv4.conf.lo.rp_filter=0     >/dev/null 2>&1
sysctl -w net.ipv4.conf.lo.route_localnet=1 >/dev/null 2>&1

ip rule del fwmark $M lookup $T 2>/dev/null
ip rule add fwmark $M lookup $T
ip route replace local default dev lo table $T

PRIV="0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 224.0.0.0/4 240.0.0.0/4"

# PREROUTING — solo intercepta el tráfico re-inyectado desde OUTPUT (destino remoto).
# CLAVE: el tráfico dirigido a la PROPIA IP del VPS (SSH admin, clientes que se
# conectan a tus servicios) se EXCLUYE con addrtype LOCAL → nunca se secuestra.
iptables -t mangle -F XRAY 2>/dev/null; iptables -t mangle -N XRAY 2>/dev/null
iptables -t mangle -A XRAY -m addrtype --dst-type LOCAL -j RETURN
iptables -t mangle -A XRAY -m mark --mark $SM -j RETURN
for n in $PRIV; do iptables -t mangle -A XRAY -d $n -j RETURN; done
[ -n "$SIP" ] && iptables -t mangle -A XRAY -d "$SIP" -j RETURN
iptables -t mangle -A XRAY -p udp -j TPROXY --on-port $TP --tproxy-mark $M
iptables -t mangle -A XRAY -p tcp -j TPROXY --on-port $TP --tproxy-mark $M
iptables -t mangle -C PREROUTING -j XRAY 2>/dev/null || iptables -t mangle -A PREROUTING -j XRAY

# OUTPUT — tráfico generado por el propio VPS (lo que sale por cada protocolo)
iptables -t mangle -F XRAY_SELF 2>/dev/null; iptables -t mangle -N XRAY_SELF 2>/dev/null
iptables -t mangle -A XRAY_SELF -m addrtype --dst-type LOCAL -j RETURN  # a la propia
