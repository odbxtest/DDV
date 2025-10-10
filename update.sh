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
awg_port=$(echo "$getConfiguration" | jq -r '.awg_port')
wg_port=$(echo "$getConfiguration" | jq -r '.wg_port')
ssh_ports=$(echo "$getConfiguration" | jq -r '."ssh_ports"[]' 2>/dev/null)
ddv_path=$(echo "$getConfiguration" | jq -r '.path')
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

for port in $ssh_ports; do
  sudo ufw allow $port
  if ! grep -q "^Port $port" /etc/ssh/sshd_config; then
    echo "Port $port" | sudo tee -a /etc/ssh/sshd_config
    info "+ Added Port [$port] to sshd_config"
  fi
done
sudo systemctl restart sshd || error "Failed to restart SSH service"

sudo ufw allow $awg_port
sudo ufw allow $wg_port
sudo ufw --force enable
sudo ufw reload

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

hostname -I
echo ""

exit 0
