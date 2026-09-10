#!/bin/bash
# vaydns.sh - Tunel por consultas DNS (VayDNS)  ->  SOCKS5 local
# Creado y modificado por t:me/JuanitoProSniif
#
# ============================================================================
#  QUE ES
# ============================================================================
#  Un tunel que mete los datos DENTRO de consultas DNS. Es lo que en la app se
#  llama **WaniDNS**. Sirve para redes que bloquean todo menos el DNS, que es
#  el caso de una linea sin saldo: el operador deja pasar el puerto 53 porque
#  sin el no funcionaria ni su propio portal.
#
#      movil -> resolutor publico (8.8.8.8) -> ESTA VPS (autoritativa del NS)
#            -> vaydns-server -> SOCKS5 local -> internet
#
#  Es lento por naturaleza —cada consulta lleva unos 143 bytes— pero pasa
#  donde no pasa nada mas.
#
# ============================================================================
#  SALE POR EL SOCKS5 QUE YA TIENES, NO POR UN DANTE APARTE
# ============================================================================
#  El instalador original de VayDNS monta un Dante propio en 127.0.0.1:8000.
#  Aqui NO: "-upstream" apunta al hev-socks5-server que ya corre en el 1080.
#
#  Eso da tres cosas gratis:
#    · Las MISMAS cuentas que el SSH. Un usuario creado en el menu entra por
#      VayDNS sin tocar nada.
#    · El contador de usuarios online ya lo cuenta (categoria socks5).
#    · Una sola pieza que mantener y vigilar, no dos.
#
# ============================================================================
#  SUSTITUYE A SLOWDNS, NO CONVIVE CON EL
# ============================================================================
#  Los dos quieren el puerto 53 y los dos ponen la MISMA regla de iptables
#  (REDIRECT de 53 a 5300). El REDIRECT no mira que dominio se pregunta, asi
#  que se lo lleva todo: instalar uno rompe al otro. SlowDNS se retiro el
#  2026-09-09 y este ocupa su sitio.
[[ -n "$BASE_DIR" ]] || source /etc/msyvpn/lib.sh

VD_DIR="/etc/vaydns"
VD_BIN="$VD_DIR/vaydns-server"
VD_KEY="$VD_DIR/server.key"
VD_PUB="$VD_DIR/server.pub"
VD_NET="$VD_DIR/net.sh"
VD_PORT=5300

# De donde sale el binario si no esta en el repo propio. Conviene subirlo a
# bin/vaydns-server-<arch> del repo de MSYVPN para no depender de un tercero.
VD_UPSTREAM_URL="https://raw.githubusercontent.com/phoenixdnsvpn/phoenix-vpn/main/scripts/vaydns-server"

vd_installed() { [[ -x "$VD_BIN" ]]; }
vd_ns()        { cat "$VD_DIR/ns"     2>/dev/null; }   # dominio del tunel (el delegado)
vd_host()      { cat "$VD_DIR/host"   2>/dev/null; }   # nombre del servidor de nombres (registro A)
vd_upstream()  { echo "127.0.0.1:$(cat "$DATA_DIR/socks5.port" 2>/dev/null || echo 1080)"; }

# ---------------------------------------------------------------
# Binario
# ---------------------------------------------------------------
vd_fetch() {
    mkdir -p "$VD_DIR"
    # Primero el repo propio (fetch_bin ya reintenta y comprueba que sea un
    # ejecutable de verdad). Si no esta, se cae al de upstream.
    if fetch_bin vaydns-server "$VD_BIN" 2>/dev/null; then
        ok "vaydns-server: del repo propio ($(arch))"
        return 0
    fi
    info "vaydns-server no esta en el repo propio; probando upstream..."
    if descargar "$VD_UPSTREAM_URL" "$VD_BIN" && es_ejecutable "$VD_BIN"; then
        chmod +x "$VD_BIN"
        ok "vaydns-server: de upstream"
        return 0
    fi
    rm -f "$VD_BIN"
    msy_anotar_fallo "no se pudo obtener vaydns-server"
    err "No se pudo obtener vaydns-server"
    return 1
}

# ---------------------------------------------------------------
# Claves
# ---------------------------------------------------------------
#
# La PUBLICA es la que hay que meter en la app. La privada no sale de aqui.
# Solo se generan si no existen: si se regeneraran, TODOS los clientes ya
# repartidos dejarian de conectar de golpe.
vd_gen_key() {
    [[ -s "$VD_KEY" && -s "$VD_PUB" ]] && return 0
    "$VD_BIN" -gen-key -privkey-file "$VD_KEY" -pubkey-file "$VD_PUB" >/dev/null 2>&1
    if [[ ! -s "$VD_KEY" || ! -s "$VD_PUB" ]]; then
        err "No se pudieron generar las claves de VayDNS"
        return 1
    fi
    chmod 600 "$VD_KEY"
    ok "Claves de VayDNS generadas"
}

# ---------------------------------------------------------------
# Red
# ---------------------------------------------------------------
#
# El servidor escucha en el 5300 SIN privilegios y una regla de NAT le manda
# el 53. Se hace asi, y no atando el 53 directamente, por dos motivos: no hace
# falta darle CAP_NET_BIND_SERVICE al proceso, y en muchas VPS el 53 lo tiene
# cogido systemd-resolved.
vd_apply_net() {
    # systemd-resolved suele escuchar en el 53: se le quita el stub.
    if ss -ulnp 2>/dev/null | grep -qE '0\.0\.0\.0:53 |:::53 '; then
        if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            mkdir -p /etc/systemd/resolved.conf.d
            printf '[Resolve]\nDNSStubListener=no\n' > /etc/systemd/resolved.conf.d/msyvpn.conf
            systemctl restart systemd-resolved 2>/dev/null
        fi
    fi

    iptables -C INPUT -p udp --dport 53        -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport 53        -j ACCEPT
    iptables -C INPUT -p udp --dport $VD_PORT  -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport $VD_PORT  -j ACCEPT

    # SOLO lo que entra por la interfaz publica. Sin esa restriccion tambien
    # se secuestraba el DNS de los clientes de WireGuard y OpenVPN, que pasa
    # por PREROUTING al ser reenviado: sus consultas acababan en el tunel y se
    # quedaban sin resolver. Sintoma: "conecta pero no navega". Esta lección
    # viene de SlowDNS y aqui aplica igual.
    local pub
    pub=$(ip -4 route ls 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')

    # Limpiar reglas antiguas (las de SlowDNS y las sin restriccion de interfaz)
    while iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 5300 2>/dev/null; do :; done

    if [[ -n "$pub" ]]; then
        iptables -t nat -C PREROUTING -i "$pub" -p udp --dport 53 -j REDIRECT --to-ports $VD_PORT 2>/dev/null || \
            iptables -t nat -I PREROUTING -i "$pub" -p udp --dport 53 -j REDIRECT --to-ports $VD_PORT
    else
        iptables -t nat -C PREROUTING ! -i wg0 -p udp --dport 53 -j REDIRECT --to-ports $VD_PORT 2>/dev/null || \
            iptables -t nat -I PREROUTING ! -i wg0 -p udp --dport 53 -j REDIRECT --to-ports $VD_PORT
    fi

    command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active && ufw allow 53/udp >/dev/null 2>&1
    return 0
}

# ---------------------------------------------------------------
# Instalacion
# ---------------------------------------------------------------

# vd_setup <dominio_ns> <host_a> — sin preguntar nada, para el instalador.
#
#   dominio_ns : el que se delega, p.ej. n.midominio.com   (el del tunel)
#   host_a     : el nombre de esta maquina, p.ej. ns.midominio.com
vd_setup() {
    local ns="$1" host="$2"
    [[ -z "$ns" ]] && { err "Falta el dominio del tunel"; return 1; }

    mkdir -p "$VD_DIR"
    vd_installed || vd_fetch || return 1
    vd_gen_key || return 1

    echo "$ns"   > "$VD_DIR/ns"
    [[ -n "$host" ]] && echo "$host" > "$VD_DIR/host"

    # Las reglas se reaplican en cada arranque: un reinicio de la VPS las
    # perderia y el tunel quedaria mudo sin ninguna senal de por que.
    cat > "$VD_NET" <<EOF
#!/bin/bash
source /etc/msyvpn/vaydns.sh
vd_apply_net
EOF
    chmod +x "$VD_NET"
    vd_apply_net

    # ── Las banderas, y por que estas ────────────────────────────────────
    #  -record-type caa : el que mas datos devuelve por respuesta. La app trae
    #                     'caa' por defecto para WaniDNS; si se cambia aqui hay
    #                     que cambiarlo tambien alli o no se entienden.
    #  -mtu 1232        : tamano maximo de respuesta DNS que se atreve a mandar.
    #                     Por encima, muchos resolutores fragmentan o descartan.
    #  -upstream        : el SOCKS5 que ya corre en esta VPS. Ver la nota de
    #                     arriba: de ahi salen las cuentas compartidas.
    cat > /etc/systemd/system/msyvpn-vaydns.service <<EOF
[Unit]
Description=MSYVPN VayDNS (tunel por DNS)
After=network.target msyvpn-socks5.service
Wants=msyvpn-socks5.service

[Service]
ExecStartPre=$VD_NET
ExecStart=$VD_BIN -udp :$VD_PORT -privkey-file $VD_KEY -domain $ns -upstream $(vd_upstream) -mtu 1232 -record-type caa -idle-timeout 60s -keepalive 10s -log-level error
StandardOutput=null
StandardError=null
Restart=always
RestartSec=3
LimitNOFILE=65535
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=$VD_DIR
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now msyvpn-vaydns >/dev/null 2>&1
    svc_restart msyvpn-vaydns
    sleep 1

    if ! ss -ulnp 2>/dev/null | grep -q ":$VD_PORT "; then
        msy_anotar_fallo "VayDNS no escucha en el $VD_PORT"
        err "VayDNS no escucha en $VD_PORT. Ver: journalctl -u msyvpn-vaydns -n 20"
        return 1
    fi
    return 0
}

vd_install() {
    echo ""
    echo "  VayDNS necesita DOS nombres, y hay que crearlos en tu proveedor"
    echo "  de DNS ANTES de que esto funcione:"
    echo ""
    echo "     ns.tudominio.com   A    $(get_ip)      <- apunta a esta VPS"
    echo "     n.tudominio.com    NS   ns.tudominio.com"
    echo ""
    echo "  El primero (A) dice DONDE esta el servidor."
    echo "  El segundo (NS) delega ese subdominio a el: es el del tunel."
    echo ""
    local host ns
    host=$(ask 'Nombre del servidor, el del registro A (ej: ns.tudominio.com): ')
    ns=$(ask   'Dominio del tunel, el del registro NS (ej: n.tudominio.com): ')
    [[ -z "$ns" ]] && { err "El dominio del tunel no puede estar vacio"; return 1; }

    vd_setup "$ns" "$host" && ok "VayDNS activo" || { err "No se pudo activar VayDNS"; return 1; }
    vd_info
}

vd_info() {
    line
    if vd_installed && [[ -n "$(vd_ns)" ]]; then
        echo "Dominio del tunel : $(vd_ns)"
        [[ -n "$(vd_host)" ]] && echo "Servidor (A)      : $(vd_host) -> $(get_ip)"
        echo "Clave publica     : $(cat "$VD_PUB" 2>/dev/null)"
        echo "Salida            : SOCKS5 $(vd_upstream)  (cuentas del SSH)"
        ss -ulnp 2>/dev/null | grep -q ":$VD_PORT " && echo "Escucha $VD_PORT      : si" || echo "Escucha $VD_PORT      : NO"
        svc_active msyvpn-vaydns && echo "Estado            : $(g activo)" || echo "Estado            : $(r inactivo)"
        echo ""
        echo "En la app: protocolo WaniDNS."
        echo "  Dominio del tunel : $(vd_ns)"
        echo "  Clave publica     : la de arriba"
        echo "  Resolutor         : 8.8.8.8:53  (probar tambien 1.1.1.1:53)"
        echo "  Tipo de registro  : caa"
        echo "  Longitud QNAME    : 253"
        echo "  Usuario y clave   : los de cualquier cuenta del menu"
        echo ""
        echo "En tu proveedor de DNS tiene que existir:"
        echo "  $(vd_host 2>/dev/null || echo 'ns.tudominio.com')   A    $(get_ip)"
        echo "  $(vd_ns)   NS   $(vd_host 2>/dev/null || echo 'ns.tudominio.com')"
    else
        echo "VayDNS no instalado."
    fi
    line
}

# Comprueba que la delegacion este de verdad puesta. Es el fallo numero uno:
# el servidor arranca perfecto y no conecta nadie porque el NS no esta.
vd_check_dns() {
    local ns; ns=$(vd_ns)
    [[ -z "$ns" ]] && { err "VayDNS no configurado"; return 1; }
    command -v dig >/dev/null 2>&1 || ensure_pkg dnsutils >/dev/null 2>&1
    command -v dig >/dev/null 2>&1 || { err "Falta 'dig' (paquete dnsutils)"; return 1; }

    echo "Preguntando por la delegacion de $ns ..."
    local res; res=$(dig +short NS "$ns" @8.8.8.8 2>/dev/null)
    if [[ -z "$res" ]]; then
        err "Nadie responde NS para $ns"
        info "Falta el registro NS en tu proveedor, o aun no se ha propagado"
        info "(puede tardar desde minutos hasta unas horas)."
        return 1
    fi
    ok "NS delegado a: $(echo "$res" | tr '\n' ' ')"

    # Y que ese nombre apunte AQUI.
    local host ip mia
    host=$(echo "$res" | head -1 | sed 's/\.$//')
    ip=$(dig +short A "$host" @8.8.8.8 2>/dev/null | head -1)
    mia=$(get_ip)
    if [[ "$ip" == "$mia" ]]; then
        ok "$host apunta a esta VPS ($ip)"
    else
        err "$host apunta a '${ip:-nada}' y esta VPS es $mia"
        return 1
    fi
}

vd_remove() {
    systemctl disable --now msyvpn-vaydns >/dev/null 2>&1
    rm -f /etc/systemd/system/msyvpn-vaydns.service
    systemctl daemon-reload
    while iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports $VD_PORT 2>/dev/null; do :; done
    iptables -t nat -D PREROUTING -i "$(ip -4 route ls 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')" \
        -p udp --dport 53 -j REDIRECT --to-ports $VD_PORT 2>/dev/null
    ok "VayDNS detenido (las claves se conservan en $VD_DIR)"
}

vd_menu() {
    while true; do
        clear; title "VAYDNS  (tunel por DNS)"
        vd_info
        echo "  1) Instalar / Reconfigurar"
        echo "  2) Comprobar la delegacion del dominio"
        echo "  3) Reaplicar reglas de red"
        echo "  4) Reiniciar"
        echo "  5) Detener y quitar"
        echo "  0) Volver"
        line
        case "$(ask 'Opcion: ')" in
            1) vd_install; pause ;;
            2) vd_check_dns; pause ;;
            3) vd_apply_net; ok "Reglas aplicadas"; pause ;;
            4) svc_restart msyvpn-vaydns; ok "Reiniciado"; pause ;;
            5) vd_remove; pause ;;
            0) return ;;
        esac
    done
}
