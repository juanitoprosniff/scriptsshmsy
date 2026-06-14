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
iptables -t mangle -A XRAY_SELF -m addrtype --dst-type LOCAL -j RETURN  # a la propia máquina → directo
iptables -t mangle -A XRAY_SELF -m mark --mark $SM -j RETURN            # el propio Xray → directo (evita bucle)
for n in $PRIV; do iptables -t mangle -A XRAY_SELF -d $n -j RETURN; done
[ -n "$SIP" ] && iptables -t mangle -A XRAY_SELF -d "$SIP" -j RETURN
iptables -t mangle -A XRAY_SELF -m conntrack --ctdir REPLY -j RETURN    # respuestas a clientes entrantes → no tocar
iptables -t mangle -A XRAY_SELF -p udp -j MARK --set-mark $M
iptables -t mangle -A XRAY_SELF -p tcp -j MARK --set-mark $M
iptables -t mangle -C OUTPUT -j XRAY_SELF 2>/dev/null || iptables -t mangle -A OUTPUT -j XRAY_SELF

# Anti-fuga IPv6: bloquear nuevas conexiones salientes IPv6 (evita filtrar la geo real)
if command -v ip6tables >/dev/null 2>&1; then
    if ! ip6tables -C OUTPUT -j XRAY6 2>/dev/null; then
        ip6tables -F XRAY6 2>/dev/null; ip6tables -N XRAY6 2>/dev/null
        ip6tables -A XRAY6 -o lo -j RETURN
        ip6tables -A XRAY6 -d ::1/128 -j RETURN
        ip6tables -A XRAY6 -d fe80::/10 -j RETURN
        ip6tables -A XRAY6 -d fc00::/7 -j RETURN
        ip6tables -A XRAY6 -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
        ip6tables -A XRAY6 -p tcp -j REJECT --reject-with tcp-reset
        ip6tables -A XRAY6 -p udp -j REJECT
        ip6tables -A OUTPUT -j XRAY6
    fi
fi
exit 0
NETUP

    cat > "$_EV_NETDOWN" <<'NETDOWN'
#!/bin/bash
# Quita toda la redirección → el VPS vuelve a salir por su IP normal.
D="/etc/SSHPlus/exitvpn"
. "$D/vars" 2>/dev/null
M="${MARK:-1}"; T="${TABLE:-100}"

iptables -t mangle -D OUTPUT -j XRAY_SELF 2>/dev/null
iptables -t mangle -D PREROUTING -j XRAY 2>/dev/null
iptables -t mangle -F XRAY_SELF 2>/dev/null; iptables -t mangle -X XRAY_SELF 2>/dev/null
iptables -t mangle -F XRAY 2>/dev/null;      iptables -t mangle -X XRAY 2>/dev/null
ip rule del fwmark $M lookup $T 2>/dev/null
ip route flush table $T 2>/dev/null

if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -D OUTPUT -j XRAY6 2>/dev/null
    ip6tables -F XRAY6 2>/dev/null; ip6tables -X XRAY6 2>/dev/null
fi
exit 0
NETDOWN

    cat > "$_EV_WATCHDOG" <<'WD'
#!/bin/bash
# Failover HÍBRIDO anti-parpadeo entre salida-Austria e IP-normal.
# La salud se mide de EXTREMO A EXTREMO: una petición real a través del túnel
# (SOCKS interno → Xray → Austria). Así la redirección global solo se aplica
# cuando el túnel DE VERDAD navega; si no, se usa la IP normal del VPS.
D="/etc/SSHPlus/exitvpn"
. "$D/vars" 2>/dev/null
SOCKS="${SOCKS_PORT:-10808}"; TP="${TPROXY_PORT:-12345}"
SVC="msy-exitvpn"
CHECK_INT=10        # cada 10s
FAIL_NEEDED=3       # ~30s sin túnel antes de pasar a IP normal
OK_NEEDED=2         # ~20s de túnel estable antes de volver a Austria

xray_up()   { systemctl is-active --quiet "$SVC" && ss -tlnp 2>/dev/null | grep -q "127.0.0.1:${TP} "; }
tunnel_ok() {
    # Navega a través del túnel sin depender de las reglas iptables.
    local u
    for u in "http://www.gstatic.com/generate_204" "http://cp.cloudflare.com/generate_204" "http://connectivitycheck.gstatic.com/generate_204"; do
        curl -s --max-time 8 --socks5-hostname "127.0.0.1:${SOCKS}" -o /dev/null "$u" 2>/dev/null && return 0
    done
    return 1
}
rules_on()  { iptables -t mangle -C OUTPUT -j XRAY_SELF 2>/dev/null; }

fails=0; oks=0
while true; do
    if xray_up && tunnel_ok; then
        oks=$((oks+1)); fails=0
        if ! rules_on && [ "$oks" -ge "$OK_NEEDED" ]; then
            bash "$D/netup.sh"
            logger -t exitvpn "Tunel estable -> salida remota ACTIVADA"
        fi
    else
        fails=$((fails+1)); oks=0
        systemctl is-active --quiet "$SVC" || systemctl start "$SVC" 2>/dev/null
        if rules_on && [ "$fails" -ge "$FAIL_NEEDED" ]; then
            bash "$D/netdown.sh"
            logger -t exitvpn "Tunel caido -> FALLBACK a IP normal del VPS"
        fi
    fi
    sleep "$CHECK_INT"
done
WD

    chmod 755 "$_EV_NETUP" "$_EV_NETDOWN" "$_EV_WATCHDOG"
}

_ev_write_units() {
    cat > "/etc/systemd/system/${_EV_SVC}.service" <<UNIT
[Unit]
Description=MSYVPN Exit (Xray Reality client) - salida por servidor remoto
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${_EV_BIN} run -config ${_EV_CONFIG}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
UNIT

    cat > "/etc/systemd/system/${_EV_SVC_WD}.service" <<UNIT
[Unit]
Description=MSYVPN Exit watchdog - failover Austria <-> IP normal
After=${_EV_SVC}.service

[Service]
Type=simple
ExecStart=/bin/bash ${_EV_WATCHDOG}
ExecStopPost=/bin/bash ${_EV_NETDOWN}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload 2>/dev/null
}

# ============================================================
# GUARDAR / CAMBIAR URI
# ============================================================
_ev_set_uri() {
    echo ""
    echo -e "\033[1;33m  Pega la URI VLESS del servidor remoto (ej. Austria) y ENTER.\033[0m"
    echo -e "\033[1;37m  Debe empezar con \033[1;36mvless://\033[1;37m (Reality/TLS/WS son soportados).\033[0m"
    echo -ne "\n\033[1;32m  URI: \033[1;37m"; read _uri
    [[ -z "$_uri" ]] && { echo -e "\033[1;31m  ✗ Nada ingresado.\033[0m"; sleep 2; return 1; }

    _ev_parse_uri "$_uri"
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        echo -e "\033[1;31m  ✗ URI inválida (código $rc). Verifica el formato vless://...\033[0m"
        sleep 3; return 1
    fi

    mkdir -p "$_EV_DIR"
    echo "$_uri" > "$_EV_URI"
    chmod 600 "$_EV_URI"

    echo -e "\n\033[1;32m  ✓ URI guardada. Datos detectados:\033[0m"
    echo -e "\033[1;33m    Host    : \033[1;37m${EV_HOST}:${EV_PORT}\033[0m"
    echo -e "\033[1;33m    Tipo    : \033[1;37m${EV_TYPE} / ${EV_SEC}\033[0m"
    echo -e "\033[1;33m    SNI     : \033[1;37m${EV_SNI}\033[0m"
    [[ -n "$EV_FLOW" ]] && echo -e "\033[1;33m    Flow    : \033[1;37m${EV_FLOW}\033[0m"

    if _ev_xray_active || _ev_wd_active; then
        echo -ne "\n\033[1;33m  Salida ya activa: ¿aplicar la nueva URI ahora? [S/n]: \033[1;37m"; read _r
        [[ ! "$_r" =~ ^[nN]$ ]] && { _ev_start silent; return; }
    fi
    sleep 1
}

# ============================================================
# INICIAR / DETENER / REINICIAR
# ============================================================
_ev_prepare() {
    # Devuelve 0 si todo quedó listo para arrancar.
    _ev_has_uri || { echo -e "\033[1;31m  ✗ No hay URI guardada. Usa la opción 'Agregar URI'.\033[0m"; return 1; }
    _ev_parse_uri "$(cat "$_EV_URI")" || { echo -e "\033[1;31m  ✗ URI guardada inválida.\033[0m"; return 1; }

    _ev_install_xray || return 1

    echo -e "\033[1;33m  Resolviendo ${EV_HOST}...\033[0m"
    _EV_SERVER_IP=$(_ev_resolve "$EV_HOST")
    if [[ -z "$_EV_SERVER_IP" ]]; then
        echo -e "\033[1;31m  ✗ No se pudo resolver ${EV_HOST}. ¿DNS/conexión?\033[0m"
        return 1
    fi
    echo -e "\033[1;32m  ✓ ${EV_HOST} → ${_EV_SERVER_IP}\033[0m"

    _ev_write_config
    _ev_write_vars
    _ev_write_netscripts
    _ev_write_units

    # Validar config con el propio binario
    if ! "$_EV_BIN" run -test -config "$_EV_CONFIG" >/tmp/exitvpn_test.log 2>&1; then
        if ! "$_EV_BIN" -test -config "$_EV_CONFIG" >/tmp/exitvpn_test.log 2>&1; then
            echo -e "\033[1;31m  ✗ Config Xray inválida. Log: /tmp/exitvpn_test.log\033[0m"
            tail -n 6 /tmp/exitvpn_test.log 2>/dev/null
            return 1
        fi
    fi
    return 0
}

_ev_start() {
    local mode="$1"
    [[ "$mode" != "silent" ]] && clear
    echo -e "\033[0;34m┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\033[0m"
    echo -e "\033[0;34m┃\E[44;1;37m       INICIANDO SALIDA POR AUSTRIA      \E[0m\033[0;34m┃"
    echo -e "\033[0;34m┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\033[0m"

    _ev_prepare || { echo -ne "\n\033[1;33m  ENTER para continuar...\033[0m"; read; return 1; }

    echo -e "\033[1;33m  Arrancando Xray...\033[0m"
    systemctl enable "$_EV_SVC" >/dev/null 2>&1
    systemctl restart "$_EV_SVC"

    # Esperar a que escuche el puerto tproxy
    local i ok=0
    for ((i=0; i<12; i++)); do
        if _ev_xray_active && ss -tlnp 2>/dev/null | grep -q "127.0.0.1:${_EV_TPROXY_PORT} "; then
            ok=1; break
        fi
        sleep 1
    done
    if [[ $ok -ne 1 ]]; then
        echo -e "\033[1;31m  ✗ Xray no arrancó. journalctl -u ${_EV_SVC} -n 30\033[0m"
        echo -ne "\n\033[1;33m  ENTER para continuar...\033[0m"; read; return 1
    fi
    echo -e "\033[1;32m  ✓ Xray activo (tproxy 127.0.0.1:${_EV_TPROXY_PORT})\033[0m"

    # Watchdog primero: él es el dueño de aplicar/quitar la redirección de forma
    # segura (solo la pone si el túnel navega de verdad). Así nunca te encierra.
    echo -e "\033[1;33m  Activando watchdog de failover...\033[0m"
    systemctl enable "$_EV_SVC_WD" >/dev/null 2>&1
    systemctl restart "$_EV_SVC_WD"

    echo -e "\033[1;33m  Verificando que el túnel realmente navega (sonda interna)...\033[0m"
    local i probe=0
    for ((i=0; i<15; i++)); do
        if _ev_tunnel_probe; then probe=1; break; fi
        sleep 2
    done

    if [[ $probe -eq 1 ]]; then
        bash "$_EV_NETUP"
        echo -e "\n\033[1;32m  ✓ TÚNEL OK — SALIDA REMOTA ACTIVA.\033[0m"
        sleep 1
        _ev_show_exit_ip
    else
        echo -e "\n\033[1;31m  ⚠ El túnel aún no navega — NO se activó la redirección.\033[0m"
        echo -e "\033[1;32m  Tu VPS sigue accesible con su IP normal (no te encierra).\033[0m"
        echo -e "\033[1;37m  El watchdog activará la salida AUTOMÁTICAMENTE en cuanto el\033[0m"
        echo -e "\033[1;37m  túnel funcione. Si nunca lo hace, revisa la URI:\033[0m"
        echo -e "\033[1;33m    journalctl -u ${_EV_SVC} -n 30\033[0m"
    fi
    [[ "$mode" != "silent" ]] && { echo -ne "\n\033[1;33m  ENTER para continuar...\033[0m"; read; }
    return 0
}

# Sonda de túnel: navega a través del SOCKS interno (Xray→remoto), sin
# depender de las reglas iptables. Devuelve 0 si el túnel funciona.
_ev_tunnel_probe() {
    local u
    for u in "http://www.gstatic.com/generate_204" "http://cp.cloudflare.com/generate_204" "http://connectivitycheck.gstatic.com/generate_204"; do
        curl -s --max-time 8 --socks5-hostname "127.0.0.1:${_EV_SOCKS_PORT}" -o /dev/null "$u" 2>/dev/null && return 0
    done
    return 1
}

_ev_stop() {
    clear
    echo -e "\033[1;33m  Deteniendo salida por Austria (volviendo a IP normal)...\033[0m"
    systemctl disable "$_EV_SVC_WD" >/dev/null 2>&1
    systemctl stop "$_EV_SVC_WD" 2>/dev/null
    [[ -x "$_EV_NETDOWN" ]] && bash "$_EV_NETDOWN"
    systemctl disable "$_EV_SVC" >/dev/null 2>&1
    systemctl stop "$_EV_SVC" 2>/dev/null
    echo -e "\033[1;32m  ✓ Salida remota detenida. El VPS usa su IP normal.\033[0m"
    sleep 2
}

_ev_restart() {
    clear
    echo -e "\033[1;33m  Reiniciando salida por Austria...\033[0m"
    systemctl stop "$_EV_SVC_WD" 2>/dev/null
    [[ -x "$_EV_NETDOWN" ]] && bash "$_EV_NETDOWN"
    systemctl stop "$_EV_SVC" 2>/dev/null
    sleep 1
    _ev_start
}

# ============================================================
# IP DE SALIDA (lo que ve el mundo) — pasa por el túnel si activo
# ============================================================
_ev_show_exit_ip() {
    local j ip country
    for url in "http://ip-api.com/json/?fields=query,country,countryCode" "https://ipinfo.io/json"; do
        j=$(curl -s --max-time 8 "$url" 2>/dev/null)
        [[ -n "$j" ]] && break
    done
    if [[ -z "$j" ]]; then
        echo -e "\033[1;31m  No se pudo consultar la IP de salida.\033[0m"
        return
    fi
    ip=$(echo "$j" | grep -oE '"(query|ip)"[ ]*:[ ]*"[^"]+"' | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    country=$(echo "$j" | grep -oE '"country"[ ]*:[ ]*"[^"]+"' | head -1 | sed -E 's/.*:[ ]*"([^"]+)"/\1/')
    echo -e "\033[1;33m  IP de salida (mundo): \033[1;32m${ip:-?}\033[0m"
    echo -e "\033[1;33m  País                : \033[1;32m${country:-?}\033[0m"
    echo -e "\033[1;33m  IP normal del VPS   : \033[1;37m$(_ev_vps_ip)\033[0m"
}

# ============================================================
# ESTADO DETALLADO
# ============================================================
_ev_status() {
    clear
    echo -e "\033[0;34m┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\033[0m"
    echo -e "\033[0;34m┃\E[44;1;37m        ESTADO — SALIDA REMOTA           \E[0m\033[0;34m┃"
    echo -e "\033[0;34m┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\033[0m"

    local s_bin s_xray s_wd s_rules
    _ev_xray_installed && s_bin="\033[1;32m✓ instalado\033[0m"  || s_bin="\033[1;31m✕ no instalado\033[0m"
    _ev_xray_active    && s_xray="\033[1;32m✓ activo\033[0m"    || s_xray="\033[1;31m✕ detenido\033[0m"
    _ev_wd_active      && s_wd="\033[1;32m✓ activo\033[0m"      || s_wd="\033[1;31m✕ detenido\033[0m"
    _ev_rules_on       && s_rules="\033[1;32m✓ salida por Austria\033[0m" || s_rules="\033[1;33m✕ IP normal (directo)\033[0m"

    echo -e "\033[1;33m  Xray-core   : \033[0m$s_bin"
    echo -e "\033[1;33m  Servicio    : \033[0m$s_xray"
    echo -e "\033[1;33m  Watchdog    : \033[0m$s_wd"
    echo -e "\033[1;33m  Redirección : \033[0m$s_rules"

    if _ev_has_uri && _ev_parse_uri "$(cat "$_EV_URI")"; then
        echo -e "\033[1;33m  Servidor    : \033[1;37m${EV_HOST}:${EV_PORT}  (${EV_SEC}/${EV_TYPE})\033[0m"
        local sip; sip=$(grep '^AUSTRIA_IP=' "$_EV_VARS" 2>/dev/null | cut -d= -f2)
        if [[ -n "$sip" ]]; then
            if timeout 6 bash -c "exec 3<>/dev/tcp/${sip}/${EV_PORT}" 2>/dev/null; then
                echo -e "\033[1;33m  Alcanzable  : \033[1;32m✓ ${sip}:${EV_PORT}\033[0m"
            else
                echo -e "\033[1;33m  Alcanzable  : \033[1;31m✕ ${sip}:${EV_PORT} no responde\033[0m"
            fi
        fi
    else
        echo -e "\033[1;33m  Servidor    : \033[1;31msin URI configurada\033[0m"
    fi

    echo ""
    _ev_show_exit_ip
    echo -ne "\n\033[1;33m  ENTER para continuar...\033[0m"; read
}

# ============================================================
# DESINSTALAR
# ============================================================
_ev_uninstall() {
    clear
    echo -ne "\033[1;31m  ¿Seguro que deseas desinstalar la salida remota? [s/N]: \033[1;37m"; read _r
    [[ ! "$_r" =~ ^[sSyY]$ ]] && return
    systemctl disable "$_EV_SVC_WD" >/dev/null 2>&1; systemctl stop "$_EV_SVC_WD" 2>/dev/null
    [[ -x "$_EV_NETDOWN" ]] && bash "$_EV_NETDOWN"
    systemctl disable "$_EV_SVC" >/dev/null 2>&1; systemctl stop "$_EV_SVC" 2>/dev/null
    rm -f "/etc/systemd/system/${_EV_SVC}.service" "/etc/systemd/system/${_EV_SVC_WD}.service"
    systemctl daemon-reload 2>/dev/null
    echo -ne "\033[1;33m  ¿Borrar también el binario Xray y la config guardada? [s/N]: \033[1;37m"; read _r2
    if [[ "$_r2" =~ ^[sSyY]$ ]]; then
        rm -f "$_EV_BIN"; rm -rf "$_EV_DIR" /usr/local/share/xray
        echo -e "\033[1;32m  ✓ Desinstalado por completo.\033[0m"
    else
        echo -e "\033[1;32m  ✓ Servicios removidos. Config/URI conservada en $_EV_DIR\033[0m"
    fi
    sleep 2
}

# ============================================================
# MENÚ PRINCIPAL DEL MÓDULO
# ============================================================
fun_exitvpn() {
    while true; do
        clear
        local s_xray s_rules host=""
        _ev_xray_active && s_rules="" || true
        if _ev_rules_on && _ev_xray_active; then
            s_xray="\033[1;32m✓ ACTIVA (saliendo por Austria)\033[0m"
        elif _ev_xray_active; then
            s_xray="\033[1;33m● Xray activo, redirección en IP normal (failover)\033[0m"
        else
            s_xray="\033[1;31m✕ DETENIDA (IP normal del VPS)\033[0m"
        fi
        _ev_has_uri && _ev_parse_uri "$(cat "$_EV_URI")" 2>/dev/null && host="${EV_HOST}:${EV_PORT}"

        echo -e "\033[0;34m┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\033[0m"
        echo -e "\033[0;34m┃\E[44;1;37m    SALIDA REMOTA / DOBLE VPN (Austria)  \E[0m\033[0;34m┃"
        echo -e "\033[0;34m┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\033[0m"
        echo -e "  \033[1;33mEstado :\033[0m $s_xray"
        echo -e "  \033[1;33mServidor:\033[0m \033[1;37m${host:-(sin URI)}\033[0m"
        echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
        echo -e "\033[1;31m[\033[1;36m01\033[1;31m] \033[1;37mAGREGAR / CAMBIAR URI\033[0m"
        echo -e "\033[1;31m[\033[1;36m02\033[1;31m] \033[1;32mINICIAR\033[1;37m (salida por Austria)\033[0m"
        echo -e "\033[1;31m[\033[1;36m03\033[1;31m] \033[1;33mDETENER\033[1;37m (volver a IP normal)\033[0m"
        echo -e "\033[1;31m[\033[1;36m04\033[1;31m] \033[1;37mREINICIAR\033[0m"
        echo -e "\033[1;31m[\033[1;36m05\033[1;31m] \033[1;37mESTADO (ver IP/país de salida)\033[0m"
        echo -e "\033[1;31m[\033[1;36m06\033[1;31m] \033[1;37mDESINSTALAR\033[0m"
        echo -e "\033[1;31m[\033[1;36m00\033[1;31m] \033[1;37mVOLVER\033[0m"
        echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
        echo -ne "\033[1;32m  Opción: \033[1;37m"; read op
        case "$op" in
            1|01) _ev_set_uri ;;
            2|02) _ev_start ;;
            3|03) _ev_stop ;;
            4|04) _ev_restart ;;
            5|05) _ev_status ;;
            6|06) _ev_uninstall ;;
            0|00) return ;;
            *) echo -e "\033[1;31m  Opción inválida!\033[0m"; sleep 1 ;;
        esac
    done
}
