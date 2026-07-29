#!/bin/bash
# monitor.sh - Monitor de conexiones online y pruebas de velocidad
# Todo se calcula con 1-2 llamadas a ps/ss: no impacta el rendimiento.
[[ -n "$BASE_DIR" ]] || source /etc/msyvpn/lib.sh

XR_PORTS="10086|10087|10088|10089|8388"
STATS_FILE="$DATA_DIR/stats.json"

# Lee un contador del archivo de stats del wsproxy (IPs reales unicas)
_stat() {
    [[ -s "$STATS_FILE" ]] || return 1
    # El archivo se reescribe cada 5s; si esta viejo, el proxy no corre
    [[ -n "$(find "$STATS_FILE" -mmin -1 2>/dev/null)" ]] || return 1
    grep -o "\"$1\": *[0-9]*" "$STATS_FILE" 2>/dev/null | grep -o '[0-9]*$' | head -1
}

# --- SSH (incluye SSL/WebSocket/SlowDNS: todos terminan en sshd) -----
# Un proceso sshd de sesion por cada conexion del usuario.
mon_ssh_list() {
    ps -eo user:32,args --no-headers 2>/dev/null | awk '
        $2 ~ /^sshd/ && $1 != "root" && $1 !~ /^sshd/ { c[$1]++ }
        END { for (u in c) printf "%-16s %d\n", u, c[u] }' | sort
}
mon_ssh() { mon_ssh_list | awk '{s+=$2} END{print s+0}'; }

# --- V2Ray/Xray -----------------------------------------------------
# Exacto: IPs reales unicas que el wsproxy tiene en rutas V2Ray.
# Un cliente abre muchas conexiones a la vez, por eso contar conexiones
# daba 20-25 con un solo usuario.
mon_v2ray() {
    local n; n=$(_stat v2ray_ips)
    if [[ -n "$n" ]]; then echo "$n"; return; fi
    # Respaldo: conexiones a los inbounds (aproximado)
    ss -tanH 2>/dev/null | awk '$1=="ESTAB"{print $4}' | grep -cE ":($XR_PORTS)\$"
}
mon_v2ray_conns() {
    local n; n=$(_stat v2ray_conns)
    [[ -n "$n" ]] && echo "$n" || echo "-"
}

# --- UDP Hysteria ---------------------------------------------------
# v2 expone /online (exacto). v1 no tiene API: se usa conntrack pero
# solo entradas ASSURED (trafico en ambos sentidos), asi no cuentan los
# paquetes sueltos de escaneos que caian en el rango de port-hopping.
mon_udp_v2() {
    local sec port
    sec=$(cat /etc/hysteria/apisecret 2>/dev/null) || return 1
    port=$(cat /etc/hysteria/apiport 2>/dev/null) || return 1
    [[ -z "$sec" || -z "$port" ]] && return 1
    local j; j=$(curl -s --max-time 3 -H "Authorization: $sec" \
        "http://127.0.0.1:$port/online" 2>/dev/null) || return 1
    [[ -z "$j" || "$j" == "{}" ]] && { echo 0; return 0; }
    echo "$j" | grep -o ':[0-9]*' | grep -o '[0-9]*' | awk '{s+=$1} END{print s+0}'
}

mon_udp() {
    local n
    n=$(mon_udp_v2) && [[ -n "$n" ]] && { echo "$n"; return; }
    command -v conntrack >/dev/null 2>&1 || { echo "-"; return; }
    local p1 p2 me
    p1=$(cat /etc/hysteria/port1 2>/dev/null || echo 36712)
    p2=$(cat /etc/hysteria/port2 2>/dev/null || echo 36713)
    me=$(get_ip)
    conntrack -L -p udp 2>/dev/null | awk -v re="($p1|$p2)" -v me="$me" '
        /ASSURED/ && ($0 ~ ("sport="re) || $0 ~ ("dport="re)) {
            if (match($0, /src=[0-9.]+/)) {
                ip = substr($0, RSTART+4, RLENGTH-4)
                if (ip != me && ip !~ /^127\./) seen[ip]=1
            }
        }
        END { n=0; for (i in seen) n++; print n }'
}

mon_show() {
    local s v u tot
    s=$(mon_ssh); v=$(mon_v2ray); u=$(mon_udp)
    tot=$(( s + v + ${u//-/0} ))
    clear
    title "MONITOR DE CONEXIONES"
    printf '  Usuarios SSH online    : %s\n' "$s"
    printf '  Usuarios V2Ray online  : %s\n' "$v"
    printf '  Usuarios UDP online    : %s\n' "$u"
    line
    printf '  TOTAL ONLINE           : %s\n' "$tot"
    line
    echo "  Detalle SSH por cuenta:"
    local det; det=$(mon_ssh_list)
    if [[ -n "$det" ]]; then
        echo "$det" | while read -r un c; do
            local lim; lim=$(awk -v u="$un" '$1==u{print $2}' "$USERS_DB" 2>/dev/null)
            printf '    %-16s %s%s\n' "$un" "$c" "${lim:+ / limite $lim}"
        done
    else
        echo "    (sin sesiones activas)"
    fi
    line
    echo "  SSH incluye SSL, WebSocket y SlowDNS."
    echo "  V2Ray cuenta usuarios (IPs), no conexiones: $(mon_v2ray_conns) conexiones abiertas."
    [[ "$u" == "-" ]] && echo "  UDP: instala 'conntrack' para contar (apt install conntrack)."
}

mon_live() {
    clear; title "MONITOR EN VIVO (Ctrl+C para salir)"
    local ifc; ifc=$(ip -4 route ls 2>/dev/null | awk '/default/{print $5; exit}')
    [[ -z "$ifc" ]] && { err "No se detecto la interfaz de red"; return; }
    local r1 t1 r2 t2 rx tx
    while true; do
        read -r r1 t1 < <(awk -v i="$ifc:" '$1==i{print $2, $10}' /proc/net/dev)
        sleep 1
        read -r r2 t2 < <(awk -v i="$ifc:" '$1==i{print $2, $10}' /proc/net/dev)
        rx=$(awk -v a="$r1" -v b="$r2" 'BEGIN{printf "%.2f",(b-a)*8/1000000}')
        tx=$(awk -v a="$t1" -v b="$t2" 'BEGIN{printf "%.2f",(b-a)*8/1000000}')
        printf '\r  %s   Bajada: %8s Mbps   Subida: %8s Mbps   |  SSH:%s V2:%s' \
            "$ifc" "$rx" "$tx" "$(mon_ssh)" "$(mon_v2ray)"
    done
}

# --- Test de velocidad de la VPS ------------------------------------
# Prueba varios servidores y solo acepta el que devuelva HTTP 200 con
# datos reales; asi no se reporta "0.00 Mbps" cuando lo que fallo fue
# la conexion (IPv6 roto, host bloqueado, DNS, etc.).
SPEED_URLS="
https://speed.cloudflare.com/__down?bytes=52428800
https://proof.ovh.net/files/50Mb.dat
https://ash-speed.hetzner.com/100MB.bin
http://speedtest.tele2.net/50MB.zip
https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
"

speed_test() {
    ensure_pkg curl
    clear; title "TEST DE VELOCIDAD DE LA VPS"

    # Diagnostico rapido de salida a internet
    if ! curl -4 -s --max-time 6 -o /dev/null https://1.1.1.1 2>/dev/null; then
        err "Sin salida HTTPS a internet (revisa DNS/firewall de la VPS)."
    fi

    echo "  Midiendo descarga..."
    echo ""
    local u code bps size mbps done=0
    for u in $SPEED_URLS; do
        read -r code bps size < <(curl -4 -L -o /dev/null -s \
            -w '%{http_code} %{speed_download} %{size_download}' \
            --max-time 20 "$u" 2>/dev/null)
        # Solo vale si respondio 200 y bajo al menos 2 MB
        if [[ "$code" == "200" ]] && awk -v s="${size:-0}" 'BEGIN{exit !(s>2000000)}'; then
            mbps=$(awk -v b="${bps:-0}" 'BEGIN{printf "%.2f", b*8/1000000}')
            printf '  Descarga : %s Mbps\n' "$mbps"
            printf '  Servidor : %s\n' "${u%%\?*}"
            printf '  Bajados  : %s MB\n' "$(awk -v s="$size" 'BEGIN{printf "%.1f", s/1048576}')"
            done=1; break
        fi
        printf '  (fallo %s -> http=%s)\n' "${u#*//}" "${code:-sin_respuesta}"
    done
    [[ $done -eq 0 ]] && err "Ningun servidor de prueba respondio."

    # Subida: se envia un archivo temporal de 10 MB (no /dev/zero infinito)
    local tmpf="/tmp/.msyspeed.$$"
    head -c 10485760 /dev/urandom > "$tmpf" 2>/dev/null
    local ucode ubps
    read -r ucode ubps < <(curl -4 -s -o /dev/null \
        -w '%{http_code} %{speed_upload}' --max-time 20 \
        -X POST --data-binary "@$tmpf" \
        "https://speed.cloudflare.com/__up" 2>/dev/null)
    rm -f "$tmpf"
    if [[ "$ucode" == "200" ]] && awk -v b="${ubps:-0}" 'BEGIN{exit !(b>0)}'; then
        printf '  Subida   : %s Mbps\n' "$(awk -v b="$ubps" 'BEGIN{printf "%.2f", b*8/1000000}')"
    else
        printf '  Subida   : no disponible\n'
    fi

    line
    echo "  Latencia (ping a 1.1.1.1):"
    ping -c 3 -W 2 1.1.1.1 2>/dev/null | tail -1 || echo "  (ping no disponible)"
}

mon_menu() {
    while true; do
        clear
        title "MONITOR Y VELOCIDAD"
        echo "  1) Ver usuarios online"
        echo "  2) Monitor en vivo (ancho de banda)"
        echo "  3) Test de velocidad (speedtest)"
        echo "  0) Volver"
        line
        case "$(ask 'Opcion: ')" in
            1) mon_show; pause ;;
            2) mon_live ;;
            3) speed_test; pause ;;
            0) return ;;
        esac
    done
}
