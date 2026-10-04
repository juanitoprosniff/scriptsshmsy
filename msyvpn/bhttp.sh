#!/bin/bash
# bhttp.sh - Instalación de BHTTP (Puerto 8180)
[[ -n "$BASE_DIR" ]] || source /etc/msyvpn/lib.sh

BHTTP_PORT=8180

bhttp_installed() { [[ -x /etc/bhttp/bin/bhttp-server ]]; }
bhttp_port() { echo "$BHTTP_PORT"; }

bhttp_setup() {
    local BHTTP_ARCH
    case "$(uname -m)" in
        x86_64|amd64)   BHTTP_ARCH="amd64" ;;
        aarch64|arm64)  BHTTP_ARCH="arm64" ;;
        *) return 1 ;;
    esac

    mkdir -p /etc/bhttp/bin > /dev/null 2>&1

    BHTTP_FILENAME="bhttp-server-v2.4.1-btun-compat-keepalive-linux-${BHTTP_ARCH}"
    BHTTP_URL="https://raw.githubusercontent.com/JotchuaDevz/BHTTP-LIBS/refs/heads/main/${BHTTP_FILENAME}"

    local tmp="/tmp/${BHTTP_FILENAME}"
    curl -fsSL -o "$tmp" "$BHTTP_URL" || wget -qO "$tmp" "$BHTTP_URL"
    if [[ -s "$tmp" ]]; then
        chmod 755 "$tmp"
        if "$tmp" --self-test > /dev/null 2>&1; then
            install -m 755 "$tmp" /etc/bhttp/bin/bhttp-server
        fi
        rm -f "$tmp"
    fi

    if [[ ! -x /etc/bhttp/bin/bhttp-server ]]; then
        return 1
    fi

    bhttp_mem_mb() { awk '/MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 1024; }
    bhttp_adaptive_sessions() {
        local m; m="$(bhttp_mem_mb)"
        if [ "$m" -lt 768 ]; then echo 512
        elif [ "$m" -lt 1536 ]; then echo 1024
        elif [ "$m" -lt 3072 ]; then echo 2048
        elif [ "$m" -lt 6144 ]; then echo 4096
        else echo 8192
        fi
    }
    BHTTP_MAX_SESSIONS="$(bhttp_adaptive_sessions)"

    BHTTP_SYSCTL_FILE="/etc/sysctl.d/bhttp-performance.conf"
    cat > "$BHTTP_SYSCTL_FILE" <<EOF
fs.file-max = 1048576
net.core.somaxconn = 16384
net.core.netdev_max_backlog = 16384
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 131072 16777216
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_max_tw_buckets = 262144
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 4
net.ipv4.tcp_mtu_probing = 1
EOF
    sysctl -p "$BHTTP_SYSCTL_FILE" >/dev/null 2>&1 || true

    cat > /etc/systemd/system/msyvpn-bhttp.service <<EOF
[Unit]
Description=BHTTP HEX AUTO (backend SSH interno)
After=network-online.target ssh.service sshd.service
Wants=network-online.target
StartLimitIntervalSec=0
[Service]
Type=simple
User=root
ExecStart=/etc/bhttp/bin/bhttp-server --listen 0.0.0.0 --port $BHTTP_PORT --backend-host 127.0.0.1 --backend-port 1080 --session-ttl 180 --max-sessions $BHTTP_MAX_SESSIONS --request-timeout 30 --read-wait-ms 2 --sequence-wait 6 --max-requests-per-conn 2048
Restart=always
RestartSec=1
TimeoutStopSec=15
KillSignal=SIGTERM
LimitNOFILE=524288
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload > /dev/null 2>&1
    systemctl enable --now msyvpn-bhttp > /dev/null 2>&1

    iptables -C INPUT -p tcp --dport $BHTTP_PORT -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport $BHTTP_PORT -j ACCEPT > /dev/null 2>&1

    return 0
}
