#!/bin/bash
# firewall.sh - Filtrado de salida (egress) MSYVPN
# Creado y modificado por t:me/JuanitoProSniif
#
# QUE PROBLEMA RESUELVE
# Con AllowTcpForwarding activo, cualquier usuario del tunel podia abrir
# conexiones hacia cualquier IP y puerto usando la IP del servidor. Eso
# permitio el escaneo de puertos que provoco el reporte de abuso.
#
# Los tuneles SSH, V2Ray, Shadowsocks y wsproxy salen desde el propio
# servidor -> cadena OUTPUT.
# OpenVPN y WireGuard salen enrutados -> cadena FORWARD.
# Por eso se filtran las dos.

[[ "$(id -u)" -eq 0 ]] || { echo "Ejecuta como root."; exit 1; }

CHAIN_OUT="MSY-OUT"
CHAIN_FWD="MSY-FWD"

# Puertos que ningun cliente necesita y que solo sirven para abusar
PUERTOS_SPAM="25,465,587,2525"
PUERTOS_ATAQUE="23,135,137,138,139,445,1433,3389,5900"

fw_limpiar() {
    local t
    for t in OUTPUT FORWARD; do
        while iptables -D "$t" -j "MSY-${t:0:3}" 2>/dev/null; do :; done
    done
    iptables -F "$CHAIN_OUT" 2>/dev/null; iptables -X "$CHAIN_OUT" 2>/dev/null
    iptables -F "$CHAIN_FWD" 2>/dev/null; iptables -X "$CHAIN_FWD" 2>/dev/null
}

fw_aplicar() {
    fw_limpiar

    iptables -N "$CHAIN_OUT" 2>/dev/null
    iptables -N "$CHAIN_FWD" 2>/dev/null

    # ---- OUTPUT: tuneles SSH, V2Ray, Shadowsocks, wsproxy -----------
    # Conexiones ya establecidas pasan sin revisar (ahorra CPU)
    iptables -A "$CHAIN_OUT" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN

    # Nada de correo sale de este host. El servidor no envia mail.
    iptables -A "$CHAIN_OUT" -p tcp -m multiport --dports "$PUERTOS_SPAM" \
        -j LOG --log-prefix "MSY-SPAM-OUT: " -m limit --limit 5/min
    iptables -A "$CHAIN_OUT" -p tcp -m multiport --dports "$PUERTOS_SPAM" -j REJECT

    # Puertos tipicos de fuerza bruta y escaneo
    iptables -A "$CHAIN_OUT" -p tcp -m multiport --dports "$PUERTOS_ATAQUE" \
        -m owner ! --uid-owner 0 -j REJECT

    # Anti-escaneo: limita conexiones nuevas de procesos que no son root.
    # Los tuneles SSH corren con el UID del usuario, asi que caen aqui.
    # Navegacion normal no llega a este limite; masscan lo revienta al instante.
    iptables -A "$CHAIN_OUT" -p tcp --syn -m owner ! --uid-owner 0 \
        -m limit --limit 250/sec --limit-burst 500 -j RETURN
    iptables -A "$CHAIN_OUT" -p tcp --syn -m owner ! --uid-owner 0 \
        -j LOG --log-prefix "MSY-SCAN-OUT: " -m limit --limit 5/min
    iptables -A "$CHAIN_OUT" -p tcp --syn -m owner ! --uid-owner 0 -j DROP

    # ---- FORWARD: OpenVPN y WireGuard -------------------------------
    iptables -A "$CHAIN_FWD" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
    iptables -A "$CHAIN_FWD" -p tcp -m multiport --dports "$PUERTOS_SPAM" -j REJECT
    iptables -A "$CHAIN_FWD" -p tcp -m multiport --dports "$PUERTOS_ATAQUE" -j REJECT

    iptables -A "$CHAIN_FWD" -p tcp --syn -m hashlimit \
        --hashlimit-name msyscan --hashlimit-mode srcip \
        --hashlimit-above 60/min --hashlimit-burst 120 \
        -j LOG --log-prefix "MSY-SCAN-FWD: " -m limit --limit 5/min
    iptables -A "$CHAIN_FWD" -p tcp --syn -m hashlimit \
        --hashlimit-name msyscan2 --hashlimit-mode srcip \
        --hashlimit-above 60/min --hashlimit-burst 120 -j DROP

    # Anti-flood UDP saliente (evita que tus clientes ataquen a terceros)
    iptables -A "$CHAIN_FWD" -p udp -m hashlimit \
        --hashlimit-name msyudp --hashlimit-mode srcip \
        --hashlimit-above 800/sec --hashlimit-burst 1500 -j DROP

    # ---- Enganchar las cadenas --------------------------------------
    iptables -I OUTPUT 1 -j "$CHAIN_OUT"
    iptables -I FORWARD 1 -j "$CHAIN_FWD"

    # ---- Proteccion basica de entrada -------------------------------
    iptables -A INPUT -p tcp --syn -m conntrack --ctstate NEW \
        -m limit --limit 100/sec --limit-burst 200 -j ACCEPT 2>/dev/null

    echo "Firewall MSYVPN aplicado."
}

fw_estado() {
    echo "== $CHAIN_OUT =="; iptables -L "$CHAIN_OUT" -n -v 2>/dev/null || echo "no activo"
    echo; echo "== $CHAIN_FWD =="; iptables -L "$CHAIN_FWD" -n -v 2>/dev/null || echo "no activo"
    echo; echo "== Bloqueos recientes =="
    grep -h "MSY-SCAN\|MSY-SPAM" /var/log/kern.log /var/log/syslog 2>/dev/null | tail -20
}

case "${1:-aplicar}" in
    aplicar)  fw_aplicar ;;
    limpiar)  fw_limpiar; echo "Reglas MSYVPN retiradas." ;;
    estado)   fw_estado ;;
    *)        echo "Uso: $0 {aplicar|limpiar|estado}" ;;
esac
