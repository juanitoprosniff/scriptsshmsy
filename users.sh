#!/bin/bash
# users.sh - Crear y administrar cuentas SSH
# Creado y modificado por t:me/JuanitoProSniif
# Cuenta = usuario del sistema (shell /bin/false, solo tunel).
# Al crear, se agrega tambien a V2Ray y Hysteria si estan instalados.
[[ -n "$BASE_DIR" ]] || source /etc/msyvpn/lib.sh
source "$BASE_DIR/v2ray.sh"       >/dev/null 2>&1
source "$BASE_DIR/hysteria.sh"    >/dev/null 2>&1
source "$BASE_DIR/shadowsocks.sh" >/dev/null 2>&1
source "$BASE_DIR/wireguard.sh"   >/dev/null 2>&1
source "$BASE_DIR/openvpn.sh"     >/dev/null 2>&1
source "$BASE_DIR/socks5.sh"      >/dev/null 2>&1

# Muestra las credenciales del usuario en cada protocolo instalado
u_show_protocols() {
    local name="$1" pass="$2" ip; ip=$(get_ip)
    if hy_installed 1 || hy_installed 2; then
        line; echo "== UDP HYSTERIA (auth = usuario:contrasena) =="
        hy_installed 1 && echo "  v1  $ip:$(hy_port 1)  obfs:$(hy_obfs 1)  auth: $name:$pass"
        hy_installed 2 && echo "  v2  $ip:$(hy_port 2)  obfs:$(hy_obfs 2)  auth: $name:$pass"
    fi
    if ss_installed && [[ -f "$SS_CFG" ]]; then
        line; echo "== SHADOWSOCKS (compartido) =="
        echo "  $(ss_link)"
    fi
    if wg_installed; then
        line; echo "== WIREGUARD ($name) =="
        wg_create_peer "$name" && wg_show_client "$name"
    fi
    if ov_installed; then
        line; echo "== OPENVPN (mismo usuario y contrasena) =="
        echo "  Usuario: $name    Contrasena: $pass"
        echo "  Perfiles en $OV_CLIENTS/ (udp / tcp / auto)"
        echo "  scp root@$ip:$OV_CLIENTS/'*.ovpn' ."
    fi
    line
}

# Instala la clave maestra en el usuario. Devuelve 0 si todo OK, 1 si no.
# Fuerza permisos correctos y verifica que sshd los aceptara (StrictModes).
u_install_authkey() {
    local usr="$1" home
    id "$usr" >/dev/null 2>&1 || { err "u_install_authkey: $usr no existe"; return 1; }
    [[ -s "$MASTER_PUBKEY" ]] || return 1
    home=$(getent passwd "$usr" | cut -d: -f6)
    [[ -z "$home" ]] && home="/home/$usr"

    # BUG posible: useradd -m puede fallar en silencio. Crear el home si falta.
    if [[ ! -d "$home" ]]; then
        mkdir -p "$home"
        chown "$usr:$usr" "$home" 2>/dev/null
    fi
    # /home debe ser accesible por sshd (a veces queda 750 y sshd falla)
    chmod 755 /home 2>/dev/null

    mkdir -p "$home/.ssh"
    local opts='no-pty,no-X11-forwarding,no-agent-forwarding'
    local pub; pub=$(cat "$MASTER_PUBKEY")
    if [[ "$pub" == ssh-* || "$pub" == ecdsa-* ]]; then
        echo "$opts $pub" > "$home/.ssh/authorized_keys"
    else
        echo "$pub" > "$home/.ssh/authorized_keys"
    fi
    # Permisos exactos que exige StrictModes de sshd
    chown "$usr:$usr" "$home"
    chmod 750 "$home"
    chown "$usr:$usr" "$home/.ssh"
    chmod 700 "$home/.ssh"
    chown "$usr:$usr" "$home/.ssh/authorized_keys"
    chmod 600 "$home/.ssh/authorized_keys"

    # Verificacion real: el archivo debe existir con dueno correcto
    local own; own=$(stat -c '%U' "$home/.ssh/authorized_keys" 2>/dev/null)
    if [[ "$own" != "$usr" ]]; then
        err "authorized_keys de $usr NO quedo con dueno correcto (es $own)"
        return 1
    fi
    return 0
}

u_create() {
    local name pass days lim exp gui
    name=$(ask 'Usuario: ')
    [[ "$name" =~ ^[a-zA-Z0-9_-]{2,16}$ ]] || { err "Nombre invalido"; return; }
    id "$name" >/dev/null 2>&1 && { err "Ya existe"; return; }
    pass=$(ask 'Contrasena: ');  [[ ${#pass} -ge 12 ]] || { err "Minimo 12 caracteres"; return; }
    days=$(ask 'Dias (0=ilimitado): '); [[ "$days" =~ ^[0-9]+$ ]] || days=30
    lim=$(ask 'Limite conexiones [1]: '); [[ "$lim" =~ ^[0-9]+$ ]] || lim=1

    if [[ "$days" -eq 0 ]]; then exp="2099-12-31"; gui="ilimitado"
    else exp=$(date +%Y-%m-%d -d "+$days days"); gui=$(date +%d/%m/%Y -d "+$days days"); fi

    # Crear usuario y home de forma robusta (no depender solo de -m)
    useradd -e "$exp" -m -s /bin/false "$name" 2>/tmp/msyua.log
    if ! id "$name" >/dev/null 2>&1; then
        err "useradd fallo:"; cat /tmp/msyua.log; return
    fi
    # Si -m no creo el home (algunos entornos), crearlo a mano
    [[ -d /home/$name ]] || { mkdir -p /home/$name; chown "$name:$name" /home/$name; }
    echo "$name:$pass" | chpasswd 2>/dev/null
    echo "$pass" > "$SENHA_DIR/$name"
    grep -qw "^$name " "$USERS_DB" 2>/dev/null || echo "$name $lim" >> "$USERS_DB"

    # Instalar la clave maestra y verificar. Si falla, avisar (no continuar
    # a ciegas como antes: era el bug de 'usuarios nuevos no conectan').
    if [[ -s "$MASTER_PUBKEY" ]]; then
        if u_install_authkey "$name"; then
            ok "Clave maestra instalada en $name"
        else
            err "La clave maestra NO se instalo bien en $name"
            info "Prueba: menu -> Usuarios -> 7) Diagnosticar clave maestra"
        fi
    fi

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
    # Integracion Hysteria (auth = usuario:contrasena)
    hy_add_user
    # SOCKS5: mismas credenciales. Recarga en caliente, sin cortar a nadie.
    s5_reload_auth 2>/dev/null
    # Credenciales/enlaces de todos los protocolos instalados
    u_show_protocols "$name" "$pass"
}

u_remove() {
    local name; name=$(ask 'Usuario a eliminar: ')
    id "$name" >/dev/null 2>&1 || { err "No existe"; return; }

    # BUG que arregla este bloque: pkill (sin senal) manda SIGTERM y
    # sigue de inmediato a userdel, pero un tunel con trafico en curso
    # puede quedar en estado D (esperando I/O) y no morir al instante.
    # userdel entonces fallaba (usuario con procesos vivos = "user busy"),
    # el error quedaba oculto por el ">/dev/null 2>&1", y el script decia
    # "eliminado" aunque el usuario seguia existiendo: seguia pudiendo
    # conectar, no aparecia como recien creado si lo volvias a crear
    # (useradd fallaba por "ya existe") y no habia forma de saber por que.
    #
    # Ahora: SIGTERM, esperar hasta 5s revisando de verdad que ya no haya
    # procesos, y solo si alguno se resiste usar SIGKILL. Recien despues
    # se llama userdel, y se comprueba que de verdad borro al usuario.
    pkill -TERM -u "$name" 2>/dev/null
    local intentos=0
    while pgrep -u "$name" >/dev/null 2>&1 && [[ $intentos -lt 10 ]]; do
        sleep 0.5
        intentos=$((intentos+1))
    done
    pgrep -u "$name" >/dev/null 2>&1 && pkill -KILL -u "$name" 2>/dev/null && sleep 0.5

    userdel -r "$name" >/tmp/msyud.log 2>&1
    if id "$name" >/dev/null 2>&1; then
        # userdel fallo de verdad: no seguir como si hubiera funcionado.
        err "No se pudo eliminar $name del sistema:"
        cat /tmp/msyud.log
        info "Procesos restantes de $name: $(pgrep -c -u "$name" 2>/dev/null || echo 0)"
        info "Vuelve a intentar la opcion 2, o revisa 'ps -u $name' a mano."
        return 1
    fi

    rm -f "$SENHA_DIR/$name"
    sed -i "/^$name /d" "$USERS_DB" 2>/dev/null
    sed -i "/|$name$/d" "$XR_DB" 2>/dev/null
    v2_installed && { v2_rebuild && svc_restart xray; }
    hy_add_user
    s5_reload_auth 2>/dev/null
    ok "Usuario $name eliminado"
}

u_passwd() {
    local name pass; name=$(ask 'Usuario: ')
    id "$name" >/dev/null 2>&1 || { err "No existe"; return; }
    pass=$(ask 'Nueva contrasena: '); [[ ${#pass} -ge 12 ]] || { err "Minimo 12 caracteres"; return; }
    echo "$name:$pass" | chpasswd 2>/dev/null
    echo "$pass" > "$SENHA_DIR/$name"
    hy_add_user
    s5_reload_auth 2>/dev/null
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
