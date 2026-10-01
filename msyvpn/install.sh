#!/bin/bash
# install.sh - Instalador unico MSYVPN (activar todo automatico)
# Creado y modificado por t:me/JuanitoProSniif
# Compatible Ubuntu 18-26 (server y minimal) / Debian 10-12
# Instala: HAProxy + wsproxy(async) + OpenSSH afinado + BBR + BadVPN
set -o pipefail

[[ "$(id -u)" -eq 0 ]] || { echo "Ejecuta como root."; exit 1; }

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="/etc/msyvpn"
REPO_RAW="https://raw.githubusercontent.com/juanitoprosniff/scriptsshmsy/main/msyvpn"

echo "=== INSTALANDO MSYVPN ==="

# ============================================================================
#  TODO LO QUE HAY QUE PREGUNTAR, SE PREGUNTA AQUI
# ============================================================================
#  Antes las preguntas estaban al FINAL, despues de diez minutos de
#  instalacion. Eso obligaba a quedarse mirando la pantalla hasta el final
#  para escribir dos dominios, y quien se iba a hacer otra cosa se encontraba
#  la instalacion parada esperando, o terminada sin TLS y sin tunel DNS.
#
#  Ahora se recogen antes de empezar y a partir de ahi no se pregunta nada
#  mas: se lanza, se va uno, y al volver esta todo activo.
#
#  En una actualizacion no se pregunta: ya estan guardados de la vez anterior.
_DOM_TLS=""; _VD_HOST=""; _VD_NS=""
if [[ -z "$MSYVPN_UPDATE" ]]; then
    _IP_AHORA=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo ""
    echo "  ------------------------------------------------------------"
    echo "   DOMINIOS  (se puede dejar en blanco y configurarlo despues)"
    echo "  ------------------------------------------------------------"
    echo ""
    echo "   1) Dominio para TLS — el del certificado, para V2Ray y los"
    echo "      puertos con SSL. Tiene que tener un registro A a $_IP_AHORA"
    echo ""
    read -rp "      Dominio TLS (ej: msyvpn.cloud): " _DOM_TLS
    _DOM_TLS=$(echo "$_DOM_TLS" | tr 'A-Z' 'a-z' | xargs)
    echo ""
    echo "   2) VayDNS — el tunel por DNS, para lineas sin saldo."
    echo "      Necesita DOS nombres, creados en tu proveedor de DNS:"
    echo ""
    echo "         ns.tudominio.com   A    $_IP_AHORA"
    echo "         n.tudominio.com    NS   ns.tudominio.com"
    echo ""
    read -rp "      Nombre del servidor, el del registro A (ej: ns.tudominio.com): " _VD_HOST
    _VD_HOST=$(echo "$_VD_HOST" | tr 'A-Z' 'a-z' | xargs)
    read -rp "      Dominio del tunel, el del registro NS (ej: n.tudominio.com): " _VD_NS
    _VD_NS=$(echo "$_VD_NS" | tr 'A-Z' 'a-z' | xargs)
    echo ""
    echo "  Listo. A partir de aqui no se pregunta nada mas."
    echo ""
fi

# --- 1. Dependencias -------------------------------------------------
echo "[1/9] Dependencias..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null 2>&1
apt-get install -y haproxy python3 openssl curl wget iproute2 iptables \
    cron jq conntrack net-tools ca-certificates >/dev/null 2>&1

# --- 2. Copiar modulos a /etc/msyvpn --------------------------------
echo "[2/9] Copiando modulos..."
mkdir -p "$BASE_DIR/bin" "$BASE_DIR/data/senha"
MODS="VERSION lib.sh wsproxy.py proxy.sh v2ray.sh vaydns.sh hysteria.sh users.sh shadowsocks.sh wireguard.sh openvpn.sh socks5.sh monitor.sh update.sh menu firewall.sh master_pubkey.pub"
# ============================================================================
#  ESTA DESCARGA SE HACE ANTES DE TENER lib.sh, ASI QUE EL REINTENTO VA AQUI
# ============================================================================
#  Antes era una linea:
#
#      wget -q "$REPO_RAW/$m" -O "$BASE_DIR/$m"
#
#  y tenia dos fallos graves. El primero, un solo intento: un parpadeo de red
#  dejaba ese modulo fuera. El segundo y peor: "-O" CREA el archivo aunque la
#  descarga falle, asi que el modulo quedaba en 0 bytes **machacando al que
#  funcionaba**. Si al que le tocaba era lib.sh, el "source" de mas abajo
#  cargaba un archivo vacio y a partir de ahi fallaba todo sin ninguna
#  relacion aparente: SOCKS5 que no arranca, OpenVPN que no se activa,
#  WireGuard que no aparece... segun a quien le tocara el parpadeo.
#
#  Ahora se baja a un temporal, se comprueba, y solo entonces se pone en su
#  sitio. Si falla, el modulo anterior sigue intacto.
_bajar_modulo() {
    local m="$1" tmp="$BASE_DIR/.$1.tmp" intento
    for intento in 1 2 3; do
        rm -f "$tmp"
        wget -q --timeout=20 --tries=1 "$REPO_RAW/$m" -O "$tmp" 2>/dev/null \
            || curl -fsSL --max-time 20 "$REPO_RAW/$m" -o "$tmp" 2>/dev/null
        if [[ -s "$tmp" ]]; then
            mv -f "$tmp" "$BASE_DIR/$m"
            return 0
        fi
        [[ $intento -lt 3 ]] && sleep $((intento * 2))
    done
    rm -f "$tmp"
    return 1
}

_faltan=""
for m in $MODS; do
    if [[ -f "$SRC_DIR/$m" ]]; then
        cp -f "$SRC_DIR/$m" "$BASE_DIR/$m"
    else
        _bajar_modulo "$m" || _faltan="$_faltan $m"
    fi
done

# Sin estos no hay nada que hacer: seguir adelante solo produce fallos raros
# mas tarde, imposibles de relacionar con una descarga de hace diez minutos.
for m in lib.sh menu; do
    if [[ ! -s "$BASE_DIR/$m" ]]; then
        echo ""
        echo "  ERROR: no se pudo obtener '$m' y sin el no se puede continuar."
        echo "  Casi siempre es un corte de red. Vuelve a lanzar el instalador."
        echo ""
        exit 1
    fi
done
[[ -n "$_faltan" ]] && echo "    (no se pudieron bajar:$_faltan — se reintentan al actualizar)"
# Binarios incluidos (amd64) — para otras arquitecturas fetch_bin descarga.
# hev-socks5-server puede no estar: socks5.sh lo compila si falta.
for b in badvpn-udpgw vaydns-server hev-socks5-server; do
    [[ -f "$SRC_DIR/bin/$b" ]] && cp -f "$SRC_DIR/bin/$b" "$BASE_DIR/bin/$b"
    chmod +x "$BASE_DIR/bin/$b" 2>/dev/null
done
chmod +x "$BASE_DIR"/*.sh "$BASE_DIR"/wsproxy.py "$BASE_DIR"/menu 2>/dev/null

# shellcheck source=/dev/null
source "$BASE_DIR/lib.sh"

# El parte de averias arranca en blanco: lo que salga al final es de ESTA
# ejecucion, no arrastrado de un intento anterior.
msy_reset_fallos

# Binario badvpn segun arquitectura -> /usr/bin
fetch_bin badvpn-udpgw /usr/bin/badvpn-udpgw || err "badvpn no disponible para $(arch)"

# Guardar IP publica
get_ip > "$BASE_DIR/ip"

# Red: se REAPLICA la preferencia de salida que hubiera configurada.
#
# Antes aqui se llamaba a net_reset_pref(), que la borraba. Como install.sh
# corre en CADA actualizacion, la preferencia se perdia sola y sin avisar: la
# VPS volvia a salir por IPv4 y, si la geolocalizacion de esa IPv4 no coincide
# con la de la IPv6, cambiaba el pais que ven Google y AdMob. Muy dificil de
# relacionar con "actualice la script".
net_pref_aplicar

# --- 3. Afinar OpenSSH (buen ping) ----------------------------------
echo "[3/9] Afinando OpenSSH..."
grep -qx '/bin/false' /etc/shells 2>/dev/null || echo '/bin/false' >> /etc/shells
grep -qx '/usr/sbin/nologin' /etc/shells 2>/dev/null || echo '/usr/sbin/nologin' >> /etc/shells
SSH_BASE='UseDNS no
Compression no
TCPKeepAlive yes
ClientAliveInterval 30
ClientAliveCountMax 3
IPQoS lowdelay throughput
AllowTcpForwarding yes
GatewayPorts no
PubkeyAuthentication yes
PasswordAuthentication yes
PermitRootLogin prohibit-password
MaxStartups 200:30:2000
MaxSessions 20
# LogLevel INFO es obligatorio para saber QUE usuario genero un abuso.
# El volumen se controla en firewall.sh y en rsyslog, no apagando el log.
LogLevel INFO'

# Compatibilidad con apps VPN y claves RSA antiguas: OpenSSH 8.8+
# desactiva las firmas ssh-rsa (SHA-1) y eso rompe la clave maestra y
# muchos clientes. El nombre de la directiva cambio en OpenSSH 8.5, por
# eso se prueban dos variantes y se valida antes de aplicar.
SSH_LEGACY_NEW='DebianBanner no
PubkeyAcceptedAlgorithms +ssh-rsa,rsa-sha2-256,rsa-sha2-512
CASignatureAlgorithms +ssh-rsa
HostKeyAlgorithms +ssh-rsa
KexAlgorithms +diffie-hellman-group14-sha1,diffie-hellman-group-exchange-sha1,diffie-hellman-group1-sha1
Ciphers +aes128-cbc,aes256-cbc,3des-cbc
MACs +hmac-sha1,hmac-sha1-96'

SSH_LEGACY_OLD='PubkeyAcceptedKeyTypes +ssh-rsa
HostKeyAlgorithms +ssh-rsa
KexAlgorithms +diffie-hellman-group14-sha1,diffie-hellman-group1-sha1
Ciphers +aes128-cbc,aes256-cbc,3des-cbc
MACs +hmac-sha1'

_ssh_write() {   # $1 = contenido completo
    if [[ -d /etc/ssh/sshd_config.d ]] && \
       grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d' /etc/ssh/sshd_config 2>/dev/null; then
        printf '%s\n' "$1" > /etc/ssh/sshd_config.d/00-msyvpn.conf
    else
        sed -i '/# MSYVPN-BEGIN/,/# MSYVPN-END/d' /etc/ssh/sshd_config 2>/dev/null
        printf '# MSYVPN-BEGIN\n%s\n# MSYVPN-END\n' "$1" >> /etc/ssh/sshd_config
    fi
}
_ssh_clear() {
    rm -f /etc/ssh/sshd_config.d/00-msyvpn.conf 2>/dev/null
    sed -i '/# MSYVPN-BEGIN/,/# MSYVPN-END/d' /etc/ssh/sshd_config 2>/dev/null
}

SSHD_BIN=$(command -v sshd || echo /usr/sbin/sshd)
_sshd_ok() { [[ -x "$SSHD_BIN" ]] && "$SSHD_BIN" -t 2>/dev/null; }

# Se valida con "sshd -t" y se retrocede si la config no sirve, para no
# dejar nunca el servidor SSH sin arrancar (quedarias fuera de la VPS).
_ssh_clear
if [[ ! -x "$SSHD_BIN" ]]; then
    # Sin binario para validar: solo directivas estandar, seguras en
    # cualquier version.
    _ssh_write "$SSH_BASE"
    echo "    SSH: ajustes basicos (sshd no encontrado para validar)"
elif _ssh_write "$SSH_BASE
$SSH_LEGACY_NEW" && _sshd_ok; then
    echo "    SSH: compatibilidad RSA activada (formato nuevo)"
elif _ssh_write "$SSH_BASE
$SSH_LEGACY_OLD" && _sshd_ok; then
    echo "    SSH: compatibilidad RSA activada (formato antiguo)"
elif _ssh_write "$SSH_BASE" && _sshd_ok; then
    echo "    SSH: ajustes basicos (sin bloque de compatibilidad)"
else
    _ssh_clear
    echo "    SSH: se conservo la configuracion original (no se pudo validar)"
fi
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null

# --- 4. Kernel: BBR + baja latencia + forwarding --------------------
echo "[4/9] Optimizando kernel (BBR)..."
modprobe tcp_bbr 2>/dev/null
sed -i '/# MSYVPN-BEGIN/,/# MSYVPN-END/d' /etc/sysctl.conf 2>/dev/null
cat >> /etc/sysctl.conf <<'EOF'
# MSYVPN-BEGIN
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_low_latency=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.core.somaxconn=8192
net.core.netdev_max_backlog=5000
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_syncookies=1
net.ipv4.ip_forward=1
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.default.disable_ipv6=0
net.ipv6.conf.all.forwarding=1
net.core.rmem_max=8388608
net.core.wmem_max=8388608
net.ipv4.tcp_rmem=4096 87380 8388608
net.ipv4.tcp_wmem=4096 65536 8388608
fs.file-max=1000000
# Conntrack: con cientos de usuarios la tabla se llena y dispara el CPU.
# Se amplia y se acortan los tiempos de espera (por defecto TCP son 5 dias).
net.netfilter.nf_conntrack_max=524288
net.netfilter.nf_conntrack_tcp_timeout_established=1800
net.netfilter.nf_conntrack_udp_timeout=30
net.netfilter.nf_conntrack_udp_timeout_stream=120
# rp_filter permisivo: algunas VPS descartan el trafico de WireGuard
net.ipv4.conf.all.rp_filter=2
# MSYVPN-END
EOF
modprobe nf_conntrack 2>/dev/null
sysctl -p >/dev/null 2>&1

# --- Limitar logs: con cientos de usuarios llenaban el disco ---------
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/msyvpn.conf <<'EOF'
[Journal]
SystemMaxUse=100M
RuntimeMaxUse=50M
MaxRetentionSec=3day
EOF
systemctl restart systemd-journald 2>/dev/null
cat > /etc/logrotate.d/msyvpn <<'EOF'
/var/log/syslog /var/log/messages /var/log/haproxy.log /var/log/auth.log {
    daily
    rotate 3
    maxsize 100M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF

# Salvaguarda horaria: si el disco pasa del 80%%, vaciar logs grandes
cat > /etc/cron.hourly/msyvpn-logs <<'CRONEOF'
#!/bin/bash
USO=$(df -P / | awk 'NR==2{print $5+0}')
[[ ${USO:-0} -lt 80 ]] && exit 0
journalctl --vacuum-size=50M >/dev/null 2>&1
for f in /var/log/syslog /var/log/messages /var/log/auth.log \
         /var/log/kern.log /var/log/daemon.log /var/log/btmp; do
    [[ -f "$f" ]] && : > "$f"
done
rm -f /var/log/*.gz /var/log/*.[0-9] /var/log/*/*.gz 2>/dev/null
exit 0
CRONEOF
chmod +x /etc/cron.hourly/msyvpn-logs

# --- 4b. Swap segun la RAM (no se toca si ya hay uno) ----------------
echo "[4b/9] Comprobando swap..."
if [[ "$(swapon --show --noheadings 2>/dev/null | wc -l)" -gt 0 ]]; then
    echo "    Ya existe swap activo — no se toca."
else
    _ram=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
    if   [[ $_ram -le 2048 ]]; then _sw=2G
    elif [[ $_ram -le 8192 ]]; then _sw=4G
    else                            _sw=8G
    fi
    _avail=$(df -Pm / | awk 'NR==2{print $4}')
    _need=$(( ${_sw%G} * 1024 + 1024 ))
    if [[ ${_avail:-0} -lt $_need ]]; then
        echo "    Espacio insuficiente para swap de $_sw — omitido."
    else
        if fallocate -l "$_sw" /swapfile 2>/dev/null || \
           dd if=/dev/zero of=/swapfile bs=1M count=$(( ${_sw%G} * 1024 )) status=none 2>/dev/null; then
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null 2>&1
            if swapon /swapfile 2>/dev/null; then
                grep -q '^/swapfile' /etc/fstab 2>/dev/null || \
                    echo '/swapfile none swap sw 0 0' >> /etc/fstab
                sysctl -w vm.swappiness=10 >/dev/null 2>&1
                grep -q '^vm.swappiness' /etc/sysctl.conf 2>/dev/null || \
                    echo 'vm.swappiness=10' >> /etc/sysctl.conf
                echo "    Swap de $_sw activado (RAM detectada: ${_ram} MB)"
            else
                rm -f /swapfile; echo "    No se pudo activar el swap."
            fi
        else
            rm -f /swapfile; echo "    No se pudo crear el archivo de swap."
        fi
    fi
fi

# --- 5. Certificado TLS (HAProxy) -----------------------------------
echo "[5/9] Generando certificado..."
source "$BASE_DIR/proxy.sh"
proxy_gen_cert

# --- 6. wsproxy como servicio (auto-reinicio) -----------------------
echo "[6/9] Servicio wsproxy..."
# WSPROXY_SSH_BANNER: linea mostrada antes del banner SSH.
# NO puede empezar con "SSH-" (el cliente la tomaria como la version real).
[[ -s "$BASE_DIR/wsproxy.env" ]] || printf 'WSPROXY_NAME=MSY VPN\nWSPROXY_COLOR=green\nWSPROXY_SSH_BANNER=MSY_VPN_SCRIPT\n' > "$BASE_DIR/wsproxy.env"
cat > /etc/systemd/system/msyvpn-wsproxy.service <<EOF
[Unit]
Description=MSYVPN WebSocket Proxy (async)
After=network.target

[Service]
EnvironmentFile=-$BASE_DIR/wsproxy.env
ExecStart=/usr/bin/python3 $BASE_DIR/wsproxy.py $WSPROXY_INTERNAL 127.0.0.1:$SSH_PORT
Restart=always
RestartSec=2
MemoryMax=300M
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
EOF

# --- 7. BadVPN UDP gateway (juegos/streaming) -----------------------
echo "[7/9] Servicio BadVPN (UDP)..."
cat > /etc/systemd/system/msyvpn-badvpn.service <<'EOF'
[Unit]
Description=MSYVPN BadVPN UDP Gateway
After=network.target

[Service]
ExecStart=/usr/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 2000 --max-connections-for-client 48 --client-socket-sndbuf 65536
StandardOutput=null
StandardError=null
Restart=always
RestartSec=2
MemoryMax=512M

[Install]
WantedBy=multi-user.target
EOF

# --- 8. HAProxy con puertos por defecto -----------------------------
echo "[8/9] Configurando HAProxy..."
proxy_write_config

# --- 9. Habilitar y arrancar ----------------------------------------
echo "[9/9] Arrancando servicios..."
# Firewall de salida: evita que un usuario del tunel escanee o spamee
chmod +x "$BASE_DIR/firewall.sh" 2>/dev/null
cat > /etc/systemd/system/msyvpn-firewall.service <<'EOF'
[Unit]
Description=MSYVPN egress firewall
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/msyvpn/firewall.sh aplicar
ExecStop=/etc/msyvpn/firewall.sh limpiar

[Install]
WantedBy=multi-user.target
EOF
systemctl enable --now msyvpn-firewall >/dev/null 2>&1
systemctl daemon-reload
systemctl enable --now msyvpn-wsproxy msyvpn-badvpn >/dev/null 2>&1
systemctl enable --now haproxy >/dev/null 2>&1
systemctl restart msyvpn-wsproxy msyvpn-badvpn haproxy >/dev/null 2>&1
# Volver a levantar lo que ya estuviera configurado (tras actualizar)
for _s in xray msyvpn-vaydns msyvpn-hysteria1 msyvpn-hysteria2; do
    systemctl is-enabled "$_s" >/dev/null 2>&1 && systemctl restart "$_s" >/dev/null 2>&1
done

# Comando 'menu'
ln -sf "$BASE_DIR/menu" /usr/bin/menu
chmod +x /usr/bin/menu
touch /usr/lib/msyvpn

# Mostrar el estado del sistema al entrar a la VPS (solo login interactivo)
cat > /etc/profile.d/msyvpn.sh <<'PROFEOF'
# MSYVPN: estado del sistema al iniciar sesion
case "$-" in *i*)
    if [[ -x /usr/bin/menu && -t 1 ]]; then
        /usr/bin/menu estado 2>/dev/null
        echo "Escribe 'menu' para administrar."
    fi
;; esac
PROFEOF
chmod +x /etc/profile.d/msyvpn.sh

# --- Hysteria UDP (v1 y v2) -----------------------------------------
source "$BASE_DIR/hysteria.sh"
if [[ -n "$MSYVPN_UPDATE" ]]; then
    # Actualizacion: regenerar SOLO lo que el usuario ya tenia instalado
    # (asi toma los logs mudos y las metricas sin forzar versiones nuevas)
    echo "[+] Regenerando Hysteria instalado..."
    hy_installed 1 && hy_install 1 >/dev/null 2>&1
    hy_installed 2 && hy_install 2 >/dev/null 2>&1
else
    echo "[+] Activando Hysteria UDP (v1 y v2)..."
    hy_install 1 >/dev/null 2>&1 && echo "    Hysteria v1 activo en UDP :$(hy_port 1)" \
        || echo "    (Hysteria v1 se puede activar luego desde el menu)"
    hy_install 2 >/dev/null 2>&1 && echo "    Hysteria v2 activo en UDP :$(hy_port 2)" \
        || echo "    (Hysteria v2 se puede activar luego desde el menu)"
fi

# Asegurar logs mudos en servicios ya existentes (units de versiones viejas)
for _u in msyvpn-vaydns; do
    _f=/etc/systemd/system/$_u.service
    [[ -f "$_f" ]] || continue
    grep -q 'StandardOutput=null' "$_f" || \
        sed -i '/^ExecStart=/a StandardOutput=null\nStandardError=null' "$_f"
done
systemctl daemon-reload 2>/dev/null

# --- Retirada de SlowDNS (sustituido por VayDNS el 2026-09-09) -------
#
# Los dos usan el puerto 53 y ponen la MISMA regla de NAT, asi que no pueden
# convivir: el REDIRECT no mira el dominio y se lo lleva todo. Al actualizar
# se apaga SlowDNS y se le quita su regla, o VayDNS no recibiria ni una
# consulta y no habria forma de saber por que.
if [[ -f /etc/systemd/system/msyvpn-slowdns.service ]]; then
    systemctl disable --now msyvpn-slowdns >/dev/null 2>&1
    rm -f /etc/systemd/system/msyvpn-slowdns.service
    while iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 5300 2>/dev/null; do :; done
    systemctl daemon-reload
    echo "    SlowDNS retirado (sus claves se conservan en /etc/slowdns)"
fi

# VayDNS: reaplicar reglas de red si ya estaba configurado
if [[ -f /etc/systemd/system/msyvpn-vaydns.service ]]; then
    source "$BASE_DIR/vaydns.sh"
    vd_apply_net 2>/dev/null && echo "    VayDNS: reglas de DNS aplicadas"
fi

# --- WireGuard y ShadowSocks: auto-activar (si aun no estan) ---------
echo "[+] Activando WireGuard y ShadowSocks..."
source "$BASE_DIR/wireguard.sh"
if wg_installed; then
    wg_rebuild        # regenerar con las mejoras (MTU/NAT) sin tocar clientes
    wg_apply_nat      # garantizar el NAT corregido
    echo "    WireGuard ya configurado, NAT actualizado."
else
    wg_setup >/dev/null 2>&1 && echo "    WireGuard activo en UDP :$(wg_port)" \
        || echo "    (WireGuard se puede activar luego desde el menu)"
fi
source "$BASE_DIR/shadowsocks.sh"
if ss_installed && [[ -f "$SS_CFG" ]]; then
    echo "    ShadowSocks ya configurado."
else
    ss_setup >/dev/null 2>&1 && echo "    ShadowSocks activo en :$(ss_port)" \
        || echo "    (ShadowSocks se puede activar luego desde el menu)"
fi

# --- OpenVPN: UDP directo + TCP tras el wsproxy ----------------------
source "$BASE_DIR/openvpn.sh"
if ov_installed; then
    ov_apply_nat; ov_write_route; ov_make_ovpn
    echo "    OpenVPN ya configurado, NAT y perfiles actualizados."
else
    # Una instancia TCP por nucleo (OpenVPN es de un solo hilo), max 4
    _cores=$(nproc 2>/dev/null || echo 1); [[ $_cores -gt 4 ]] && _cores=4
    ov_setup 1194 "$_cores" >/dev/null 2>&1 \
        && echo "    OpenVPN activo: UDP 1194 + $_cores instancia(s) TCP" \
        || echo "    (OpenVPN se puede activar luego desde el menu)"
fi

# --- SOCKS5: mismos puertos, mismos payloads, mismas cuentas ---------
#
# No abre ningun puerto nuevo: escucha en loopback y le llega todo por el
# wsproxy, igual que al SSH. Si el binario no esta disponible para esta
# arquitectura, socks5.sh lo compila; y si tampoco puede, se sigue sin el
# —el resto de la instalacion no depende de esto.
source "$BASE_DIR/socks5.sh"
echo "[+] Activando SOCKS5..."
if s5_setup >/dev/null 2>&1; then
    echo "    SOCKS5 activo (interno :$(s5_port), cuentas compartidas con SSH)"
else
    echo "    (SOCKS5 se puede activar luego desde el menu -> 12)"
fi

# --- Aplicar los dominios que se pidieron al principio ---------------
#
# Ya no se pregunta nada aqui: lo que hubiera que saber se recogio antes de
# empezar. Si algo falla se anota y se resume abajo, pero la instalacion
# termina igual — un dominio mal puesto no debe dejar la VPS a medias.
if [[ -n "$_DOM_TLS" ]]; then
    echo "[+] Activando TLS para $_DOM_TLS..."
    source "$BASE_DIR/v2ray.sh"
    echo "$_DOM_TLS" > "$DATA_DIR/domain"
    if v2_check_domain "$_DOM_TLS" >/dev/null 2>&1; then
        proxy_cert_real "$_DOM_TLS" >/dev/null 2>&1 \
            && echo "    Certificado emitido para $_DOM_TLS" \
            || { echo "    (no se pudo emitir el certificado)"; \
                 msy_anotar_fallo "certificado TLS de $_DOM_TLS"; }
    else
        echo "    $_DOM_TLS todavia no apunta a esta IP"
        msy_anotar_fallo "el dominio $_DOM_TLS no resuelve a esta VPS (menu -> V2Ray -> Activar TLS)"
    fi
fi

if [[ -n "$_VD_NS" ]]; then
    echo "[+] Activando VayDNS ($_VD_NS)..."
    source "$BASE_DIR/vaydns.sh"
    if vd_setup "$_VD_NS" "$_VD_HOST" >/dev/null 2>&1; then
        echo "    VayDNS activo. Clave publica:"
        echo "      $(cat /etc/vaydns/server.pub 2>/dev/null)"
        # La delegacion es el fallo numero uno y no depende de la VPS: el
        # servidor arranca perfecto y no conecta nadie porque falta el NS.
        if vd_check_dns >/dev/null 2>&1; then
            echo "    Delegacion comprobada: el NS ya apunta aqui"
        else
            echo "    OJO: el NS aun no esta delegado o no se ha propagado"
            msy_anotar_fallo "la delegacion de $_VD_NS aun no responde (menu -> VayDNS -> Comprobar)"
        fi
    else
        echo "    (VayDNS se puede activar luego desde el menu)"
        msy_anotar_fallo "no se pudo activar VayDNS"
    fi
fi

echo ""
echo "=== MSYVPN INSTALADO ==="
echo "IP        : $(cat "$BASE_DIR/ip")"
[[ -s "$MASTER_PUBKEY" ]] && echo "Clave RSA : instalada (auth por llave activo)"
[[ -n "$_VD_NS" ]] && echo "VayDNS    : $_VD_NS  (clave en menu -> VayDNS)"
echo "Escribe 'menu' para administrar."

# El parte de averias. Sin esto, un fallo de descarga desaparecia en el
# /dev/null y el usuario se quedaba sin saber por que le faltaba un protocolo.
msy_resumen_fallos
echo ""
