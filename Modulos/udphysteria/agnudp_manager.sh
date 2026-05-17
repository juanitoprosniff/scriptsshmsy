#!/bin/bash
# ============================================================
# UDP Hysteria Manager — MSYVPN-SCRIPT
# Acceso: escribir 'agnudp' o 'hysteria-manager' en la terminal
# ============================================================

CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="$CONFIG_DIR/config.json"
USER_DB="$CONFIG_DIR/udpusers.db"

_hyst_header() {
    clear
    echo -e "\033[1;34m╔══════════════════════════════════════════════════╗\033[0m"
    tput setaf 7 ; tput setab 4 ; tput bold ; printf '%52s%s%-12s\n' "   UDP HYSTERIA MANAGER — MSYVPN   " ; tput sgr0
    echo -e "\033[1;34m╚══════════════════════════════════════════════════╝\033[0m"

    local _port="" _obfs="" _status=""
    [[ -f "$CONFIG_FILE" ]] && {
        _port=$(jq -r '.listen // ":36712"' "$CONFIG_FILE" 2>/dev/null | tr -d ':')
        _obfs=$(jq -r '.obfs // "agnudp"' "$CONFIG_FILE" 2>/dev/null)
    }
    if systemctl is-active --quiet hysteria-server 2>/dev/null; then
        _status="\033[1;32m● ACTIVO\033[0m"
    else
        _status="\033[1;31m○ INACTIVO\033[0m"
    fi

    local _ip; _ip=$(cat /etc/IP 2>/dev/null | tr -d '\n' || hostname -I | awk '{print $1}')
    echo -e "\033[1;33m  Estado   : $_status"
    [[ -n "$_ip" ]]   && echo -e "\033[1;33m  IP       : \033[1;37m$_ip\033[0m"
    [[ -n "$_port" ]] && echo -e "\033[1;33m  Puerto   : \033[1;37m$_port (UDP)\033[0m"
    [[ -n "$_obfs" ]] && echo -e "\033[1;33m  Obfs     : \033[1;37m$_obfs\033[0m"
    echo ""
}

_hyst_fetch_users() {
    [[ -f "$USER_DB" ]] && sqlite3 "$USER_DB" "SELECT username || ':' || password FROM users;" | paste -sd, - 2>/dev/null
}

_hyst_rebuild_config() {
    [[ ! -f "$CONFIG_FILE" ]] && return 1
    local _users; _users=$(_hyst_fetch_users)
    [[ -z "$_users" ]] && return 0
    local _arr; _arr=$(echo "$_users" | awk -F, '{for(i=1;i<=NF;i++){if(i>1)printf ","; printf "\"%s\"",$i}; print ""}')
    jq ".auth.config = [$_arr]" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" 2>/dev/null && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
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

_hyst_add_user() {
    echo -e "\033[1;34m── Agregar Usuario ──\033[0m"
    echo -ne "\033[1;32mUsuario: \033[1;37m"; read -r _usr
    [[ -z "$_usr" ]] && { echo -e "\033[1;31mUsuario vacío.\033[0m"; return; }
    echo -ne "\033[1;32mContraseña: \033[1;37m"; read -r _pass
    [[ -z "$_pass" ]] && { echo -e "\033[1;31mContraseña vacía.\033[0m"; return; }

    sqlite3 "$USER_DB" "INSERT OR REPLACE INTO users (username, password) VALUES ('$_usr', '$_pass');" 2>/dev/null
    _hyst_rebuild_config
    _hyst_restart

    local _port; _port=$(jq -r '.listen // ":36712"' "$CONFIG_FILE" 2>/dev/null | tr -d ':')
    local _obfs; _obfs=$(jq -r '.obfs // "agnudp"' "$CONFIG_FILE" 2>/dev/null)
    local _ip; _ip=$(cat /etc/IP 2>/dev/null | tr -d '\n' || hostname -I | awk '{print $1}')
    echo ""
    echo -e "\033[1;32m✓ Usuario agregado: $_usr\033[0m"
    echo ""
    echo -e "\033[1;33m  Datos de conexión:\033[0m"
    echo -e "\033[1;32m  IP       : \033[1;37m${_ip}\033[0m"
    echo -e "\033[1;32m  Puerto   : \033[1;37m${_port}\033[0m"
    echo -e "\033[1;32m  Obfs     : \033[1;37m${_obfs}\033[0m"
    echo -e "\033[1;32m  Usuario  : \033[1;37m${_usr}\033[0m"
    echo -e "\033[1;32m  Contraseña: \033[1;37m${_pass}\033[0m"
    echo ""
    read -p "Presione [Enter] para continuar"
}

_hyst_edit_user() {
    echo -e "\033[1;34m── Editar Contraseña ──\033[0m"
    echo -ne "\033[1;32mUsuario a editar: \033[1;37m"; read -r _usr
    echo -ne "\033[1;32mNueva contraseña: \033[1;37m"; read -r _pass
    sqlite3 "$USER_DB" "UPDATE users SET password='$_pass' WHERE username='$_usr';" 2>/dev/null
    _hyst_rebuild_config; _hyst_restart
    echo -e "\033[1;32m✓ Contraseña actualizada.\033[0m"
    sleep 2
}

_hyst_delete_user() {
    echo -e "\033[1;34m── Eliminar Usuario ──\033[0m"
    echo -ne "\033[1;32mUsuario a eliminar: \033[1;37m"; read -r _usr
    sqlite3 "$USER_DB" "DELETE FROM users WHERE username='$_usr';" 2>/dev/null
    _hyst_rebuild_config; _hyst_restart
    echo -e "\033[1;32m✓ Usuario eliminado.\033[0m"
    sleep 2
}

_hyst_show_users() {
    echo -e "\033[1;34m── Usuarios Registrados ──\033[0m"
    echo ""
    local _port; _port=$(jq -r '.listen // ":36712"' "$CONFIG_FILE" 2>/dev/null | tr -d ':')
    local _obfs; _obfs=$(jq -r '.obfs // "agnudp"' "$CONFIG_FILE" 2>/dev/null)
    local _ip; _ip=$(cat /etc/IP 2>/dev/null | tr -d '\n' || hostname -I | awk '{print $1}')
    sqlite3 "$USER_DB" "SELECT username, password FROM users;" 2>/dev/null | while IFS='|' read -r _u _p; do
        echo -e "\033[1;32m  Usuario : \033[1;37m$_u\033[0m"
        echo -e "\033[1;32m  Pass    : \033[1;37m$_p\033[0m"
        echo -e "\033[1;32m  Conexión: \033[1;37m$_ip:$_port  Obfs=$_obfs  User=$_u  Pass=$_p\033[0m"
        echo ""
    done
    read -p "Presione [Enter] para continuar"
}

_hyst_change_obfs() {
    echo -ne "\033[1;32mNuevo valor de Obfs: \033[1;37m"; read -r _obfs
    jq ".obfs = \"$_obfs\"" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    _hyst_restart
    echo -e "\033[1;32m✓ Obfs cambiado a: $_obfs\033[0m"; sleep 2
}

_hyst_change_port() {
    echo -ne "\033[1;32mNuevo puerto UDP (ej: 36712): \033[1;37m"; read -r _p
    [[ ! "$_p" =~ ^[0-9]+$ ]] && { echo "Puerto inválido"; sleep 2; return; }
    jq ".listen = \":$_p\"" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    _hyst_restart
    echo -e "\033[1;32m✓ Puerto cambiado a: $_p\033[0m"; sleep 2
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
    sleep 2; exit 0
}

hyst_menu() {
    _hyst_header
    echo -e "\033[1;34m╔══════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;34m║\033[1;31m[\033[1;36m01\033[1;31m]\033[1;37m Agregar usuario                          \033[1;34m║\033[0m"
    echo -e "\033[1;34m║\033[1;31m[\033[1;36m02\033[1;31m]\033[1;37m Editar contraseña                        \033[1;34m║\033[0m"
    echo -e "\033[1;34m║\033[1;31m[\033[1;36m03\033[1;31m]\033[1;37m Eliminar usuario                         \033[1;34m║\033[0m"
    echo -e "\033[1;34m║\033[1;31m[\033[1;36m04\033[1;31m]\033[1;37m Ver usuarios y datos de conexión         \033[1;34m║\033[0m"
    echo -e "\033[1;34m║\033[1;31m[\033[1;36m05\033[1;31m]\033[1;37m Cambiar Obfs                             \033[1;34m║\033[0m"
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

# Verificar que esté instalado
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "\033[1;31m✗ Hysteria no está instalado.\033[0m"
    echo -e "\033[1;33m  Instálalo desde el menú principal → opción 18\033[0m"
    exit 1
fi

# Verificar sqlite3
if ! command -v sqlite3 &>/dev/null; then
    apt-get install -y sqlite3 >/dev/null 2>&1
fi

hyst_menu
