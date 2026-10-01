#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  instalar_conteo.sh - Servidor conteo online MSY VPN                    ║
# ║  Archivos en /root | HTTP :8081 | TCP :8082                             ║
# ║  Ubuntu 18, 20, 22, 24, 25, 26, 27+ | Node.js via NVM                  ║
# ║  t:me/JuanitoProSniif                                                    ║
# ╚══════════════════════════════════════════════════════════════════════════╝

VERDE='\033[0;32m'; ROJO='\033[0;31m'; AMARILLO='\033[1;33m'; AZUL='\033[0;34m'; NC='\033[0m'
ok()    { echo -e "${VERDE}[OK]${NC} $1"; }
info()  { echo -e "${AZUL}[INFO]${NC} $1"; }
error() { echo -e "${ROJO}[ERROR]${NC} $1"; exit 1; }
aviso() { echo -e "${AMARILLO}[AVISO]${NC} $1"; }

# Detectar versión Ubuntu
_UBUNTU_VER=$(lsb_release -rs 2>/dev/null | cut -d. -f1 || grep -oP '(?<=Ubuntu )\d+' /etc/issue.net 2>/dev/null || echo "0")

echo -e "${VERDE}"
echo "╔══════════════════════════════════════════════════╗"
echo "║   Servidor Conteo Online MSY VPN                 ║"
echo "║   HTTP :8081 + TCP :8082  |  Archivos en /root   ║"
echo "║   Ubuntu 18 → 27+  |  Node.js via NVM            ║"
echo -e "╚══════════════════════════════════════════════════╝${NC}"

[ "$EUID" -ne 0 ] && error "Ejecutar como root: sudo bash instalar_conteo.sh"
info "Ubuntu $_UBUNTU_VER detectado"

ARCHIVO_JS="/root/conteo_server.js"
SERVICIO="/etc/systemd/system/msyvpn-conteo.service"
NVM_DIR="/root/.nvm"

# ── Dependencias ──────────────────────────────────────────────────────────────
info "Actualizando paquetes..."
apt-get update -qq 2>/dev/null || true
apt-get install -y -qq curl build-essential 2>/dev/null || \
    apt-get install -y curl build-essential 2>/dev/null || true

# ── Node.js via NVM ───────────────────────────────────────────────────────────
# NVM funciona en Ubuntu 18-27 (no depende de la versión del sistema)
if [ ! -d "$NVM_DIR" ]; then
    info "Instalando NVM..."
    # Intentar con la versión más reciente de NVM
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh 2>/dev/null | bash || \
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh 2>/dev/null | bash || \
    wget -qO- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh 2>/dev/null | bash
fi

export NVM_DIR="$NVM_DIR"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# Verificar que NVM está disponible
if ! command -v nvm &>/dev/null && ! type nvm &>/dev/null 2>&1; then
    error "No se pudo instalar NVM. Verifica tu conexión a internet."
fi

info "Instalando Node.js 18 LTS..."
nvm install 18 2>/dev/null || nvm install 20 2>/dev/null || nvm install --lts 2>/dev/null
nvm use 18    2>/dev/null || nvm use 20 2>/dev/null || nvm use --lts 2>/dev/null
nvm alias default 18 2>/dev/null || nvm alias default 20 2>/dev/null || true

NODE_BIN=$(command -v node 2>/dev/null || echo "")
[ -z "$NODE_BIN" ] && error "No se encontró el binario node tras la instalación."
ok "Node.js $(node --version) instalado en $NODE_BIN"

# ── Crear servidor Node.js ────────────────────────────────────────────────────
info "Creando $ARCHIVO_JS..."

# IMPORTANTE: El heredoc usa comillas simples 'EOF' para que bash NO interprete
# nada del contenido. El \p{L} con /gu es la corrección crítica para que
# "España" no se convierta en "Espa_a".
cat > "$ARCHIVO_JS" << 'JSEOF'
/**
 * conteo_server.js - Servidor de conteo online MSY VPN
 * HTTP :8081 (primario) + TCP :8082 (fallback)
 * t:me/JuanitoProSniif
 */
'use strict';

const http = require('http');
const net  = require('net');

const TOKEN = 'msyvpn2024secret';  // Mismo que en ContadorOnlineVPS.java
const PH    = 8081;                // Puerto HTTP
const PT    = 8082;                // Puerto TCP fallback
const TU    = 3 * 60 * 1000;      // Timeout usuario: 3 minutos
const TL    = 2 * 60 * 1000;      // Intervalo limpieza: 2 minutos
const MB    = 512;                 // Max bytes body
const MC    = 200;                 // Max conexiones TCP simultáneas

// userId → { sv: "España_6", cf: "V2Ray_Full", ts: timestamp }
// sv = ubicación  (ConfigSelectionDialog  → selected_server_name2)
// cf = método     (ServerSelectionDialog  → selected_server_name)
const usuarios = new Map();
let   connTcp  = 0;

// ── SANITIZACIÓN ──────────────────────────────────────────────────────────────
// \p{L} con /gu = mismo comportamiento que Java \p{L}
// → "España" conserva la ñ, "México" conserva la é, etc.
// \w (versión vieja) solo reconocía ASCII → convertía ñ en _ (BUG)
function sanitizar(n) {
    if (!n || typeof n !== 'string') return '';
    return n.trim()
        .replace(/[.#$[\]/\\]/g, '_')
        .replace(/[^\p{L}\p{N}\s_\-]/gu, '_')
        .replace(/\s+/g, '_')
        .replace(/_{2,}/g, '_')
        .substring(0, 120);
}

// ── CALCULAR CONTEOS ──────────────────────────────────────────────────────────
function calcular() {
    const ahora = Date.now();
    const sv = Object.create(null);
    const cf = Object.create(null);
    let total = 0;
    for (const [, u] of usuarios) {
        if (ahora - u.ts > TU) continue;
        total++;
        if (u.sv) sv[u.sv] = (sv[u.sv] || 0) + 1;
        if (u.cf) cf[u.cf] = (cf[u.cf] || 0) + 1;
    }
    return { t: total, sv, cf };
}

// ── PROCESAR COMANDO (compartido HTTP y TCP) ──────────────────────────────────
function procesarCmd(comando, datos) {
    try {
        if (comando === 'CT') return JSON.stringify(calcular());
        if (comando === 'HB' && datos && datos.id) {
            usuarios.set(String(datos.id), {
                sv: sanitizar(datos.sv || ''),
                cf: sanitizar(datos.cf || ''),
                ts: Date.now()
            });
            return '{}';
        }
        if (comando === 'DC' && datos && datos.id) {
            usuarios.delete(String(datos.id));
            return '{}';
        }
    } catch (e) {}
    return '{}';
}

// ── LIMPIEZA AUTOMÁTICA ───────────────────────────────────────────────────────
setInterval(() => {
    const ahora = Date.now();
    let n = 0;
    for (const [id, u] of usuarios) {
        if (ahora - u.ts > TU) { usuarios.delete(id); n++; }
    }
    if (n > 0) console.log(`[Limpieza] -${n} | Activos: ${usuarios.size}`);
}, TL);

// ── HTTP ──────────────────────────────────────────────────────────────────────
function leerBody(req) {
    return new Promise((res, rej) => {
        let data = '', bytes = 0;
        req.on('data', c => {
            bytes += c.length;
            if (bytes > MB) { req.destroy(); rej(new Error('largo')); return; }
            data += c.toString('utf8');
        });
        req.on('end',   () => res(data));
        req.on('error', e  => rej(e));
    });
}

function respHTTP(res, code, json) {
    res.writeHead(code, {
        'Content-Type':   'application/json; charset=utf-8',
        'Content-Length': Buffer.byteLength(json, 'utf8')
    });
    res.end(json);
}

const sHTTP = http.createServer(async (req, res) => {
    if (req.headers['x-token'] !== TOKEN) { respHTTP(res, 403, '{}'); return; }

    if (req.method === 'GET' && req.url === '/ct') {
        respHTTP(res, 200, JSON.stringify(calcular()));
        return;
    }
    if (req.method === 'GET' && req.url === '/status') {
        respHTTP(res, 200, JSON.stringify({
            activos: usuarios.size,
            tcp:     connTcp,
            uptime:  Math.floor(process.uptime()) + 's',
            node:    process.version
        }));
        return;
    }
    if (req.method === 'GET' && req.url === '/debug') {
        const ahora = Date.now(), lista = [];
        for (const [id, u] of usuarios) {
            if (ahora - u.ts <= TU)
                lista.push({ id: id.substring(0, 12), sv: u.sv, cf: u.cf, hace: Math.floor((ahora - u.ts) / 1000) + 's' });
        }
        respHTTP(res, 200, JSON.stringify({ total: lista.length, usuarios: lista }));
        return;
    }
    if (req.method === 'POST' && (req.url === '/hb' || req.url === '/dc')) {
        try {
            const datos = JSON.parse(await leerBody(req));
            respHTTP(res, 200, procesarCmd(req.url === '/hb' ? 'HB' : 'DC', datos));
        } catch (e) { respHTTP(res, 400, '{}'); }
        return;
    }
    respHTTP(res, 404, '{}');
});

sHTTP.on('error', e => {
    console.error('[HTTP Error]', e.message);
    if (e.code === 'EADDRINUSE') { console.error('Puerto ' + PH + ' ocupado.'); process.exit(1); }
});
sHTTP.listen(PH, '0.0.0.0', () => console.log('✓ HTTP  :' + PH));

// ── TCP FALLBACK ──────────────────────────────────────────────────────────────
// Protocolo: TOKEN|COMANDO|JSON\n → JSON_RESPUESTA\n
const sTCP = net.createServer(sock => {
    if (connTcp >= MC) { sock.destroy(); return; }
    connTcp++;
    sock.setTimeout(8000);
    let buf = '';

    sock.on('data', chunk => {
        buf += chunk.toString('utf8');
        if (buf.length > MB * 2) { sock.destroy(); return; }
        const fin = buf.indexOf('\n');
        if (fin === -1) return;
        const linea = buf.substring(0, fin).trim();
        buf = '';
        const s1 = linea.indexOf('|'), s2 = linea.indexOf('|', s1 + 1);
        if (s1 === -1) { sock.destroy(); return; }
        const tok = linea.substring(0, s1);
        const cmd = s2 !== -1 ? linea.substring(s1 + 1, s2) : linea.substring(s1 + 1);
        const cu  = s2 !== -1 ? linea.substring(s2 + 1) : '{}';
        if (tok !== TOKEN) { sock.destroy(); return; }
        let datos = {};
        try { datos = JSON.parse(cu); } catch (e) {}
        sock.end(procesarCmd(cmd, datos) + '\n');
    });

    const liberar = () => { connTcp = Math.max(0, connTcp - 1); };
    sock.on('close',   liberar);
    sock.on('error',   () => { liberar(); sock.destroy(); });
    sock.on('timeout', () => { liberar(); sock.destroy(); });
});

sTCP.on('error', e => console.error('[TCP Error]', e.message));
sTCP.listen(PT, '0.0.0.0', () => console.log('✓ TCP   :' + PT + ' (fallback)'));

function cerrar() { sHTTP.close(); sTCP.close(); setTimeout(() => process.exit(0), 500); }
process.on('SIGTERM', cerrar);
process.on('SIGINT',  cerrar);
JSEOF

ok "$ARCHIVO_JS creado"

# ── Verificar que el fix crítico está en el archivo ───────────────────────────
if grep -q "p{L}" "$ARCHIVO_JS"; then
    ok "Sanitización unicode correcta (\\p{L}) verificada en el archivo"
else
    error "ERROR: la sanitización unicode no quedó en el archivo"
fi

# ── Test rápido de sanitización con Node.js ───────────────────────────────────
info "Probando sanitización unicode..."
RESULTADO=$("$NODE_BIN" -e "
function sanitizar(n){
  if(!n||typeof n!=='string')return'';
  return n.trim()
    .replace(/[.#\$\[\]\/\\\\]/g,'_')
    .replace(/[^\p{L}\p{N}\s_\-]/gu,'_')
    .replace(/\s+/g,'_')
    .replace(/_{2,}/g,'_');
}
const pruebas = ['España','México','São Paulo','V2Ray Full','SSH Direct'];
let ok = true;
pruebas.forEach(p => {
  const r = sanitizar(p);
  const correcto = !r.includes('Espa_a') && !r.includes('M_xico') && !r.includes('S_o');
  if(!correcto) ok = false;
  console.log(p + ' → ' + r);
});
console.log(ok ? 'TEST_OK' : 'TEST_FAIL');
" 2>&1)

echo "$RESULTADO"
if echo "$RESULTADO" | grep -q "TEST_OK"; then
    ok "Sanitización unicode funciona correctamente"
else
    aviso "Posible problema con Node.js y unicode. Versión: $("$NODE_BIN" --version)"
fi

# ── Servicio systemd ──────────────────────────────────────────────────────────
# Ubuntu 18+ incluye systemd por defecto
info "Configurando servicio systemd..."
cat > "$SERVICIO" << SYSEOF
[Unit]
Description=MSY VPN Servidor Conteo Online
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=$NODE_BIN $ARCHIVO_JS
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=msyvpn-conteo
Environment=NODE_ENV=production
Environment=HOME=/root

[Install]
WantedBy=multi-user.target
SYSEOF

systemctl daemon-reload 2>/dev/null || true
systemctl enable msyvpn-conteo 2>/dev/null || true
systemctl restart msyvpn-conteo 2>/dev/null || service msyvpn-conteo restart 2>/dev/null || true
sleep 3

if systemctl is-active --quiet msyvpn-conteo 2>/dev/null; then
    ok "Servicio msyvpn-conteo activo"
else
    aviso "Error con systemd. Revisando logs..."
    journalctl -u msyvpn-conteo -n 15 --no-pager 2>/dev/null || true
    echo -e "${AMARILLO}Si el servicio no inicia, ejecuta manualmente:${NC}"
    echo -e "  $NODE_BIN $ARCHIVO_JS &"
fi

# ── Firewall ──────────────────────────────────────────────────────────────────
info "Abriendo puertos 8081 y 8082..."
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
    # Ubuntu 18 no soporta "comment" en ufw allow — usar sin comentario
    ufw allow 8081/tcp 2>/dev/null || true
    ufw allow 8082/tcp 2>/dev/null || true
    ok "Puertos abiertos en UFW"
fi
# Siempre aplicar iptables como respaldo
if command -v iptables &>/dev/null; then
    iptables -C INPUT -p tcp --dport 8081 -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p tcp --dport 8081 -j ACCEPT 2>/dev/null || true
    iptables -C INPUT -p tcp --dport 8082 -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p tcp --dport 8082 -j ACCEPT 2>/dev/null || true
    ok "Puertos abiertos en iptables"
fi

# ── Verificación final ────────────────────────────────────────────────────────
sleep 2
info "Verificando servidor..."
CT=$(curl -s -H "X-Token: msyvpn2024secret" "http://127.0.0.1:8081/ct" 2>/dev/null)
STATUS=$(curl -s -H "X-Token: msyvpn2024secret" "http://127.0.0.1:8081/status" 2>/dev/null)

if echo "$STATUS" | grep -q "uptime"; then
    ok "Servidor HTTP respondiendo correctamente"
else
    aviso "Servidor no responde. Revisa: journalctl -u msyvpn-conteo -f"
fi

IP=$(curl -s https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')

echo ""
echo -e "${VERDE}╔══════════════════════════════════════════════════════════════╗"
echo    "║              ✓  INSTALACIÓN COMPLETADA                      ║"
echo    "╠══════════════════════════════════════════════════════════════╣"
echo -e "║  Archivo:   /root/conteo_server.js"
echo -e "║  Servicio:  msyvpn-conteo (systemd)"
echo -e "║  HTTP:      http://$IP:8081"
echo -e "║  TCP:       $IP:8082 (fallback)"
echo -e "║  Token:     msyvpn2024secret"
echo -e "║"
echo -e "║  En ContadorOnlineVPS.java cambia estas líneas:"
echo -e "║    VPS_HOST = \"$IP\""
echo -e "║    TOKEN    = \"msyvpn2024secret\""
echo -e "║"
echo -e "║  Comandos útiles:"
echo -e "║  → Logs en vivo:  journalctl -u msyvpn-conteo -f"
echo -e "║  → Ver conteos:   curl -H 'X-Token: msyvpn2024secret' \\"
echo -e "║                        http://127.0.0.1:8081/ct"
echo -e "║  → Ver usuarios:  curl -H 'X-Token: msyvpn2024secret' \\"
echo -e "║                        http://127.0.0.1:8081/debug"
echo -e "║  → Reiniciar:     systemctl restart msyvpn-conteo"
echo -e "╚══════════════════════════════════════════════════════════════╝${NC}"
