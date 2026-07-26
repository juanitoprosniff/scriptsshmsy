#!/bin/bash
# hysteria.sh - UDP Hysteria v1 (alto rendimiento juegos/streaming)
# Auth por usuario "usuario:contrasena" tomada de las cuentas del sistema.
[[ -n "$BASE_DIR" ]] || source /etc/msyvpn/lib.sh

HY_DIR="/etc/hysteria"
HY_BIN="/usr/local/bin/hysteria"
HY_CFG="$HY_DIR/config.json"
HY_CERT="$HY_DIR/server.crt"
HY_KEY="$HY_DIR/server.key"
HY_PORT="36712"
HY_OBFS="msyvpn"

# Construye el arreglo JSON de auth desde las contrasenas guardadas
hy_build_auth() {
    local arr="" f u p
    for f in "$SENHA_DIR"/*; do
        [[ -f "$f" ]] || continue
        u=$(basename "$f"); p=$(tr -d '\n' < "$f")
        id "$u" >/dev/null 2>&1 || continue
        [[ -z "$u" || -z "$p" ]] && continue
        [[ -n "$arr" ]] && arr+=","
        arr+="\"$u:$p\""
    done
    [[ -z "$arr" ]] && arr='"test:1234msy"'
    echo "$arr"
}

hy_write_config() {
    local ip; ip=$(get_ip)
    mkdir -p "$HY_DIR"
    cat > "$HY_CFG" <<JSON
{
  "server": "$ip",
  "listen": ":$HY_PORT",
  "protocol": "udp",
  "cert": "$HY_CERT",
  "key": "$HY_KEY",
  "up_mbps": 1000,
  "down_mbps": 1000,
  "disable_udp": false,
  "insecure": true,
  "obfs": "$HY_OBFS",
  "auth": { "mode": "passwords", "config": [$(hy_build_auth)] }
}
JSON
}

hy_install() {
    ensure_pkg curl openssl jq
    local a; a=$(arch)
    if [[ ! -x "$HY_BIN" ]]; then
        info "Descargando Hysteria..."
        curl -L -f -s "https://github.com/apernet/hysteria/releases/download/v1.3.5/hysteria-linux-$a" \
            -o "$HY_BIN" && chmod +x "$HY_BIN"
    fi
    [[ -x "$HY_BIN" ]] || { err "No se pudo descargar Hysteria"; return 1; }

    mkdir -p "$HY_DIR"
    local ip; ip=$(get_ip)
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$HY_KEY" -out "$HY_CERT" \
        -subj "/CN=$ip" >/dev/null 2>&1
    chmod 600 "$HY_KEY"

    hy_write_config

    cat > /etc/systemd/system/msyvpn-hysteria.service <<EOF
[Unit]
Description=MSYVPN Hysteria UDP
After=network.target

[Service]
ExecStart=$HY_BIN server --config $HY_CFG
Restart=always
RestartSec=3
MemoryMax=250M

[Install]
WantedBy=multi-user.target
EOF
    open_port "$HY_PORT" udp
    # Port hopping 10000-65000 -> puerto Hysteria
    local ifc; ifc=$(ip -4 route ls 2>/dev/null | awk '/default/{print $5; exit}')
    iptables -t nat -C PREROUTING -i "$ifc" -p udp --dport 10000:65000 -j DNAT --to-destination ":$HY_PORT" 2>/dev/null || \
        iptables -t nat -A PREROUTING -i "$ifc" -p udp --dport 10000:65000 -j DNAT --to-destination ":$HY_PORT" 2>/dev/null

    systemctl daemon-reload
    systemctl enable --now msyvpn-hysteria >/dev/null 2>&1
    svc_restart msyvpn-hysteria
    sleep 1
    hy_info
}

# Agregar/refrescar un usuario (llamado desde users.sh)
hy_add_user() {
    [[ -x "$HY_BIN" && -f "$HY_CFG" ]] || return 0
    hy_write_config
    svc_restart msyvpn-hysteria
}

hy_info() {
    line
    if [[ -f "$HY_CFG" ]]; then
        echo "Servidor : $(get_ip)"
        echo "Puerto   : $HY_PORT (UDP)"
        echo "Obfs     : $HY_OBFS"
        echo "Password : usuario:contrasena (el de la cuenta)"
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
        title "UDP HYSTERIA  (juegos / streaming)"
        hy_info
        echo "  1) Instalar / Reconfigurar"
        echo "  2) Ver datos"
        echo "  3) Eliminar"
        echo "  0) Volver"
        line
        case "$(ask 'Opcion: ')" in
            1) hy_install; pause ;;
            2) hy_info; pause ;;
            3) hy_remove; pause ;;
            0) return ;;
        esac
    done
}
