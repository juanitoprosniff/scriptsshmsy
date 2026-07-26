#!/bin/bash
# monitor.sh - Monitor de conexiones online y pruebas de velocidad
# Todo se calcula con 1-2 llamadas a ps/ss: no impacta el rendimiento.
[[ -n "$BASE_DIR" ]] || source /etc/msyvpn/lib.sh

XR_PORTS="10086|10087|10088|10089|8388"

# --- SSH (incluye SSL/WebSocket/SlowDNS: todos terminan en sshd) -----
# Un proceso sshd de sesion por cada conexion del usuario.
mon_ssh_list() {
    ps -eo user:32,args --no-headers 2>/dev/null | awk '
        $2 ~ /^sshd/ && $1 != "root" && $1 !~ /^sshd/ { c[$1]++ }
        END { for (u in c) printf "%-16s %d\n", u, c[u] }' | sort
}
mon_ssh() { mon_ssh_list | awk '{s+=$2} END{print s+0}'; }

# --- V2Ray/Xray: conexiones establecidas a los inbounds internos ----
mon_v2ray() {
    ss -tanH 2>/dev/null | awk '$1=="ESTAB"{print $4}' \
        | grep -cE ":($XR_PORTS)\$"
}

# --- UDP Hysteria: IPs unicas con sesion UDP hacia los puertos ------
mon_udp() {
    local p1 p2
    p1=$(cat /etc/hysteria/port1 2>/dev/null || echo 36712)
    p2=$(cat /etc/hysteria/port2 2>/dev/null || echo 36713)
    if ! command -v conntrack >/dev/null 2>&1; then echo "-"; return; fi
    conntrack -L -p udp 2>/dev/null | awk -v re="($p1|$p2)" '
        $0 ~ ("sport="re) || $0 ~ ("dport="re) {
            if (match($0, /src=[0-9.]+/)) {
                ip = substr($0, RSTART+4, RLENGTH-4); seen[ip]=1
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
speed_test() {
    ensure_pkg curl
    clear; title "TEST DE VELOCIDAD DE LA VPS"
    echo "  Midiendo... (unos 30 segundos)"
    echo ""
    local url="https://speed.cloudflare.com/__down?bytes=100000000"
    local bps mbps
    bps=$(curl -o /dev/null -s -w '%{speed_download}' --max-time 30 "$url" 2>/dev/null)
    mbps=$(awk -v b="${bps:-0}" 'BEGIN{printf "%.2f", b*8/1000000}')
    printf '  Descarga : %s Mbps\n' "$mbps"

    local uurl="https://speed.cloudflare.com/__up"
    local ubps umbps
    ubps=$(curl -o /dev/null -s -w '%{speed_upload}' --max-time 30 \
        -X POST --data-binary "@/dev/zero" -H 'Content-Type: application/octet-stream' \
        --max-filesize 1 "$uurl" 2>/dev/null)
    if [[ -n "$ubps" && "$ubps" != "0" && "$ubps" != "0.000" ]]; then
        umbps=$(awk -v b="$ubps" 'BEGIN{printf "%.2f", b*8/1000000}')
        printf '  Subida   : %s Mbps\n' "$umbps"
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
