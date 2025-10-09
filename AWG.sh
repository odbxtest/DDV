#!/bin/bash

set -e

echo "Updating system..."
sudo apt update && sudo apt upgrade -y

if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    curl -sSL https://get.docker.com | sh || { echo "Docker installation failed"; exit 1; }
    sudo usermod -aG docker $(whoami)
fi

sudo apt install curl jq -y

getConfiguration=$(curl -s --connect-timeout 10 'https://raw.githubusercontent.com/odbxtest/VAL2/main/conc_info.json') || error "Failed to fetch configuration"
awg_port=$(echo "$getConfiguration" | jq -r '.awg_port')
wg_port=$(echo "$getConfiguration" | jq -r '.wg_port')

echo "Configuring firewall..."
sudo ufw allow 22
sudo ufw allow $awg_port
sudo ufw allow $wg_port
sudo ufw --force enable
sudo ufw --force reload

echo "Detecting server IP..."
serverIp=$(curl -s api.ipify.org || hostname -I | awk '{print $1}' || echo "YOUR_PUBLIC_IP_HERE")
if [ -z "$serverIp" ]; then
  echo "Warning: Auto-detection failed. Edit script to set WG_HOST manually."
  exit 1
fi
echo "Server IP: $serverIp"

echo "Generating bcrypt hash for password..."
read -sp "Enter admin panel password: " panelPassword
echo
panelPasswordHash=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'$panelPassword', bcrypt.gensalt()).decode())")
if [ -z "$panelPasswordHash" ]; then
  echo "Error: Failed to generate password hash. Install bcrypt with 'pip3 install bcrypt'."
  exit 1
fi
echo "Hash generated successfully (first 10 chars): ${panelPasswordHash:0:10}..."

echo "Starting AmneziaWG-Easy container..."

mkdir -p /root/AWG

# Create the docker-compose.yml file in /root/AWG
cat << 'EOF' > /root/AWG/docker-compose.yml
version: '3.8'

services:
  amnezia-wg-easy:
    image: ghcr.io/w0rng/amnezia-wg-easy
    container_name: amnezia-wg-easy
    environment:
      - LANG=en
      - WG_HOST=wg1.bdqp.ir
      - PORT=1013
      - PASSWORD_HASH=${panelPasswordHash}
      - WG_PERSISTENT_KEEPALIVE=21
      - WG_DEFAULT_DNS=1.1.1.1,8.8.8.8
      - UI_TRAFFIC_STATS=true
      - ENABLE_PROMETHEUS_METRICS=true
      - WG_PORT=${wg_port}
    volumes:
      - /root/.amnezia-wg-easy:/etc/wireguard
    ports:
      - "${wg_port}:${wg_port}/udp"
      - "${awg_port}:${awg_port}/tcp"
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv4.ip_forward=1
    devices:
      - /dev/net/tun:/dev/net/tun
    restart: unless-stopped
EOF

ls -la /root/AWG/
#cat /root/AWG/docker-compose.yml

cd /root/AWG
docker-compose up -d
docker-compose ps

echo "AmneziaWG-Easy installed successfully!"
echo "Verify: docker ps | grep amnezia-wg-easy"
echo "Access the web UI at http://$serverIp:$awg_port"
