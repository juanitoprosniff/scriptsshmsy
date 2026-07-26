#!/bin/bash
# v2ray.sh - Motor Xray (VLESS por defecto + protocolos opcionales)
# VLESS-WS es automatico. Opcionales: VMess, Trojan, Shadowsocks, Reality, xhttp.
# WS/xhttp pasan por wsproxy + HAProxy(TLS). SS y Reality usan su propio puerto.
[[ -n "$BASE_DIR" ]] || source /etc/msyvpn/lib.sh

XR_CFG="/usr/local/etc/xray/config.json"
XR_DB="$DATA_DIR/xray.db"          # uuid|alias
XR_UUID="$DATA_DIR/xray.uuid"      # uuid por defecto persistente
XR_ON="$DATA_DIR/xray.on"          # protocolos activos (vless siempre)
XR_SS="$DATA_DIR/xray.sspass"
XR_RPORT="$DATA_DIR/xray.rport"
XR_RKEYS="$DATA_DIR/xray.reality"  # privkey|pubkey|shortid

V2_VLESS_PORT=10086; V2_VLESS_PATH="/vless"
V2_VMESS_PORT=10087; V2_VMESS_PATH="/vmess"
V2_TROJAN_PORT=10088; V2_TROJAN_PATH="/trojan-ws"
V2_XH_PORT=10089;     V2_XH_PATH="/xh"
V2_SS_PORT=8388
V2_REALITY_DEST="www.microsoft.com"

xr_bin()       { command -v xray 2>/dev/null || { [[ -x /usr/local/bin/xray ]] && echo /usr/local/bin/xray; }; }
xr_installed() { [[ -n "$(xr_bin)" ]]; }
v2_installed() { xr_installed; }          # compat menu
v2_uuid()      { cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c 'import uuid;print(uuid.uuid4())'; }
v2_valid()     { [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
xr_is_on()     { grep -qw "$1" "$XR_ON" 2>/dev/null; }
xr_enable()    { xr_is_on "$1" || echo "$1" >> "$XR_ON"; }
xr_disable()   { [[ -f "$XR_ON" ]] && sed -i "/^$1$/d" "$XR_ON"; }

xr_def_uuid() {
    if [[ -s "$XR_UUID" ]]; then head -1 "$XR_UUID"; return; fi
    local u; u=$(v2_uuid); echo "$u" > "$XR_UUID"; echo "$u"
}

# ---- Genera y valida config.json (revierte si es invalida) ----------
v2_rebuild() {
    mkdir -p "$(dirname "$XR_CFG")" "$DATA_DIR" /var/log/xray
    touch "$XR_DB"
    [[ -f "$XR_ON" ]] || echo "vless" > "$XR_ON"
    local du; du=$(xr_def_uuid)
    grep -q "^$du|" "$XR_DB" 2>/dev/null || echo "$du|default" >> "$XR_DB"

    local vless="" vmess="" trojan="" fv=1 fm=1 ft=1 u a
    while IFS='|' read -r u a; do
        v2_valid "$u" || continue; [[ -z "$a" ]] && a="$u"
        [[ $fv -eq 1 ]] && fv=0 || vless+=","
        vless+=$(printf '{"id":"%s","email":"%s"}' "$u" "$a")
        [[ $fm -eq 1 ]] && fm=0 || vmess+=","
        vmess+=$(printf '{"id":"%s","email":"%s"}' "$u" "$a")
        [[ $ft -eq 1 ]] && ft=0 || trojan+=","
        trojan+=$(printf '{"password":"%s","email":"%s"}' "$u" "$a")
    done < "$XR_DB"

    local inb
    inb=$(printf '{"listen":"127.0.0.1","port":%s,"protocol":"vless","settings":{"clients":[%s],"decryption":"none"},"streamSettings":{"network":"ws","wsSettings":{"path":"%s"}},"sniffing":{"enabled":true,"destOverride":["http","tls"]}}' "$V2_VLESS_PORT" "$vless" "$V2_VLESS_PATH")

    if xr_is_on vmess; then
        inb+=$(printf ',{"listen":"127.0.0.1","port":%s,"protocol":"vmess","settings":{"clients":[%s]},"streamSettings":{"network":"ws","wsSettings":{"path":"%s"}}}' "$V2_VMESS_PORT" "$vmess" "$V2_VMESS_PATH")
    fi
    if xr_is_on trojan; then
        inb+=$(printf ',{"listen":"127.0.0.1","port":%s,"protocol":"trojan","settings":{"clients":[%s]},"streamSettings":{"network":"ws","wsSettings":{"path":"%s"}}}' "$V2_TROJAN_PORT" "$trojan" "$V2_TROJAN_PATH")
    fi
    if xr_is_on xhttp; then
        inb+=$(printf ',{"listen":"127.0.0.1","port":%s,"protocol":"vless","settings":{"clients":[%s],"decryption":"none"},"streamSettings":{"network":"xhttp","xhttpSettings":{"path":"%s"}}}' "$V2_XH_PORT" "$vless" "$V2_XH_PATH")
    fi
    if xr_is_on ss; then
        local sp; sp=$(cat "$XR_SS" 2>/dev/null || { openssl rand -hex 8 | tee "$XR_SS"; })
        inb+=$(printf ',{"listen":"0.0.0.0","port":%s,"protocol":"shadowsocks","settings":{"method":"aes-128-gcm","password":"%s","network":"tcp,udp"}}' "$V2_SS_PORT" "$sp")
    fi
    if xr_is_on reality; then
        xr_reality_keys
        local rp pk sid rport
        pk=$(cut -d'|' -f1 "$XR_RKEYS"); sid=$(cut -d'|' -f3 "$XR_RKEYS")
        rport=$(cat "$XR_RPORT" 2>/dev/null || echo 2087)
        local rcl="" fr=1
        while IFS='|' read -r u a; do v2_valid "$u" || continue
            [[ $fr -eq 1 ]] && fr=0 || rcl+=","
            rcl+=$(printf '{"id":"%s","flow":"xtls-rprx-vision","email":"%s"}' "$u" "$a")
        done < "$XR_DB"
        inb+=$(printf ',{"listen":"0.0.0.0","port":%s,"protocol":"vless","settings":{"clients":[%s],"decryption":"none"},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"show":false,"dest":"%s:443","serverNames":["%s"],"privateKey":"%s","shortIds":["%s"]}}}' "$rport" "$rcl" "$V2_REALITY_DEST" "$V2_REALITY_DEST" "$pk" "$sid")
    fi

    # El archivo de prueba DEBE terminar en .json (Xray detecta el formato
    # por la extension). Se prueba en /tmp para no ensuciar el confdir.
    local tmp="/tmp/xray_msy_$$.json"
    printf '{"log":{"loglevel":"warning"},"inbounds":[%s],"outbounds":[{"protocol":"freedom"}]}' "$inb" > "$tmp"

    if xr_installed; then
        if ! ( "$(xr_bin)" test -c "$tmp" >/tmp/xr.log 2>&1 || "$(xr_bin)" run -test -c "$tmp" >/tmp/xr.log 2>&1 ); then
            err "Config Xray invalida — se mantiene la anterior:"; tail -3 /tmp/xr.log
            rm -f "$tmp"; return 1
        fi
    fi
    mkdir -p "$(dirname "$XR_CFG")"
    mv -f "$tmp" "$XR_CFG"
    v2_write_routes
    return 0
}

xr_reality_keys() {
    [[ -s "$XR_RKEYS" ]] && return
    local out pk pub sid
    out=$("$(xr_bin)" x25519 2>/dev/null)
    pk=$(echo "$out"  | awk -F': ' '/Private/{print $2}' | tr -d ' ')
    pub=$(echo "$out" | awk -F': ' '/Public/{print $2}'  | tr -d ' ')
    sid=$(openssl rand -hex 4 2>/dev/null || echo 1a2b3c4d)
    echo "$pk|$pub|$sid" > "$XR_RKEYS"
}

# Rutas para el wsproxy (solo protocolos basados en WS/xhttp)
v2_write_routes() {
    { echo "V2RAY_ENABLED=yes"
      echo "ROUTE=$V2_VLESS_PATH:127.0.0.1:$V2_VLESS_PORT"
      xr_is_on vmess  && echo "ROUTE=$V2_VMESS_PATH:127.0.0.1:$V2_VMESS_PORT"
      xr_is_on trojan && echo "ROUTE=$V2_TROJAN_PATH:127.0.0.1:$V2_TROJAN_PORT"
      xr_is_on xhttp  && echo "ROUTE=$V2_XH_PATH:127.0.0.1:$V2_XH_PORT"
    } > "$ROUTES_CONF"
}

v2_install() {
    # Migracion: quitar v2ray v2fly viejo si existiera
    systemctl disable --now v2ray >/dev/null 2>&1
    if ! xr_installed; then
        info "Instalando Xray-core oficial..."
        ensure_pkg curl unzip
        bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
    fi
    xr_installed || { err "Fallo la instalacion de Xray"; return 1; }
    echo "vless" > "$XR_ON"
    v2_rebuild || return 1
    systemctl enable xray >/dev/null 2>&1
    svc_restart xray; svc_restart msyvpn-wsproxy
    sleep 1
    svc_active xray && ok "Xray activo (VLESS por defecto)" || err "Xray no arranco: journalctl -u xray"
}

# ---- Usuarios --------------------------------------------------------
v2_add_user() {
    xr_installed || { err "Instala primero (opcion 1)"; return; }
    local alias uuid
    alias=$(ask 'Alias/nombre: '); alias=$(echo "$alias" | tr -cd '[:alnum:]_-' | head -c 24)
    [[ -z "$alias" ]] && alias="user$(date +%s)"
    if [[ "$(ask 'UUID manual? [s/N]: ')" =~ ^[sS]$ ]]; then
        uuid=$(ask 'UUID: '); v2_valid "$uuid" || { err "UUID invalido"; return; }
    else
        uuid=$(v2_uuid)
    fi
    echo "$uuid|$alias" >> "$XR_DB"
    v2_rebuild && svc_restart xray
    ok "Usuario creado"; v2_show_one "$uuid" "$alias"
}

v2_del_user() {
    [[ -s "$XR_DB" ]] || { err "Sin usuarios"; return; }
    nl -w2 -s') ' "$XR_DB"
    local n; n=$(ask 'Linea a eliminar: '); [[ "$n" =~ ^[0-9]+$ ]] || return
    sed -i "${n}d" "$XR_DB"
    v2_rebuild && svc_restart xray
    ok "Eliminado"
}

v2_show_one() {
    local u="$1" a="$2" ip; ip=$(get_ip)
    local dom; dom=$(cat "$DATA_DIR/domain" 2>/dev/null); local addr="${dom:-$ip}"
    line
    echo "Usuario: $a    UUID: $u"
    echo "Path: $V2_VLESS_PATH   Host/SNI: $addr"
    echo "VLESS TLS (443):"
    echo "vless://$u@$addr:443?type=ws&encryption=none&security=tls&sni=$addr&host=$addr&path=%2Fvless&allowInsecure=1#$a-tls"
    echo "VLESS HTTP (80):"
    echo "vless://$u@$addr:80?type=ws&encryption=none&security=none&host=$addr&path=%2Fvless#$a-http"
    if xr_is_on reality; then
        local pub sid rport; pub=$(cut -d'|' -f2 "$XR_RKEYS"); sid=$(cut -d'|' -f3 "$XR_RKEYS")
        rport=$(cat "$XR_RPORT" 2>/dev/null || echo 2087)
        echo "VLESS Reality ($rport):"
        echo "vless://$u@$ip:$rport?type=tcp&encryption=none&security=reality&flow=xtls-rprx-vision&sni=$V2_REALITY_DEST&pbk=$pub&sid=$sid&fp=chrome#$a-reality"
    fi
    line
}

v2_uris() {
    [[ -s "$XR_DB" ]] || { err "Sin usuarios"; return; }
    local u a; while IFS='|' read -r u a; do v2_valid "$u" && v2_show_one "$u" "$a"; done < "$XR_DB"
}

# ---- Protocolos opcionales ------------------------------------------
v2_toggle() {
    local proto="$1"
    if xr_is_on "$proto"; then
        xr_disable "$proto"; v2_rebuild && svc_restart xray && svc_restart msyvpn-wsproxy
        ok "$proto desactivado"
    else
        [[ "$proto" == reality ]] && { local p; p=$(ask 'Puerto Reality [2087]: '); [[ "$p" =~ ^[0-9]+$ ]] || p=2087; echo "$p" > "$XR_RPORT"; open_port "$p" tcp; }
        [[ "$proto" == ss ]] && open_port "$V2_SS_PORT" tcp
        xr_enable "$proto"
        if v2_rebuild; then svc_restart xray; svc_restart msyvpn-wsproxy; ok "$proto activado"; else xr_disable "$proto"; fi
    fi
}

v2_protocols_menu() {
    while true; do
        clear; title "PROTOCOLOS XRAY (VLESS siempre activo)"
        for p in vmess trojan shadowsocks:ss reality xhttp; do
            local name="${p%%:*}" key="${p##*:}"
            xr_is_on "$key" && echo "  [ON ] $name" || echo "  [off] $name"
        done
        line
        echo "  1) VMess    2) Trojan    3) Shadowsocks"
        echo "  4) Reality  5) xhttp     0) Volver"
        line
        case "$(ask 'Activar/desactivar: ')" in
            1) v2_toggle vmess;  pause ;;
            2) v2_toggle trojan; pause ;;
            3) v2_toggle ss;     pause ;;
            4) v2_toggle reality;pause ;;
            5) v2_toggle xhttp;  pause ;;
            0) return ;;
        esac
    done
}

v2_uninstall() {
    systemctl disable --now xray >/dev/null 2>&1
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge >/dev/null 2>&1
    echo "V2RAY_ENABLED=no" > "$ROUTES_CONF"; svc_restart msyvpn-wsproxy
    ok "Xray desinstalado"
}

# ---- Dominio + verificacion de DNS ----------------------------------
# Comprueba que el dominio apunte a esta VPS (o a Cloudflare).
v2_check_domain() {
    local dom="$1" ip dns; ip=$(get_ip)
    dns=$(getent hosts "$dom" 2>/dev/null | awk '{print $1; exit}')
    [[ -z "$dns" ]] && dns=$(python3 -c "import socket;print(socket.gethostbyname('$dom'))" 2>/dev/null)
    if [[ -z "$dns" ]]; then
        err "El dominio $dom no resuelve todavia (revisa el DNS)."; return 1
    fi
    if [[ "$dns" == "$ip" ]]; then
        ok "Dominio $dom -> $dns  (coincide con esta VPS)"; return 0
    fi
    if [[ "$dns" =~ ^(104\.(1[6-9]|2[0-9]|3[01])\.|172\.(6[4-9]|[78][0-9]|9[0-5])\.|188\.114\.|162\.158\.|141\.101\.|173\.245\.) ]]; then
        info "Dominio $dom -> $dns  (IP de Cloudflare, proxy activo — normal)."; return 0
    fi
    err "Dominio $dom -> $dns  pero esta VPS es $ip (no coincide)."
    info "Corrige el registro A para que apunte a $ip, o usa Cloudflare."
    return 1
}

v2_set_domain() {
    local dom; dom=$(ask 'Dominio (Host/SNI): ')
    dom=$(echo "$dom" | tr 'A-Z' 'a-z' | xargs)
    [[ -z "$dom" ]] && return
    echo "$dom" > "$DATA_DIR/domain"
    v2_check_domain "$dom"
}

# Emite el certificado TLS real usando el dominio ya guardado/verificado.
v2_cert_tls() {
    local d; d=$(cat "$DATA_DIR/domain" 2>/dev/null)
    [[ -z "$d" ]] && { err "Primero fija el dominio (opcion 7)"; return; }
    v2_check_domain "$d" || { info "Corrige el DNS y reintenta."; return; }
    source "$BASE_DIR/proxy.sh"; proxy_cert_real "$d"
}

v2_menu() {
    while true; do
        clear; title "V2RAY / XRAY  (VLESS por defecto)"
        xr_installed && echo "Estado: $(svc_active xray && echo activo || echo inactivo)  ·  UUID def: $(xr_def_uuid)" \
                     || echo "Estado: no instalado"
        line
        echo "  1) Instalar / Activar (VLESS auto)"
        echo "  2) Crear usuario (UUID auto o manual)"
        echo "  3) Eliminar usuario"
        echo "  4) Ver URIs"
        echo "  5) Protocolos opcionales (VMess/Trojan/SS/Reality/xhttp)"
        echo "  6) Activar TLS real (dominio verificado)"
        echo "  7) Fijar/verificar dominio (Host/SNI)"
        echo "  8) Desinstalar"
        echo "  0) Volver"
        line
        case "$(ask 'Opcion: ')" in
            1) v2_install; pause ;;
            2) v2_add_user; pause ;;
            3) v2_del_user; pause ;;
            4) v2_uris; pause ;;
            5) v2_protocols_menu ;;
            6) v2_cert_tls; pause ;;
            7) v2_set_domain; pause ;;
            8) v2_uninstall; pause ;;
            0) return ;;
        esac
    done
}
