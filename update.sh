#!/bin/bash

RED='\033[0;31m'
GR='\033[0;32m'
YE='\033[0;33m'
NC='\033[0m'
info()  { echo -e "${GR}${1:-}${NC}"; }
warn()  { echo -e "${YE}${1:-}${NC}"; }
error() { echo -e "${RED}${1:-Unknown error}${NC}" 1>&2; exit 1; }


cd /root/

apt_wait() {
  echo "Checking dpkg/apt locks"
  for i in $(seq 1 120); do
    if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
       || fuser /var/lib/dpkg/lock >/dev/null 2>&1 \
       || pgrep -x apt >/dev/null \
       || pgrep -x apt-get >/dev/null \
       || pgrep -x dpkg >/dev/null \
       || pgrep -x unattended-upgrade >/dev/null; then
      warn "[$i/120] lock/process active; waiting 5s..."
      sleep 5
    else
      echo "Lock is free. Proceed."
      return 0
    fi
  done
  return 1
}

apt_wait
sudo DEBIAN_FRONTEND=noninteractive apt-get -y -q update

apt_wait
sudo DEBIAN_FRONTEND=noninteractive \
    apt-get -y -q \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    upgrade

apt_wait
sudo DEBIAN_FRONTEND=noninteractive \
    apt-get -y -q \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    install sudo curl ufw jq

if ! grep -q "disable_ipv6" /etc/sysctl.conf; then
  echo -e "net.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\nnet.ipv6.conf.lo.disable_ipv6 = 1" | sudo tee -a /etc/sysctl.conf
  sudo sysctl -p
  info "* IPV6 Disabled"
fi

getConfiguration=$(curl -s --connect-timeout 10 'https://raw.githubusercontent.com/odbxtest/DDV/main/info.json') || error "Failed to fetch configuration"
ddv_url=$(echo "$getConfiguration" | jq -r '.url')
ddv_path=$(echo "$getConfiguration" | jq -r '.path')
awg_port=$(echo "$getConfiguration" | jq -r '.awg_port')
ssh_ports=$(echo "$getConfiguration" | jq -r '."ssh_ports"[]' 2>/dev/null)
apt=$(echo "$getConfiguration" | jq -r '."apt"[]' 2>/dev/null)
pip=$(echo "$getConfiguration" | jq -r '."pip"[]' 2>/dev/null)

if [[ "$ddv_path" == *"/"* ]]; then
    echo "OK - $ddv_path"
else
    error "Error: Invalid or unsafe path '$ddv_path'."
fi

apt_wait
if [ -n "$apt" ]; then
  sudo DEBIAN_FRONTEND=noninteractive \
    apt-get -y -q \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    install $apt || error "Failed to install apt packages"
fi

apt_wait
if [ -n "$pip" ]; then
  pipCMD="pip3 install $pip"
  warn "$pipCMD"
  $pipCMD || error "Failed to install pip packages"
fi

apt_wait
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

for port in $ssh_ports; do
  sudo ufw allow $port
  if ! grep -q "^Port $port" /etc/ssh/sshd_config; then
    echo "Port $port" | sudo tee -a /etc/ssh/sshd_config
    info "+ Added Port [$port] to sshd_config"
  fi
done
sudo systemctl restart sshd || error "Failed to restart SSH service"

read -p "Enter WG-Users Port: " wgUsersPort
read -sp "Enter admin panel password: " panelPassword
echo
echo "Generating bcrypt hash for password..."
panelPasswordHash=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'$panelPassword', bcrypt.gensalt()).decode())") || error "Failed to generate password hash."
if [ -z "$panelPasswordHash" ]; then
    error "Error: Failed to generate password hash."
fi
echo "Hash generated successfully (first 10 chars): ${panelPasswordHash:0:10}..."

sudo ufw allow $awg_port
sudo ufw allow $wgUsersPort
sudo ufw --force enable
sudo ufw reload

echo "Detecting server IP..."
#serverIp=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me || hostname -I | awk '{print $1}') || error "Failed to detect server IP."
serverIp=$(hostname -I | awk '{print $1}') || error "Failed to detect server IP."
if [ -z "$serverIp" ]; then
    error "Warning: Auto-detection failed. Edit script to set serverIp manually."
fi
echo "Server IP: $serverIp"

# ---------------------------
cd $ddv_path && docker compose down
docker stop $(docker ps -a -q) &> /dev/null
docker rm $(docker ps -a -q) &> /dev/null
docker volume rm ddawg_ddAWG_wgConfigs
docker compose down --volumes --rmi all
rm -r $ddv_path
rm -r /etc/wireguard/*
# ---------------------------

mkdir -p "$ddv_path"

echo "Starting ddAWG..."

cd "$ddv_path"
wget "${ddv_url}/files/ddAWG.zip" || error "Failed to download ddAWG.zip"
unzip ddAWG.zip

cat << EOF > "$ddv_path/.env"
DDV_URL=${ddv_url}
DDV_PATH=${ddv_path}
WG_HOST=${serverIp}
WG_DEVICE=eth0
PORT=${awg_port}
WG_PORT=${wgUsersPort}
WG_DEFAULT_ADDRESS=10.13
WG_DEFAULT_DNS=10.0.0.243,10.0.0.242
PASSWORD_HASH='${panelPasswordHash}'
ENABLE_PROMETHEUS_METRICS=true
WG_PERSISTENT_KEEPALIVE=21
UI_TRAFFIC_STATS=true
DICEBEAR_TYPE=bottts
USE_GRAVATAR=true
LANGUAGE=ddv
EOF
cat << 'EOF' >> "$ddv_path/.env"
WG_POST_UP='iptables -A FORWARD -i %i -o wg-+ -j ACCEPT; iptables -A FORWARD -i wg-+ -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -A POSTROUTING -o wg-+ -j MASQUERADE'
WG_POST_DOWN='iptables -D FORWARD -i %i -o wg-+ -j ACCEPT; iptables -D FORWARD -i wg-+ -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -D POSTROUTING -o wg-+ -j MASQUERADE'
EOF

cat $ddv_path/.env
read -sp "Continue? "

cat << 'EOF' > "$ddv_path/docker-compose.yml"
services:
  ddawg_panel:
    env_file:
      - .env
    build: .
    container_name: ddawg_panel
    volumes:
      - ${DDV_PATH}:${DDV_PATH}
      - /etc/wireguard:/etc/wireguard
    ports:
      - "${WG_PORT}:${WG_PORT}/udp"
      - "${PORT}:${PORT}/tcp"
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
      - SYS_ADMIN
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
    devices:
    - /dev/net/tun:/dev/net/tun
    dns:
      - 1.1.1.1
      - 8.8.8.8
EOF

cat $ddv_path/docker-compose.yml
read -sp "Continue? "

docker compose up --build -d
docker compose ps
echo
sleep 1
docker compose logs -f
