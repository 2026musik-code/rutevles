# Nautica Node.js Server (RuteVless)

Repository: [https://github.com/2026musik-code/rutevles](https://github.com/2026musik-code/rutevles)

This project is a Node.js port of the [Nautica](https://github.com/FoolVPN-ID/Nautica) Cloudflare Worker script. It allows you to deploy a powerful VLESS/VMess/Trojan/Shadowsocks tunneling server on any Ubuntu VPS, with added support for routing outbound traffic through SOCKS5 or HTTP proxies.

## Features

*   **Multi-Protocol Support:**
    *   VLESS (UUID v4)
    *   VMess (AEAD)
    *   Trojan
    *   Shadowsocks
*   **Outbound Proxy Routing:**
    *   Route your tunneling traffic through an upstream SOCKS5 or HTTP proxy.
    *   Hides your VPS IP from the final destination.
*   **Auto-Installer:**
    *   Simple bash script to install Node.js, dependencies, and set up a systemd service.
*   **High Performance:**
    *   Built on Node.js native `net` and `ws` modules.

## Installation

You can install this server on your Ubuntu VPS with a single command.

### Quick Install

Connect to your VPS via SSH and run:

```bash
wget https://raw.githubusercontent.com/2026musik-code/rutevles/main/install.sh && chmod +x install.sh && ./install.sh
```

*(Note: Ensure the repository URL in the command matches where you push this code)*

### Manual Installation

1.  **Install Node.js (v18 or later):**
    ```bash
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y nodejs
    ```

2.  **Clone the Repository:**
    ```bash
    git clone https://github.com/2026musik-code/rutevles.git /opt/nautica
    cd /opt/nautica
    ```

3.  **Install Dependencies:**
    ```bash
    npm install
    ```

4.  **Run the Server:**
    ```bash
    sudo node server.js
    ```
    *The server runs on port 80 by default.*

## Usage & Proxy Routing

To connect to the server, use your V2Ray/V2Fly/Xray client.

### Standard Connection (Direct)
Connect using your VPS IP and Port 80.

### Connection via Proxy (The "Rute" Feature)

You can route your traffic through an upstream proxy by modifying the **Path** in your client configuration.

**Format:**
```
/PROXY_IP:PROXY_PORT?proxyType=TYPE
```

*   **PROXY_IP**: The IP address of the upstream proxy.
*   **PROXY_PORT**: The port of the upstream proxy.
*   **TYPE**: `socks5` or `http`.

**Examples:**

1.  **Route through a SOCKS5 Proxy at 1.2.3.4:1080:**
    *   **Path:** `/1.2.3.4:1080?proxyType=socks5`

2.  **Route through an HTTP Proxy at 5.6.7.8:8080:**
    *   **Path:** `/5.6.7.8:8080?proxyType=http`

3.  **Legacy Relay Mode (No Handshake / Direct Relay):**
    *   **Path:** `/1.2.3.4:80`
    *   *(If `proxyType` is omitted, it attempts to connect directly to the target IP provided in the path, acting as a simple relay)*.

## Service Management

If installed via `install.sh`, the server runs as a systemd service named `nautica`.

*   **Check Status:** `systemctl status nautica`
*   **Restart:** `systemctl restart nautica`
*   **Stop:** `systemctl stop nautica`
*   **Logs:** `journalctl -u nautica -f`
