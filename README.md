# Nautica Node.js Server (RuteVless)

Repository: [https://github.com/2026musik-code/rutevles](https://github.com/2026musik-code/rutevles)

This is a comprehensive VLESS/VMess/Trojan tunneling server solution for Ubuntu VPS. It features a modern **Web Admin Panel**, **Real User Authentication**, **Subscription Links**, and **Automatic HTTPS** via Caddy.

## Key Features

*   **🛡️ Multi-Protocol Support:**
    *   **VLESS** (UUID v4)
    *   **VMess** (AEAD)
    *   **Trojan**
*   **👥 Real User Management:**
    *   **Web Dashboard:** Create, delete, and manage users easily.
    *   **Authentication:** Server enforces UUID validation against a local database (`users.json`).
    *   **Expiry System:** Auto-reject connections from expired accounts.
*   **🔗 Subscription System:**
    *   **RSS Feed:** Generate V2Ray subscription links for easy client configuration.
    *   **One-Click Copy:** Copy subscription URLs directly from the dashboard.
*   **🔒 Auto HTTPS:**
    *   Integrated **Caddy Web Server** automatically provisions and renews Let's Encrypt SSL certificates.
    *   Serves the Admin Panel and WebSocket tunnels over standard HTTPS (Port 443).
*   **📊 Live Stats:**
    *   Monitor CPU, RAM, Disk, and Network Traffic in real-time.

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

You will see the **RUTE PREMIUM** dashboard. Login with the credentials you set during installation (Default: `admin` / `admin`).

### 2. Creating an Account
1.  Click the **(+) New User** button.
2.  **Username:** Enter a client name.
3.  **Protocol:** Choose VLESS, VMess, or Trojan.
4.  **Duration:** Select validity period.
5.  Click **"Create"**.

### 3. Connecting Client
*   **Single Config:** Click the blue **Copy Config** button next to a user.
*   **Subscription:** Click the green **RSS** button to copy the subscription URL. Paste this into your client app (v2rayNG -> Update Subscription) to import all configs at once.

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
