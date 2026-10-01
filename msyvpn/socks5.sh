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
# ============================================================================
#  POR QUE AHORA SE COMPILA SIEMPRE, Y NO SE USA EL BINARIO DEL REPO
# ============================================================================
#  hev-socks5-server de upstream tiene un BUCLE A 100% DE CPU. Esta en
#  src/hev-socks5-worker.c, en el bucle de accept del worker:
#
#      nfd = hev_task_io_socket_accept (fd, NULL, NULL, task_io_yielder, self);
#      if (nfd == -1) {
#          LOG_E ("socks5 proxy accept");
#          continue;              <-- vuelve a intentarlo AL INSTANTE
#      }
#
#  hev_task_io_socket_accept solo cede la CPU cuando accept() da EAGAIN. Con
#  CUALQUIER otro error devuelve -1 sin ceder, y el worker vuelve a llamarlo
#  inmediatamente. Cuando el proceso se queda sin descriptores (EMFILE), la
#  conexion pendiente sigue en la cola —o sea que no es EAGAIN— y accept()
#  falla una y otra vez para siempre: bucle cerrado, un nucleo al 100%, y ni
#  una conexion nueva atendida hasta reiniciar.
#
#  Y son TODOS los nucleos, no uno: hev_socket_factory_get hace dup() del mismo
#  socket de escucha para cada worker, asi que los "workers: nproc" se quedan
#  girando a la vez sobre la misma conexion pendiente.
#
#  OJO: este bug es REAL pero resulto NO ser la causa del nucleo al 100% que
#  se sufrio en produccion. Eso era el desbordamiento de pila — ver la nota de
#  task-stack-size mas abajo. Se comprobo midiendo: con el nucleo clavado solo
#  habia 746 descriptores abiertos de 100.000, o sea que EMFILE nunca llego a
#  pasar. El parche se mantiene porque el bucle sigue estando ahi y saltaria el
#  dia que de verdad se agoten los descriptores.
#
#  hev-socks5-server NO tiene tope de sesiones (a diferencia de
#  hev-socks5-tunnel, que si trae max-session-count), asi que los descriptores
#  crecen con los usuarios sin ningun techo.
#
#  El parche son dos lineas y hay que aplicarlo al fuente antes de compilar.
#  Por eso el binario precompilado del repo YA NO SE USA: lo trae sin parchear.

s5_fetch() {
    # Se intenta compilar parcheado. Solo si no se puede (sin compilador, sin
    # red, arquitectura rara) se cae al binario del repo, que tiene el bug.
    if s5_build; then
        return 0
    fi
    err "No se pudo compilar: se usara el binario del repo, que TIENE el bug"
    err "del bucle de CPU. El vigilante (msyvpn-socks5-watch) lo reiniciara."
    if fetch_bin hev-socks5-server "$S5_BIN" 2>/dev/null && [[ -s "$S5_BIN" ]]; then
        chmod +x "$S5_BIN"
        # El binario del repo puede ser de otra arquitectura: si no ejecuta,
        # se descarta. Sin esta comprobacion el servicio quedaba en bucle de
        # reinicio con "Exec format error".
        if "$S5_BIN" --version >/dev/null 2>&1 || "$S5_BIN" 2>&1 | grep -qi 'usage\|config'; then
            info "hev-socks5-server: binario del repo ($(arch)), SIN parchear"
            return 0
        fi
        rm -f "$S5_BIN"
    fi
    return 1
}

# Mete el descanso que le falta al bucle de accept.
#
# 100 ms no se notan cuando accept() falla de verdad —son casos de error—, y
# convierten un nucleo al 100% en diez intentos por segundo. Ademas el proceso
# se RECUPERA solo: en cuanto se liberan descriptores, el siguiente accept()
# funciona y sigue como si nada, sin reinicio.
s5_patch_accept() {
    local src="$1/src/hev-socks5-worker.c"
    [[ -f "$src" ]] || { err "No aparece hev-socks5-worker.c: no se pudo parchear"; return 1; }

    # Ya parcheado (por si upstream lo arregla algun dia).
    grep -q 'hev_task_sleep (100);' "$src" && { info "El fuente ya trae el descanso"; return 0; }

    grep -q 'LOG_E ("socks5 proxy accept");' "$src" || {
        err "El bucle de accept cambio en upstream: revisar el parche a mano"
        return 1
    }

    sed -i 's|LOG_E ("socks5 proxy accept");|LOG_E ("socks5 proxy accept");\n            hev_task_sleep (100);|' "$src"

    grep -q 'hev_task_sleep (100);' "$src" || { err "El parche no entro"; return 1; }
    ok "Parche del bucle de CPU aplicado"
}

s5_build() {
    info "Compilando hev-socks5-server para $(arch) (tarda un minuto)..."
    ensure_pkg git build-essential
    command -v git >/dev/null 2>&1 || { err "Falta git"; return 1; }
    command -v make >/dev/null 2>&1 || { err "Falta make (build-essential)"; return 1; }

    local tmp="/tmp/hev-socks5-server.$$"
    # --recursive es obligatorio: el core y el sistema de tareas son submodulos
    # y sin ellos el make falla con cientos de errores de cabeceras.
    #
    # Tres intentos: el clone era de uno solo, y un parpadeo de red dejaba la
    # VPS sin SOCKS5 hasta que alguien se diera cuenta y lo reintentara a mano.
    # Ese era el "le di varias veces y a la tercera se compilo".
    local intento clonado=0
    for intento in 1 2 3; do
        rm -rf "$tmp"
        if git clone --recursive --depth 1 "$S5_SRC" "$tmp" >/dev/null 2>&1; then
            clonado=1; break
        fi
        [[ $intento -lt 3 ]] && { info "  reintentando la descarga del codigo ($intento/3)..."; sleep $((intento * 3)); }
    done
    if [[ $clonado -ne 1 ]]; then
        err "No se pudo descargar el codigo de hev-socks5-server"
        msy_anotar_fallo "descarga del codigo de hev-socks5-server (3 intentos)"
        rm -rf "$tmp"; return 1
    fi

    # SIN el parche no se compila: un binario con el bucle es peor que no
    # tenerlo, porque el sintoma tarda dias en aparecer y no se relaciona.
    s5_patch_accept "$tmp" || { rm -rf "$tmp"; return 1; }

    # ENABLE_STATIC: sin dependencias de libc en tiempo de ejecucion, asi el
    # binario sobrevive a una actualizacion del sistema.
    ( cd "$tmp" && make ENABLE_STATIC=1 -j"$(nproc 2>/dev/null || echo 1)" >/dev/null 2>&1 )
    if [[ -s "$tmp/bin/hev-socks5-server" ]]; then
        cp -f "$tmp/bin/hev-socks5-server" "$S5_BIN"
        chmod +x "$S5_BIN"
        rm -rf "$tmp"
        ok "hev-socks5-server compilado (con el parche del bucle)"
        return 0
    fi
    rm -rf "$tmp"
    err "Fallo la compilacion de hev-socks5-server"
    msy_anotar_fallo "compilacion de hev-socks5-server"
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
  # ==========================================================================
  #  ESTE NUMERO ERA EL CULPABLE DEL NUCLEO AL 100% (2026-09-10)
  # ==========================================================================
  #  Estuvo en 20480 y las tareas DESBORDABAN LA PILA. Cazado en produccion
  #  trazando el hilo caliente: escribia esto 1.300 veces por segundo.
  #
  #      ========== Oops! Stack overflow! ==========
  #      Task: 0x7eb20407ce50
  #        Stack   : 0x7eb22c1bc000 - 0x7eb22c1c2000   <- 24 KB, o sea 20480
  #        Bad addr: 0x7eb22c1bcfc8
  #
  #  Cuando una tarea desborda, hev lo detecta con su pagina de guarda, lo
  #  imprime... y el hilo se queda en un bucle imprimiendolo. De ahi el
  #  sintoma: un nucleo al 100%, luego otro, y el SOCKS5 dejando de aceptar.
  #  Medido: 47.000 futex/s (los dos hilos peleandose por el cerrojo del
  #  logger) y 6.600 write/s. No era EMFILE: solo habia 746 descriptores de
  #  100.000.
  #
  #  Desborda por el camino UDP: hev-socks5-udp.c usa arrays de tamano
  #  variable EN PILA (mmsghdr, iovec, sockaddr_in6, HevSocks5UDPMsg),
  #  dimensionados por udp-copy-buffer-nums (10), y anidados en varios
  #  niveles de llamada. Cada nivel se come cerca de 1 KB.
  #
  #  Por eso ademas se caia al arrancar un speedtest: de golpe abre muchas
  #  conexiones y UDP a la vez, se baja mas hondo en la pila y desborda.
  #
  #  64 KB da margen de sobra. No cuesta memoria real: la pila se reserva en
  #  espacio de direcciones y solo se ocupan las paginas que se tocan.
  #
  #  **No volver a bajarlo.** Si algun dia hay que ajustarlo, la otra palanca
  #  es udp-copy-buffer-nums, que escala directamente esos arrays.
  task-stack-size: 65536
  connect-timeout: 10000
  # ==========================================================================
  #  ESTE NUMERO ES EL QUE MANDA SOBRE LOS DESCRIPTORES
  # ==========================================================================
  #  hev-socks5-server NO tiene tope de sesiones —a diferencia de
  #  hev-socks5-tunnel, que trae max-session-count—, asi que lo unico que
  #  libera descriptores es que las sesiones caduquen. Cada sesion son DOS.
  #
  #  Estuvo en 300000 (5 minutos). Un movil que pierde cobertura deja su
  #  sesion muerta ocupando dos descriptores todo ese rato, y con cientos de
  #  usuarios eso se acumula hasta EMFILE — que es lo que dispara el bucle de
  #  accept del worker (ver la nota larga de arriba).
  #
  #  Dos minutos siguen siendo de sobra para cualquier conexion viva: mientras
  #  haya trafico el contador se reinicia. Solo corta a las que ya no existen.
  tcp-read-write-timeout: 120000
  udp-read-write-timeout: 60000
  # log-file null a proposito: si el bucle de accept volviera por otra via,
  # un log activo escribiria miles de lineas por segundo y llenaria el disco.
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

# Recarga el auth. Antes se usaba SIGUSR1 para recargar en caliente, pero
# hev-socks5-server puede quedar en bucle de reintento de lectura del
# archivo si la senal llega mientras hay conexiones activas (mas facil
# de ver con "workers" en varios nucleos) — cada worker atascado consume
# un nucleo entero, que es el sintoma de "todos los nucleos al 100%,
# proceso msyvpns5 o socks5.yml" que se puede ver con htop.
#
# El restart corta a los conectados de SOCKS5 un instante, pero es
# la unica forma confiable de que el proceso quede sirviendo con el
# archivo de auth real que hay en disco. La alternativa (seguir con
# SIGUSR1) es la causa exacta del bug: no vale la pena ahorrarse el
# corte de un segundo a cambio de nucleos atascados horas o dias despues.
s5_reload_auth() {
    s5_installed || return 0
    [[ -f "$S5_CFG" ]] || return 0
    s5_write_auth
    svc_active msyvpn-socks5 && svc_restart msyvpn-socks5
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
# ============================================================================
#  OJO CON ESTE LIMITE: ESTABA HACIENDO DANO
# ============================================================================
#  Estuvo en CPUQuota=100%, que NO es "el 100% de la maquina" sino **un solo
#  nucleo en total para todo el servicio**. Con "workers: nproc" eso ahoga a
#  todos los workers dentro de un unico nucleo: bajo carga las sesiones se
#  acumulan, con ellas los descriptores, y los descriptores son justo lo que
#  dispara el bucle de accept. O sea que el remedio alimentaba la enfermedad.
#
#  Ahora se deja como red de seguridad de verdad: el 75% de la maquina. Sobra
#  para servir, y deja siempre un cuarto libre para que sshd y HAProxy
#  respondan aunque el SOCKS5 se vuelva loco — que es lo unico que se le pedia
#  al limite.
CPUQuota=$(( $(nproc 2>/dev/null || echo 1) * 75 ))%
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
    s5_setup_watchdog
    sleep 1
    svc_active msyvpn-socks5
}

# ============================================================================
#  EL VIGILANTE
# ============================================================================
#  Con el parche del bucle esto no deberia saltar nunca. Se pone igualmente
#  por dos motivos: si la compilacion falla se acaba usando el binario del
#  repo, que si tiene el bug; y porque un servidor que deja de aceptar sin
#  morirse es la peor averia posible — systemd no la ve, porque el proceso
#  sigue "activo".
#
#  La prueba es directa: se abre una conexion al puerto interno y se manda un
#  saludo SOCKS5. Si el servidor esta sano contesta dos bytes. No se mira la
#  CPU ni el numero de descriptores: se comprueba lo unico que importa, que es
#  si atiende. Dos fallos seguidos (30 s) para no reiniciar por una rafaga.
s5_setup_watchdog() {
    cat > "$BASE_DIR/socks5_watch.sh" <<'WEOF'
#!/bin/bash
# Comprueba que el SOCKS5 local sigue aceptando. Lo llama un timer de systemd.
source /etc/msyvpn/lib.sh 2>/dev/null || exit 0
port=$(cat "$DATA_DIR/socks5.port" 2>/dev/null || echo 1080)
fallos="$DATA_DIR/socks5.fallos"
atasco="$DATA_DIR/socks5_atasco.log"

systemctl is-active --quiet msyvpn-socks5 || exit 0

# Saludo SOCKS5 sin autenticacion: 05 01 00. Un servidor sano responde 2 bytes.
if printf '\x05\x01\x00' | timeout 5 nc -w 3 127.0.0.1 "$port" 2>/dev/null | head -c 2 | wc -c | grep -q '^2$'; then
    rm -f "$fallos"
    exit 0
fi

n=$(( $(cat "$fallos" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$fallos"
if [[ $n -ge 2 ]]; then
    # ── CAPTURA ANTES DE REINICIAR ──────────────────────────────────────
    #  Reiniciar borra la evidencia. Sin esto solo se sabe QUE se atasco,
    #  nunca EN QUE. La pila sale con nombres solo si esta el binario con
    #  simbolos; es el mismo codigo, byte a byte, pero sin quitar la tabla.
    PID=$(ps -eo pid,comm --no-headers | awk '$2=="hev-socks5-serv"{print $1; exit}')
    if [[ -n "$PID" ]]; then
        {
            echo "===== $(date '+%Y-%m-%d %H:%M:%S') ====="
            echo "pid $PID · fds: $(ls /proc/$PID/fd 2>/dev/null | wc -l) · hilos: $(ls /proc/$PID/task 2>/dev/null | wc -l)"
            echo "--- CPU por hilo (delta 3 s) ---"
            HZ=$(getconf CLK_TCK)
            for t in /proc/$PID/task/*; do
                echo "$(basename "$t") $(awk '{print $14+$15}' "$t/stat" 2>/dev/null)"
            done > /tmp/w1
            sleep 3
            for t in /proc/$PID/task/*; do
                echo "$(basename "$t") $(awk '{print $14+$15}' "$t/stat" 2>/dev/null)"
            done > /tmp/w2
            join /tmp/w1 /tmp/w2 2>/dev/null | awk -v h="$HZ" '{d=($3-$2)*100/h/3; if(d>20) printf "  hilo %s : %.0f%%\n", $1, d}'
            echo "--- pilas ---"
            command -v gdb >/dev/null 2>&1 && \
                timeout 40 gdb -p "$PID" -batch -ex 'thread apply all bt 10' 2>/dev/null | grep -E '^Thread|^#'
            echo ""
        } >> "$atasco" 2>&1
        # No dejar que el archivo crezca sin fin.
        tail -n 2000 "$atasco" > "$atasco.tmp" 2>/dev/null && mv -f "$atasco.tmp" "$atasco"
    fi

    logger -t msyvpn-socks5-watch "no acepta conexiones tras $n intentos: reiniciando"
    systemctl restart msyvpn-socks5
    rm -f "$fallos"
fi
WEOF
    chmod +x "$BASE_DIR/socks5_watch.sh"

    cat > /etc/systemd/system/msyvpn-socks5-watch.service <<EOF
[Unit]
Description=MSYVPN SOCKS5 watchdog
[Service]
Type=oneshot
ExecStart=$BASE_DIR/socks5_watch.sh
EOF

    cat > /etc/systemd/system/msyvpn-socks5-watch.timer <<EOF
[Unit]
Description=MSYVPN SOCKS5 watchdog
[Timer]
OnBootSec=2min
OnUnitActiveSec=15s
AccuracySec=5s
[Install]
WantedBy=timers.target
EOF

    # nc hace la prueba. Sin el, el vigilante no puede comprobar nada.
    command -v nc >/dev/null 2>&1 || ensure_pkg netcat-openbsd 2>/dev/null || ensure_pkg netcat 2>/dev/null
    systemctl daemon-reload
    systemctl enable --now msyvpn-socks5-watch.timer >/dev/null 2>&1
}

s5_remove() {
    systemctl disable --now msyvpn-socks5-watch.timer >/dev/null 2>&1
    rm -f /etc/systemd/system/msyvpn-socks5-watch.timer \
          /etc/systemd/system/msyvpn-socks5-watch.service \
          "$BASE_DIR/socks5_watch.sh"
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
