#!/bin/bash

set -euo pipefail

RED='\033[0;31m'
GR='\033[0;32m'
YE='\033[0;33m'
NC='\033[0m'
info()  { echo -e "${GR}${1:-}${NC}"; }
warn()  { echo -e "${YE}${1:-}${NC}"; }
error() { echo -e "${RED}${1:-Unknown error}${NC}" 1>&2; exit 1; }


if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    curl -sSL https://get.docker.com | sh || error "Docker installation failed."
    if [ "$(id -u)" != "0" ]; then
        sudo usermod -aG docker "$(whoami)" || error "Failed to add user to docker group."
        echo "Added user to docker group. You may need to log out and log back in for changes to take effect."
        echo "Alternatively, run the script as root."
    fi
fi

if ! docker compose version &> /dev/null; then
    error "Docker Compose is required. Please ensure it's installed or use Docker's compose plugin."
fi

echo "Fetching configuration..."
getConfiguration=$(curl -s --connect-timeout 10 'https://raw.githubusercontent.com/odbxtest/DDV/main/info.json') || error "Failed to fetch configuration."
ddv_url=$(echo "$getConfiguration" | jq -r '.url') || error "Failed to parse .url from configuration."
awg_port=$(echo "$getConfiguration" | jq -r '.awg_port') || error "Failed to parse .awg_port from configuration."
wg_port=$(echo "$getConfiguration" | jq -r '.wg_port') || error "Failed to parse .wg_port from configuration."
ddv_path=$(echo "$getConfiguration" | jq -r '.path') || error "Failed to parse .path from configuration."

echo "Detecting server IP..."
#serverIp=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me || hostname -I | awk '{print $1}') || error "Failed to detect server IP."
serverIp=$(hostname -I | awk '{print $1}') || error "Failed to detect server IP."
if [ -z "$serverIp" ]; then
    error "Warning: Auto-detection failed. Edit script to set serverIp manually."
fi
echo "Server IP: $serverIp"

echo "Generating bcrypt hash for password..."
read -sp "Enter admin panel password: " panelPassword
echo
panelPasswordHash=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'$panelPassword', bcrypt.gensalt()).decode())") || error "Failed to generate password hash."
if [ -z "$panelPasswordHash" ]; then
    error "Error: Failed to generate password hash."
fi
echo "Hash generated successfully (first 10 chars): ${panelPasswordHash:0:10}..."

echo "Starting AmneziaWG-Easy container..."

# ---------------------------
rm -r $ddv_path
# ---------------------------

mkdir -p "$ddv_path"

cat << EOF > "$ddv_path/.env"
DDV_PATH=${ddv_path}
DDV_URL=${ddv_url}
WG_HOST=${serverIp}
PORT=${awg_port}
WG_DEVICE=eth0
WG_PORT=${wg_port}
WG_DEFAULT_ADDRESS=10.13.0.1
WG_DEFAULT_DNS=1.1.1.1,8.8.8.8
WG_ALLOWED_IPS=0.0.0.0/0, ::/0
DICEBEAR_TYPE=bottts
USE_GRAVATAR=true
PASSWORD_HASH=${panelPasswordHash}
WG_PERSISTENT_KEEPALIVE=21
UI_TRAFFIC_STATS=true
ENABLE_PROMETHEUS_METRICS=true
LANGUAGE=en
EOF

cat << 'EOF' > "$ddv_path/docker-compose.yml"
volumes:
  etc_wireguard:
services:
  amnezia-wg-easy:
    env_file:
      - .env
    image: ghcr.io/w0rng/amnezia-wg-easy
    container_name: amnezia-wg-easy
    volumes:
      - ${DDV_PATH}:/etc/wireguard
    ports:
      - "${WG_PORT}:${WG_PORT}/udp"
      - "${PORT}:${PORT}/tcp"
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
    devices:
    - /dev/net/tun:/dev/net/tun
EOF

cd "$ddv_path"
docker compose up -d
docker compose ps

if docker ps | grep -q amnezia-wg-easy; then
    echo "AmneziaWG-Easy installed successfully!"
    echo "Verify: docker ps | grep amnezia-wg-easy"
    echo "Access the web UI at http://$serverIp:$awg_port"
else
    error "Failed to start AmneziaWG-Easy container."
fi
