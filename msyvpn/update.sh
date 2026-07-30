#!/bin/bash
# update.sh - Actualizar o desinstalar MSYVPN
# La actualizacion descarga la version nueva, detiene todo de forma
# limpia y reinstala conservando usuarios, claves y certificados.
[[ -n "$BASE_DIR" ]] || source /etc/msyvpn/lib.sh

MSY_SERVICES="msyvpn-wsproxy msyvpn-badvpn msyvpn-hysteria1 msyvpn-hysteria2 msyvpn-slowdns haproxy xray"
MSY_MODULES="VERSION lib.sh wsproxy.py proxy.sh v2ray.sh slowdns.sh hysteria.sh users.sh monitor.sh exitvpn.sh update.sh menu install.sh master_pubkey.pub"

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
    local m fails=0
    for m in $MSY_MODULES; do
        if ! wget -q --timeout=30 "$REPO_RAW/$m" -O "$tmp/$m"; then
            err "No se pudo descargar $m"; fails=$((fails+1))
        fi
    done
    # Verificar que los archivos clave llegaron completos
    if [[ $fails -gt 0 || ! -s "$tmp/install.sh" || ! -s "$tmp/wsproxy.py" ]]; then
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

upd_menu() {
    while true; do
        clear
        title "MANTENIMIENTO"
        echo "  Disco: $(df -h / | awk 'NR==2{print $4" libres de "$2" ("$5" usado)"}')"
        line
        echo "  1) Actualizar script a la ultima version"
        echo "  2) Liberar espacio en disco (logs)"
        echo "  3) Reiniciar todos los servicios"
        echo "  4) Desinstalar MSYVPN"
        echo "  0) Volver"
        line
        case "$(ask 'Opcion: ')" in
            1) msy_update; pause ;;
            2) msy_clean_disk; pause ;;
            3) msy_stop_all; msy_start_all; pause ;;
            4) msy_uninstall; pause ;;
            0) return ;;
        esac
    done
}
