#!/bin/bash
# ============================================================
# MÓDULO SLOWDNS — MSYVPN-SCRIPT
# Compatible: Ubuntu 18 / 20 / 22 / 24 / 25+ | ARM + AMD64
# Rutas: /etc/SSHPlus/slowdns/  (keys + binario)
# Autor base: @rufu99  |  Adaptado por MSYVPN
# ============================================================

# ── Directorios base ─────────────────────────────────────────
_SLOW_BASE="/etc/SSHPlus/slowdns"
_SLOW_KEY="${_SLOW_BASE}/keys"
_SLOW_BIN="${_SLOW_BASE}/dns-server"

# ── Crear directorios si no existen ──────────────────────────
mkdir -p "$_SLOW_BASE" "$_SLOW_KEY"

# ── Detectar arquitectura ─────────────────────────────────────
_ARCH=$(uname -m)
case "$_ARCH" in
    x86_64)         _ARCH_TYPE="amd64" ;;
    aarch64|arm64)  _ARCH_TYPE="arm64" ;;
    armv7l|armv6l)  _ARCH_TYPE="arm"   ;;
    *)              _ARCH_TYPE="amd64" ;;
esac

# ── Funciones de color (compatibles sin dependencias externas) ─
_bar()   { echo -e "\033[1;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"; }
_verd()  { echo -e "\033[1;32m$*\033[0m"; }
_verm()  { echo -e "\033[1;31m$*\033[0m"; }
_ama()   { echo -e "\033[1;33m$*\033[0m"; }
_azu()   { echo -e "\033[1;36m$*\033[0m"; }
_bra()   { echo -e "\033[0;34m┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\033[0m"
           echo -e "\033[0;34m┃\E[44;1;37m  $*\E[0m\033[0;34m┃"
           echo -e "\033[0;34m┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\033[0m"; }

# ── Verificar / descargar binario dns-server ─────────────────
_check_or_download_bin() {
    [[ -x "$_SLOW_BIN" ]] && return 0

    _ama "  Descargando binario dns-server ($_ARCH_TYPE)..."

    local _URLS=(
        "https://raw.githubusercontent.com/khaledagn/VPS-AGN_English_Official/master/LINKS-LIBRARIES/dns-server"
        "https://github.com/juanitoprosniff/scriptsshmsy/raw/main/installer/dns-server"
    )

    for _url in "${_URLS[@]}"; do
        wget -q --timeout=20 "$_url" -O "$_SLOW_BIN" 2>/dev/null
        if [[ -s "$_SLOW_BIN" ]]; then
            chmod +x "$_SLOW_BIN"
            _verd "  ✓ Binario descargado correctamente"
            return 0
        fi
        rm -f "$_SLOW_BIN" 2>/dev/null
    done

    _verm "  ✗ No se pudo descargar el binario."
    _ama "  Coloque manualmente dns-server en: $_SLOW_BIN"
    return 1
}

# ── Mostrar información actual ────────────────────────────────
info_slow() {
    clear
    _bar
    _bra "    INFORMACIÓN SLOWDNS — MSYVPN-SCRIPT    "
    _bar
    echo ""

    local _ns _key _port _status

    # Leer datos guardados
    _ns=$(cat "${_SLOW_KEY}/domain_ns" 2>/dev/null)
    _key=$(cat "${_SLOW_KEY}/server.pub" 2>/dev/null)
    _port=$(cat "${_SLOW_KEY}/puerto" 2>/dev/null)

    if [[ -z "$_ns" ]] || [[ -z "$_key" ]]; then
        _verm "  ✗ SlowDNS no configurado todavía."
        _ama "  Use la opción [2] para instalar y configurar."
        echo ""
        _bar
        read -p "  Presione ENTER para continuar..." _p
        return
    fi

    # Estado del proceso
    if screen -ls 2>/dev/null | grep -q "slowdns"; then
        _status="\033[1;32m● ACTIVO\033[0m"
    else
        _status="\033[1;31m● INACTIVO\033[0m"
    fi

    echo -e "  Estado       : $_status"
    _bar
    echo -e "  \033[1;33mNS (Nameserver): \033[1;32m$_ns\033[0m"
    echo -e "  \033[1;33mClave pública  : \033[1;32m$_key\033[0m"
    echo -e "  \033[1;33mPuerto SSH/DB  : \033[1;32m${_port:-no configurado}\033[0m"
    echo -e "  \033[1;33mPuerto SlowDNS : \033[1;32m5300 UDP\033[0m"
    echo -e "  \033[1;33mArquitectura   : \033[1;32m$_ARCH_TYPE\033[0m"
    _bar
    echo ""
    _ama "  Configuración en tu app cliente:"
    echo -e "  \033[1;37m  Servidor NS  → \033[1;32m$_ns\033[0m"
    echo -e "  \033[1;37m  Clave pública → \033[1;32m$_key\033[0m"
    echo ""
    _bar
    read -p "  Presione ENTER para continuar..." _p
}

# ── Detectar puertos SSH/Dropbear disponibles ─────────────────
_detect_ports() {
    local _ports_raw _proto _port
    declare -g -a _PORT_LIST=()
    declare -g -a _PROTO_LIST=()

    while read -r _line; do
        _proto=$(echo "$_line" | awk '{print $1}')
        _port=$(echo "$_line" | awk '{print $9}' | awk -F: '{print $NF}')
        [[ -z "$_port" ]] && continue

        case "$_proto" in
            sshd|dropbear|dropbear-legacy|stunnel4|stunnel|python|python3)
                _PORT_LIST+=("$_port")
                _PROTO_LIST+=("$_proto")
                ;;
        esac
    done < <(ss -tlpn 2>/dev/null | grep "LISTEN" | grep -v "COMMAND")
}

# ── Configurar e iniciar SlowDNS ──────────────────────────────
ini_slow() {
    clear
    _bra "        CONFIGURAR SLOWDNS — MSYVPN          "
    echo ""

    # Verificar / descargar binario
    _check_or_download_bin || { sleep 3; return; }

    # ── Detectar puertos disponibles ──────────────────────────
    _ama "  Servicios disponibles para tunelizar:"
    _bar

    # Recopilar puertos activos con ss
    declare -A _seen
    local n=1
    declare -a _drop_ports=()
    declare -a _drop_protos=()

    while IFS= read -r _raw; do
        local _pr _pt
        _pr=$(echo "$_raw" | awk '{print $1}')
        _pt=$(echo "$_raw" | awk '{print $4}' | rev | cut -d: -f1 | rev)
        [[ -z "$_pt" || "${_seen[$_pt]}" ]] && continue
        case "$_pr" in
            sshd|dropbear|stunnel4|stunnel|python|python3) : ;;
            *) continue ;;
        esac
        _seen[$_pt]=1
        printf "  \033[1;31m[%s]\033[0m \033[1;33m%-14s\033[0m \033[1;36m%s\033[0m\n" "$n" "$_pr" "$_pt"
        _drop_ports+=("$_pt")
        _drop_protos+=("$_pr")
        ((n++))
    done < <(ss -tlpn 2>/dev/null | grep "LISTEN")

    # Agregar SSH manualmente si no apareció
    local _ssh_p=$(grep '^Port' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
    if [[ -n "$_ssh_p" && -z "${_seen[$_ssh_p]}" ]]; then
        printf "  \033[1;31m[%s]\033[0m \033[1;33m%-14s\033[0m \033[1;36m%s\033[0m\n" "$n" "sshd (manual)" "$_ssh_p"
        _drop_ports+=("$_ssh_p")
        ((n++))
    fi

    _bar
    local _max=$(( n - 1 ))
    echo -ne "\033[1;32m  Seleccione el número del servicio [1-$_max]: \033[1;37m"
    read _sel
    [[ -z "$_sel" || "$_sel" -lt 1 || "$_sel" -gt "$_max" ]] 2>/dev/null && {
        _verm "  Opción inválida."; sleep 2; return
    }

    local _PORT="${_drop_ports[$(( _sel - 1 ))]}"
    echo "$_PORT" > "${_SLOW_KEY}/puerto"
    echo -e "\n  \033[1;33mPuerto seleccionado: \033[1;32m$_PORT\033[0m"
    _bar

    # ── Ingresar NS ───────────────────────────────────────────
    local _NS=""
    while [[ -z "$_NS" ]]; do
        echo -ne "  \033[1;33mIngrese su NS (Nameserver): \033[1;37m"
        read _NS
    done
    echo "$_NS" > "${_SLOW_KEY}/domain_ns"
    echo -e "  \033[1;33mNameserver guardado: \033[1;32m$_NS\033[0m"
    _bar

    # ── Gestión de clave ──────────────────────────────────────
    local _pub_existing
    _pub_existing=$(cat "${_SLOW_KEY}/server.pub" 2>/dev/null)

    if [[ -n "$_pub_existing" ]]; then
        echo -e "  \033[1;33mClave existente encontrada:\033[0m"
        echo -e "  \033[1;32m$_pub_existing\033[0m"
        echo -ne "\n  \033[1;33m¿Usar clave existente? \033[1;31m[s/n]: \033[1;37m"
        read _use_existing
        case "$_use_existing" in
            s|S|y|Y)
                echo -e "  \033[1;32m✓ Usando clave existente.\033[0m"
                ;;
            n|N)
                rm -f "${_SLOW_KEY}/server.key" "${_SLOW_KEY}/server.pub"
                "$_SLOW_BIN" -gen-key \
                    -privkey-file "${_SLOW_KEY}/server.key" \
                    -pubkey-file  "${_SLOW_KEY}/server.pub" 2>/dev/null
                echo -e "  \033[1;33mNueva clave pública:\033[0m"
                echo -e "  \033[1;32m$(cat ${_SLOW_KEY}/server.pub)\033[0m"
                ;;
        esac
    else
        # Generar clave nueva
        _ama "  Generando par de claves..."
        rm -f "${_SLOW_KEY}/server.key" "${_SLOW_KEY}/server.pub"
        "$_SLOW_BIN" -gen-key \
            -privkey-file "${_SLOW_KEY}/server.key" \
            -pubkey-file  "${_SLOW_KEY}/server.pub" 2>/dev/null

        if [[ -s "${_SLOW_KEY}/server.pub" ]]; then
            echo -e "  \033[1;33mClave pública generada:\033[0m"
            echo -e "  \033[1;32m$(cat ${_SLOW_KEY}/server.pub)\033[0m"
        else
            _verm "  ✗ No se pudo generar la clave. Verifique el binario."
            sleep 3; return
        fi
    fi
    _bar

    # ── Configurar firewall ───────────────────────────────────
    iptables -I INPUT  -p udp --dport 5300 -j ACCEPT 2>/dev/null
    iptables -t nat -I PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 5300 2>/dev/null
    command -v ufw &>/dev/null && ufw allow 5300/udp >/dev/null 2>&1

    # ── Iniciar SlowDNS ───────────────────────────────────────
    # Matar instancia previa si existe
    screen -ls 2>/dev/null | grep "slowdns" | cut -d. -f1 | awk '{print $1}' | xargs kill 2>/dev/null
    sleep 1

    _ama "  Iniciando SlowDNS..."
    if screen -dmS slowdns "$_SLOW_BIN" -udp :5300 \
        -privkey-file "${_SLOW_KEY}/server.key" \
        "$_NS" "127.0.0.1:$_PORT"; then
        _verd "  ✓ SlowDNS iniciado correctamente!"
    else
        _verm "  ✗ Error al iniciar SlowDNS."
    fi

    # Guardar en autostart para persistencia al reiniciar
    sed -i '/slowdns/d' /etc/autostart 2>/dev/null
    echo "screen -ls | grep -q slowdns || screen -dmS slowdns ${_SLOW_BIN} -udp :5300 -privkey-file ${_SLOW_KEY}/server.key \$(cat ${_SLOW_KEY}/domain_ns) 127.0.0.1:\$(cat ${_SLOW_KEY}/puerto)" >> /etc/autostart

    _bar
    echo ""
    info_slow
}

# ── Reiniciar SlowDNS ─────────────────────────────────────────
reset_slow() {
    clear
    _bar
    _ama "  Reiniciando SlowDNS..."

    local _NS=$(cat "${_SLOW_KEY}/domain_ns" 2>/dev/null)
    local _PORT=$(cat "${_SLOW_KEY}/puerto" 2>/dev/null)

    if [[ -z "$_NS" || -z "$_PORT" ]]; then
        _verm "  ✗ SlowDNS no está configurado."
        _ama "  Use la opción [2] para configurarlo primero."
        sleep 3; return
    fi

    [[ ! -x "$_SLOW_BIN" ]] && { _check_or_download_bin || { sleep 3; return; }; }

    # Matar instancia anterior
    screen -ls 2>/dev/null | grep "slowdns" | cut -d. -f1 | awk '{print $1}' | xargs kill 2>/dev/null
    sleep 1

    if screen -dmS slowdns "$_SLOW_BIN" -udp :5300 \
        -privkey-file "${_SLOW_KEY}/server.key" \
        "$_NS" "127.0.0.1:$_PORT"; then
        _verd "  ✓ SlowDNS reiniciado correctamente!"
    else
        _verm "  ✗ Error al reiniciar."
    fi
    _bar
    sleep 2
}

# ── Detener SlowDNS ───────────────────────────────────────────
stop_slow() {
    clear
    _bar
    _ama "  Deteniendo SlowDNS..."
    if screen -ls 2>/dev/null | grep "slowdns" | cut -d. -f1 | awk '{print $1}' | xargs kill 2>/dev/null; then
        screen -wipe >/dev/null 2>&1
        _verd "  ✓ SlowDNS detenido."
    else
        _verm "  SlowDNS no estaba activo."
    fi
    _bar
    sleep 2
}

# ── Cambiar NS / Puerto ───────────────────────────────────────
change_config() {
    clear
    _bra "    CAMBIAR CONFIGURACIÓN SLOWDNS    "
    echo ""
    echo -e "  \033[1;31m[\033[1;36m1\033[1;31m] \033[1;33mCambiar Nameserver (NS)"
    echo -e "  \033[1;31m[\033[1;36m2\033[1;31m] \033[1;33mCambiar Puerto destino SSH"
    echo -e "  \033[1;31m[\033[1;36m3\033[1;31m] \033[1;33mRegenenar claves"
    echo -e "  \033[1;31m[\033[1;36m0\033[1;31m] \033[1;33mVolver"
    echo ""
    echo -ne "\033[1;32m  Opción: \033[1;37m"; read _c_opt

    case "$_c_opt" in
    1)
        echo -ne "\n  \033[1;33mNuevo NS: \033[1;37m"; read _new_ns
        [[ -n "$_new_ns" ]] && echo "$_new_ns" > "${_SLOW_KEY}/domain_ns" && \
            _verd "  ✓ NS actualizado. Reinicie SlowDNS." ;;
    2)
        echo -ne "\n  \033[1;33mNuevo Puerto: \033[1;37m"; read _new_port
        [[ -n "$_new_port" ]] && echo "$_new_port" > "${_SLOW_KEY}/puerto" && \
            _verd "  ✓ Puerto actualizado. Reinicie SlowDNS." ;;
    3)
        rm -f "${_SLOW_KEY}/server.key" "${_SLOW_KEY}/server.pub"
        [[ -x "$_SLOW_BIN" ]] && \
        "$_SLOW_BIN" -gen-key \
            -privkey-file "${_SLOW_KEY}/server.key" \
            -pubkey-file  "${_SLOW_KEY}/server.pub" 2>/dev/null && \
        _verd "  ✓ Nuevas claves generadas:" && \
        echo -e "  \033[1;32m$(cat ${_SLOW_KEY}/server.pub)\033[0m" ;;
    0) return ;;
    esac
    sleep 3
}

# ── Menú principal ────────────────────────────────────────────
while true; do
    clear
    echo -e "\033[0;34m┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\033[0m"
    echo -e "\033[0;34m┃\E[44;1;37m         SLOWDNS — MSYVPN-SCRIPT           \E[0m\033[0;34m┃"
    echo -e "\033[0;34m┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\033[0m"
    echo ""

    # Estado en tiempo real
    if screen -ls 2>/dev/null | grep -q "slowdns"; then
        echo -e "  Estado : \033[1;32m● ACTIVO\033[0m"
    else
        echo -e "  Estado : \033[1;31m● INACTIVO\033[0m"
    fi
    _ns_cur=$(cat "${_SLOW_KEY}/domain_ns" 2>/dev/null || echo "no configurado")
    _pt_cur=$(cat "${_SLOW_KEY}/puerto"    2>/dev/null || echo "no configurado")
    echo -e "  NS     : \033[1;33m$_ns_cur\033[0m"
    echo -e "  Puerto : \033[1;33m$_pt_cur\033[0m"
    echo ""
    echo -e "\033[0;34m┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\033[0m"
    echo -e "\033[0;34m┃\033[1;31m[\033[1;36m1\033[1;31m] \033[1;33mVer información SlowDNS                \033[0;34m┃"
    echo -e "\033[0;34m┃\033[1;31m[\033[1;36m2\033[1;31m] \033[1;33mInstalar / Configurar SlowDNS          \033[0;34m┃"
    echo -e "\033[0;34m┃\033[1;31m[\033[1;36m3\033[1;31m] \033[1;32mReiniciar SlowDNS                      \033[0;34m┃"
    echo -e "\033[0;34m┃\033[1;31m[\033[1;36m4\033[1;31m] \033[1;33mCambiar NS / Puerto / Claves           \033[0;34m┃"
    echo -e "\033[0;34m┃\033[1;31m[\033[1;36m5\033[1;31m] \033[1;31mDetener SlowDNS                        \033[0;34m┃"
    echo -e "\033[0;34m┃\033[1;31m[\033[1;36m0\033[1;31m] \033[1;33mVolver                                 \033[0;34m┃"
    echo -e "\033[0;34m┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\033[0m"
    echo ""
    echo -ne "\033[1;32mOpción: \033[1;37m"; read _opcion

    case "$_opcion" in
        1) info_slow ;;
        2) ini_slow ;;
        3) reset_slow ;;
        4) change_config ;;
        5) stop_slow ;;
        0) exit 0 ;;
        *) _verm "  Opción inválida."; sleep 1 ;;
    esac
done
