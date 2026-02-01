#!/bin/bash

# Setup Script: All-In-One Installer for Nautica Node.js Server
# This script creates all necessary files locally and sets up the environment.

echo "============================================="
echo "   Nautica VLESS/VMess/Trojan Setup Script   "
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

# 1. Install Node.js (v20+) & Caddy
echo "[1/4] Installing dependencies..."
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl nodejs unzip git

curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt-get update
apt-get install -y caddy

# 2. Create Project Files
echo "[2/4] Generating application files..."
INSTALL_DIR="/opt/nautica"
mkdir -p $INSTALL_DIR/public

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
const { webcrypto, createHash } = require('crypto');
const crypto = webcrypto;

const DB_FILE = path.join(__dirname, 'users.json');
const CONFIG_FILE = path.join(__dirname, 'config.json');
const horse = "dHJvamFu";
const flash = "dm1lc3M=";
const neko = "dmxlc3M=";

const PORTS = [443, 80];
const PROTOCOLS = [atob(horse), atob(flash), atob(neko)];
const RELAY_SERVER_UDP = {
  host: "udp-relay.hobihaus.space",
  port: 7300,
};
const PRX_HEALTH_CHECK_API = "https://id1.foolvpn.web.id/api/v1/check";
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

function checkAuth(req) {
    if (!fs.existsSync(CONFIG_FILE)) return true;
    let config = { adminUser: 'admin', adminPass: 'admin' };
    try { config = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8')); } catch {}

    const auth = { login: config.adminUser, password: config.adminPass };
    const b64auth = (req.headers.authorization || '').split(' ')[1] || '';
    const [login, password] = Buffer.from(b64auth, 'base64').toString().split(':');
    return login === auth.login && password === auth.password;
}

const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, `http://${req.headers.host}`);

    if (req.method === 'OPTIONS') {
        res.writeHead(200, CORS_HEADER_OPTIONS);
        res.end();
        return;
    }

    const isPublic = url.pathname.startsWith("/check") || url.pathname.startsWith("/sub");
    if (!isPublic && (url.pathname.startsWith('/api/') || url.pathname === '/' || url.pathname.endsWith('.html'))) {
        if (!checkAuth(req)) {
            res.writeHead(401, { 'WWW-Authenticate': 'Basic realm="Nautica Admin"' });
            res.end('Access denied');
            return;
        }
    }

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
                } catch (e) {
                    res.writeHead(400, CORS_HEADER_OPTIONS);
                    res.end(JSON.stringify({ error: e.message }));
                }
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

    if (url.pathname.startsWith("/check")) {
        const target = url.searchParams.get("target").split(":");
        try {
            const cres = await fetch(`${PRX_HEALTH_CHECK_API}?ip=${target[0]}:${target[1]||443}`);
            const json = await cres.json();
            res.writeHead(200, { ...CORS_HEADER_OPTIONS, "Content-Type": "application/json" });
            res.end(JSON.stringify(json));
        } catch(e) { res.writeHead(500); res.end("{}"); }
        return;
    }

    res.writeHead(404);
    res.end("Not Found");
});

const wss = new WebSocket.Server({ noServer: true });

server.on('upgrade', async (request, socket, head) => {
    const url = new URL(request.url, `http://${request.headers.host}`);
    let prxIP = "";
    const proxyType = url.searchParams.get("proxyType") || "";
    const prxMatch = url.pathname.match(/^\/(.+[:=-]\d+)$/);
    if (prxMatch) prxIP = prxMatch[1];

    wss.handleUpgrade(request, socket, head, (ws) => {
        websocketHandler(ws, request, prxIP, proxyType);
    });
});

async function websocketHandler(webSocket, request, prxIP, proxyType) {
    const wsStream = WebSocket.createWebSocketStream(webSocket);
    const log = (msg) => console.log(`[WS] ${msg}`);

    wsStream.once('data', async (chunk) => {
        wsStream.pause();

        try {
            const protocol = await protocolSniffer(chunk);
            let protocolHeader;
            let uuid = "";
            let authenticated = false;

            log(`Sniffed Protocol: ${protocol}`);

            if (protocol === atob(horse)) { // Trojan
                protocolHeader = readHorseHeader(chunk);
                if (!protocolHeader.hasError && isValidTrojanUser(protocolHeader.passwordHash)) {
                    authenticated = true;
                }
            } else if (protocol === atob(neko)) { // VLESS
                protocolHeader = readNekoHeader(chunk);
                uuid = arrayBufferToHex(chunk.slice(1, 17));
                const formattedUUID = `${uuid.substr(0,8)}-${uuid.substr(8,4)}-${uuid.substr(12,4)}-${uuid.substr(16,4)}-${uuid.substr(20,12)}`;
                log(`VLESS UUID: ${formattedUUID}`);
                if (isValidUser(formattedUUID)) {
                    authenticated = true;
                } else {
                    log(`User not found in DB: ${formattedUUID}`);
                }
            } else if (protocol === atob(flash)) { // VMess
                const users = getUsers().filter(u => u.protocol === 'vmess');
                for (const user of users) {
                    const result = await readStreamHeader(chunk, user.uuid);
                    if (!result.hasError) {
                        protocolHeader = result;
                        authenticated = true;
                        log(`VMess Auth Success: ${user.uuid}`);
                        break;
                    }
                }
            } else {
                log("Unknown Protocol Data: " + chunk.toString('hex').substring(0, 50));
                throw new Error("Unknown Protocol");
            }

            if (!protocolHeader || protocolHeader.hasError) {
                throw new Error(protocolHeader ? protocolHeader.message : "Header Parse Failed");
            }

            if (!authenticated) {
                log("Authentication Failed");
                webSocket.close();
                return;
            }

            let responseHeader = protocolHeader.version;
            if (protocol === atob(flash) && protocolHeader.needsResponse) {
                 responseHeader = await generateStreamResponseHeader(
                    protocolHeader.responseOptions,
                    protocolHeader.encKey,
                    protocolHeader.encIv,
                );
            }

            log(`Connecting to Target: ${protocolHeader.addressRemote}:${protocolHeader.portRemote} (UDP: ${protocolHeader.isUDP})`);

            if (protocolHeader.isUDP) {
                await handleUDPOutbound(
                    protocolHeader.addressRemote,
                    protocolHeader.portRemote,
                    chunk,
                    webSocket,
                    responseHeader,
                    log,
                    RELAY_SERVER_UDP,
                    prxIP,
                    proxyType,
                    wsStream
                );
            } else {
                await handleTCPOutBound(
                    protocolHeader.addressRemote,
                    protocolHeader.portRemote,
                    protocolHeader.rawClientData,
                    webSocket,
                    responseHeader,
                    log,
                    prxIP,
                    proxyType,
                    wsStream
                );
            }

        } catch (err) {
            log(`Error: ${err.message}`);
            webSocket.close();
        }
    });

    wsStream.on('error', (err) => log(`Stream Error: ${err.message}`));
}

async function handleTCPOutBound(addressRemote, portRemote, rawClientData, webSocket, responseHeader, log, prxIP, proxyType, wsStream) {
    async function connectTarget(addr, port) {
        if (prxIP && proxyType) {
            const parts = prxIP.split(/[:=-]/);
            const pAddr = parts[0];
            const pPort = parseInt(parts[1]);
            log(`Proxy connect ${pAddr}:${pPort} -> ${addr}:${port}`);

            const socket = net.connect(pPort, pAddr);
            await new Promise((res, rej) => {
                socket.once('connect', res);
                socket.once('error', rej);
            });

            if (proxyType === 'http') await httpProxyConnect(socket, addr, port);
            else await socks5Connect(socket, addr, port);

            return socket;
        } else {
            if (prxIP && !proxyType) {
                const parts = prxIP.split(/[:=-]/);
                const pAddr = parts[0];
                const pPort = parseInt(parts[1]);
                log(`Relay connect ${pAddr}:${pPort} -> ${addr}:${port}`);
                return net.connect(parseInt(parts[1]), parts[0]);
            }
            log(`Direct connect ${addr}:${port}`);
            return net.connect(port, addr);
        }
    }

    try {
        const tcpSocket = await connectTarget(addressRemote, portRemote);

        if (responseHeader && responseHeader.length > 0) {
            wsStream.write(Buffer.from(responseHeader));
        }

        if (rawClientData && rawClientData.length > 0) {
            tcpSocket.write(rawClientData);
        }

        wsStream.resume();

        wsStream.pipe(tcpSocket);
        tcpSocket.pipe(wsStream);

        tcpSocket.on('error', (e) => log(`TCP Error: ${e.message}`));
        tcpSocket.on('close', () => {
            log("TCP Closed");
            webSocket.close();
        });

    } catch (e) {
        log(`Outbound Connection Failed: ${e.message}`);
        webSocket.close();
    }
}

async function socks5Connect(socket, targetAddress, targetPort) {
    return new Promise((resolve, reject) => {
        const onHandshakeError = (err) => reject(err);
        socket.once('error', onHandshakeError);
        socket.write(new Uint8Array([0x05, 0x01, 0x00]));
        socket.once('data', (data) => {
            if (!data || data[0] !== 0x05 || data[1] !== 0x00) {
                socket.removeListener('error', onHandshakeError);
                return reject(new Error("SOCKS5 greeting failed"));
            }
            const portBuffer = Buffer.alloc(2);
            portBuffer.writeUInt16BE(targetPort);
            let addressType, addressBuffer;
            if (net.isIPv4(targetAddress)) {
                addressType = 0x01;
                addressBuffer = Buffer.from(targetAddress.split('.').map(Number));
            } else {
                addressType = 0x03;
                addressBuffer = Buffer.from([targetAddress.length, ...Buffer.from(targetAddress)]);
            }
            socket.write(Buffer.concat([Buffer.from([0x05, 0x01, 0x00, addressType]), addressBuffer, portBuffer]));
            socket.once('data', (data2) => {
                socket.removeListener('error', onHandshakeError);
                if (!data2 || data2[0] !== 0x05 || data2[1] !== 0x00) return reject(new Error("SOCKS5 connection failed"));
                resolve(socket);
            });
        });
    });
}

async function httpProxyConnect(socket, targetAddress, targetPort) {
    return new Promise((resolve, reject) => {
        const req = `CONNECT ${targetAddress}:${targetPort} HTTP/1.1\r\nHost: ${targetAddress}:${targetPort}\r\n\r\n`;
        socket.write(req);
        socket.once('data', (data) => {
            if (data.toString().includes("200")) resolve(socket);
            else reject(new Error("HTTP Proxy failed"));
        });
        socket.once('error', reject);
    });
}

async function handleUDPOutbound(targetAddress, targetPort, dataChunk, webSocket, responseHeader, log, relay, prxIP, proxyType, wsStream) {
    async function connectTarget() {
        if (prxIP && proxyType) {
            const parts = prxIP.split(/[:=-]/);
            const socket = net.connect(parseInt(parts[1]), parts[0]);
            await new Promise((res, rej) => { socket.once('connect', res); socket.once('error', rej); });
            if (proxyType === 'http') await httpProxyConnect(socket, relay.host, relay.port);
            else await socks5Connect(socket, relay.host, relay.port);
            return socket;
        } else return net.connect(relay.port, relay.host);
    }

    try {
        const socket = await connectTarget();
        if (responseHeader) wsStream.write(Buffer.from(responseHeader));

        const header = `udp:${targetAddress}:${targetPort}`;
        const payload = Buffer.concat([Buffer.from(header), Buffer.from([0x7c]), Buffer.from(dataChunk)]);
        socket.write(payload);

        wsStream.resume();
        wsStream.pipe(socket);
        socket.pipe(wsStream);
        socket.on('error', (e) => log(`UDP Error: ${e.message}`));
    } catch(e) { webSocket.close(); }
}

async function protocolSniffer(buffer) {
    if (buffer.length >= 18 && buffer[0] === 0) return atob(neko);
    if (buffer.length >= 62) {
        const d = buffer.slice(56, 60);
        if (d[0]===0x0d && d[1]===0x0a) return atob(horse);
    }
    if (buffer.length >= 42) return atob(flash);
    return "";
}

function isValidTrojanUser(hash) {
    const users = getUsers().filter(u => u.protocol === 'trojan');
    for (const u of users) {
        if (createHash('sha224').update(u.uuid).digest('hex') === hash) return true;
    }
    return false;
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
    else if (atype === 4) { off+=16; addr="ipv6"; } // Simplify
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
    for (const p of path) {
        result = await hmac(result, p);
    }
    return result;
}

function arrayBufferToHex(buf) { return Buffer.from(buf).toString('hex'); }

server.listen(PORT, () => { console.log(`Server running on ${PORT}`); });
EOF

# Generate HTML (Content from previous step)
# NOTE: Use simple cat, the HTML content has no variable expansion conflict usually but better safe.
# We will use EOF with quotes to be safe.
cat <<'EOF' > $INSTALL_DIR/public/index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Nautica Admin | VPS Manager</title>
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

        .stat-label { color: var(--text-muted); font-size: 0.9rem; margin-bottom: 8px; }
        .stat-value { font-size: 2rem; font-weight: 700; color: white; }

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

        /* Mobile */
        .mobile-toggle { display: none; color: white; font-size: 1.5rem; cursor: pointer; }

        @media (max-width: 768px) {
            .sidebar { transform: translateX(-100%); }
            .sidebar.open { transform: translateX(0); }
            .main { margin-left: 0; padding: 20px; }
            .mobile-toggle { display: block; margin-right: 16px; }
            .table-container { overflow-x: auto; }
            .header-actions { display: none; } /* Hide profile on mobile to save space */
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
            <i class="fa-solid fa-bolt"></i> Nautica
        </div>
        <div class="nav-links">
            <a href="#" class="nav-link active"><i class="fa-solid fa-grid-2"></i> Dashboard</a>
            <a href="#" class="nav-link"><i class="fa-solid fa-users"></i> Users</a>
            <a href="#" class="nav-link"><i class="fa-solid fa-network-wired"></i> Proxies</a>
            <div style="margin-top: auto; padding-top: 20px; border-top: 1px solid var(--border);">
                <a href="#" class="nav-link" onclick="location.reload()"><i class="fa-solid fa-rotate"></i> Refresh</a>
            </div>
        </div>
    </nav>

    <main class="main">
        <div class="header">
            <div style="display:flex; align-items:center;">
                <div class="mobile-toggle" onclick="toggleSidebar()"><i class="fa-solid fa-bars"></i></div>
                <div class="title">
                    <h1>Dashboard</h1>
                    <p>Manage your VLESS/VMess/Trojan Accounts</p>
                </div>
            </div>
            <div class="header-actions">
                <button class="btn btn-primary" onclick="openModal()">
                    <i class="fa-solid fa-plus"></i> New User
                </button>
            </div>
        </div>

        <div class="stats-grid">
            <div class="stat-card">
                <div class="stat-label">Total Users</div>
                <div class="stat-value" id="stat-total">0</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">Active Protocols</div>
                <div class="stat-value">3</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">System Status</div>
                <div class="stat-value" style="color: var(--success); font-size: 1.5rem;">
                    <i class="fa-solid fa-circle-check"></i> Online
                </div>
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
                        <th>Proxy Route</th>
                        <th>Expiry</th>
                        <th>Actions</th>
                    </tr>
                </thead>
                <tbody id="user-table-body">
                    <!-- Data Injected Here -->
                </tbody>
            </table>
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
                    <label>Proxy Route (Optional)</label>
                    <div style="display: flex; gap: 10px;">
                        <input type="text" id="in_proxy" placeholder="1.2.3.4:1080">
                        <select id="in_proxy_type" style="width: 100px;">
                            <option value="socks5">SOCKS5</option>
                            <option value="http">HTTP</option>
                        </select>
                    </div>
                    <small style="color: var(--text-muted)">Route this user's traffic through an upstream proxy.</small>
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
                    <button type="button" class="btn" style="background: var(--bg-input); color: white;" onclick="closeModal()">Cancel</button>
                    <button type="submit" class="btn btn-primary">Create</button>
                </div>
            </form>
        </div>
    </div>

    <div id="toast-container"></div>

    <script>
        const API_URL = '/api/users';
        let allUsers = [];

        // Init
        document.addEventListener('DOMContentLoaded', loadData);

        function toggleSidebar() {
            document.getElementById('sidebar').classList.toggle('open');
        }

        function openModal() {
            document.getElementById('createModal').classList.add('active');
        }
        function closeModal() {
            document.getElementById('createModal').classList.remove('active');
        }

        async function loadData() {
            try {
                const res = await fetch(API_URL);
                if (res.status === 401) return; // Auth handled by browser
                allUsers = await res.json();
                renderTable(allUsers);
                document.getElementById('stat-total').innerText = allUsers.length;
            } catch(e) {
                showToast(e.message, 'error');
            }
        }

        function renderTable(users) {
            const tbody = document.getElementById('user-table-body');
            tbody.innerHTML = '';

            if (users.length === 0) {
                tbody.innerHTML = '<tr><td colspan="6" style="text-align:center; padding: 30px;">No users found.</td></tr>';
                return;
            }

            users.forEach(u => {
                const tr = document.createElement('tr');
                const expiry = new Date(u.expiredDate).toLocaleDateString();
                const proxyDisplay = u.proxyRoute ? `<span style="font-family:monospace; font-size:0.8rem; background:var(--bg-input); padding:2px 6px; border-radius:4px;">${u.proxyRoute}</span>` : '<span style="color:var(--text-muted)">Direct</span>';

                tr.innerHTML = `
                    <td><b>${u.username}</b></td>
                    <td><span class="badge badge-${u.protocol}">${u.protocol.toUpperCase()}</span></td>
                    <td style="font-family: monospace; color: var(--text-muted);">${u.uuid.substring(0,8)}...</td>
                    <td>${proxyDisplay}</td>
                    <td>${expiry}</td>
                    <td>
                        <button class="btn btn-primary btn-sm" onclick="copyConfig('${u.uuid}', '${u.protocol}', '${u.username}', '${u.proxyRoute}', '${u.proxyType}')">
                            <i class="fa-regular fa-copy"></i>
                        </button>
                        <button class="btn btn-danger btn-sm" onclick="deleteUser('${u.uuid}')">
                            <i class="fa-solid fa-trash"></i>
                        </button>
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
            const proxyRoute = document.getElementById('in_proxy').value;
            const proxyType = document.getElementById('in_proxy_type').value;
            const days = document.getElementById('in_days').value;

            // Generate UUID
            const uuid = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
                const r = Math.random() * 16 | 0, v = c == 'x' ? r : (r & 0x3 | 0x8);
                return v.toString(16);
            });

            const date = new Date();
            date.setDate(date.getDate() + parseInt(days));

            const payload = { username, protocol, uuid, proxyRoute, proxyType, days, expiredDate: date.toISOString() };

            try {
                const res = await fetch(API_URL, {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify(payload)
                });
                if (res.ok) {
                    showToast('User created successfully');
                    closeModal();
                    loadData();
                    e.target.reset();
                } else {
                    showToast('Failed to create user', 'error');
                }
            } catch(e) { showToast(e.message, 'error'); }
        }

        async function deleteUser(uuid) {
            if(!confirm('Are you sure you want to delete this user?')) return;
            try {
                const res = await fetch(`${API_URL}/${uuid}`, { method: 'DELETE' });
                if (res.ok) {
                    showToast('User deleted');
                    loadData();
                }
            } catch(e) { showToast(e.message, 'error'); }
        }

        function copyConfig(uuid, protocol, username, proxyRoute, proxyType) {
            const host = window.location.hostname;
            const port = 443;
            let path = '/';
            if (proxyRoute && proxyRoute.trim()) {
                path = `/${proxyRoute}?proxyType=${proxyType}`;
            } else {
                path = '/';
            }

            let link = '';
            if (protocol === 'vless') {
                link = `vless://${uuid}@${host}:${port}?encryption=none&security=tls&type=ws&host=${host}&path=${encodeURIComponent(path)}#${encodeURIComponent(username)}`;
            } else if (protocol === 'vmess') {
                const vmessJson = {
                    v: "2", ps: username, add: host, port: port, id: uuid, aid: "0", scy: "auto", net: "ws", type: "none", host: host, path: path, tls: "tls"
                };
                link = `vmess://${btoa(JSON.stringify(vmessJson))}`;
            } else if (protocol === 'trojan') {
                link = `trojan://${uuid}@${host}:${port}?security=tls&type=ws&host=${host}&path=${encodeURIComponent(path)}#${encodeURIComponent(username)}`;
            }

            navigator.clipboard.writeText(link).then(() => showToast('Config copied to clipboard'));
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

# Init DB
echo "[]" > $INSTALL_DIR/users.json
chmod 600 $INSTALL_DIR/users.json

# Init Config
echo "{\"adminUser\": \"admin\", \"adminPass\": \"$ADMIN_PASS\"}" > $INSTALL_DIR/config.json
chmod 600 $INSTALL_DIR/config.json

cd $INSTALL_DIR
echo "Installing NPM dependencies..."
npm install

# 3. Configure Caddy
echo "[3/4] Configuring Caddy..."
cat <<EOF > /etc/caddy/Caddyfile
$DOMAIN_NAME {
    reverse_proxy localhost:3000
}
EOF
systemctl reload caddy

# 4. Create Service
echo "[4/4] Creating Systemd service..."
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
echo "Proxy Protocol: Enabled"
echo "============================================="
