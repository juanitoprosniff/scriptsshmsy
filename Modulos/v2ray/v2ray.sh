#!/bin/bash
# ============================================================
# * Creado y modificado por t:me/JuanitoProSniff
# ============================================================
# V2RAY_MODULE_VERSION: msyvpn-v2ray-5
#
# MÓDULO V2RAY VLESS — MSYVPN-SCRIPT
# - Protocolo: VLESS sobre WebSocket (path /vless)
# - V2Ray escucha SOLO en 127.0.0.1:10086 (texto plano)
# - Coexiste con wsproxy / stunnel / OpenSSH / Dropbear
#   compartiendo los mismos puertos públicos.
# - 3 modos de cliente con la misma config interna:
#     · NGINX + Let's Encrypt (cert real, dominio)
#     · TLS self-signed via stunnel (Default SNI / Bug location)
#     · HTTP plano via wsproxy   (Reverse SNI / Bug as address)
# Compatible: Ubuntu 18 / 20 / 22 / 24 / 25 / 26 / 27
# Arquitectura: amd64 / arm64 / arm (oficial v2fly)
# ============================================================

_V2RAY_DIR="/etc/v2ray"
# IMPORTANTE: el instalador oficial v2fly espera la config en
# /usr/local/etc/v2ray/config.json (lo define el unit systemd).
# Si escribimos en otro lado, V2Ray arranca pero carga el sample vacío
# y no escucha en 10086. Por eso usamos la ruta oficial.
_V2RAY_OFFICIAL_DIR="/usr/local/etc/v2ray"
_V2RAY_CONFIG="$_V2RAY_OFFICIAL_DIR/config.json"
_V2RAY_USERS_DB="$_V2RAY_DIR/users.db"
_V2RAY_DOMAIN_FILE="$_V2RAY_DIR/domain"
_V2RAY_DEFAULT_UUID_FILE="$_V2RAY_DIR/default.uuid"
_V2RAY_CERT_DIR="$_V2RAY_DIR/cert"
_V2RAY_CERT="$_V2RAY_CERT_DIR/cert.crt"
_V2RAY_CERT_KEY="$_V2RAY_CERT_DIR/cert.key"
_V2RAY_BIN_CANDIDATES=("/usr/local/bin/v2ray" "/usr/bin/v2ray")
_V2RAY_SERVICE="v2ray"
_V2RAY_INTERNAL_PORT="10086"
_V2RAY_WS_PATH="/vless"
_V2RAY_ROUTE_CONF="/etc/SSHPlus/v2ray-route.conf"
_V2RAY_NGINX_PORT="8443"
_V2RAY_NGINX_HTTP_PORT="8880"
_V2RAY_REPO_BASE="${_REPO_BASE:-https://raw.githubusercontent.com/juanitoprosniff/scriptsshmsy/main}"
_V2RAY_WSPROXY_PATH="/etc/SSHPlus/wsproxy.py"
_V2RAY_WSPROXY_VERSION="msyvpn-v2ray-2"

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

# ============================================================
# ASEGURAR wsproxy.py actualizado con detección V2Ray
# Verifica el marker WSPROXY_VERSION y descarga si es viejo.
# ============================================================
_v2ray_ensure_wsproxy_updated() {
    mkdir -p /etc/SSHPlus
    local _ok=0
    if [[ -s "$_V2RAY_WSPROXY_PATH" ]] && \
       grep -q "WSPROXY_VERSION: ${_V2RAY_WSPROXY_VERSION}" "$_V2RAY_WSPROXY_PATH" 2>/dev/null; then
        _ok=1
    fi
    if [[ "$_ok" = 0 ]]; then
        echo -e "\033[1;33m  wsproxy.py desactualizado — actualizando...\033[0m"
        cp -f "$_V2RAY_WSPROXY_PATH" "${_V2RAY_WSPROXY_PATH}.bak.$(date +%s)" 2>/dev/null
        wget -q --timeout=30 \
            "${_V2RAY_REPO_BASE}/Modulos/proxy/wsproxy.py" \
            -O "${_V2RAY_WSPROXY_PATH}.new"
        if [[ -s "${_V2RAY_WSPROXY_PATH}.new" ]] && \
           grep -q "WSPROXY_VERSION: ${_V2RAY_WSPROXY_VERSION}" "${_V2RAY_WSPROXY_PATH}.new"; then
            mv -f "${_V2RAY_WSPROXY_PATH}.new" "$_V2RAY_WSPROXY_PATH"
            chmod 755 "$_V2RAY_WSPROXY_PATH"
            echo -e "\033[1;32m  ✓ wsproxy.py actualizado a $_V2RAY_WSPROXY_VERSION\033[0m"
            return 0
        fi
        rm -f "${_V2RAY_WSPROXY_PATH}.new" 2>/dev/null
        echo -e "\033[1;31m  ✗ No se pudo descargar wsproxy.py de:\033[0m"
        echo -e "\033[1;33m    ${_V2RAY_REPO_BASE}/Modulos/proxy/wsproxy.py\033[0m"
        echo -e "\033[1;33m    Verifique conexión o suba el archivo manualmente.\033[0m"
        return 1
    fi
    return 0
}

# ── UUID por defecto persistente (sobrevive reinstalaciones) ──
_v2ray_get_default_uuid() {
    if [[ -s "$_V2RAY_DEFAULT_UUID_FILE" ]]; then
        local _u; _u=$(head -1 "$_V2RAY_DEFAULT_UUID_FILE" | tr -d '[:space:]')
        if _v2ray_valid_uuid "$_u"; then echo "$_u"; return; fi
    fi
    mkdir -p "$_V2RAY_DIR"
    local _new; _new=$(_v2ray_gen_uuid)
    echo "$_new" > "$_V2RAY_DEFAULT_UUID_FILE"
    chmod 600 "$_V2RAY_DEFAULT_UUID_FILE"
    echo "$_new"
}

_v2ray_get_domain() {
    [[ -s "$_V2RAY_DOMAIN_FILE" ]] && head -1 "$_V2RAY_DOMAIN_FILE" | tr -d '[:space:]'
}

# ── Liberar puerto 80 (mata wsproxy, nginx, apache) ───────────
# Devuelve, vía echo, una "etiqueta" con lo que detuvo para
# restaurarlo después.
_v2ray_free_port80() {
    local _had=""
    if ss -tlpn 2>/dev/null | grep -q ':80 '; then
        # nginx
        if systemctl is-active --quiet nginx 2>/dev/null; then
            systemctl stop nginx 2>/dev/null
            _had+="nginx,"
        fi
        # apache
        if systemctl is-active --quiet apache2 2>/dev/null; then
            systemctl stop apache2 2>/dev/null
            _had+="apache2,"
        fi
        # wsproxy en 80
        for pid in $(screen -ls 2>/dev/null | grep -E "\.ws80\b" | awk '{print $1}'); do
            screen -r -S "$pid" -X quit 2>/dev/null
        done
        pkill -f "wsproxy.py 80" 2>/dev/null
        [[ -n "$(pgrep -af 'wsproxy.py 80')" ]] || _had+="ws80,"
        sleep 1
    fi
    # Verificar que quedó libre
    local _i
    for _i in 1 2 3 4 5; do
        ss -tlpn 2>/dev/null | grep -q ':80 ' || { echo "$_had"; return 0; }
        sleep 1
    done
    echo "$_had"
    return 1
}

_v2ray_restore_port80() {
    local _had="$1"
    [[ -z "$_had" ]] && return
    [[ "$_had" = *"nginx,"* ]]    && systemctl start nginx    2>/dev/null
    [[ "$_had" = *"apache2,"* ]]  && systemctl start apache2  2>/dev/null
    if [[ "$_had" = *"ws80,"* ]]; then
        screen -dmS ws80 python3 "$_V2RAY_WSPROXY_PATH" 80 127.0.0.1:22
    fi
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
    # Aseguramos ambos dirs: mio (aux) y oficial (config V2Ray)
    mkdir -p "$_V2RAY_DIR" "$_V2RAY_OFFICIAL_DIR"
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
    apt-get install -y curl wget unzip ca-certificates socat cron >/dev/null 2>&1

    echo -e "\033[1;33mDescargando instalador oficial v2fly...\033[0m"
    local _tmp="/tmp/v2ray_install_$$.sh"
    wget -q --timeout=60 \
        "https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh" \
        -O "$_tmp"

    if [[ ! -s "$_tmp" ]]; then
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

    # Crear directorios de log con permisos correctos para el usuario v2ray
    mkdir -p /var/log/v2ray
    if id nobody >/dev/null 2>&1; then
        chown -R nobody:nogroup /var/log/v2ray 2>/dev/null || \
            chown -R nobody:nobody /var/log/v2ray 2>/dev/null
    fi
    chmod 755 /var/log/v2ray

    echo -e "\033[1;32m✓ V2Ray instalado: $(_v2ray_bin)\033[0m"
    return 0
}

# ============================================================
# VALIDAR config.json con el propio binario V2Ray
# ============================================================
_v2ray_validate_config() {
    local _bin; _bin=$(_v2ray_bin)
    [[ -z "$_bin" ]] && return 0
    [[ ! -s "$_V2RAY_CONFIG" ]] && return 1
    # V2Ray 5.x: "v2ray test -c file"; 4.x: "v2ray -test -config file"
    if "$_bin" test -c "$_V2RAY_CONFIG" >/tmp/v2ray_test.log 2>&1; then
        return 0
    fi
    if "$_bin" -test -config "$_V2RAY_CONFIG" >/tmp/v2ray_test.log 2>&1; then
        return 0
    fi
    return 1
}

# ============================================================
# HEALTH CHECK — verificar que V2Ray esté escuchando
# ============================================================
_v2ray_health_check() {
    local _retries=10 _i
    for ((_i=0; _i<_retries; _i++)); do
        if _v2ray_active && ss -tlpn 2>/dev/null | grep -q "127.0.0.1:${_V2RAY_INTERNAL_PORT} "; then
            return 0
        fi
        sleep 1
    done
    return 1
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

    # Puertos de wsproxy (no-TLS) — escuchando ahora
    local _np
    _np=$(ss -tlpn 2>/dev/null | grep -E 'python|python3' | \
          awk '{print $4}' | rev | cut -d: -f1 | rev | \
          grep -v "^${_V2RAY_INTERNAL_PORT}$" | grep -v "^10443$" | \
          sort -un | xargs)
    _NOTLS_PORTS="$_np"

    # Puertos de stunnel (TLS) — primero del proceso activo, luego del .conf
    local _tp
    _tp=$(ss -tlpn 2>/dev/null | grep -i 'stunnel' | \
          awk '{print $4}' | rev | cut -d: -f1 | rev | \
          sort -un | xargs)
    if [[ -z "$_tp" && -f /etc/stunnel/stunnel.conf ]]; then
        # Cualquier whitespace alrededor de "accept" y "="
        _tp=$(grep -E '^[[:space:]]*accept[[:space:]]*=' /etc/stunnel/stunnel.conf 2>/dev/null | \
              grep -oE '[0-9]+' | sort -un | xargs)
    fi
    _TLS_PORTS="$_tp"
}

_v2ray_show_uris_user() {
    local _uuid="$1" _alias="$2"
    local _ip; _ip=$(_v2ray_ip)
    local _saved_dom; _saved_dom=$(_v2ray_get_domain)
    local _bug
    if [[ -n "$_saved_dom" ]]; then
        echo -ne "\n\033[1;33mDominio BUG (ENTER usa $_saved_dom): \033[1;37m"; read _bug
        [[ -z "$_bug" ]] && _bug="$_saved_dom"
    else
        echo -ne "\n\033[1;33mDominio BUG (ENTER para usar IP $_ip): \033[1;37m"; read _bug
        [[ -z "$_bug" ]] && _bug="$_ip"
    fi
    _bug=$(echo "$_bug" | xargs)

    _v2ray_collect_ports

    # Path siempre es /vless — escapado manualmente, sin dependencia de python
    local _path_enc="%2Fvless"

    # Sanitizar alias para que v2rayNG no se queje del remark
    local _safe_alias
    _safe_alias=$(echo "$_alias" | tr -cd '[:alnum:]_-' | head -c 24)
    [[ -z "$_safe_alias" ]] && _safe_alias="user"

    # Puertos nginx (cert real) si están configurados
    local _ng_tls="" _ng_http=""
    if [[ -s "$_V2RAY_DIR/nginx.ports" ]]; then
        IFS='|' read -r _ng_tls _ng_http < "$_V2RAY_DIR/nginx.ports"
    fi

    echo ""
    echo -e "\033[0;34m┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\033[0m"
    echo -e "\033[0;34m┃\E[44;1;37m   URIs V2RAY VLESS — ${_safe_alias}              \E[0m\033[0;34m┃"
    echo -e "\033[0;34m┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\033[0m"
    echo -e "\033[1;33m  UUID   : \033[1;37m$_uuid"
    echo -e "\033[1;33m  Path   : \033[1;37m${_V2RAY_WS_PATH}"
    echo -e "\033[1;33m  IP VPS : \033[1;37m$_ip"
    echo -e "\033[1;33m  Bug    : \033[1;37m$_bug"
    [[ -n "$_saved_dom" ]] && echo -e "\033[1;33m  Dominio: \033[1;37m$_saved_dom"

    # ── Modo 0: NGINX con cert real (recomendado) ────────────────
    if [[ -n "$_ng_tls" && -s "$_V2RAY_CERT" && -n "$_saved_dom" ]]; then
        echo ""
        echo -e "\033[1;32m── Modo NGINX + Let's Encrypt (cert real) ─────────\033[0m"
        local _uri_n="vless://${_uuid}@${_saved_dom}:${_ng_tls}?type=ws&encryption=none&security=tls&sni=${_saved_dom}&host=${_saved_dom}&path=${_path_enc}#${_safe_alias}-cert-${_ng_tls}"
        echo -e "  \033[1;37m• Cert válido puerto $_ng_tls:\033[0m"
        echo -e "    \033[1;36m$_uri_n\033[0m"
        if [[ -n "$_ng_http" ]]; then
            local _uri_nh="vless://${_uuid}@${_saved_dom}:${_ng_http}?type=ws&encryption=none&security=none&host=${_saved_dom}&path=${_path_enc}#${_safe_alias}-ngx-${_ng_http}"
            echo -e "  \033[1;37m• HTTP nginx puerto $_ng_http:\033[0m"
            echo -e "    \033[1;36m$_uri_nh\033[0m"
        fi
    fi

    # ── Modo 1: Default SNI / Bug location (TLS self-signed) ─────
    echo ""
    echo -e "\033[1;32m── Modo TLS  (Default SNI / Bug location) ─────────\033[0m"
    if [[ -z "$_TLS_PORTS" ]]; then
        echo -e "\033[1;31m  Sin puertos TLS activos (stunnel). Active SSL Tunnel primero.\033[0m"
    else
        echo -e "\033[1;37m  Address=IP VPS · SNI=Bug · marcar 'allowInsecure' en la app\033[0m"
        for _p in $_TLS_PORTS; do
            local _uri="vless://${_uuid}@${_ip}:${_p}?type=ws&encryption=none&security=tls&sni=${_bug}&host=${_bug}&path=${_path_enc}#${_safe_alias}-tls-${_p}"
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
        echo -e "\033[1;37m  Variante A: Address=Bug   → solo funciona si el DNS del bug"
        echo -e "                                  apunta al VPS (Cloudflare proxy en"
        echo -e "                                  puertos 80/8080/8880/2086 — NO 8888)"
        echo -e "\033[1;37m  Variante B: Address=IP    → funciona siempre, Host=Bug en HTTP\033[0m"
        for _p in $_NOTLS_PORTS; do
            local _uri_a="vless://${_uuid}@${_bug}:${_p}?type=ws&encryption=none&security=none&host=${_bug}&path=${_path_enc}#${_safe_alias}-bug-${_p}"
            local _uri_b="vless://${_uuid}@${_ip}:${_p}?type=ws&encryption=none&security=none&host=${_bug}&path=${_path_enc}#${_safe_alias}-ip-${_p}"
            echo -e "  \033[1;37m• Puerto $_p — A (bug as address):\033[0m"
            echo -e "    \033[1;36m$_uri_a\033[0m"
            echo -e "  \033[1;37m• Puerto $_p — B (IP + Host=bug):\033[0m"
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
# CONFIGURAR DOMINIO (Cloudflare / DNS apuntando al VPS)
# ============================================================
_v2ray_set_domain() {
    local _current; _current=$(_v2ray_get_domain)
    echo ""
    [[ -n "$_current" ]] && echo -e "\033[1;33mDominio actual: \033[1;37m$_current\033[0m"
    echo -ne "\n\033[1;32mIngrese dominio (ej: vpn.tudominio.com, ENTER para mantener): \033[1;37m"
    read _dom
    _dom=$(echo "$_dom" | xargs | tr 'A-Z' 'a-z')
    [[ -z "$_dom" ]] && return 0
    if ! [[ "$_dom" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]]; then
        echo -e "\033[1;31m✗ Dominio inválido.\033[0m"; sleep 2; return 1
    fi
    mkdir -p "$_V2RAY_DIR"
    echo "$_dom" > "$_V2RAY_DOMAIN_FILE"
    echo -e "\033[1;32m✓ Dominio guardado: $_dom\033[0m"

    # Verificar que apunta al VPS
    local _vps_ip; _vps_ip=$(_v2ray_ip)
    local _dns_ip
    _dns_ip=$(getent hosts "$_dom" 2>/dev/null | awk '{print $1}' | head -1)
    [[ -z "$_dns_ip" ]] && _dns_ip=$(dig +short "$_dom" 2>/dev/null | tail -1)
    if [[ -n "$_dns_ip" ]]; then
        if [[ "$_dns_ip" = "$_vps_ip" ]]; then
            echo -e "\033[1;32m✓ DNS apunta correctamente a $_vps_ip\033[0m"
        else
            echo -e "\033[1;33m⚠ DNS apunta a $_dns_ip pero VPS es $_vps_ip\033[0m"
            echo -e "\033[1;33m  Cloudflare en modo proxy (naranja) muestra IP de CF — eso es normal.\033[0m"
        fi
    else
        echo -e "\033[1;33m⚠ No se pudo resolver $_dom — espere unos minutos.\033[0m"
    fi
    sleep 2
    return 0
}

# ============================================================
# OBTENER CERTIFICADO TLS — acme.sh + Let's Encrypt (standalone)
# Requiere puerto 80 libre durante el challenge.
# ============================================================
_v2ray_issue_cert() {
    local _dom; _dom=$(_v2ray_get_domain)
    if [[ -z "$_dom" ]]; then
        echo -e "\033[1;31m✗ Primero configure un dominio (opción Dominio).\033[0m"
        sleep 2; return 1
    fi

    echo -e "\n\033[1;33mPreparando emisión de certificado para: \033[1;37m$_dom\033[0m"
    echo -e "\033[1;33mRequisitos:\033[0m"
    echo -e "  \033[1;37m• DNS A record apuntando al IP del VPS\033[0m"
    echo -e "  \033[1;37m• Cloudflare en modo 'DNS only' (nube gris) — no proxy\033[0m"
    echo -e "  \033[1;37m• Puerto 80 accesible desde Internet\033[0m"
    echo -ne "\n\033[1;32m¿Continuar? [s/N]: \033[1;37m"; read _c
    [[ ! "$_c" =~ ^[sSyY]$ ]] && return 1

    apt-get install -y socat curl cron tar >/dev/null 2>&1

    # Instalar acme.sh si no existe
    if [[ ! -x /root/.acme.sh/acme.sh ]]; then
        echo -e "\033[1;33mInstalando acme.sh...\033[0m"
        local _ok=0

        # Método 1: tarball oficial directo (más confiable, sin wrappers)
        rm -rf /tmp/acme.sh-master /tmp/acme.tgz 2>/dev/null
        curl -fsSL --max-time 60 \
            "https://github.com/acmesh-official/acme.sh/archive/refs/heads/master.tar.gz" \
            -o /tmp/acme.tgz 2>/tmp/acme_install.log
        if [[ -s /tmp/acme.tgz ]]; then
            tar xzf /tmp/acme.tgz -C /tmp 2>>/tmp/acme_install.log
            if [[ -x /tmp/acme.sh-master/acme.sh ]]; then
                ( cd /tmp/acme.sh-master && \
                  ./acme.sh --install --no-cron \
                      --home /root/.acme.sh \
                      -m "admin@${_dom}" \
                      >>/tmp/acme_install.log 2>&1 )
                [[ -x /root/.acme.sh/acme.sh ]] && _ok=1
            fi
        fi

        # Método 2: wrapper get.acme.sh (sin flags ofensivos)
        if [[ $_ok -eq 0 ]]; then
            echo -e "\033[1;33m  Reintentando con get.acme.sh...\033[0m"
            curl -fsSL --max-time 30 https://get.acme.sh -o /tmp/acme.sh.install 2>>/tmp/acme_install.log
            if [[ -s /tmp/acme.sh.install ]]; then
                bash /tmp/acme.sh.install >>/tmp/acme_install.log 2>&1
                [[ -x /root/.acme.sh/acme.sh ]] && _ok=1
            fi
        fi

        rm -f /tmp/acme.sh.install /tmp/acme.tgz 2>/dev/null
        rm -rf /tmp/acme.sh-master 2>/dev/null
    fi
    if [[ ! -x /root/.acme.sh/acme.sh ]]; then
        echo -e "\033[1;31m✗ No se pudo instalar acme.sh.\033[0m"
        echo -e "\033[1;33m  Últimas líneas del log:\033[0m"
        tail -n 12 /tmp/acme_install.log 2>/dev/null
        sleep 4; return 1
    fi
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1
    /root/.acme.sh/acme.sh --register-account -m "admin@${_dom}" >/dev/null 2>&1

    # Verificar que el dominio resuelve
    local _vps_ip; _vps_ip=$(_v2ray_ip)
    local _dns_ip; _dns_ip=$(getent hosts "$_dom" 2>/dev/null | awk '{print $1}' | head -1)
    if [[ -z "$_dns_ip" ]]; then
        echo -e "\033[1;31m✗ El dominio $_dom no resuelve a ninguna IP.\033[0m"
        echo -e "\033[1;33m  Verifique el A record en Cloudflare y espere propagación.\033[0m"
        return 1
    fi
    if [[ "$_dns_ip" != "$_vps_ip" ]]; then
        echo -e "\033[1;33m⚠ DNS apunta a $_dns_ip pero VPS es $_vps_ip.\033[0m"
        echo -e "\033[1;33m  Si Cloudflare está en modo 'proxy' (nube naranja),\033[0m"
        echo -e "\033[1;33m  el challenge HTTP-01 va a fallar. Cámbielo a DNS only.\033[0m"
        echo -ne "\n\033[1;32m¿Intentar de todas formas? [s/N]: \033[1;37m"; read _yes
        [[ ! "$_yes" =~ ^[sSyY]$ ]] && return 1
    fi

    # Liberar puerto 80 robustamente
    echo -e "\033[1;33mLiberando puerto 80 para el challenge HTTP-01...\033[0m"
    local _had; _had=$(_v2ray_free_port80)
    if ss -tlpn 2>/dev/null | grep -q ':80 '; then
        echo -e "\033[1;31m✗ No se pudo liberar el puerto 80.\033[0m"
        echo -e "\033[1;33m  Quien lo tiene: \033[1;37m$(ss -tlpn | grep ':80 ' | awk '{print $6}')\033[0m"
        _v2ray_restore_port80 "$_had"
        return 1
    fi
    echo -e "\033[1;32m  Puerto 80 libre.\033[0m"

    mkdir -p "$_V2RAY_CERT_DIR"
    echo -e "\033[1;33mEmitiendo certificado Let's Encrypt (30-90s)...\033[0m"
    /root/.acme.sh/acme.sh --issue -d "$_dom" --standalone -k ec-256 \
        --force --log /tmp/v2ray_cert.log >>/tmp/v2ray_cert.log 2>&1
    local _rc=$?

    # Restaurar puerto 80 antes de seguir
    _v2ray_restore_port80 "$_had"

    if [[ $_rc -ne 0 ]]; then
        echo -e "\033[1;31m✗ Falló la emisión del certificado (rc=$_rc).\033[0m"
        echo -e "\033[1;33m  Últimas líneas del log:\033[0m"
        tail -n 15 /tmp/v2ray_cert.log 2>/dev/null
        echo -e "\n\033[1;33m  Causas comunes:\033[0m"
        echo -e "\033[1;37m   • Cloudflare en modo proxy (debe ser DNS only)"
        echo -e "   • Firewall del proveedor bloquea puerto 80"
        echo -e "   • Rate limit de Let's Encrypt (5 fails/hr por dominio)\033[0m"
        return 1
    fi

    /root/.acme.sh/acme.sh --installcert -d "$_dom" \
        --fullchainpath "$_V2RAY_CERT" \
        --keypath       "$_V2RAY_CERT_KEY" \
        --ecc \
        --reloadcmd "systemctl reload nginx 2>/dev/null; systemctl restart v2ray 2>/dev/null" \
        >>/tmp/v2ray_cert.log 2>&1
    chmod 644 "$_V2RAY_CERT" 2>/dev/null
    chmod 600 "$_V2RAY_CERT_KEY" 2>/dev/null

    if [[ -s "$_V2RAY_CERT" && -s "$_V2RAY_CERT_KEY" ]]; then
        echo -e "\033[1;32m✓ Certificado emitido y guardado:\033[0m"
        echo -e "\033[1;37m  Cert : $_V2RAY_CERT"
        echo -e "  Key  : $_V2RAY_CERT_KEY\033[0m"
        return 0
    fi
    echo -e "\033[1;31m✗ Certificado no se generó correctamente.\033[0m"
    return 1
}

# ============================================================
# NGINX — termina TLS con certificado real y enruta a V2Ray
# Escucha en puertos alternativos (8443/8880) para coexistir
# con stunnel (443/444/8443) si está activo. Si stunnel no usa
# 8443, lo usaremos nosotros; si lo usa, caemos a otro.
# ============================================================
_v2ray_install_nginx() {
    local _dom; _dom=$(_v2ray_get_domain)
    if [[ -z "$_dom" ]]; then
        echo -e "\033[1;31m✗ Primero configure un dominio (opción 10).\033[0m"; sleep 2; return 1
    fi
    if [[ ! -s "$_V2RAY_CERT" || ! -s "$_V2RAY_CERT_KEY" ]]; then
        echo -e "\033[1;31m✗ Primero emita el certificado (opción 11).\033[0m"; sleep 2; return 1
    fi

    echo -e "\n\033[1;33mInstalando nginx...\033[0m"
    apt-get update -y >/dev/null 2>&1
    apt-get install -y nginx >/tmp/nginx_apt.log 2>&1
    if ! command -v nginx &>/dev/null; then
        echo -e "\033[1;31m✗ No se pudo instalar nginx. Log apt:\033[0m"
        tail -n 12 /tmp/nginx_apt.log 2>/dev/null
        sleep 4; return 1
    fi
    # Asegurar que el site default no compita por 80/443
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null

    # Elegir puertos que NO estén en uso por stunnel
    local _tls_p="$_V2RAY_NGINX_PORT" _http_p="$_V2RAY_NGINX_HTTP_PORT"
    if ss -tlpn 2>/dev/null | grep -q ":${_tls_p} "; then
        for _alt in 2096 2087 2083 2052; do
            ss -tlpn 2>/dev/null | grep -q ":${_alt} " || { _tls_p="$_alt"; break; }
        done
    fi
    if ss -tlpn 2>/dev/null | grep -q ":${_http_p} "; then
        for _alt in 2095 2086 2082 2053; do
            ss -tlpn 2>/dev/null | grep -q ":${_alt} " || { _http_p="$_alt"; break; }
        done
    fi

    mkdir -p /etc/nginx/conf.d
    rm -f /etc/nginx/conf.d/v2ray.conf
    cat > /etc/nginx/conf.d/v2ray.conf <<NGEOF
server {
    listen ${_http_p};
    listen [::]:${_http_p};
    server_name ${_dom};

    location ${_V2RAY_WS_PATH} {
        if (\$http_upgrade != "websocket") {
            return 404;
        }
        proxy_pass http://127.0.0.1:${_V2RAY_INTERNAL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }

    location / {
        return 200 "ok\\n";
        add_header Content-Type text/plain;
    }
}

server {
    listen ${_tls_p} ssl http2;
    listen [::]:${_tls_p} ssl http2;
    server_name ${_dom};

    ssl_certificate     ${_V2RAY_CERT};
    ssl_certificate_key ${_V2RAY_CERT_KEY};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;

    location ${_V2RAY_WS_PATH} {
        if (\$http_upgrade != "websocket") {
            return 404;
        }
        proxy_pass http://127.0.0.1:${_V2RAY_INTERNAL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }

    location / {
        return 200 "ok\\n";
        add_header Content-Type text/plain;
    }
}
NGEOF

    # Guardar puertos en disco para que las URIs los lean
    echo "${_tls_p}|${_http_p}" > "$_V2RAY_DIR/nginx.ports"

    nginx -t >/tmp/nginx_test.log 2>&1
    if [[ $? -ne 0 ]]; then
        echo -e "\033[1;31m✗ Config nginx inválida:\033[0m"
        tail -n 8 /tmp/nginx_test.log
        return 1
    fi
    systemctl enable nginx >/dev/null 2>&1
    systemctl restart nginx
    sleep 1

    # Abrir puertos en firewall
    if declare -F _fw_open >/dev/null 2>&1; then
        _fw_open "$_tls_p" tcp
        _fw_open "$_http_p" tcp
    else
        iptables -I INPUT -p tcp --dport "$_tls_p" -j ACCEPT 2>/dev/null
        iptables -I INPUT -p tcp --dport "$_http_p" -j ACCEPT 2>/dev/null
    fi
    command -v ufw &>/dev/null && {
        ufw allow "${_tls_p}/tcp" >/dev/null 2>&1
        ufw allow "${_http_p}/tcp" >/dev/null 2>&1
    }

    echo -e "\033[1;32m✓ Nginx activo:\033[0m"
    echo -e "\033[1;33m  TLS (cert real) : \033[1;37mhttps://${_dom}:${_tls_p}${_V2RAY_WS_PATH}\033[0m"
    echo -e "\033[1;33m  HTTP plano       : \033[1;37mhttp://${_dom}:${_http_p}${_V2RAY_WS_PATH}\033[0m"
    return 0
}

_v2ray_uninstall_nginx() {
    if [[ -f /etc/nginx/conf.d/v2ray.conf ]]; then
        rm -f /etc/nginx/conf.d/v2ray.conf
        rm -f "$_V2RAY_DIR/nginx.ports"
        nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null
        echo -e "\033[1;32m✓ Config nginx V2Ray removida.\033[0m"
    fi
    sleep 1
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
    echo -e "\033[1;37m Orden recomendado (VPS limpia):\033[0m"
    echo -e "   \033[1;32m1)\033[1;37m Actualizar wsproxy.py (detección V2Ray /vless)"
    echo -e "   \033[1;32m2)\033[1;37m Instalar V2Ray oficial v2fly"
    echo -e "   \033[1;32m3)\033[1;37m Generar config V2Ray + UUID por defecto"
    echo -e "   \033[1;32m4)\033[1;37m \033[1;36m[opcional]\033[1;37m Dominio + cert Let's Encrypt + nginx"
    echo -e "   \033[1;32m5)\033[1;37m Activar wsproxy en 80, 8080, 8880, 8888, 2086"
    echo -e "   \033[1;32m6)\033[1;37m Activar stunnel en 443, 444, 8443 (self-signed)"
    echo -e "   \033[1;32m7)\033[1;37m Health check de V2Ray"
    echo ""
    echo -ne "\033[1;33m¿Continuar? [s/N]: \033[1;37m"; read _ok
    [[ ! "$_ok" =~ ^[sSyY]$ ]] && return

    # 1. wsproxy.py actualizado
    echo -e "\n\033[1;33m[1/7] Verificando wsproxy.py...\033[0m"
    if ! _v2ray_ensure_wsproxy_updated; then
        echo -e "\033[1;31mAbortado: wsproxy.py no se pudo actualizar.\033[0m"; sleep 4; return
    fi

    # 2. Instalar V2Ray
    echo -e "\n\033[1;33m[2/7] Instalando V2Ray...\033[0m"
    _v2ray_install || { echo -e "\033[1;31mAbortado.\033[0m"; sleep 3; return; }

    # 3. UUID por defecto + config en RUTA OFICIAL
    echo -e "\n\033[1;33m[3/7] Generando config V2Ray + UUID por defecto...\033[0m"
    mkdir -p "$_V2RAY_DIR" "$_V2RAY_OFFICIAL_DIR"
    local _def_uuid; _def_uuid=$(_v2ray_get_default_uuid)
    touch "$_V2RAY_USERS_DB"
    if ! grep -q "^${_def_uuid}|" "$_V2RAY_USERS_DB" 2>/dev/null; then
        echo "${_def_uuid}|default" >> "$_V2RAY_USERS_DB"
    fi
    _v2ray_rebuild_config
    _v2ray_write_route_conf
    if ! _v2ray_validate_config; then
        echo -e "\033[1;31m✗ Config V2Ray inválida:\033[0m"
        tail -n 12 /tmp/v2ray_test.log 2>/dev/null
        echo -e "\033[1;33m  Abortando.\033[0m"; sleep 5; return
    fi
    echo -e "\033[1;32m  ✓ Config válida en $_V2RAY_CONFIG\033[0m"
    echo -e "\033[1;32m  ✓ UUID por defecto: $_def_uuid\033[0m"
    systemctl enable "$_V2RAY_SERVICE" >/dev/null 2>&1
    systemctl restart "$_V2RAY_SERVICE" 2>/dev/null
    sleep 1

    # 4. [Opcional] Dominio + cert + nginx ANTES de wsproxy/stunnel
    #    (necesario para liberar 80 sin conflictos)
    echo -e "\n\033[1;33m[4/7] Configuración con dominio (opcional)\033[0m"
    echo -ne "\033[1;33m¿Configurar dominio + cert TLS Let's Encrypt + nginx ahora? [s/N]: \033[1;37m"
    read _wantdom
    local _nginx_done=0
    if [[ "$_wantdom" =~ ^[sSyY]$ ]]; then
        if _v2ray_set_domain; then
            if _v2ray_issue_cert; then
                _v2ray_install_nginx && _nginx_done=1
            else
                echo -e "\033[1;33m  Saltando nginx — cert no emitido.\033[0m"
            fi
        fi
    else
        echo -e "\033[1;37m  Saltando (puede hacerlo luego con opciones 10/11/12).\033[0m"
    fi

    # 5. wsproxy en puertos estándar
    echo -e "\n\033[1;33m[5/7] Activando wsproxy en 80, 8080, 8880, 8888, 2086...\033[0m"
    for _p in 80 8080 8880 8888 2086; do
        if ss -tlpn 2>/dev/null | grep -q ":${_p} "; then
            # Saltar si nginx lo está usando (80 si activamos nginx en ese puerto)
            if [[ "$_nginx_done" = 1 && "$_p" = "80" ]] && ss -tlpn 2>/dev/null | grep ":80 " | grep -q nginx; then
                echo -e "\033[1;33m  Puerto 80 usado por nginx, saltando wsproxy.\033[0m"
                continue
            fi
            # Si es wsproxy viejo, lo reemplazamos
            local _is_ws
            _is_ws=$(ss -tlpn 2>/dev/null | grep ":${_p} " | grep -c 'python')
            if [[ "$_is_ws" -gt 0 ]]; then
                for pid in $(screen -ls 2>/dev/null | grep "\.ws${_p}" | awk '{print $1}'); do
                    screen -r -S "$pid" -X quit 2>/dev/null
                done
                pkill -f "wsproxy.py ${_p}" 2>/dev/null
                sleep 0.5
            else
                echo -e "\033[1;33m  Puerto $_p ocupado por otro servicio, saltando.\033[0m"
                continue
            fi
        fi
        screen -dmS "ws${_p}" python3 "$_V2RAY_WSPROXY_PATH" "$_p" "127.0.0.1:22"
        sed -i "\|wsproxy.py ${_p}|d" /etc/autostart 2>/dev/null
        echo "ss -tlpn | grep -qw ${_p} || screen -dmS ws${_p} python3 ${_V2RAY_WSPROXY_PATH} ${_p} 127.0.0.1:22" >> /etc/autostart
        if declare -F _fw_open >/dev/null 2>&1; then _fw_open "$_p" tcp
        else iptables -I INPUT -p tcp --dport "$_p" -j ACCEPT 2>/dev/null
        fi
        sleep 0.4
        ss -tlpn 2>/dev/null | grep -q ":${_p} " && \
            echo -e "\033[1;32m  ✓ Puerto $_p activo (wsproxy → SSH/V2Ray)\033[0m" || \
            echo -e "\033[1;31m  ✗ Puerto $_p no respondió\033[0m"
    done

    # 6. SSL Tunnel + dispatcher
    echo -e "\n\033[1;33m[6/7] Activando SSL Tunnel + Dispatcher...\033[0m"
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
        # Si nginx ya está en 8443, no insistimos
        if ss -tlpn 2>/dev/null | grep ":${_p} " | grep -q nginx; then
            echo -e "\033[1;33m  Puerto $_p usado por nginx, saltando stunnel.\033[0m"
            continue
        fi
        if declare -F _fw_open >/dev/null 2>&1; then _fw_open "$_p" tcp
        else iptables -I INPUT -p tcp --dport "$_p" -j ACCEPT 2>/dev/null
        fi
    done
    systemctl restart stunnel4 2>/dev/null || service stunnel4 restart 2>/dev/null

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

    # 6b. badvpn-udpgw en 7300 (UDP gateway para clientes SSH)
    echo -e "\n\033[1;33m[6b/7] Activando badvpn-udpgw en 7300...\033[0m"
    if [[ ! -x /bin/badvpn-udpgw ]]; then
        wget -q --timeout=30 \
            "${_V2RAY_REPO_BASE}/Install/badvpn-udpgw" \
            -O /bin/badvpn-udpgw 2>/dev/null
        chmod +x /bin/badvpn-udpgw 2>/dev/null
    fi
    if [[ -x /bin/badvpn-udpgw ]]; then
        if ! pgrep -f 'badvpn-udpgw.*7300' >/dev/null 2>&1; then
            screen -dmS udpvpn /bin/badvpn-udpgw \
                --listen-addr 127.0.0.1:7300 \
                --max-clients 10000 \
                --max-connections-for-client 8 \
                --client-socket-sndbuf 10000
            grep -q 'udpvpn' /etc/autostart 2>/dev/null || \
                echo "ps x | grep 'udpvpn' | grep -v 'grep' || screen -dmS udpvpn /bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 10000 --max-connections-for-client 8 --client-socket-sndbuf 10000" >> /etc/autostart
            sleep 0.5
            pgrep -f 'badvpn-udpgw.*7300' >/dev/null && \
                echo -e "\033[1;32m  ✓ badvpn 7300 activo\033[0m" || \
                echo -e "\033[1;31m  ✗ badvpn no arrancó\033[0m"
        else
            echo -e "\033[1;37m  badvpn ya estaba corriendo\033[0m"
        fi
    else
        echo -e "\033[1;33m  badvpn-udpgw no disponible, saltando.\033[0m"
    fi

    # 7. Health check final
    echo -e "\n\033[1;33m[7/7] Verificando salud de V2Ray...\033[0m"
    if _v2ray_health_check; then
        echo -e "\033[1;32m  ✓ V2Ray escuchando en 127.0.0.1:${_V2RAY_INTERNAL_PORT}\033[0m"
    else
        echo -e "\033[1;31m  ✗ V2Ray NO está escuchando. Diagnóstico:\033[0m"
        echo -e "\033[1;33m  • Config en uso: $_V2RAY_CONFIG\033[0m"
        ls -la "$_V2RAY_CONFIG" 2>/dev/null
        echo -e "\033[1;33m  • Test config:\033[0m"
        _v2ray_validate_config && echo "    válida" || tail -n 6 /tmp/v2ray_test.log 2>/dev/null
        echo -e "\033[1;33m  • journalctl:\033[0m"
        journalctl -u "$_V2RAY_SERVICE" -n 12 --no-pager 2>/dev/null
    fi

    sleep 1
    echo ""
    echo -e "\033[0;34m┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\033[0m"
    echo -e "\033[1;32m✓ V2RAY + WSPROXY + STUNNEL ACTIVOS\033[0m"
    echo -e "\033[1;33m  V2Ray   : \033[1;37m127.0.0.1:${_V2RAY_INTERNAL_PORT}  path ${_V2RAY_WS_PATH}"
    echo -e "\033[1;33m  No-TLS  : \033[1;37m80, 8080, 8880, 8888, 2086"
    echo -e "\033[1;33m  TLS     : \033[1;37m443, 444, 8443 (stunnel self-signed)"
    [[ "$_nginx_done" = 1 ]] && \
        echo -e "\033[1;33m  Nginx   : \033[1;32m✓ cert real Let's Encrypt"
    echo -e "\033[1;33m  UUID    : \033[1;37m$_def_uuid\033[0m"
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

        local _inst_sts _act_sts _route_sts _n_users _ws_sts _dom_sts _cert_sts _nginx_sts
        _v2ray_installed && _inst_sts="\033[1;32m✓ instalado " || _inst_sts="\033[1;31m✕ no instalado"
        _v2ray_active    && _act_sts="\033[1;32m✓ activo"     || _act_sts="\033[1;31m✕ inactivo"
        if [[ -f "$_V2RAY_ROUTE_CONF" ]] && grep -q '^V2RAY_ENABLED=yes' "$_V2RAY_ROUTE_CONF" 2>/dev/null; then
            _route_sts="\033[1;32m✓ activo"
        else
            _route_sts="\033[1;31m✕ inactivo"
        fi
        if [[ -s "$_V2RAY_WSPROXY_PATH" ]] && grep -q "WSPROXY_VERSION: ${_V2RAY_WSPROXY_VERSION}" "$_V2RAY_WSPROXY_PATH"; then
            _ws_sts="\033[1;32m✓ v2 (detecta V2Ray)"
        else
            _ws_sts="\033[1;31m✕ vieja (NO detecta V2Ray)"
        fi
        local _dom; _dom=$(_v2ray_get_domain)
        [[ -n "$_dom" ]] && _dom_sts="\033[1;32m$_dom" || _dom_sts="\033[1;31m✕ sin configurar"
        if [[ -s "$_V2RAY_CERT" && -s "$_V2RAY_CERT_KEY" ]]; then
            _cert_sts="\033[1;32m✓ cert real"
        else
            _cert_sts="\033[1;31m✕ sin cert"
        fi
        if [[ -f /etc/nginx/conf.d/v2ray.conf ]] && systemctl is-active --quiet nginx 2>/dev/null; then
            _nginx_sts="\033[1;32m✓ activo"
        else
            _nginx_sts="\033[1;31m✕ inactivo"
        fi
        _n_users=0
        [[ -s "$_V2RAY_USERS_DB" ]] && _n_users=$(grep -c '^[0-9a-f]' "$_V2RAY_USERS_DB" 2>/dev/null)

        _v2ray_collect_ports
        echo -e "\033[0;34m╼ \033[1;33mV2Ray bin  : $_inst_sts"
        echo -e "\033[0;34m╼ \033[1;33mServicio   : $_act_sts"
        echo -e "\033[0;34m╼ \033[1;33mwsproxy    : $_ws_sts"
        echo -e "\033[0;34m╼ \033[1;33mRuteo cfg  : $_route_sts"
        echo -e "\033[0;34m╼ \033[1;33mDominio    : $_dom_sts"
        echo -e "\033[0;34m╼ \033[1;33mCert TLS   : $_cert_sts"
        echo -e "\033[0;34m╼ \033[1;33mNginx      : $_nginx_sts"
        echo -e "\033[0;34m╼ \033[1;33mUsuarios   : \033[1;37m${_n_users}"
        echo -e "\033[0;34m╼ \033[1;33mInterno    : \033[1;37m127.0.0.1:${_V2RAY_INTERNAL_PORT}  path ${_V2RAY_WS_PATH}"
        echo -e "\033[0;34m╼ \033[1;33mNo-TLS     : \033[1;37m${_NOTLS_PORTS:-—}"
        echo -e "\033[0;34m╼ \033[1;33mTLS        : \033[1;37m${_TLS_PORTS:-—}"

        echo -e "\033[0;34m┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\033[0m"
        echo -e "\033[0;34m┃\033[1;31m[\033[1;36m01\033[1;31m] \033[1;32mACTIVAR TODO  ◄ recomendado         \033[0;34m┃"
        echo -e "\033[0;34m┃\033[1;31m[\033[1;36m02\033[1;31m] \033[1;33mAGREGAR UUID MANUAL                 \033[0;34m┃"
        echo -e "\033[0;34m┃\033[1;31m[\033[1;36m03\033[1;31m] \033[1;33mCREAR UUID AL AZAR                  \033[0;34m┃"
        echo -e "\033[0;34m┃\033[1;31m[\033[1;36m04\033[1;31m] \033[1;33mVER URIs (TLS + HTTP + nginx)       \033[0;34m┃"
        echo -e "\033[0;34m┃\033[1;31m[\033[1;36m05\033[1;31m] \033[1;33mELIMINAR USUARIO                    \033[0;34m┃"
        echo -e "\033[0;34m┃\033[1;31m[\033[1;36m06\033[1;31m] \033[1;33mREINICIAR V2RAY                     \033[0;34m┃"
        echo -e "\033[0;34m┃\033[1;31m[\033[1;36m07\033[1;31m] \033[1;33mDETENER V2RAY (libera puertos)      \033[0;34m┃"
        echo -e "\033[0;34m┃\033[1;31m[\033[1;36m08\033[1;31m] \033[1;33mACTUALIZAR wsproxy.py               \033[0;34m┃"
        echo -e "\033[0;34m┃\033[1;31m[\033[1;36m09\033[1;31m] \033[1;33mINSTALAR V2RAY (solo binario)       \033[0;34m┃"
        echo -e "\033[0;34m┃\033[1;31m[\033[1;36m10\033[1;31m] \033[1;33mCONFIGURAR DOMINIO (Cloudflare)     \033[0;34m┃"
        echo -e "\033[0;34m┃\033[1;31m[\033[1;36m11\033[1;31m] \033[1;33mEMITIR CERT TLS (Let's Encrypt)     \033[0;34m┃"
        echo -e "\033[0;34m┃\033[1;31m[\033[1;36m12\033[1;31m] \033[1;33mACTIVAR NGINX (cert real → V2Ray)   \033[0;34m┃"
        echo -e "\033[0;34m┃\033[1;31m[\033[1;36m13\033[1;31m] \033[1;33mDESACTIVAR NGINX                    \033[0;34m┃"
        echo -e "\033[0;34m┃\033[1;31m[\033[1;36m14\033[1;31m] \033[1;33mVER LOGS V2RAY (Ctrl+C salir)       \033[0;34m┃"
        echo -e "\033[0;34m┃\033[1;31m[\033[1;36m15\033[1;31m] \033[1;31mDESINSTALAR V2RAY                   \033[0;34m┃"
        echo -e "\033[0;34m┃\033[1;31m[\033[1;36m00\033[1;31m] \033[1;33mVOLVER                              \033[0;34m┃"
        echo -e "\033[0;34m┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\033[0m"
        echo -ne "\033[1;32mOpción: \033[1;37m"; read _v2opt

        case "$_v2opt" in
            1|01) _v2ray_activar_todo ;;
            2|02) _v2ray_installed || { echo -e "\033[1;31mInstale V2Ray primero (opción 09 o 01).\033[0m"; sleep 2; continue; }
                  _v2ray_add_user manual ;;
            3|03) _v2ray_installed || { echo -e "\033[1;31mInstale V2Ray primero (opción 09 o 01).\033[0m"; sleep 2; continue; }
                  _v2ray_add_user random ;;
            4|04) _v2ray_show_uris ;;
            5|05) _v2ray_delete_user ;;
            6|06) _v2ray_restart ;;
            7|07) _v2ray_stop ;;
            8|08) _v2ray_ensure_wsproxy_updated && _v2ray_reload_wsproxy
                  echo -e "\033[1;32m✓ wsproxy.py actualizado y relanzado.\033[0m"; sleep 2 ;;
            9|09) _v2ray_install
                  if _v2ray_installed; then
                      _v2ray_get_default_uuid >/dev/null
                      touch "$_V2RAY_USERS_DB"
                      grep -q "^$(_v2ray_get_default_uuid)|" "$_V2RAY_USERS_DB" 2>/dev/null || \
                          echo "$(_v2ray_get_default_uuid)|default" >> "$_V2RAY_USERS_DB"
                      _v2ray_rebuild_config
                      _v2ray_write_route_conf
                      systemctl enable "$_V2RAY_SERVICE" >/dev/null 2>&1
                      systemctl restart "$_V2RAY_SERVICE" 2>/dev/null
                      _v2ray_ensure_wsproxy_updated && _v2ray_reload_wsproxy
                  fi
                  sleep 2 ;;
            10) _v2ray_set_domain ;;
            11) _v2ray_issue_cert ;;
            12) _v2ray_install_nginx ;;
            13) _v2ray_uninstall_nginx ;;
            14) echo -e "\033[1;33mCtrl+C para salir...\033[0m"; sleep 1
                journalctl -u "$_V2RAY_SERVICE" -f --no-pager 2>/dev/null ;;
            15)
                echo -ne "\n\033[1;31m¿Seguro que desea DESINSTALAR V2Ray? [s/N]: \033[1;37m"
                read _cfm
                [[ "$_cfm" =~ ^[sSyY]$ ]] && _v2ray_uninstall ;;
            0|00) return ;;
            *) echo -e "\033[1;31mOpción inválida!\033[0m"; sleep 1 ;;
        esac
    done
}
