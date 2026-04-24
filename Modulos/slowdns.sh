#!/bin/bash
# ============================================================
# MÓDULO: SLOWDNS — MSYVPN-SCRIPT
# Autor original: @rufu99 / adaptado: @JUANITOPROSNIFF
# Compatible: Ubuntu 18 / 20 / 22 / 24 / 25 / 26+
# Repo: https://github.com/juanitoprosniff/script_msyvpn
# FIXES v2:
#   - Detección automática ARM / AMD64 / ARM64
#   - Binario dns-server descargado desde repo propio
#   - Compatibilidad iptables / nftables (Ubuntu 22+)
#   - Autostart con systemd service (más robusto que screen)
#   - Carpeta /etc/SSHPlus/Slow/ (integrado en árbol MSYvpn)
# ============================================================

ADM_inst="/etc/SSHPlus/Slow/install"
ADM_slow="/etc/SSHPlus/Slow/Key"

# Repo propio (reemplaza el eliminado de khaledagn)
_REPO_BASE="https://raw.githubusercontent.com/juanitoprosniff/script_msyvpn/main/Slow"

# ── Crear carpetas si no existen ─────────────────────────────
[[ ! -d "${ADM_inst}" ]] && mkdir -p "${ADM_inst}"
[[ ! -d "${ADM_slow}" ]] && mkdir -p "${ADM_slow}"

# ── Detectar arquitectura ────────────────────────────────────
_detect_arch() {
    local _arch
    _arch=$(uname -m)
    case "$_arch" in
        x86_64|amd64)   echo "amd64" ;;
        aarch64|arm64)  echo "arm64" ;;
        armv7*|armhf)   echo "arm"   ;;
        armv6*)         echo "arm"   ;;
        *)              echo "amd64" ;;  # fallback
    esac
}
_ARCH=$(_detect_arch)

# ── Colores y mensajes ───────────────────────────────────────
msg() {
    case "$1" in
        -bar)   echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m" ;;
        -bar3)  echo -e "\033[0;34m───────────────────────────────────────\033[0m" ;;
        -ama)   echo -e "\033[1;33m${2}\033[0m" ;;
        -verd)  echo -e "\033[1;32m${2}\033[0m" ;;
        -verm)  echo -e "\033[1;31m${2}\033[0m" ;;
        -verm2) echo -e "\033[0;31m${2}\033[0m" ;;
        -azu)   echo -e "\033[1;36m${2}\033[0m" ;;
        -bra)   echo -e "\033[1;37m${2}\033[0m" ;;
    esac
}

menu_func() {
    local n=1
    for item in "$@"; do
        echo -e " \033[1;31m[$n]\033[0m \033[1;33m$item\033[0m"
        ((n++))
    done
    echo -e " \033[1;31m[0]\033[0m \033[1;33mVOLVER\033[0m"
}

selection_fun() {
    local max="$1"
    local opc
    while true; do
        echo -ne " \033[1;32mOpción: \033[1;37m"; read opc
        [[ "$opc" =~ ^[0-9]+$ ]] && [[ "$opc" -ge 0 ]] && [[ "$opc" -le "$max" ]] && { echo "$opc"; return; }
        echo -e " \033[1;31mOpción inválida!\033[0m"
    done
}

# ── Firewall: abrir puerto UDP ────────────────────────────────
_fw_open_udp() {
    local pt="$1"
    command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active" && \
        ufw allow ${pt}/udp >/dev/null 2>&1
    command -v iptables &>/dev/null && {
        iptables -C INPUT -p udp --dport ${pt} -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p udp --dport ${pt} -j ACCEPT >/dev/null 2>&1
    }
    # Soporte nftables (Ubuntu 22+)
    command -v nft &>/dev/null && nft list ruleset 2>/dev/null | grep -q "type filter" && {
        nft add rule inet filter input udp dport ${pt} accept 2>/dev/null || true
    }
}

# ── Descargar binario dns-server desde repo propio ───────────
_download_dns_server() {
    msg -ama " Detectando arquitectura: $_ARCH"
    msg -ama " Descargando dns-server desde repo propio..."

    # Nombre del binario según arch (ajusta según los archivos que subas a tu repo)
    local _bin_name
    case "$_ARCH" in
        amd64) _bin_name="dns-server"      ;;
        arm64) _bin_name="dns-server-arm64" ;;
        arm)   _bin_name="dns-server-arm"   ;;
        *)     _bin_name="dns-server"      ;;
    esac

    local _url="${_REPO_BASE}/${_bin_name}"

    if wget -q --timeout=30 -O "${ADM_inst}/dns-server" "${_url}" 2>/dev/null; then
        chmod +x "${ADM_inst}/dns-server"
        if "${ADM_inst}/dns-server" --help &>/dev/null || \
           "${ADM_inst}/dns-server" -h &>/dev/null || \
           file "${ADM_inst}/dns-server" 2>/dev/null | grep -q "ELF"; then
            msg -verd " [OK] dns-server descargado correctamente ($_ARCH)"
            return 0
        fi
    fi

    # Fallback: intentar con curl
    if curl -fsSL --max-time 30 "${_url}" -o "${ADM_inst}/dns-server" 2>/dev/null; then
        chmod +x "${ADM_inst}/dns-server"
        msg -verd " [OK] dns-server (via curl)"
        return 0
    fi

    msg -verm " [FAIL] No se pudo descargar dns-server"
    msg -bar
    msg -ama " Suba manualmente el binario a:"
    msg -ama " ${ADM_inst}/dns-server"
    return 1
}

# ── Crear servicio systemd para SlowDNS ──────────────────────
_create_slowdns_service() {
    local _ns="$1"
    local _port="$2"

    cat > /etc/systemd/system/slowdns.service <<EOF
[Unit]
Description=SlowDNS Tunnel - MSYVPN-SCRIPT
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=${ADM_inst}/dns-server -udp :5300 -privkey-file ${ADM_slow}/server.key ${_ns} 127.0.0.1:${_port}
Restart=always
RestartSec=5
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload 2>/dev/null
    systemctl enable slowdns 2>/dev/null
}

# ── Ver información SlowDNS ───────────────────────────────────
info() {
    clear
    nodata() {
        msg -bar
        msg -ama "!SIN INFORMACIÓN DE SLOWDNS!"
        msg -bar
        msg -ama "Use la opción [2] para configurar SlowDNS."
        sleep 3
        exit 0
    }

    if [[ -e "${ADM_slow}/domain_ns" ]]; then
        local ns; ns=$(cat "${ADM_slow}/domain_ns")
        [[ -z "$ns" ]] && nodata
    else
        nodata
    fi

    if [[ -e "${ADM_slow}/server.pub" ]]; then
        local key; key=$(cat "${ADM_slow}/server.pub")
        [[ -z "$key" ]] && nodata
    else
        nodata
    fi

    local _port_file="${ADM_slow}/puerto"
    local _port="N/D"
    [[ -e "$_port_file" ]] && _port=$(cat "$_port_file")

    # Estado del servicio
    local _status="\033[1;31m⬤ INACTIVO\033[0m"
    if systemctl is-active slowdns &>/dev/null; then
        _status="\033[1;32m⬤ ACTIVO (systemd)\033[0m"
    elif screen -ls 2>/dev/null | grep -q "slowdns"; then
        _status="\033[1;32m⬤ ACTIVO (screen)\033[0m"
    fi

    echo -e "\033[0;34m┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\033[0m"
    echo -e "\033[0;34m┃\E[44;1;37m       INFORMACIÓN DE SLOWDNS            \E[0m\033[0;34m┃"
    echo -e "\033[0;34m┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\033[0m"
    echo -e " \033[1;33mEstado       : ${_status}"
    echo -e " \033[1;33mArquitectura : \033[1;37m${_ARCH}"
    echo -e " \033[1;33mNameserver   : \033[1;32m${ns}"
    echo -e " \033[1;33mPuerto SSH   : \033[1;32m${_port}"
    echo -e " \033[1;33mClave pública: \033[1;37m${key}"
    echo -e "\033[0;34m┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\033[0m"
    echo ""
    echo -ne "\033[1;33mPresione ENTER para volver...\033[0m"; read
    exit 0
}

# ── Detectar puertos de servicios SSH disponibles ────────────
drop_port() {
    local portasVAR
    if command -v ss &>/dev/null; then
        portasVAR=$(ss -tlpn 2>/dev/null | grep "LISTEN")
    else
        portasVAR=$(netstat -tlpn 2>/dev/null | grep "LISTEN")
    fi

    local NOREPEAT reQ Port
    unset DPB

    while read -r port; do
        reQ=$(echo "${port}" | awk '{print $1}')
        if command -v ss &>/dev/null; then
            Port=$(echo "${port}" | awk '{print $4}' | rev | cut -d: -f1 | rev)
        else
            Port=$(echo "${port}" | awk '{print $4}' | cut -d: -f2)
        fi

        [[ -z "$Port" ]] && continue
        [[ $(echo -e "$NOREPEAT" | grep -w "$Port") ]] && continue
        NOREPEAT+="$Port\n"

        case ${reQ} in
            sshd|dropbear|stunnel4|stunnel|python|python3) DPB+=" $reQ:$Port" ;;
            *) continue ;;
        esac
    done <<< "${portasVAR}"
}

# ── Instalar / Configurar SlowDNS ────────────────────────────
ini_slow() {
    clear
    echo -e "\033[0;34m┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\033[0m"
    echo -e "\033[0;34m┃\E[44;1;37m       INSTALACIÓN DE SLOWDNS            \E[0m\033[0;34m┃"
    echo -e "\033[0;34m┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\033[0m"
    echo -e " \033[1;33mArquitectura detectada: \033[1;32m${_ARCH}\033[0m"
    msg -bar

    # ── Seleccionar puerto destino ────────────────────────────
    drop_port
    if [[ -z "$DPB" ]]; then
        msg -verm "No se detectaron servicios SSH/proxy activos."
        msg -ama "Inicie OpenSSH, Dropbear o un proxy primero."
        sleep 3; return
    fi

    echo -e " \033[1;33mSeleccione el puerto destino para SlowDNS:\033[0m"
    msg -bar
    local n=1
    local drop=()
    for i in $DPB; do
        local proto; proto=$(echo "$i" | awk -F ":" '{print $1}')
        local proto2; proto2=$(printf '%-12s' "$proto")
        local port;  port=$(echo "$i"  | awk -F ":" '{print $2}')
        echo -e " \033[1;31m[$n]\033[0m \033[0;31m▶\033[0m \033[1;33m${proto2}\033[1;36m${port}\033[0m"
        drop[$n]=$port
        ((n++))
    done
    local num_opc=$((n - 1))
    msg -bar
    local opc; opc=$(selection_fun "$num_opc")
    [[ "$opc" = "0" ]] && return

    echo "${drop[$opc]}" > "${ADM_slow}/puerto"
    local PORT; PORT=$(cat "${ADM_slow}/puerto")

    echo ""
    echo -e " \033[1;33mPuerto de conexión vía SlowDNS: \033[1;32m${PORT}\033[0m"
    msg -bar

    # ── Ingresar NS ───────────────────────────────────────────
    local NS=""
    while [[ -z "$NS" ]]; do
        echo -ne " \033[1;33mTu dominio NS (Nameserver): \033[1;37m"; read NS
    done
    echo "$NS" > "${ADM_slow}/domain_ns"
    echo -e " \033[1;32m✓ Nameserver guardado: \033[1;37m${NS}\033[0m"
    msg -bar

    # ── Descargar binario si no existe ───────────────────────
    if [[ ! -x "${ADM_inst}/dns-server" ]] || \
       ! file "${ADM_inst}/dns-server" 2>/dev/null | grep -q "ELF"; then
        _download_dns_server || { sleep 3; return; }
    else
        msg -verd " dns-server ya presente, omitiendo descarga."
    fi

    # ── Gestionar llaves ──────────────────────────────────────
    msg -bar
    local pub=""
    [[ -e "${ADM_slow}/server.pub" ]] && pub=$(cat "${ADM_slow}/server.pub")

    if [[ -n "$pub" ]]; then
        echo -e " \033[1;33mClave existente detectada.\033[0m"
        echo -e " \033[1;37mClave: \033[1;32m${pub}\033[0m"
        msg -bar
        echo -ne " \033[1;33m¿Usar clave existente? [S/n]: \033[1;37m"; read ex_key
        case "$ex_key" in
            n|N)
                rm -f "${ADM_slow}/server.key" "${ADM_slow}/server.pub"
                "${ADM_inst}/dns-server" -gen-key \
                    -privkey-file "${ADM_slow}/server.key" \
                    -pubkey-file  "${ADM_slow}/server.pub" &>/dev/null
                echo -e " \033[1;32m✓ Nueva clave generada: \033[1;37m$(cat ${ADM_slow}/server.pub)\033[0m"
                ;;
            *)
                echo -e " \033[1;32m✓ Usando clave existente.\033[0m"
                ;;
        esac
    else
        rm -f "${ADM_slow}/server.key" "${ADM_slow}/server.pub"
        "${ADM_inst}/dns-server" -gen-key \
            -privkey-file "${ADM_slow}/server.key" \
            -pubkey-file  "${ADM_slow}/server.pub" &>/dev/null
        echo -e " \033[1;32m✓ Clave generada: \033[1;37m$(cat ${ADM_slow}/server.pub)\033[0m"
    fi

    msg -bar
    msg -ama "    Iniciando SlowDNS..."

    # ── Firewall ──────────────────────────────────────────────
    _fw_open_udp 5300
    _fw_open_udp 53

    # Redirigir UDP 53 → 5300 (compatible iptables/nftables)
    iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 5300 2>/dev/null
    iptables -t nat -I PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 5300 2>/dev/null

    # ── Crear servicio systemd ────────────────────────────────
    _create_slowdns_service "$NS" "$PORT"

    # Parar instancias antiguas de screen si las hay
    screen -ls 2>/dev/null | grep slowdns | awk '{print $1}' | \
        xargs -I{} screen -S {} -X quit 2>/dev/null
    screen -wipe >/dev/null 2>&1

    # Iniciar via systemd
    systemctl start slowdns 2>/dev/null

    sleep 2
    if systemctl is-active slowdns &>/dev/null; then
        msg -verd " ✓ SlowDNS iniciado correctamente (systemd)!"
    else
        # Fallback: screen
        msg -ama " Intentando inicio via screen..."
        screen -dmS slowdns "${ADM_inst}/dns-server" \
            -udp :5300 -privkey-file "${ADM_slow}/server.key" "$NS" "127.0.0.1:${PORT}"
        sleep 2
        if screen -ls 2>/dev/null | grep -q "slowdns"; then
            msg -verd " ✓ SlowDNS iniciado via screen."
        else
            msg -verm " ✗ Error al iniciar SlowDNS."
            msg -ama "   Verifique: ${ADM_inst}/dns-server"
        fi
    fi

    echo ""
    msg -bar
    echo -e " \033[1;33mRESUMEN:\033[0m"
    echo -e " \033[1;37m NS (Nameserver) : \033[1;32m${NS}\033[0m"
    echo -e " \033[1;37m Puerto destino  : \033[1;32m${PORT}\033[0m"
    echo -e " \033[1;37m Clave pública   : \033[1;32m$(cat ${ADM_slow}/server.pub 2>/dev/null)\033[0m"
    echo -e " \033[1;37m Arquitectura    : \033[1;32m${_ARCH}\033[0m"
    msg -bar
    echo -ne "\033[1;33mPresione ENTER para continuar...\033[0m"; read
    exit 0
}

# ── Reiniciar SlowDNS ─────────────────────────────────────────
reset_slow() {
    clear
    msg -bar
    msg -ama "    Reiniciando SlowDNS..."

    # Intentar systemd primero
    if systemctl is-enabled slowdns &>/dev/null; then
        systemctl restart slowdns 2>/dev/null
        sleep 2
        if systemctl is-active slowdns &>/dev/null; then
            msg -verd " ✓ Reiniciado correctamente (systemd)!"
            sleep 2; exit 0
        fi
    fi

    # Fallback: matar screen y re-lanzar
    screen -ls 2>/dev/null | grep slowdns | awk '{print $1}' | \
        xargs -I{} screen -S {} -X quit 2>/dev/null
    screen -wipe >/dev/null 2>&1

    if [[ -e "${ADM_slow}/domain_ns" ]] && [[ -e "${ADM_slow}/puerto" ]] && \
       [[ -e "${ADM_slow}/server.key" ]]; then
        local NS; NS=$(cat "${ADM_slow}/domain_ns")
        local PORT; PORT=$(cat "${ADM_slow}/puerto")
        screen -dmS slowdns "${ADM_inst}/dns-server" \
            -udp :5300 -privkey-file "${ADM_slow}/server.key" "$NS" "127.0.0.1:${PORT}"
        sleep 2
        screen -ls 2>/dev/null | grep -q "slowdns" && \
            msg -verd " ✓ Reiniciado via screen." || \
            msg -verm " ✗ No se pudo reiniciar."
    else
        msg -verm " Configuración incompleta. Use la opción [2] para configurar."
    fi
    sleep 2; exit 0
}

# ── Parar SlowDNS ─────────────────────────────────────────────
stop_slow() {
    clear
    msg -bar
    msg -ama "    Deteniendo SlowDNS..."

    systemctl stop slowdns 2>/dev/null
    screen -ls 2>/dev/null | grep slowdns | awk '{print $1}' | \
        xargs -I{} screen -S {} -X quit 2>/dev/null
    screen -wipe >/dev/null 2>&1

    msg -verd " ✓ SlowDNS detenido."
    sleep 2; exit 0
}

# ── Menú principal ────────────────────────────────────────────
while :; do
    clear
    echo -e "\033[0;34m┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\033[0m"
    echo -e "\033[0;34m┃\E[44;1;37m           MSYVPN — SLOWDNS              \E[0m\033[0;34m┃"
    echo -e "\033[0;34m┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\033[0m"
    echo -e " \033[1;33mArquitectura : \033[1;32m${_ARCH}\033[0m"

    # Estado rápido
    if systemctl is-active slowdns &>/dev/null; then
        echo -e " \033[1;33mEstado       : \033[1;32m⬤ ACTIVO (systemd)\033[0m"
    elif screen -ls 2>/dev/null | grep -q "slowdns"; then
        echo -e " \033[1;33mEstado       : \033[1;32m⬤ ACTIVO (screen)\033[0m"
    else
        echo -e " \033[1;33mEstado       : \033[1;31m⬤ INACTIVO\033[0m"
    fi

    msg -bar
    menu_func \
        "Ver información de SlowDNS" \
        "$(echo -e "\033[1;32mInstalar / Configurar SlowDNS\033[0m")" \
        "$(echo -e "\033[1;33mReiniciar SlowDNS\033[0m")" \
        "$(echo -e "\033[1;31mDetener SlowDNS\033[0m")"
    msg -bar

    opcion=$(selection_fun 4)
    case $opcion in
        1) info ;;
        2) ini_slow ;;
        3) reset_slow ;;
        4) stop_slow ;;
        0) exit 0 ;;
    esac
done
