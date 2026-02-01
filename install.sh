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

const DB_FILE = path.join(__dirname, 'users.json');
const CONFIG_FILE = path.join(__dirname, 'config.json');
const horse = "dHJvamFu";
const flash = "dm1lc3M=";
const neko = "dmxlc3M=";

const PORTS = [443, 80];
const PROTOCOLS = [atob(horse), atob(flash), atob(neko)];
const SUB_PAGE_URL = "https://foolvpn.web.id/nautica";
const KV_PRX_URL = "https://raw.githubusercontent.com/FoolVPN-ID/Nautica/refs/heads/main/kvProxyList.json";
const PRX_BANK_URL = "https://raw.githubusercontent.com/FoolVPN-ID/Nautica/refs/heads/main/proxyList.txt";
const DNS_SERVER_ADDRESS = "8.8.8.8";
const DNS_SERVER_PORT = 53;
const RELAY_SERVER_UDP = {
  host: "udp-relay.hobihaus.space",
  port: 7300,
};
const PRX_HEALTH_CHECK_API = "https://id1.foolvpn.web.id/api/v1/check";
const CONVERTER_URL = "https://api.foolvpn.web.id/convert";
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

async function getKVPrxList(kvPrxUrl = KV_PRX_URL) {
  if (!kvPrxUrl) throw new Error("No URL Provided!");
  try {
      const kvPrx = await fetch(kvPrxUrl);
      if (kvPrx.status == 200) return await kvPrx.json();
  } catch (e) { console.error(e); }
  return {};
}

async function getPrxList(prxBankUrl = PRX_BANK_URL) {
  if (!prxBankUrl) throw new Error("No URL Provided!");
  try {
      const prxBank = await fetch(prxBankUrl);
      if (prxBank.status == 200) {
        const text = (await prxBank.text()) || "";
        const prxString = text.split("\n").filter(Boolean);
        cachedPrxList = prxString
          .map((entry) => {
            const [prxIP, prxPort, country, org] = entry.split(",");
            return {
              prxIP: prxIP || "Unknown",
              prxPort: prxPort || "Unknown",
              country: country || "Unknown",
              org: org || "Unknown Org",
            };
          })
          .filter(Boolean);
      }
  } catch(e) { console.error(e); }
  return cachedPrxList;
}

const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, `http://${req.headers.host}`);

    if (req.method === 'OPTIONS') {
        res.writeHead(200, CORS_HEADER_OPTIONS);
        res.end();
        return;
    }

    const isProtected = url.pathname.startsWith('/api/users') || url.pathname === '/' || url.pathname === '/index.html' || url.pathname.endsWith('.html');

    if (isProtected) {
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

    if (url.pathname === '/' || url.pathname === '/index.html' || url.pathname.indexOf('.') > -1) {
        let filePath = path.join(__dirname, 'public', url.pathname === '/' ? 'index.html' : url.pathname);
        if (fs.existsSync(filePath) && fs.statSync(filePath).isFile()) {
             const ext = path.extname(filePath);
             const mime = { '.html': 'text/html', '.css': 'text/css', '.js': 'text/javascript' }[ext] || 'text/plain';
             res.writeHead(200, { 'Content-Type': mime });
             fs.createReadStream(filePath).pipe(res);
             return;
        }
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

    if (url.pathname.startsWith("/sub")) {
        res.writeHead(301, { 'Location': SUB_PAGE_URL + `?host=${APP_DOMAIN}` });
        res.end();
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
<html lang="id">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>MyVPN Vault | Personal Admin</title>

    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;600&family=Rajdhani:wght@500;600;700&display=swap" rel="stylesheet">

    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">
    <script src="https://cdnjs.cloudflare.com/ajax/libs/three.js/r128/three.min.js"></script>

    <style>
        :root {
            --accent-cyan: #00e5ff;
            --accent-glow: rgba(0, 229, 255, 0.4);
            --bg-dark: #050505;
            --panel-bg: rgba(10, 15, 30, 0.85);
            --border-color: rgba(0, 229, 255, 0.2);
            --text-main: #e0e0e0;
            --text-dim: #6e7681;
            --danger: #ff2a6d;
            --success: #00ff88;
        }

        * { margin: 0; padding: 0; box-sizing: border-box; }

        body {
            background-color: var(--bg-dark);
            color: var(--text-main);
            font-family: 'Inter', sans-serif;
            overflow-x: hidden;
            height: 100vh;
            display: flex;
            flex-direction: column;
        }

        #bg-canvas {
            position: fixed;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            z-index: -1;
            opacity: 0.5;
        }

        .container {
            display: flex;
            flex: 1;
            height: 100%;
            position: relative;
            z-index: 10;
        }

        /* --- Sidebar --- */
        .sidebar {
            width: 80px;
            background: rgba(0,0,0,0.8);
            backdrop-filter: blur(10px);
            border-right: 1px solid var(--border-color);
            display: flex;
            flex-direction: column;
            align-items: center;
            padding-top: 30px;
            transition: width 0.3s;
        }

        .sidebar:hover { width: 200px; }

        .nav-item {
            width: 100%;
            padding: 15px 0;
            display: flex;
            align-items: center;
            justify-content: center;
            color: var(--text-dim);
            cursor: pointer;
            transition: 0.3s;
            border-left: 3px solid transparent;
        }

        .sidebar:hover .nav-item { justify-content: flex-start; padding-left: 28px; }
        .sidebar:hover .nav-text { opacity: 1; display: inline; }

        .nav-item:hover, .nav-item.active {
            color: var(--accent-cyan);
            background: rgba(0, 229, 255, 0.05);
            border-left-color: var(--accent-cyan);
            box-shadow: 0 0 15px var(--accent-glow);
        }

        .nav-item i { font-size: 1.2rem; min-width: 50px; text-align: center; }
        .nav-text { opacity: 0; margin-left: 10px; font-family: 'Rajdhani', sans-serif; font-weight: 600; letter-spacing: 1px; }

        /* --- Main Content --- */
        .main-content {
            flex: 1;
            padding: 30px;
            overflow-y: auto;
        }

        header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 40px;
            border-bottom: 1px solid var(--border-color);
            padding-bottom: 20px;
        }

        .user-profile {
            display: flex;
            align-items: center;
            gap: 15px;
        }
        .avatar {
            width: 40px;
            height: 40px;
            border-radius: 50%;
            background: linear-gradient(45deg, #000, var(--accent-cyan));
            display: flex;
            align-items: center;
            justify-content: center;
            font-weight: bold;
            color: #fff;
            border: 1px solid var(--accent-cyan);
        }

        /* --- Grid & Cards --- */
        .grid-dashboard {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }

        .card {
            background: var(--panel-bg);
            border: 1px solid var(--border-color);
            border-radius: 12px;
            padding: 20px;
            position: relative;
            transition: 0.3s;
        }
        .card-title {
            font-family: 'Rajdhani', sans-serif;
            color: var(--text-dim);
            font-size: 0.8rem;
            text-transform: uppercase;
            margin-bottom: 5px;
        }
        .card-value {
            font-family: 'Rajdhani', sans-serif;
            font-size: 1.8rem;
            font-weight: 700;
            color: #fff;
        }

        /* --- Config List --- */
        .section-header {
            font-family: 'Rajdhani', sans-serif;
            font-size: 1.5rem;
            margin-bottom: 20px;
            display: flex;
            align-items: center;
            justify-content: space-between;
        }

        .config-grid {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(320px, 1fr));
            gap: 20px;
        }

        .config-card {
            background: rgba(255, 255, 255, 0.03);
            border: 1px solid var(--border-color);
            border-radius: 10px;
            padding: 15px;
            display: flex;
            flex-direction: column;
            gap: 10px;
            transition: 0.3s;
        }
        .config-card:hover { border-color: var(--accent-cyan); transform: translateY(-3px); }

        .config-header { display: flex; justify-content: space-between; align-items: center; }
        .server-name { font-weight: 600; color: #fff; font-size: 1.1rem; }

        .protocol-badge {
            font-size: 0.7rem; padding: 2px 6px; border-radius: 4px; background: rgba(0,0,0,0.5);
            font-family: 'Rajdhani', sans-serif; letter-spacing: 1px;
        }
        .protocol-trojan { color: var(--danger); border-color: var(--danger); }
        .protocol-vless { color: var(--accent-cyan); border-color: var(--accent-cyan); }
        .protocol-vmess { color: #ffe600; border-color: #ffe600; }

        .config-details { font-size: 0.8rem; color: var(--text-dim); line-height: 1.5; }

        .config-actions {
            margin-top: auto;
            display: flex;
            gap: 8px;
        }
        .btn {
            flex: 1; padding: 8px; border: none; border-radius: 6px; cursor: pointer;
            font-family: 'Rajdhani', sans-serif; font-weight: 600; text-transform: uppercase;
            transition: 0.3s; font-size: 0.8rem;
        }
        .btn-primary {
            background: rgba(0, 229, 255, 0.1); color: var(--accent-cyan); border: 1px solid rgba(0, 229, 255, 0.3);
        }
        .btn-primary:hover { background: var(--accent-cyan); color: #000; }
        .btn-danger {
            background: rgba(255, 42, 109, 0.1); color: var(--danger); border: 1px solid rgba(255, 42, 109, 0.3);
        }
        .btn-danger:hover { background: var(--danger); color: #fff; }

        /* --- Floating Action Button (Create) --- */
        .fab {
            position: fixed;
            bottom: 30px;
            right: 30px;
            width: 60px;
            height: 60px;
            background: var(--accent-cyan);
            border-radius: 50%;
            display: flex;
            align-items: center;
            justify-content: center;
            color: #000;
            font-size: 1.5rem;
            box-shadow: 0 0 20px var(--accent-glow);
            cursor: pointer;
            transition: 0.3s;
            z-index: 100;
        }
        .fab:hover { transform: scale(1.1) rotate(90deg); }

        /* --- Modal Form --- */
        .modal-overlay {
            position: fixed;
            top: 0; left: 0; width: 100%; height: 100%;
            background: rgba(0,0,0,0.8);
            backdrop-filter: blur(5px);
            z-index: 200;
            display: none;
            justify-content: center;
            align-items: center;
        }
        .modal-overlay.active { display: flex; }

        .modal {
            background: #0f1219;
            width: 90%;
            max-width: 500px;
            padding: 30px;
            border-radius: 15px;
            border: 1px solid var(--border-color);
            box-shadow: 0 0 50px rgba(0,0,0,0.8);
            position: relative;
            animation: slideUp 0.4s ease;
        }
        @keyframes slideUp {
            from { transform: translateY(50px); opacity: 0; }
            to { transform: translateY(0); opacity: 1; }
        }

        .modal h2 {
            font-family: 'Rajdhani', sans-serif;
            margin-bottom: 20px;
            color: var(--accent-cyan);
            text-transform: uppercase;
        }

        .form-group { margin-bottom: 15px; }
        .form-group label {
            display: block; margin-bottom: 8px; color: var(--text-dim); font-size: 0.9rem;
        }
        .form-group input, .form-group select {
            width: 100%;
            padding: 12px;
            background: rgba(255,255,255,0.05);
            border: 1px solid #333;
            border-radius: 6px;
            color: #fff;
            font-family: 'Inter', sans-serif;
            outline: none;
        }
        .form-group input:focus, .form-group select:focus {
            border-color: var(--accent-cyan);
            box-shadow: 0 0 10px rgba(0,229,255,0.2);
        }

        .modal-actions { display: flex; justify-content: flex-end; gap: 10px; margin-top: 25px; }

        /* --- Toast --- */
        #toast-container {
            position: fixed; top: 20px; right: 20px; z-index: 999;
        }
        .toast {
            background: #0f1219; border-left: 4px solid var(--accent-cyan);
            color: #fff; padding: 15px 20px; margin-bottom: 10px;
            border-radius: 4px; box-shadow: 0 5px 15px rgba(0,0,0,0.5);
            animation: slideIn 0.3s ease; display: flex; align-items: center; gap: 10px;
        }
        @keyframes slideIn { from { transform: translateX(100%); } to { transform: translateX(0); } }

        @media (max-width: 768px) {
            .container { flex-direction: column; }
            .sidebar { width: 100%; height: 60px; flex-direction: row; justify-content: space-around; padding: 0; order: 2; border-top: 1px solid var(--border-color); border-right: none; }
            .sidebar:hover { width: 100%; }
            .nav-item { flex-direction: column; justify-content: center !important; padding: 0 !important; border-left: none; border-bottom: 3px solid transparent; }
            .nav-text { display: none !important; }
            .main-content { padding: 20px 15px; }
        }
    </style>
</head>
<body>

    <canvas id="bg-canvas"></canvas>

    <div class="container">
        <!-- Sidebar -->
        <nav class="sidebar">
            <a href="#" class="nav-item active">
                <i class="fa-solid fa-gauge-high"></i><span class="nav-text">Dashboard</span>
            </a>
            <a href="#" class="nav-item">
                <i class="fa-solid fa-server"></i><span class="nav-text">Accounts</span>
            </a>
            <a href="#" class="nav-item">
                <i class="fa-solid fa-gear"></i><span class="nav-text">Settings</span>
            </a>
        </nav>

        <!-- Main -->
        <main class="main-content">
            <header>
                <div>
                    <h2 style="font-family: 'Rajdhani', sans-serif; font-weight: 700;">ADMIN PANEL</h2>
                    <p style="color: var(--text-dim); font-size: 0.9rem;">Kelola Akun VLES, VMES, TROJAN</p>
                </div>
                <div class="user-profile">
                    <div style="text-align: right;">
                        <div style="font-weight: 600;">Personal User</div>
                        <div style="font-size: 0.8rem; color: var(--accent-cyan);">Premium</div>
                    </div>
                    <div class="avatar">P</div>
                </div>
            </header>

            <!-- Stats -->
            <div class="grid-dashboard">
                <div class="card">
                    <div class="card-title">Total Akun</div>
                    <div class="card-value" id="total-accounts">0</div>
                </div>
                <div class="card">
                    <div class="card-title">Aktif Sekarang</div>
                    <div class="card-value" style="color: var(--success)">0</div>
                </div>
                <div class="card">
                    <div class="card-title">Expired dalam 7 Hari</div>
                    <div class="card-value" style="color: #ffe600">0</div>
                </div>
            </div>

            <!-- List -->
            <div class="section-header">
                <span><i class="fa-solid fa-users-gear" style="margin-right:10px; color: var(--accent-cyan)"></i> DAFTAR AKUN</span>
            </div>

            <div class="config-grid" id="account-list">
                <!-- Loaded from API -->
            </div>

        </main>
    </div>

    <!-- Floating Create Button -->
    <div class="fab" onclick="openModal()">
        <i class="fa-solid fa-plus"></i>
    </div>

    <!-- Create Account Modal -->
    <div class="modal-overlay" id="createModal">
        <div class="modal">
            <h2>Create New Account</h2>
            <form id="createForm" onsubmit="createAccount(event)">
                <div class="form-group">
                    <label>Username / Remark</label>
                    <input type="text" id="username" placeholder="Contoh: Client iPhone" required>
                </div>
                <div class="form-group">
                    <label>Protocol</label>
                    <select id="protocol">
                        <option value="vless">VLESS</option>
                        <option value="vmess">VMESS</option>
                        <option value="trojan">TROJAN</option>
                    </select>
                </div>
                <div class="form-group">
                    <label>Masa Aktif (Hari)</label>
                    <select id="duration">
                        <option value="7">7 Hari</option>
                        <option value="30" selected>30 Hari</option>
                        <option value="90">90 Hari</option>
                        <option value="365">1 Tahun</option>
                    </select>
                </div>

                <!-- PROXY INPUT -->
                <div class="form-group">
                    <label>Proxy Route (Optional)</label>
                    <input type="text" id="proxyRoute" placeholder="Contoh: 1.2.3.4:1080">
                    <select id="proxyType" style="margin-top: 5px;">
                        <option value="socks5">SOCKS5</option>
                        <option value="http">HTTP</option>
                    </select>
                </div>

                <div class="form-group">
                    <label>UUID (Auto Generated)</label>
                    <input type="text" id="uuidDisplay" readonly style="color: var(--text-dim); cursor: not-allowed;">
                </div>

                <div class="modal-actions">
                    <button type="button" class="btn" style="background: #333; color: #fff;" onclick="closeModal()">Batal</button>
                    <button type="submit" class="btn btn-primary">Buat Akun</button>
                </div>
            </form>
        </div>
    </div>

    <div id="toast-container"></div>

    <script>
        const API_URL = '/api/users';

        // --- AUTH: Prompt for credentials or handle 401 ---
        // For simplicity, browser handles Basic Auth prompt automatically on 401.

        window.addEventListener('DOMContentLoaded', loadUsers);

        // --- Three.js BG (Simple Particles) ---
        const canvas = document.querySelector('#bg-canvas');
        const renderer = new THREE.WebGLRenderer({ canvas, alpha: true });
        renderer.setSize(window.innerWidth, window.innerHeight);
        const scene = new THREE.Scene();
        const camera = new THREE.PerspectiveCamera(75, window.innerWidth/window.innerHeight, 0.1, 1000);
        camera.position.z = 20;

        const geometry = new THREE.BufferGeometry();
        const count = 300;
        const positions = new Float32Array(count*3);
        for(let i=0; i<count*3; i++) positions[i] = (Math.random()-0.5)*50;
        geometry.setAttribute('position', new THREE.BufferAttribute(positions, 3));
        const material = new THREE.PointsMaterial({size: 0.1, color: 0x00e5ff});
        const particles = new THREE.Points(geometry, material);
        scene.add(particles);

        function animate() {
            requestAnimationFrame(animate);
            particles.rotation.y += 0.001;
            renderer.render(scene, camera);
        }
        animate();

        // --- Logic Aplikasi ---

        function generateUUID() {
            return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
                var r = Math.random() * 16 | 0, v = c == 'x' ? r : (r & 0x3 | 0x8);
                return v.toString(16);
            });
        }

        const modal = document.getElementById('createModal');
        const uuidInput = document.getElementById('uuidDisplay');

        function openModal() {
            uuidInput.value = generateUUID();
            modal.classList.add('active');
        }

        function closeModal() {
            modal.classList.remove('active');
            document.getElementById('createForm').reset();
        }

        modal.addEventListener('click', (e) => {
            if (e.target === modal) closeModal();
        });

        function showToast(msg, type = 'success') {
            const container = document.getElementById('toast-container');
            const toast = document.createElement('div');
            toast.className = 'toast';
            const color = type === 'success' ? 'var(--accent-cyan)' : 'var(--danger)';
            toast.style.borderLeftColor = color;
            toast.innerHTML = `<i class="fa-solid fa-circle-info" style="color:${color}"></i> ${msg}`;
            container.appendChild(toast);
            setTimeout(() => {
                toast.style.opacity = '0';
                setTimeout(() => toast.remove(), 300);
            }, 3000);
        }

        // --- REAL API INTEGRATION ---

        async function loadUsers() {
            try {
                const res = await fetch(API_URL);
                if (res.status === 401) {
                    // Browser should show prompt, but if not, reload to trigger it
                    // window.location.reload();
                    return;
                }
                const users = await res.json();
                renderUserList(users);
                updateStats(users);
            } catch (err) {
                showToast("Gagal memuat data (Auth required)", "error");
            }
        }

        function renderUserList(users) {
            const list = document.getElementById('account-list');
            list.innerHTML = '';

            users.forEach(user => {
                let badgeClass = '';
                if(user.protocol === 'vless') badgeClass = 'protocol-vless';
                else if(user.protocol === 'vmess') badgeClass = 'protocol-vmess';
                else badgeClass = 'protocol-trojan';

                const card = document.createElement('div');
                card.className = 'config-card';
                card.innerHTML = `
                    <div class="config-header">
                        <div class="server-name">${user.username}</div>
                        <span class="protocol-badge ${badgeClass}">${user.protocol.toUpperCase()}</span>
                    </div>
                    <div class="config-details">
                        <div><i class="fa-solid fa-fingerprint" style="width:15px"></i> UUID: ${user.uuid.substring(0,8)}...</div>
                        <div><i class="fa-regular fa-clock" style="width:15px"></i> Exp: ${user.days} Hari (${new Date(user.expiredDate).toLocaleDateString()})</div>
                        ${user.proxyRoute ? `<div><i class="fa-solid fa-route" style="width:15px"></i> Proxy: ${user.proxyRoute} (${user.proxyType})</div>` : ''}
                        <div><i class="fa-solid fa-globe" style="width:15px"></i> Status: <span style="color:var(--success)">Aktif</span></div>
                    </div>
                    <div class="config-actions">
                        <button class="btn btn-primary" onclick="copyConfig('${user.uuid}', '${user.protocol}', '${user.username}', '${user.proxyRoute}', '${user.proxyType}')"><i class="fa-regular fa-copy"></i> Copy</button>
                        <button class="btn btn-danger" onclick="deleteAccount('${user.uuid}')"><i class="fa-solid fa-trash"></i></button>
                    </div>
                `;
                list.appendChild(card);
            });
        }

        async function createAccount(e) {
            e.preventDefault();

            const username = document.getElementById('username').value;
            const protocol = document.getElementById('protocol').value;
            const days = document.getElementById('duration').value;
            const uuid = document.getElementById('uuidDisplay').value;
            const proxyRoute = document.getElementById('proxyRoute').value;
            const proxyType = document.getElementById('proxyType').value;

            const date = new Date();
            date.setDate(date.getDate() + parseInt(days));

            const newUser = {
                username, protocol, days, uuid, proxyRoute, proxyType,
                expiredDate: date.toISOString()
            };

            try {
                const res = await fetch(API_URL, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(newUser)
                });

                if (res.ok) {
                    showToast('Akun berhasil dibuat!');
                    closeModal();
                    loadUsers();
                } else {
                    showToast('Gagal membuat akun', 'error');
                }
            } catch (err) {
                showToast('Error koneksi', 'error');
            }
        }

        async function deleteAccount(uuid) {
            if(confirm('Hapus akun ini?')) {
                try {
                    await fetch(`${API_URL}/${uuid}`, { method: 'DELETE' });
                    showToast('Akun dihapus');
                    loadUsers();
                } catch (err) {
                    showToast('Gagal menghapus', 'error');
                }
            }
        }

        function updateStats(users) {
            document.getElementById('total-accounts').innerText = users.length;
            document.getElementById('total-accounts').nextElementSibling.nextElementSibling.innerText = users.length;
        }

        function copyConfig(uuid, protocol, username, proxyRoute, proxyType) {
            const host = window.location.hostname;
            const port = 443; // Default TLS
            let path = '/';

            // Fix Proxy Path Generation
            if (proxyRoute && proxyRoute.trim() !== '') {
                // If proxyRoute includes 'http' or 'socks5', user might have pasted full link?
                // Assume user enters "IP:PORT"
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
                // Use built-in btoa for base64
                link = `vmess://${btoa(JSON.stringify(vmessJson))}`;
            } else if (protocol === 'trojan') {
                link = `trojan://${uuid}@${host}:${port}?security=tls&type=ws&host=${host}&path=${encodeURIComponent(path)}#${encodeURIComponent(username)}`;
            }

            navigator.clipboard.writeText(link).then(() => {
                showToast(`Config ${username} disalin`);
            }, (err) => {
                // Fallback if clipboard fails (non-secure context)
                console.error(err);
                prompt("Copy config link:", link);
            });
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
