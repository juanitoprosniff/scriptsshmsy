#!/bin/bash
# socks5.sh - Servidor SOCKS5 (hev-socks5-server)
# Creado y modificado por t:me/JuanitoProSniif
#
# ============================================================================
#  QUE ES Y POR DONDE ENTRA
# ============================================================================
#  Es el otro extremo del motor SOCKS5 de la app. Escucha SOLO en 127.0.0.1 y
#  todo le llega por el mismo camino que al SSH:
#
#      cliente -> HAProxy (80/443/8080/8443...) -> wsproxy -> aqui
#
#  Por eso no hay que abrir ni un puerto nuevo: usa los planos y los TLS que ya
#  estan configurados en proxy.sh, con los mismos payloads. El wsproxy lo
#  reconoce por el saludo SOCKS5 del cliente, igual que reconoce OpenVPN por su
#  primer paquete.
#
#  NUNCA ponerlo a escuchar en 0.0.0.0: quedaria un proxy abierto en internet.
#
# ============================================================================
#  AUTENTICACION
# ============================================================================
#  Contra la MISMA base de usuarios que el SSH ($USERS_DB + $SENHA_DIR), asi
#  que una cuenta creada con el menu sirve para los dos sin tocar nada. El
#  archivo de auth se regenera al crear, borrar o cambiar la contrasena de un
#  usuario, y se recarga en caliente con SIGUSR1 — sin reiniciar el servicio y
#  sin cortar a nadie.
#
# ============================================================================
#  UDP
# ============================================================================
#  El servidor soporta las dos formas: UDP ASSOCIATE (el estandar) y FWD UDP
#  (UDP dentro de la propia conexion TCP). La app usa SIEMPRE la segunda,
#  porque es la unica que atraviesa el payload y el TLS. Por eso aqui no se
#  configura udp-port ni se abre nada en el firewall: el UDP viaja por el mismo
#  443 que el resto.
#
#  Esto es lo que hace que con SOCKS5 funcionen los juegos y las llamadas sin
#  badvpn-udpgw, que ademas tiene tope de flujos por cliente.
[[ -n "$BASE_DIR" ]] || source /etc/msyvpn/lib.sh

S5_BIN="/usr/bin/hev-socks5-server"
S5_CFG="$BASE_DIR/socks5.yml"
S5_AUTH="$DATA_DIR/socks5.auth"

# ============================================================================
#  POR QUE NO CORRE COMO ROOT
# ============================================================================
#  El firewall de salida (firewall.sh) limita el escaneo y la fuerza bruta con
#  reglas "-m owner ! --uid-owner 0": solo pisan a los procesos que NO son
#  root. Con el SSH eso funciona porque cada tunel corre con el UID de su
#  usuario, asi que el limite le aplica.
#
#  Si este servidor corriera como root, todo el trafico de sus usuarios saldria
#  con UID 0 y se saltaria esas reglas: quedaria una via para escanear y hacer
#  fuerza bruta desde la VPS sin ningun tope, justo lo que el firewall existe
#  para evitar. Con un usuario propio, el SOCKS5 queda sujeto a lo mismo que el
#  SSH.
#
#  No necesita privilegios: escucha en el 1080, muy por encima del 1024.
S5_USER="msyvpns5"
S5_SRC="https://github.com/heiher/hev-socks5-server"
S5_PORT_DEF=1080

# ============================================================================
#  SOBRE EL LIMITE DE CONEXIONES POR CUENTA
# ============================================================================
#  hev-socks5-server admite una tercera columna en el archivo de auth con una
#  "marca" por usuario: la pone en los sockets de salida (SO_MARK) y entonces
#  una regla de iptables con connlimit puede cortar al que se pase.
#
#  Aqui NO se usa, y es a proposito: poner SO_MARK necesita CAP_NET_ADMIN, y
#  esa capacidad tambien permite reescribir el firewall. Darsela al proceso que
#  atiende a los usuarios seria peor que el problema que resuelve — y mas
#  cuando el limite de la base de usuarios tampoco corta en SSH, donde se
#  muestra en el menu pero es informativo.
#
#  Si algun dia hace falta de verdad, la via limpia es contar fuera del
#  proceso, no meter una capacidad dentro.

s5_installed() { [[ -x "$S5_BIN" ]]; }

# Usuario de sistema sin shell ni home. Idempotente.
s5_ensure_user() {
    id "$S5_USER" >/dev/null 2>&1 && return 0
    useradd --system --no-create-home --shell /usr/sbin/nologin "$S5_USER" 2>/dev/null \
        || useradd -r -M -s /bin/false "$S5_USER" 2>/dev/null
    id "$S5_USER" >/dev/null 2>&1
}
s5_port()      { cat "$DATA_DIR/socks5.port" 2>/dev/null || echo "$S5_PORT_DEF"; }

# ---------------------------------------------------------------
# Instalacion del binario
# ---------------------------------------------------------------

# Primero el binario del repo (instantaneo), y si no hay para esta
# arquitectura se compila. Compilar tarda ~1 min y necesita git y compilador,
# pero funciona en cualquier arquitectura sin que haya que subir nada.
s5_fetch() {
    if fetch_bin hev-socks5-server "$S5_BIN" 2>/dev/null && [[ -s "$S5_BIN" ]]; then
        chmod +x "$S5_BIN"
        # El binario del repo puede ser de otra arquitectura: si no ejecuta,
        # se descarta y se compila. Sin esta comprobacion el servicio quedaba
        # en bucle de reinicio con "Exec format error".
        if "$S5_BIN" --version >/dev/null 2>&1 || "$S5_BIN" 2>&1 | grep -qi 'usage\|config'; then
            info "hev-socks5-server: binario del repo ($(arch))"
            return 0
        fi
        rm -f "$S5_BIN"
    fi
    s5_build
}

s5_build() {
    info "Compilando hev-socks5-server para $(arch) (tarda un minuto)..."
    ensure_pkg git build-essential
    command -v git >/dev/null 2>&1 || { err "Falta git"; return 1; }
    command -v make >/dev/null 2>&1 || { err "Falta make (build-essential)"; return 1; }

    local tmp="/tmp/hev-socks5-server.$$"
    rm -rf "$tmp"
    # --recursive es obligatorio: el core y el sistema de tareas son submodulos
    # y sin ellos el make falla con cientos de errores de cabeceras.
    git clone --recursive --depth 1 "$S5_SRC" "$tmp" >/dev/null 2>&1 \
        || { err "No se pudo descargar el codigo de hev-socks5-server"; rm -rf "$tmp"; return 1; }

    # ENABLE_STATIC: sin dependencias de libc en tiempo de ejecucion, asi el
    # binario sobrevive a una actualizacion del sistema.
    ( cd "$tmp" && make ENABLE_STATIC=1 -j"$(nproc 2>/dev/null || echo 1)" >/dev/null 2>&1 )
    if [[ -s "$tmp/bin/hev-socks5-server" ]]; then
        cp -f "$tmp/bin/hev-socks5-server" "$S5_BIN"
        chmod +x "$S5_BIN"
        rm -rf "$tmp"
        ok "hev-socks5-server compilado"
        return 0
    fi
    rm -rf "$tmp"
    err "Fallo la compilacion de hev-socks5-server"
    return 1
}

# ---------------------------------------------------------------
# Configuracion
# ---------------------------------------------------------------

s5_write_config() {
    local port; port=$(s5_port)
    local nthr; nthr=$(nproc 2>/dev/null || echo 2)
    cat > "$S5_CFG" <<EOF
main:
  # Un hilo por nucleo: el servidor es asincrono y escala con ellos.
  workers: $nthr
  port: $port
  # SOLO loopback. Todo entra por HAProxy -> wsproxy; publicarlo en 0.0.0.0
  # dejaria un proxy abierto a internet.
  listen-address: '127.0.0.1'
  listen-ipv6-only: false
  # unspec: si el destino es un dominio, resuelve y usa lo que haya (A o AAAA).
  # Asi el cliente sale por IPv6 cuando el sitio solo tiene IPv6.
  domain-address-type: unspec
  mark: 0

auth:
  file: $S5_AUTH

misc:
  task-stack-size: 20480
  connect-timeout: 10000
  tcp-read-write-timeout: 300000
  udp-read-write-timeout: 60000
  log-file: null
  log-level: error
  limit-nofile: 100000
EOF
    # Lo lee el proceso, que no es root. 600 y con dueno propio: nadie mas
    # llega a el, y ahi dentro esta la ruta del archivo de contrasenas.
    chown "$S5_USER" "$S5_CFG" 2>/dev/null
    chmod 600 "$S5_CFG"
}

# Genera el archivo de autenticacion desde la base de usuarios del SSH.
#
# Formato: <usuario> <contrasena>
# (la tercera columna, la marca, no se usa: ver la nota del principio)
s5_write_auth() {
    local usuario limite pass saltados=0
    : > "$S5_AUTH.tmp"

    while read -r usuario limite; do
        [[ -z "$usuario" ]] && continue
        id "$usuario" >/dev/null 2>&1 || continue
        pass=$(cat "$SENHA_DIR/$usuario" 2>/dev/null)
        [[ -z "$pass" ]] && continue

        # El formato separa por espacios, asi que una contrasena con espacios
        # partiria la linea y el usuario no entraria nunca. Mejor dejarlo
        # fuera y decirlo que dejar una cuenta rota en silencio.
        if [[ "$pass" =~ [[:space:]] ]]; then
            saltados=$((saltados+1))
            continue
        fi

        echo "$usuario $pass" >> "$S5_AUTH.tmp"
    done < <(cat "$USERS_DB" 2>/dev/null)

    mv -f "$S5_AUTH.tmp" "$S5_AUTH"
    # Contrasenas en claro: solo el proceso que las necesita.
    chown "$S5_USER" "$S5_AUTH" 2>/dev/null
    chmod 600 "$S5_AUTH"

    [[ $saltados -gt 0 ]] && \
        err "$saltados cuenta(s) omitidas: su contrasena tiene espacios y SOCKS5 no las admite"
    return 0
}

# Recarga el auth en caliente. Sin reinicio y sin cortar a los conectados.
s5_reload_auth() {
    s5_installed || return 0
    [[ -f "$S5_CFG" ]] || return 0
    s5_write_auth
    pkill -SIGUSR1 -x hev-socks5-server 2>/dev/null
    return 0
}

s5_write_route() {
    sed -i '/^SOCKS5=/d' "$ROUTES_CONF" 2>/dev/null
    echo "SOCKS5=127.0.0.1:$(s5_port)" >> "$ROUTES_CONF"
    svc_restart msyvpn-wsproxy
}

# ---------------------------------------------------------------
# Servicio
# ---------------------------------------------------------------

# s5_setup [puerto] — sin preguntar nada, para el instalador.
s5_setup() {
    local port="${1:-$S5_PORT_DEF}"
    [[ "$port" =~ ^[0-9]+$ ]] || port=$S5_PORT_DEF
    echo "$port" > "$DATA_DIR/socks5.port"

    s5_installed || s5_fetch || return 1
    s5_ensure_user || { err "No se pudo crear el usuario $S5_USER"; return 1; }
    s5_write_config
    s5_write_auth

    cat > /etc/systemd/system/msyvpn-socks5.service <<EOF
[Unit]
Description=MSYVPN SOCKS5 (hev-socks5-server)
After=network.target

[Service]
# Sin privilegios: asi el firewall de salida le aplica el anti-escaneo, que
# solo pisa a los procesos que no son root. Ver la nota de arriba del archivo.
User=$S5_USER
Group=$S5_USER
ExecStart=$S5_BIN $S5_CFG
ExecReload=/bin/kill -USR1 \$MAINPID
StandardOutput=null
StandardError=null
Restart=always
RestartSec=2
MemoryMax=512M
# El limite lo pone systemd, no el proceso: sin privilegios no podria subir
# el suyo por encima del limite duro heredado.
LimitNOFILE=100000
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now msyvpn-socks5 >/dev/null 2>&1
    svc_restart msyvpn-socks5
    s5_write_route
    sleep 1
    svc_active msyvpn-socks5
}

s5_remove() {
    systemctl disable --now msyvpn-socks5 >/dev/null 2>&1
    rm -f /etc/systemd/system/msyvpn-socks5.service
    systemctl daemon-reload
    sed -i '/^SOCKS5=/d' "$ROUTES_CONF" 2>/dev/null
    svc_restart msyvpn-wsproxy
    ok "SOCKS5 detenido (el binario y las cuentas se conservan)"
}

s5_info() {
    line
    if s5_installed && [[ -f "$S5_CFG" ]]; then
        echo "Servidor  : $(get_ip)"
        # _plain_ports/_tls_ports viven en proxy.sh. Al entrar por el menu ya
        # esta cargado, pero este modulo tambien se usa desde users.sh, que no
        # lo carga: sin el respaldo, la linea saldria con un "command not found".
        if declare -F _plain_ports >/dev/null 2>&1; then
            echo "Puertos   : los mismos del proxy — planos $(_plain_ports) / TLS $(_tls_ports)"
        else
            echo "Puertos   : los mismos que ya usa el proxy (menu -> Proxy / SSL)"
        fi
        echo "Interno   : 127.0.0.1:$(s5_port)  (no expuesto)"
        echo "Cuentas   : $(wc -l < "$S5_AUTH" 2>/dev/null || echo 0) (las mismas del SSH)"
        svc_active msyvpn-socks5 && echo "Estado    : $(g activo)" || echo "Estado    : $(r inactivo)"
        echo ""
        echo "En la app: modo Custom -> Ajustes -> Motor de conexion -> SOCKS5."
        echo "El payload, el SNI y el puerto son los MISMOS que ya usas con SSH."
    else
        echo "SOCKS5 no instalado."
    fi
    line
}

s5_menu() {
    while true; do
        clear; title "SOCKS5  (hev-socks5-server)"
        s5_info
        echo "  1) Instalar / Reconfigurar"
        echo "  2) Regenerar cuentas y recargar"
        echo "  3) Cambiar puerto interno"
        echo "  4) Reiniciar"
        echo "  5) Detener y quitar"
        echo "  0) Volver"
        line
        case "$(ask 'Opcion: ')" in
            1) s5_setup && ok "SOCKS5 activo" || err "No se pudo activar"; pause ;;
            2) s5_reload_auth && ok "Cuentas regeneradas y recargadas"; pause ;;
            3) s5_setup "$(ask 'Puerto interno [1080]: ')"; pause ;;
            4) svc_restart msyvpn-socks5; ok "Reiniciado"; pause ;;
            5) s5_remove; pause ;;
            0) return ;;
        esac
    done
}
