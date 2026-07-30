#!/bin/bash
# exitvpn.sh - Salida remota (doble VPN)
# Envia el trafico de los usuarios a otro servidor (por ejemplo en
# Austria) usando un outbound VLESS/Reality de Xray. Asi la
# geolocalizacion es la del nodo remoto en TODOS los protocolos que
# pasan por Xray, sin depender de la IP de esta VPS.
[[ -n "$BASE_DIR" ]] || source /etc/msyvpn/lib.sh

EX_URI="$DATA_DIR/exit.uri"      # URI vless:// del nodo remoto
EX_ON="$DATA_DIR/exit.on"        # 1 = activo

ex_active() { [[ "$(cat "$EX_ON" 2>/dev/null)" == "1" ]]; }

# Descompone una URI vless:// en las variables EXV_*
# Formato: vless://uuid@host:puerto?clave=valor&...#nombre
ex_parse() {
    local uri="$1"
    [[ "$uri" == vless://* ]] || { err "Solo se admiten URIs vless://"; return 1; }
    local body="${uri#vless://}"; body="${body%%#*}"
    local cred="${body%%\?*}" query=""
    [[ "$body" == *\?* ]] && query="${body#*\?}"
    EXV_ID="${cred%%@*}"
    local hostport="${cred#*@}"
    EXV_HOST="${hostport%:*}"; EXV_PORT="${hostport##*:}"
    [[ -z "$EXV_ID" || -z "$EXV_HOST" || -z "$EXV_PORT" ]] && { err "URI incompleta"; return 1; }
    # Valores por defecto y luego los parametros de la query
    EXV_NET=tcp; EXV_SEC=none; EXV_SNI=""; EXV_PATH=""; EXV_HOSTH=""
    EXV_PBK=""; EXV_SID=""; EXV_FLOW=""; EXV_FP=chrome
    local kv k v
    local IFS='&'
    for kv in $query; do
        k="${kv%%=*}"; v="${kv#*=}"
        v=$(printf '%b' "${v//%/\\x}")     # decodificar %2F etc.
        case "$k" in
            type)     EXV_NET="$v" ;;
            security) EXV_SEC="$v" ;;
            sni)      EXV_SNI="$v" ;;
            path)     EXV_PATH="$v" ;;
            host)     EXV_HOSTH="$v" ;;
            pbk)      EXV_PBK="$v" ;;
            sid)      EXV_SID="$v" ;;
            flow)     EXV_FLOW="$v" ;;
            fp)       EXV_FP="$v" ;;
        esac
    done
    [[ -z "$EXV_SNI" ]] && EXV_SNI="$EXV_HOSTH"
    [[ -z "$EXV_SNI" ]] && EXV_SNI="$EXV_HOST"
    return 0
}

# Genera el JSON del outbound remoto (lo usa v2ray.sh al construir)
ex_outbound_json() {
    ex_active || return 1
    [[ -s "$EX_URI" ]] || return 1
    ex_parse "$(cat "$EX_URI")" || return 1

    local stream user
    user=$(printf '{"id":"%s","encryption":"none"%s}' "$EXV_ID" \
        "$([[ -n "$EXV_FLOW" ]] && printf ',"flow":"%s"' "$EXV_FLOW")")

    if [[ "$EXV_SEC" == reality ]]; then
        stream=$(printf '"streamSettings":{"network":"%s","security":"reality","realitySettings":{"serverName":"%s","fingerprint":"%s","publicKey":"%s","shortId":"%s"}}' \
            "$EXV_NET" "$EXV_SNI" "$EXV_FP" "$EXV_PBK" "$EXV_SID")
    elif [[ "$EXV_SEC" == tls ]]; then
        stream=$(printf '"streamSettings":{"network":"%s","security":"tls","tlsSettings":{"serverName":"%s","allowInsecure":true}%s}' \
            "$EXV_NET" "$EXV_SNI" \
            "$([[ "$EXV_NET" == ws ]] && printf ',"wsSettings":{"path":"%s","headers":{"Host":"%s"}}' "$EXV_PATH" "$EXV_HOSTH")")
    else
        stream=$(printf '"streamSettings":{"network":"%s"%s}' "$EXV_NET" \
            "$([[ "$EXV_NET" == ws ]] && printf ',"wsSettings":{"path":"%s","headers":{"Host":"%s"}}' "$EXV_PATH" "$EXV_HOSTH")")
    fi

    printf '{"tag":"exit","protocol":"vless","settings":{"vnext":[{"address":"%s","port":%s,"users":[%s]}]},%s}' \
        "$EXV_HOST" "$EXV_PORT" "$user" "$stream"
}

ex_set() {
    local uri; uri=$(ask 'Pega la URI vless:// del nodo remoto: ')
    uri=$(echo "$uri" | xargs)
    [[ -z "$uri" ]] && return
    ex_parse "$uri" || { sleep 2; return 1; }
    echo "$uri" > "$EX_URI"; chmod 600 "$EX_URI"
    ok "Nodo remoto guardado: $EXV_HOST:$EXV_PORT ($EXV_SEC/$EXV_NET)"
}

ex_on() {
    [[ -s "$EX_URI" ]] || { err "Primero configura el nodo remoto (opcion 1)"; return 1; }
    xr_installed || { err "Requiere Xray instalado"; return 1; }
    echo 1 > "$EX_ON"
    if ! v2_rebuild; then
        echo 0 > "$EX_ON"; v2_rebuild; svc_restart xray
        err "Config invalida — revisa la URI. Salida remota NO activada"
        return 1
    fi
    svc_restart xray; sleep 2
    if ! svc_active xray; then
        echo 0 > "$EX_ON"; v2_rebuild; svc_restart xray
        err "Xray no arranco — se revirtio"; return 1
    fi
    ok "Salida remota ACTIVA — el trafico sale por $EXV_HOST"
    info "Comprueba con: Monitor -> Geolocalizacion de salida"
}

ex_off() {
    echo 0 > "$EX_ON"
    v2_rebuild && svc_restart xray
    ok "Salida remota desactivada (se sale por esta VPS)"
}

ex_status() {
    if ex_active && [[ -s "$EX_URI" ]]; then
        ex_parse "$(cat "$EX_URI")" 2>/dev/null && echo "activa -> $EXV_HOST"
    else
        echo "inactiva"
    fi
}

ex_menu() {
    while true; do
        clear
        title "SALIDA REMOTA (doble VPN)"
        echo "  Estado: $(ex_status)"
        line
        echo "  Manda el trafico a otro servidor tuyo. La geolocalizacion"
        echo "  pasa a ser la de ese nodo en todos los protocolos que van"
        echo "  por Xray (V2Ray y, si esta activa, la salida IPv6 de SSH)."
        line
        echo "  1) Configurar nodo remoto (URI vless://)"
        echo "  2) Activar salida remota"
        echo "  3) Desactivar"
        echo "  0) Volver"
        line
        case "$(ask 'Opcion: ')" in
            1) ex_set; pause ;;
            2) ex_on;  pause ;;
            3) ex_off; pause ;;
            0) return ;;
        esac
    done
}
