#!/bin/bash
# ============================================================
# UDP Hysteria v1 Manager — MSYVPN-SCRIPT
# Acceso: 'agnudp' o 'hysteria-manager'
#
# Configuración del lado app (mismo para todos los usuarios):
#   • Obfs       = valor fijo del servidor (default: agnudp)
#   • Pass field = "usuario:contraseña"
#   • Insecure   = ON (cert self-signed)
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
        _obfs=$(jq -r '.obfs // ""' "$CONFIG_FILE" 2>/dev/null)
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
    [[ -n "$_obfs" ]] && echo -e "\033[1;33m  Obfs (fijo): \033[1;37m$_obfs\033[0m"
    echo -e "\033[1;33m  Usuarios   : \033[1;37m${_ucount:-0}\033[0m"
    echo ""
}

_hyst_rebuild_config() {
    [[ ! -f "$CONFIG_FILE" ]] && return 1
    local _arr="" _u _p
    while IFS='|' read -r _u _p; do
        [[ -z "$_u" ]] && continue
        [[ -n "$_arr" ]] && _arr+=","
        _arr+="\"${_u}:${_p}\""
    done < <(sqlite3 "$USER_DB" "SELECT username, password FROM users;" 2>/dev/null)
    jq ".auth.config = [${_arr}]" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" 2>/dev/null \
        && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
}

_hyst_restart() {
    systemctl restart hysteria-server 2>/dev/null
    sleep 1
    if systemctl is-active --quiet hysteria-server 2>/dev/null; then
        echo -e "\033[1;32m✓ Hysteria reiniciado correctamente.\033[0m"
    else
        echo -e "\033[1;31m✗ Hysteria no pudo iniciar. Ver: journalctl -u hysteria-server -n 20\033[0m"
    fi
}

_hyst_show_conn_info() {
    local _u="$1" _p="$2"
    local _port; _port=$(jq -r '.listen // ":36712"' "$CONFIG_FILE" 2>/dev/null | tr -d ':')
    local _obfs; _obfs=$(jq -r '.obfs // ""' "$CONFIG_FILE" 2>/dev/null)
    local _ip; _ip=$(cat /etc/IP 2>/dev/null | tr -d '\n')
    [[ -z "$_ip" ]] && _ip=$(hostname -I | awk '{print $1}')
    echo ""
    echo -e "\033[1;33m  ── Datos para la app ──\033[0m"
    echo -e "\033[1;32m  Servidor   : \033[1;37m${_ip}\033[0m"
    echo -e "\033[1;32m  Puerto UDP : \033[1;37m${_port}\033[0m"
    echo -e "\033[1;32m  Obfs (fijo): \033[1;37m${_obfs}\033[0m"
    echo -e "\033[1;32m  Password   : \033[1;37m${_u}:${_p}\033[0m"
    echo -e "\033[1;33m  Insecure   : ON  (cert self-signed)\033[0m"
    echo ""
}

_hyst_add_user() {
    _hyst_header
    echo -e "\033[1;34m── Agregar Usuario ──\033[0m"
    echo -ne "\033[1;32mUsuario    : \033[1;37m"; read -r _usr
    [[ -z "$_usr" ]] && { echo -e "\033[1;31mUsuario vacío.\033[0m"; sleep 1; return; }
    echo -ne "\033[1;32mContraseña : \033[1;37m"; read -r _pass
    [[ -z "$_pass" ]] && { echo -e "\033[1;31mContraseña vacía.\033[0m"; sleep 1; return; }

    sqlite3 "$USER_DB" "INSERT OR REPLACE INTO users (username, password) VALUES ('$_usr', '$_pass');" 2>/dev/null
    _hyst_rebuild_config
    _hyst_restart
    echo -e "\033[1;32m✓ Usuario agregado: $_usr\033[0m"
    _hyst_show_conn_info "$_usr" "$_pass"
    read -p "Presione [Enter] para continuar"
}

_hyst_edit_user() {
    _hyst_header
    echo -e "\033[1;34m── Editar Contraseña ──\033[0m"
    echo -ne "\033[1;32mUsuario a editar : \033[1;37m"; read -r _usr
    [[ -z "$_usr" ]] && return
    echo -ne "\033[1;32mNueva contraseña : \033[1;37m"; read -r _pass
    [[ -z "$_pass" ]] && return
    sqlite3 "$USER_DB" "UPDATE users SET password='$_pass' WHERE username='$_usr';" 2>/dev/null
    _hyst_rebuild_config
    _hyst_restart
    echo -e "\033[1;32m✓ Contraseña actualizada.\033[0m"
    _hyst_show_conn_info "$_usr" "$_pass"
    read -p "Presione [Enter] para continuar"
}

_hyst_delete_user() {
    _hyst_header
    echo -e "\033[1;34m── Eliminar Usuario ──\033[0m"
    echo -ne "\033[1;32mUsuario a eliminar: \033[1;37m"; read -r _usr
    [[ -z "$_usr" ]] && return
    sqlite3 "$USER_DB" "DELETE FROM users WHERE username='$_usr';" 2>/dev/null
    _hyst_rebuild_config
    _hyst_restart
    echo -e "\033[1;32m✓ Usuario eliminado: $_usr\033[0m"
    sleep 2
}

_hyst_show_users() {
    _hyst_header
    echo -e "\033[1;34m── Usuarios Registrados ──\033[0m"
    echo ""
    local _port; _port=$(jq -r '.listen // ":36712"' "$CONFIG_FILE" 2>/dev/null | tr -d ':')
    local _obfs; _obfs=$(jq -r '.obfs // ""' "$CONFIG_FILE" 2>/dev/null)
    local _ip; _ip=$(cat /etc/IP 2>/dev/null | tr -d '\n')
    [[ -z "$_ip" ]] && _ip=$(hostname -I | awk '{print $1}')
    local _count=0
    while IFS='|' read -r _u _p; do
        [[ -z "$_u" ]] && continue
        _count=$((_count+1))
        echo -e "\033[1;36m  [$_count]\033[0m"
        echo -e "\033[1;32m    Usuario    : \033[1;37m$_u\033[0m"
        echo -e "\033[1;32m    Contraseña : \033[1;37m$_p\033[0m"
        echo -e "\033[1;32m    App Pass   : \033[1;37m$_u:$_p\033[0m"
        echo -e "\033[1;32m    Servidor   : \033[1;37m$_ip:$_port  Obfs=$_obfs\033[0m"
        echo ""
    done < <(sqlite3 "$USER_DB" "SELECT username, password FROM users;" 2>/dev/null)
    [[ $_count -eq 0 ]] && echo -e "\033[1;33m  No hay usuarios registrados.\033[0m\n"
    read -p "Presione [Enter] para continuar"
}

_hyst_change_obfs() {
    _hyst_header
    echo -e "\033[1;34m── Cambiar Obfs (fijo global) ──\033[0m"
    local _cur; _cur=$(jq -r '.obfs // "agnudp"' "$CONFIG_FILE" 2>/dev/null)
    echo -e "\033[1;33m  Obfs actual: \033[1;37m$_cur\033[0m"
    echo -e "\033[1;33m  Nota: cambiar el Obfs obliga a todos los clientes\033[0m"
    echo -e "\033[1;33m        a actualizar el campo Obfs en su app.\033[0m"
    echo -ne "\033[1;32mNuevo Obfs: \033[1;37m"; read -r _obfs
    [[ -z "$_obfs" ]] && { echo -e "\033[1;31mObfs vacío.\033[0m"; sleep 1; return; }
    jq ".obfs = \"$_obfs\"" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    _hyst_restart
    echo -e "\033[1;32m✓ Obfs cambiado a: $_obfs\033[0m"
    sleep 2
}

_hyst_change_port() {
    _hyst_header
    echo -e "\033[1;34m── Cambiar Puerto UDP ──\033[0m"
    local _cur; _cur=$(jq -r '.listen // ":36712"' "$CONFIG_FILE" 2>/dev/null | tr -d ':')
    echo -e "\033[1;33m  Puerto actual: \033[1;37m$_cur\033[0m"
    echo -ne "\033[1;32mNuevo puerto UDP: \033[1;37m"; read -r _p
    [[ ! "$_p" =~ ^[0-9]+$ ]] && { echo -e "\033[1;31mPuerto inválido\033[0m"; sleep 2; return; }
    jq ".listen = \":$_p\"" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    iptables -D INPUT -p udp --dport "$_cur" -j ACCEPT 2>/dev/null
    iptables -I INPUT -p udp --dport "$_p"   -j ACCEPT 2>/dev/null
    _hyst_restart
    echo -e "\033[1;32m✓ Puerto cambiado a: $_p\033[0m"
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
    echo -e "\033[1;34m║\033[1;31m[\033[1;36m01\033[1;31m]\033[1;37m Agregar usuario                          \033[1;34m║\033[0m"
    echo -e "\033[1;34m║\033[1;31m[\033[1;36m02\033[1;31m]\033[1;37m Editar contraseña                        \033[1;34m║\033[0m"
    echo -e "\033[1;34m║\033[1;31m[\033[1;36m03\033[1;31m]\033[1;37m Eliminar usuario                         \033[1;34m║\033[0m"
    echo -e "\033[1;34m║\033[1;31m[\033[1;36m04\033[1;31m]\033[1;37m Ver usuarios y datos de conexión         \033[1;34m║\033[0m"
    echo -e "\033[1;34m║\033[1;31m[\033[1;36m05\033[1;31m]\033[1;37m Cambiar Obfs (fijo global)               \033[1;34m║\033[0m"
    echo -e "\033[1;34m║\033[1;31m[\033[1;36m06\033[1;31m]\033[1;37m Cambiar puerto UDP                       \033[1;34m║\033[0m"
    echo -e "\033[1;34m║\033[1;31m[\033[1;36m07\033[1;31m]\033[1;37m Reiniciar servidor                       \033[1;34m║\033[0m"
    echo -e "\033[1;34m║\033[1;31m[\033[1;36m08\033[1;31m]\033[1;37m Desinstalar Hysteria                     \033[1;34m║\033[0m"
    echo -e "\033[1;34m║\033[1;31m[\033[1;36m00\033[1;31m]\033[1;37m Salir                                    \033[1;34m║\033[0m"
    echo -e "\033[1;34m╚══════════════════════════════════════════════════╝\033[0m"
    echo ""
    echo -ne "\033[1;32m¿Qué deseas hacer?: \033[1;37m" && read _ch

    case $_ch in
        1|01) _hyst_add_user;    hyst_menu ;;
        2|02) _hyst_edit_user;   hyst_menu ;;
        3|03) _hyst_delete_user; hyst_menu ;;
        4|04) _hyst_show_users;  hyst_menu ;;
        5|05) _hyst_change_obfs; hyst_menu ;;
        6|06) _hyst_change_port; hyst_menu ;;
        7|07) _hyst_restart;     sleep 2; hyst_menu ;;
        8|08) _hyst_uninstall ;;
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
