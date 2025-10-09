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

getConfiguration=$(curl -s --connect-timeout 10 'https://raw.githubusercontent.com/odbxtest/VAL2/main/conc_info.json') || error "Failed to fetch configuration"
conc_url=$(echo "$getConfiguration" | jq -r '.url')
conc_port=$(echo "$getConfiguration" | jq -r '.conc_port')
awg_port=$(echo "$getConfiguration" | jq -r '.awg_port')
wg_port=$(echo "$getConfiguration" | jq -r '.wg_port')
ssh_ports=$(echo "$getConfiguration" | jq -r '."ssh_ports"[]' 2>/dev/null)
trafficCalculator=$(echo "$getConfiguration" | jq -c '.trafficCalculator')
onlineCheck=$(echo "$getConfiguration" | jq -c '.onlineCheck')
conc_path=$(echo "$getConfiguration" | jq -r '.path')
conc_awg_path=$(echo "$getConfiguration" | jq -r '.awg_path')
apt=$(echo "$getConfiguration" | jq -r '."apt"[]' 2>/dev/null)
pip=$(echo "$getConfiguration" | jq -r '."pip"[]' 2>/dev/null)

if [[ "$conc_awg_path" == *"/"* ]]; then
    echo "OK - $conc_awg_path"
else
    error "Error: Invalid or unsafe path '$conc_awg_path'."
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

sudo ufw allow $conc_port
sudo ufw allow $awg_port
sudo ufw allow $wg_port
sudo ufw allow 7300
sudo ufw allow 7555
sudo ufw --force enable
sudo ufw reload

# ********************************* #
for s in awgApp; do
    systemctl stop "$s.service"
    systemctl disable "$s.service"
    rm -f "/etc/systemd/system/$s.service"
done

rm -r $conc_awg_path
# ********************************* #

apt_wait

if [ -n "$(sudo lsof -t -i :"$awg_port")" ]; then
  sudo kill -9 $(sudo lsof -t -i :"$awg_port") && info "Killed process on port $awg_port"
else
  info "No process found on port $awg_port"
fi

if [ ! -d "$conc_awg_path" ]; then
  sudo mkdir -p "$conc_awg_path"
  sudo chmod 755 "$conc_awg_path"
  info "+ Created dir [$conc_awg_path]"
fi

cd $conc_awg_path
if [ ! -f app.py ]; then
  rm -rf "$conc_awg_path"/*
  
  wget "$conc_url/files/VAL2AWG.zip" || error "Failed to download VAL2AWG.zip"
  unzip VAL2AWG.zip
  find . -type f -name "*.py" -exec sed -i -e 's/\r$//' {} \;
  sudo pip3 install -r $conc_awg_path/requirements.txt
  
  for file in "$conc_awg_path"/systemd/*; do
    # Just for debug
    service_name=$(basename "$file")
    echo "Stopping and disabling: $service_name"
    sudo systemctl stop "$service_name".service >> /dev/null 2>&1
    sudo systemctl disable "$service_name".service >> /dev/null 2>&1
    sudo rm "/etc/systemd/system/$service_name.service" >> /dev/null 2>&1
    # ----------- #
    if [ ! -f /etc/systemd/system/$(basename $file) ]; then
      cp $file /etc/systemd/system/
    fi
    
  done
  
  chmod +x $conc_awg_path/app.py
  chmod +x $conc_awg_path/*.sh
  
  sudo systemctl daemon-reload
fi


services=("awgApp")
for service in "${services[@]}"; do
    echo "🔧 Managing service: $service"

    sudo systemctl enable "$service"

    if systemctl is-active --quiet "$service"; then
        echo "↻ Restarting $service (already running)"
        sudo systemctl restart "$service"
    else
        echo "▶️ Starting $service"
        sudo systemctl start "$service"
    fi
done

CRON_JOB="0 * * * * /usr/bin/systemctl restart awgApp >/dev/null 2>&1"
(crontab -l 2>/dev/null | grep -v -F "$CRON_JOB"; echo "$CRON_JOB") | crontab -

hostname -I
echo ""

exit 0
