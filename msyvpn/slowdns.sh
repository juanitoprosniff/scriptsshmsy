#!/bin/bash
# slowdns.sh - Tunel DNS (SlowDNS) sobre UDP 53 -> SSH
# Usa el binario incluido y corre bajo systemd con auto-reinicio.
[[ -n "$BASE_DIR" ]] || source /etc/msyvpn/lib.sh

SD_DIR="/etc/slowdns"
SD_BIN="$SD_DIR/dns-server"
SD_KEY="$SD_DIR/server.key"
SD_PUB="$SD_DIR/server.pub"

sd_install() {
    local ns port
    ns=$(ask 'Nameserver (ej: ns.tudominio.com): ')
    [[ -z "$ns" ]] && { err "El NS no puede estar vacio"; return; }
    port=$(ask 'Puerto destino [22]: '); [[ "$port" =~ ^[0-9]+$ ]] || port=22

    mkdir -p "$SD_DIR"
    if [[ -f "$BASE_DIR/bin/dns-server" ]]; then
        cp -f "$BASE_DIR/bin/dns-server" "$SD_BIN"
    else
        wget -q "$REPO_RAW/bin/dns-server" -O "$SD_BIN"
    fi
    chmod +x "$SD_BIN"

    if [[ ! -s "$SD_KEY" || ! -s "$SD_PUB" ]]; then
        "$SD_BIN" -gen-key -privkey-file "$SD_KEY" -pubkey-file "$SD_PUB" >/dev/null 2>&1
    fi
    echo "$ns" > "$SD_DIR/ns"

    cat > /etc/systemd/system/msyvpn-slowdns.service <<EOF
[Unit]
Description=MSYVPN SlowDNS
After=network.target

[Service]
ExecStartPre=-/bin/bash -c 'iptables -C INPUT -p udp --dport 5300 -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport 5300 -j ACCEPT'
ExecStartPre=-/bin/bash -c 'iptables -t nat -C PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 5300 2>/dev/null || iptables -t nat -I PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 5300'
ExecStart=$SD_BIN -udp :5300 -privkey-file $SD_KEY $ns 127.0.0.1:$port
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now msyvpn-slowdns >/dev/null 2>&1
    svc_restart msyvpn-slowdns
    sleep 1
    sd_info
}

sd_info() {
    line
    if [[ -s "$SD_DIR/ns" ]]; then
        echo "NS          : $(cat "$SD_DIR/ns")"
        echo "Clave pub   : $(cat "$SD_PUB" 2>/dev/null)"
        svc_active msyvpn-slowdns && echo "Estado      : activo" || echo "Estado      : inactivo"
    else
        echo "SlowDNS no instalado."
    fi
    line
}

sd_remove() {
    systemctl disable --now msyvpn-slowdns >/dev/null 2>&1
    rm -f /etc/systemd/system/msyvpn-slowdns.service
    systemctl daemon-reload
    ok "SlowDNS eliminado (claves conservadas en $SD_DIR)"
}

sd_menu() {
    while true; do
        clear
        title "SLOWDNS  (tunel DNS UDP 53)"
        sd_info
        echo "  1) Instalar / Reconfigurar"
        echo "  2) Ver datos (NS + clave)"
        echo "  3) Eliminar"
        echo "  0) Volver"
        line
        case "$(ask 'Opcion: ')" in
            1) sd_install; pause ;;
            2) sd_info; pause ;;
            3) sd_remove; pause ;;
            0) return ;;
        esac
    done
}
