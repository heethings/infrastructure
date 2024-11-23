#!/bin/bash

# Check if SSH key is provided
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <ssh_public_key>"
    echo "Example: $0 'ssh-rsa AAAA...'"
    exit 1
fi

SSH_USER="haproxy"
SSH_KEY="$1"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}Setting up secondary node...${NC}"

# Check if haproxy user exists and create if not
if ! id "$SSH_USER" &>/dev/null; then
    echo -e "${GREEN}Creating haproxy user...${NC}"
    sudo useradd -m -s /bin/bash $SSH_USER
    sudo passwd -l $SSH_USER
else
    echo -e "${GREEN}Configuring existing haproxy user...${NC}"
    sudo usermod -d /home/$SSH_USER -s /bin/bash $SSH_USER
fi

# Configure sudo permissions
echo -e "${GREEN}Configuring sudo permissions...${NC}"
sudo usermod -aG sudo $SSH_USER

# Ensure /etc/sudoers.d exists
if [ ! -d "/etc/sudoers.d" ]; then
    echo -e "${GREEN}Creating /etc/sudoers.d directory...${NC}"
    sudo mkdir -p /etc/sudoers.d
    sudo chmod 750 /etc/sudoers.d
fi

# Create sudoers file for haproxy user
SUDOERS_FILE="/etc/sudoers.d/$SSH_USER"
echo -e "${GREEN}Creating sudoers file: $SUDOERS_FILE${NC}"
echo "$SSH_USER ALL=(ALL) NOPASSWD: /usr/sbin/haproxy, /bin/systemctl reload haproxy, /bin/systemctl restart haproxy" | sudo tee "$SUDOERS_FILE" > /dev/null
sudo chmod 440 "$SUDOERS_FILE"

# Setup SSH directory
echo -e "${GREEN}Setting up SSH directory...${NC}"
sudo mkdir -p "/home/$SSH_USER/.ssh"
sudo chown -R $SSH_USER:$SSH_USER "/home/$SSH_USER"
sudo chmod 700 "/home/$SSH_USER/.ssh"
echo "$SSH_KEY" | sudo -u $SSH_USER tee "/home/$SSH_USER/.ssh/authorized_keys" > /dev/null
sudo chmod 600 "/home/$SSH_USER/.ssh/authorized_keys"

echo -e "${GREEN}Setup complete!${NC}"
