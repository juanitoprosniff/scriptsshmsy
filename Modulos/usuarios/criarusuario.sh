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

# ── V2Ray Integration ─────────────────────────────────────────
_CU_V2RAY_DIR="/etc/v2ray"
_CU_V2RAY_USERS_DB="$_CU_V2RAY_DIR/users.db"
_CU_V2RAY_OFFICIAL_DIR="/usr/local/etc/v2ray"
_CU_V2RAY_CONFIG="$_CU_V2RAY_OFFICIAL_DIR/config.json"
_CU_V2RAY_SERVICE="v2ray"
_CU_V2RAY_INTERNAL_PORT="10086"
_CU_V2RAY_WS_PATH="/vless"
_CU_V2RAY_VMESS_PORT="10087"
_CU_V2RAY_VMESS_PATH="/vmess"
_CU_V2RAY_TROJAN_PORT="10088"
_CU_V2RAY_TROJAN_PATH="/trojan-ws"

_cu_v2ray_installed() {
    local _b
    for _b in /usr/local/bin/v2ray /usr/bin/v2ray; do
        [[ -x "$_b" ]] && return 0
    done
    return 1
}

_cu_gen_uuid() {
    cat /proc/sys/kernel/random/uuid 2>/dev/null || \
    python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null || \
    uuidgen 2>/dev/null | tr 'A-Z' 'a-z'
}

_cu_valid_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

_cu_rebuild_v2ray() {
    [[ ! -s "$_CU_V2RAY_USERS_DB" ]] && return 1
    local _vless="" _vmess="" _trojan=""
    local _first_v=1 _first_m=1 _first_t=1
    local _uuid _alias
    while IFS='|' read -r _uuid _alias; do
        [[ -z "$_uuid" ]] && continue
        _cu_valid_uuid "$_uuid" || continue
        [[ -z "$_alias" ]] && _alias="$_uuid"
        [[ $_first_v -eq 1 ]] && _first_v=0 || _vless+=","
        _vless+=$(printf '\n        {"id": "%s", "level": 0, "email": "%s"}' "$_uuid" "$_alias")
        [[ $_first_m -eq 1 ]] && _first_m=0 || _vmess+=","
        _vmess+=$(printf '\n        {"id": "%s", "alterId": 0, "level": 0, "email": "%s"}' "$_uuid" "$_alias")
        [[ $_first_t -eq 1 ]] && _first_t=0 || _trojan+=","
        _trojan+=$(printf '\n        {"password": "%s", "level": 0, "email": "%s"}' "$_uuid" "$_alias")
    done < "$_CU_V2RAY_USERS_DB"
    [[ -z "$_vless" ]] && return 1
    mkdir -p "$_CU_V2RAY_OFFICIAL_DIR" /var/log/v2ray
    cat > "$_CU_V2RAY_CONFIG" <<JSON
{
  "log": {"loglevel": "warning", "access": "/var/log/v2ray/access.log", "error": "/var/log/v2ray/error.log"},
  "inbounds": [
    {
      "tag": "vless-ws", "listen": "127.0.0.1", "port": ${_CU_V2RAY_INTERNAL_PORT},
      "protocol": "vless",
      "settings": {"clients": [${_vless}
        ], "decryption": "none"},
      "streamSettings": {"network": "ws", "security": "none",
        "wsSettings": {"path": "${_CU_V2RAY_WS_PATH}", "headers": {}}},
      "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
    },
    {
      "tag": "vmess-ws", "listen": "127.0.0.1", "port": ${_CU_V2RAY_VMESS_PORT},
      "protocol": "vmess",
      "settings": {"clients": [${_vmess}
        ]},
      "streamSettings": {"network": "ws", "security": "none",
        "wsSettings": {"path": "${_CU_V2RAY_VMESS_PATH}", "headers": {}}},
      "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
    },
    {
      "tag": "trojan-ws", "listen": "127.0.0.1", "port": ${_CU_V2RAY_TROJAN_PORT},
      "protocol": "trojan",
      "settings": {"clients": [${_trojan}
        ]},
      "streamSettings": {"network": "ws", "security": "none",
        "wsSettings": {"path": "${_CU_V2RAY_TROJAN_PATH}", "headers": {}}},
      "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
    }
  ],
  "outbounds": [
    {"tag": "direct",  "protocol": "freedom",   "settings": {}},
    {"tag": "blocked", "protocol": "blackhole", "settings": {}}
  ],
  "routing": {"domainStrategy": "AsIs",
    "rules": [{"type": "field", "ip": ["geoip:private"], "outboundTag": "blocked"}]}
}
JSON
    chmod 644 "$_CU_V2RAY_CONFIG"
    systemctl restart "$_CU_V2RAY_SERVICE" 2>/dev/null
    return 0
}

# Mostrar info extra (Dominio CF, NS SlowDNS, V2Ray UUID + URIs)
_cu_show_extra_info() {
    local _uname="$1"
    local _v2uuid=""

    # Obtener datos de configuración
    local _cf_dom; _cf_dom=$(cat /etc/v2ray/domain 2>/dev/null | head -1 | tr -d '[:space:]')
    local _ns_dom; _ns_dom=$(cat /etc/slowdns/infons 2>/dev/null | tr -d '\n')
    local _sd_key; _sd_key=$(cat /root/server.pub 2>/dev/null | tr -d '\n')

    # Crear usuario V2Ray si está instalado
    if _cu_v2ray_installed && [[ -d "$_CU_V2RAY_DIR" ]]; then
        _v2uuid=$(_cu_gen_uuid)
        if _cu_valid_uuid "$_v2uuid"; then
            mkdir -p "$_CU_V2RAY_DIR"
            touch "$_CU_V2RAY_USERS_DB"
            echo "${_v2uuid}|${_uname}" >> "$_CU_V2RAY_USERS_DB"
            _cu_rebuild_v2ray >/dev/null 2>&1
        fi
    fi

    # Detectar puertos V2Ray disponibles
    local _http_p; _http_p=$(ss -tlpn 2>/dev/null | grep -E 'python|python3' | awk '{print $4}' | rev | cut -d: -f1 | rev | sort -n | head -1)
    local _tls_p;  _tls_p=$(ss -tlpn  2>/dev/null | grep 'stunnel'           | awk '{print $4}' | rev | cut -d: -f1 | rev | sort -n | head -1)
    [[ -z "$_http_p" ]] && _http_p="80"
    [[ -z "$_tls_p"  ]] && _tls_p="443"

    local _addr="${_cf_dom:-$IP}"
    local _safe; _safe=$(echo "$_uname" | tr ' /' '--')
    local _path_enc="%2Fvless"

    # ─── Mostrar bloque de info extendida ───────────────────────
    echo ""
    echo -e "\033[1;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    echo -e "\033[1;33m  INFORMACIÓN DE CONEXIÓN\033[0m"
    echo -e "\033[1;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"

    echo -e "\033[1;32mIP Servidor     : \033[1;37m${IP}\033[0m"
    [[ -n "$_cf_dom" ]] && echo -e "\033[1;32mDominio CF      : \033[1;37m${_cf_dom}\033[0m"
    [[ -n "$_ns_dom" ]] && echo -e "\033[1;32mDominio NS      : \033[1;37m${_ns_dom}\033[0m"

    # SlowDNS info
    if [[ -n "$_ns_dom" && -n "$_sd_key" ]]; then
        echo ""
        echo -e "\033[1;33m  ── SlowDNS ──\033[0m"
        echo -e "\033[1;32mNS (Nameserver) : \033[1;37m${_ns_dom}\033[0m"
        echo -e "\033[1;32mKey Pública     : \033[1;37m${_sd_key}\033[0m"
        if ps aux 2>/dev/null | grep -v grep | grep -q 'dns-server'; then
            echo -e "\033[1;32mEstado SlowDNS  : \033[1;32m● ACTIVO\033[0m"
        fi
    fi

    # V2Ray info
    if [[ -n "$_v2uuid" ]] && _cu_valid_uuid "$_v2uuid"; then
        echo ""
        echo -e "\033[1;33m  ── V2Ray VLESS ──\033[0m"
        echo -e "\033[1;32mUUID V2Ray      : \033[1;37m${_v2uuid}\033[0m"
        echo ""
        local _uri_h="vless://${_v2uuid}@${IP}:${_http_p}?type=ws&encryption=none&security=none&host=${_addr}&path=${_path_enc}#${_safe}-http-${_http_p}"
        local _uri_t="vless://${_v2uuid}@${IP}:${_tls_p}?type=ws&encryption=none&security=tls&sni=${_addr}&host=${_addr}&path=${_path_enc}&allowInsecure=1#${_safe}-tls-${_tls_p}"
        echo -e "\033[1;32mVLESS HTTP      : \033[1;36m${_uri_h}\033[0m"
        echo ""
        echo -e "\033[1;32mVLESS TLS       : \033[1;36m${_uri_t}\033[0m"
        [[ -n "$_cf_dom" ]] && {
            local _uri_cf="vless://${_v2uuid}@${IP}:443?type=ws&encryption=none&security=tls&sni=${_cf_dom}&host=${_cf_dom}&path=${_path_enc}#${_safe}-cf-443"
            echo ""
            echo -e "\033[1;32mVLESS Cloudflare: \033[1;36m${_uri_cf}\033[0m"
        }
    fi

    echo -e "\033[1;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
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
    _cu_show_extra_info "$username"
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
    _cu_show_extra_info "$username"
fi
