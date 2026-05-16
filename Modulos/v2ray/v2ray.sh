#!/bin/bash
# ============================================================
# * Creado y modificado por t:me/JuanitoProSniff
# ============================================================
# MÓDULO V2RAY VLESS — MSYVPN-SCRIPT
# - Protocolo: VLESS sobre WebSocket (path /vless)
# - V2Ray escucha SOLO en 127.0.0.1:10086 (texto plano)
# - Coexiste con wsproxy / stunnel / OpenSSH / Dropbear
#   compartiendo los mismos puertos públicos.
# - 2 modos de cliente soportados con la misma config:
#     · Default SNI / Bug location  (TLS, vía stunnel)
#     · Reverse SNI / Bug as address (HTTP plano, vía wsproxy)
# Compatible: Ubuntu 18 / 20 / 22 / 24 / 25 / 26 / 27
# Arquitectura: amd64 / arm64 / arm (oficial v2fly)
# ============================================================

_V2RAY_DIR="/etc/v2ray"
_V2RAY_CONFIG="$_V2RAY_DIR/config.json"
_V2RAY_USERS_DB="$_V2RAY_DIR/users.db"
_V2RAY_BIN_CANDIDATES=("/usr/local/bin/v2ray" "/usr/bin/v2ray")
_V2RAY_SERVICE="v2ray"
_V2RAY_INTERNAL_PORT="10086"
_V2RAY_WS_PATH="/vless"
_V2RAY_ROUTE_CONF="/etc/SSHPlus/v2ray-route.conf"

_v2ray_bin() {
    for b in "${_V2RAY_BIN_CANDIDATES[@]}"; do
        [[ -x "$b" ]] && { echo "$b"; return; }
    done
    command -v v2ray 2>/dev/null
}

_v2ray_installed() {
    [[ -n "$(_v2ray_bin)" ]] && return 0 || return 1
}

_v2ray_active() {
    systemctl is-active --quiet "$_V2RAY_SERVICE" 2>/dev/null
}

# ── Generar UUID v4 sin depender de uuidgen ───────────────────
_v2ray_gen_uuid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr 'A-Z' 'a-z'
    elif [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        python3 -c 'import uuid; print(uuid.uuid4())'
    fi
}

# ── Validar formato UUID ──────────────────────────────────────
_v2ray_valid_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# ── IP pública del VPS ────────────────────────────────────────
_v2ray_ip() {
    local _ip
    [[ -f /etc/IP ]] && _ip=$(cat /etc/IP 2>/dev/null)
    [[ -z "$_ip" ]] && _ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$_ip" ]] && _ip=$(curl -s --max-time 4 ifconfig.me 2>/dev/null)
    echo "${_ip:-VPS_IP}"
}

# ============================================================
# REGENERAR config.json desde la base de datos de usuarios
# users.db formato:  uuid|alias
# ============================================================
_v2ray_rebuild_config() {
    mkdir -p "$_V2RAY_DIR"
    touch "$_V2RAY_USERS_DB"

    local _clients="" _first=1 _uuid _alias
    while IFS='|' read -r _uuid _alias; do
        [[ -z "$_uuid" ]] && continue
        _v2ray_valid_uuid "$_uuid" || continue
        [[ -z "$_alias" ]] && _alias="$_uuid"
        if [[ $_first -eq 1 ]]; then
            _first=0
        else
            _clients+=","
        fi
        _clients+=$(printf '\n        {"id": "%s", "level": 0, "email": "%s"}' "$_uuid" "$_alias")
    done < "$_V2RAY_USERS_DB"

    # Si no hay usuarios, generar uno por defecto para que el servicio arranque sano
    if [[ -z "$_clients" ]]; then
        local _def; _def=$(_v2ray_gen_uuid)
        echo "${_def}|default" >> "$_V2RAY_USERS_DB"
        _clients=$(printf '\n        {"id": "%s", "level": 0, "email": "default"}' "$_def")
    fi

    cat > "$_V2RAY_CONFIG" <<JSON
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/v2ray/access.log",
    "error": "/var/log/v2ray/error.log"
  },
  "inbounds": [
    {
      "tag": "vless-ws",
      "listen": "127.0.0.1",
      "port": ${_V2RAY_INTERNAL_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [${_clients}
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "${_V2RAY_WS_PATH}",
          "headers": {}
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    { "tag": "direct",  "protocol": "freedom",   "settings": {} },
    { "tag": "blocked", "protocol": "blackhole", "settings": {} }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "blocked" }
    ]
  }
}
JSON
    mkdir -p /var/log/v2ray
    chmod 644 "$_V2RAY_CONFIG"
}

# ============================================================
# Escribir/limpiar archivo de ruteo para wsproxy
# ============================================================
_v2ray_write_route_conf() {
    mkdir -p /etc/SSHPlus
    cat > "$_V2RAY_ROUTE_CONF" <<EOF
# Auto-generado — MSYVPN-SCRIPT V2Ray module
V2RAY_ENABLED=yes
V2RAY_PATH=${_V2RAY_WS_PATH}
V2RAY_HOST=127.0.0.1:${_V2RAY_INTERNAL_PORT}
EOF
    chmod 644 "$_V2RAY_ROUTE_CONF"
}

_v2ray_remove_route_conf() {
    if [[ -f "$_V2RAY_ROUTE_CONF" ]]; then
        sed -i 's|^V2RAY_ENABLED=.*|V2RAY_ENABLED=no|' "$_V2RAY_ROUTE_CONF"
    fi
}

# ============================================================
# Reiniciar wsproxy para que recargue ruteo V2Ray
# (los procesos leen la config al iniciar)
# ============================================================
_v2ray_reload_wsproxy() {
    [[ ! -f /etc/autostart ]] && return 0
    local _restarted=0
    # Matar instancias actuales de wsproxy
    for pid in $(screen -ls 2>/dev/null | grep -E '\.ws[0-9]|ws[0-9]+\.' | awk '{print $1}'); do
        screen -r -S "$pid" -X quit 2>/dev/null
    done
    pkill -f "/etc/SSHPlus/wsproxy" 2>/dev/null
    screen -wipe >/dev/null 2>&1
    sleep 1
    # Relanzar desde autostart
    while IFS= read -r _cmd; do
        [[ "$_cmd" =~ wsproxy ]] && { eval "$_cmd" 2>/dev/null; ((_restarted++)); }
    done < /etc/autostart
    return 0
}

# ============================================================
# INSTALAR V2RAY (instalador oficial v2fly)
# ============================================================
_v2ray_install() {
    if _v2ray_installed; then
        echo -e "\033[1;33mV2Ray ya está instalado en: $(_v2ray_bin)\033[0m"
        sleep 1; return 0
    fi

    echo -e "\n\033[1;33mInstalando dependencias...\033[0m"
    apt-get update -y >/dev/null 2>&1
    apt-get install -y curl wget unzip ca-certificates >/dev/null 2>&1

    echo -e "\033[1;33mDescargando instalador oficial v2fly...\033[0m"
    local _tmp="/tmp/v2ray_install_$$.sh"
    wget -q --timeout=60 \
        "https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh" \
        -O "$_tmp"

    if [[ ! -s "$_tmp" ]]; then
        # Fallback al espejo oficial
        curl -fsSL --max-time 60 \
            "https://github.com/v2fly/fhs-install-v2ray/raw/master/install-release.sh" \
            -o "$_tmp" 2>/dev/null
    fi

    if [[ ! -s "$_tmp" ]]; then
        echo -e "\033[1;31m✗ No se pudo descargar el instalador V2Ray.\033[0m"
        echo -e "\033[1;33m  Verifique conexión a internet.\033[0m"
        rm -f "$_tmp"; return 1
    fi

    chmod +x "$_tmp"
    echo -e "\033[1;33mEjecutando instalador (~1-3 min)...\033[0m"
    bash "$_tmp" >/tmp/v2ray_install.log 2>&1
    local _rc=$?
    rm -f "$_tmp"

    if ! _v2ray_installed; then
        echo -e "\033[1;31m✗ Instalación V2Ray falló (rc=$_rc).\033[0m"
        echo -e "\033[1;33m  Log: /tmp/v2ray_install.log\033[0m"
        tail -n 8 /tmp/v2ray_install.log 2>/dev/null
        return 1
    fi

    echo -e "\033[1;32m✓ V2Ray instalado: $(_v2ray_bin)\033[0m"
    return 0
}

# ============================================================
# DESINSTALAR V2RAY
# ============================================================
_v2ray_uninstall() {
    echo -e "\n\033[1;33mDeteniendo V2Ray...\033[0m"
    systemctl stop "$_V2RAY_SERVICE" 2>/dev/null
    systemctl disable "$_V2RAY_SERVICE" 2>/dev/null
    # Específico: solo el binario y "v2ray run", no archivos de script
    pkill -x v2ray 2>/dev/null
    pkill -f "v2ray run" 2>/dev/null
    pkill -f "/usr/local/bin/v2ray" 2>/dev/null

    local _tmp="/tmp/v2ray_uninst_$$.sh"
    wget -q --timeout=30 \
        "https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh" \
        -O "$_tmp" 2>/dev/null
    if [[ -s "$_tmp" ]]; then
        chmod +x "$_tmp"
        bash "$_tmp" --remove >/dev/null 2>&1
        rm -f "$_tmp"
    fi

    # Limpieza manual por si el script no remueve todo
    rm -f /usr/local/bin/v2ray /usr/local/bin/v2ctl 2>/dev/null
    rm -rf /usr/local/share/v2ray 2>/dev/null
    rm -f /etc/systemd/system/v2ray.service \
          /etc/systemd/system/v2ray@.service 2>/dev/null
    systemctl daemon-reload 2>/dev/null

    _v2ray_remove_route_conf
    _v2ray_reload_wsproxy

    echo -e "\033[1;32m✓ V2Ray desinstalado.\033[0m"
    echo -e "\033[1;33m  Carpeta $_V2RAY_DIR conservada (uuid/db). Borrar manual si lo desea.\033[0m"
    sleep 2
}

# ============================================================
# Reiniciar / detener V2Ray
# ============================================================
_v2ray_restart() {
    if ! _v2ray_installed; then
        echo -e "\033[1;31m✗ V2Ray no está instalado.\033[0m"; sleep 2; return
    fi
    _v2ray_rebuild_config
    systemctl daemon-reload 2>/dev/null
    systemctl restart "$_V2RAY_SERVICE"
    sleep 1
    if _v2ray_active; then
        echo -e "\033[1;32m✓ V2Ray reiniciado correctamente.\033[0m"
    else
        echo -e "\033[1;31m✗ V2Ray no arrancó. Ver: journalctl -u $_V2RAY_SERVICE -n 30\033[0m"
    fi
    sleep 2
}

_v2ray_stop() {
    if ! _v2ray_installed; then
        echo -e "\033[1;31m✗ V2Ray no está instalado.\033[0m"; sleep 2; return
    fi
    systemctl stop "$_V2RAY_SERVICE" 2>/dev/null
    pkill -f "v2ray run" 2>/dev/null
    sleep 1
    if ! _v2ray_active; then
        echo -e "\033[1;32m✓ V2Ray detenido y puerto $_V2RAY_INTERNAL_PORT liberado.\033[0m"
    else
        echo -e "\033[1;31m✗ No se pudo detener V2Ray.\033[0m"
    fi
    sleep 2
}

# ============================================================
# AGREGAR USUARIO (UUID manual o aleatorio)
# ============================================================
_v2ray_add_user() {
    local _modo="$1"  # manual | random
    local _uuid _alias

    if [[ "$_modo" == "manual" ]]; then
        echo -ne "\n\033[1;32mIngrese UUID (formato 8-4-4-4-12): \033[1;37m"; read _uuid
        _uuid=$(echo "$_uuid" | tr 'A-Z' 'a-z' | xargs)
        if ! _v2ray_valid_uuid "$_uuid"; then
            echo -e "\033[1;31m✗ UUID inválido. Ejemplo:\033[1;37m b831381d-6324-4d53-ad4f-8cda48b30811\033[0m"
            sleep 3; return
        fi
    else
        _uuid=$(_v2ray_gen_uuid)
    fi

    echo -ne "\n\033[1;32mAlias / nombre (opcional, ENTER para auto): \033[1;37m"; read _alias
    _alias=$(echo "$_alias" | tr -cd '[:alnum:]_-' | head -c 32)
    [[ -z "$_alias" ]] && _alias="user_$(date +%s)"

    mkdir -p "$_V2RAY_DIR"
    touch "$_V2RAY_USERS_DB"
    if grep -q "^${_uuid}|" "$_V2RAY_USERS_DB" 2>/dev/null; then
        echo -e "\n\033[1;33m⚠ Ese UUID ya existe en la base de datos.\033[0m"
        sleep 2; return
    fi
    echo "${_uuid}|${_alias}" >> "$_V2RAY_USERS_DB"
    _v2ray_rebuild_config
    systemctl restart "$_V2RAY_SERVICE" 2>/dev/null

    echo -e "\n\033[0;34m┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\033[0m"
    echo -e "\033[1;32m✓ USUARIO V2RAY AGREGADO\033[0m"
    echo -e "\033[1;33m  UUID  : \033[1;37m$_uuid"
    echo -e "\033[1;33m  Alias : \033[1;37m$_alias\033[0m"
    echo -e "\033[0;34m┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\033[0m"
    sleep 1
    echo -ne "\n\033[1;33m¿Mostrar URIs de este usuario? [s/N]: \033[1;37m"; read _v
    [[ "$_v" =~ ^[sSyY]$ ]] && _v2ray_show_uris_user "$_uuid" "$_alias"
    echo -ne "\n\033[1;33mENTER para continuar...\033[0m"; read
}

_v2ray_delete_user() {
    if [[ ! -s "$_V2RAY_USERS_DB" ]]; then
        echo -e "\n\033[1;31mNo hay usuarios registrados.\033[0m"; sleep 2; return
    fi
    echo -e "\n\033[1;33mUsuarios actuales:\033[0m"
    local _i=0 _uuid _alias
    declare -a _uuids
    while IFS='|' read -r _uuid _alias; do
        [[ -z "$_uuid" ]] && continue
        _i=$((_i+1)); _uuids[$_i]="$_uuid"
        printf "  \033[1;31m[\033[1;36m%2d\033[1;31m] \033[1;37m%s  \033[1;33m(%s)\033[0m\n" "$_i" "$_uuid" "$_alias"
    done < "$_V2RAY_USERS_DB"
    [[ $_i -eq 0 ]] && { echo -e "\033[1;31mDB vacía.\033[0m"; sleep 2; return; }
    echo -ne "\n\033[1;32mNº a eliminar (0 = cancelar): \033[1;37m"; read _n
    [[ ! "$_n" =~ ^[0-9]+$ ]] || [[ $_n -le 0 ]] || [[ $_n -gt $_i ]] && return
    local _target="${_uuids[$_n]}"
    # Eliminar línea cuyo UUID coincide (delimitador # para evitar choque con |)
    sed -i "\#^${_target}|#d" "$_V2RAY_USERS_DB"
    _v2ray_rebuild_config
    systemctl restart "$_V2RAY_SERVICE" 2>/dev/null
    echo -e "\n\033[1;32m✓ Usuario eliminado: $_target\033[0m"; sleep 2
}

# ============================================================
# MOSTRAR URIs — ambos modos (TLS y no-TLS)
# ============================================================
_v2ray_collect_ports() {
    # Devuelve dos variables globales: _NOTLS_PORTS y _TLS_PORTS
    _NOTLS_PORTS=""
    _TLS_PORTS=""

    # Puertos de wsproxy (no-TLS)
    local _np
    _np=$(ss -tlpn 2>/dev/null | grep -E 'python|python3' | \
          awk '{print $4}' | rev | cut -d: -f1 | rev | \
          grep -v "^${_V2RAY_INTERNAL_PORT}$" | grep -v "^10443$" | \
          sort -un | xargs)
    _NOTLS_PORTS="$_np"

    # Puertos de stunnel (TLS)
    if [[ -f /etc/stunnel/stunnel.conf ]]; then
        _TLS_PORTS=$(grep -oP '(?<=^accept\s{2}=\s)\d+' /etc/stunnel/stunnel.conf 2>/dev/null | \
                    sort -un | xargs)
        [[ -z "$_TLS_PORTS" ]] && \
            _TLS_PORTS=$(grep -oP '(?<=^accept\s=\s)\d+' /etc/stunnel/stunnel.conf 2>/dev/null | sort -un | xargs)
    fi
}

_v2ray_show_uris_user() {
    local _uuid="$1" _alias="$2"
    local _ip; _ip=$(_v2ray_ip)
    local _bug
    echo -ne "\n\033[1;33mDominio BUG (ENTER para usar IP $_ip): \033[1;37m"; read _bug
    _bug=$(echo "$_bug" | xargs)
    [[ -z "$_bug" ]] && _bug="$_ip"

    _v2ray_collect_ports

    local _path_enc
    _path_enc=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${_V2RAY_WS_PATH}', safe=''))" 2>/dev/null)
    [[ -z "$_path_enc" ]] && _path_enc="%2Fvless"

    echo ""
    echo -e "\033[0;34m┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\033[0m"
    echo -e "\033[0;34m┃\E[44;1;37m   URIs V2RAY VLESS — ${_alias}              \E[0m\033[0;34m┃"
    echo -e "\033[0;34m┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\033[0m"
    echo -e "\033[1;33m  UUID : \033[1;37m$_uuid"
    echo -e "\033[1;33m  Path : \033[1;37m${_V2RAY_WS_PATH}"
    echo -e "\033[1;33m  IP   : \033[1;37m$_ip"
    echo -e "\033[1;33m  Bug  : \033[1;37m$_bug"

    # ── Modo 1: Default SNI / Bug location (TLS) ─────────────────
    echo ""
    echo -e "\033[1;32m── Modo TLS  (Default SNI / Bug location) ─────────\033[0m"
    if [[ -z "$_TLS_PORTS" ]]; then
        echo -e "\033[1;31m  Sin puertos TLS activos (stunnel). Active SSL Tunnel primero.\033[0m"
    else
        for _p in $_TLS_PORTS; do
            local _uri="vless://${_uuid}@${_ip}:${_p}?encryption=none&security=tls&type=ws&host=${_bug}&sni=${_bug}&path=${_path_enc}&allowInsecure=1#${_alias}-tls-${_p}"
            echo -e "  \033[1;37m• Puerto $_p :\033[0m"
            echo -e "    \033[1;36m$_uri\033[0m"
        done
    fi

    # ── Modo 2: Reverse SNI / Bug as address (sin TLS) ───────────
    echo ""
    echo -e "\033[1;32m── Modo HTTP (Reverse SNI / Bug as address) ───────\033[0m"
    if [[ -z "$_NOTLS_PORTS" ]]; then
        echo -e "\033[1;31m  Sin puertos WS activos (wsproxy). Active Proxy WebSocket primero.\033[0m"
    else
        for _p in $_NOTLS_PORTS; do
            # En este modo el cliente pone el bug como address y la IP real va
            # como host del payload. Generamos dos variantes útiles.
            local _uri_a="vless://${_uuid}@${_bug}:${_p}?encryption=none&security=none&type=ws&host=${_bug}&path=${_path_enc}#${_alias}-bug-${_p}"
            local _uri_b="vless://${_uuid}@${_ip}:${_p}?encryption=none&security=none&type=ws&host=${_bug}&path=${_path_enc}#${_alias}-ip-${_p}"
            echo -e "  \033[1;37m• Puerto $_p (bug as address):\033[0m"
            echo -e "    \033[1;36m$_uri_a\033[0m"
            echo -e "  \033[1;37m• Puerto $_p (IP + Host bug):\033[0m"
            echo -e "    \033[1;36m$_uri_b\033[0m"
        done
    fi

    echo ""
    echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
}

_v2ray_show_uris() {
    if [[ ! -s "$_V2RAY_USERS_DB" ]]; then
        echo -e "\n\033[1;31mNo hay usuarios. Cree uno desde el menú primero.\033[0m"
        sleep 2; return
    fi
    echo -e "\n\033[1;33mUsuarios registrados:\033[0m"
    local _i=0 _uuid _alias
    declare -a _uuids _aliases
    while IFS='|' read -r _uuid _alias; do
        [[ -z "$_uuid" ]] && continue
        _i=$((_i+1)); _uuids[$_i]="$_uuid"; _aliases[$_i]="$_alias"
        printf "  \033[1;31m[\033[1;36m%2d\033[1;31m] \033[1;37m%s  \033[1;33m(%s)\033[0m\n" "$_i" "$_uuid" "$_alias"
    done < "$_V2RAY_USERS_DB"
    echo -e "  \033[1;31m[\033[1;36m 0\033[1;31m] \033[1;33mTODOS los usuarios"
    echo -ne "\n\033[1;32mNº (0=todos): \033[1;37m"; read _n
    [[ ! "$_n" =~ ^[0-9]+$ ]] && return

    if [[ "$_n" -eq 0 ]]; then
        for ((j=1; j<=_i; j++)); do
            _v2ray_show_uris_user "${_uuids[$j]}" "${_aliases[$j]}"
        done
    elif [[ "$_n" -ge 1 && "$_n" -le "$_i" ]]; then
        _v2ray_show_uris_user "${_uuids[$_n]}" "${_aliases[$_n]}"
    else
        return
    fi
    echo -ne "\n\033[1;33mENTER para continuar...\033[0m"; read
}

# ============================================================
# ACTIVAR TODO — Instalación end-to-end
# ============================================================
_v2ray_activar_todo() {
    clear
    echo -e "\033[0;34m┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\033[0m"
    echo -e "\033[0;34m┃\E[42;1;37m    V2RAY — ACTIVAR TODO AUTOMÁTICO       \E[0m\033[0;34m┃"
    echo -e "\033[0;34m┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\033[0m"
    echo ""
    echo -e "\033[1;37m Esta opción hará lo siguiente:\033[0m"
    echo -e "   \033[1;32m1)\033[1;37m Instalar V2Ray oficial (si falta)"
    echo -e "   \033[1;32m2)\033[1;37m Crear primer usuario con UUID aleatorio"
    echo -e "   \033[1;32m3)\033[1;37m Activar wsproxy en 80, 8080, 8880, 8888, 2086"
    echo -e "   \033[1;32m4)\033[1;37m Activar stunnel/dispatcher en 443, 444, 8443"
    echo -e "   \033[1;32m5)\033[1;37m Conectar wsproxy ↔ V2Ray (path ${_V2RAY_WS_PATH})\033[0m"
    echo ""
    echo -ne "\033[1;33m¿Continuar? [s/N]: \033[1;37m"; read _ok
    [[ ! "$_ok" =~ ^[sSyY]$ ]] && return

    # 1. Instalar V2Ray
    echo -e "\n\033[1;33m[1/5] Instalando V2Ray...\033[0m"
    _v2ray_install || { echo -e "\033[1;31mAbortado.\033[0m"; sleep 3; return; }

    # 2. Crear primer usuario si la DB está vacía
    echo -e "\n\033[1;33m[2/5] Verificando usuarios...\033[0m"
    if [[ ! -s "$_V2RAY_USERS_DB" ]]; then
        local _uuid; _uuid=$(_v2ray_gen_uuid)
        mkdir -p "$_V2RAY_DIR"
        echo "${_uuid}|principal" > "$_V2RAY_USERS_DB"
        echo -e "\033[1;32m  ✓ Usuario creado: $_uuid\033[0m"
    else
        echo -e "\033[1;37m  Usuarios ya presentes: $(wc -l < "$_V2RAY_USERS_DB")\033[0m"
    fi

    # 3. Activar ruteo y reiniciar V2Ray
    _v2ray_rebuild_config
    _v2ray_write_route_conf
    systemctl enable "$_V2RAY_SERVICE" >/dev/null 2>&1
    systemctl restart "$_V2RAY_SERVICE" 2>/dev/null
    sleep 1

    # 4. wsproxy en puertos estándar (si no hay activos)
    echo -e "\n\033[1;33m[3/5] Activando wsproxy en 80, 8080, 8880, 8888, 2086...\033[0m"
    local _ws_running
    _ws_running=$(ss -tlpn 2>/dev/null | grep -E 'python|python3' | \
                  awk '{print $4}' | rev | cut -d: -f1 | rev | xargs)
    for _p in 80 8080 8880 8888 2086; do
        # Saltar si el puerto ya escucha
        if ss -tlpn 2>/dev/null | grep -q ":${_p} "; then
            echo -e "\033[1;37m  Puerto $_p ya en uso, conservando.\033[0m"
            continue
        fi
        screen -dmS "ws${_p}" python3 /etc/SSHPlus/wsproxy.py "$_p" "127.0.0.1:22"
        # Persistir
        sed -i "\|wsproxy.py ${_p}|d" /etc/autostart 2>/dev/null
        echo "ss -tlpn | grep -qw ${_p} || screen -dmS ws${_p} python3 /etc/SSHPlus/wsproxy.py ${_p} 127.0.0.1:22" >> /etc/autostart
        _fw_open "$_p" tcp 2>/dev/null || iptables -I INPUT -p tcp --dport "$_p" -j ACCEPT 2>/dev/null
        sleep 0.3
        ss -tlpn 2>/dev/null | grep -q ":${_p} " && \
            echo -e "\033[1;32m  ✓ Puerto $_p activo\033[0m" || \
            echo -e "\033[1;31m  ✗ Puerto $_p no respondió\033[0m"
    done

    # 5. SSL Tunnel + dispatcher
    echo -e "\n\033[1;33m[4/5] Activando SSL Tunnel + Dispatcher...\033[0m"
    if [[ ! -f /etc/stunnel/stunnel.conf ]]; then
        apt-get install -y stunnel4 openssl >/dev/null 2>&1
        [[ -f /etc/default/stunnel4 ]] && sed -i 's/ENABLED=0/ENABLED=1/' /etc/default/stunnel4
        mkdir -p /etc/stunnel
        openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
            -subj "/C=CO/ST=Colombia/L=Bogota/O=MSYVPN/CN=msyvpn.local" \
            -keyout /etc/stunnel/stunnel.key -out /etc/stunnel/stunnel.crt >/dev/null 2>&1
        cat /etc/stunnel/stunnel.crt /etc/stunnel/stunnel.key > /etc/stunnel/stunnel.pem
        chmod 600 /etc/stunnel/stunnel.pem
        cat > /etc/stunnel/stunnel.conf <<EOF
cert = /etc/stunnel/stunnel.pem
client = no
socket = a:SO_REUSEADDR=1
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

[sshtunnel443]
accept  = 443
connect = 127.0.0.1:10443

[sshtunnel444]
accept  = 444
connect = 127.0.0.1:10443

[sshtunnel8443]
accept  = 8443
connect = 127.0.0.1:10443
EOF
    fi
    for _p in 443 444 8443; do
        _fw_open "$_p" tcp 2>/dev/null || iptables -I INPUT -p tcp --dport "$_p" -j ACCEPT 2>/dev/null
    done
    systemctl restart stunnel4 2>/dev/null || service stunnel4 restart 2>/dev/null

    # Dispatcher
    if [[ -f /etc/SSHPlus/ssldispatcher.py ]]; then
        for pid in $(screen -ls 2>/dev/null | grep '\.ssldispatch' | awk '{print $1}'); do
            screen -r -S "$pid" -X quit 2>/dev/null
        done
        pkill -f "ssldispatcher.py" 2>/dev/null
        screen -wipe >/dev/null 2>&1
        sleep 0.5
        screen -dmS ssldispatch python3 /etc/SSHPlus/ssldispatcher.py 10443 127.0.0.1:22 127.0.0.1:80
        sed -i '/ssldispatcher.py/d' /etc/autostart 2>/dev/null
        echo "ss -tlpn | grep -qw 10443 || screen -dmS ssldispatch python3 /etc/SSHPlus/ssldispatcher.py 10443 127.0.0.1:22 127.0.0.1:80" >> /etc/autostart
    fi

    # 6. Recargar wsproxy con la nueva config V2Ray
    echo -e "\n\033[1;33m[5/5] Recargando wsproxy con ruteo V2Ray...\033[0m"
    _v2ray_reload_wsproxy

    sleep 1
    echo ""
    echo -e "\033[0;34m┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\033[0m"
    echo -e "\033[1;32m✓ V2RAY + WSPROXY + STUNNEL ACTIVOS\033[0m"
    echo -e "\033[1;33m  V2Ray   : \033[1;37m127.0.0.1:${_V2RAY_INTERNAL_PORT}  path ${_V2RAY_WS_PATH}"
    echo -e "\033[1;33m  No-TLS  : \033[1;37m80, 8080, 8880, 8888, 2086"
    echo -e "\033[1;33m  TLS     : \033[1;37m443, 444, 8443\033[0m"
    echo -e "\033[0;34m┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\033[0m"
    echo ""
    echo -ne "\033[1;33mENTER para ver las URIs de tus usuarios...\033[0m"; read
    _v2ray_show_uris
}

# ============================================================
# MENÚ V2RAY
# ============================================================
fun_v2ray() {
    while true; do
        clear
        echo -e "\033[0;34m┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\033[0m"
        echo -e "\033[0;34m┃\E[44;1;37m         V2RAY VLESS — GESTIONAR         \E[0m\033[0;34m┃"
        echo -e "\033[0;34m┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\033[0m"

        local _inst_sts _act_sts _route_sts _n_users
        _v2ray_installed && _inst_sts="\033[1;32m✓ instalado " || _inst_sts="\033[1;31m✕ no instalado"
        _v2ray_active    && _act_sts="\033[1;32m✓ activo"     || _act_sts="\033[1;31m✕ inactivo"
        if [[ -f "$_V2RAY_ROUTE_CONF" ]] && grep -q '^V2RAY_ENABLED=yes' "$_V2RAY_ROUTE_CONF" 2>/dev/null; then
            _route_sts="\033[1;32m✓ wsproxy→V2Ray"
        else
            _route_sts="\033[1;31m✕ wsproxy NO rutea"
        fi
        _n_users=0
        [[ -s "$_V2RAY_USERS_DB" ]] && _n_users=$(grep -c '^[0-9a-f]' "$_V2RAY_USERS_DB" 2>/dev/null)

        # Puertos activos públicos relevantes
        _v2ray_collect_ports
        echo -e "\033[0;34m╼ \033[1;33mV2Ray binario  : $_inst_sts"
        echo -e "\033[0;34m╼ \033[1;33mServicio       : $_act_sts"
        echo -e "\033[0;34m╼ \033[1;33mRuteo wsproxy  : $_route_sts"
        echo -e "\033[0;34m╼ \033[1;33mUsuarios       : \033[1;37m${_n_users}"
        echo -e "\033[0;34m╼ \033[1;33mPuerto interno : \033[1;37m127.0.0.1:${_V2RAY_INTERNAL_PORT}"
        echo -e "\033[0;34m╼ \033[1;33mPath WebSocket : \033[1;37m${_V2RAY_WS_PATH}"
        echo -e "\033[0;34m╼ \033[1;33mPuertos no-TLS : \033[1;37m${_NOTLS_PORTS:-—}"
        echo -e "\033[0;34m╼ \033[1;33mPuertos TLS    : \033[1;37m${_TLS_PORTS:-—}"

        echo -e "\033[0;34m┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\033[0m"
        echo -e "\033[0;34m┃\033[1;31m[\033[1;36m1\033[1;31m] \033[1;32mACTIVAR TODO  ◄ recomendado          \033[0;34m┃"
        echo -e "\033[0;34m┃\033[1;31m[\033[1;36m2\033[1;31m] \033[1;33mAGREGAR UUID MANUAL                  \033[0;34m┃"
        echo -e "\033[0;34m┃\033[1;31m[\033[1;36m3\033[1;31m] \033[1;33mCREAR UUID AL AZAR                   \033[0;34m┃"
        echo -e "\033[0;34m┃\033[1;31m[\033[1;36m4\033[1;31m] \033[1;33mVER URIs (TLS + HTTP)                \033[0;34m┃"
        echo -e "\033[0;34m┃\033[1;31m[\033[1;36m5\033[1;31m] \033[1;33mELIMINAR USUARIO                     \033[0;34m┃"
        echo -e "\033[0;34m┃\033[1;31m[\033[1;36m6\033[1;31m] \033[1;33mREINICIAR V2RAY                      \033[0;34m┃"
        echo -e "\033[0;34m┃\033[1;31m[\033[1;36m7\033[1;31m] \033[1;33mDETENER V2RAY (libera puertos)       \033[0;34m┃"
        echo -e "\033[0;34m┃\033[1;31m[\033[1;36m8\033[1;31m] \033[1;31mDESINSTALAR V2RAY                    \033[0;34m┃"
        echo -e "\033[0;34m┃\033[1;31m[\033[1;36m9\033[1;31m] \033[1;33mINSTALAR V2RAY (solo binario)        \033[0;34m┃"
        echo -e "\033[0;34m┃\033[1;31m[\033[1;36m0\033[1;31m] \033[1;33mVOLVER                               \033[0;34m┃"
        echo -e "\033[0;34m┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\033[0m"
        echo -ne "\033[1;32mOpción: \033[1;37m"; read _v2opt

        case "$_v2opt" in
            1|01) _v2ray_activar_todo ;;
            2|02) _v2ray_installed || { echo -e "\033[1;31mInstale V2Ray primero (opción 9 o 1).\033[0m"; sleep 2; continue; }
                  _v2ray_add_user manual ;;
            3|03) _v2ray_installed || { echo -e "\033[1;31mInstale V2Ray primero (opción 9 o 1).\033[0m"; sleep 2; continue; }
                  _v2ray_add_user random ;;
            4|04) _v2ray_show_uris ;;
            5|05) _v2ray_delete_user ;;
            6|06) _v2ray_restart ;;
            7|07) _v2ray_stop ;;
            8|08)
                echo -ne "\n\033[1;31m¿Seguro que desea DESINSTALAR V2Ray? [s/N]: \033[1;37m"
                read _cfm
                [[ "$_cfm" =~ ^[sSyY]$ ]] && _v2ray_uninstall ;;
            9|09) _v2ray_install
                  if _v2ray_installed; then
                      _v2ray_rebuild_config
                      _v2ray_write_route_conf
                      systemctl enable "$_V2RAY_SERVICE" >/dev/null 2>&1
                      systemctl restart "$_V2RAY_SERVICE" 2>/dev/null
                      _v2ray_reload_wsproxy
                  fi
                  sleep 2 ;;
            0|00) return ;;
            *) echo -e "\033[1;31mOpción inválida!\033[0m"; sleep 1 ;;
        esac
    done
}
