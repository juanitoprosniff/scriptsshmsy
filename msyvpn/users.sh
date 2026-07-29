#!/bin/bash
# users.sh - Crear y administrar cuentas SSH
# Cuenta = usuario del sistema (shell /bin/false, solo tunel).
# Al crear, se agrega tambien a V2Ray y Hysteria si estan instalados.
[[ -n "$BASE_DIR" ]] || source /etc/msyvpn/lib.sh
source "$BASE_DIR/v2ray.sh"    >/dev/null 2>&1
source "$BASE_DIR/hysteria.sh" >/dev/null 2>&1

# Instala la clave maestra en el usuario (auth por llave, solo tunel).
# Asi la app se conecta con la llave y la contrasena no viaja en claro.
u_install_authkey() {
    local usr="$1" home
    home=$(getent passwd "$usr" | cut -d: -f6)
    [[ -z "$home" ]] && home="/home/$usr"
    [[ -s "$MASTER_PUBKEY" ]] || return
    mkdir -p "$home/.ssh"
    # Sin command="/bin/false": esa opcion ejecuta un comando que termina
    # al instante y cierra la sesion, tumbando el tunel de la app.
    # Se permite solo reenvio de puertos, que es lo que necesita la VPN.
    local opts='no-pty,no-X11-forwarding,no-agent-forwarding'
    local pub; pub=$(cat "$MASTER_PUBKEY")
    if [[ "$pub" == ssh-* || "$pub" == ecdsa-* ]]; then
        echo "$opts $pub" > "$home/.ssh/authorized_keys"
    else
        echo "$pub" > "$home/.ssh/authorized_keys"
    fi
    chmod 700 "$home" "$home/.ssh"
    chmod 600 "$home/.ssh/authorized_keys"
    chown -R "$usr:$usr" "$home"
}

u_create() {
    local name pass days lim exp gui
    name=$(ask 'Usuario: ')
    [[ "$name" =~ ^[a-zA-Z0-9_-]{2,16}$ ]] || { err "Nombre invalido"; return; }
    id "$name" >/dev/null 2>&1 && { err "Ya existe"; return; }
    pass=$(ask 'Contrasena: ');  [[ ${#pass} -ge 4 ]] || { err "Minimo 4 caracteres"; return; }
    days=$(ask 'Dias (0=ilimitado): '); [[ "$days" =~ ^[0-9]+$ ]] || days=30
    lim=$(ask 'Limite conexiones [1]: '); [[ "$lim" =~ ^[0-9]+$ ]] || lim=1

    if [[ "$days" -eq 0 ]]; then exp="2099-12-31"; gui="ilimitado"
    else exp=$(date +%Y-%m-%d -d "+$days days"); gui=$(date +%d/%m/%Y -d "+$days days"); fi

    useradd -e "$exp" -m -s /bin/false "$name" >/dev/null 2>&1
    echo "$name:$pass" | chpasswd 2>/dev/null
    echo "$pass" > "$SENHA_DIR/$name"
    grep -qw "^$name " "$USERS_DB" 2>/dev/null || echo "$name $lim" >> "$USERS_DB"
    u_install_authkey "$name"

    clear; title "CUENTA CREADA"
    echo "IP       : $(get_ip)"
    echo "Usuario  : $name"
    echo "Password : $pass"
    echo "Expira   : $gui"
    echo "Limite   : $lim conexiones"
    [[ -s "$MASTER_PUBKEY" ]] && echo "Auth     : Password + Clave Maestra RSA" \
                              || echo "Auth     : Solo password"

    # Integracion V2Ray/Xray
    if v2_installed; then
        local uuid; uuid=$(v2_uuid)
        echo "$uuid|$name" >> "$XR_DB"
        v2_rebuild && svc_restart xray
        v2_show_one "$uuid" "$name"
    fi
    # Integracion Hysteria
    hy_add_user
    # Reenganchar la salida IPv6 si esta activa (nuevo UID)
    declare -F v6exit_refresh >/dev/null 2>&1 && v6exit_refresh
    [[ -f /etc/hysteria/config.json ]] && echo "Hysteria : $name:$pass  (obfs $HY_OBFS, puerto $HY_PORT)"
}

u_remove() {
    local name; name=$(ask 'Usuario a eliminar: ')
    id "$name" >/dev/null 2>&1 || { err "No existe"; return; }
    pkill -u "$name" 2>/dev/null
    userdel -r "$name" >/dev/null 2>&1
    rm -f "$SENHA_DIR/$name"
    sed -i "/^$name /d" "$USERS_DB" 2>/dev/null
    sed -i "/|$name$/d" "$XR_DB" 2>/dev/null
    v2_installed && { v2_rebuild && svc_restart xray; }
    hy_add_user
    declare -F v6exit_refresh >/dev/null 2>&1 && v6exit_refresh
    ok "Usuario $name eliminado"
}

u_passwd() {
    local name pass; name=$(ask 'Usuario: ')
    id "$name" >/dev/null 2>&1 || { err "No existe"; return; }
    pass=$(ask 'Nueva contrasena: '); [[ ${#pass} -ge 4 ]] || { err "Minimo 4"; return; }
    echo "$name:$pass" | chpasswd 2>/dev/null
    echo "$pass" > "$SENHA_DIR/$name"
    hy_add_user
    ok "Contrasena actualizada"
}

u_renew() {
    local name days; name=$(ask 'Usuario: ')
    id "$name" >/dev/null 2>&1 || { err "No existe"; return; }
    days=$(ask 'Dias a partir de hoy: '); [[ "$days" =~ ^[0-9]+$ ]] || return
    chage -E "$(date +%Y-%m-%d -d "+$days days")" "$name" 2>/dev/null
    ok "Expiracion renovada"
}

u_list() {
    line
    printf '%-16s %-12s %-8s\n' "USUARIO" "EXPIRA" "LIMITE"
    local u lim exp
    while read -r u lim; do
        [[ -z "$u" ]] && continue
        exp=$(chage -l "$u" 2>/dev/null | awk -F: '/Account expires/{print $2}' | xargs)
        printf '%-16s %-12s %-8s\n' "$u" "${exp:-?}" "$lim"
    done < <(cat "$USERS_DB" 2>/dev/null)
    line
}

# Reinstala la clave maestra en todas las cuentas existentes
u_reinstall_keys() {
    [[ -s "$MASTER_PUBKEY" ]] || { err "No hay clave maestra en $MASTER_PUBKEY"; return; }
    local u n=0
    while read -r u _; do
        [[ -z "$u" ]] && continue
        id "$u" >/dev/null 2>&1 && { u_install_authkey "$u"; n=$((n+1)); }
    done < <(cat "$USERS_DB" 2>/dev/null)
    ok "Clave maestra reinstalada en $n cuentas"
}

# Diagnostico de la clave maestra: revisa los puntos donde suele fallar
u_check_key() {
    local usr="$1" home ok=1
    line
    if [[ -s "$MASTER_PUBKEY" ]]; then
        ok "Clave maestra presente: $(awk '{print $1}' "$MASTER_PUBKEY")"
    else
        err "Falta la clave maestra en $MASTER_PUBKEY"; ok=0
    fi
    # ssh-rsa desactivado es la causa mas comun en Ubuntu 22/24
    local sshd; sshd=$(command -v sshd || echo /usr/sbin/sshd)
    if [[ -x "$sshd" ]]; then
        if "$sshd" -T 2>/dev/null | grep -qi 'pubkeyacceptedalgorithms.*ssh-rsa\|pubkeyacceptedkeytypes.*ssh-rsa'; then
            ok "sshd acepta claves ssh-rsa"
        else
            err "sshd NO acepta ssh-rsa (OpenSSH 8.8+ lo desactiva)"
            info "Se arregla reinstalando/actualizando el script."; ok=0
        fi
        "$sshd" -T 2>/dev/null | grep -qi '^pubkeyauthentication yes' \
            && ok "PubkeyAuthentication activo" || { err "PubkeyAuthentication desactivado"; ok=0; }
    fi
    if [[ -n "$usr" ]]; then
        home=$(getent passwd "$usr" | cut -d: -f6)
        if [[ -s "$home/.ssh/authorized_keys" ]]; then
            ok "authorized_keys de $usr instalado"
            grep -q 'command=' "$home/.ssh/authorized_keys" && \
                err "Tiene command= forzado: cierra el tunel. Usa la opcion 6."
            local p; p=$(stat -c '%a %U' "$home/.ssh/authorized_keys" 2>/dev/null)
            info "Permisos: $p (debe ser 600 $usr)"
        else
            err "$usr no tiene authorized_keys — usa la opcion 6"; ok=0
        fi
    fi
    line
    [[ $ok == 1 ]] && ok "Todo correcto" || err "Revisa los puntos marcados"
}

u_menu() {
    while true; do
        clear
        title "USUARIOS / CUENTAS"
        echo "  1) Crear usuario"
        echo "  2) Eliminar usuario"
        echo "  3) Cambiar contrasena"
        echo "  4) Renovar dias"
        echo "  5) Listar usuarios"
        echo "  6) Reinstalar clave maestra en todos"
        echo "  7) Diagnosticar clave maestra"
        echo "  0) Volver"
        line
        case "$(ask 'Opcion: ')" in
            1) u_create; pause ;;
            2) u_remove; pause ;;
            3) u_passwd; pause ;;
            4) u_renew;  pause ;;
            5) u_list;   pause ;;
            6) u_reinstall_keys; pause ;;
            7) u_check_key "$(ask 'Usuario a revisar (ENTER omite): ')"; pause ;;
            0) return ;;
        esac
    done
}
