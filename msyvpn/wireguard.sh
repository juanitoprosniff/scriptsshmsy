#!/bin/bash
# wireguard.sh - WireGuard VPN (kernel, muy eficiente)
# Cada cliente es un peer con su par de claves. Genera .conf y QR.
[[ -n "$BASE_DIR" ]] || source /etc/msyvpn/lib.sh

WG_DIR="/etc/wireguard"
WG_IF="wg0"
WG_CFG="$WG_DIR/$WG_IF.conf"
WG_CLIENTS="$WG_DIR/clients"
WG_NET="10.66.66"
WG_PORT_DEF=51820

wg_installed() { command -v wg >/dev/null 2>&1 && [[ -f "$WG_CFG" ]]; }
wg_iface()  { ip -4 route ls 2>/dev/null | awk '/default/{print $5; exit}'; }
wg_port()   { grep -oP 'ListenPort\s*=\s*\K[0-9]+' "$WG_CFG" 2>/dev/null || echo $WG_PORT_DEF; }
wg_srv_pub(){ cat "$WG_DIR/server.pub" 2>/dev/null; }

# Reconstruye wg0.conf desde server.key + los .conf de los clientes.
# Cada cliente guarda su clave privada; la publica se deriva de ella.
wg_rebuild() {
    local port ifc; port=$(wg_port); ifc=$(wg_iface)
    {
        echo "[Interface]"
        echo "Address = $WG_NET.1/24"
        echo "ListenPort = $port"
        echo "PrivateKey = $(cat "$WG_DIR/server.key")"
        echo "PostUp = iptables -A FORWARD -i $WG_IF -j ACCEPT; iptables -A FORWARD -o $WG_IF -j ACCEPT; iptables -t nat -A POSTROUTING -o $ifc -j MASQUERADE"
        echo "PostDown = iptables -D FORWARD -i $WG_IF -j ACCEPT; iptables -D FORWARD -o $WG_IF -j ACCEPT; iptables -t nat -D POSTROUTING -o $ifc -j MASQUERADE"
        local c cpriv cpub cpsk cip
        for c in "$WG_CLIENTS"/*.conf; do
            [[ -f "$c" ]] || continue
            cpriv=$(awk -F' = ' '/PrivateKey/{print $2; exit}' "$c")
            cpub=$(echo "$cpriv" | wg pubkey)
            cpsk=$(awk -F' = ' '/PresharedKey/{print $2; exit}' "$c")
            cip=$(awk -F' = ' '/^Address/{print $2; exit}' "$c" | cut -d/ -f1)
            echo ""
            echo "[Peer]"
            echo "# $(basename "$c" .conf)"
            echo "PublicKey = $cpub"
            [[ -n "$cpsk" ]] && echo "PresharedKey = $cpsk"
            echo "AllowedIPs = $cip/32"
        done
    } > "$WG_CFG"
    chmod 600 "$WG_CFG"
    systemctl restart wg-quick@$WG_IF 2>/dev/null
}

wg_install() {
    ensure_pkg wireguard wireguard-tools qrencode iptables
    command -v wg >/dev/null 2>&1 || { err "No se pudo instalar WireGuard"; return 1; }
    mkdir -p "$WG_DIR" "$WG_CLIENTS"; chmod 700 "$WG_DIR"
    local port; port=$(ask "Puerto UDP [$WG_PORT_DEF]: "); [[ "$port" =~ ^[0-9]+$ ]] || port=$WG_PORT_DEF
    if [[ ! -s "$WG_DIR/server.key" ]]; then
        (umask 077; wg genkey | tee "$WG_DIR/server.key" | wg pubkey > "$WG_DIR/server.pub")
    fi
    echo "$port" > "$WG_DIR/port"
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    open_port "$port" udp
    wg_rebuild
    systemctl enable wg-quick@$WG_IF >/dev/null 2>&1
    systemctl restart wg-quick@$WG_IF
    sleep 1
    wg_info
}

# Devuelve la siguiente IP libre de la subred
wg_next_ip() {
    local i
    for i in $(seq 2 254); do
        grep -rqs "$WG_NET.$i/" "$WG_CLIENTS" || { echo "$WG_NET.$i"; return; }
    done
}

wg_add_client() {
    wg_installed || { err "Instala WireGuard primero (opcion 1)"; return; }
    local name; name=$(ask 'Nombre del cliente: ')
    name=$(echo "$name" | tr -cd '[:alnum:]_-' | head -c 20)
    [[ -z "$name" ]] && { err "Nombre invalido"; return; }
    [[ -f "$WG_CLIENTS/$name.conf" ]] && { err "Ya existe"; return; }
    local ip priv psk; ip=$(wg_next_ip)
    [[ -z "$ip" ]] && { err "Sin IPs libres"; return; }
    priv=$(wg genkey); psk=$(wg genpsk)
    cat > "$WG_CLIENTS/$name.conf" <<EOF
[Interface]
PrivateKey = $priv
Address = $ip/24
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = $(wg_srv_pub)
PresharedKey = $psk
Endpoint = $(get_ip):$(wg_port)
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
    chmod 600 "$WG_CLIENTS/$name.conf"
    wg_rebuild
    ok "Cliente $name creado (IP $ip)"
    echo "Config guardada en: $WG_CLIENTS/$name.conf"
    echo "Descargala con:  scp root@$(get_ip):$WG_CLIENTS/$name.conf ."
    echo ""
    command -v qrencode >/dev/null 2>&1 && qrencode -t ANSIUTF8 < "$WG_CLIENTS/$name.conf" 2>/dev/null
}

wg_list() {
    line; echo "Clientes WireGuard:"
    local c any=0 now hs pub
    now=$(date +%s)
    for c in "$WG_CLIENTS"/*.conf; do
        [[ -f "$c" ]] || continue; any=1
        local nm; nm=$(basename "$c" .conf)
        pub=$(awk -F' = ' '/PrivateKey/{print $2; exit}' "$c" | wg pubkey)
        hs=$(wg show $WG_IF latest-handshakes 2>/dev/null | awk -v p="$pub" '$1==p{print $2}')
        if [[ -n "$hs" && "$hs" != 0 ]] && (( now - hs < 180 )); then
            printf '  %-20s %s\n' "$nm" "$(g online)"
        else
            printf '  %-20s offline\n' "$nm"
        fi
    done
    [[ $any -eq 0 ]] && echo "  (sin clientes)"
    line
}

wg_del_client() {
    local name; name=$(ask 'Cliente a eliminar: ')
    [[ -f "$WG_CLIENTS/$name.conf" ]] || { err "No existe"; return; }
    rm -f "$WG_CLIENTS/$name.conf"
    wg_rebuild
    ok "Cliente $name eliminado"
}

wg_info() {
    line
    if wg_installed; then
        echo "Servidor : $(get_ip)"
        echo "Puerto   : $(wg_port) (UDP)"
        echo "Subred   : $WG_NET.0/24"
        echo "Clientes : $(ls -1 "$WG_CLIENTS"/*.conf 2>/dev/null | wc -l)"
        svc_active wg-quick@$WG_IF && echo "Estado   : $(g activo)" || echo "Estado   : $(r inactivo)"
    else
        echo "WireGuard no instalado."
    fi
    line
}

wg_remove() {
    systemctl disable --now wg-quick@$WG_IF >/dev/null 2>&1
    ok "WireGuard detenido (claves y clientes conservados en $WG_DIR)"
}

wg_menu() {
    while true; do
        clear; title "WIREGUARD"
        wg_info
        echo "  1) Instalar / Reconfigurar"
        echo "  2) Crear cliente (.conf + QR)"
        echo "  3) Listar clientes (online/offline)"
        echo "  4) Eliminar cliente"
        echo "  5) Detener / Eliminar servidor"
        echo "  0) Volver"
        line
        case "$(ask 'Opcion: ')" in
            1) wg_install; pause ;;
            2) wg_add_client; pause ;;
            3) wg_list; pause ;;
            4) wg_del_client; pause ;;
            5) wg_remove; pause ;;
            0) return ;;
        esac
    done
}
