const http = require('http');
const net = require('net');
const WebSocket = require('ws');
const fs = require('fs');
const path = require('path');
const { webcrypto, createHash, randomUUID } = require('crypto');
const crypto = webcrypto;

// --- Config & State ---
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

// --- Crypto Constants (Base64) ---
const SALT_A1 = atob("Vk1lc3MgSGVhZGVyIEFFQUQgS2V5X0xlbmd0aA==");
const SALT_A2 = atob("Vk1lc3MgSGVhZGVyIEFFQUQgTm9uY2VfTGVuZ3Ro");
const SALT_A3 = atob("Vk1lc3MgSGVhZGVyIEFFQUQgS2V5");
const SALT_A4 = atob("Vk1lc3MgSGVhZGVyIEFFQUQgTm9uY2U=");
const SALT_B1 = atob("QUVBRCBSZXNwIEhlYWRlciBMZW4gS2V5");
const SALT_B2 = atob("QUVBRCBSZXNwIEhlYWRlciBMZW4gSVY=");
const SALT_B3 = atob("QUVBRCBSZXNwIEhlYWRlciBLZXk=");
const SALT_B4 = atob("QUVBRCBSZXNwIEhlYWRlciBJVg==");

const PORT = process.env.PORT || 80;

// --- Helpers ---
function atob(str) { return Buffer.from(str, 'base64').toString('binary'); }
function btoa(str) { return Buffer.from(str, 'binary').toString('base64'); }
function arrayBufferToHex(buffer) {
    return [...new Uint8Array(buffer)].map(x => x.toString(16).padStart(2, '0')).join('');
}

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
    // Normalize UUID: remove dashes, lowercase
    const norm = uuid.replace(/-/g, '').toLowerCase();
    const user = users.find(u => u.uuid.replace(/-/g, '').toLowerCase() === norm);
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

// --- HTTP Server (Auth & Dashboard) ---
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

    if (req.method === 'OPTIONS') {
        res.writeHead(200, CORS_HEADER_OPTIONS);
        res.end();
        return;
    }

    // Check Auth for protected paths
    const isPublic = url.pathname.startsWith("/check") || url.pathname.startsWith("/sub") || url.pathname === '/login.html';
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

    // Static Files
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

// --- WebSocket & Protocol Logic ---

async function websocketHandler(webSocket, request, prxIP, proxyType) {
    const log = (msg) => console.log(`[WS] ${msg}`);

    // We rely on 'message' event to get the first chunk (Header)
    webSocket.once('message', async (chunk) => {
        // NOTE: chunk is a Buffer in ws
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
                // Extract UUID from VLESS header (bytes 1-17)
                uuid = arrayBufferToHex(chunk.slice(1, 17));
                // Format: 8-4-4-4-12
                const formattedUUID = `${uuid.substr(0,8)}-${uuid.substr(8,4)}-${uuid.substr(12,4)}-${uuid.substr(16,4)}-${uuid.substr(20,12)}`;
                log(`VLESS UUID: ${formattedUUID}`);

                // Nautica validates UUID strictly
                if (isValidUser(formattedUUID)) {
                    authenticated = true;
                } else {
                    log(`User not found: ${formattedUUID}`);
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
                if(!authenticated) log("VMess Auth Failed: No matching user");
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

            // Generate VMess response header if needed
            let responseHeader = protocolHeader.version;
            if (protocol === atob(flash) && protocolHeader.needsResponse) {
                 responseHeader = await generateStreamResponseHeader(
                    protocolHeader.responseOptions,
                    protocolHeader.encKey,
                    protocolHeader.encIv,
                );
            }

            log(`Connecting to Target: ${protocolHeader.addressRemote}:${protocolHeader.portRemote} (UDP: ${protocolHeader.isUDP})`);

            // Establish Outbound
            if (protocolHeader.isUDP) {
                await handleUDPOutbound(
                    protocolHeader.addressRemote,
                    protocolHeader.portRemote,
                    chunk, // Initial packet includes payload for UDP usually
                    webSocket,
                    responseHeader,
                    log,
                    RELAY_SERVER_UDP,
                    prxIP,
                    proxyType
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
                    proxyType
                );
            }

        } catch (err) {
            log(`Error: ${err.message}`);
            webSocket.close();
        }
    });

    webSocket.on('error', (err) => log(`WS Error: ${err.message}`));
}

async function handleTCPOutBound(addressRemote, portRemote, rawClientData, webSocket, responseHeader, log, prxIP, proxyType) {
    async function connectTarget(addr, port) {
        if (proxyType) {
            if (!prxIP) throw new Error("ProxyType set but no ProxyIP provided");
            // Parsing Logic matching Nautica/NodeJS
            let sepIdx = -1;
            if (prxIP.includes('=')) sepIdx = prxIP.lastIndexOf('=');
            else if (prxIP.includes('-')) sepIdx = prxIP.lastIndexOf('-');
            else sepIdx = prxIP.lastIndexOf(':');

            if (sepIdx === -1) throw new Error("Invalid Proxy IP format");
            const pAddr = prxIP.substring(0, sepIdx);
            const pPort = parseInt(prxIP.substring(sepIdx + 1));
            if (isNaN(pPort)) throw new Error("Invalid Proxy Port");

            log(`Proxy connect ${pAddr}:${pPort} -> ${addr}:${port}`);
            const socket = net.connect(pPort, pAddr);
            await new Promise((res, rej) => {
                socket.once('connect', res);
                socket.once('error', rej);
            });

            if (proxyType === 'http') return await httpProxyConnect(socket, addr, port);
            else return await socks5Connect(socket, addr, port);
        } else {
             // Relay Mode (Legacy) - Direct connection via "Relay" param
             if (prxIP && !proxyType) {
                 let sepIdx = -1;
                 if (prxIP.includes('=')) sepIdx = prxIP.lastIndexOf('=');
                 else if (prxIP.includes('-')) sepIdx = prxIP.lastIndexOf('-');
                 else sepIdx = prxIP.lastIndexOf(':');
                 if (sepIdx !== -1) {
                     const pAddr = prxIP.substring(0, sepIdx);
                     const pPort = parseInt(prxIP.substring(sepIdx + 1));
                     log(`Relay connect ${pAddr}:${pPort} -> ${addr}:${port}`);
                     return { socket: net.connect(pPort, pAddr), leftover: null };
                 }
            }
            log(`Direct connect ${addr}:${port}`);
            return { socket: net.connect(port, addr), leftover: null };
        }
    }

    try {
        const { socket: tcpSocket, leftover } = await connectTarget(addressRemote, portRemote);

        // 1. Send Response Header to Client (CRITICAL for VLESS/VMess)
        if (responseHeader && responseHeader.length > 0) {
            webSocket.send(responseHeader);
        }

        // 2. Handle Leftover Data from Proxy Handshake (Client -> Target)
        // Wait, leftover is from TARGET -> SERVER. We need to send it to Client.
        if (leftover && leftover.length > 0) {
            webSocket.send(leftover);
        }

        // 3. Send Initial Payload to Target
        if (rawClientData && rawClientData.length > 0) {
            tcpSocket.write(rawClientData);
        }

        // 4. Pipe Traffic
        // WS -> TCP
        const wsStream = WebSocket.createWebSocketStream(webSocket);
        wsStream.pipe(tcpSocket);

        // TCP -> WS
        tcpSocket.pipe(wsStream);

        tcpSocket.on('error', (e) => log(`TCP Error: ${e.message}`));
        tcpSocket.on('close', () => {
            log("TCP Closed");
            webSocket.close();
        });

    } catch (e) {
        log(`Outbound Failed: ${e.message}`);
        webSocket.close();
    }
}

// --- Crypto & Parsing Logic (Strictly from Nautica) ---

async function protocolSniffer(buffer) {
    // Exact Nautica Logic
    if (buffer.length >= 62) {
        const d = buffer.slice(56, 60);
        if (d[0]===0x0d && d[1]===0x0a) {
            if (d[2]===0x01 || d[2]===0x03 || d[2]===0x7f) {
                if (d[3]===0x01 || d[3]===0x03 || d[3]===0x04) return atob(horse);
            }
        }
    }
    if (buffer.length >= 18) {
        if (buffer[0] === 0) {
            // VLESS check UUID
            const uuid = arrayBufferToHex(buffer.slice(1, 17));
            if(uuid.match(/^[0-9a-f]{8}[0-9a-f]{4}4[0-9a-f]{3}[89ab][0-9a-f]{3}[0-9a-f]{12}$/i)) return atob(neko);
        }
    }
    if (buffer.length >= 42) {
        const first = buffer[0];
        if (first === 0x01 || first === 0x03 || first === 0x04) return "ss"; // Not supporting SS
        return atob(flash); // VMess
    }
    return "ss";
}

function readHorseHeader(buffer) {
    const data = buffer.slice(58);
    if (data.length < 6) return { hasError: true, message: "invalid data" };

    const view = new DataView(data.buffer, data.byteOffset, data.length);
    const cmd = view.getUint8(0);
    if (cmd !== 1 && cmd !== 3) return { hasError: true, message: "Unsupported command" };

    const atype = view.getUint8(1);
    let off = 2;
    let addr = "";
    if (atype === 1) { addr = `${view.getUint8(off)}.${view.getUint8(off+1)}.${view.getUint8(off+2)}.${view.getUint8(off+3)}`; off+=4; }
    else if (atype === 3) { const l = view.getUint8(off); off++; addr = new TextDecoder().decode(data.slice(off, off+l)); off+=l; }
    else if (atype === 4) { const p=[]; for(let i=0;i<8;i++) p.push(view.getUint16(off+i*2).toString(16)); addr=p.join(":"); off+=16; }
    else return { hasError: true, message: "Invalid ATYP" };

    const port = view.getUint16(off);
    return { hasError: false, addressRemote: addr, portRemote: port, isUDP: cmd===3, rawClientData: data.slice(off+2), passwordHash: buffer.slice(0, 56).toString() };
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
    if (atype === 1) { addr = `${buffer[off]}.${buffer[off+1]}.${buffer[off+2]}.${buffer[off+3]}`; off+=4; }
    else if (atype === 2) { const l = buffer[off]; off++; addr = buffer.slice(off, off+l).toString(); off+=l; }
    else if (atype === 3) { const p=[]; for(let i=0;i<8;i++) p.push(buffer.readUInt16BE(off+i*2).toString(16)); addr=p.join(":"); off+=16; }

    return { hasError: false, addressRemote: addr, portRemote: port, isUDP: cmd===2, rawClientData: buffer.slice(off), version: new Uint8Array([ver, 0]) };
}

async function readStreamHeader(buffer, uuid) {
    // Exact Nautica Logic
    try {
        const uuidBytes = new Uint8Array(uuid.replace(/-/g, "").match(/.{1,2}/g).map(b => parseInt(b, 16)));
        const authKey = await md5(uuidBytes, new TextEncoder().encode(atob("YzQ4NjE5ZmUtOGYwMi00OWUwLWI5ZTktZWRmNzYzZTE3ZTIx")));

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

        // Parse Head
        const view = new DataView(head.buffer, head.byteOffset, head.length);
        let off = 0;
        const ver = view.getUint8(off++);
        if (ver !== 1) throw new Error("Invalid Version");

        const encIv = head.slice(off, off+16); off+=16;
        const encKey = head.slice(off, off+16); off+=16;
        const opts = head.slice(off, off+4); off+=4;
        const cmd = view.getUint8(off++);
        const port = view.getUint16(off); off+=2;
        const atype = view.getUint8(off++);
        let addr = "";
        if (atype === 1) { addr = `${view.getUint8(off)}.${view.getUint8(off+1)}.${view.getUint8(off+2)}.${view.getUint8(off+3)}`; off+=4; }
        else if (atype === 2 || atype === 3) { const l = view.getUint8(off++); addr = new TextDecoder().decode(head.slice(off, off+l)); off+=l; }
        else if (atype === 4) { const p=[]; for(let i=0;i<8;i++) p.push(view.getUint16(off+i*2).toString(16)); addr=p.join(":"); off+=16; }

        const rawInd = 42 + hLen + 16;
        return { hasError: false, addressRemote: addr, portRemote: port, isUDP: cmd!==1, rawClientData: buffer.slice(rawInd), version: new Uint8Array([opts[0], 0]), encKey, encIv, needsResponse: true, responseOptions: opts };
    } catch(e) { return { hasError: true, message: e.message }; }
}

async function generateStreamResponseHeader(opts, key, iv) {
    try {
        // NOTE: In Nautica/Rust, KEY and IV are swapped in the hash input relative to variable names?
        // const key = sha256(encKey)...
        // Check Nautica Code:
        // const key = (await sha256(encKey)).slice(0, 16);
        // const iv = (await sha256(encIv)).slice(0, 16);
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

// --- Crypto Primitives ---
async function md5(...args) {
    const combined = Buffer.concat(args.map(a => new Uint8Array(a)));
    return new Uint8Array(await crypto.subtle.digest("MD5", combined));
}
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
    const sha256Hash = async (d) => new Uint8Array(await crypto.subtle.digest("SHA-256", d));
    const hmacSha256 = async (k, d) => {
        const key = await crypto.subtle.importKey("raw", k, {name:"HMAC", hash:"SHA-256"}, false, ["sign"]);
        return new Uint8Array(await crypto.subtle.sign("HMAC", key, d));
    };

    // Recursive Hash (Mirrors Nautica/v2ray-core)
    const recursiveHash = async (kBytes, innerFn) => {
        return async (data) => {
            const ipad = new Uint8Array(64);
            const opad = new Uint8Array(64);
            ipad.set(kBytes.slice(0, 64));
            opad.set(kBytes.slice(0, 64));
            for(let i=0; i<64; i++) { ipad[i] ^= 0x36; opad[i] ^= 0x5c; }

            const inner = new Uint8Array(ipad.length + data.length);
            inner.set(ipad); inner.set(data, ipad.length);
            const innerRes = await innerFn(inner);

            const outer = new Uint8Array(opad.length + innerRes.length);
            outer.set(opad); outer.set(innerRes, opad.length);
            return await innerFn(outer);
        };
    };

    let currentFn = await recursiveHash(new TextEncoder().encode("VMess AEAD KDF"), sha256Hash);
    for (const salt of path) {
        const saltBytes = typeof salt === 'string' ? new TextEncoder().encode(salt) : new Uint8Array(salt);
        currentFn = await recursiveHash(saltBytes, currentFn);
    }
    return await currentFn(key);
}

// --- Outbound Handlers (Proxy) ---
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

async function handleUDPOutbound(targetAddress, targetPort, dataChunk, webSocket, responseHeader, log, relay, prxIP, proxyType) {
    async function connectTarget() {
        if (proxyType) {
             if (!prxIP) throw new Error("ProxyType set but no ProxyIP provided");
             let sepIdx = -1;
             if (prxIP.includes('=')) sepIdx = prxIP.lastIndexOf('=');
             else if (prxIP.includes('-')) sepIdx = prxIP.lastIndexOf('-');
             else sepIdx = prxIP.lastIndexOf(':');

             if (sepIdx === -1) throw new Error("Invalid Proxy IP");
             const pAddr = prxIP.substring(0, sepIdx);
             const pPort = parseInt(prxIP.substring(sepIdx + 1));

            const socket = net.connect(pPort, pAddr);
            await new Promise((res, rej) => { socket.once('connect', res); socket.once('error', rej); });

            let res;
            if (proxyType === 'http') res = await httpProxyConnect(socket, relay.host, relay.port);
            else res = await socks5Connect(socket, relay.host, relay.port);
            return res.socket;
        } else return net.connect(relay.port, relay.host);
    }

    try {
        const socket = await connectTarget();
        // Send Response Header (VLESS/VMess) before anything else
        if (responseHeader) webSocket.send(responseHeader);

        const header = `udp:${targetAddress}:${targetPort}`;
        const payload = Buffer.concat([Buffer.from(header), Buffer.from([0x7c]), Buffer.from(dataChunk)]);
        socket.write(payload);

        // Pipe from Socket -> WebSocket
        socket.on('data', (chunk) => {
            if (webSocket.readyState === WebSocket.OPEN) webSocket.send(chunk);
        });

        // Pipe from WebSocket -> Socket (Need to handle frames)
        webSocket.on('message', (msg) => {
            if (!socket.destroyed) socket.write(msg);
        });

        socket.on('error', (e) => log(`UDP Error: ${e.message}`));
    } catch(e) { webSocket.close(); }
}

server.listen(PORT, () => { console.log(`Server running on ${PORT}`); });
