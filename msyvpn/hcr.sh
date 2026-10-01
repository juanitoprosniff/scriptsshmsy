#!/bin/bash
# hcr.sh - Instalación de HCR (Puerto 8780)
[[ -n "$BASE_DIR" ]] || source /etc/msyvpn/lib.sh

HCR_PORT=8780

hcr_installed() { [[ -x /etc/hcr/bin/hcr-server ]]; }
hcr_port() { echo "$HCR_PORT"; }

hcr_setup() {
    local HCR_ARCH
    case "$(uname -m)" in
        x86_64|amd64)   HCR_ARCH="amd64" ;;
        aarch64|arm64)  HCR_ARCH="arm64" ;;
        *) return 1 ;;
    esac

    mkdir -p /etc/hcr/bin > /dev/null 2>&1

    HCR_FILENAME="hcr-server-linux-${HCR_ARCH}"
    HCR_URL="https://raw.githubusercontent.com/JotchuaDevz/BHTTP-LIBS/refs/heads/main/${HCR_FILENAME}"

    local tmp="/tmp/${HCR_FILENAME}"
    curl -fsSL -o "$tmp" "$HCR_URL" || wget -qO "$tmp" "$HCR_URL"
    if [[ -s "$tmp" ]]; then
        chmod 755 "$tmp"
        if "$tmp" --help > /dev/null 2>&1; then
            install -m 755 "$tmp" /etc/hcr/bin/hcr-server
        fi
        rm -f "$tmp"
    fi

    if [[ ! -x /etc/hcr/bin/hcr-server ]]; then
        return 1
    fi

    cat > /etc/systemd/system/msyvpn-hcr.service <<EOF
[Unit]
Description=HCR TCP relay (backend SSH interno)
After=network-online.target ssh.service sshd.service
Wants=network-online.target
StartLimitIntervalSec=0
[Service]
Type=simple
User=root
ExecStart=/etc/hcr/bin/hcr-server --listen :$HCR_PORT --target 127.0.0.1:$SSH_PORT --transport plain --max-download-frame 6144 --download-poll-timeout 8s --session-timeout 2m --session-stats-interval 0 --max-connections 2048 --max-sessions 32 --max-sessions-per-ip 16
Restart=on-failure
RestartSec=2s
LimitNOFILE=131072
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload > /dev/null 2>&1
    systemctl enable --now msyvpn-hcr > /dev/null 2>&1

    iptables -C INPUT -p tcp --dport $HCR_PORT -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport $HCR_PORT -j ACCEPT > /dev/null 2>&1

    return 0
}