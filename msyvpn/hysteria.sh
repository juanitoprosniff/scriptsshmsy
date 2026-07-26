#!/bin/bash
# hysteria.sh - UDP Hysteria (v1 o v2) para juegos/streaming
# Soporta ambas versiones (una activa a la vez). Auth "usuario:contrasena"
# de las cuentas del sistema. Obfs configurable.
[[ -n "$BASE_DIR" ]] || source /etc/msyvpn/lib.sh

HY_DIR="/etc/hysteria"
HY_BIN1="/usr/local/bin/hysteria1"
HY_BIN2="/usr/local/bin/hysteria2"
HY_CERT="$HY_DIR/server.crt"
HY_KEY="$HY_DIR/server.key"
HY_PORT_FILE="$HY_DIR/port"
HY_OBFS_FILE="$HY_DIR/obfs"
HY_VER_FILE="$HY_DIR/version"

hy_port() { local v; v=$(cat "$HY_PORT_FILE" 2>/dev/null); echo "${v:-36712}"; }
hy_obfs() { local v; v=$(cat "$HY_OBFS_FILE" 2>/dev/null); echo "${v:-msyvpn}"; }
hy_ver()  { local v; v=$(cat "$HY_VER_FILE"  2>/dev/null); echo "${v:-1}"; }

# Lista "usuario:contrasena" de cuentas validas del sistema
hy_userlist() {
    local f u p
    for f in "$SENHA_DIR"/*; do
        [[ -f "$f" ]] || continue
        u=$(basename "$f"); p=$(tr -d '\n' < "$f")
        id "$u" >/dev/null 2>&1 || continue
        [[ -z "$u" || -z "$p" ]] && continue
        printf '%s:%s\n' "$u" "$p"
    done
}

# ---- Hysteria v1 (config.json) --------------------------------------
hy_write_v1() {
    local arr="" line first=1
    while IFS= read -r line; do
        [[ $first -eq 1 ]] && first=0 || arr+=","
        arr+="\"$line\""
    done < <(hy_userlist)
    [[ -z "$arr" ]] && arr='"test:1234msy"'
    cat > "$HY_DIR/config.json" <<JSON
{
  "server": "$(get_ip)",
  "listen": ":$(hy_port)",
  "protocol": "udp",
  "cert": "$HY_CERT",
  "key": "$HY_KEY",
  "up_mbps": 1000,
  "down_mbps": 1000,
  "disable_udp": false,
  "insecure": true,
  "obfs": "$(hy_obfs)",
  "auth": { "mode": "passwords", "config": [$arr] }
}
JSON
}

# ---- Hysteria v2 (config.yaml) --------------------------------------
hy_write_v2() {
    local up="" line
    while IFS= read -r line; do
        up+="    ${line%%:*}: \"${line#*:}\""$'\n'
    done < <(hy_userlist)
    [[ -z "$up" ]] && up='    test: "1234msy"'
    cat > "$HY_DIR/config.yaml" <<YAML
listen: ":$(hy_port)"
tls:
  cert: $HY_CERT
  key: $HY_KEY
auth:
  type: userpass
  userpass:
$up
obfs:
  type: salamander
  salamander:
    password: $(hy_obfs)
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true
bandwidth:
  up: 1 gbps
  down: 1 gbps
YAML
}

hy_write_config() { [[ "$(hy_ver)" == 1 ]] && hy_write_v1 || hy_write_v2; }

hy_port_hopping() {
    local ifc; ifc=$(ip -4 route ls 2>/dev/null | awk '/default/{print $5; exit}')
    [[ -z "$ifc" ]] && return
    iptables -t nat -C PREROUTING -i "$ifc" -p udp --dport 10000:65000 -j DNAT --to-destination ":$(hy_port)" 2>/dev/null || \
        iptables -t nat -A PREROUTING -i "$ifc" -p udp --dport 10000:65000 -j DNAT --to-destination ":$(hy_port)" 2>/dev/null
}

# hy_install <1|2>
hy_install() {
    local ver="${1:-1}" a bin url exec
    ensure_pkg curl openssl
    a=$(arch)
    mkdir -p "$HY_DIR"
    if [[ "$ver" == 1 ]]; then
        bin="$HY_BIN1"; url="https://github.com/apernet/hysteria/releases/download/v1.3.5/hysteria-linux-$a"
    else
        bin="$HY_BIN2"; url="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-$a"
    fi
    if [[ ! -x "$bin" ]]; then
        info "Descargando Hysteria v$ver ($a)..."
        curl -L -f -s "$url" -o "$bin" && chmod +x "$bin"
    fi
    [[ -x "$bin" ]] || { err "No se pudo descargar Hysteria v$ver para $a"; return 1; }

    [[ -f "$HY_PORT_FILE" ]] || echo 36712 > "$HY_PORT_FILE"
    [[ -f "$HY_OBFS_FILE" ]] || echo msyvpn > "$HY_OBFS_FILE"
    echo "$ver" > "$HY_VER_FILE"
    if [[ ! -s "$HY_CERT" || ! -s "$HY_KEY" ]]; then
        openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -keyout "$HY_KEY" -out "$HY_CERT" -subj "/CN=$(get_ip)" >/dev/null 2>&1
        chmod 600 "$HY_KEY"
    fi
    hy_write_config

    if [[ "$ver" == 1 ]]; then
        exec="$HY_BIN1 server --config $HY_DIR/config.json"
    else
        exec="$HY_BIN2 server -c $HY_DIR/config.yaml"
    fi
    cat > /etc/systemd/system/msyvpn-hysteria.service <<EOF
[Unit]
Description=MSYVPN Hysteria v$ver UDP
After=network.target

[Service]
ExecStart=$exec
Restart=always
RestartSec=3
MemoryMax=250M

[Install]
WantedBy=multi-user.target
EOF
    open_port "$(hy_port)" udp
    hy_port_hopping
    systemctl daemon-reload
    systemctl enable --now msyvpn-hysteria >/dev/null 2>&1
    svc_restart msyvpn-hysteria
    sleep 1
    hy_info
}

# Refresca usuarios (llamado desde users.sh)
hy_add_user() {
    [[ -f "$HY_DIR/config.json" || -f "$HY_DIR/config.yaml" ]] || return 0
    hy_write_config
    svc_restart msyvpn-hysteria
}

hy_set_obfs() {
    local o; o=$(ask 'Nuevo obfs: '); [[ -z "$o" ]] && { err "Vacio"; return; }
    echo "$o" > "$HY_OBFS_FILE"
    hy_write_config
    svc_restart msyvpn-hysteria
    ok "Obfs cambiado a: $o"
}

hy_info() {
    line
    if [[ -f "$HY_VER_FILE" ]]; then
        echo "Version  : Hysteria v$(hy_ver)"
        echo "Servidor : $(get_ip)"
        echo "Puerto   : $(hy_port) (UDP)"
        echo "Obfs     : $(hy_obfs)"
        echo "Auth     : usuario:contrasena  ·  Insecure: ON"
        svc_active msyvpn-hysteria && echo "Estado   : activo" || echo "Estado   : inactivo"
    else
        echo "Hysteria no instalado."
    fi
    line
}

hy_remove() {
    systemctl disable --now msyvpn-hysteria >/dev/null 2>&1
    rm -f /etc/systemd/system/msyvpn-hysteria.service
    systemctl daemon-reload
    ok "Hysteria eliminado"
}

hy_menu() {
    while true; do
        clear
        title "UDP HYSTERIA  (v1 / v2)"
        hy_info
        echo "  1) Instalar Hysteria v1"
        echo "  2) Instalar Hysteria v2"
        echo "  3) Cambiar Obfs personalizado"
        echo "  4) Ver datos"
        echo "  5) Eliminar"
        echo "  0) Volver"
        line
        case "$(ask 'Opcion: ')" in
            1) hy_install 1; pause ;;
            2) hy_install 2; pause ;;
            3) hy_set_obfs; pause ;;
            4) hy_info; pause ;;
            5) hy_remove; pause ;;
            0) return ;;
        esac
    done
}
