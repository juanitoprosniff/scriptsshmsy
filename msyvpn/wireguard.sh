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
wg_iface()  { ip -4 route ls 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}'; }
wg_port()   { cat "$WG_DIR/port" 2>/dev/null || echo $WG_PORT_DEF; }
wg_srv_pub(){ cat "$WG_DIR/server.pub" 2>/dev/null; }

# Reconstruye wg0.conf desde server.key + los .conf de los clientes.
# La clave publica de cada cliente se deriva de su clave privada.
wg_rebuild() {
    local port ifc; port=$(wg_port); ifc=$(wg_iface); [[ -z "$ifc" ]] && ifc=eth0
    {
        echo "[Interface]"
        echo "Address = $WG_NET.1/24"
        echo "ListenPort = $port"
        echo "PrivateKey = $(cat "$WG_DIR/server.key")"
        # -I (insert) gana a reglas DROP previas (Docker/ufw); sysctl por si acaso
        echo "PostUp = sysctl -w net.ipv4.ip_forward=1; iptables -I FORWARD -i $WG_IF -j ACCEPT; iptables -I FORWARD -o $WG_IF -j ACCEPT; iptables -t nat -I POSTROUTING -s $WG_NET.0/24 -o $ifc -j MASQUERADE"
        echo "PostDown = iptables -D FORWARD -i $WG_IF -j ACCEPT; iptables -D FORWARD -o $WG_IF -j ACCEPT; iptables -t nat -D POSTROUTING -s $WG_NET.0/24 -o $ifc -j MASQUERADE"
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

# Aplica NAT + forwarding de forma idempotente, sin depender del PostUp
# de wg-quick (que a veces falla en silencio y deja el tunel sin salida).
wg_apply_nat() {
    local ifc; ifc=$(wg_iface); [[ -z "$ifc" ]] && ifc=eth0
    # Forwarding + rp_filter en TODAS las interfaces (all + wg0 + salida)
    sysctl -w net.ipv4.ip_forward=1                         >/dev/null 2>&1
    sysctl -w net.ipv4.conf.all.rp_filter=2                 >/dev/null 2>&1
    sysctl -w net.ipv4.conf.default.rp_filter=2             >/dev/null 2>&1
    sysctl -w net.ipv4.conf.$WG_IF.rp_filter=2              >/dev/null 2>&1
    sysctl -w net.ipv4.conf.$ifc.rp_filter=2                >/dev/null 2>&1
    # Politica FORWARD por defecto ACCEPT (Docker/otros la ponen en DROP)
    iptables -P FORWARD ACCEPT 2>/dev/null
    iptables -C FORWARD -i $WG_IF -j ACCEPT 2>/dev/null || iptables -I FORWARD -i $WG_IF -j ACCEPT
    iptables -C FORWARD -o $WG_IF -j ACCEPT 2>/dev/null || iptables -I FORWARD -o $WG_IF -j ACCEPT
    iptables -t nat -C POSTROUTING -s $WG_NET.0/24 -o "$ifc" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -I POSTROUTING -s $WG_NET.0/24 -o "$ifc" -j MASQUERADE
    # Desactivar firewalld si esta activo (bloquea el forward silenciosamente)
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        systemctl stop firewalld 2>/dev/null
        systemctl disable firewalld 2>/dev/null
    fi
}

# Configura el servidor sin preguntar (para auto-activar): wg_setup [puerto]
wg_setup() {
    local port="${1:-$WG_PORT_DEF}"
    ensure_pkg wireguard wireguard-tools qrencode iptables
    command -v wg >/dev/null 2>&1 || { err "No se pudo instalar WireGuard"; return 1; }
    mkdir -p "$WG_DIR" "$WG_CLIENTS"; chmod 700 "$WG_DIR"
    if [[ ! -s "$WG_DIR/server.key" ]]; then
        (umask 077; wg genkey | tee "$WG_DIR/server.key" | wg pubkey > "$WG_DIR/server.pub")
    fi
    echo "$port" > "$WG_DIR/port"
    # Forwarding + rp_filter permisivo (algunas VPS descartan el trafico del tunel)
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1
    modprobe wireguard 2>/dev/null
    open_port "$port" udp
    wg_rebuild
    systemctl enable wg-quick@$WG_IF >/dev/null 2>&1
    systemctl restart wg-quick@$WG_IF 2>/dev/null
    sleep 1
    wg_apply_nat        # garantiza el NAT aunque el PostUp haya fallado
}

wg_install() {
    local port; port=$(ask "Puerto UDP [$WG_PORT_DEF]: "); [[ "$port" =~ ^[0-9]+$ ]] || port=$WG_PORT_DEF
    wg_setup "$port" && ok "WireGuard activo en UDP $port" || return 1
    wg_info
}

# Devuelve la siguiente IP libre de la subred
wg_next_ip() {
    local i
    for i in $(seq 2 254); do
        grep -rqs "$WG_NET.$i/" "$WG_CLIENTS" || { echo "$WG_NET.$i"; return; }
    done
}

# Crea el peer sin interaccion (reusa si ya existe). Uso: wg_create_peer <nombre>
wg_create_peer() {
    wg_installed || return 1
    local name="$1"
    name=$(echo "$name" | tr -cd '[:alnum:]_-' | head -c 20)
    [[ -z "$name" ]] && return 1
    [[ -f "$WG_CLIENTS/$name.conf" ]] && return 0    # ya existe, se reusa
    local ip priv psk; ip=$(wg_next_ip)
    [[ -z "$ip" ]] && return 1
    priv=$(wg genkey); psk=$(wg genpsk)
    cat > "$WG_CLIENTS/$name.conf" <<EOF
[Interface]
PrivateKey = $priv
Address = $ip/24
DNS = 1.1.1.1, 8.8.8.8
MTU = 1420

[Peer]
PublicKey = $(wg_srv_pub)
PresharedKey = $psk
Endpoint = $(get_ip):$(wg_port)
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
    chmod 600 "$WG_CLIENTS/$name.conf"
    wg_rebuild
}

# Muestra la config, el enlace y el QR de un cliente
wg_show_client() {
    local name="$1" f="$WG_CLIENTS/$name.conf"
    [[ -f "$f" ]] || { err "Cliente $name no existe"; return; }
    echo "Config: $f   (scp root@$(get_ip):$f .)"
    echo "Enlace NapsternetV:"
    echo "  $(wg_sn_link "$name")"
    echo ""
    command -v qrencode >/dev/null 2>&1 && qrencode -t ANSIUTF8 < "$f" 2>/dev/null
}

wg_add_client() {
    wg_installed || { err "Instala WireGuard primero (opcion 1)"; return; }
    local name; name=$(ask 'Nombre del cliente: ')
    name=$(echo "$name" | tr -cd '[:alnum:]_-' | head -c 20)
    [[ -z "$name" ]] && { err "Nombre invalido"; return; }
    [[ -f "$WG_CLIENTS/$name.conf" ]] && { err "Ya existe"; return; }
    wg_create_peer "$name" || { err "No se pudo crear (sin IPs o WG parado)"; return; }
    ok "Cliente $name creado"
    wg_show_client "$name"
}

# Enlace sn://wg? para apps tipo NapsternetV = base64url(zlib(.conf))
wg_sn_link() {
    local name="$1" f="$WG_CLIENTS/$name.conf"
    [[ -f "$f" ]] || return
    local b64
    b64=$(python3 - "$f" <<'PY' 2>/dev/null
import sys, zlib, base64
data = open(sys.argv[1], 'rb').read()
print(base64.urlsafe_b64encode(zlib.compress(data, 9)).decode().rstrip('='))
PY
)
    [[ -n "$b64" ]] && echo "sn://wg?$b64"
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

# Diagnostico REAL: revisa cada capa Y hace una prueba de trafico
wg_diag() {
    line
    if ! wg_installed; then echo "WireGuard no instalado."; line; return; fi

    # 1. Interfaz
    ip link show $WG_IF >/dev/null 2>&1 && ok "Interfaz $WG_IF arriba" \
        || { err "Interfaz $WG_IF NO existe"; info "Mira: journalctl -u wg-quick@$WG_IF -n 30"; line; return; }

    # 2. Forwarding + rp_filter
    local ipf ifc rpa rpi
    ipf=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
    ifc=$(wg_iface); [[ -z "$ifc" ]] && ifc=eth0
    rpa=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null)
    rpi=$(sysctl -n net.ipv4.conf.$ifc.rp_filter 2>/dev/null)
    [[ "$ipf" == 1 ]] && ok "IP forwarding activo" || err "IP forwarding DESACTIVADO (sysctl net.ipv4.ip_forward)"
    echo "     Interfaz salida: $ifc   rp_filter all=$rpa ${ifc}=$rpi (debe ser 0 o 2)"

    # 3. Politica FORWARD y NAT
    local pol
    pol=$(iptables -L FORWARD -n 2>/dev/null | awk 'NR==1{print $NF}' | tr -d '()')
    [[ "$pol" == "ACCEPT" ]] && ok "FORWARD policy: ACCEPT" || err "FORWARD policy: $pol (algunos paquetes se descartan)"
    if iptables -t nat -C POSTROUTING -s $WG_NET.0/24 -o "$ifc" -j MASQUERADE 2>/dev/null; then
        ok "NAT (MASQUERADE) presente sobre $ifc"
    else
        err "NAT ausente — REAPLICANDO ahora..."; wg_apply_nat
        iptables -t nat -C POSTROUTING -s $WG_NET.0/24 -o "$ifc" -j MASQUERADE 2>/dev/null \
            && ok "NAT recien aplicado" || err "NAT sigue sin poder aplicarse"
    fi

    # 4. Docker/firewalld interfiriendo
    systemctl is-active --quiet docker 2>/dev/null && \
        info "Docker detectado: pone FORWARD en DROP. Ya se forzo ACCEPT."
    systemctl is-active --quiet firewalld 2>/dev/null && \
        err "firewalld ACTIVO — bloquea el forward. Se recomienda: systemctl disable --now firewalld"
    # nftables como respaldo puede interferir tambien
    if command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -qi 'drop'; then
        info "nftables tiene reglas 'drop'. Revisa: nft list ruleset"
    fi

    # 5. Peers y handshakes
    local nc; nc=$(ls -1 "$WG_CLIENTS"/*.conf 2>/dev/null | wc -l)
    echo "     Puerto UDP: $(wg_port)   Clientes: $nc"
    local now hs any=0; now=$(date +%s)
    while read -r p t rest; do
        [[ -z "$p" ]] && continue
        any=1
        if [[ "$t" -gt 0 ]]; then
            echo "       $p  handshake hace $((now-t))s"
        else
            echo "       $p  SIN handshake"
        fi
    done < <(wg show $WG_IF latest-handshakes 2>/dev/null)
    [[ $any -eq 0 ]] && echo "       (ningun peer conectado)"

    # 6. Prueba REAL: puede el servidor salir a internet desde 10.66.66.1?
    echo ""
    echo "  Prueba de salida a internet (ping desde IP del tunel):"
    if ping -c 2 -W 2 -I $WG_NET.1 8.8.8.8 >/dev/null 2>&1; then
        ok "El servidor SI puede salir a internet desde $WG_NET.1"
        info "Si el cliente aun no navega: recrea el .conf del cliente (opcion 2)"
        info "Los .conf viejos tenian ::/0 y sin MTU — hay que regenerarlos."
    else
        err "El servidor NO puede salir a internet desde $WG_NET.1"
        info "El problema es la salida del propio server, NO del cliente."
        info "Prueba: ping -I $ifc 8.8.8.8   (¿la VPS tiene internet?)"
    fi
    line
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
        echo "  5) Diagnostico (por que no navega)"
        echo "  6) Detener / Eliminar servidor"
        echo "  0) Volver"
        line
        case "$(ask 'Opcion: ')" in
            1) wg_install; pause ;;
            2) wg_add_client; pause ;;
            3) wg_list; pause ;;
            4) wg_del_client; pause ;;
            5) wg_diag; pause ;;
            6) wg_remove; pause ;;
            0) return ;;
        esac
    done
}
