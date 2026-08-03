#!/bin/bash
# monitor.sh - Monitor de conexiones online y pruebas de velocidad
# Todo se calcula con 1-2 llamadas a ps/ss: no impacta el rendimiento.
[[ -n "$BASE_DIR" ]] || source /etc/msyvpn/lib.sh

XR_PORTS="10086|10087|10088|10089|8388"
# El wsproxy corre en varios procesos y cada uno escribe su archivo
# "stats.N" con lineas "<categoria> <ip> <conexiones>". Se juntan todos
# y se cuentan IPs unicas, para no duplicar entre procesos.
_stats_cat() {
    find "$DATA_DIR" -maxdepth 1 -name 'stats.[0-9]*' -mmin -1 2>/dev/null \
        | while read -r f; do cat "$f" 2>/dev/null; done
}
# _stat <categoria> <ips|conns>
_stat() {
    local out
    if [[ "$2" == ips ]]; then
        out=$(_stats_cat | awk -v c="$1" '$1==c{print $2}' | sort -u | wc -l)
    else
        out=$(_stats_cat | awk -v c="$1" '$1==c{s+=$3} END{print s+0}')
    fi
    [[ -z "$(_stats_cat)" ]] && return 1
    echo "$out"
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
    local n; n=$(_stat v2ray ips)
    if [[ -n "$n" ]]; then echo "$n"; return; fi
    # Respaldo: conexiones a los inbounds (aproximado)
    ss -tanH 2>/dev/null | awk '$1=="ESTAB"{print $4}' | grep -cE ":($XR_PORTS)\$"
}
mon_v2ray_conns() {
    local n; n=$(_stat v2ray conns)
    [[ -n "$n" ]] && echo "$n" || echo "-"
}

# --- UDP Hysteria (v1 + v2) -----------------------------------------
# Cada version se cuenta por separado y con su propio respaldo, para que
# si a una le falla su API la otra siga apareciendo (antes, si v2
# respondia, v1 nunca llegaba al metodo alternativo).

# Cuenta IPs unicas de clientes en conntrack para un puerto UDP dado.
_udp_conntrack() {
    local port="$1" me; me=$(get_ip)
    command -v conntrack >/dev/null 2>&1 || { echo ""; return 1; }
    conntrack -L -p udp 2>/dev/null | awk -v p="$port" -v me="$me" '
        ($0 ~ ("sport="p) || $0 ~ ("dport="p)) && /ASSURED/ {
            if (match($0, /src=[0-9.]+/)) {
                ip = substr($0, RSTART+4, RLENGTH-4)
                if (ip != me && ip !~ /^127\./) seen[ip]=1
            }
        }
        END { n=0; for (i in seen) n++; print n }'
}

# v2: API trafficStats /online (exacto). Respaldo: conntrack de su puerto.
mon_udp_v2() {
    svc_active msyvpn-hysteria2 || { echo "-"; return 1; }
    local sec port j
    sec=$(cat /etc/hysteria/apisecret 2>/dev/null); port=$(cat /etc/hysteria/apiport 2>/dev/null)
    if [[ -n "$sec" && -n "$port" ]]; then
        j=$(curl -s --max-time 3 -H "Authorization: $sec" \
            "http://127.0.0.1:$port/online" 2>/dev/null)
        if [[ -n "$j" ]]; then
            [[ "$j" == "{}" ]] && { echo 0; return 0; }
            echo "$j" | grep -o ':[0-9]*' | grep -o '[0-9]*' | awk '{s+=$1} END{print s+0}'
            return 0
        fi
    fi
    _udp_conntrack "$(cat /etc/hysteria/port2 2>/dev/null || echo 36713)"
}

# v1: metricas Prometheus (usuarios con conexiones activas). Respaldo:
# conntrack de su puerto, que es lo que hace que SIEMPRE aparezca aunque
# el binario v1.3.5 no exponga /metrics.
mon_udp_v1() {
    svc_active msyvpn-hysteria1 || { echo "-"; return 1; }
    local port m n
    port=$(cat /etc/hysteria/mport1 2>/dev/null || echo 27997)
    m=$(curl -s --max-time 2 "http://127.0.0.1:$port/metrics" 2>/dev/null)
    if [[ -n "$m" ]] && echo "$m" | grep -q 'hysteria_active_conns'; then
        echo "$m" | awk '
            /^hysteria_active_conns\{/ && $NF+0 > 0 {
                if (match($0, /auth="[^"]*"/))
                    seen[substr($0, RSTART+6, RLENGTH-7)] = 1
            }
            END { n=0; for (i in seen) n++; print n }'
        return 0
    fi
    _udp_conntrack "$(cat /etc/hysteria/port1 2>/dev/null || echo 36712)"
}

mon_udp() {
    local n1 n2 tot=0
    n1=$(mon_udp_v1); n2=$(mon_udp_v2)
    [[ "$n1" =~ ^[0-9]+$ ]] && tot=$((tot+n1))
    [[ "$n2" =~ ^[0-9]+$ ]] && tot=$((tot+n2))
    echo "$tot"
}

# Desglose por version para el panel
mon_udp_detalle() {
    local a b
    a=$(mon_udp_v1); b=$(mon_udp_v2)
    printf 'v1: %s   v2: %s' "${a:--}" "${b:--}"
}

# --- WireGuard: peers con handshake reciente (< 3 min) --------------
mon_wg() {
    command -v wg >/dev/null 2>&1 || { echo "-"; return; }
    svc_active wg-quick@wg0 || { echo 0; return; }
    local now; now=$(date +%s)
    wg show all latest-handshakes 2>/dev/null | \
        awk -v now="$now" '$3>0 && (now-$3)<180{n++} END{print n+0}'
}

# --- ShadowSocks: IPs unicas con conexion establecida al puerto -----
mon_ss() {
    svc_active msyvpn-ss || { echo "-"; return; }
    local port; port=$(jq -r '.server_port // 8388' /etc/shadowsocks-libev/config.json 2>/dev/null || echo 8388)
    ss -tanH 2>/dev/null | awk -v p=":$port" '
        $1=="ESTAB" && index($4,p) {
            ip=$5; sub(/:[0-9]+$/,"",ip); seen[ip]=1
        }
        END { n=0; for (i in seen) n++; print n }'
}

# Uso de memoria y swap
mon_swap() {
    if [[ "$(swapon --show --noheadings 2>/dev/null | wc -l)" -eq 0 ]]; then
        echo "sin swap"
    else
        free -m | awk -v c="$C_C" -v z="$C_0" \
            '/Swap:/{printf "%s%s%s MB usados de %s%s%s MB", c,$3,z, c,$2,z}'
    fi
}

# RAM detallada: total / usado / cache / disponible
mon_ram() {
    free -m | awk -v c="$C_C" -v z="$C_0" '/Mem:/{
        total=$2; used=$3; free=$4; cache=$6; avail=$7
        printf "%s%s%s MB total  ·  usando %s%s%s MB  ·  cache %s%s%s MB  ·  libre %s%s%s MB",
               c,total,z, c,used,z, c,cache,z, c,(avail?avail:free),z
    }'
}

# CPU: velocidad y % de uso por nucleo (muestreo de ~0.7s)
mon_cpu() {
    local mhz
    mhz=$(awk -F: '/cpu MHz/{printf "%d", $2; exit}' /proc/cpuinfo 2>/dev/null)
    [[ -z "$mhz" || "$mhz" == 0 ]] && \
        mhz=$(( $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo 0) / 1000 ))
    local ncpu; ncpu=$(nproc 2>/dev/null || echo 1)
    printf 'Nucleos: %s%s%s   Velocidad: %s%s MHz%s\n' "$C_C" "$ncpu" "$C_0" "$C_C" "${mhz:-?}" "$C_0"
    # Dos lecturas de /proc/stat; se comparan por nombre de nucleo, no por
    # posicion (la linea tiene numero variable de columnas segun el kernel).
    local fa="/tmp/.msycpu.a.$$" fb="/tmp/.msycpu.b.$$"
    grep '^cpu[0-9]' /proc/stat > "$fa"
    sleep 0.7
    grep '^cpu[0-9]' /proc/stat > "$fb"
    awk -v g="$C_G" -v y="$C_Y" -v r="$C_R" -v z="$C_0" '
    FNR==NR {
        tot=0; for (i=2;i<=NF;i++) tot+=$i
        totA[$1]=tot; idleA[$1]=$5+$6      # idle + iowait
        next
    }
    {
        tot=0; for (i=2;i<=NF;i++) tot+=$i
        dt=tot-totA[$1]; di=($5+$6)-idleA[$1]
        pct=(dt>0)? (100*(dt-di)/dt) : 0
        if (pct<0) pct=0; if (pct>100) pct=100
        col=(pct>=80)? r : (pct>=50)? y : g
        printf "  %-5s %s%5.1f%%%s ", $1, col, pct, z
        if (++n%4==0) printf "\n"
    }
    END { if (n%4!=0) printf "\n" }' "$fa" "$fb"
    rm -f "$fa" "$fb"
}

mon_show() {
    local s v u tot
    s=$(mon_ssh); v=$(mon_v2ray); u=$(mon_udp)
    tot=$(( s + v + ${u//-/0} ))
    clear
    title "MONITOR DE CONEXIONES"
    printf '  Usuarios SSH online    : %s\n' "$(num "$s")"
    printf '  Usuarios V2Ray online  : %s\n' "$(num "$v")"
    printf '  Usuarios UDP online    : %s   (%s)\n' "$(num "$u")" "$(mon_udp_detalle)"
    printf '  ShadowSocks online     : %s\n' "$(num "$(mon_ss)")"
    printf '  WireGuard online       : %s\n' "$(num "$(mon_wg)")"
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
    printf '  RAM  : %s\n' "$(free -m | awk '/Mem:/{printf "%s/%s MB", $3, $2}')"
    printf '  Swap : %s\n' "$(mon_swap)"
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

# --- Geolocalizacion de salida --------------------------------------
# Consulta como te ve internet por IPv4 y por IPv6. Sirve para saber
# que pais reporta cada familia de direcciones.
_geo_of() {
    local fam="$1" j
    j=$(curl -s "$fam" --max-time 8 https://ifconfig.co/json 2>/dev/null)
    [[ -z "$j" ]] && j=$(curl -s "$fam" --max-time 8 https://ipinfo.io/json 2>/dev/null)
    [[ -z "$j" ]] && { echo "sin respuesta"; return; }
    local ip pais ciudad
    ip=$(echo "$j"     | grep -o '"ip"[^,]*'      | head -1 | cut -d'"' -f4)
    pais=$(echo "$j"   | grep -o '"country[^,]*'  | head -1 | cut -d'"' -f4)
    ciudad=$(echo "$j" | grep -o '"city"[^,]*'    | head -1 | cut -d'"' -f4)
    echo "${ip:-?}  ->  ${pais:-?} ${ciudad:+/ $ciudad}"
}

geo_check() {
    clear; title "GEOLOCALIZACION DE SALIDA"
    echo "  Saliendo por IPv4:"
    echo "    $(_geo_of -4)"
    echo ""
    echo "  Saliendo por IPv6:"
    echo "    $(_geo_of -6)"
    line
    echo "  Por defecto (lo que decide el sistema):"
    echo "    $(_geo_of '')"
    line
    echo "  Un destino solo-IPv4 obliga a salir por IPv4: en ese caso"
    echo "  se ve el pais de tu IPv4 aunque prefieras IPv6."
    echo "  Para que un protocolo salga por IPv6, la app debe enviar el"
    echo "  DOMINIO (DNS remoto), no una IP ya resuelta."
}

mon_menu() {
    while true; do
        clear
        title "MONITOR Y VELOCIDAD"
        echo "  1) Ver usuarios online"
        echo "  2) Monitor en vivo (ancho de banda)"
        echo "  3) Test de velocidad (speedtest)"
        echo "  4) Geolocalizacion de salida (IPv4 / IPv6)"
        echo "  0) Volver"
        line
        case "$(ask 'Opcion: ')" in
            1) mon_show; pause ;;
            2) mon_live ;;
            3) speed_test; pause ;;
            4) geo_check; pause ;;
            0) return ;;
        esac
    done
}
