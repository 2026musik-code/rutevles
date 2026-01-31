# Nautica Node.js Server (RuteVless)

Repository: [https://github.com/2026musik-code/rutevles](https://github.com/2026musik-code/rutevles)

This is a comprehensive VLESS/VMess/Trojan tunneling server solution for Ubuntu VPS. It features a modern **Web Admin Panel**, **Real User Authentication**, **Outbound Proxy Routing**, and **Automatic HTTPS** via Caddy.

## Key Features

*   **🛡️ Multi-Protocol Support:**
    *   **VLESS** (UUID v4)
    *   **VMess** (AEAD)
    *   **Trojan**
    *   **Shadowsocks**
*   **🚀 Outbound Proxy Routing:**
    *   Route individual user traffic through upstream SOCKS5 or HTTP proxies.
    *   Hide your VPS IP address from target websites.
*   **👥 Real User Management:**
    *   **Web Dashboard:** Create, delete, and manage users easily.
    *   **Authentication:** Server enforces UUID validation against a local database (`users.json`).
    *   **Expiry System:** Auto-reject connections from expired accounts.
*   **🔒 Auto HTTPS:**
    *   Integrated **Caddy Web Server** automatically provisions and renews Let's Encrypt SSL certificates.
    *   Serves the Admin Panel and WebSocket tunnels over standard HTTPS (Port 443).

## Installation

**Prerequisites:**
1.  A VPS running **Ubuntu 20.04** or newer.
2.  A **Domain Name** pointing to your VPS IP address (A Record).

### Quick Install (One-Click)

Connect to your VPS via SSH as `root` and run:

```bash
wget https://raw.githubusercontent.com/2026musik-code/rutevles/main/install.sh && chmod +x install.sh && ./install.sh
```

**During installation:**
*   You will be asked to enter your **Domain Name** (e.g., `vpn.example.com`).
*   The script will install Node.js, Caddy, dependencies, and set up the systemd service automatically.

## Usage Guide

### 1. Accessing the Admin Panel
Open your browser and navigate to:
`https://your-domain.com/`

You will see the "MyVPN Vault" dashboard.

### 2. Creating an Account
1.  Click the **(+)** button.
2.  **Username:** Enter a client name.
3.  **Protocol:** Choose VLESS, VMess, or Trojan.
4.  **Duration:** Select validity period.
5.  **Proxy Route (Optional):**
    *   To route this user's traffic through a proxy, enter `IP:PORT` (e.g., `1.2.3.4:1080`).
    *   Select the proxy type: `SOCKS5` or `HTTP`.
6.  Click **"Buat Akun"**.

### 3. Connecting Client
1.  In the dashboard list, click **"Copy"** on the user card.
2.  Paste the config link (vless://, vmess://, trojan://) into your client app (v2rayNG, Nekoray, etc.).
3.  Connect!

### Proxy Routing Explanation
When you configure a Proxy Route for a user, the generated config link will look like this:
*   **Path:** `/PROXY_IP:PORT?proxyType=socks5`
*   **Mechanism:** Your VPS receives the connection -> Handshakes with the Upstream Proxy -> Forwards traffic to the final destination.

## Manual Management

*   **Restart Server:** `systemctl restart nautica`
*   **Check Logs:** `journalctl -u nautica -f`
*   **Database File:** `/opt/nautica/users.json`
*   **Web Config:** `/etc/caddy/Caddyfile`

## Troubleshooting

**Q: Can't access dashboard?**
*   Check if port 80/443 is open in your firewall (`ufw allow 80`, `ufw allow 443`).
*   Ensure your domain DNS has propagated.

**Q: Connection failed?**
*   Check server logs: `journalctl -u nautica -f`
*   Ensure the client time matches the server time (VMess requirement).
