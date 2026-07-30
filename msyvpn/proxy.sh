#!/bin/bash
# proxy.sh - Gestion de HAProxy + wsproxy + certificado
# HAProxy escucha los puertos publicos (TLS y plano) y entrega
# todo al wsproxy interno, que detecta SSH / WebSocket / V2Ray.
[[ -n "$BASE_DIR" ]] || source /etc/msyvpn/lib.sh

PLAIN_FILE="$BASE_DIR/ports.plain"
TLS_FILE="$BASE_DIR/ports.tls"
DEF_PLAIN="80 8080 8880 2086"
DEF_TLS="443 444 8443"

_plain_ports() { cat "$PLAIN_FILE" 2>/dev/null || echo "$DEF_PLAIN"; }
_tls_ports()   { cat "$TLS_FILE"   2>/dev/null || echo "$DEF_TLS"; }

proxy_gen_cert() {
    [[ -s "$CERT_PEM" ]] && return 0
    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
        -subj "/C=CO/O=MSYVPN/CN=msyvpn.local" \
        -keyout /tmp/_k.pem -out /tmp/_c.pem >/dev/null 2>&1
    cat /tmp/_c.pem /tmp/_k.pem > "$CERT_PEM"
    chmod 600 "$CERT_PEM"; rm -f /tmp/_k.pem /tmp/_c.pem
}

proxy_write_config() {
    proxy_gen_cert
    [[ -f "$PLAIN_FILE" ]] || echo "$DEF_PLAIN" > "$PLAIN_FILE"
    [[ -f "$TLS_FILE"   ]] || echo "$DEF_TLS"   > "$TLS_FILE"
    local nthr; nthr=$(nproc 2>/dev/null || echo 2)
    {
        cat <<EOF
global
    maxconn 60000
    # nbthread: reparte el trabajo entre todos los nucleos
    nbthread $nthr
    tune.ssl.default-dh-param 2048
    # SIN 'log': en modo TCP HAProxy escribe una linea por conexion.
    # Con cientos de usuarios eso llenaba el disco en horas.

defaults
    mode tcp
    no log
    option dontlognull
    timeout connect 5s
    timeout client  1h
    timeout server  1h

frontend ft_plain
EOF
        for p in $(_plain_ports); do echo "    bind :$p"; done
        echo "    default_backend bk_ws"
        echo ""
        echo "frontend ft_tls"
        for p in $(_tls_ports); do echo "    bind :$p ssl crt $CERT_PEM"; done
        cat <<EOF
    default_backend bk_ws

backend bk_ws
    # send-proxy: pasa la IP real del cliente al wsproxy (conteo exacto)
    server ws 127.0.0.1:$WSPROXY_INTERNAL send-proxy
EOF
    } > "$HAPROXY_CFG"
    for p in $(_plain_ports) $(_tls_ports); do open_port "$p" tcp; done
    systemctl reload haproxy 2>/dev/null || systemctl restart haproxy 2>/dev/null
}

proxy_add_port() {
    local kind="$1" pt="$2" file
    [[ "$kind" == tls ]] && file="$TLS_FILE" || file="$PLAIN_FILE"
    [[ "$pt" =~ ^[0-9]+$ ]] || { err "Puerto invalido"; return; }
    local cur; cur=$( [[ "$kind" == tls ]] && _tls_ports || _plain_ports )
    echo "$cur" | grep -qw "$pt" && { info "Ya existe"; return; }
    echo "$cur $pt" > "$file"; proxy_write_config
    ok "Puerto $pt agregado ($kind)"
}

proxy_del_port() {
    local pt="$1" f
    for f in "$PLAIN_FILE" "$TLS_FILE"; do
        [[ -f "$f" ]] && echo "$(tr ' ' '\n' < "$f" | grep -vw "$pt" | xargs)" > "$f"
    done
    proxy_write_config; ok "Puerto $pt eliminado"
}

# Certificado real Let's Encrypt (detiene HAProxy para validar en el 80).
# Con cert real, V2Ray funciona con allowInsecure ON u OFF.
proxy_cert_real() {
    local dom="$1"; [[ -z "$dom" ]] && { err "Dominio vacio"; return 1; }
    echo "$dom" > "$DATA_DIR/domain"
    ensure_pkg socat curl
    if [[ ! -x /root/.acme.sh/acme.sh ]]; then
        curl -s https://get.acme.sh | sh -s email=admin@"$dom" >/dev/null 2>&1
    fi
    [[ -x /root/.acme.sh/acme.sh ]] || { err "No se pudo instalar acme.sh"; return 1; }
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1
    info "Liberando el puerto 80 para la validacion..."
    systemctl stop haproxy 2>/dev/null
    /root/.acme.sh/acme.sh --issue -d "$dom" --standalone --httpport 80 >/tmp/acme.log 2>&1
    local d=/root/.acme.sh/${dom}_ecc; [[ -d "$d" ]] || d=/root/.acme.sh/${dom}
    if [[ -s "$d/fullchain.cer" && -s "$d/${dom}.key" ]]; then
        cat "$d/fullchain.cer" "$d/${dom}.key" > "$CERT_PEM"; chmod 600 "$CERT_PEM"
        systemctl start haproxy 2>/dev/null; proxy_write_config
        ok "Certificado real instalado para $dom"
        info "Usa security=tls y sni=$dom — funciona con o sin allowInsecure."
    else
        systemctl start haproxy 2>/dev/null
        err "No se pudo emitir el certificado. Revisa el DNS del dominio y el puerto 80."
        tail -3 /tmp/acme.log 2>/dev/null
    fi
}

# Cambia la salida a internet entre IPv6 e IPv4 y lo aplica a todo
# (sistema, Xray e Hysteria) para que la geolocalizacion sea la correcta.
proxy_set_ipvpref() {
    local pref="$1"
    if [[ "$pref" == 6 ]] && ! has_ipv6; then
        err "Esta VPS no tiene IPv6 global asignada."
        info "Actívala en el panel de tu proveedor y vuelve a intentar."
        return 1
    fi
    net_apply_pref "$pref"
    # Reconstruir configs que llevan la preferencia dentro
    if declare -F v2_rebuild >/dev/null 2>&1 && [[ -n "$(command -v xray)" ]]; then
        v2_rebuild && svc_restart xray
    fi
    if declare -F hy_add_user >/dev/null 2>&1; then hy_add_user; fi
    if [[ "$pref" == 6 ]]; then
        ok "Salida preferente por IPv6: $(get_ip6)"
        info "Comprueba con: curl -s https://ifconfig.co"
    else
        ok "Salida preferente por IPv4: $(get_ip)"
    fi
}

# ---------------------------------------------------------------------
# SALIDA IPv6 PARA SSH / SlowDNS  (geolocalizacion correcta)
# ---------------------------------------------------------------------
# Las apps envian al servidor una IP ya resuelta (IPv4), y a un destino
# IPv4 solo se llega desde una IP de origen IPv4. V2Ray se libra porque
# Xray hace "sniffing": lee el dominio del SNI y lo resuelve de nuevo,
# eligiendo IPv6. Aqui se hace lo mismo para el resto: el trafico TCP de
# las cuentas VPN se manda a un proxy transparente local de Xray.
V6X_CHAIN="MSYVPN_V6"
V6X_PORT=12346
: "${XR_V6X:=$DATA_DIR/v6exit}"

_v6x_uids() {
    local u; while read -r u _; do
        [[ -n "$u" ]] && id -u "$u" 2>/dev/null
    done < <(cat "$USERS_DB" 2>/dev/null)
}

_v6x_rules_del() {
    # Se borran TODOS los saltos a nuestra cadena leyendo iptables-save,
    # asi no quedan reglas huerfanas de cuentas ya eliminadas.
    local rule n=0
    while :; do
        rule=$(iptables-save -t nat 2>/dev/null | \
               grep -m1 -- "-A OUTPUT .*-j $V6X_CHAIN" | sed 's/^-A //')
        [[ -z "$rule" ]] && break
        # shellcheck disable=SC2086
        iptables -t nat -D $rule 2>/dev/null || break
        n=$((n+1)); [[ $n -ge 100 ]] && break
    done
    iptables -t nat -F "$V6X_CHAIN" 2>/dev/null
    iptables -t nat -X "$V6X_CHAIN" 2>/dev/null
}

_v6x_rules_add() {
    iptables -t nat -N "$V6X_CHAIN" 2>/dev/null
    iptables -t nat -F "$V6X_CHAIN"
    # Nunca desviar trafico local o privado
    local net
    for net in 0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 169.254.0.0/16 \
               172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
        iptables -t nat -A "$V6X_CHAIN" -d "$net" -j RETURN
    done
    iptables -t nat -A "$V6X_CHAIN" -d "$(get_ip)" -j RETURN 2>/dev/null
    iptables -t nat -A "$V6X_CHAIN" -p tcp -j REDIRECT --to-ports "$V6X_PORT"
    # Enganchar solo los UID de las cuentas VPN (no root ni el sistema)
    local uid n=0
    for uid in $(_v6x_uids); do
        iptables -t nat -C OUTPUT -p tcp -m owner --uid-owner "$uid" -j "$V6X_CHAIN" 2>/dev/null || \
            iptables -t nat -A OUTPUT -p tcp -m owner --uid-owner "$uid" -j "$V6X_CHAIN"
        n=$((n+1))
    done
    echo "$n"
}

# Enciende el desvio transparente: el trafico TCP de las cuentas VPN
# pasa por Xray. Sirve tanto para salir por IPv6 como para salir por un
# nodo remoto (exitvpn). No requiere IPv6.
xredirect_on() {
    if [[ -z "$(command -v xray)" ]] && [[ ! -x /usr/local/bin/xray ]]; then
        err "Requiere Xray instalado (menu -> V2Ray -> Instalar)"; return 1
    fi
    echo 1 > "$XR_V6X"
    if ! v2_rebuild; then
        echo 0 > "$XR_V6X"; err "No se pudo generar la config de Xray"; return 1
    fi
    svc_restart xray; sleep 2
    # Comprobar de verdad que Xray abrio el puerto del proxy transparente
    local i up=0
    for i in 1 2 3 4 5; do
        if ss -tlnH 2>/dev/null | grep -q ":$V6X_PORT" || \
           (exec 3<>/dev/tcp/127.0.0.1/$V6X_PORT) 2>/dev/null; then up=1; break; fi
        sleep 1
    done
    if [[ $up -eq 0 ]]; then
        echo 0 > "$XR_V6X"; v2_rebuild; svc_restart xray
        err "Xray no abrio el puerto $V6X_PORT — no se aplicaron reglas"
        info "Mira el error con: journalctl -u xray -n 20"
        return 1
    fi
    local n; n=$(_v6x_rules_add)
    ok "Desvio por Xray activo para $n cuentas (trafico TCP)"
    info "OJO: anade un salto por Xray a TODO el trafico TCP de SSH."
    info "Con muchos usuarios sube el CPU; si se satura, desactivalo."
    return 0
}

v6exit_on() {
    if ! has_ipv6; then err "Esta VPS no tiene IPv6 global"; return 1; fi
    prefer_ipv6 || net_apply_pref 6
    xredirect_on || return 1
    info "Las apps veran la geo de tu IPv6 en los sitios con IPv6."
    info "UDP y destinos solo-IPv4 seguiran saliendo por IPv4."
}

v6exit_off() {
    _v6x_rules_del
    echo 0 > "$XR_V6X"
    if declare -F v2_rebuild >/dev/null 2>&1; then v2_rebuild && svc_restart xray; fi
    ok "Desvio transparente desactivado"
}

# Rehace los enganches al crear/borrar cuentas
v6exit_refresh() {
    [[ "$(cat "$XR_V6X" 2>/dev/null)" == "1" ]] || return 0
    _v6x_rules_del; _v6x_rules_add >/dev/null
}

v6exit_status() {
    if [[ "$(cat "$XR_V6X" 2>/dev/null)" == "1" ]] && \
       iptables -t nat -L "$V6X_CHAIN" >/dev/null 2>&1; then
        echo "activa"
    else
        echo "inactiva"
    fi
}

# Activa/desactiva la linea que se muestra antes del banner SSH
proxy_toggle_sshbanner() {
    local env="$BASE_DIR/wsproxy.env"
    if grep -q '^WSPROXY_SSH_BANNER=.\+' "$env" 2>/dev/null; then
        sed -i 's|^WSPROXY_SSH_BANNER=.*|WSPROXY_SSH_BANNER=|' "$env"
        ok "Banner SSH desactivado"
    else
        sed -i '/^WSPROXY_SSH_BANNER=/d' "$env" 2>/dev/null
        echo "WSPROXY_SSH_BANNER=MSY_VPN_SCRIPT" >> "$env"
        ok "Banner SSH activado"
    fi
    svc_restart msyvpn-wsproxy
}

proxy_status() {
    echo "Puertos plano : $(_plain_ports)"
    echo "Puertos TLS   : $(_tls_ports)"
    if prefer_ipv6; then echo "Salida        : IPv6 ($(get_ip6))"
    else echo "Salida        : IPv4 ($(get_ip))"; fi
    echo "Salida SSH v6 : $(v6exit_status)"
    svc_active haproxy        && echo "HAProxy       : activo" || echo "HAProxy       : inactivo"
    svc_active msyvpn-wsproxy && echo "wsproxy       : activo" || echo "wsproxy       : inactivo"
    svc_active msyvpn-badvpn  && echo "BadVPN UDP    : activo" || echo "BadVPN UDP    : inactivo"
}

proxy_menu() {
    while true; do
        clear; title "PROXY / SSL  (HAProxy + wsproxy)"
        proxy_status
        line
        echo "  1) Agregar puerto PLANO (sin TLS)"
        echo "  2) Agregar puerto TLS (SSL)"
        echo "  3) Eliminar puerto"
        echo "  4) Salida a internet por IPv6 (geolocalizacion)"
        echo "  5) Salida a internet por IPv4"
        echo "  6) ACTIVAR salida IPv6 para SSH/SlowDNS  <- geo Austria"
        echo "  7) Desactivar salida IPv6 para SSH"
        echo "  8) Activar/desactivar banner SSH"
        echo "  9) Reiniciar proxy"
        echo "  0) Volver"
        line
        case "$(ask 'Opcion: ')" in
            1) proxy_add_port plain "$(ask 'Puerto plano: ')"; pause ;;
            2) proxy_add_port tls   "$(ask 'Puerto TLS: ')";   pause ;;
            3) proxy_del_port "$(ask 'Puerto a eliminar: ')";  pause ;;
            4) proxy_set_ipvpref 6; pause ;;
            5) proxy_set_ipvpref 4; pause ;;
            6) v6exit_on;  pause ;;
            7) v6exit_off; pause ;;
            8) proxy_toggle_sshbanner; pause ;;
            9) proxy_write_config; svc_restart msyvpn-wsproxy; ok "Reiniciado"; pause ;;
            0) return ;;
        esac
    done
}
