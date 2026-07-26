#!/bin/bash
# proxy.sh - Gestion de HAProxy + wsproxy + certificado
# HAProxy escucha los puertos publicos (TLS y plano) y entrega
# todo al wsproxy interno, que detecta SSH / WebSocket / V2Ray.
[[ -n "$BASE_DIR" ]] || source /etc/msyvpn/lib.sh

PLAIN_FILE="$BASE_DIR/ports.plain"
TLS_FILE="$BASE_DIR/ports.tls"
DEF_PLAIN="80 8080 8880"
DEF_TLS="443 444 8443"

_plain_ports() { cat "$PLAIN_FILE" 2>/dev/null || echo "$DEF_PLAIN"; }
_tls_ports()   { cat "$TLS_FILE"   2>/dev/null || echo "$DEF_TLS"; }

# Certificado self-signed para HAProxy (cert + key en un solo .pem)
proxy_gen_cert() {
    [[ -s "$CERT_PEM" ]] && return 0
    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
        -subj "/C=CO/O=MSYVPN/CN=msyvpn.local" \
        -keyout /tmp/_k.pem -out /tmp/_c.pem >/dev/null 2>&1
    cat /tmp/_c.pem /tmp/_k.pem > "$CERT_PEM"
    chmod 600 "$CERT_PEM"
    rm -f /tmp/_k.pem /tmp/_c.pem
}

# Escribe haproxy.cfg completo a partir de los puertos guardados
proxy_write_config() {
    proxy_gen_cert
    [[ -f "$PLAIN_FILE" ]] || echo "$DEF_PLAIN" > "$PLAIN_FILE"
    [[ -f "$TLS_FILE"   ]] || echo "$DEF_TLS"   > "$TLS_FILE"

    {
        cat <<'EOF'
global
    maxconn 20000
    log /dev/log local0
    tune.ssl.default-dh-param 2048

defaults
    mode tcp
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
    server ws 127.0.0.1:$WSPROXY_INTERNAL
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
    echo "$cur $pt" > "$file"
    proxy_write_config
    ok "Puerto $pt agregado ($kind)"
}

proxy_del_port() {
    local pt="$1" f
    for f in "$PLAIN_FILE" "$TLS_FILE"; do
        [[ -f "$f" ]] && echo "$(tr ' ' '\n' < "$f" | grep -vw "$pt" | xargs)" > "$f"
    done
    proxy_write_config
    ok "Puerto $pt eliminado"
}

proxy_set_status() {
    local msg="$1"
    echo "WSPROXY_STATUS=$msg" > "$BASE_DIR/wsproxy.env"
    svc_restart msyvpn-wsproxy
    ok "Status: $msg"
}

# Emitir certificado real Let's Encrypt para un dominio (opcional)
proxy_cert_real() {
    local dom="$1"
    [[ -z "$dom" ]] && { err "Dominio vacio"; return 1; }
    ensure_pkg socat
    if [[ ! -x /root/.acme.sh/acme.sh ]]; then
        curl -s https://get.acme.sh | sh -s email=admin@"$dom" >/dev/null 2>&1
    fi
    # acme necesita el 80 libre: HAProxy lo usa, asi que modo standalone en 8088
    /root/.acme.sh/acme.sh --issue -d "$dom" --standalone --httpport 8088 \
        --server letsencrypt >/dev/null 2>&1
    open_port 8088 tcp
    local d=/root/.acme.sh/${dom}_ecc
    [[ -d "$d" ]] || d=/root/.acme.sh/${dom}
    if [[ -s "$d/fullchain.cer" && -s "$d/${dom}.key" ]]; then
        cat "$d/fullchain.cer" "$d/${dom}.key" > "$CERT_PEM"
        chmod 600 "$CERT_PEM"
        proxy_write_config
        ok "Certificado real instalado para $dom"
    else
        err "No se pudo emitir el certificado (revisa DNS/puerto 80)"
    fi
}

proxy_status() {
    echo "Puertos plano : $(_plain_ports)"
    echo "Puertos TLS   : $(_tls_ports)"
    svc_active haproxy        && echo "HAProxy       : activo" || echo "HAProxy       : inactivo"
    svc_active msyvpn-wsproxy && echo "wsproxy       : activo" || echo "wsproxy       : inactivo"
    svc_active msyvpn-badvpn  && echo "BadVPN UDP    : activo" || echo "BadVPN UDP    : inactivo"
}

proxy_menu() {
    while true; do
        clear
        title "PROXY / SSL  (HAProxy + wsproxy)"
        proxy_status
        line
        echo "  1) Agregar puerto PLANO (sin TLS)"
        echo "  2) Agregar puerto TLS (SSL)"
        echo "  3) Eliminar puerto"
        echo "  4) Cambiar mensaje de status (101)"
        echo "  5) Certificado real Let's Encrypt (dominio)"
        echo "  6) Reiniciar proxy"
        echo "  0) Volver"
        line
        case "$(ask 'Opcion: ')" in
            1) proxy_add_port plain "$(ask 'Puerto plano: ')"; pause ;;
            2) proxy_add_port tls   "$(ask 'Puerto TLS: ')";   pause ;;
            3) proxy_del_port "$(ask 'Puerto a eliminar: ')";  pause ;;
            4) proxy_set_status "$(ask 'Nuevo status: ')";     pause ;;
            5) proxy_cert_real "$(ask 'Dominio: ')";           pause ;;
            6) proxy_write_config; svc_restart msyvpn-wsproxy; ok "Reiniciado"; pause ;;
            0) return ;;
        esac
    done
}
