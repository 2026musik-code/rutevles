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

# Generate server.js (Content from previous step)
# NOTE: Using cat <<'EOF' with quotes to prevent variable expansion
cat <<'EOF' > $INSTALL_DIR/server.js
const http = require('http');
const net = require('net');
const WebSocket = require('ws');
const fs = require('fs');
const path = require('path');
const { webcrypto, createHash } = require('crypto');
const crypto = webcrypto;

// Constants
const DB_FILE = path.join(__dirname, 'users.json');
const CONFIG_FILE = path.join(__dirname, 'config.json');
const horse = "dHJvamFu";
const flash = "dm1lc3M=";
const neko = "dmxlc3M=";

const PORTS = [443, 80];
const PROTOCOLS = [atob(horse), atob(flash), atob(neko)];
const DNS_SERVER_ADDRESS = "8.8.8.8";
const DNS_SERVER_PORT = 53;
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

// Encrypted Stream Constants
const SALT_A1 = atob("Vk1lc3MgSGVhZGVyIEFFQUQgS2V5X0xlbmd0aA==");
const SALT_A2 = atob("Vk1lc3MgSGVhZGVyIEFFQUQgTm9uY2VfTGVuZ3Ro");
const SALT_A3 = atob("Vk1lc3MgSGVhZGVyIEFFQUQgS2V5");
const SALT_A4 = atob("Vk1lc3MgSGVhZGVyIEFFQUQgTm9uY2U=");
const SALT_B1 = atob("QUVBRCBSZXNwIEhlYWRlciBMZW4gS2V5");
const SALT_B2 = atob("QUVBRCBSZXNwIEhlYWRlciBMZW4gSVY=");
const SALT_B3 = atob("QUVBRCBSZXNwIEhlYWRlciBLZXk=");
const SALT_B4 = atob("QUVBRCBSZXNwIEhlYWRlciBJVg==");

const PORT = process.env.PORT || 80;

// -- Helpers --
function atob(str) { return Buffer.from(str, 'base64').toString('binary'); }
function btoa(str) { return Buffer.from(str, 'binary').toString('base64'); }

// -- Database Helpers --
function getUsers() {
    if (!fs.existsSync(DB_FILE)) return [];
    try {
        return JSON.parse(fs.readFileSync(DB_FILE, 'utf8'));
    } catch { return []; }
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

    if (login && password && login === auth.login && password === auth.password) {
        return true;
    }
    return false;
}

async function checkPrxHealth(ip, port) {
    try {
        const res = await fetch(`${PRX_HEALTH_CHECK_API}?ip=${ip}:${port}`);
        return await res.json();
    } catch { return { error: "failed" }; }
}

const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, `http://${req.headers.host}`);

    // CORS
    if (req.method === 'OPTIONS') {
        res.writeHead(200, CORS_HEADER_OPTIONS);
        res.end();
        return;
    }

    // --- PROTECTED ROUTES ---
    // Protect EVERYTHING by default, except specific public endpoints
    const isPublic =
        url.pathname.startsWith("/check") ||
        url.pathname.startsWith("/sub");

    if (!isPublic) {
        if (!checkAuth(req)) {
            res.writeHead(401, { 'WWW-Authenticate': 'Basic realm="Nautica Admin"' });
            res.end('Access denied');
            return;
        }
    }

    // --- API Endpoints ---
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
                    if (!data.username || !data.protocol || !data.uuid) {
                        throw new Error("Missing fields");
                    }
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

    // --- Static Files (SECURE LFI FIX) ---
    // Normalize path and prevent directory traversal
    let requestedPath = url.pathname === '/' ? '/index.html' : url.pathname;
    // Remove query string
    requestedPath = requestedPath.split('?')[0];

    // Normalize logic
    const publicDir = path.join(__dirname, 'public');
    const safePath = path.normalize(path.join(publicDir, requestedPath));

    // Check if path is actually inside publicDir
    if (!safePath.startsWith(publicDir)) {
        res.writeHead(403);
        res.end("Forbidden");
        return;
    }

    if (fs.existsSync(safePath) && fs.statSync(safePath).isFile()) {
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
        } catch(e) {
            res.writeHead(500); res.end("{}");
        }
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

    wsStream.once('data', async (chunk) => {
        wsStream.pause();

        try {
            const protocol = await protocolSniffer(chunk);
            let protocolHeader;
            let uuid = "";
            let authenticated = false;

            if (protocol === atob(horse)) { // Trojan
                const result = await readHorseHeader(chunk);
                protocolHeader = result;
                if (!result.hasError) {
                    if (isValidTrojanUser(result.passwordHash)) {
                        authenticated = true;
                    }
                }
            } else if (protocol === atob(neko)) { // VLESS
                protocolHeader = readNekoHeader(chunk);
                uuid = arrayBufferToHex(chunk.slice(1, 17));
                const formattedUUID = `${uuid.substr(0,8)}-${uuid.substr(8,4)}-${uuid.substr(12,4)}-${uuid.substr(16,4)}-${uuid.substr(20,12)}`;
                if (isValidUser(formattedUUID)) {
                    authenticated = true;
                }
            } else if (protocol === atob(flash)) { // VMess
                const users = getUsers().filter(u => u.protocol === 'vmess');
                for (const user of users) {
                    const result = await readStreamHeader(chunk, user.uuid);
                    if (!result.hasError) {
                        protocolHeader = result;
                        authenticated = true;
                        break;
                    }
                }

                if (!authenticated) {
                    protocolHeader = { hasError: true, message: "Authentication failed" };
                }
            } else {
                throw new Error("Unknown Protocol");
            }

            if (protocolHeader.hasError) {
                throw new Error(protocolHeader.message);
            }

            if (!authenticated) {
                console.log("Authentication Failed");
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

            if (protocolHeader.isUDP) {
                if (protocolHeader.portRemote === 53) {
                    await handleUDPOutbound(
                        DNS_SERVER_ADDRESS,
                        DNS_SERVER_PORT,
                        chunk,
                        webSocket,
                        responseHeader,
                        log,
                        RELAY_SERVER_UDP,
                        prxIP,
                        proxyType,
                        wsStream
                    );
                    return;
                }

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
                return;
            }

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

        } catch (err) {
            console.log("Handler Error", err.message);
            webSocket.close();
        }
    });

    wsStream.on('error', (err) => console.log("WS Stream Error", err.message));
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

            let addressType;
            let addressBuffer;

            if (net.isIPv4(targetAddress)) {
                addressType = 0x01;
                addressBuffer = Buffer.from(targetAddress.split('.').map(Number));
            } else {
                addressType = 0x03;
                addressBuffer = Buffer.from([targetAddress.length, ...Buffer.from(targetAddress)]);
            }

            const request = Buffer.concat([
                Buffer.from([0x05, 0x01, 0x00, addressType]),
                addressBuffer,
                portBuffer
            ]);

            socket.write(request);

            socket.once('data', (data2) => {
                socket.removeListener('error', onHandshakeError);
                if (!data2 || data2[0] !== 0x05 || data2[1] !== 0x00) {
                    return reject(new Error("SOCKS5 connection failed"));
                }
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
            const response = data.toString();
            if (response.includes("200 Connection Established") || response.includes("200 OK")) {
                resolve(socket);
            } else {
                reject(new Error("HTTP Proxy connection failed: " + response.split('\r\n')[0]));
            }
        });
        socket.once('error', (err) => reject(err));
    });
}

async function handleTCPOutBound(addressRemote, portRemote, rawClientData, webSocket, responseHeader, log, prxIP, proxyType, wsStream) {
    async function connectTarget(addr, port) {
        if (prxIP && proxyType) {
            const parts = prxIP.split(/[:=-]/);
            const pAddr = parts[0];
            const pPort = parseInt(parts[1]);
            log(`Proxy connect ${pAddr}:${pPort} (${proxyType}) -> ${addr}:${port}`);

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
                return net.connect(parseInt(parts[1]), parts[0]);
            }
            return net.connect(port, addr);
        }
    }

    try {
        const tcpSocket = await connectTarget(addressRemote, portRemote);

        if (rawClientData && rawClientData.length > 0) {
            tcpSocket.write(rawClientData);
        }

        if (responseHeader && responseHeader.length > 0) {
            wsStream.write(Buffer.from(responseHeader));
        }

        wsStream.resume();
        wsStream.pipe(tcpSocket);
        tcpSocket.pipe(wsStream);

        tcpSocket.on('error', (e) => {});
        tcpSocket.on('close', () => webSocket.close());

    } catch (e) {
        webSocket.close();
    }
}

async function handleUDPOutbound(targetAddress, targetPort, dataChunk, webSocket, responseHeader, log, relay, prxIP, proxyType, wsStream) {
    async function connectTarget() {
        if (prxIP && proxyType) {
            const parts = prxIP.split(/[:=-]/);
            const pAddr = parts[0];
            const pPort = parseInt(parts[1]);

            const socket = net.connect(pPort, pAddr);
            await new Promise((res, rej) => {
                socket.once('connect', res);
                socket.once('error', rej);
            });

            if (proxyType === 'http') await httpProxyConnect(socket, relay.host, relay.port);
            else await socks5Connect(socket, relay.host, relay.port);

            return socket;
        } else {
            return net.connect(relay.port, relay.host);
        }
    }

    try {
        const socket = await connectTarget();

        const header = `udp:${targetAddress}:${targetPort}`;
        const headerBuffer = Buffer.from(header);
        const separator = Buffer.from([0x7c]);
        const payload = Buffer.concat([headerBuffer, separator, Buffer.from(dataChunk)]);
        socket.write(payload);

        if (responseHeader) {
            wsStream.write(Buffer.from(responseHeader));
        }

        wsStream.resume();
        wsStream.pipe(socket);
        socket.pipe(wsStream);

        socket.on('error', (e) => {});
        socket.on('close', () => {});

    } catch(e) {
        webSocket.close();
    }
}

async function protocolSniffer(buffer) {
    if (buffer.length >= 62) {
        const horseDelimiter = buffer.slice(56, 60);
        if (horseDelimiter[0] === 0x0d && horseDelimiter[1] === 0x0a) {
             if (horseDelimiter[2] === 0x01 || horseDelimiter[2] === 0x03 || horseDelimiter[2] === 0x7f) {
                 if (horseDelimiter[3] === 0x01 || horseDelimiter[3] === 0x03 || horseDelimiter[3] === 0x04) return atob(horse);
             }
        }
    }
    if (buffer.length >= 18) {
        const version = buffer[0];
        if (version === 0) return atob(neko);
    }
    if (buffer.length >= 42) {
        const first = buffer[0];
        if (first === 1 || first === 3 || first === 4) return "ss";
        return atob(flash);
    }
    return "";
}

function isValidTrojanUser(hashBuffer) {
    const receivedHash = hashBuffer.toString();
    const users = getUsers().filter(u => u.protocol === 'trojan');
    for (const user of users) {
        const userHash = createHash('sha224').update(user.uuid).digest('hex');
        if (userHash === receivedHash) {
            const expDate = new Date(user.expiredDate);
            if (new Date() > expDate) return false;
            return true;
        }
    }
    return false;
}

function readHorseHeader(buffer) {
    const dataBuffer = buffer.slice(58);
    if (dataBuffer.length < 6) return { hasError: true, message: "invalid request data" };

    const cmd = dataBuffer[0];
    const isUDP = cmd === 3;
    const addressType = dataBuffer[1];
    let offset = 2;
    let addressValue = "";

    if (addressType === 1) {
        addressValue = dataBuffer.slice(offset, offset+4).join('.');
        offset += 4;
    } else if (addressType === 3) {
        const len = dataBuffer[offset];
        offset++;
        addressValue = dataBuffer.slice(offset, offset+len).toString();
        offset += len;
    } else if (addressType === 4) {
        const ipv6 = [];
        for (let i = 0; i < 8; i++) {
            ipv6.push(dataBuffer.readUInt16BE(offset + i * 2).toString(16));
        }
        addressValue = ipv6.join(":");
        offset += 16;
    } else {
        return { hasError: true, message: `invalid addressType is ${addressType}` };
    }

    const portRemote = dataBuffer.readUInt16BE(offset);
    return {
        hasError: false,
        addressRemote: addressValue,
        portRemote: portRemote,
        isUDP,
        rawClientData: dataBuffer.slice(offset+2),
        version: null,
        passwordHash: buffer.slice(0, 56).toString()
    };
}

function readNekoHeader(buffer) {
    const version = buffer[0];
    const optLength = buffer[17];
    const cmd = buffer[18 + optLength];
    const isUDP = cmd === 2;
    const portIndex = 18 + optLength + 1;
    const portRemote = buffer.readUInt16BE(portIndex);

    let addressIndex = portIndex + 2;
    const addressType = buffer[addressIndex];
    let addressValue = "";
    let offset = addressIndex + 1;

    if (addressType === 1) {
        addressValue = buffer.slice(offset, offset+4).join('.');
        offset += 4;
    } else if (addressType === 2) {
        const len = buffer[offset];
        offset++;
        addressValue = buffer.slice(offset, offset+len).toString();
        offset += len;
    } else if (addressType === 3) {
        const ipv6 = [];
        for (let i = 0; i < 8; i++) {
            ipv6.push(buffer.readUInt16BE(offset + i * 2).toString(16));
        }
        addressValue = ipv6.join(":");
        offset += 16;
    }

    return {
        hasError: false,
        addressRemote: addressValue,
        portRemote,
        isUDP,
        rawClientData: buffer.slice(offset),
        version: new Uint8Array([version, 0]),
    };
}

function readSsHeader(ssBuffer) {
  const view = ssBuffer;
  const addressType = view[0];
  let addressLength = 0;
  let addressValueIndex = 1;
  let addressValue = "";

  switch (addressType) {
    case 1:
      addressLength = 4;
      addressValue = view.slice(addressValueIndex, addressValueIndex + addressLength).join(".");
      break;
    case 3:
      addressLength = view[addressValueIndex];
      addressValueIndex += 1;
      addressValue = view.slice(addressValueIndex, addressValueIndex + addressLength).toString();
      break;
    case 4:
      addressLength = 16;
      const ipv6 = [];
      for (let i = 0; i < 8; i++) {
        ipv6.push(view.readUInt16BE(addressValueIndex + i * 2).toString(16));
      }
      addressValue = ipv6.join(":");
      break;
    default:
      return { hasError: true, message: `Invalid addressType for SS: ${addressType}` };
  }

  const portIndex = addressValueIndex + addressLength;
  const portRemote = view.readUInt16BE(portIndex);
  return {
    hasError: false,
    addressRemote: addressValue,
    addressType: addressType,
    portRemote: portRemote,
    rawDataIndex: portIndex + 2,
    rawClientData: ssBuffer.slice(portIndex + 2),
    version: null,
    isUDP: portRemote == 53,
  };
}

async function readStreamHeader(buffer, userUUID) {
    try {
        const uuidBytes = new Uint8Array(
          userUUID.replace(/-/g, "").match(/.{1,2}/g).map((byte) => parseInt(byte, 16))
        );

        const authKey = await md5(
          uuidBytes,
          new TextEncoder().encode(atob("YzQ4NjE5ZmUtOGYwMi00OWUwLWI5ZTktZWRmNzYzZTE3ZTIx")),
        );

        const authId = buffer.slice(0, 16);
        const encryptedLength = buffer.slice(16, 34);
        const nonce = buffer.slice(34, 42);

        const lengthKey = (await kdf(authKey, [SALT_A1, authId, nonce])).slice(0, 16);
        const lengthIv = (await kdf(authKey, [SALT_A2, authId, nonce])).slice(0, 12);

        const lengthBytes = await aesGcmDecrypt(lengthKey, lengthIv, encryptedLength, authId);
        const headerLength = (lengthBytes[0] << 8) | lengthBytes[1];

        const encryptedHeader = buffer.slice(42, 42 + headerLength + 16);

        const payloadKey = (await kdf(authKey, [SALT_A3, authId, nonce])).slice(0, 16);
        const payloadIv = (await kdf(authKey, [SALT_A4, authId, nonce])).slice(0, 12);

        const headerPayload = await aesGcmDecrypt(payloadKey, payloadIv, encryptedHeader, authId);

        const view = Buffer.from(headerPayload);
        let offset = 0;

        const version = view[offset]; offset++;
        if (version !== 1) return { hasError: true, message: `Invalid protocol version: ${version}` };

        const encIv = view.slice(offset, offset+16); offset+=16;
        const encKey = view.slice(offset, offset+16); offset+=16;
        const options = view.slice(offset, offset+4); offset+=4;
        const cmd = view[offset]; offset++;
        const isUDP = cmd !== 1;
        const portRemote = view.readUInt16BE(offset); offset+=2;
        const addressType = view[offset]; offset++;

        let addressRemote = "";
        if (addressType === 1) {
            addressRemote = view.slice(offset, offset+4).join('.'); offset+=4;
        } else if (addressType === 2 || addressType === 3) {
            const len = view[offset]; offset++;
            addressRemote = view.slice(offset, offset+len).toString(); offset+=len;
        } else if (addressType === 4) {
            const ipv6 = [];
            for(let i=0; i<8; i++) ipv6.push(view.readUInt16BE(offset+i*2).toString(16));
            addressRemote = ipv6.join(":"); offset+=16;
        }

        const rawDataIndex = 42 + headerLength + 16;

        return {
            hasError: false,
            addressRemote,
            portRemote,
            rawDataIndex,
            rawClientData: buffer.slice(rawDataIndex),
            version: new Uint8Array([options[0], 0]),
            isUDP,
            needsResponse: true,
            responseOptions: options,
            encKey,
            encIv
        };

    } catch (e) {
        return { hasError: true, message: e.message };
    }
}

async function generateStreamResponseHeader(responseOptions, encKey, encIv) {
  try {
    const key = (await sha256(encKey)).slice(0, 16);
    const iv = (await sha256(encIv)).slice(0, 16);

    const lengthKey = (await kdf(key, [SALT_B1])).slice(0, 16);
    const lengthIv = (await kdf(iv, [SALT_B2])).slice(0, 12);

    const lengthData = new Uint8Array(2);
    lengthData[0] = 0;
    lengthData[1] = 4;

    const encryptedLength = await aesGcmEncrypt(lengthKey, lengthIv, lengthData, new Uint8Array(0));

    const headerPayload = new Uint8Array([
      responseOptions[0],
      0x00,
      0x00,
      0x00,
    ]);

    const payloadKey = (await kdf(key, [SALT_B3])).slice(0, 16);
    const payloadIv = (await kdf(iv, [SALT_B4])).slice(0, 12);

    const encryptedPayload = await aesGcmEncrypt(payloadKey, payloadIv, headerPayload, new Uint8Array(0));

    const response = new Uint8Array(encryptedLength.length + encryptedPayload.length);
    response.set(encryptedLength, 0);
    response.set(encryptedPayload, encryptedLength.length);

    return response;
  } catch (e) {
    return new Uint8Array(0);
  }
}

async function md5(...inputs) {
  const combined = Buffer.concat(inputs.map(i => Buffer.from(i)));
  return new Uint8Array(createHash('md5').update(combined).digest());
}

async function sha256(input) {
  const hashBuffer = await crypto.subtle.digest("SHA-256", input);
  return new Uint8Array(hashBuffer);
}

async function kdf(key, path) {
  async function hmacSha256(key, data) {
    const hmacKey = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    const signature = await crypto.subtle.sign("HMAC", hmacKey, data);
    return new Uint8Array(signature);
  }

  async function recursiveHash(keyBytes, innerHashFn) {
    return async (data) => {
      const ipad = new Uint8Array(64);
      const opad = new Uint8Array(64);

      ipad.set(keyBytes.slice(0, Math.min(64, keyBytes.length)));
      opad.set(keyBytes.slice(0, Math.min(64, keyBytes.length)));

      for (let i = 0; i < 64; i++) {
        ipad[i] ^= 0x36;
        opad[i] ^= 0x5c;
      }

      const innerData = new Uint8Array(ipad.length + data.length);
      innerData.set(ipad);
      innerData.set(data, ipad.length);
      const innerResult = await innerHashFn(innerData);

      const outerData = new Uint8Array(opad.length + innerResult.length);
      outerData.set(opad);
      outerData.set(innerResult, opad.length);
      return await innerHashFn(outerData);
    };
  }

  const sha256Hash = async (data) => {
    return new Uint8Array(await crypto.subtle.digest("SHA-256", data));
  };

  let currentHashFn = await recursiveHash(new TextEncoder().encode("VMess AEAD KDF"), sha256Hash);

  for (const salt of path) {
    const saltBytes = typeof salt === "string" ? new TextEncoder().encode(salt) : new Uint8Array(salt);
    currentHashFn = await recursiveHash(saltBytes, currentHashFn);
  }

  return await currentHashFn(key);
}

async function aesGcmDecrypt(key, nonce, data, aad) {
  const cryptoKey = await crypto.subtle.importKey("raw", key, { name: "AES-GCM" }, false, ["decrypt"]);

  try {
    const decrypted = await crypto.subtle.decrypt({ name: "AES-GCM", iv: nonce, additionalData: aad }, cryptoKey, data);
    return new Uint8Array(decrypted);
  } catch (e) {
    throw new Error("AEAD decryption failed: " + e.message);
  }
}

async function aesGcmEncrypt(key, nonce, data, aad) {
  const cryptoKey = await crypto.subtle.importKey("raw", key, { name: "AES-GCM" }, false, ["encrypt"]);

  const encrypted = await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, additionalData: aad }, cryptoKey, data);
  return new Uint8Array(encrypted);
}

function arrayBufferToHex(buffer) {
  return [...new Uint8Array(buffer)].map((x) => x.toString(16).padStart(2, "0")).join("");
}

function shuffleArray(array) {
    for (let i = array.length - 1; i > 0; i--) {
        const j = Math.floor(Math.random() * (i + 1));
        [array[i], array[j]] = [array[j], array[i]];
    }
}

function getFlagEmoji(isoCode) {
  if(!isoCode) return "";
  const codePoints = isoCode
    .toUpperCase()
    .split("")
    .map((char) => 127397 + char.charCodeAt(0));
  return String.fromCodePoint(...codePoints);
}

server.listen(PORT, () => {
    console.log(`Server listening on port ${PORT}`);
});
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
                path = `/${host}:80`;
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
