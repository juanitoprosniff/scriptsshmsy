#!/bin/bash
# openvpn.sh - OpenVPN en dos modos que comparten usuarios y certificados
#   UDP directo : maximo rendimiento (juegos/streaming), sin BadVPN
#   TCP interno : detras del wsproxy -> payloads, TLS, SlowDNS y los
#                 mismos puertos publicos que ya usa SSH
# Autenticacion por usuario/contrasena del sistema (PAM), asi las mismas
# cuentas SSH sirven y caducan igual.
[[ -n "$BASE_DIR" ]] || source /etc/msyvpn/lib.sh

OV_DIR="/etc/openvpn/msyvpn"
OV_PKI="$OV_DIR/pki"
OV_CLIENTS="$OV_DIR/clients"
OV_UDP_PORT_DEF=1194
OV_TCP_BASE=11940        # puertos internos TCP: 11940, 11941, ...
OV_STATUS="/run/openvpn"

ov_bin()        { command -v openvpn 2>/dev/null; }
ov_installed()  { [[ -n "$(ov_bin)" && -s "$OV_PKI/ca.crt" ]]; }
ov_udp_port()   { cat "$OV_DIR/udp.port" 2>/dev/null || echo $OV_UDP_PORT_DEF; }
ov_tcp_count()  { cat "$OV_DIR/tcp.count" 2>/dev/null || echo 1; }
ov_udp_on()     { [[ -f /etc/systemd/system/msyvpn-ovpn-udp.service ]]; }

# Ruta del plugin PAM (cambia segun distro)
ov_pam_plugin() {
    local p
    for p in /usr/lib/openvpn/openvpn-plugin-auth-pam.so \
             /usr/lib/openvpn/plugins/openvpn-plugin-auth-pam.so \
             /usr/lib/x86_64-linux-gnu/openvpn/plugins/openvpn-plugin-auth-pam.so \
             /usr/lib64/openvpn/plugins/openvpn-plugin-auth-pam.so; do
        [[ -f "$p" ]] && { echo "$p"; return; }
    done
    find /usr/lib -name 'openvpn-plugin-auth-pam.so' 2>/dev/null | head -1
}

# ---- PKI propia (sin easy-rsa: mas rapido y sin dependencias) --------
ov_make_pki() {
    mkdir -p "$OV_PKI"; chmod 700 "$OV_PKI"
    [[ -s "$OV_PKI/ca.crt" && -s "$OV_PKI/server.crt" ]] && return 0
    info "Generando certificados (una sola vez)..."
    openssl req -x509 -new -nodes -newkey rsa:2048 -days 3650 \
        -keyout "$OV_PKI/ca.key" -out "$OV_PKI/ca.crt" \
        -subj "/CN=MSYVPN-CA" >/dev/null 2>&1
    openssl req -new -nodes -newkey rsa:2048 \
        -keyout "$OV_PKI/server.key" -out "$OV_PKI/server.csr" \
        -subj "/CN=msyvpn-server" >/dev/null 2>&1
    printf 'extendedKeyUsage=serverAuth\nkeyUsage=digitalSignature,keyEncipherment\n' \
        > "$OV_PKI/srv.ext"
    openssl x509 -req -in "$OV_PKI/server.csr" -CA "$OV_PKI/ca.crt" \
        -CAkey "$OV_PKI/ca.key" -CAcreateserial -days 3650 \
        -extfile "$OV_PKI/srv.ext" -out "$OV_PKI/server.crt" >/dev/null 2>&1
    rm -f "$OV_PKI/server.csr" "$OV_PKI/srv.ext"
    # Clave tls-crypt (el nombre del subcomando cambio en OpenVPN 2.6)
    "$(ov_bin)" --genkey secret "$OV_PKI/ta.key" >/dev/null 2>&1 || \
    "$(ov_bin)" --genkey --secret "$OV_PKI/ta.key" >/dev/null 2>&1
    chmod 600 "$OV_PKI"/*.key
    [[ -s "$OV_PKI/server.crt" && -s "$OV_PKI/ta.key" ]]
}

# Servicio PAM propio: valida contra /etc/shadow y respeta la caducidad
# de la cuenta, sin exigir shell valida (los usuarios usan /bin/false).
ov_make_pam() {
    cat > /etc/pam.d/openvpn <<'EOF'
auth    required pam_unix.so shadow nodelay
account required pam_unix.so
EOF
    # Metodo alternativo por si la distro no trae el plugin PAM: valida
    # contra las contrasenas que guarda el script y respeta la caducidad.
    cat > "$OV_DIR/auth.sh" <<'AUTHEOF'
#!/bin/bash
# OpenVPN pasa un fichero temporal con usuario (linea 1) y clave (linea 2)
u=$(sed -n 1p "$1"); p=$(sed -n 2p "$1")
[[ -z "$u" || -z "$p" ]] && exit 1
id "$u" >/dev/null 2>&1 || exit 1
# Cuenta caducada -> denegar
exp=$(getent shadow "$u" 2>/dev/null | cut -d: -f8)
if [[ -n "$exp" ]] && [[ $exp -gt 0 ]] && [[ $(( $(date +%s) / 86400 )) -gt $exp ]]; then
    exit 1
fi
real=$(cat "/etc/msyvpn/data/senha/$u" 2>/dev/null)
[[ -n "$real" && "$p" == "$real" ]] && exit 0
exit 1
AUTHEOF
    chmod 700 "$OV_DIR/auth.sh"
}

# ---- Configuracion comun a todas las instancias ----------------------
# $1 = archivo destino, $2 = proto (udp|tcp-server), $3 = puerto,
# $4 = dev, $5 = subred (ej 10.8.0.0), $6 = local (vacio = todas)
ov_write_server() {
    local f="$1" proto="$2" port="$3" dev="$4" net="$5" bind="$6"
    local pam; pam=$(ov_pam_plugin)
    {
        [[ -n "$bind" ]] && echo "local $bind"
        echo "port $port"
        echo "proto $proto"
        echo "dev $dev"
        echo "dev-type tun"
        echo "ca $OV_PKI/ca.crt"
        echo "cert $OV_PKI/server.crt"
        echo "key $OV_PKI/server.key"
        echo "dh none"
        echo "tls-crypt $OV_PKI/ta.key"
        echo "topology subnet"
        echo "server $net 255.255.255.0"
        echo 'push "redirect-gateway def1 bypass-dhcp"'
        echo 'push "dhcp-option DNS 1.1.1.1"'
        echo 'push "dhcp-option DNS 8.8.8.8"'
        echo "keepalive 10 60"
        echo "data-ciphers AES-256-GCM:AES-128-GCM"
        echo "data-ciphers-fallback AES-256-GCM"
        echo "auth SHA256"
        # Sin certificado por cliente: solo usuario/contrasena del sistema
        echo "verify-client-cert none"
        echo "username-as-common-name"
        echo "duplicate-cn"
        if [[ -n "$pam" ]]; then
            echo "plugin $pam openvpn"
        else
            # Sin plugin PAM: validar con el script propio
            echo "auth-user-pass-verify $OV_DIR/auth.sh via-file"
            echo "script-security 2"
        fi
        echo "persist-key"
        echo "persist-tun"
        echo "user nobody"
        echo "group nogroup"
        echo "verb 1"
        echo "mute 20"
        # El estado va a /run (tmpfs): permite contar usuarios sin gastar disco
        echo "status $OV_STATUS/$(basename "$f" .conf).status 10"
        echo "status-version 2"
        [[ "$proto" == udp ]] && echo "explicit-exit-notify 1"
    } > "$f"
}

ov_unit() {   # $1 = nombre servicio, $2 = archivo conf
    cat > "/etc/systemd/system/$1.service" <<EOF
[Unit]
Description=MSYVPN OpenVPN ($1)
After=network.target

[Service]
Type=simple
RuntimeDirectory=openvpn
ExecStart=$(ov_bin) --config $2
StandardOutput=null
StandardError=null
Restart=always
RestartSec=3
LimitNPROC=infinity
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
EOF
}

# NAT para las subredes de OpenVPN (idempotente)
ov_apply_nat() {
    local ifc; ifc=$(ip -4 route ls 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
    [[ -z "$ifc" ]] && ifc=eth0
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    iptables -P FORWARD ACCEPT 2>/dev/null
    local n
    for n in $(seq 0 "$(ov_tcp_count)"); do
        iptables -t nat -C POSTROUTING -s "10.8.$n.0/24" -o "$ifc" -j MASQUERADE 2>/dev/null || \
            iptables -t nat -I POSTROUTING -s "10.8.$n.0/24" -o "$ifc" -j MASQUERADE
    done
    iptables -C FORWARD -i tun+ -j ACCEPT 2>/dev/null || iptables -I FORWARD -i tun+ -j ACCEPT
    iptables -C FORWARD -o tun+ -j ACCEPT 2>/dev/null || iptables -I FORWARD -o tun+ -j ACCEPT
}

# Publica los backends TCP para que el wsproxy sepa a donde enviar
ov_write_route() {
    local list="" n
    for ((n=0; n<$(ov_tcp_count); n++)); do
        [[ -n "$list" ]] && list+=","
        list+="127.0.0.1:$((OV_TCP_BASE+n))"
    done
    sed -i '/^OPENVPN=/d' "$ROUTES_CONF" 2>/dev/null
    [[ -n "$list" ]] && echo "OPENVPN=$list" >> "$ROUTES_CONF"
    svc_restart msyvpn-wsproxy
}

# ---- Instalacion ------------------------------------------------------
# ov_setup [puerto_udp] [instancias_tcp]
ov_setup() {
    local uport="${1:-$OV_UDP_PORT_DEF}" tcpn="${2:-1}"
    ensure_pkg openvpn openssl iptables
    [[ -n "$(ov_bin)" ]] || { err "No se pudo instalar OpenVPN"; return 1; }
    mkdir -p "$OV_DIR" "$OV_CLIENTS" "$OV_STATUS"
    ov_make_pki || { err "Fallo la generacion de certificados"; return 1; }
    ov_make_pam
    echo "$uport" > "$OV_DIR/udp.port"
    echo "$tcpn"  > "$OV_DIR/tcp.count"

    # Instancia UDP (directa, la mas eficiente)
    ov_write_server "$OV_DIR/udp.conf" udp "$uport" tun8 "10.8.0.0" ""
    ov_unit msyvpn-ovpn-udp "$OV_DIR/udp.conf"
    open_port "$uport" udp

    # Instancias TCP (internas, detras del wsproxy). Una por nucleo si se
    # pidieron varias: OpenVPN es de un solo hilo por proceso.
    local n
    for ((n=0; n<tcpn; n++)); do
        ov_write_server "$OV_DIR/tcp$n.conf" tcp-server "$((OV_TCP_BASE+n))" \
            "tun9$n" "10.8.$((n+1)).0" "127.0.0.1"
        ov_unit "msyvpn-ovpn-tcp$n" "$OV_DIR/tcp$n.conf"
    done

    ov_apply_nat
    systemctl daemon-reload
    systemctl enable --now msyvpn-ovpn-udp >/dev/null 2>&1
    for ((n=0; n<tcpn; n++)); do
        systemctl enable --now "msyvpn-ovpn-tcp$n" >/dev/null 2>&1
    done
    ov_write_route
    sleep 2
    ov_make_ovpn
    return 0
}

ov_install() {
    local uport tcpn cores
    cores=$(nproc 2>/dev/null || echo 1)
    uport=$(ask "Puerto UDP [$OV_UDP_PORT_DEF]: "); [[ "$uport" =~ ^[0-9]+$ ]] || uport=$OV_UDP_PORT_DEF
    echo "  OpenVPN usa un solo nucleo por instancia."
    echo "  Con muchos usuarios conviene una instancia TCP por nucleo (tienes $cores)."
    tcpn=$(ask "Instancias TCP [1]: "); [[ "$tcpn" =~ ^[0-9]+$ ]] && [[ $tcpn -ge 1 ]] || tcpn=1
    [[ $tcpn -gt 8 ]] && tcpn=8
    ov_setup "$uport" "$tcpn" && ok "OpenVPN activo (UDP $uport + $tcpn instancia(s) TCP)"
    ov_info
}

# ---- Perfiles .ovpn ---------------------------------------------------
# Un solo perfil sirve para todos: la autenticacion es por usuario.
ov_make_ovpn() {
    local ip tlsport; ip=$(get_ip)
    tlsport=$(cat "$BASE_DIR/ports.tls" 2>/dev/null | awk '{print $1}'); [[ -z "$tlsport" ]] && tlsport=443
    local plain; plain=$(cat "$BASE_DIR/ports.plain" 2>/dev/null | awk '{print $1}'); [[ -z "$plain" ]] && plain=80
    mkdir -p "$OV_CLIENTS"
    local base="client
dev tun
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth-user-pass
data-ciphers AES-256-GCM:AES-128-GCM
data-ciphers-fallback AES-256-GCM
auth SHA256
verb 1"

    # UDP directo
    { echo "$base"; echo "proto udp"; echo "remote $ip $(ov_udp_port)"
      echo "<ca>"; cat "$OV_PKI/ca.crt"; echo "</ca>"
      echo "<tls-crypt>"; cat "$OV_PKI/ta.key"; echo "</tls-crypt>"
    } > "$OV_CLIENTS/msyvpn-udp.ovpn"

    # TCP por el puerto publico (pasa por HAProxy+wsproxy: payload/TLS)
    { echo "$base"; echo "proto tcp"; echo "remote $ip $plain"
      echo "<ca>"; cat "$OV_PKI/ca.crt"; echo "</ca>"
      echo "<tls-crypt>"; cat "$OV_PKI/ta.key"; echo "</tls-crypt>"
    } > "$OV_CLIENTS/msyvpn-tcp.ovpn"

    # Automatico: intenta UDP y cae a TCP si esta bloqueado
    { echo "$base"
      echo "<connection>"; echo "remote $ip $(ov_udp_port) udp"; echo "</connection>"
      echo "<connection>"; echo "remote $ip $plain tcp-client"; echo "</connection>"
      echo "<ca>"; cat "$OV_PKI/ca.crt"; echo "</ca>"
      echo "<tls-crypt>"; cat "$OV_PKI/ta.key"; echo "</tls-crypt>"
    } > "$OV_CLIENTS/msyvpn-auto.ovpn"
    chmod 600 "$OV_CLIENTS"/*.ovpn
}

ov_show_profiles() {
    ov_installed || { err "OpenVPN no instalado"; return; }
    ov_make_ovpn
    line
    echo "Perfiles (la misma cuenta SSH sirve como usuario/contrasena):"
    echo "  UDP directo : $OV_CLIENTS/msyvpn-udp.ovpn   (mejor para juegos)"
    echo "  TCP publico : $OV_CLIENTS/msyvpn-tcp.ovpn   (payload/TLS/SlowDNS)"
    echo "  Automatico  : $OV_CLIENTS/msyvpn-auto.ovpn  (UDP y cae a TCP)"
    echo ""
    echo "Descargalos con:"
    echo "  scp root@$(get_ip):$OV_CLIENTS/'*.ovpn' ."
    line
}

ov_info() {
    line
    if ov_installed; then
        echo "Servidor : $(get_ip)"
        echo "UDP      : puerto $(ov_udp_port)   $(svc_active msyvpn-ovpn-udp && g activo || r inactivo)"
        local n act=0
        for ((n=0; n<$(ov_tcp_count); n++)); do
            svc_active "msyvpn-ovpn-tcp$n" && act=$((act+1))
        done
        echo "TCP      : $act/$(ov_tcp_count) instancias activas (puertos internos desde $OV_TCP_BASE)"
        echo "           entra por los puertos publicos: $(cat "$BASE_DIR/ports.plain" 2>/dev/null) / TLS $(cat "$BASE_DIR/ports.tls" 2>/dev/null)"
        echo "Auth     : usuario y contrasena de las cuentas SSH"
    else
        echo "OpenVPN no instalado."
    fi
    line
}

ov_remove() {
    systemctl disable --now msyvpn-ovpn-udp >/dev/null 2>&1
    local n
    for ((n=0; n<8; n++)); do
        systemctl disable --now "msyvpn-ovpn-tcp$n" >/dev/null 2>&1
        rm -f "/etc/systemd/system/msyvpn-ovpn-tcp$n.service"
    done
    rm -f /etc/systemd/system/msyvpn-ovpn-udp.service
    systemctl daemon-reload
    sed -i '/^OPENVPN=/d' "$ROUTES_CONF" 2>/dev/null
    svc_restart msyvpn-wsproxy
    ok "OpenVPN detenido (certificados conservados en $OV_PKI)"
}

ov_menu() {
    while true; do
        clear; title "OPENVPN  (UDP directo + TCP por payload/TLS)"
        ov_info
        echo "  1) Instalar / Reconfigurar"
        echo "  2) Ver perfiles .ovpn"
        echo "  3) Reaplicar NAT (si no navega)"
        echo "  4) Eliminar"
        echo "  0) Volver"
        line
        case "$(ask 'Opcion: ')" in
            1) ov_install; pause ;;
            2) ov_show_profiles; pause ;;
            3) ov_apply_nat; ok "NAT reaplicado"; pause ;;
            4) ov_remove; pause ;;
            0) return ;;
        esac
    done
}
