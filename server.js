const http = require('http');
const net = require('net');
const WebSocket = require('ws');
const fs = require('fs');
const path = require('path');
const { webcrypto, createHash, randomUUID } = require('crypto');
const { exec } = require('child_process');
const crypto = webcrypto;

const DB_FILE = path.join(__dirname, 'users.json');
const CONFIG_FILE = path.join(__dirname, 'config.json');
const SESSIONS = new Map();

const horse = "dHJvamFu";
const flash = "dm1lc3M=";
const neko = "dmxlc3M=";

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

// ... Crypto Constants ...
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

const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, `http://${req.headers.host}`);

    // API: Login
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
                    res.writeHead(200, {
                        'Set-Cookie': `session_token=${token}; HttpOnly; Path=/; Max-Age=86400`,
                        'Content-Type': 'application/json'
                    });
                    res.end(JSON.stringify({ success: true }));
                } else {
                    res.writeHead(401, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ error: "Invalid credentials" }));
                }
            } catch { res.writeHead(400); res.end(); }
        });
        return;
    }

    // API: Update System
    if (url.pathname === '/api/update' && req.method === 'POST') {
        const cookieHeader = req.headers.cookie;
        let isAuthenticated = false;
        if (cookieHeader) {
            const cookies = cookieHeader.split(';').reduce((acc, c) => {
                const [n, v] = c.trim().split('='); acc[n] = v; return acc;
            }, {});
            if (cookies.session_token && SESSIONS.has(cookies.session_token)) isAuthenticated = true;
        }

        if(!isAuthenticated) {
            res.writeHead(401);
            res.end("Unauthorized");
            return;
        }

        res.writeHead(200, { 'Content-Type': 'application/json' });
        exec('git pull origin main', { cwd: __dirname }, (err, stdout, stderr) => {
            if (err) {
                res.end(JSON.stringify({ success: false, message: stderr }));
                return;
            }
            res.end(JSON.stringify({ success: true, message: "Update successful. Restarting..." }));
            setTimeout(() => process.exit(0), 1000);
        });
        return;
    }

    if (req.method === 'OPTIONS') {
        res.writeHead(200, CORS_HEADER_OPTIONS);
        res.end();
        return;
    }

    const isPublic = url.pathname.startsWith("/check") || url.pathname.startsWith("/sub") || url.pathname === '/login.html';

    // Auth Check
    let isAuthenticated = false;
    const cookieHeader = req.headers.cookie;
    if (cookieHeader) {
        const cookies = cookieHeader.split(';').reduce((acc, c) => {
            const [n, v] = c.trim().split('='); acc[n] = v; return acc;
        }, {});
        if (cookies.session_token && SESSIONS.has(cookies.session_token)) isAuthenticated = true;
    }

    if (!isPublic && (url.pathname.startsWith('/api/') || url.pathname === '/' || url.pathname.endsWith('.html'))) {
        if (!isAuthenticated) {
            if (url.pathname === '/' || url.pathname.endsWith('.html')) {
                res.writeHead(302, { 'Location': '/login.html' });
                res.end();
            } else {
                res.writeHead(401);
                res.end('Unauthorized');
            }
            return;
        }
    }

    // API: Users
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

    let pathSegment = url.pathname.substring(1);
    if (pathSegment && (pathSegment.includes(':') || pathSegment.includes('=') || pathSegment.includes('-'))) {
         prxIP = pathSegment;
    }

    wss.handleUpgrade(request, socket, head, (ws) => {
        websocketHandler(ws, request, prxIP, proxyType);
    });
});

async function websocketHandler(webSocket, request, prxIP, proxyType) {
    const log = (msg) => console.log(`[WS] ${msg}`);

    let isHeader = true;
    let isConnected = false;
    let buffer = []; // Buffer for chunks arriving during connect
    let tcpSocket = null;
    let remoteProtocolHeader = null;

    webSocket.on('message', async (chunk) => {
        if (isHeader) {
            isHeader = false; // Only try to parse the first chunk as header

            try {
                // 1. Sniff & Parse
                const protocol = await protocolSniffer(chunk);
                let protocolHeader;
                let authenticated = false;

                log(`Sniffed Protocol: ${protocol}`);

                if (protocol === atob(horse)) { // Trojan
                    protocolHeader = readHorseHeader(chunk);
                    if (!protocolHeader.hasError && isValidTrojanUser(protocolHeader.passwordHash)) {
                        authenticated = true;
                    }
                } else if (protocol === atob(neko)) { // VLESS
                    protocolHeader = readNekoHeader(chunk);
                    const uuid = arrayBufferToHex(chunk.slice(1, 17));
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

                remoteProtocolHeader = protocolHeader;

                // 2. Send Response Header (VLESS/Trojan)
                let responseHeader = remoteProtocolHeader.version;
                if (protocol === atob(flash) && remoteProtocolHeader.needsResponse) {
                     responseHeader = await generateStreamResponseHeader(
                        remoteProtocolHeader.responseOptions,
                        remoteProtocolHeader.encKey,
                        remoteProtocolHeader.encIv,
                    );
                }

                // IMPORTANT: Send response header immediately
                if (responseHeader) webSocket.send(responseHeader);

                // 3. Connect to Backend
                const targetHost = remoteProtocolHeader.addressRemote;
                const targetPort = remoteProtocolHeader.portRemote;
                const isUDP = remoteProtocolHeader.isUDP;

                log(`Connecting to ${targetHost}:${targetPort} (UDP: ${isUDP})`);

                if (isUDP) {
                     // UDP Logic (Simplified for buffering - UDP doesn't "connect" in the same way, but we need a socket)
                     await handleUDPBuffering(
                        targetHost, targetPort, remoteProtocolHeader.rawClientData,
                        webSocket, buffer, log, RELAY_SERVER_UDP, prxIP, proxyType
                     );
                     // Note: UDP handler manages its own flow
                } else {
                    // TCP Connect
                    const { socket, leftover } = await connectTarget(targetHost, targetPort, prxIP, proxyType);
                    tcpSocket = socket;

                    // 4. Handle Connection Events
                    tcpSocket.on('error', (e) => {
                         log(`TCP Error: ${e.message}`);
                         webSocket.close();
                    });

                    tcpSocket.on('close', () => {
                        log("TCP Closed");
                        webSocket.close();
                    });

                    tcpSocket.on('data', (d) => {
                        if (webSocket.readyState === WebSocket.OPEN) webSocket.send(d);
                    });

                    // 5. Write Initial Data (Leftover from Proxy + Payload)
                    if (leftover && leftover.length > 0) {
                        tcpSocket.write(leftover);
                    }

                    if (remoteProtocolHeader.rawClientData && remoteProtocolHeader.rawClientData.length > 0) {
                         tcpSocket.write(remoteProtocolHeader.rawClientData);
                    }

                    // 6. Flush Buffer (Data arrived while we were awaiting connectTarget)
                    if (buffer.length > 0) {
                        const bufferedData = Buffer.concat(buffer);
                        tcpSocket.write(bufferedData);
                        buffer = null; // Free memory
                    }

                    isConnected = true;
                }

            } catch (err) {
                log(`Handshake Error: ${err.message}`);
                webSocket.close();
            }
        } else {
            // Not Header (subsequent data)
            if (isConnected && tcpSocket && !tcpSocket.destroyed) {
                tcpSocket.write(chunk);
            } else {
                // Still connecting, buffer it
                // Only buffer if we are not in UDP mode (UDP handler handles its own msg)
                // If protocolHeader is unknown (failed handshake), we are closed anyway
                if (buffer) buffer.push(chunk);
            }
        }
    });

    webSocket.on('error', (e) => log(`WS Error: ${e.message}`));
    webSocket.on('close', () => {
        if (tcpSocket && !tcpSocket.destroyed) tcpSocket.destroy();
    });
}

// UDP Handler (Modified for flow)
async function handleUDPBuffering(targetAddress, targetPort, initialData, webSocket, initialBuffer, log, relay, prxIP, proxyType) {
    // This is trickier because we need to share the socket with the main 'message' handler
    // For now, we'll keep the UDP logic self-contained but we need to stop the main handler from buffering unnecessarily
    // The main handler pushes to `buffer` if `!isConnected`.
    // We can set `isConnected = true` and `tcpSocket = udpSocket`? No, UDP socket write signature is different.

    // Simpler approach for UDP: Just launch the UDP handler and tell the main handler to STOP.
    // Actually, the main handler is `on('message')`. We can remove that listener or make it ignore?
    // Better: UDP is rare. Let's just create the socket and use a custom write logic.

    try {
        let socket;
         if (proxyType) {
             // ... Proxy logic for UDP ...
             const { socket: s } = await connectTarget(relay.host, relay.port, prxIP, proxyType);
             socket = s;
         } else {
             socket = net.connect(relay.port, relay.host);
         }

        // Initial Payload
        const header = `udp:${targetAddress}:${targetPort}`;
        const payload = Buffer.concat([Buffer.from(header), Buffer.from([0x7c]), Buffer.from(initialData)]);
        socket.write(payload);

        // Flush Initial Buffer
        if (initialBuffer.length > 0) {
             // We need to wrap these in UDP frame too?
             // Usually subsequent packets in UDP over VLESS are just raw payload?
             // No, standard UDP over TCP/VLESS usually requires framing.
             // But for this specific Relay, let's assume raw for now or just write them.
             const buf = Buffer.concat(initialBuffer);
             socket.write(buf);
        }

        socket.on('data', (chunk) => {
            if (webSocket.readyState === WebSocket.OPEN) webSocket.send(chunk);
        });

        // Take over the WebSocket message handling
        webSocket.removeAllListeners('message');
        webSocket.on('message', (msg) => {
             if (!socket.destroyed) socket.write(msg);
        });

        socket.on('error', (e) => log(`UDP Error: ${e.message}`));

    } catch(e) {
        log(`UDP Setup Error: ${e.message}`);
        webSocket.close();
    }
}

async function connectTarget(host, port, prxIP, proxyType) {
    if (proxyType) {
        if (!prxIP) throw new Error("ProxyType set but no ProxyIP provided");
        let sepIdx = -1;
        if (prxIP.includes('=')) sepIdx = prxIP.lastIndexOf('=');
        else if (prxIP.includes('-')) sepIdx = prxIP.lastIndexOf('-');
        else sepIdx = prxIP.lastIndexOf(':');

        if (sepIdx === -1) throw new Error("Invalid Proxy IP format");
        const pAddr = prxIP.substring(0, sepIdx);
        const pPort = parseInt(prxIP.substring(sepIdx + 1));

        const socket = net.connect(pPort, pAddr);
        await new Promise((res, rej) => {
            socket.once('connect', res);
            socket.once('error', rej);
        });

        if (proxyType === 'http') return await httpProxyConnect(socket, host, port);
        else return await socks5Connect(socket, host, port);
    } else {
         if (prxIP && !proxyType) { // Relay
             let sepIdx = -1;
             if (prxIP.includes('=')) sepIdx = prxIP.lastIndexOf('=');
             else if (prxIP.includes('-')) sepIdx = prxIP.lastIndexOf('-');
             else sepIdx = prxIP.lastIndexOf(':');
             if (sepIdx !== -1) {
                 const pAddr = prxIP.substring(0, sepIdx);
                 const pPort = parseInt(prxIP.substring(sepIdx + 1));
                 return { socket: net.connect(pPort, pAddr), leftover: null };
             }
        }
        // Direct
        const socket = net.connect(port, host);
        await new Promise((res, rej) => {
            socket.once('connect', res);
            socket.once('error', rej);
        });
        return { socket, leftover: null };
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

                let headerLen = 0;
                if (data2[3] === 0x01) headerLen = 10;
                else if (data2[3] === 0x04) headerLen = 22;
                else if (data2[3] === 0x03) headerLen = 7 + data2[4];

                let leftover = null;
                if (data2.length > headerLen) leftover = data2.slice(headerLen);
                resolve({ socket, leftover });
            });
        });
    });
}

async function httpProxyConnect(socket, targetAddress, targetPort) {
    return new Promise((resolve, reject) => {
        const req = `CONNECT ${targetAddress}:${targetPort} HTTP/1.1\r\nHost: ${targetAddress}:${targetPort}\r\n\r\n`;
        socket.write(req);
        socket.once('data', (data) => {
            if (data.toString().includes("200")) {
                let leftover = null;
                const idx = data.indexOf("\r\n\r\n");
                if (idx !== -1 && idx + 4 < data.length) leftover = data.slice(idx + 4);
                resolve({ socket, leftover });
            }
            else reject(new Error("HTTP Proxy failed"));
        });
        socket.once('error', reject);
    });
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
    for (const p of path) {
        result = await hmac(result, p);
    }
    return result;
}

server.listen(PORT, () => { console.log(`Server running on ${PORT}`); });
