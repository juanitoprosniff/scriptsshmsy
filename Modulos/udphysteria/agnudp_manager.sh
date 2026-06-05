#!/bin/bash
# ============================================================
# UDP Hysteria v1 Manager — MSYVPN-SCRIPT
# Acceso: 'agnudp' desde la terminal
# ============================================================

CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="$CONFIG_DIR/config.json"
USER_DB="$CONFIG_DIR/udpusers.db"

_R='\033[1;31m'; _G='\033[1;32m'; _Y='\033[1;33m'; _B='\033[1;34m'; _W='\033[1;37m'; _N='\033[0m'

# ── Reconstruir auth.config desde usuarios MSYVPN ────────────
# Lee /etc/SSHPlus/senha/ (creados con criarusuario.sh)
# Si no hay ninguno, usa la BD SQLite como fallback.
_hyst_rebuild_config() {
    local _arr="" _u _p

    if [[ -d /etc/SSHPlus/senha ]]; then
        for _f in /etc/SSHPlus/senha/*; do
            [[ -f "$_f" ]] || continue
            _u=$(basename "$_f")
            _p=$(cat "$_f" 2>/dev/null | tr -d '\n')
            [[ -z "$_u" || -z "$_p" ]] && continue
            id "$_u" &>/dev/null || continue
            sqlite3 "$USER_DB" \
                "INSERT OR REPLACE INTO users (username,password) VALUES ('$_u','$_p');" 2>/dev/null
            [[ -n "$_arr" ]] && _arr+=","
            _arr+="\"${_u}:${_p}\""
        done
    fi

    if [[ -z "$_arr" && -f "$USER_DB" ]]; then
        local _line
        while IFS= read -r _line; do
            [[ -z "$_line" ]] && continue
            [[ -n "$_arr" ]] && _arr+=","
            _arr+="\"$_line\""
        done < <(sqlite3 "$USER_DB" "SELECT username||':'||password FROM users;" 2>/dev/null)
    fi

    [[ -z "$_arr" ]] && return 1

    jq ".auth.config = [${_arr}]" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" 2>/dev/null && \
        mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    systemctl restart hysteria-server 2>/dev/null
    return 0
}

_hyst_header() {
    clear
    echo -e "${_B}╔══════════════════════════════════════════════════╗${_N}"
    echo -e "${_B}║      ${_W} UDP HYSTERIA v1 MANAGER — MSYVPN        ${_B}║${_N}"
    echo -e "${_B}╚══════════════════════════════════════════════════╝${_N}"

    local _port="" _obfs=""
    [[ -f "$CONFIG_FILE" ]] && {
        _port=$(jq -r '.listen // ":36712"' "$CONFIG_FILE" 2>/dev/null | tr -d ':')
        _obfs=$(jq -r '.obfs // "agnudp"' "$CONFIG_FILE" 2>/dev/null)
    }

    local _status
    if systemctl is-active --quiet hysteria-server 2>/dev/null; then
        _status="${_G}● ACTIVO${_N}"
    else
        _status="${_R}○ INACTIVO${_N}"
    fi

    local _ip; _ip=$(cat /etc/IP 2>/dev/null | tr -d '\n')
    [[ -z "$_ip" ]] && _ip=$(hostname -I | awk '{print $1}')

    local _ucount=0
    [[ -f "$USER_DB" ]] && _ucount=$(sqlite3 "$USER_DB" "SELECT COUNT(*) FROM users;" 2>/dev/null)

    echo -e "${_Y}  Estado     : $_status"
    [[ -n "$_ip" ]]   && echo -e "${_Y}  IP         : ${_W}$_ip${_N}"
    [[ -n "$_port" ]] && echo -e "${_Y}  Puerto UDP : ${_W}$_port${_N}"
    echo -e "${_Y}  Obfs       : ${_W}${_obfs}${_N}"
    echo -e "${_Y}  Usuarios   : ${_W}${_ucount:-0}${_N}"
    echo ""
}

_hyst_change_obfs() {
    _hyst_header
    echo -e "${_B}── Cambiar Obfs ──${_N}"
    local _cur; _cur=$(jq -r '.obfs // "agnudp"' "$CONFIG_FILE" 2>/dev/null)
    echo -e "${_Y}  Obfs actual: ${_W}$_cur${_N}"
    echo -e "${_Y}  ¡Aviso! Todos los usuarios deben actualizar el Obfs en su app.${_N}"
    echo -ne "${_G}Nuevo Obfs: ${_W}"; read -r _obfs
    [[ -z "$_obfs" ]] && { echo -e "${_R}Obfs vacío.${_N}"; sleep 1; return; }
    jq ".obfs = \"$_obfs\"" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    systemctl restart hysteria-server 2>/dev/null
    sleep 1
    echo -e "${_G}✓ Obfs cambiado a: $_obfs${_N}"
    sleep 2
}

_hyst_show_users() {
    _hyst_header
    echo -e "${_B}── Usuarios activos ──${_N}"
    echo ""
    if [[ -d /etc/SSHPlus/senha ]]; then
        local _count=0
        for _f in /etc/SSHPlus/senha/*; do
            [[ -f "$_f" ]] || continue
            local _u; _u=$(basename "$_f")
            id "$_u" &>/dev/null || continue
            echo -e "  ${_G}✓${_N} $_u"
            ((_count++))
        done
        [[ $_count -eq 0 ]] && echo -e "  ${_Y}Sin usuarios MSYVPN. Usa criarusuario para crear.${_N}"
    else
        echo -e "  ${_Y}/etc/SSHPlus/senha/ no existe.${_N}"
    fi
    echo ""
    echo -ne "${_Y}Presiona ENTER para volver...${_N}"; read
}

_hyst_uninstall() {
    echo -ne "${_R}¿Seguro que deseas desinstalar Hysteria? [s/N]: ${_W}"; read _c
    [[ ! "$_c" =~ ^[sSyY]$ ]] && return
    systemctl stop hysteria-server 2>/dev/null
    systemctl disable hysteria-server 2>/dev/null
    rm -f /etc/systemd/system/hysteria-server.service \
          /etc/systemd/system/hysteria-server@.service \
          /usr/local/bin/hysteria
    systemctl daemon-reload 2>/dev/null
    rm -rf "$CONFIG_DIR"
    rm -f /usr/local/bin/hysteria-manager /usr/local/bin/agnudp
    echo -e "${_G}✓ Hysteria desinstalado.${_N}"
    sleep 2
    exit 0
}

hyst_menu() {
    _hyst_header
    echo -e "${_B}╔══════════════════════════════════════════════════╗${_N}"
    echo -e "${_B}║${_R}[${_Y}01${_R}]${_W} Reiniciar UDP                            ${_B}║${_N}"
    echo -e "${_B}║${_R}[${_Y}02${_R}]${_W} Detener UDP                              ${_B}║${_N}"
    echo -e "${_B}║${_R}[${_Y}03${_R}]${_W} Iniciar UDP                              ${_B}║${_N}"
    echo -e "${_B}║${_R}[${_Y}04${_R}]${_W} Cambiar Obfs                             ${_B}║${_N}"
    echo -e "${_B}║${_R}[${_Y}05${_R}]${_W} Ver usuarios                             ${_B}║${_N}"
    echo -e "${_B}║${_R}[${_Y}06${_R}]${_W} Sincronizar usuarios MSYVPN              ${_B}║${_N}"
    echo -e "${_B}║${_R}[${_Y}07${_R}]${_W} Desinstalar Hysteria                     ${_B}║${_N}"
    echo -e "${_B}║${_R}[${_Y}00${_R}]${_W} Salir                                    ${_B}║${_N}"
    echo -e "${_B}╚══════════════════════════════════════════════════╝${_N}"
    echo ""
    echo -ne "${_G}¿Qué deseas hacer?: ${_W}" && read _ch

    case $_ch in
        1|01)
            systemctl restart hysteria-server 2>/dev/null; sleep 1
            systemctl is-active --quiet hysteria-server && \
                echo -e "${_G}✓ Hysteria reiniciado.${_N}" || \
                echo -e "${_R}✗ No pudo iniciar.${_N}"
            sleep 2; hyst_menu ;;
        2|02)
            systemctl stop hysteria-server 2>/dev/null
            echo -e "${_Y}● Hysteria detenido.${_N}"; sleep 2; hyst_menu ;;
        3|03)
            systemctl start hysteria-server 2>/dev/null; sleep 1
            systemctl is-active --quiet hysteria-server && \
                echo -e "${_G}✓ Hysteria iniciado.${_N}" || \
                echo -e "${_R}✗ No pudo iniciar — ver: journalctl -u hysteria-server -n 20${_N}"
            sleep 2; hyst_menu ;;
        4|04) _hyst_change_obfs; hyst_menu ;;
        5|05) _hyst_show_users; hyst_menu ;;
        6|06)
            echo -e "${_Y}Sincronizando usuarios desde /etc/SSHPlus/senha/...${_N}"
            _hyst_rebuild_config && \
                echo -e "${_G}✓ Usuarios sincronizados y Hysteria reiniciado.${_N}" || \
                echo -e "${_R}✗ No se encontraron usuarios MSYVPN válidos.${_N}"
            sleep 2; hyst_menu ;;
        7|07) _hyst_uninstall ;;
        0|00) exit 0 ;;
        *) echo -e "${_R}Opción inválida${_N}"; sleep 1; hyst_menu ;;
    esac
}

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${_R}✗ Hysteria no está instalado.${_N}"
    echo -e "${_Y}  Instálalo desde el menú principal → opción 18${_N}"
    exit 1
fi

command -v sqlite3 &>/dev/null || apt-get install -y sqlite3 >/dev/null 2>&1
command -v jq     &>/dev/null || apt-get install -y jq      >/dev/null 2>&1

hyst_menu
