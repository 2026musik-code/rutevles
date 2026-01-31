#!/bin/bash

# Auto Installer for Nautica Node.js (Proxy Support) on Ubuntu

echo "Installing Nautica Node.js..."

# 1. Install Node.js (v18+)
echo "Setting up Node.js repository..."
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs

# 2. Setup Directory
INSTALL_DIR="/opt/nautica"
mkdir -p $INSTALL_DIR
cp server.js $INSTALL_DIR/
cp package.json $INSTALL_DIR/

cd $INSTALL_DIR

# 3. Install Dependencies
echo "Installing NPM dependencies..."
npm install

# 4. Create Systemd Service
echo "Creating Systemd service..."
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
Environment=PORT=80

[Install]
WantedBy=multi-user.target
EOF

# 5. Start Service
echo "Starting service..."
systemctl daemon-reload
systemctl enable nautica
systemctl restart nautica

echo "Installation Complete!"
echo "Server is running on port 80."
echo "Check status with: systemctl status nautica"
