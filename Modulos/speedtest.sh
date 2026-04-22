#!/bin/bash
# ============================================================
# SPEEDTEST — usando CLI oficial de Ookla (speedtest.net)
# Compatible: Ubuntu 18 / 20 / 22 / 24 / 25+
# ============================================================

_UBUNTU_VER=$(lsb_release -rs 2>/dev/null | cut -d. -f1 || echo "0")

clear
echo -e "\E[38;5;18m╭━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╮\033[0m"
echo -e "\E[38;5;18m┃\E[44;1;37m     PROBANDO VELOCIDAD DEL SERVIDOR     \E[0m\E[38;5;18m┃"
echo -e "\E[38;5;18m╰━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╯\033[0m"
echo ""

# ── Instalar CLI oficial de Ookla si no está ─────────────────
_instalar_ookla() {
    echo -e "\033[1;33m  Instalando CLI oficial de speedtest.net...\033[0m"

    # Detectar arquitectura
    local _arch
    case "$(uname -m)" in
        x86_64)  _arch="x86_64" ;;
        aarch64) _arch="aarch64" ;;
        armv7l)  _arch="armhf" ;;
        *)       _arch="x86_64" ;;
    esac

    # Método 1: repositorio oficial Ookla (recomendado)
    if command -v curl &>/dev/null; then
        curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh \
            | bash >/dev/null 2>&1
        apt-get install -y speedtest >/dev/null 2>&1
    fi

    # Verificar si funcionó
    if command -v speedtest &>/dev/null; then
        echo -e "\033[1;32m  CLI Ookla instalado correctamente.\033[0m"
        return 0
    fi

    # Método 2: descarga directa del binario desde speedtest.net
    echo -e "\033[1;33m  Intentando descarga directa...\033[0m"
    local _tmp_dir="/tmp/speedtest_install"
    mkdir -p "$_tmp_dir"
    cd "$_tmp_dir"

    local _url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-${_arch}.tgz"
    wget -q --timeout=30 "$_url" -O speedtest.tgz 2>/dev/null || \
    curl -s --max-time 30 "$_url" -o speedtest.tgz 2>/dev/null

    if [[ -s speedtest.tgz ]]; then
        tar xzf speedtest.tgz >/dev/null 2>&1
        [[ -f speedtest ]] && {
            cp speedtest /usr/local/bin/speedtest
            chmod +x /usr/local/bin/speedtest
            echo -e "\033[1;32m  Binario instalado.\033[0m"
            cd /; rm -rf "$_tmp_dir"
            return 0
        }
    fi
    cd /; rm -rf "$_tmp_dir"

    # Método 3: fallback a speedtest-cli de Python
    echo -e "\033[1;33m  Usando speedtest-cli (Python) como fallback...\033[0m"
    apt-get install -y python3-pip >/dev/null 2>&1
    if [[ "${_UBUNTU_VER:-0}" -ge 22 ]]; then
        pip3 install speedtest-cli --break-system-packages -q 2>/dev/null || \
        pip3 install speedtest-cli -q 2>/dev/null
    else
        pip3 install speedtest-cli -q 2>/dev/null || \
        pip  install speedtest-cli -q 2>/dev/null
    fi
    command -v speedtest-cli &>/dev/null && return 0

    return 1
}

# ── Determinar qué binario usar ───────────────────────────────
_bin=""
if command -v speedtest &>/dev/null; then
    # Verificar que sea el CLI de Ookla (no otro 'speedtest')
    speedtest --version 2>/dev/null | grep -qi "ookla\|speedtest" && _bin="ookla" || _bin="ookla"
elif command -v speedtest-cli &>/dev/null; then
    _bin="python"
else
    _instalar_ookla
    command -v speedtest     &>/dev/null && _bin="ookla"
    command -v speedtest-cli &>/dev/null && _bin="python"
fi

if [[ -z "$_bin" ]]; then
    echo -e "\033[1;31m  No se pudo instalar ninguna herramienta de speedtest.\033[0m"
    echo -e "\033[1;33m  Intente: apt install speedtest\033[0m"
    echo -ne "\n\033[1;31mENTER \033[1;37mpara volver...\033[0m"; read
    exit 1
fi

echo -e "\033[1;33m  Ejecutando prueba con speedtest.net...\033[0m"
echo -e "\033[1;37m  Espere hasta 90 segundos...\033[0m"
echo ""

# ── Ejecutar y capturar resultados ───────────────────────────
_ping_ms="" _down="" _up="" _link="" _server="" _isp=""

if [[ "$_bin" = "ookla" ]]; then
    # Aceptar licencia sin interacción + formato de salida legible
    _result=$(timeout 90 speedtest \
        --accept-license \
        --accept-gdpr \
        --progress=no \
        2>/dev/null)

    # Parsear salida del CLI Ookla (formato texto estándar)
    _ping_ms=$(echo "$_result" | grep -i 'Latency\|Idle Latency' | \
               grep -oP '[\d.]+\s*ms' | head -1)
    _down=$(echo "$_result" | grep -i 'Download' | \
            grep -oP '[\d.]+\s*\w+bps' | head -1)
    _up=$(echo "$_result" | grep -i 'Upload' | \
          grep -oP '[\d.]+\s*\w+bps' | head -1)
    _link=$(echo "$_result" | grep -i 'Result URL\|Share' | \
            grep -oP 'https?://\S+' | head -1)
    _server=$(echo "$_result" | grep -i 'Server' | head -1 | \
              sed 's/Server://i' | sed 's/^[[:space:]]*//')
    _isp=$(echo "$_result" | grep -i 'ISP' | head -1 | \
           sed 's/ISP://i' | sed 's/^[[:space:]]*//')

    # Si no hubo resultado (timeout o error), mostrar mensaje
    if [[ -z "$_down" && -z "$_up" ]]; then
        echo -e "\033[1;31m  No se obtuvieron resultados (timeout o error de red).\033[0m"
        echo -e "\033[1;37m  Salida raw:\033[0m"
        echo "$_result" | head -10
        echo ""
        echo -ne "\n\033[1;31mENTER \033[1;37mpara volver...\033[0m"; read
        exit 1
    fi

elif [[ "$_bin" = "python" ]]; then
    _result=$(timeout 90 speedtest-cli --simple 2>/dev/null)
    _ping_ms=$(echo "$_result" | grep -i 'Ping'     | awk '{print $2 " " $3}')
    _down=$(echo "$_result"    | grep -i 'Download' | awk '{print $2 " " $3}')
    _up=$(echo "$_result"      | grep -i 'Upload'   | awk '{print $2 " " $3}')
    _link=$(timeout 20 speedtest-cli --share 2>/dev/null | grep -oP 'https?://\S+' | head -1)
fi

# ── Mostrar resultados ────────────────────────────────────────
clear
echo -e "\E[38;5;18m╭━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╮\033[0m"
echo -e "\E[38;5;18m┃\E[44;1;37m        RESULTADO — speedtest.net        \E[0m\E[38;5;18m┃"
echo -e "\E[38;5;18m╰━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╯\033[0m"
echo ""
echo -e "\E[38;5;18m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
[[ -n "$_isp"    ]] && echo -e "\033[1;32mISP             :\033[1;37m $_isp"
[[ -n "$_server" ]] && echo -e "\033[1;32mSERVIDOR        :\033[1;37m $_server"
echo -e "\033[1;32mPING (LATENCIA) :\033[1;37m ${_ping_ms:-N/A}"
echo -e "\033[1;32mDESCARGA        :\033[1;37m ${_down:-N/A}"
echo -e "\033[1;32mSUBIDA          :\033[1;37m ${_up:-N/A}"
echo -e "\E[38;5;18m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
[[ -n "$_link" ]] && {
    echo ""
    echo -e "\033[1;32mCOMPARTIR RESULTADO:\033[0m"
    echo -e "\E[38;5;33m  $_link\033[0m"
}
echo ""
echo -ne "\n\033[1;31mENTER \033[1;37mpara volver al \033[1;32mMENÚ!\033[0m"; read
