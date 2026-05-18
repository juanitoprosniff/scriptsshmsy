#!/bin/bash
# ============================================================
# UDP Hysteria v1 Manager — MSYVPN-SCRIPT
# Acceso: 'agnudp' desde la terminal
# ============================================================

CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="$CONFIG_DIR/config.json"
USER_DB="$CONFIG_DIR/udpusers.db"

_hyst_header() {
    clear
    echo -e "\033[1;34m╔══════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;34m║      \033[1;37m UDP HYSTERIA v1 MANAGER — MSYVPN        \033[1;34m║\033[0m"
    echo -e "\033[1;34m╚══════════════════════════════════════════════════╝\033[0m"

    local _port="" _obfs=""
    [[ -f "$CONFIG_FILE" ]] && {
        _port=$(jq -r '.listen // ":36712"' "$CONFIG_FILE" 2>/dev/null | tr -d ':')
        _obfs=$(jq -r '.obfs // "agnudp"' "$CONFIG_FILE" 2>/dev/null)
    }

    local _status
    if systemctl is-active --quiet hysteria-server 2>/dev/null; then
        _status="\033[1;32m● ACTIVO\033[0m"
    else
        _status="\033[1;31m○ INACTIVO\033[0m"
    fi

    local _ip; _ip=$(cat /etc/IP 2>/dev/null | tr -d '\n')
    [[ -z "$_ip" ]] && _ip=$(hostname -I | awk '{print $1}')

    local _ucount=0
    [[ -f "$USER_DB" ]] && _ucount=$(sqlite3 "$USER_DB" "SELECT COUNT(*) FROM users;" 2>/dev/null)

    echo -e "\033[1;33m  Estado     : $_status"
    [[ -n "$_ip" ]]   && echo -e "\033[1;33m  IP         : \033[1;37m$_ip\033[0m"
    [[ -n "$_port" ]] && echo -e "\033[1;33m  Puerto UDP : \033[1;37m$_port\033[0m"
    echo -e "\033[1;33m  Obfs       : \033[1;37m${_obfs}\033[0m"
    echo -e "\033[1;33m  Usuarios   : \033[1;37m${_ucount:-0}\033[0m"
    echo ""
}

_hyst_change_obfs() {
    _hyst_header
    echo -e "\033[1;34m── Cambiar Obfs ──\033[0m"
    local _cur; _cur=$(jq -r '.obfs // "agnudp"' "$CONFIG_FILE" 2>/dev/null)
    echo -e "\033[1;33m  Obfs actual: \033[1;37m$_cur\033[0m"
    echo -e "\033[1;33m  ¡Aviso! Todos los usuarios deben actualizar el Obfs en su app.\033[0m"
    echo -ne "\033[1;32mNuevo Obfs: \033[1;37m"; read -r _obfs
    [[ -z "$_obfs" ]] && { echo -e "\033[1;31mObfs vacío.\033[0m"; sleep 1; return; }
    jq ".obfs = \"$_obfs\"" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    systemctl restart hysteria-server 2>/dev/null
    sleep 1
    echo -e "\033[1;32m✓ Obfs cambiado a: $_obfs\033[0m"
    sleep 2
}

_hyst_uninstall() {
    echo -ne "\033[1;31m¿Seguro que deseas desinstalar Hysteria? [s/N]: \033[1;37m"; read _c
    [[ ! "$_c" =~ ^[sSyY]$ ]] && return
    systemctl stop hysteria-server 2>/dev/null
    systemctl disable hysteria-server 2>/dev/null
    rm -f /etc/systemd/system/hysteria-server.service /usr/local/bin/hysteria
    systemctl daemon-reload 2>/dev/null
    rm -rf "$CONFIG_DIR"
    rm -f /usr/local/bin/hysteria-manager /usr/local/bin/agnudp
    echo -e "\033[1;32m✓ Hysteria desinstalado.\033[0m"
    sleep 2
    exit 0
}

hyst_menu() {
    _hyst_header
    echo -e "\033[1;34m╔══════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;34m║\033[1;31m[\033[1;36m01\033[1;31m]\033[1;37m Reiniciar UDP                            \033[1;34m║\033[0m"
    echo -e "\033[1;34m║\033[1;31m[\033[1;36m02\033[1;31m]\033[1;37m Detener UDP                              \033[1;34m║\033[0m"
    echo -e "\033[1;34m║\033[1;31m[\033[1;36m03\033[1;31m]\033[1;37m Iniciar UDP                              \033[1;34m║\033[0m"
    echo -e "\033[1;34m║\033[1;31m[\033[1;36m04\033[1;31m]\033[1;37m Cambiar Obfs                             \033[1;34m║\033[0m"
    echo -e "\033[1;34m║\033[1;31m[\033[1;36m05\033[1;31m]\033[1;37m Desinstalar Hysteria                     \033[1;34m║\033[0m"
    echo -e "\033[1;34m║\033[1;31m[\033[1;36m00\033[1;31m]\033[1;37m Salir                                    \033[1;34m║\033[0m"
    echo -e "\033[1;34m╚══════════════════════════════════════════════════╝\033[0m"
    echo ""
    echo -ne "\033[1;32m¿Qué deseas hacer?: \033[1;37m" && read _ch

    case $_ch in
        1|01)
            systemctl restart hysteria-server 2>/dev/null; sleep 1
            systemctl is-active --quiet hysteria-server && \
                echo -e "\033[1;32m✓ Hysteria reiniciado.\033[0m" || \
                echo -e "\033[1;31m✗ No pudo iniciar.\033[0m"
            sleep 2; hyst_menu ;;
        2|02)
            systemctl stop hysteria-server 2>/dev/null
            echo -e "\033[1;33m● Hysteria detenido.\033[0m"; sleep 2; hyst_menu ;;
        3|03)
            systemctl start hysteria-server 2>/dev/null; sleep 1
            systemctl is-active --quiet hysteria-server && \
                echo -e "\033[1;32m✓ Hysteria iniciado.\033[0m" || \
                echo -e "\033[1;31m✗ No pudo iniciar — ver: journalctl -u hysteria-server -n 20\033[0m"
            sleep 2; hyst_menu ;;
        4|04) _hyst_change_obfs; hyst_menu ;;
        5|05) _hyst_uninstall ;;
        0|00) exit 0 ;;
        *) echo -e "\033[1;31mOpción inválida\033[0m"; sleep 1; hyst_menu ;;
    esac
}

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "\033[1;31m✗ Hysteria no está instalado.\033[0m"
    echo -e "\033[1;33m  Instálalo desde el menú principal → opción 18\033[0m"
    exit 1
fi

command -v sqlite3 &>/dev/null || apt-get install -y sqlite3 >/dev/null 2>&1

hyst_menu
