#!/bin/bash
# hysteria.sh - UDP Hysteria v1 y v2 (pueden estar activos a la vez)
# Cada version tiene su binario, puerto, obfs y servicio propios.
# Auth "usuario:contrasena" tomada de las cuentas del sistema.
[[ -n "$BASE_DIR" ]] || source /etc/msyvpn/lib.sh

HY_DIR="/etc/hysteria"
HY_CERT="$HY_DIR/server.crt"
HY_KEY="$HY_DIR/server.key"

# Puertos y rangos de port-hopping separados para que no choquen
hy_port() { local v; v=$(cat "$HY_DIR/port$1" 2>/dev/null); echo "${v:-$([[ $1 == 1 ]] && echo 36712 || echo 36713)}"; }
hy_obfs() { local v; v=$(cat "$HY_DIR/obfs$1" 2>/dev/null); echo "${v:-msyvpn}"; }
hy_hop()  { [[ "$1" == 1 ]] && echo "20000:40000" || echo "40001:60000"; }
hy_svc()  { echo "msyvpn-hysteria$1"; }
hy_bin()  { echo "/usr/local/bin/hysteria$1"; }

hy_installed() { [[ -x "$(hy_bin "$1")" ]]; }

# Lista "usuario:contrasena" de cuentas validas del sistema
hy_userlist() {
    local f u p
    for f in "$SENHA_DIR"/*; do
        [[ -f "$f" ]] || continue
        u=$(basename "$f"); p=$(tr -d '\n' < "$f")
        id "$u" >/dev/null 2>&1 || continue
        [[ -z "$u" || -z "$p" ]] && continue
        printf '%s:%s\n' "$u" "$p"
    done
}

hy_cert() {
    mkdir -p "$HY_DIR"
    [[ -s "$HY_CERT" && -s "$HY_KEY" ]] && return
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$HY_KEY" -out "$HY_CERT" -subj "/CN=$(get_ip)" >/dev/null 2>&1
    chmod 600 "$HY_KEY"
}

# ---- v1: config.json ------------------------------------------------
hy_write_v1() {
    local arr="" line first=1
    while IFS= read -r line; do
        [[ $first -eq 1 ]] && first=0 || arr+=","
        arr+="\"$line\""
    done < <(hy_userlist)
    [[ -z "$arr" ]] && arr='"test:1234msy"'
    cat > "$HY_DIR/config.json" <<JSON
{
  "server": "$(get_ip)",
  "listen": ":$(hy_port 1)",
  "protocol": "udp",
  "cert": "$HY_CERT",
  "key": "$HY_KEY",
  "up_mbps": 1000,
  "down_mbps": 1000,
  "disable_udp": false,
  "insecure": true,
  "obfs": "$(hy_obfs 1)",
  "resolve_preference": "$(prefer_ipv6 && echo 64 || echo 46)",
  "auth": { "mode": "passwords", "config": [$arr] }
}
JSON
}

# ---- v2: config.yaml ------------------------------------------------
hy_write_v2() {
    local up="" line
    while IFS= read -r line; do
        up+="    ${line%%:*}: \"${line#*:}\""$'\n'
    done < <(hy_userlist)
    [[ -z "$up" ]] && up='    test: "1234msy"'
    # API local de estadisticas: permite contar usuarios online exactos
    [[ -s "$HY_DIR/apisecret" ]] || openssl rand -hex 12 > "$HY_DIR/apisecret"
    [[ -s "$HY_DIR/apiport"   ]] || echo 27998 > "$HY_DIR/apiport"
    local asec aport
    asec=$(cat "$HY_DIR/apisecret"); aport=$(cat "$HY_DIR/apiport")
    cat > "$HY_DIR/config.yaml" <<YAML
listen: ":$(hy_port 2)"
trafficStats:
  listen: 127.0.0.1:$aport
  secret: $asec
tls:
  cert: $HY_CERT
  key: $HY_KEY
auth:
  type: userpass
  userpass:
$up
obfs:
  type: salamander
  salamander:
    password: $(hy_obfs 2)
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true
bandwidth:
  up: 1 gbps
  down: 1 gbps
outbounds:
  - name: salida
    type: direct
    direct:
      mode: $(prefer_ipv6 && echo 64 || echo 46)
YAML
}

hy_write_config() {
    hy_installed 1 && hy_write_v1
    hy_installed 2 && hy_write_v2
    return 0
}

hy_hopping() {
    local v="$1" ifc rng; rng=$(hy_hop "$v")
    ifc=$(ip -4 route ls 2>/dev/null | awk '/default/{print $5; exit}')
    [[ -z "$ifc" ]] && return
    iptables -t nat -C PREROUTING -i "$ifc" -p udp --dport "$rng" -j DNAT --to-destination ":$(hy_port "$v")" 2>/dev/null || \
        iptables -t nat -A PREROUTING -i "$ifc" -p udp --dport "$rng" -j DNAT --to-destination ":$(hy_port "$v")" 2>/dev/null
}

# hy_install <1|2>
hy_install() {
    local v="${1:-1}" a bin url exec
    ensure_pkg curl openssl
    a=$(arch); bin=$(hy_bin "$v"); mkdir -p "$HY_DIR"
    if [[ "$v" == 1 ]]; then
        url="https://github.com/apernet/hysteria/releases/download/v1.3.5/hysteria-linux-$a"
    else
        url="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-$a"
    fi
    if [[ ! -x "$bin" ]]; then
        info "Descargando Hysteria v$v ($a)..."
        curl -L -f -s "$url" -o "$bin" && chmod +x "$bin"
    fi
    [[ -x "$bin" ]] || { err "No se pudo descargar Hysteria v$v para $a"; return 1; }

    [[ -f "$HY_DIR/port$v" ]] || hy_port "$v" > "$HY_DIR/port$v"
    [[ -f "$HY_DIR/obfs$v" ]] || echo msyvpn > "$HY_DIR/obfs$v"
    hy_cert
    [[ "$v" == 1 ]] && hy_write_v1 || hy_write_v2

    if [[ "$v" == 1 ]]; then
        exec="$bin server --config $HY_DIR/config.json"
    else
        exec="$bin server -c $HY_DIR/config.yaml"
    fi
    # Script que reaplica el port-hopping (iptables se pierde al reiniciar)
    cat > "$HY_DIR/hop$v.sh" <<EOF
#!/bin/bash
source /etc/msyvpn/lib.sh
source /etc/msyvpn/hysteria.sh
hy_hopping $v
EOF
    chmod +x "$HY_DIR/hop$v.sh"
    cat > "/etc/systemd/system/$(hy_svc "$v").service" <<EOF
[Unit]
Description=MSYVPN Hysteria v$v UDP
After=network.target

[Service]
ExecStartPre=$HY_DIR/hop$v.sh
ExecStart=$exec
Restart=always
RestartSec=3
MemoryMax=250M

[Install]
WantedBy=multi-user.target
EOF
    open_port "$(hy_port "$v")" udp
    hy_hopping "$v"
    systemctl daemon-reload
    systemctl enable --now "$(hy_svc "$v")" >/dev/null 2>&1
    svc_restart "$(hy_svc "$v")"
    sleep 1
    hy_info
}

# Refresca usuarios en las versiones instaladas (llamado desde users.sh)
hy_add_user() {
    hy_installed 1 && { hy_write_v1; svc_restart "$(hy_svc 1)"; }
    hy_installed 2 && { hy_write_v2; svc_restart "$(hy_svc 2)"; }
    return 0
}

hy_set_obfs() {
    local v="$1" o
    hy_installed "$v" || { err "Hysteria v$v no esta instalado"; return; }
    o=$(ask "Nuevo obfs para v$v: "); [[ -z "$o" ]] && { err "Vacio"; return; }
    echo "$o" > "$HY_DIR/obfs$v"
    [[ "$v" == 1 ]] && hy_write_v1 || hy_write_v2
    svc_restart "$(hy_svc "$v")"
    ok "Obfs v$v cambiado a: $o"
}

hy_info_one() {
    local v="$1"
    hy_installed "$v" || { echo "  Hysteria v$v : no instalado"; return; }
    printf '  Hysteria v%s : puerto %s UDP | obfs %s | hopping %s | %s\n' \
        "$v" "$(hy_port "$v")" "$(hy_obfs "$v")" "$(hy_hop "$v")" \
        "$(svc_active "$(hy_svc "$v")" && echo activo || echo inactivo)"
}

hy_info() {
    line
    echo "  Servidor : $(get_ip)   ·   Auth: usuario:contrasena   ·   Insecure: ON"
    hy_info_one 1
    hy_info_one 2
    line
}

hy_remove() {
    local v="$1"
    systemctl disable --now "$(hy_svc "$v")" >/dev/null 2>&1
    rm -f "/etc/systemd/system/$(hy_svc "$v").service" "$(hy_bin "$v")"
    systemctl daemon-reload
    ok "Hysteria v$v eliminado"
}

hy_menu() {
    while true; do
        clear
        title "UDP HYSTERIA  (v1 y v2 pueden coexistir)"
        hy_info
        echo "  1) Instalar / Reconfigurar v1"
        echo "  2) Instalar / Reconfigurar v2"
        echo "  3) Cambiar Obfs de v1"
        echo "  4) Cambiar Obfs de v2"
        echo "  5) Eliminar v1"
        echo "  6) Eliminar v2"
        echo "  0) Volver"
        line
        case "$(ask 'Opcion: ')" in
            1) hy_install 1; pause ;;
            2) hy_install 2; pause ;;
            3) hy_set_obfs 1; pause ;;
            4) hy_set_obfs 2; pause ;;
            5) hy_remove 1; pause ;;
            6) hy_remove 2; pause ;;
            0) return ;;
        esac
    done
}
