#!/bin/bash

# Auto Installer for Nautica Node.js (Proxy Support) on Ubuntu

echo "============================================="
echo "   Nautica VLESS/VMess/Trojan Auto Installer "
echo "   With Caddy (Auto HTTPS) & Proxy Support   "
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

echo "Installing Nautica on $DOMAIN_NAME..."

# 1. Install Node.js (v20+)
echo "[1/5] Installing Node.js..."
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs unzip git

# 2. Install Caddy
echo "[2/5] Installing Caddy Web Server..."
apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive- keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt-get update
apt-get install -y caddy

# 3. Setup Directory
echo "[3/5] Setting up project files..."
INSTALL_DIR="/opt/nautica"
mkdir -p $INSTALL_DIR/public
cp server.js $INSTALL_DIR/
cp package.json $INSTALL_DIR/
cp public/index.html $INSTALL_DIR/public/
echo "[]" > $INSTALL_DIR/users.json # Init DB
chmod 666 $INSTALL_DIR/users.json

cd $INSTALL_DIR
echo "Installing NPM dependencies..."
npm install

# 4. Configure Caddy (Reverse Proxy + Auto HTTPS)
echo "[4/5] Configuring Caddy..."
cat <<EOF > /etc/caddy/Caddyfile
$DOMAIN_NAME {
    reverse_proxy localhost:3000
}
EOF
systemctl reload caddy

# 5. Create Systemd Service for Node App
echo "[5/5] Creating Systemd service..."
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

# 6. Start Service
echo "Starting service..."
systemctl daemon-reload
systemctl enable nautica
systemctl restart nautica

echo "============================================="
echo "   Installation Complete!                    "
echo "============================================="
echo "Dashboard: https://$DOMAIN_NAME/"
echo "Proxy Protocol: Enabled"
echo ""
echo "Manage service: systemctl status nautica"
