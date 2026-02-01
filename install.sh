#!/bin/bash

# Setup Script: All-In-One Installer for Nautica Node.js Server
# This script creates all necessary files locally and sets up the environment.

echo "============================================="
echo "   RUTE PREMIUM Auto-Installer               "
echo "   (Local File Generation Version)           "
echo "============================================="

# 0. Pre-check
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit
fi

# Ask for Domain
read -p "Enter your domain (e.g. vpn.example.com): " DOMAIN_NAME
if [ -z "$DOMAIN_NAME" ]; then
    echo "Domain is required!"
    exit 1
fi

# Ask for Admin Password
read -p "Set Dashboard Password (user: admin): " ADMIN_PASS
if [ -z "$ADMIN_PASS" ]; then
    ADMIN_PASS="admin"
    echo "Default password 'admin' set."
fi

# 1. Install Dependencies
echo "[1/4] Installing dependencies..."
apt-get update
apt-get install -y curl debian-keyring debian-archive-keyring apt-transport-https unzip git cron

curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs

curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt-get update
apt-get install -y caddy

# 2. Create Project Files
echo "[2/4] Generating application files..."
INSTALL_DIR="/opt/nautica"
mkdir -p $INSTALL_DIR/public

# Generate .gitignore
cat <<EOF > $INSTALL_DIR/.gitignore
node_modules/
config.json
users.json
public/
EOF

# Generate package.json
cat <<EOF > $INSTALL_DIR/package.json
{
  "name": "nautica-node-proxy",
  "version": "1.0.0",
  "description": "Node.js port of Nautica with Proxy Routing Support",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "ws": "^8.16.0"
  },
  "engines": {
    "node": ">=18.0.0"
  }
}
EOF

# Generate server.js
cat <<'EOF' > $INSTALL_DIR/server.js
const http = require('http');
const net = require('net');
const WebSocket = require('ws');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { webcrypto, createHash, randomUUID } = require('crypto');
const { exec } = require('child_process');
const crypto = webcrypto;

const DB_FILE = path.join(__dirname, 'users.json');
const CONFIG_FILE = path.join(__dirname, 'config.json');
const SESSIONS = new Map();

const horse = "dHJvamFu";
const flash = "dm1lc3M=";
const neko = "dmxlc3M=";

const CORS_HEADER_OPTIONS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET,HEAD,POST,DELETE,OPTIONS",
  "Access-Control-Max-Age": "86400",
  "Access-Control-Allow-Headers": "Content-Type, Authorization"
};

const SALT_A1 = atob("Vk1lc3MgSGVhZGVyIEFFQUQgS2V5X0xlbmd0aA==");
const SALT_A2 = atob("Vk1lc3MgSGVhZGVyIEFFQUQgTm9uY2VfTGVuZ3Ro");
const SALT_A3 = atob("Vk1lc3MgSGVhZGVyIEFFQUQgS2V5");
const SALT_A4 = atob("Vk1lc3MgSGVhZGVyIEFFQUQgTm9uY2U=");
const SALT_B1 = atob("QUVBRCBSZXNwIEhlYWRlciBMZW4gS2V5");
const SALT_B2 = atob("QUVBRCBSZXNwIEhlYWRlciBMZW4gSVY=");
const SALT_B3 = atob("QUVBRCBSZXNwIEhlYWRlciBLZXk=");
const SALT_B4 = atob("QUVBRCBSZXNwIEhlYWRlciBJVg==");

const PORT = process.env.PORT || 80;

function atob(str) { return Buffer.from(str, 'base64').toString('binary'); }
function btoa(str) { return Buffer.from(str, 'binary').toString('base64'); }
function arrayBufferToHex(buf) { return Buffer.from(buf).toString('hex'); }

function getUsers() {
    if (!fs.existsSync(DB_FILE)) return [];
    try { return JSON.parse(fs.readFileSync(DB_FILE, 'utf8')); } catch { return []; }
}

function saveUser(user) {
    const users = getUsers();
    users.unshift(user);
    fs.writeFileSync(DB_FILE, JSON.stringify(users, null, 2));
}

function deleteUser(uuid) {
    const users = getUsers().filter(u => u.uuid !== uuid);
    fs.writeFileSync(DB_FILE, JSON.stringify(users, null, 2));
}

function isValidUser(uuid) {
    const users = getUsers();
    const user = users.find(u => u.uuid === uuid);
    if (!user) return false;
    const expDate = new Date(user.expiredDate);
    if (new Date() > expDate) return false;
    return true;
}

function isValidTrojanUser(hash) {
    const users = getUsers().filter(u => u.protocol === 'trojan');
    for (const u of users) {
        if (createHash('sha224').update(u.uuid).digest('hex') === hash) return true;
    }
    return false;
}

function getAdminCredentials() {
    if (!fs.existsSync(CONFIG_FILE)) return { adminUser: 'admin', adminPass: 'admin' };
    try { return JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8')); } catch { return { adminUser: 'admin', adminPass: 'admin' }; }
}

// --- Stats & Info ---
let previousCpuUsage = null;
let sysInfo = {
    ip: "Loading...",
    isp: "Loading...",
    city: "Loading...",
    domain: "Loading..."
};

// Fetch IP/ISP
exec('curl -s http://ip-api.com/json', (err, stdout) => {
    if (!err) {
        try {
            const data = JSON.parse(stdout);
            sysInfo.ip = data.query;
            sysInfo.isp = data.isp;
            sysInfo.city = data.city;
        } catch {}
    }
});

// Fetch Domain (from Caddyfile)
function getDomain() {
    try {
        const caddy = fs.readFileSync('/etc/caddy/Caddyfile', 'utf8');
        const match = caddy.match(/^([a-zA-Z0-9.-]+)\s*\{/);
        return match ? match[1] : (process.env.DOMAIN_NAME || "Unknown");
    } catch { return "Unknown"; }
}

function getCpuUsage() {
    const cpus = os.cpus();
    let user = 0, nice = 0, sys = 0, idle = 0, irq = 0;
    for (const cpu of cpus) {
        user += cpu.times.user; nice += cpu.times.nice; sys += cpu.times.sys; idle += cpu.times.idle; irq += cpu.times.irq;
    }
    const total = user + nice + sys + idle + irq;
    const usage = { total, idle };
    let percent = 0;
    if (previousCpuUsage) {
        const totalDiff = total - previousCpuUsage.total;
        const idleDiff = idle - previousCpuUsage.idle;
        if (totalDiff > 0) percent = 100 - Math.round((idleDiff / totalDiff) * 100);
    }
    previousCpuUsage = usage;
    return percent;
}

function getNetworkTraffic() {
    try {
        const data = fs.readFileSync('/proc/net/dev', 'utf8');
        const lines = data.split('\n');
        for (const line of lines) {
            if (line.includes(':') && !line.trim().startsWith('lo')) {
                const parts = line.split(':')[1].trim().split(/\s+/);
                return { rx: parseInt(parts[0]), tx: parseInt(parts[8]) };
            }
        }
    } catch { }
    return { rx: 0, tx: 0 };
}

const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, `http://${req.headers.host}`);

    // Auth Check
    const isPublic = url.pathname.startsWith("/sub") || url.pathname === '/login.html' || url.pathname === '/api/login';
    let isAuthenticated = false;
    const cookieHeader = req.headers.cookie;
    if (cookieHeader) {
        const cookies = cookieHeader.split(';').reduce((acc, c) => {
            const [n, v] = c.trim().split('='); acc[n] = v; return acc;
        }, {});
        if (cookies.session_token && SESSIONS.has(cookies.session_token)) isAuthenticated = true;
    }

    if (url.pathname.startsWith('/api/') && url.pathname !== '/api/login') {
        if (!isAuthenticated) { res.writeHead(401); res.end('Unauthorized'); return; }
    } else if (!isPublic && (url.pathname === '/' || url.pathname.endsWith('.html'))) {
        if (!isAuthenticated) { res.writeHead(302, { 'Location': '/login.html' }); res.end(); return; }
    }

    // Login
    if (url.pathname === '/api/login' && req.method === 'POST') {
        let body = '';
        req.on('data', chunk => body += chunk);
        req.on('end', () => {
            try {
                const { username, password } = JSON.parse(body);
                const creds = getAdminCredentials();
                if (username === creds.adminUser && password === creds.adminPass) {
                    const token = randomUUID();
                    SESSIONS.set(token, { user: username, created: Date.now() });
                    res.writeHead(200, { 'Set-Cookie': `session_token=${token}; HttpOnly; Path=/; Max-Age=86400`, 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ success: true }));
                } else {
                    res.writeHead(401, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ error: "Invalid credentials" }));
                }
            } catch { res.writeHead(400); res.end(); }
        });
        return;
    }

    // API Stats
    if (url.pathname === '/api/stats' && req.method === 'GET') {
        const stats = {
            info: {
                ...sysInfo,
                domain: getDomain()
            },
            ram: { total: os.totalmem(), free: os.freemem(), usage: Math.round(((os.totalmem() - os.freemem()) / os.totalmem()) * 100) },
            cpu: { cores: os.cpus().length, usage: getCpuUsage() },
            net: getNetworkTraffic()
        };
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(stats));
        return;
    }

    // Settings
    if (url.pathname === '/api/settings/domain' && req.method === 'POST') {
        let body = '';
        req.on('data', chunk => body += chunk);
        req.on('end', () => {
            try {
                const { domain } = JSON.parse(body);
                if (!domain || !/^[a-zA-Z0-9.-]+$/.test(domain)) throw new Error("Invalid Domain");
                const caddyFile = `${domain} {\n    reverse_proxy localhost:${PORT}\n}`;
                fs.writeFileSync('/etc/caddy/Caddyfile', caddyFile);
                exec('systemctl reload caddy', (err) => {
                    if (err) { res.writeHead(500); res.end(JSON.stringify({ error: "Failed to reload Caddy" })); }
                    else { res.writeHead(200); res.end(JSON.stringify({ success: true })); }
                });
            } catch (e) { res.writeHead(400); res.end(JSON.stringify({ error: e.message })); }
        });
        return;
    }

    if (url.pathname === '/api/settings/password' && req.method === 'POST') {
        let body = '';
        req.on('data', chunk => body += chunk);
        req.on('end', () => {
            try {
                const { password } = JSON.parse(body);
                if (!password) throw new Error("Missing password");
                const creds = getAdminCredentials();
                creds.adminPass = password;
                fs.writeFileSync(CONFIG_FILE, JSON.stringify(creds, null, 2));
                res.writeHead(200); res.end(JSON.stringify({ success: true }));
            } catch (e) { res.writeHead(400); res.end(JSON.stringify({ error: e.message })); }
        });
        return;
    }

    if (url.pathname === '/api/settings/reboot' && req.method === 'POST') {
        let body = '';
        req.on('data', chunk => body += chunk);
        req.on('end', () => {
            try {
                const { time } = JSON.parse(body);
                if (!time || !/^\d{2}:\d{2}$/.test(time)) throw new Error("Invalid time");
                const [h, m] = time.split(':');
                exec('crontab -l | grep -v "sbin/reboot"', (err, stdout) => {
                    const newCron = `${stdout ? stdout.trim() + '\n' : ''}${m} ${h} * * * /sbin/reboot\n`;
                    const p = exec('crontab -', (e) => {
                        if (e) { res.writeHead(500); res.end(JSON.stringify({ error: "Failed to update crontab" })); }
                        else { res.writeHead(200); res.end(JSON.stringify({ success: true })); }
                    });
                    p.stdin.write(newCron);
                    p.stdin.end();
                });
            } catch (e) { res.writeHead(400); res.end(JSON.stringify({ error: e.message })); }
        });
        return;
    }

    // Update (FIXED LOGIC)
    if (url.pathname === '/api/update' && req.method === 'POST') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        exec('git fetch --all && git reset --hard origin/main', { cwd: __dirname }, (err, stdout, stderr) => {
            if (err) {
                console.error(err);
                res.end(JSON.stringify({ success: false, message: stderr || err.message }));
                return;
            }
            res.end(JSON.stringify({ success: true, message: "Update successful. Restarting..." }));
            setTimeout(() => process.exit(0), 3000);
        });
        return;
    }

    // Users
    if (url.pathname === '/api/users') {
        if (req.method === 'GET') {
            res.writeHead(200, { ...CORS_HEADER_OPTIONS, 'Content-Type': 'application/json' });
            res.end(JSON.stringify(getUsers()));
            return;
        } else if (req.method === 'POST') {
            let body = '';
            req.on('data', chunk => body += chunk);
            req.on('end', () => {
                try {
                    const data = JSON.parse(body);
                    if (!data.username || !data.protocol || !data.uuid) throw new Error("Missing fields");
                    saveUser(data);
                    res.writeHead(200, CORS_HEADER_OPTIONS);
                    res.end(JSON.stringify({ success: true }));
                } catch (e) { res.writeHead(400, CORS_HEADER_OPTIONS); res.end(JSON.stringify({ error: e.message })); }
            });
            return;
        }
    }

    if (url.pathname.startsWith('/api/users/') && req.method === 'DELETE') {
        const uuid = url.pathname.split('/').pop();
        deleteUser(uuid);
        res.writeHead(200, CORS_HEADER_OPTIONS);
        res.end(JSON.stringify({ success: true }));
        return;
    }

    // Static
    let requestedPath = url.pathname === '/' ? '/index.html' : url.pathname;
    requestedPath = requestedPath.split('?')[0];
    const publicDir = path.join(__dirname, 'public');
    const safePath = path.normalize(path.join(publicDir, requestedPath));

    if (safePath.startsWith(publicDir) && fs.existsSync(safePath) && fs.statSync(safePath).isFile()) {
         const ext = path.extname(safePath);
         const mime = { '.html': 'text/html', '.css': 'text/css', '.js': 'text/javascript' }[ext] || 'text/plain';
         res.writeHead(200, { 'Content-Type': mime });
         fs.createReadStream(safePath).pipe(res);
         return;
    }

    res.writeHead(404);
    res.end("Not Found");
});

const wss = new WebSocket.Server({ noServer: true });

server.on('upgrade', async (request, socket, head) => {
    wss.handleUpgrade(request, socket, head, (ws) => {
        websocketHandler(ws, request);
    });
});

async function websocketHandler(webSocket, request) {
    const wsStream = WebSocket.createWebSocketStream(webSocket);
    const log = (msg) => console.log(`[WS] ${msg}`);

    wsStream.once('data', async (chunk) => {
        wsStream.pause();
        try {
            const protocol = await protocolSniffer(chunk);
            let protocolHeader;
            let authenticated = false;

            if (protocol === atob(horse)) {
                protocolHeader = readHorseHeader(chunk);
                if (!protocolHeader.hasError && isValidTrojanUser(protocolHeader.passwordHash)) authenticated = true;
            } else if (protocol === atob(neko)) {
                protocolHeader = readNekoHeader(chunk);
                const uuid = arrayBufferToHex(chunk.slice(1, 17));
                const formattedUUID = `${uuid.substr(0,8)}-${uuid.substr(8,4)}-${uuid.substr(12,4)}-${uuid.substr(16,4)}-${uuid.substr(20,12)}`;
                if (isValidUser(formattedUUID)) authenticated = true;
            } else if (protocol === atob(flash)) {
                const users = getUsers().filter(u => u.protocol === 'vmess');
                for (const user of users) {
                    const result = await readStreamHeader(chunk, user.uuid);
                    if (!result.hasError) { protocolHeader = result; authenticated = true; break; }
                }
            } else throw new Error("Unknown Protocol");

            if (!protocolHeader || protocolHeader.hasError) throw new Error("Header Parse Failed");
            if (!authenticated) { webSocket.close(); return; }

            let responseHeader = protocolHeader.version;
            if (protocol === atob(flash) && protocolHeader.needsResponse) {
                 responseHeader = await generateStreamResponseHeader(protocolHeader.responseOptions, protocolHeader.encKey, protocolHeader.encIv);
            }

            if (responseHeader) wsStream.write(responseHeader);

            const targetHost = protocolHeader.addressRemote;
            const targetPort = protocolHeader.portRemote;

            if (protocolHeader.isUDP) {
                 await handleUDPOutbound(targetHost, targetPort, protocolHeader.rawClientData, webSocket, wsStream, log);
            } else {
                await handleTCPOutbound(targetHost, targetPort, protocolHeader.rawClientData, webSocket, wsStream, log);
            }
        } catch (err) { webSocket.close(); }
    });
    wsStream.on('error', (err) => log(`Stream Error: ${err.message}`));
}

async function handleTCPOutbound(addressRemote, portRemote, rawClientData, webSocket, wsStream, log) {
    try {
        const s = net.connect(portRemote, addressRemote);
        s.setNoDelay(true);
        s.setKeepAlive(true);
        await new Promise((res, rej) => { s.once('connect', res); s.once('error', rej); });

        if (rawClientData && rawClientData.length > 0) s.write(rawClientData);

        wsStream.pipe(s);
        s.pipe(wsStream);
        wsStream.resume();
        s.on('close', () => webSocket.close());
    } catch (e) { webSocket.close(); }
}

async function handleUDPOutbound(targetAddress, targetPort, dataChunk, webSocket, wsStream, log) {
    webSocket.close();
}

// ... Protocol Parsers ...
async function protocolSniffer(buffer) {
    if (buffer.length >= 18 && buffer[0] === 0) return atob(neko);
    if (buffer.length >= 62) { const d = buffer.slice(56, 60); if (d[0]===0x0d && d[1]===0x0a) return atob(horse); }
    if (buffer.length >= 42) return atob(flash);
    return "";
}
function readHorseHeader(buffer) {
    if (buffer.length < 58) return { hasError: true };
    const hash = buffer.slice(0, 56).toString();
    const data = buffer.slice(58);
    if (data.length < 6) return { hasError: true };
    const cmd = data[0];
    const atype = data[1];
    let off = 2;
    let addr = "";
    if (atype === 1) { addr = data.slice(off, off+4).join('.'); off+=4; }
    else if (atype === 3) { const l = data[off]; off++; addr = data.slice(off, off+l).toString(); off+=l; }
    else if (atype === 4) { off+=16; addr="ipv6"; }
    else return { hasError: true };
    const port = data.readUInt16BE(off);
    return { hasError: false, addressRemote: addr, portRemote: port, isUDP: cmd===3, rawClientData: data.slice(off+2), passwordHash: hash };
}
function readNekoHeader(buffer) {
    const ver = buffer[0];
    const optLen = buffer[17];
    const cmd = buffer[18+optLen];
    const portInd = 18+optLen+1;
    const port = buffer.readUInt16BE(portInd);
    const atype = buffer[portInd+2];
    let off = portInd+3;
    let addr = "";
    if (atype === 1) { addr = buffer.slice(off, off+4).join('.'); off+=4; }
    else if (atype === 2) { const l = buffer[off]; off++; addr = buffer.slice(off, off+l).toString(); off+=l; }
    else if (atype === 3) { off+=16; addr="ipv6"; }
    return { hasError: false, addressRemote: addr, portRemote: port, isUDP: cmd===2, rawClientData: buffer.slice(off), version: new Uint8Array([ver, 0]) };
}
async function readStreamHeader(buffer, uuid) {
    try {
        const keyBytes = new Uint8Array(uuid.replace(/-/g, "").match(/.{1,2}/g).map(b => parseInt(b, 16)));
        const authKey = await md5(keyBytes, new TextEncoder().encode(atob("YzQ4NjE5ZmUtOGYwMi00OWUwLWI5ZTktZWRmNzYzZTE3ZTIx")));
        const authId = buffer.slice(0, 16);
        const encLen = buffer.slice(16, 34);
        const nonce = buffer.slice(34, 42);
        const lKey = (await kdf(authKey, [SALT_A1, authId, nonce])).slice(0, 16);
        const lIv = (await kdf(authKey, [SALT_A2, authId, nonce])).slice(0, 12);
        const lBytes = await aesGcmDecrypt(lKey, lIv, encLen, authId);
        const hLen = (lBytes[0] << 8) | lBytes[1];
        const encHead = buffer.slice(42, 42 + hLen + 16);
        const pKey = (await kdf(authKey, [SALT_A3, authId, nonce])).slice(0, 16);
        const pIv = (await kdf(authKey, [SALT_A4, authId, nonce])).slice(0, 12);
        const head = await aesGcmDecrypt(pKey, pIv, encHead, authId);
        const view = Buffer.from(head);
        let off = 0;
        const ver = view[off++];
        const encIv = view.slice(off, off+16); off+=16;
        const encKey = view.slice(off, off+16); off+=16;
        const opts = view.slice(off, off+4); off+=4;
        const cmd = view[off++];
        const port = view.readUInt16BE(off); off+=2;
        const atype = view[off++];
        let addr = "";
        if (atype === 1) { addr = view.slice(off, off+4).join('.'); off+=4; }
        else if (atype === 2) { const l = view[off++]; addr = view.slice(off, off+l).toString(); off+=l; }
        return { hasError: false, addressRemote: addr, portRemote: port, isUDP: cmd!==1, rawClientData: buffer.slice(42+hLen+16), version: new Uint8Array([opts[0], 0]), encKey, encIv, needsResponse: true, responseOptions: opts };
    } catch(e) { return { hasError: true, message: e.message }; }
}
async function generateStreamResponseHeader(opts, key, iv) {
    try {
        const sKey = (await sha256(key)).slice(0, 16);
        const sIv = (await sha256(iv)).slice(0, 16);
        const rLenKey = (await kdf(sKey, [SALT_B1])).slice(0, 16);
        const rLenIv = (await kdf(sIv, [SALT_B2])).slice(0, 12);
        const rLenData = new Uint8Array([0, 4]);
        const encLen = await aesGcmEncrypt(rLenKey, rLenIv, rLenData, new Uint8Array(0));
        const rHead = new Uint8Array([opts[0], 0, 0, 0]);
        const rHeadKey = (await kdf(sKey, [SALT_B3])).slice(0, 16);
        const rHeadIv = (await kdf(sIv, [SALT_B4])).slice(0, 12);
        const encHead = await aesGcmEncrypt(rHeadKey, rHeadIv, rHead, new Uint8Array(0));
        return Buffer.concat([encLen, encHead]);
    } catch(e) { return Buffer.alloc(0); }
}
async function md5(...args) { return new Uint8Array(createHash('md5').update(Buffer.concat(args.map(a=>Buffer.from(a)))).digest()); }
async function sha256(d) { return new Uint8Array(await crypto.subtle.digest("SHA-256", d)); }
async function aesGcmDecrypt(k, n, d, a) {
    const key = await crypto.subtle.importKey("raw", k, {name:"AES-GCM"}, false, ["decrypt"]);
    return new Uint8Array(await crypto.subtle.decrypt({name:"AES-GCM", iv:n, additionalData:a}, key, d));
}
async function aesGcmEncrypt(k, n, d, a) {
    const key = await crypto.subtle.importKey("raw", k, {name:"AES-GCM"}, false, ["encrypt"]);
    return new Uint8Array(await crypto.subtle.encrypt({name:"AES-GCM", iv:n, additionalData:a}, key, d));
}
async function kdf(key, path) {
    async function hmac(k, d) {
        const key = await crypto.subtle.importKey("raw", k, {name:"HMAC", hash:"SHA-256"}, false, ["sign"]);
        return new Uint8Array(await crypto.subtle.sign("HMAC", key, d));
    }
    let result = key;
    for (const p of path) { result = await hmac(result, p); }
    return result;
}

function arrayBufferToHex(buf) { return Buffer.from(buf).toString('hex'); }

server.listen(PORT, () => { console.log(`Server running on ${PORT}`); });
EOF

# Generate Dashboard HTML
cat <<'EOF' > $INSTALL_DIR/public/index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>RUTE PREMIUM | VPS Manager</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&display=swap" rel="stylesheet">
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">
    <style>
        :root {
            --bg-body: #0f172a;
            --bg-panel: #1e293b;
            --bg-input: #334155;
            --text-main: #f8fafc;
            --text-muted: #94a3b8;
            --primary: #3b82f6;
            --primary-hover: #2563eb;
            --danger: #ef4444;
            --success: #10b981;
            --warning: #f59e0b;
            --border: #334155;
        }

        * { margin: 0; padding: 0; box-sizing: border-box; }

        body {
            font-family: 'Inter', sans-serif;
            background-color: var(--bg-body);
            color: var(--text-main);
            min-height: 100vh;
            display: flex;
        }

        /* Sidebar */
        .sidebar {
            width: 250px;
            background-color: var(--bg-panel);
            border-right: 1px solid var(--border);
            display: flex;
            flex-direction: column;
            position: fixed;
            height: 100%;
            left: 0;
            top: 0;
            z-index: 50;
            transition: transform 0.3s ease;
        }

        .brand {
            padding: 24px;
            font-size: 1.5rem;
            font-weight: 700;
            color: var(--primary);
            display: flex;
            align-items: center;
            gap: 10px;
        }

        .nav-links {
            flex: 1;
            padding: 0 16px;
        }

        .nav-link {
            display: flex;
            align-items: center;
            gap: 12px;
            padding: 12px 16px;
            color: var(--text-muted);
            text-decoration: none;
            border-radius: 8px;
            margin-bottom: 4px;
            transition: all 0.2s;
            cursor: pointer;
        }

        .nav-link:hover, .nav-link.active {
            background-color: rgba(59, 130, 246, 0.1);
            color: var(--primary);
        }

        .nav-link i { width: 20px; text-align: center; }

        /* Main Content */
        .main {
            flex: 1;
            margin-left: 250px;
            padding: 32px;
            width: 100%;
        }

        /* Header */
        .header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 32px;
        }

        .title h1 { font-size: 1.5rem; font-weight: 600; }
        .title p { color: var(--text-muted); font-size: 0.9rem; margin-top: 4px; }

        .header-actions { display: flex; gap: 16px; }

        .btn {
            padding: 10px 20px;
            border-radius: 8px;
            border: none;
            font-weight: 500;
            cursor: pointer;
            display: inline-flex;
            align-items: center;
            gap: 8px;
            font-family: inherit;
            transition: 0.2s;
        }

        .btn-primary { background-color: var(--primary); color: white; }
        .btn-primary:hover { background-color: var(--primary-hover); }
        .btn-danger { background-color: rgba(239, 68, 68, 0.1); color: var(--danger); }
        .btn-danger:hover { background-color: rgba(239, 68, 68, 0.2); }
        .btn-success { background-color: var(--success); color: white; }
        .btn-success:hover { background-color: #059669; }
        .btn-sm { padding: 6px 12px; font-size: 0.85rem; }

        /* Stats Grid */
        .stats-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
            gap: 24px;
            margin-bottom: 32px;
        }

        .stat-card {
            background-color: var(--bg-panel);
            border: 1px solid var(--border);
            border-radius: 12px;
            padding: 24px;
        }

        .stat-label { color: var(--text-muted); font-size: 0.9rem; margin-bottom: 8px; display: flex; justify-content: space-between; }
        .stat-value { font-size: 1.5rem; font-weight: 700; color: white; }
        .stat-sub { font-size: 0.8rem; color: var(--text-muted); margin-top: 4px; }

        /* Progress Bar */
        .progress-bg {
            background-color: var(--bg-input);
            height: 6px;
            border-radius: 3px;
            margin-top: 12px;
            overflow: hidden;
        }
        .progress-fill {
            height: 100%;
            background-color: var(--primary);
            width: 0%;
            transition: width 0.5s ease;
        }

        /* Traffic Bar (Horizontal) */
        .traffic-card {
            background-color: var(--bg-panel);
            border: 1px solid var(--border);
            border-radius: 12px;
            padding: 24px;
            margin-bottom: 32px;
        }
        .traffic-header { display: flex; justify-content: space-between; margin-bottom: 16px; }

        .traffic-bar-container {
            display: flex;
            align-items: center;
            gap: 16px;
        }
        .traffic-bar-visual {
            flex: 1;
            background-color: var(--bg-input);
            height: 24px;
            border-radius: 6px;
            overflow: hidden;
            position: relative;
        }
        .traffic-bar-fill {
            height: 100%;
            background-color: var(--primary);
            width: 0%;
            transition: width 0.5s ease;
            position: absolute;
            left: 0; top: 0;
        }
        .traffic-stats-text {
            font-family: monospace;
            font-size: 1rem;
            color: white;
            min-width: 150px;
            text-align: right;
        }

        /* Table */
        .table-container {
            background-color: var(--bg-panel);
            border: 1px solid var(--border);
            border-radius: 12px;
            overflow: hidden;
        }

        .table-header {
            padding: 20px;
            border-bottom: 1px solid var(--border);
            display: flex;
            justify-content: space-between;
            align-items: center;
        }

        .search-box {
            position: relative;
        }
        .search-box input {
            background-color: var(--bg-body);
            border: 1px solid var(--border);
            color: white;
            padding: 8px 12px 8px 36px;
            border-radius: 6px;
            outline: none;
            width: 250px;
        }
        .search-box i {
            position: absolute;
            left: 12px;
            top: 50%;
            transform: translateY(-50%);
            color: var(--text-muted);
        }

        table {
            width: 100%;
            border-collapse: collapse;
        }

        th {
            text-align: left;
            padding: 16px 24px;
            color: var(--text-muted);
            font-weight: 500;
            font-size: 0.85rem;
            border-bottom: 1px solid var(--border);
        }

        td {
            padding: 16px 24px;
            border-bottom: 1px solid var(--border);
            vertical-align: middle;
        }

        tr:last-child td { border-bottom: none; }
        tr:hover td { background-color: rgba(255,255,255,0.02); }

        .badge {
            padding: 4px 8px;
            border-radius: 4px;
            font-size: 0.75rem;
            font-weight: 600;
            text-transform: uppercase;
        }
        .badge-vless { background: rgba(16, 185, 129, 0.1); color: var(--success); }
        .badge-vmess { background: rgba(245, 158, 11, 0.1); color: var(--warning); }
        .badge-trojan { background: rgba(59, 130, 246, 0.1); color: var(--primary); }

        /* Modal */
        .modal-overlay {
            position: fixed;
            top: 0; left: 0; width: 100%; height: 100%;
            background: rgba(0,0,0,0.5);
            backdrop-filter: blur(4px);
            z-index: 100;
            display: none;
            justify-content: center;
            align-items: center;
        }
        .modal-overlay.active { display: flex; }

        .modal {
            background-color: var(--bg-panel);
            width: 90%;
            max-width: 500px;
            border-radius: 16px;
            padding: 32px;
            border: 1px solid var(--border);
            box-shadow: 0 20px 25px -5px rgba(0, 0, 0, 0.3);
        }

        .form-group { margin-bottom: 20px; }
        .form-group label { display: block; margin-bottom: 8px; color: var(--text-muted); font-size: 0.9rem; }
        .form-group input, .form-group select {
            width: 100%;
            padding: 10px;
            background-color: var(--bg-input);
            border: 1px solid var(--border);
            border-radius: 6px;
            color: white;
            outline: none;
        }
        .form-group input:focus, .form-group select:focus { border-color: var(--primary); }

        /* Tabs */
        .tabs { display: flex; gap: 10px; margin-bottom: 20px; border-bottom: 1px solid var(--border); }
        .tab { padding: 10px; color: var(--text-muted); cursor: pointer; border-bottom: 2px solid transparent; }
        .tab.active { color: var(--primary); border-bottom-color: var(--primary); }
        .tab-content { display: none; }
        .tab-content.active { display: block; }

        /* Mobile */
        .mobile-toggle { display: none; color: white; font-size: 1.5rem; cursor: pointer; }

        @media (max-width: 768px) {
            .sidebar { transform: translateX(-100%); }
            .sidebar.open { transform: translateX(0); }
            .main { margin-left: 0; padding: 20px; }
            .mobile-toggle { display: block; margin-right: 16px; }
            .table-container { overflow-x: auto; }
            .header-actions { display: none; }
        }

        /* Toast */
        #toast-container { position: fixed; bottom: 24px; right: 24px; z-index: 200; }
        .toast {
            background: var(--bg-panel);
            border: 1px solid var(--border);
            padding: 16px 24px;
            border-radius: 8px;
            margin-top: 10px;
            display: flex;
            align-items: center;
            gap: 12px;
            box-shadow: 0 10px 15px -3px rgba(0, 0, 0, 0.3);
            animation: slideUp 0.3s ease;
        }
        @keyframes slideUp { from { transform: translateY(20px); opacity: 0; } to { transform: translateY(0); opacity: 1; } }
    </style>
</head>
<body>

    <nav class="sidebar" id="sidebar">
        <div class="brand">
            <i class="fa-solid fa-bolt"></i> RUTE PREMIUM
        </div>
        <div class="nav-links">
            <a onclick="showSection('dashboard')" class="nav-link active"><i class="fa-solid fa-grid-2"></i> Dashboard</a>
            <a onclick="showSection('settings')" class="nav-link"><i class="fa-solid fa-gear"></i> Settings</a>
            <div style="margin-top: auto; padding-top: 20px; border-top: 1px solid var(--border);">
                <a href="#" class="nav-link" onclick="updateSystem()"><i class="fa-solid fa-cloud-arrow-down"></i> Update System</a>
                <a href="#" class="nav-link" onclick="location.reload()"><i class="fa-solid fa-rotate"></i> Refresh</a>
            </div>
        </div>
    </nav>

    <main class="main" id="main-content">
        <!-- Dashboard Section -->
        <div id="section-dashboard">
            <div class="header">
                <div style="display:flex; align-items:center;">
                    <div class="mobile-toggle" onclick="toggleSidebar()"><i class="fa-solid fa-bars"></i></div>
                    <div class="title">
                        <h1>Dashboard</h1>
                        <p>System Overview & User Management</p>
                    </div>
                </div>
                <div class="header-actions">
                    <button class="btn btn-primary" onclick="openModal('createModal')">
                        <i class="fa-solid fa-plus"></i> New User
                    </button>
                </div>
            </div>

            <div class="stats-grid">
                <div class="stat-card">
                    <div class="stat-label">Public IP <i class="fa-solid fa-globe"></i></div>
                    <div class="stat-value" id="stat-ip" style="font-size: 1.2rem;">Loading...</div>
                    <div class="stat-sub" id="stat-isp">ISP: Loading...</div>
                </div>
                <div class="stat-card">
                    <div class="stat-label">Domain <i class="fa-solid fa-link"></i></div>
                    <div class="stat-value" id="stat-domain" style="font-size: 1.2rem;">Loading...</div>
                    <div class="stat-sub">VPS Domain</div>
                </div>
                <div class="stat-card">
                    <div class="stat-label">CPU Load <i class="fa-solid fa-microchip"></i></div>
                    <div class="stat-value" id="stat-cpu">0%</div>
                    <div class="progress-bg"><div class="progress-fill" id="prog-cpu" style="width: 0%"></div></div>
                    <div class="stat-sub" id="stat-cores">Loading Cores...</div>
                </div>
                <div class="stat-card">
                    <div class="stat-label">RAM Usage <i class="fa-solid fa-memory"></i></div>
                    <div class="stat-value" id="stat-ram">0%</div>
                    <div class="progress-bg"><div class="progress-fill" id="prog-ram" style="width: 0%; background-color: var(--warning);"></div></div>
                    <div class="stat-sub" id="stat-mem-det">Loading...</div>
                </div>
            </div>

            <div class="traffic-card">
                <div class="traffic-header">
                    <h3>Live Traffic</h3>
                    <span style="color: var(--text-muted); font-size: 0.9rem;">Real-time Network Load</span>
                </div>
                <div class="traffic-bar-container">
                    <div class="traffic-bar-visual">
                        <div class="traffic-bar-fill" id="traffic-fill"></div>
                    </div>
                    <div class="traffic-stats-text" id="traffic-text">0 KB/s</div>
                </div>
            </div>

            <div class="table-container">
                <div class="table-header">
                    <h3>User List</h3>
                    <div class="search-box">
                        <i class="fa-solid fa-search"></i>
                        <input type="text" placeholder="Search user..." id="search" onkeyup="filterUsers()">
                    </div>
                </div>
                <table>
                    <thead>
                        <tr>
                            <th>Username</th>
                            <th>Protocol</th>
                            <th>UUID / Password</th>
                            <th>Expiry</th>
                            <th>Actions</th>
                        </tr>
                    </thead>
                    <tbody id="user-table-body">
                    </tbody>
                </table>
            </div>
        </div>

        <!-- Settings Section -->
        <div id="section-settings" style="display: none;">
            <div class="header">
                <div style="display:flex; align-items:center;">
                    <div class="mobile-toggle" onclick="toggleSidebar()"><i class="fa-solid fa-bars"></i></div>
                    <div class="title">
                        <h1>Settings</h1>
                        <p>Server Configuration</p>
                    </div>
                </div>
            </div>

            <div class="modal" style="width: 100%; max-width: 600px; box-shadow: none;">
                <div class="tabs">
                    <div class="tab active" onclick="switchTab('domain')">Domain</div>
                    <div class="tab" onclick="switchTab('password')">Password</div>
                    <div class="tab" onclick="switchTab('reboot')">Auto Reboot</div>
                </div>

                <div id="tab-domain" class="tab-content active">
                    <form onsubmit="handleSettings('domain', event)">
                        <div class="form-group">
                            <label>Server Domain</label>
                            <input type="text" id="set_domain" placeholder="vpn.example.com" required>
                            <small style="color: var(--text-muted)">Changes will update Caddyfile and restart the web server.</small>
                        </div>
                        <button type="submit" class="btn btn-primary">Save Domain</button>
                    </form>
                </div>

                <div id="tab-password" class="tab-content">
                    <form onsubmit="handleSettings('password', event)">
                        <div class="form-group">
                            <label>New Admin Password</label>
                            <input type="password" id="set_password" required>
                        </div>
                        <button type="submit" class="btn btn-primary">Update Password</button>
                    </form>
                </div>

                <div id="tab-reboot" class="tab-content">
                    <form onsubmit="handleSettings('reboot', event)">
                        <div class="form-group">
                            <label>Reboot Time (Server Time)</label>
                            <input type="time" id="set_reboot" required>
                            <small style="color: var(--text-muted)">Schedules a daily cron job to reboot the VPS.</small>
                        </div>
                        <button type="submit" class="btn btn-danger">Set Reboot Schedule</button>
                    </form>
                </div>
            </div>
        </div>
    </main>

    <!-- Create Modal -->
    <div class="modal-overlay" id="createModal">
        <div class="modal">
            <h2 style="margin-bottom: 24px;">Create New User</h2>
            <form onsubmit="createUser(event)">
                <div class="form-group">
                    <label>Username</label>
                    <input type="text" id="in_username" placeholder="e.g. client01" required>
                </div>
                <div class="form-group">
                    <label>Protocol</label>
                    <select id="in_protocol">
                        <option value="vless">VLESS</option>
                        <option value="vmess">VMESS</option>
                        <option value="trojan">TROJAN</option>
                    </select>
                </div>
                <div class="form-group">
                    <label>Duration</label>
                    <select id="in_days">
                        <option value="30">30 Days</option>
                        <option value="90">90 Days</option>
                        <option value="365">1 Year</option>
                    </select>
                </div>
                <div style="display: flex; justify-content: flex-end; gap: 12px;">
                    <button type="button" class="btn" style="background: var(--bg-input); color: white;" onclick="closeModal('createModal')">Cancel</button>
                    <button type="submit" class="btn btn-primary">Create</button>
                </div>
            </form>
        </div>
    </div>

    <div id="toast-container"></div>

    <script>
        const API_USERS = '/api/users';
        const API_STATS = '/api/stats';
        let allUsers = [];
        let statsInterval;

        // Init
        document.addEventListener('DOMContentLoaded', () => {
            loadData();
            startStatsLoop();
        });

        function toggleSidebar() { document.getElementById('sidebar').classList.toggle('open'); }
        function openModal(id) { document.getElementById(id).classList.add('active'); }
        function closeModal(id) { document.getElementById(id).classList.remove('active'); }

        function showSection(name) {
            document.querySelectorAll('.nav-link').forEach(l => l.classList.remove('active'));
            event.currentTarget.classList.add('active'); // assuming click

            document.getElementById('section-dashboard').style.display = name === 'dashboard' ? 'block' : 'none';
            document.getElementById('section-settings').style.display = name === 'settings' ? 'block' : 'none';
        }

        function switchTab(name) {
            document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
            document.querySelectorAll('.tab-content').forEach(c => c.classList.remove('active'));
            event.target.classList.add('active');
            document.getElementById(`tab-${name}`).classList.add('active');
        }

        // --- System Stats ---
        function startStatsLoop() {
            fetchStats();
            statsInterval = setInterval(fetchStats, 2000);
        }

        async function fetchStats() {
            try {
                const res = await fetch(API_STATS);
                if (!res.ok) return;
                const data = await res.json();

                // Info
                document.getElementById('stat-ip').innerText = data.info.ip;
                document.getElementById('stat-isp').innerText = `ISP: ${data.info.isp}`;
                document.getElementById('stat-domain').innerText = data.info.domain;

                // CPU
                document.getElementById('stat-cpu').innerText = data.cpu.usage + '%';
                document.getElementById('prog-cpu').style.width = data.cpu.usage + '%';
                document.getElementById('stat-cores').innerText = `${data.cpu.cores} Cores Detected`;

                // RAM
                const usedMem = ((data.ram.total - data.ram.free) / 1024 / 1024 / 1024).toFixed(1);
                const totalMem = (data.ram.total / 1024 / 1024 / 1024).toFixed(1);
                document.getElementById('stat-ram').innerText = data.ram.usage + '%';
                document.getElementById('prog-ram').style.width = data.ram.usage + '%';
                document.getElementById('stat-mem-det').innerText = `${usedMem}GB / ${totalMem}GB`;

                // Net & Traffic Bar
                if (window.lastNet) {
                    const diffTx = data.net.tx - window.lastNet.tx;
                    const diffRx = data.net.rx - window.lastNet.rx;
                    const speedTx = ((diffTx / 2) / 1024).toFixed(1); // KB/s over 2s interval

                    document.getElementById('traffic-text').innerText = `${speedTx} KB/s`;

                    // Visual Horizontal Bar
                    const maxSpeed = 5000; // 5MB/s scale
                    const width = Math.min(100, (speedTx / maxSpeed) * 100);
                    document.getElementById('traffic-fill').style.width = width + '%';
                }
                window.lastNet = data.net;

            } catch(e) { console.error(e); }
        }

        // --- Settings Actions ---
        async function handleSettings(type, e) {
            e.preventDefault();
            const payload = {};

            if (type === 'domain') payload.domain = document.getElementById('set_domain').value;
            if (type === 'password') payload.password = document.getElementById('set_password').value;
            if (type === 'reboot') payload.time = document.getElementById('set_reboot').value;

            try {
                showToast(`Updating ${type}...`, 'success');
                const res = await fetch(`/api/settings/${type}`, {
                    method: 'POST',
                    body: JSON.stringify(payload)
                });
                const data = await res.json();
                if (data.success) showToast('Settings saved successfully!');
                else showToast('Error: ' + data.error, 'error');
            } catch(e) { showToast('Connection Error', 'error'); }
        }

        // --- Existing User Logic ---
        async function updateSystem() {
            if(!confirm("Update system from GitHub? This will overwrite local changes.")) return;
            try {
                showToast("Updating...", "success");
                const res = await fetch('/api/update', { method: 'POST' });
                const data = await res.json();
                if(data.success) {
                    showToast(data.message);
                    setTimeout(() => location.reload(), 3000);
                } else {
                    showToast("Update failed: " + data.message, "error");
                }
            } catch(e) { showToast("Update error: " + e.message, "error"); }
        }

        async function loadData() {
            try {
                const res = await fetch(API_USERS);
                if (res.status === 401) { window.location.href = '/login.html'; return; }
                allUsers = await res.json();
                renderTable(allUsers);
                document.getElementById('stat-total').innerText = allUsers.length;
            } catch(e) { showToast(e.message, 'error'); }
        }

        function renderTable(users) {
            const tbody = document.getElementById('user-table-body');
            tbody.innerHTML = '';
            if (users.length === 0) { tbody.innerHTML = '<tr><td colspan="5" style="text-align:center; padding: 30px;">No users found.</td></tr>'; return; }

            users.forEach(u => {
                const tr = document.createElement('tr');
                const expiry = new Date(u.expiredDate).toLocaleDateString();
                tr.innerHTML = `
                    <td><b>${u.username}</b></td>
                    <td><span class="badge badge-${u.protocol}">${u.protocol.toUpperCase()}</span></td>
                    <td style="font-family: monospace; color: var(--text-muted);">${u.uuid.substring(0,8)}...</td>
                    <td>${expiry}</td>
                    <td>
                        <button class="btn btn-primary btn-sm" onclick="copyConfig('${u.uuid}', '${u.protocol}', '${u.username}')"><i class="fa-regular fa-copy"></i></button>
                        <button class="btn btn-danger btn-sm" onclick="deleteUser('${u.uuid}')"><i class="fa-solid fa-trash"></i></button>
                    </td>
                `;
                tbody.appendChild(tr);
            });
        }

        function filterUsers() {
            const term = document.getElementById('search').value.toLowerCase();
            const filtered = allUsers.filter(u => u.username.toLowerCase().includes(term));
            renderTable(filtered);
        }

        async function createUser(e) {
            e.preventDefault();
            const username = document.getElementById('in_username').value;
            const protocol = document.getElementById('in_protocol').value;
            const days = document.getElementById('in_days').value;

            const uuid = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
                const r = Math.random() * 16 | 0, v = c == 'x' ? r : (r & 0x3 | 0x8);
                return v.toString(16);
            });

            const date = new Date();
            date.setDate(date.getDate() + parseInt(days));
            const payload = { username, protocol, uuid, days, expiredDate: date.toISOString() };

            try {
                const res = await fetch(API_USERS, { method: 'POST', body: JSON.stringify(payload) });
                if (res.ok) { showToast('User created'); closeModal('createModal'); loadData(); e.target.reset(); }
                else showToast('Failed', 'error');
            } catch(e) { showToast(e.message, 'error'); }
        }

        async function deleteUser(uuid) {
            if(!confirm('Delete user?')) return;
            await fetch(`${API_USERS}/${uuid}`, { method: 'DELETE' });
            showToast('User deleted'); loadData();
        }

        function copyConfig(uuid, protocol, username) {
            const host = window.location.hostname;
            const port = 443;
            let path = `/${protocol}`;
            let link = '';
            if (protocol === 'vless') link = `vless://${uuid}@${host}:${port}?encryption=none&security=tls&type=ws&host=${host}&path=${encodeURIComponent(path)}#${encodeURIComponent(username)}`;
            else if (protocol === 'vmess') {
                const vmessJson = { v: "2", ps: username, add: host, port: port, id: uuid, aid: "0", scy: "auto", net: "ws", type: "none", host: host, path: path, tls: "tls" };
                link = `vmess://${btoa(JSON.stringify(vmessJson))}`;
            } else if (protocol === 'trojan') link = `trojan://${uuid}@${host}:${port}?security=tls&type=ws&host=${host}&path=${encodeURIComponent(path)}#${encodeURIComponent(username)}`;

            navigator.clipboard.writeText(link).then(() => showToast('Copied!'));
        }

        function showToast(msg, type = 'success') {
            const div = document.createElement('div');
            div.className = 'toast';
            div.style.borderLeft = `4px solid ${type === 'success' ? 'var(--success)' : 'var(--danger)'}`;
            div.innerHTML = `<span>${msg}</span>`;
            document.getElementById('toast-container').appendChild(div);
            setTimeout(() => div.remove(), 3000);
        }
    </script>
</body>
</html>
EOF

# Generate Login HTML (reusing previous correct version)
cat <<'EOF' > $INSTALL_DIR/public/login.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>RUTE PREMIUM | Login</title>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;600;700&display=swap" rel="stylesheet">
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Inter', sans-serif;
            background-color: #0f172a;
            color: #f8fafc;
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
            overflow: hidden;
        }

        .ambient {
            position: absolute;
            width: 100%;
            height: 100%;
            z-index: 1;
            background: radial-gradient(circle at 50% 10%, rgba(59, 130, 246, 0.15) 0%, transparent 60%);
        }

        .login-card {
            background-color: #1e293b;
            border: 1px solid #334155;
            padding: 40px;
            border-radius: 16px;
            width: 100%;
            max-width: 400px;
            z-index: 10;
            box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.5);
            animation: floatUp 0.6s cubic-bezier(0.2, 0.8, 0.2, 1);
        }

        @keyframes floatUp {
            from { transform: translateY(20px); opacity: 0; }
            to { transform: translateY(0); opacity: 1; }
        }

        .brand {
            text-align: center;
            margin-bottom: 8px;
            font-size: 1.75rem;
            font-weight: 700;
            color: #3b82f6;
            letter-spacing: -0.5px;
        }

        .subtitle {
            text-align: center;
            color: #94a3b8;
            font-size: 0.9rem;
            margin-bottom: 32px;
        }

        .form-group { margin-bottom: 20px; }
        .form-group label {
            display: block;
            margin-bottom: 8px;
            font-size: 0.85rem;
            color: #94a3b8;
        }
        .form-group input {
            width: 100%;
            padding: 12px;
            border-radius: 8px;
            background-color: #0f172a;
            border: 1px solid #334155;
            color: white;
            outline: none;
            transition: border-color 0.2s;
            font-family: inherit;
        }
        .form-group input:focus { border-color: #3b82f6; }

        .btn {
            width: 100%;
            padding: 12px;
            background-color: #3b82f6;
            color: white;
            border: none;
            border-radius: 8px;
            font-weight: 600;
            cursor: pointer;
            transition: background-color 0.2s;
            margin-top: 10px;
        }
        .btn:hover { background-color: #2563eb; }

        .error-msg {
            color: #ef4444;
            text-align: center;
            margin-bottom: 20px;
            font-size: 0.9rem;
            display: none;
        }

        .contact-buttons {
            display: flex;
            gap: 12px;
            margin-top: 24px;
            padding-top: 24px;
            border-top: 1px solid #334155;
        }

        .contact-btn {
            flex: 1;
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 8px;
            padding: 10px;
            border-radius: 8px;
            text-decoration: none;
            font-size: 0.9rem;
            font-weight: 500;
            transition: opacity 0.2s;
        }
        .contact-btn:hover { opacity: 0.8; }

        .btn-wa { background-color: #25D366; color: white; }
        .btn-tg { background-color: #0088cc; color: white; }

    </style>
</head>
<body>
    <div class="ambient"></div>
    <div class="login-card">
        <div class="brand">RUTE PREMIUM</div>
        <div class="subtitle">Secure Tunneling System</div>

        <div id="error" class="error-msg">Invalid credentials</div>

        <form onsubmit="handleLogin(event)">
            <div class="form-group">
                <label>Username</label>
                <input type="text" id="username" required autocomplete="off">
            </div>
            <div class="form-group">
                <label>Password</label>
                <input type="password" id="password" required>
            </div>
            <button type="submit" class="btn">Sign In</button>
        </form>

        <div class="contact-buttons">
            <a href="https://wa.me/6287733745059" target="_blank" class="contact-btn btn-wa">
                <i class="fa-brands fa-whatsapp"></i> WhatsApp
            </a>
            <a href="https://t.me/otomotif_digital" target="_blank" class="contact-btn btn-tg">
                <i class="fa-brands fa-telegram"></i> Telegram
            </a>
        </div>
    </div>

    <script>
        async function handleLogin(e) {
            e.preventDefault();
            const u = document.getElementById('username').value;
            const p = document.getElementById('password').value;
            const err = document.getElementById('error');

            try {
                const res = await fetch('/api/login', {
                    method: 'POST',
                    body: JSON.stringify({ username: u, password: p })
                });
                const data = await res.json();

                if (data.success) {
                    window.location.href = '/index.html';
                } else {
                    err.style.display = 'block';
                    err.innerText = data.error || 'Login failed';
                }
            } catch {
                err.style.display = 'block';
                err.innerText = 'Connection error';
            }
        }
    </script>
</body>
</html>
EOF

# Init DB
echo "[]" > $INSTALL_DIR/users.json
chmod 600 $INSTALL_DIR/users.json

# Init Config
echo "{\"adminUser\": \"admin\", \"adminPass\": \"$ADMIN_PASS\"}" > $INSTALL_DIR/config.json
chmod 600 $INSTALL_DIR/config.json

# Setup Git for Updates
echo "[3/4] Initializing Git..."
cd $INSTALL_DIR
if [ ! -d ".git" ]; then
    git init
    git remote add origin https://github.com/2026musik-code/rutevles
fi

echo "Installing NPM dependencies..."
npm install

# 3. Configure Caddy
echo "[4/4] Configuring Caddy..."
cat <<EOF > /etc/caddy/Caddyfile
$DOMAIN_NAME {
    reverse_proxy localhost:3000
}
EOF
systemctl reload caddy

# 4. Create Service
echo "Creating Systemd service..."
cat <<EOF > /etc/systemd/system/nautica.service
[Unit]
Description=Nautica Tunneling Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/node server.js
Restart=always
Environment=PORT=3000

[Install]
WantedBy=multi-user.target
EOF

# Start
echo "Starting service..."
systemctl daemon-reload
systemctl enable nautica
systemctl restart nautica

echo "============================================="
echo "   Installation Complete!                    "
echo "============================================="
echo "Dashboard: https://$DOMAIN_NAME/"
echo "Login: admin / $ADMIN_PASS"
echo "Brand: RUTE PREMIUM"
echo "Updates: Enabled (from GitHub)"
echo "============================================="
