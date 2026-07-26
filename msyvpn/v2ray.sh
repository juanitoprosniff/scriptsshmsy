#!/bin/bash
# v2ray.sh - Modulo V2Ray (VLESS + VMess + Trojan sobre WebSocket)
# V2Ray escucha SOLO en 127.0.0.1. El wsproxy enruta /vless /vmess
# /trojan-ws hacia el. Sin stunnel ni nginx: HAProxy pone el TLS.
[[ -n "$BASE_DIR" ]] || source /etc/msyvpn/lib.sh

V2_DB="$DATA_DIR/v2ray.db"
V2_CFG="/usr/local/etc/v2ray/config.json"
V2_VLESS_PORT=10086; V2_VLESS_PATH="/vless"
V2_VMESS_PORT=10087; V2_VMESS_PATH="/vmess"
V2_TROJAN_PORT=10088; V2_TROJAN_PATH="/trojan-ws"

v2_bin()       { command -v v2ray 2>/dev/null || { [[ -x /usr/local/bin/v2ray ]] && echo /usr/local/bin/v2ray; }; }
v2_installed() { [[ -n "$(v2_bin)" ]]; }
v2_uuid()      { cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c 'import uuid;print(uuid.uuid4())'; }
v2_valid()     { [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }

# Genera config.json desde la base de usuarios (uuid|alias)
v2_rebuild() {
    mkdir -p "$(dirname "$V2_CFG")" /var/log/v2ray "$DATA_DIR"
    touch "$V2_DB"
    local vless="" vmess="" trojan="" fv=1 fm=1 ft=1 u a
    while IFS='|' read -r u a; do
        v2_valid "$u" || continue
        [[ -z "$a" ]] && a="$u"
        [[ $fv -eq 1 ]] && fv=0 || vless+=","
        vless+=$(printf '\n{"id":"%s","level":0,"email":"%s"}' "$u" "$a")
        [[ $fm -eq 1 ]] && fm=0 || vmess+=","
        vmess+=$(printf '\n{"id":"%s","alterId":0,"level":0,"email":"%s"}' "$u" "$a")
        [[ $ft -eq 1 ]] && ft=0 || trojan+=","
        trojan+=$(printf '\n{"password":"%s","level":0,"email":"%s"}' "$u" "$a")
    done < "$V2_DB"
    if [[ -z "$vless" ]]; then
        local d; d=$(v2_uuid); echo "$d|default" >> "$V2_DB"
        vless=$(printf '\n{"id":"%s","level":0,"email":"default"}' "$d")
        vmess=$(printf '\n{"id":"%s","alterId":0,"level":0,"email":"default"}' "$d")
        trojan=$(printf '\n{"password":"%s","level":0,"email":"default"}' "$d")
    fi
    cat > "$V2_CFG" <<JSON
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {"tag":"vless","listen":"127.0.0.1","port":$V2_VLESS_PORT,"protocol":"vless",
     "settings":{"clients":[$vless],"decryption":"none"},
     "streamSettings":{"network":"ws","wsSettings":{"path":"$V2_VLESS_PATH"}}},
    {"tag":"vmess","listen":"127.0.0.1","port":$V2_VMESS_PORT,"protocol":"vmess",
     "settings":{"clients":[$vmess]},
     "streamSettings":{"network":"ws","wsSettings":{"path":"$V2_VMESS_PATH"}}},
    {"tag":"trojan","listen":"127.0.0.1","port":$V2_TROJAN_PORT,"protocol":"trojan",
     "settings":{"clients":[$trojan]},
     "streamSettings":{"network":"ws","wsSettings":{"path":"$V2_TROJAN_PATH"}}}
  ],
  "outbounds": [{"protocol":"freedom"}]
}
JSON
}

# Escribe las rutas para que el wsproxy enrute hacia V2Ray
v2_write_routes() {
    cat > "$ROUTES_CONF" <<EOF
V2RAY_ENABLED=yes
ROUTE=$V2_VLESS_PATH:127.0.0.1:$V2_VLESS_PORT
ROUTE=$V2_VMESS_PATH:127.0.0.1:$V2_VMESS_PORT
ROUTE=$V2_TROJAN_PATH:127.0.0.1:$V2_TROJAN_PORT
EOF
}

v2_install() {
    if ! v2_installed; then
        info "Instalando V2Ray oficial..."
        ensure_pkg curl unzip
        bash <(curl -fsSL https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh) >/dev/null 2>&1
    fi
    v2_installed || { err "Fallo la instalacion de V2Ray"; return 1; }
    v2_rebuild
    v2_write_routes
    systemctl enable v2ray >/dev/null 2>&1
    svc_restart v2ray
    svc_restart msyvpn-wsproxy
    sleep 1
    svc_active v2ray && ok "V2Ray activo (VLESS/VMess/Trojan)" || err "V2Ray no arranco: journalctl -u v2ray"
}

v2_add_user() {
    v2_installed || { err "Instala V2Ray primero"; return; }
    local alias; alias=$(ask 'Alias/nombre: ')
    alias=$(echo "$alias" | tr -cd '[:alnum:]_-' | head -c 24)
    [[ -z "$alias" ]] && alias="user$(date +%s)"
    local u; u=$(v2_uuid)
    echo "$u|$alias" >> "$V2_DB"
    v2_rebuild; svc_restart v2ray
    ok "Usuario V2Ray creado"
    v2_show_one "$u" "$alias"
}

v2_del_user() {
    [[ -s "$V2_DB" ]] || { err "Sin usuarios"; return; }
    nl -w2 -s') ' "$V2_DB"
    local n; n=$(ask 'Linea a eliminar: ')
    [[ "$n" =~ ^[0-9]+$ ]] || return
    sed -i "${n}d" "$V2_DB"
    v2_rebuild; svc_restart v2ray
    ok "Eliminado"
}

v2_show_one() {
    local u="$1" a="$2" ip; ip=$(get_ip)
    local dom; dom=$(cat "$DATA_DIR/domain" 2>/dev/null)
    local addr="${dom:-$ip}"
    line
    echo "Usuario : $a"
    echo "UUID    : $u"
    echo "Path    : $V2_VLESS_PATH   Host/SNI: $addr"
    echo ""
    echo "VLESS TLS  (443):"
    echo "vless://$u@$addr:443?type=ws&encryption=none&security=tls&sni=$addr&host=$addr&path=%2Fvless&allowInsecure=1#$a-tls"
    echo ""
    echo "VLESS HTTP (80):"
    echo "vless://$u@$addr:80?type=ws&encryption=none&security=none&host=$addr&path=%2Fvless#$a-http"
    line
}

v2_uris() {
    [[ -s "$V2_DB" ]] || { err "Sin usuarios"; return; }
    local u a
    while IFS='|' read -r u a; do
        v2_valid "$u" && v2_show_one "$u" "$a"
    done < "$V2_DB"
}

v2_uninstall() {
    systemctl stop v2ray 2>/dev/null; systemctl disable v2ray 2>/dev/null
    bash <(curl -fsSL https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh) --remove >/dev/null 2>&1
    echo "V2RAY_ENABLED=no" > "$ROUTES_CONF"
    svc_restart msyvpn-wsproxy
    ok "V2Ray desinstalado"
}

v2_menu() {
    while true; do
        clear
        title "V2RAY  (VLESS / VMess / Trojan)"
        v2_installed && echo "Estado: $(svc_active v2ray && echo activo || echo instalado-inactivo)" \
                     || echo "Estado: no instalado"
        line
        echo "  1) Instalar / Activar V2Ray"
        echo "  2) Crear usuario"
        echo "  3) Eliminar usuario"
        echo "  4) Ver URIs de usuarios"
        echo "  5) Fijar dominio (Host/SNI)"
        echo "  6) Desinstalar V2Ray"
        echo "  0) Volver"
        line
        case "$(ask 'Opcion: ')" in
            1) v2_install; pause ;;
            2) v2_add_user; pause ;;
            3) v2_del_user; pause ;;
            4) v2_uris; pause ;;
            5) ask 'Dominio: ' > "$DATA_DIR/domain"; ok "Guardado"; pause ;;
            6) v2_uninstall; pause ;;
            0) return ;;
        esac
    done
}
