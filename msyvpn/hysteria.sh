#!/bin/bash
# hysteria.sh - Hysteria2 (UDP/QUIC) alto rendimiento juegos/streaming
# Auth "usuario:contrasena" de las cuentas del sistema. Obfs configurable.
[[ -n "$BASE_DIR" ]] || source /etc/msyvpn/lib.sh

HY_DIR="/etc/hysteria"
HY_BIN="/usr/local/bin/hysteria"
HY_CFG="$HY_DIR/config.yaml"
HY_CERT="$HY_DIR/server.crt"
HY_KEY="$HY_DIR/server.key"
HY_PORT_FILE="$HY_DIR/port"
HY_OBFS_FILE="$HY_DIR/obfs"

hy_port() { cat "$HY_PORT_FILE" 2>/dev/null || echo 36712; }
hy_obfs() { cat "$HY_OBFS_FILE" 2>/dev/null || echo msyvpn; }

# Lineas "    usuario: pass" para el bloque userpass del YAML
hy_userpass() {
    local f u p out=""
    for f in "$SENHA_DIR"/*; do
        [[ -f "$f" ]] || continue
        u=$(basename "$f"); p=$(tr -d '\n' < "$f")
        id "$u" >/dev/null 2>&1 || continue
        [[ -z "$u" || -z "$p" ]] && continue
        out+="    $u: \"$p\""$'\n'
    done
    [[ -z "$out" ]] && out='    test: "1234msy"'
    printf '%s' "$out"
}

hy_write_config() {
    mkdir -p "$HY_DIR"
    cat > "$HY_CFG" <<YAML
listen: :$(hy_port)
tls:
  cert: $HY_CERT
  key: $HY_KEY
auth:
  type: userpass
  userpass:
$(hy_userpass)
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

hy_install() {
    ensure_pkg curl openssl
    local a; a=$(arch)
    if [[ ! -x "$HY_BIN" ]]; then
        info "Descargando Hysteria2..."
        curl -L -f -s "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-$a" \
            -o "$HY_BIN" && chmod +x "$HY_BIN"
    fi
    [[ -x "$HY_BIN" ]] || { err "No se pudo descargar Hysteria2 para $a"; return 1; }

    mkdir -p "$HY_DIR"
    [[ -f "$HY_PORT_FILE" ]] || echo 36712 > "$HY_PORT_FILE"
    [[ -f "$HY_OBFS_FILE" ]] || echo msyvpn > "$HY_OBFS_FILE"
    if [[ ! -s "$HY_CERT" || ! -s "$HY_KEY" ]]; then
        openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -keyout "$HY_KEY" -out "$HY_CERT" -subj "/CN=$(get_ip)" >/dev/null 2>&1
        chmod 600 "$HY_KEY"
    fi
    hy_write_config

    cat > /etc/systemd/system/msyvpn-hysteria.service <<EOF
[Unit]
Description=MSYVPN Hysteria2 UDP
After=network.target

[Service]
ExecStart=$HY_BIN server -c $HY_CFG
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

hy_port_hopping() {
    local ifc; ifc=$(ip -4 route ls 2>/dev/null | awk '/default/{print $5; exit}')
    [[ -z "$ifc" ]] && return
    iptables -t nat -C PREROUTING -i "$ifc" -p udp --dport 10000:65000 -j DNAT --to-destination ":$(hy_port)" 2>/dev/null || \
        iptables -t nat -A PREROUTING -i "$ifc" -p udp --dport 10000:65000 -j DNAT --to-destination ":$(hy_port)" 2>/dev/null
}

# Refresca usuarios (llamado desde users.sh)
hy_add_user() {
    [[ -x "$HY_BIN" && -f "$HY_CFG" ]] || return 0
    hy_write_config
    svc_restart msyvpn-hysteria
}

hy_set_obfs() {
    local o; o=$(ask 'Nuevo obfs (password salamander): ')
    [[ -z "$o" ]] && { err "Vacio"; return; }
    echo "$o" > "$HY_OBFS_FILE"
    hy_write_config
    svc_restart msyvpn-hysteria
    ok "Obfs cambiado a: $o"
}

hy_info() {
    line
    if [[ -f "$HY_CFG" ]]; then
        echo "Servidor : $(get_ip)"
        echo "Puerto   : $(hy_port) (UDP)"
        echo "Obfs     : $(hy_obfs)   (salamander)"
        echo "Auth     : usuario:contrasena  ·  Insecure: ON"
        svc_active msyvpn-hysteria && echo "Estado   : activo" || echo "Estado   : inactivo"
    else
        echo "Hysteria2 no instalado."
    fi
    line
}

hy_remove() {
    systemctl disable --now msyvpn-hysteria >/dev/null 2>&1
    rm -f /etc/systemd/system/msyvpn-hysteria.service
    systemctl daemon-reload
    ok "Hysteria2 eliminado"
}

hy_menu() {
    while true; do
        clear
        title "HYSTERIA2  (UDP juegos/streaming)"
        hy_info
        echo "  1) Instalar / Reconfigurar"
        echo "  2) Cambiar Obfs personalizado"
        echo "  3) Ver datos"
        echo "  4) Eliminar"
        echo "  0) Volver"
        line
        case "$(ask 'Opcion: ')" in
            1) hy_install; pause ;;
            2) hy_set_obfs; pause ;;
            3) hy_info; pause ;;
            4) hy_remove; pause ;;
            0) return ;;
        esac
    done
}
