#!/bin/bash
# shadowsocks.sh - ShadowSocks (shadowsocks-libev, ligero)
# Servidor con una config compartida (puerto/metodo/password). Muestra
# el enlace ss:// y su QR para pegar en la app.
[[ -n "$BASE_DIR" ]] || source /etc/msyvpn/lib.sh

SS_DIR="/etc/shadowsocks-libev"
SS_CFG="$SS_DIR/config.json"
SS_PORT_DEF=8388
SS_METHOD_DEF="aes-256-gcm"

ss_installed() { command -v ss-server >/dev/null 2>&1; }
ss_port()   { jq -r '.server_port // 8388'      "$SS_CFG" 2>/dev/null || echo 8388; }
ss_pass()   { jq -r '.password // ""'           "$SS_CFG" 2>/dev/null; }
ss_method() { jq -r '.method // "aes-256-gcm"'  "$SS_CFG" 2>/dev/null; }

ss_write_config() {
    local port="$1" pass="$2" method="$3"
    mkdir -p "$SS_DIR"
    cat > "$SS_CFG" <<JSON
{
  "server": ["0.0.0.0", "::0"],
  "server_port": $port,
  "password": "$pass",
  "method": "$method",
  "mode": "tcp_and_udp",
  "timeout": 300,
  "fast_open": true,
  "no_delay": true
}
JSON
    chmod 600 "$SS_CFG"
}

# Configura el servidor sin preguntar (para auto-activar):
# ss_setup [puerto] [password] [metodo]
ss_setup() {
    ensure_pkg shadowsocks-libev qrencode jq
    ss_installed || return 1
    local port="${1:-$SS_PORT_DEF}" pass="$2" method="${3:-$SS_METHOD_DEF}"
    [[ -z "$pass" ]] && pass=$(openssl rand -base64 12 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 16)
    ss_write_config "$port" "$pass" "$method"
    open_port "$port" tcp; open_port "$port" udp
    cat > /etc/systemd/system/msyvpn-ss.service <<EOF
[Unit]
Description=MSYVPN ShadowSocks
After=network.target

[Service]
ExecStart=$(command -v ss-server) -c $SS_CFG
StandardOutput=null
StandardError=null
Restart=always
RestartSec=3
MemoryMax=150M

[Install]
WantedBy=multi-user.target
EOF
    systemctl disable --now shadowsocks-libev >/dev/null 2>&1   # evitar doble instancia
    systemctl daemon-reload
    systemctl enable --now msyvpn-ss >/dev/null 2>&1
    svc_restart msyvpn-ss
    sleep 1
}

ss_install() {
    ensure_pkg shadowsocks-libev qrencode jq
    ss_installed || { err "No se pudo instalar shadowsocks-libev (revisa el repo 'universe')"; return 1; }
    local port pass method
    port=$(ask "Puerto [$SS_PORT_DEF]: "); [[ "$port" =~ ^[0-9]+$ ]] || port=$SS_PORT_DEF
    echo "  Metodo:  1) aes-256-gcm (recomendado)   2) chacha20-ietf-poly1305"
    case "$(ask 'Metodo [1]: ')" in
        2) method="chacha20-ietf-poly1305" ;;
        *) method="$SS_METHOD_DEF" ;;
    esac
    pass=$(ask 'Password (ENTER genera uno): ')
    ss_setup "$port" "$pass" "$method"
    ss_info
}

ss_link() {
    local ip port method pass userinfo
    ip=$(get_ip); port=$(ss_port); method=$(ss_method); pass=$(ss_pass)
    userinfo=$(printf '%s:%s' "$method" "$pass" | base64 2>/dev/null | tr -d '\n')
    echo "ss://${userinfo}@${ip}:${port}#MSYVPN"
}

ss_info() {
    line
    if ss_installed && [[ -f "$SS_CFG" ]]; then
        echo "Servidor : $(get_ip)"
        echo "Puerto   : $(ss_port)"
        echo "Metodo   : $(ss_method)"
        echo "Password : $(ss_pass)"
        svc_active msyvpn-ss && echo "Estado   : $(g activo)" || echo "Estado   : $(r inactivo)"
        echo ""
        echo "Enlace (pegar en la app):"
        echo "  $(ss_link)"
        if command -v qrencode >/dev/null 2>&1; then
            echo ""; qrencode -t ANSIUTF8 "$(ss_link)" 2>/dev/null
        fi
    else
        echo "ShadowSocks no instalado."
    fi
    line
}

ss_remove() {
    systemctl disable --now msyvpn-ss >/dev/null 2>&1
    rm -f /etc/systemd/system/msyvpn-ss.service
    systemctl daemon-reload
    ok "ShadowSocks eliminado"
}

ss_menu() {
    while true; do
        clear; title "SHADOWSOCKS"
        ss_info
        echo "  1) Instalar / Reconfigurar"
        echo "  2) Ver enlace y QR"
        echo "  3) Eliminar"
        echo "  0) Volver"
        line
        case "$(ask 'Opcion: ')" in
            1) ss_install; pause ;;
            2) ss_info; pause ;;
            3) ss_remove; pause ;;
            0) return ;;
        esac
    done
}
