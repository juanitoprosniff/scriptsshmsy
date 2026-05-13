#!/bin/bash
# ============================================================
# * Creado y modificado por t:me/JuanitoProSniif
# ============================================================
# CREAR USUARIO SSH — SSHMSY MANAGER v2.1
# Sin OpenVPN / Sin OpenSSH directo — usa Dropbear 2016/2020/2022
#
# CAMBIOS v2.1:
#   + Descarga automática de master_pubkey.pub desde GitHub
#   + Detecta Dropbear 2016 / 2020 / 2022 y muestra todos los puertos
#   + Soporte de autenticación por CLAVE PÚBLICA RSA (authorized_keys)
#   + Shell bloqueado en /bin/false (solo túnel, no shell interactivo)
#   + Mantiene contraseña como compat para apps antiguas
#   + Soporta clave maestra compartida — multi-usuario con la misma key
# ============================================================

IP=$(cat /etc/IP 2>/dev/null || hostname -I | awk '{print $1}')
cor1='\033[41;1;37m'
cor2='\033[44;1;37m'
scor='\033[0m'

_REPO_BASE="https://raw.githubusercontent.com/juanitoprosniff/scriptsshmsy/main"
MASTER_PUBKEY="/etc/SSHPlus/master_pubkey.pub"

# FIX Dropbear: registrar shells válidos para evitar rechazo de login
grep -qx '/bin/false' /etc/shells 2>/dev/null       || echo '/bin/false' >> /etc/shells
grep -qx '/usr/sbin/nologin' /etc/shells 2>/dev/null || echo '/usr/sbin/nologin' >> /etc/shells

# ── Descargar clave maestra si no existe ─────────────────────
# Se llama automáticamente al iniciar el script si la key no está.
# Así el admin no tiene que acordarse de descargarla a mano.
_auto_descargar_master_key() {
    [[ -f "$MASTER_PUBKEY" && -s "$MASTER_PUBKEY" ]] && return

    echo -e "\033[1;33m  Descargando clave maestra desde GitHub...\033[0m"
    mkdir -p /etc/SSHPlus
    wget -q --timeout=30 \
        "${_REPO_BASE}/Modulos/master_pubkey.pub" \
        -O "$MASTER_PUBKEY" 2>/dev/null

    if [[ -s "$MASTER_PUBKEY" ]]; then
        chmod 644 "$MASTER_PUBKEY"
        echo -e "\033[1;32m  ✓ Clave maestra descargada automáticamente\033[0m"
    else
        rm -f "$MASTER_PUBKEY"
        echo -e "\033[1;31m  ✗ No se pudo descargar la clave maestra\033[0m"
        echo -e "\033[1;33m    Los usuarios se crearán solo con password.\033[0m"
        echo -e "\033[1;33m    Descárgala desde: Conexión → Clave Maestra\033[0m"
    fi
}

# ── Instalar authorized_keys para un usuario ─────────────────
# Crea ~/.ssh/authorized_keys con la clave maestra.
# Shell sigue siendo /bin/false → no hay acceso a terminal.
# Solo se permite port-forwarding (-L, -R, -D) para el túnel VPN.
fun_install_authkey() {
    local usr="$1"
    local home="/home/$usr"

    [[ ! -f "$MASTER_PUBKEY" ]] && {
        echo -e "\033[1;33m  ⚠ Clave maestra no configurada (omitiendo authorized_keys)\033[0m"
        return
    }

    mkdir -p "$home/.ssh"
    chown -R "$usr:$usr" "$home"
    chmod 700 "$home" "$home/.ssh"

    local opciones='no-pty,no-X11-forwarding,no-agent-forwarding,command="/bin/false"'
    local pub_content
    pub_content=$(cat "$MASTER_PUBKEY" 2>/dev/null)
    [[ -z "$pub_content" ]] && return

    # Agregar opciones de restricción solo si la línea es una clave pura
    if [[ "$pub_content" == ssh-rsa* || "$pub_content" == ssh-ed25519* || "$pub_content" == ecdsa-* ]]; then
        echo "${opciones} ${pub_content}" > "$home/.ssh/authorized_keys"
    else
        echo "$pub_content" > "$home/.ssh/authorized_keys"
    fi

    chmod 600 "$home/.ssh/authorized_keys"
    chown "$usr:$usr" "$home/.ssh/authorized_keys"
    echo -e "\033[1;32m  ✓ Clave RSA instalada en $home/.ssh/authorized_keys\033[0m"
}

# ── Mostrar puertos activos de todos los servicios ───────────
fun_show_ports() {
    echo -e "\033[1;33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"

    # OpenSSH
    _ssh_ports=$(grep '^Port' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | xargs)
    [[ -n "$_ssh_ports" ]] && echo -e "\033[1;32mOpenSSH      :\033[1;37m $_ssh_ports\033[0m"

    # Dropbear 2016
    _db16_port=""
    systemctl is-active dropbear-legacy >/dev/null 2>&1 && \
        _db16_port=$(systemctl show dropbear-legacy --property=ExecStart 2>/dev/null | grep -oP '(?<=-p )\d+' | head -1)
    [[ -z "$_db16_port" ]] && \
        _db16_port=$(screen -list 2>/dev/null | grep 'dropbear2016' | grep -oP '\d+(?=\.dropbear2016)' | head -1)
    [[ -n "$_db16_port" ]] && echo -e "\033[1;32mDropbear 2016:\033[1;37m $_db16_port\033[0m"

    # Dropbear 2020
    _db20_port=""
    systemctl is-active dropbear-2020 >/dev/null 2>&1 && \
        _db20_port=$(systemctl show dropbear-2020 --property=ExecStart 2>/dev/null | grep -oP '(?<=-p )\d+' | head -1)
    [[ -n "$_db20_port" ]] && echo -e "\033[1;32mDropbear 2020:\033[1;37m $_db20_port\033[0m"

    # Dropbear 2022
    _db22_port=""
    systemctl is-active dropbear-2022 >/dev/null 2>&1 && \
        _db22_port=$(systemctl show dropbear-2022 --property=ExecStart 2>/dev/null | grep -oP '(?<=-p )\d+' | head -1)
    [[ -n "$_db22_port" ]] && echo -e "\033[1;32mDropbear 2022:\033[1;37m $_db22_port\033[0m"

    # Proxy WebSocket
    _py_ports=$(ss -tlpn 2>/dev/null | grep -E 'python|python3' | awk '{print $4}' | rev | cut -d: -f1 | rev | sort -u | xargs)
    [[ -n "$_py_ports" ]] && echo -e "\033[1;32mProxy WS     :\033[1;37m $_py_ports\033[0m"

    # SSL/Stunnel
    _ssl_ports=$(ss -tlpn 2>/dev/null | grep 'stunnel' | awk '{print $4}' | rev | cut -d: -f1 | rev | sort -u | xargs)
    [[ -n "$_ssl_ports" ]] && echo -e "\033[1;32mSSL/Stunnel  :\033[1;37m $_ssl_ports\033[0m"

    # Nginx
    _nginx_ports=$(ss -tlpn 2>/dev/null | grep 'nginx' | awk '{print $4}' | rev | cut -d: -f1 | rev | sort -u | xargs)
    [[ -n "$_nginx_ports" ]] && echo -e "\033[1;32mNginx        :\033[1;37m $_nginx_ports\033[0m"

    # V2Ray / Xray
    _v2_ports=$(ss -tlpn 2>/dev/null | grep -E 'v2ray|xray' | awk '{print $4}' | rev | cut -d: -f1 | rev | sort -u | xargs)
    [[ -n "$_v2_ports" ]] && echo -e "\033[1;32mV2Ray/Xray   :\033[1;37m $_v2_ports\033[0m"

    # Estado clave maestra
    if [[ -f "$MASTER_PUBKEY" && -s "$MASTER_PUBKEY" ]]; then
        local fp
        fp=$(ssh-keygen -lf "$MASTER_PUBKEY" 2>/dev/null | awk '{print $2}' | head -c 30)
        echo -e "\033[1;32mMaster Key   :\033[1;37m ${fp}...\033[0m"
    else
        echo -e "\033[1;31mMaster Key   :\033[1;37m NO CONFIGURADA\033[0m"
    fi

    echo -e "\033[1;33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
}

fun_bar() {
    comando[0]="$1"
    (
        [[ -e $HOME/fim ]] && rm $HOME/fim
        ${comando[0]} >/dev/null 2>&1
        touch $HOME/fim
    ) >/dev/null 2>&1 &
    tput civis
    echo -ne "\033[1;33mAGUARDE \033[1;37m- \033[1;33m["
    while true; do
        for ((i = 0; i < 18; i++)); do echo -ne "\033[1;31m#"; sleep 0.1s; done
        [[ -e $HOME/fim ]] && rm $HOME/fim && break
        echo -e "\033[1;33m]"; sleep 1s; tput cuu1; tput dl1
        echo -ne "\033[1;33mAGUARDE \033[1;37m- \033[1;33m["
    done
    echo -e "\033[1;33m]\033[1;37m -\033[1;32m OK !\033[1;37m"
    tput cnorm
}

# ── Token SSH ─────────────────────────────────────────────────
fun_usertoken() {
    clear
    echo -e "\033[0;34m╭━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╮\033[0m"
    echo -e "\033[0;34m┃\E[44;1;37m              CREAR TOKEN SSH            \E[0m\033[0;34m┃"
    echo -e "\033[0;34m╰━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╯\033[0m"
    echo ""
    echo -ne "\033[1;32mInsira o Token:\033[1;37m "
    read username
    [[ -z $username ]] && { echo -e "\n${cor1}Token vazio ou invalido!${scor}\n"; exit 1; }
    [[ "$(grep -wc $username /etc/passwd)" != '0' ]] && { echo -e "\n${cor1}Este Token já existe!${scor}\n"; exit 1; }
    [[ ${username} != ?(+|-)+([a-zA-Z0-9]) ]] && {
        echo -e "\n${cor1}Token inválido! Sem espaços, acentos ou caracteres especiais.${scor}\n"; exit 1
    }
    [[ ${#username} -lt 2 ]] && { echo -e "\n${cor1}Token muito curto (mín. 2 caracteres)${scor}\n"; exit 1; }

    echo -ne "\033[1;32mDias para expirar \033[1;33m[0 = ilimitado]\033[1;32m:\033[1;37m "
    read dias
    [[ -z $dias ]] && { echo -e "\n${cor1}Numero de dias vazio!${scor}\n"; exit 1; }
    [[ ${dias} != +([0-9]) ]] && { echo -e "\n${cor1}Número inválido!${scor}\n"; exit 1; }

    echo -ne "\033[1;32mLimite de conexões:\033[1;37m "
    read sshlimiter
    [[ -z $sshlimiter ]] && { echo -e "\n${cor1}Limite de conexões vazio!${scor}\n"; exit 1; }
    [[ ${sshlimiter} != +([0-9]) || $sshlimiter -lt 1 ]] && {
        echo -e "\n${cor1}Número de conexões inválido (mín. 1)!${scor}\n"; exit 1
    }

    password=$(cat /etc/SSHPlus/Token.txt 2>/dev/null)
    [[ -z "$password" ]] && { echo -e "\n${cor1}Token master não encontrado em /etc/SSHPlus/Token.txt${scor}\n"; exit 1; }

    if [[ "$dias" -eq 0 ]]; then
        final="2099-12-31"; gui="Ilimitado"
    else
        final=$(date "+%Y-%m-%d" -d "+$dias days")
        gui=$(date "+%d/%m/%Y" -d "+$dias days")
    fi

    pass=$(perl -e 'print crypt($ARGV[0], "\$1\$sshmsy\$")' $password)
    useradd -e $final -m -s /bin/false -p $pass $username >/dev/null 2>&1

    [[ -d /etc/SSHPlus/senha ]] || mkdir -p /etc/SSHPlus/senha
    echo "$password" >/etc/SSHPlus/senha/$username
    echo "$username $sshlimiter" >>/root/usuarios.db

    fun_install_authkey "$username"

    echo -e "\033[0;34m╰━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╯\033[0m"
    echo ""
    echo -e "\033[1;32mIP          :\033[1;37m $IP\033[0m"
    echo -e "\033[1;32mToken       :\033[1;37m $username\033[0m"
    echo -e "\033[1;32mExpira em   :\033[1;37m $gui\033[0m"
    echo -e "\033[1;32mConexões    :\033[1;37m $sshlimiter\033[0m"
    echo -e "\033[1;32mAuth        :\033[1;37m Password + Clave RSA Master\033[0m"
    echo ""
    fun_show_ports
}

# ── Verificar que el sistema esté instalado ───────────────────
[[ ! -e /usr/lib/sshplus ]] && exit 0

# Intentar descargar la key automáticamente si no existe
_auto_descargar_master_key

clear
echo -e "\033[0;34m╭━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╮\033[0m"
echo -e "\033[0;34m┃\E[44;1;37m            CREAR USUARIO SSH            \E[0m\033[0;34m┃"
echo -e "\033[0;34m╰━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╯\033[0m"
tput sgr0
echo ""

if [[ ! -f "$MASTER_PUBKEY" || ! -s "$MASTER_PUBKEY" ]]; then
    echo -e "\033[1;33m⚠ Clave maestra RSA no configurada.\033[0m"
    echo -e "\033[1;33m  Los usuarios se crearán SOLO con password.\033[0m"
    echo -e "\033[1;33m  Descárgala desde: Conexión → Clave Maestra\033[0m"
    echo ""
fi

read -p "$(echo -ne "\033[1;32mDeseja usar Token? \033[1;33m[s/n]:\033[1;37m") " -e -i n resp

if [[ "$resp" = 's' ]]; then
    clear
    if [ -e "/etc/SSHPlus/Token.txt" ]; then
        fun_usertoken
    else
        clear
        echo -e "\033[1;31mNenhuma senha de Token cadastrada.\033[0m"
        echo ""
        echo -ne "\033[1;32mInforme uma senha para o Token: \033[1;37m "
        read senha
        [[ -z $senha ]] && { echo -e "\n${cor1}Senha vazia!${scor}\n"; exit 1; }
        [[ -d /etc/SSHPlus ]] || mkdir -p /etc/SSHPlus
        echo $senha >/etc/SSHPlus/Token.txt
        echo -e "\n\033[1;32mSenha cadastrada!\033[0m"
        sleep 1
        fun_usertoken
    fi
else
    clear
    echo -e "\033[0;34m╭━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╮\033[0m"
    echo -e "\033[0;34m┃\E[44;1;37m            CRIAR USUARIO SSH            \E[0m\033[0;34m┃"
    echo -e "\033[0;34m╰━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╯\033[0m"
    echo ""

    echo -ne "\033[1;32mNome do usuário:\033[1;37m "
    read username
    [[ -z $username ]] && { echo -e "\n${cor1}Nome vazio ou invalido!${scor}\n"; exit 1; }
    [[ "$(grep -wc $username /etc/passwd)" != '0' ]] && {
        echo -e "\n${cor1}Este usuário já existe!${scor}\n"; exit 1
    }
    [[ ${username} != ?(+|-)+([a-zA-Z0-9]) ]] && {
        echo -e "\n${cor1}Nome inválido! Sem espaços, acentos ou caracteres especiais.${scor}\n"; exit 1
    }
    [[ ${#username} -lt 2 ]]  && { echo -e "\n${cor1}Nome muito curto (mín. 2 caracteres)!${scor}\n"; exit 1; }
    [[ ${#username} -gt 10 ]] && { echo -e "\n${cor1}Nome muito longo (máx. 10 caracteres)!${scor}\n"; exit 1; }

    echo -ne "\033[1;32mSenha:\033[1;37m "
    read password
    [[ -z $password ]] && { echo -e "\n${cor1}Senha vazia!${scor}\n"; exit 1; }
    [[ ${#password} -lt 4 ]] && { echo -e "\n${cor1}Senha muito curta (mín. 4 caracteres)!${scor}\n"; exit 1; }

    echo -ne "\033[1;32mDias para expirar \033[1;33m[0 = ilimitado]\033[1;32m:\033[1;37m "
    read dias
    [[ -z $dias ]] && { echo -e "\n${cor1}Numero de dias vazio!${scor}\n"; exit 1; }
    [[ ${dias} != +([0-9]) ]] && { echo -e "\n${cor1}Número inválido!${scor}\n"; exit 1; }

    echo -ne "\033[1;32mLimite de conexões:\033[1;37m "
    read sshlimiter
    [[ -z $sshlimiter ]] && { echo -e "\n${cor1}Limite vazio!${scor}\n"; exit 1; }
    [[ ${sshlimiter} != +([0-9]) || $sshlimiter -lt 1 ]] && {
        echo -e "\n${cor1}Número de conexões inválido (mín. 1)!${scor}\n"; exit 1
    }

    if [[ "$dias" -eq 0 ]]; then
        final="2099-12-31"; gui="Ilimitado"
    else
        final=$(date "+%Y-%m-%d" -d "+$dias days")
        gui=$(date "+%d/%m/%Y" -d "+$dias days")
    fi

    pass=$(perl -e 'print crypt($ARGV[0], "\$1\$sshmsy\$")' $password)
    useradd -e $final -m -s /bin/false -p $pass $username >/dev/null 2>&1

    [[ -d /etc/SSHPlus/senha ]] || mkdir -p /etc/SSHPlus/senha
    echo "$password" >/etc/SSHPlus/senha/$username
    echo "$username $sshlimiter" >>/root/usuarios.db

    fun_install_authkey "$username"

    clear
    echo -e "\033[0;34m╭━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╮\033[0m"
    echo -e "\033[0;34m┃\E[44;1;37m            CONTA SSH CRIADA             \E[0m\033[0;34m┃"
    echo -e "\033[0;34m╰━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╯\033[0m"
    echo ""
    echo -e "\033[1;32mIP          :\033[1;37m $IP\033[0m"
    echo -e "\033[1;32mUsuário     :\033[1;37m $username\033[0m"
    echo -e "\033[1;32mSenha       :\033[1;37m $password\033[0m"
    echo -e "\033[1;32mExpira em   :\033[1;37m $gui\033[0m"
    echo -e "\033[1;32mConexões    :\033[1;37m $sshlimiter\033[0m"
    if [[ -f "$MASTER_PUBKEY" && -s "$MASTER_PUBKEY" ]]; then
        echo -e "\033[1;32mAuth        :\033[1;37m Password + Clave RSA Master\033[0m"
    else
        echo -e "\033[1;32mAuth        :\033[1;37m Solo Password (master no instalada)\033[0m"
    fi
    echo ""
    fun_show_ports
fi
