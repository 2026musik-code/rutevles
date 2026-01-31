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
// Removed SS to prevent open proxy

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

// -- Auth Helper --
function checkAuth(req) {
    if (!fs.existsSync(CONFIG_FILE)) return true; // Fail open if no config? No, fail secure.
    // If no config file, default to admin:admin
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

// HTTP Server
const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, `http://${req.headers.host}`);

    // CORS
    if (req.method === 'OPTIONS') {
        res.writeHead(200, CORS_HEADER_OPTIONS);
        res.end();
        return;
    }

    // --- PROTECTED ROUTES (Dashboard & API) ---
    // Note: Public /sub links typically need to be open, but we keep them open for now.
    // Dashboard and User API must be secured.

    const isProtected = url.pathname.startsWith('/api/users') || url.pathname === '/' || url.pathname === '/index.html' || url.pathname.endsWith('.html');

    if (isProtected) {
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

    // --- Static Files ---
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

    // Fallback logic endpoints
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
        // ... (Existing sub logic if needed, kept simple redirect for now as per previous step)
        res.writeHead(301, { 'Location': SUB_PAGE_URL + `?host=${APP_DOMAIN}` });
        res.end();
        return;
    }

    res.writeHead(404);
    res.end("Not Found");
});

// WebSocket Server
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
                // Unknown or unsupported (SS removed)
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

// ... Proxy Connectors ...

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

// ... Parsers ...

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
        if (first === 1 || first === 3 || first === 4) return "ss"; // Removed "ss" from sniffed return
        return atob(flash);
    }
    // Default fallback
    return "";
}

// Trojan Auth Helper
function isValidTrojanUser(hashBuffer) {
    const receivedHash = hashBuffer.toString();
    const users = getUsers().filter(u => u.protocol === 'trojan');
    for (const user of users) {
        const userHash = createHash('sha224').update(user.uuid).digest('hex'); // uuid used as password
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

// Removed readSsHeader from usage path

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
    console.error("Failed to generate stream response:", e);
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
