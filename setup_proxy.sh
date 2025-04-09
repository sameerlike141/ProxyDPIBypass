#!/bin/bash

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run this script as root (use sudo).${NC}"
  exit 1
fi

# Function to install everything
install_setup() {
  echo -e "${GREEN}Starting installation...${NC}"

  # Ask for server type
  echo "Is this the Transit Server (China) or Login Server (HK/JP/KR/SG/US)? (transit/login)"
  read -p "Enter choice: " server_type

  # Ask for domain
  echo "Please enter the domain name for this server (e.g., transit.example.com or login.example.com):"
  read -p "Domain: " domain

  # Ask for email for Certbot
  echo "Please enter your email for Let's Encrypt certificate:"
  read -p "Email: " email

  # Update system
  apt update -y

  if [ "$server_type" == "transit" ]; then
    # Install Nginx
    apt install nginx -y

    # Install Certbot
    apt install certbot python3-certbot-nginx -y
    certbot --nginx -d "$domain" --non-interactive --agree-tos --email "$email"

    # Configure Nginx
    cat > /etc/nginx/sites-available/"$domain" <<EOF
server {
    listen 443 ssl;
    server_name $domain;
    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    ssl_protocols TLSv1.3;
    location / {
        proxy_pass http://127.0.0.1:8443;
        proxy_set_header Host \$host;
    }
}
EOF
    ln -s /etc/nginx/sites-available/"$domain" /etc/nginx/sites-enabled/
    nginx -t && systemctl restart nginx

    # Ask for login server domain
    echo "Please enter the login server domain (e.g., login.example.com):"
    read -p "Login Domain: " login_domain

    # Install GOST
    wget -q https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz
    gunzip gost-linux-amd64-2.11.5.gz
    chmod +x gost-linux-amd64-2.11.5
    mv gost-linux-amd64-2.11.5 /usr/local/bin/gost

    # Configure GOST
    mkdir -p /etc/gost
    cat > /etc/gost/config.yaml <<EOF
services:
  - name: transit
    addr: :8443
    handler:
      type: tcp
      chain: to-login
    listener:
      type: tcp
chains:
  - name: to-login
    hops:
      - name: hop0
        nodes:
          - name: login
            addr: $login_domain:443
            connector:
              type: http2
            dialer:
              type: tls
EOF
    # Create GOST service
    cat > /etc/systemd/system/gost.service <<EOF
[Unit]
Description=GOST Transit Service
After=network.target
[Service]
ExecStart=/usr/local/bin/gost -C /etc/gost/config.yaml
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable gost
    systemctl start gost

  elif [ "$server_type" == "login" ]; then
    # Install Certbot
    apt install certbot -y
    certbot certonly --standalone -d "$domain" --non-interactive --agree-tos --email "$email"

    # Install GOST
    wget -q https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz
    gunzip gost-linux-amd64-2.11.5.gz
    chmod +x gost-linux-amd64-2.11.5
    mv gost-linux-amd64-2.11.5 /usr/local/bin/gost

    # Configure GOST
    mkdir -p /etc/gost
    cat > /etc/gost/config.yaml <<EOF
services:
  - name: login
    addr: :443
    handler:
      type: tcp
      forwarder:
        nodes:
          - name: mtproxy
            addr: 127.0.0.1:8888
    listener:
      type: tls
      metadata:
        cert: /etc/letsencrypt/live/$domain/fullchain.pem
        key: /etc/letsencrypt/live/$domain/privkey.pem
EOF
    # Create GOST service
    cat > /etc/systemd/system/gost.service <<EOF
[Unit]
Description=GOST Login Service
After=network.target
[Service]
ExecStart=/usr/local/bin/gost -C /etc/gost/config.yaml
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable gost
    systemctl start gost

    # Install MTProxy
    apt install git build-essential -y
    git clone https://github.com/TelegramMessenger/MTProxy.git
    cd MTProxy
    make
    cd ..
    mv MTProxy /opt/MTProxy
    SECRET=$(head -c 16 /dev/urandom | xxd -ps)
    echo "Your MTProxy secret is: dd$SECRET (use this in Telegram with 'dd' prefix for padding)"
    /opt/MTProxy/mtproto-proxy -u nobody -p 8888 -H 443 -S "$SECRET" --aes-pwd /opt/MTProxy/proxy-secret /opt/MTProxy/proxy-multi.conf -M 1 &

    # Create MTProxy service
    cat > /etc/systemd/system/mtproxy.service <<EOF
[Unit]
Description=MTProxy Service
After=network.target
[Service]
WorkingDirectory=/opt/MTProxy
ExecStart=/opt/MTProxy/mtproto-proxy -u nobody -p 8888 -H 443 -S $SECRET --aes-pwd proxy-secret proxy-multi.conf -M 1
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable mtproxy
    systemctl start mtproxy
  else
    echo -e "${RED}Invalid server type. Use 'transit' or 'login'.${NC}"
    exit 1
  fi

  echo -e "${GREEN}Installation completed!${NC}"
}

# Function to remove everything
remove_setup() {
  echo -e "${GREEN}Starting removal...${NC}"
  echo "Are you sure you want to remove everything? (yes/no)"
  read -p "Choice: " confirm

  if [ "$confirm" == "yes" ]; then
    # Stop and disable services
    systemctl stop gost 2>/dev/null
    systemctl disable gost 2>/dev/null
    systemctl stop mtproxy 2>/dev/null
    systemctl disable mtproxy 2>/dev/null
    systemctl stop nginx 2>/dev/null
    systemctl disable nginx 2>/dev/null

    # Remove files
    rm -rf /etc/systemd/system/gost.service
    rm -rf /etc/systemd/system/mtproxy.service
    rm -rf /etc/gost
    rm -rf /usr/local/bin/gost
    rm -rf /opt/MTProxy
    rm -rf /etc/nginx/sites-available/* /etc/nginx/sites-enabled/*
    rm -rf /etc/letsencrypt

    # Uninstall packages
    apt purge -y nginx certbot python3-certbot-nginx git build-essential
    apt autoremove -y

    systemctl daemon-reload
    echo -e "${GREEN}Everything has been removed!${NC}"
  else
    echo -e "${GREEN}Removal canceled.${NC}"
  fi
}

# Main menu
echo -e "${GREEN}Welcome to Proxy Setup Script${NC}"
echo "1. Install"
echo "2. Remove"
read -p "Select an option (1 or 2): " choice

case $choice in
  1)
    install_setup
    ;;
  2)
    remove_setup
    ;;
  *)
    echo -e "${RED}Invalid option. Please select 1 or 2.${NC}"
    exit 1
    ;;
esac
