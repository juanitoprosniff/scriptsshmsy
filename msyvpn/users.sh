#!/bin/bash
# users.sh - Crear y administrar cuentas SSH
# Cuenta = usuario del sistema (shell /bin/false, solo tunel).
# Al crear, se agrega tambien a V2Ray y Hysteria si estan instalados.
[[ -n "$BASE_DIR" ]] || source /etc/msyvpn/lib.sh
source "$BASE_DIR/v2ray.sh"    >/dev/null 2>&1
source "$BASE_DIR/hysteria.sh" >/dev/null 2>&1

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

    useradd -e "$exp" -M -s /bin/false "$name" >/dev/null 2>&1
    echo "$name:$pass" | chpasswd 2>/dev/null
    echo "$pass" > "$SENHA_DIR/$name"
    grep -qw "^$name " "$USERS_DB" 2>/dev/null || echo "$name $lim" >> "$USERS_DB"

    clear; title "CUENTA CREADA"
    echo "IP       : $(get_ip)"
    echo "Usuario  : $name"
    echo "Password : $pass"
    echo "Expira   : $gui"
    echo "Limite   : $lim conexiones"

    # Integracion V2Ray
    if v2_installed; then
        local uuid; uuid=$(v2_uuid)
        echo "$uuid|$name" >> "$V2_DB"
        v2_rebuild; svc_restart v2ray
        v2_show_one "$uuid" "$name"
    fi
    # Integracion Hysteria
    hy_add_user
    [[ -f /etc/hysteria/config.json ]] && echo "Hysteria : $name:$pass  (obfs $HY_OBFS, puerto $HY_PORT)"
}

u_remove() {
    local name; name=$(ask 'Usuario a eliminar: ')
    id "$name" >/dev/null 2>&1 || { err "No existe"; return; }
    pkill -u "$name" 2>/dev/null
    userdel -r "$name" >/dev/null 2>&1
    rm -f "$SENHA_DIR/$name"
    sed -i "/^$name /d" "$USERS_DB" 2>/dev/null
    sed -i "/|$name$/d" "$V2_DB" 2>/dev/null
    v2_installed && { v2_rebuild; svc_restart v2ray; }
    hy_add_user
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

u_menu() {
    while true; do
        clear
        title "USUARIOS / CUENTAS"
        echo "  1) Crear usuario"
        echo "  2) Eliminar usuario"
        echo "  3) Cambiar contrasena"
        echo "  4) Renovar dias"
        echo "  5) Listar usuarios"
        echo "  0) Volver"
        line
        case "$(ask 'Opcion: ')" in
            1) u_create; pause ;;
            2) u_remove; pause ;;
            3) u_passwd; pause ;;
            4) u_renew;  pause ;;
            5) u_list;   pause ;;
            0) return ;;
        esac
    done
}
