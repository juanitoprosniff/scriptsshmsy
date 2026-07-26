#!/bin/bash
# slowdns.sh - Tunel DNS (SlowDNS) sobre UDP 53 -> SSH
# Corre bajo systemd con auto-reinicio. Reglas NAT aplicadas al instalar.
[[ -n "$BASE_DIR" ]] || source /etc/msyvpn/lib.sh

SD_DIR="/etc/slowdns"
SD_BIN="$SD_DIR/dns-server"
SD_KEY="$SD_DIR/server.key"
SD_PUB="$SD_DIR/server.pub"
SD_NAT="$SD_DIR/nat.sh"

# Aplica (idempotente) las reglas de red que SlowDNS necesita.
sd_apply_net() {
    # Si systemd-resolved ocupa el 53 en la IP publica, desactivar su stub.
    if ss -ulnp 2>/dev/null | grep -qE '0\.0\.0\.0:53 |:::53 '; then
        if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            mkdir -p /etc/systemd/resolved.conf.d
            printf '[Resolve]\nDNSStubListener=no\n' > /etc/systemd/resolved.conf.d/msyvpn.conf
            systemctl restart systemd-resolved 2>/dev/null
        fi
    fi
    # Aceptar UDP 53 y 5300, y redirigir 53 -> 5300
    iptables -C INPUT -p udp --dport 53   -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport 53   -j ACCEPT
    iptables -C INPUT -p udp --dport 5300 -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport 5300 -j ACCEPT
    iptables -t nat -C PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 5300 2>/dev/null || \
        iptables -t nat -I PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 5300
    command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active && ufw allow 53/udp >/dev/null 2>&1
}

sd_install() {
    local ns port
    ns=$(ask 'Nameserver (ej: ns.tudominio.com): ')
    [[ -z "$ns" ]] && { err "El NS no puede estar vacio"; return 1; }
    port=$(ask 'Puerto destino [22]: '); [[ "$port" =~ ^[0-9]+$ ]] || port=22

    mkdir -p "$SD_DIR"
    fetch_bin dns-server "$SD_BIN" || { err "dns-server no disponible para $(arch)"; return 1; }

    [[ -s "$SD_KEY" && -s "$SD_PUB" ]] || \
        "$SD_BIN" -gen-key -privkey-file "$SD_KEY" -pubkey-file "$SD_PUB" >/dev/null 2>&1
    echo "$ns" > "$SD_DIR/ns"

    # Script NAT persistente (lo llama el servicio en cada arranque)
    cat > "$SD_NAT" <<EOF
#!/bin/bash
source /etc/msyvpn/slowdns.sh
sd_apply_net
EOF
    chmod +x "$SD_NAT"
    sd_apply_net

    cat > /etc/systemd/system/msyvpn-slowdns.service <<EOF
[Unit]
Description=MSYVPN SlowDNS
After=network.target

[Service]
ExecStartPre=$SD_NAT
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
    if ! ss -ulnp 2>/dev/null | grep -q ':5300 '; then
        err "SlowDNS no escucha en 5300. Ver: journalctl -u msyvpn-slowdns -n 20"
    fi
}

# Permite fijar un par de claves propio (para no cambiar la config
# de los clientes ya repartidos). SlowDNS necesita AMBAS: priv y pub.
sd_set_key() {
    local priv pub
    echo "  Las claves son cadenas hexadecimales de 64 caracteres."
    priv=$(ask 'Clave PRIVADA (server.key): '); priv=$(echo "$priv" | tr -cd '[:xdigit:]')
    pub=$(ask  'Clave PUBLICA  (server.pub): '); pub=$(echo "$pub" | tr -cd '[:xdigit:]')
    if [[ ${#priv} -ne 64 || ${#pub} -ne 64 ]]; then
        err "Claves invalidas (se esperan 64 caracteres hex cada una)"
        info "Privada: ${#priv} car.  ·  Publica: ${#pub} car."
        return 1
    fi
    mkdir -p "$SD_DIR"
    printf '%s' "$priv" > "$SD_KEY"
    printf '%s' "$pub"  > "$SD_PUB"
    chmod 600 "$SD_KEY"
    svc_active msyvpn-slowdns && svc_restart msyvpn-slowdns
    ok "Claves personalizadas instaladas"
}

sd_info() {
    line
    if [[ -s "$SD_DIR/ns" ]]; then
        echo "NS          : $(cat "$SD_DIR/ns")"
        echo "Clave pub   : $(cat "$SD_PUB" 2>/dev/null)"
        ss -ulnp 2>/dev/null | grep -q ':5300 ' && echo "Escucha 5300: si" || echo "Escucha 5300: NO"
        svc_active msyvpn-slowdns && echo "Estado      : activo" || echo "Estado      : inactivo"
        echo "Recuerda: el NS debe estar delegado (registro NS + A) hacia esta IP."
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
        echo "  3) Usar clave personalizada (priv + pub)"
        echo "  4) Reaplicar reglas de red"
        echo "  5) Eliminar"
        echo "  0) Volver"
        line
        case "$(ask 'Opcion: ')" in
            1) sd_install; pause ;;
            2) sd_info; pause ;;
            3) sd_set_key; pause ;;
            4) sd_apply_net; ok "Reglas aplicadas"; pause ;;
            5) sd_remove; pause ;;
            0) return ;;
        esac
    done
}
