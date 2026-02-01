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

// Stats
let previousCpuUsage = null;
let publicIP = "Loading...";
exec('curl -s https://api.ipify.org', (err, stdout) => { if (!err) publicIP = stdout.trim(); });

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
            ip: publicIP,
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

    // Update
    if (url.pathname === '/api/update' && req.method === 'POST') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        // Force update code, but preserve config/users via .gitignore (handled by installer)
        exec('git fetch --all && git reset --hard origin/main', { cwd: __dirname }, (err, stdout, stderr) => {
            if (err) {
                console.error(err);
                res.end(JSON.stringify({ success: false, message: stderr || err.message }));
                return;
            }
            res.end(JSON.stringify({ success: true, message: "Update successful. Restarting..." }));
            // Increased timeout to ensure response is flushed
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
    webSocket.close(); // UDP disabled as per previous request
}

// ... Protocol Parsers (Same as before) ...
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
