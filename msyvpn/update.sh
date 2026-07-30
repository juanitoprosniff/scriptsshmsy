#!/bin/bash
# update.sh - Actualizar o desinstalar MSYVPN
# La actualizacion descarga la version nueva, detiene todo de forma
# limpia y reinstala conservando usuarios, claves y certificados.
[[ -n "$BASE_DIR" ]] || source /etc/msyvpn/lib.sh

MSY_SERVICES="msyvpn-wsproxy msyvpn-badvpn msyvpn-hysteria1 msyvpn-hysteria2 msyvpn-slowdns haproxy xray"
MSY_MODULES="VERSION lib.sh wsproxy.py proxy.sh v2ray.sh slowdns.sh hysteria.sh users.sh monitor.sh update.sh menu install.sh master_pubkey.pub"

msy_stop_all() {
    local s
    for s in $MSY_SERVICES; do systemctl stop "$s" >/dev/null 2>&1; done
    # Servicios viejos de versiones anteriores
    systemctl stop msyvpn-hysteria v2ray >/dev/null 2>&1
    ok "Servicios detenidos"
}

msy_start_all() {
    local s
    for s in $MSY_SERVICES; do
        systemctl is-enabled "$s" >/dev/null 2>&1 && systemctl start "$s" >/dev/null 2>&1
    done
    ok "Servicios iniciados"
}

msy_update() {
    clear; title "ACTUALIZAR MSYVPN"
    echo "  Se descargara la ultima version y se reinstalara."
    echo "  Se conservan: usuarios, claves, certificados y dominios."
    line
    [[ "$(ask '¿Continuar? [s/N]: ')" =~ ^[sS]$ ]] || return

    local tmp="/tmp/msyvpn_update_$$"
    rm -rf "$tmp"; mkdir -p "$tmp/bin"

    echo ""
    info "Descargando version nueva..."
    # El instalador nuevo es la lista autoritativa de modulos. Se baja
    # primero y de el se lee que archivos pedir, asi un modulo que yo
    # elimine del repo nunca vuelve a romper la actualizacion.
    if ! wget -q --timeout=30 "$REPO_RAW/install.sh" -O "$tmp/install.sh" \
         || [[ ! -s "$tmp/install.sh" ]]; then
        err "No se pudo descargar el instalador — se cancela."
        info "No se toco nada de la instalacion actual."
        rm -rf "$tmp"; return 1
    fi
    local mods m fails=0
    mods=$(grep -m1 '^MODS=' "$tmp/install.sh" | sed 's/^MODS="//; s/"$//')
    [[ -z "$mods" ]] && mods="$MSY_MODULES"     # respaldo por si cambia el formato
    for m in $mods; do
        [[ "$m" == install.sh ]] && continue    # ya descargado
        if ! wget -q --timeout=30 "$REPO_RAW/$m" -O "$tmp/$m"; then
            err "No se pudo descargar $m"; fails=$((fails+1))
        fi
    done
    # Verificar que los archivos clave llegaron completos
    if [[ $fails -gt 0 || ! -s "$tmp/wsproxy.py" || ! -s "$tmp/menu" ]]; then
        err "Descarga incompleta — se cancela la actualizacion."
        info "No se toco nada de la instalacion actual."
        rm -rf "$tmp"; return 1
    fi
    if ! bash -n "$tmp/install.sh" 2>/dev/null; then
        err "El instalador descargado no es valido — se cancela."
        rm -rf "$tmp"; return 1
    fi
    ok "Descarga verificada"

    # Respaldo de datos antes de tocar nada
    local bkp="/root/msyvpn-backup-$(date +%Y%m%d%H%M%S).tar.gz"
    tar czf "$bkp" -C / etc/msyvpn/data etc/msyvpn/cert.pem 2>/dev/null
    [[ -s "$bkp" ]] && ok "Respaldo: $bkp"

    echo ""
    info "Deteniendo servicios..."
    msy_stop_all

    echo ""
    info "Instalando version nueva..."
    MSYVPN_UPDATE=1 bash "$tmp/install.sh"
    rm -rf "$tmp"

    # El instalador solo arranca sus propios servicios; hay que volver a
    # levantar V2Ray, SlowDNS e Hysteria, que se detuvieron mas arriba.
    echo ""
    info "Reactivando servicios..."
    msy_start_all
    local s
    for s in xray msyvpn-slowdns msyvpn-hysteria1 msyvpn-hysteria2; do
        systemctl is-enabled "$s" >/dev/null 2>&1 && \
            { systemctl restart "$s" >/dev/null 2>&1; info "  $s reiniciado"; }
    done

    echo ""
    line
    ok "ACTUALIZACION COMPLETA"
    info "Escribe 'menu' para entrar de nuevo."
    line
    # Salimos: el proceso actual todavia tiene en memoria la version vieja.
    exit 0
}

msy_uninstall() {
    clear; title "DESINSTALAR MSYVPN"
    echo "  Se eliminan servicios, proxies y configuraciones."
    echo "  Las cuentas del sistema NO se borran."
    line
    [[ "$(ask 'Escribe SI para confirmar: ')" == "SI" ]] || { info "Cancelado"; return; }

    local s
    for s in $MSY_SERVICES; do
        systemctl disable --now "$s" >/dev/null 2>&1
    done
    systemctl disable --now msyvpn-hysteria v2ray >/dev/null 2>&1
    rm -f /etc/systemd/system/msyvpn-*.service
    systemctl daemon-reload

    rm -f /usr/bin/menu /usr/lib/msyvpn
    rm -f /etc/ssh/sshd_config.d/00-msyvpn.conf
    sed -i '/# MSYVPN-BEGIN/,/# MSYVPN-END/d' /etc/ssh/sshd_config /etc/sysctl.conf 2>/dev/null
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null

    echo ""
    if [[ "$(ask '¿Borrar tambien datos y usuarios VPN? [s/N]: ')" =~ ^[sS]$ ]]; then
        local u
        while read -r u _; do
            [[ -n "$u" ]] && id "$u" >/dev/null 2>&1 && userdel -r "$u" >/dev/null 2>&1
        done < <(cat "$USERS_DB" 2>/dev/null)
        rm -rf "$BASE_DIR" /etc/hysteria /etc/slowdns
        ok "Datos y usuarios eliminados"
    else
        info "Datos conservados en $BASE_DIR"
    fi
    ok "MSYVPN desinstalado"
    exit 0
}

# Libera espacio: logs son casi siempre la causa de disco lleno
msy_clean_disk() {
    clear; title "LIBERAR ESPACIO EN DISCO"
    echo "  Uso actual:"; df -h / | tail -1
    line
    echo "  Mayores consumidores en /var/log:"
    du -sh /var/log/* 2>/dev/null | sort -rh | head -8
    line
    [[ "$(ask '¿Limpiar logs ahora? [s/N]: ')" =~ ^[sS]$ ]] || return

    journalctl --rotate >/dev/null 2>&1
    journalctl --vacuum-size=100M >/dev/null 2>&1
    # Vaciar (no borrar) los logs grandes para no romper los servicios
    local f
    for f in /var/log/syslog /var/log/messages /var/log/auth.log \
             /var/log/haproxy.log /var/log/kern.log /var/log/daemon.log \
             /var/log/user.log /var/log/debug /var/log/xray/access.log \
             /var/log/xray/error.log /var/log/v2ray/access.log; do
        [[ -f "$f" ]] && : > "$f"
    done
    rm -f /var/log/*.gz /var/log/*.1 /var/log/*/*.gz /var/log/*/*.1 2>/dev/null
    apt-get clean >/dev/null 2>&1
    rm -rf /tmp/msyvpn_update_* /tmp/*.deb 2>/dev/null
    # Respaldos viejos del propio script (deja los 2 mas recientes)
    ls -1t /root/msyvpn-backup-*.tar.gz 2>/dev/null | tail -n +3 | xargs -r rm -f
    line
    echo "  Uso despues:"; df -h / | tail -1
    ok "Limpieza terminada"
}

# ---------------------------------------------------------------------
# BACKUP / RESTORE de usuarios y configuraciones
# ---------------------------------------------------------------------
# Guarda: cuentas SSH (usuario, contrasena, limite, expiracion), UUIDs y
# protocolos de V2Ray, obfs/puertos de Hysteria, claves SlowDNS, clave
# maestra y certificado. Sirve para migrar a otra VPS o restaurar.
msy_backup() {
    clear; title "BACKUP DE MSYVPN"
    local tmp="/tmp/msybk.$$"; rm -rf "$tmp"; mkdir -p "$tmp"

    # Exportar cuentas del sistema: usuario|contrasena|limite|dias_exp
    local u pass lim exp
    : > "$tmp/users.export"
    while read -r u lim; do
        [[ -z "$u" ]] && continue
        id "$u" >/dev/null 2>&1 || continue
        pass=$(cat "$SENHA_DIR/$u" 2>/dev/null)
        exp=$(getent shadow "$u" 2>/dev/null | cut -d: -f8)
        echo "$u|$pass|${lim:-1}|$exp" >> "$tmp/users.export"
    done < <(cat "$USERS_DB" 2>/dev/null)

    # Copiar datos y configs (lo que exista)
    mkdir -p "$tmp/etc"
    cp -a "$DATA_DIR"                "$tmp/etc/data"        2>/dev/null
    cp -a "$MASTER_PUBKEY"           "$tmp/etc/"            2>/dev/null
    cp -a "$CERT_PEM"                "$tmp/etc/"            2>/dev/null
    cp -a /etc/hysteria              "$tmp/etc/hysteria"    2>/dev/null
    cp -a /etc/slowdns/server.key /etc/slowdns/server.pub /etc/slowdns/ns \
                                     "$tmp/etc/"            2>/dev/null

    local out="/root/msyvpn-backup-$(date +%Y%m%d-%H%M).tar.gz"
    tar czf "$out" -C "$tmp" . 2>/dev/null
    rm -rf "$tmp"
    if [[ -s "$out" ]]; then
        ok "Backup creado: $out"
        info "Cuentas: $(wc -l < "$USERS_DB" 2>/dev/null || echo 0)   Tamano: $(du -h "$out" | cut -f1)"
        info "Descargalo con:  scp root@$(get_ip):$out ."
    else
        err "No se pudo crear el backup"
    fi
}

msy_restore() {
    clear; title "RESTAURAR BACKUP"
    echo "  Archivos .tar.gz encontrados en /root:"
    local f i=0; declare -a arr
    while read -r f; do
        [[ -z "$f" ]] && continue
        i=$((i+1)); arr[$i]="$f"
        printf "  [%d] %s  (%s)\n" "$i" "$(basename "$f")" "$(du -h "$f" | cut -f1)"
    done < <(ls -1t /root/msyvpn-backup-*.tar.gz 2>/dev/null)
    [[ $i -eq 0 ]] && { err "No hay backups en /root"; info "Sube tu .tar.gz a /root y vuelve a entrar."; return; }
    local n; n=$(ask 'Numero a restaurar (0 cancela): ')
    [[ "$n" =~ ^[0-9]+$ ]] && [[ $n -ge 1 && $n -le $i ]] || return
    local bk="${arr[$n]}"

    local tmp="/tmp/msyrs.$$"; rm -rf "$tmp"; mkdir -p "$tmp"
    tar xzf "$bk" -C "$tmp" 2>/dev/null || { err "Backup corrupto"; rm -rf "$tmp"; return; }

    # Restaurar datos y configs
    [[ -d "$tmp/etc/data" ]]     && cp -a "$tmp/etc/data/."   "$DATA_DIR/" 2>/dev/null
    [[ -f "$tmp/etc/master_pubkey.pub" ]] && cp -a "$tmp/etc/master_pubkey.pub" "$MASTER_PUBKEY" 2>/dev/null
    [[ -f "$tmp/etc/cert.pem" ]] && cp -a "$tmp/etc/cert.pem" "$CERT_PEM" 2>/dev/null
    [[ -d "$tmp/etc/hysteria" ]] && { mkdir -p /etc/hysteria; cp -a "$tmp/etc/hysteria/." /etc/hysteria/ 2>/dev/null; }
    mkdir -p /etc/slowdns
    for f in server.key server.pub ns; do
        [[ -f "$tmp/etc/$f" ]] && cp -a "$tmp/etc/$f" /etc/slowdns/ 2>/dev/null
    done

    # Recrear las cuentas del sistema que falten
    local u pass lim exp cnt=0
    while IFS='|' read -r u pass lim exp; do
        [[ -z "$u" ]] && continue
        if ! id "$u" >/dev/null 2>&1; then
            if [[ -n "$exp" ]]; then
                useradd -e "$(date -d "@$((exp*86400))" +%Y-%m-%d 2>/dev/null)" -m -s /bin/false "$u" >/dev/null 2>&1
            else
                useradd -m -s /bin/false "$u" >/dev/null 2>&1
            fi
            [[ -n "$pass" ]] && echo "$u:$pass" | chpasswd 2>/dev/null
            echo "$pass" > "$SENHA_DIR/$u"
            declare -F u_install_authkey >/dev/null 2>&1 && u_install_authkey "$u"
            cnt=$((cnt+1))
        fi
    done < "$tmp/users.export"
    rm -rf "$tmp"

    # Reconstruir configs y reiniciar
    declare -F v2_rebuild >/dev/null 2>&1 && command -v xray >/dev/null 2>&1 && { v2_rebuild; svc_restart xray; }
    declare -F hy_add_user >/dev/null 2>&1 && hy_add_user
    svc_restart msyvpn-slowdns 2>/dev/null
    ok "Restauracion completa: $cnt cuentas recreadas"
    info "Total de cuentas ahora: $(wc -l < "$USERS_DB" 2>/dev/null || echo 0)"
}

upd_menu() {
    while true; do
        clear
        title "MANTENIMIENTO"
        echo "  Disco: $(df -h / | awk 'NR==2{print $4" libres de "$2" ("$5" usado)"}')"
        line
        echo "  1) Actualizar script a la ultima version"
        echo "  2) Backup (usuarios + configuraciones)"
        echo "  3) Restaurar backup"
        echo "  4) Liberar espacio en disco (logs)"
        echo "  5) Reiniciar todos los servicios"
        echo "  6) Desinstalar MSYVPN"
        echo "  0) Volver"
        line
        case "$(ask 'Opcion: ')" in
            1) msy_update; pause ;;
            2) msy_backup; pause ;;
            3) msy_restore; pause ;;
            4) msy_clean_disk; pause ;;
            5) msy_stop_all; msy_start_all; pause ;;
            6) msy_uninstall; pause ;;
            0) return ;;
        esac
    done
}
