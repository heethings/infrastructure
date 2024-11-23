#!/bin/bash

# Check if SSH key is provided
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <ssh_public_key>"
    echo "Example: $0 'ssh-rsa AAAA...'"
    exit 1
fi

SSH_USER="haproxy"
SSH_KEY="$1"
SSH_DIR="/home/$SSH_USER/.ssh"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to check and fix directory permissions
check_fix_permissions() {
    local path="$1"
    local expected_perm="$2"
    local type="$3"
    local current_perm=$(stat -c "%a" "$path")
    
    if [ "$current_perm" != "$expected_perm" ]; then
        echo -e "${YELLOW}Fixing $type permissions for $path ($current_perm -> $expected_perm)${NC}"
        chmod "$expected_perm" "$path"
    else
        echo -e "${GREEN}$type permissions correct for $path ($current_perm)${NC}"
    fi
}

echo -e "${GREEN}Setting up secondary node...${NC}"

# Check if haproxy user exists and create if not
if ! id "$SSH_USER" &>/dev/null; then
    echo -e "${GREEN}Creating haproxy user...${NC}"
    useradd -m -s /bin/bash $SSH_USER
    passwd -l $SSH_USER
else
    echo -e "${GREEN}Configuring existing haproxy user...${NC}"
    usermod -d /home/$SSH_USER -s /bin/bash $SSH_USER
fi

# Configure sudo permissions
echo -e "${GREEN}Configuring sudo permissions...${NC}"
usermod -aG sudo $SSH_USER

# Ensure /etc/sudoers.d exists with proper permissions
if [ ! -d "/etc/sudoers.d" ]; then
    echo -e "${GREEN}Creating /etc/sudoers.d directory...${NC}"
    mkdir -p /etc/sudoers.d
    chmod 750 /etc/sudoers.d
fi

# Create sudoers file for haproxy user
SUDOERS_FILE="/etc/sudoers.d/$SSH_USER"
echo -e "${GREEN}Creating sudoers file: $SUDOERS_FILE${NC}"
echo "$SSH_USER ALL=(ALL) NOPASSWD: /usr/sbin/haproxy, /bin/systemctl reload haproxy, /bin/systemctl restart haproxy" | tee "$SUDOERS_FILE" > /dev/null
chmod 440 "$SUDOERS_FILE"

# Setup SSH directory structure
echo -e "${GREEN}Setting up SSH directory structure...${NC}"

# Create and set permissions for SSH directory
if [ ! -d "$SSH_DIR" ]; then
    echo -e "${GREEN}Creating SSH directory...${NC}"
    mkdir -p "$SSH_DIR"
fi

# Set proper ownership for the entire home directory
echo -e "${GREEN}Setting proper ownership...${NC}"
chown -R $SSH_USER:$SSH_USER "/home/$SSH_USER"

# Set proper permissions for SSH directory and files
echo -e "${GREEN}Setting proper permissions...${NC}"
check_fix_permissions "$SSH_DIR" "700" "SSH directory"

# Create and configure authorized_keys
echo -e "${GREEN}Configuring authorized_keys...${NC}"
echo "$SSH_KEY" > "$SSH_DIR/authorized_keys"
chown $SSH_USER:$SSH_USER "$SSH_DIR/authorized_keys"
check_fix_permissions "$SSH_DIR/authorized_keys" "644" "authorized_keys file"

# Verify the setup
echo -e "\n${GREEN}Verifying setup:${NC}"
echo -e "${YELLOW}1. SSH directory permissions:${NC}"
ls -la "$SSH_DIR"
echo -e "\n${YELLOW}2. authorized_keys content:${NC}"
cat "$SSH_DIR/authorized_keys"
echo -e "\n${YELLOW}3. User sudo access:${NC}"
cat "$SUDOERS_FILE"
echo -e "\n${YELLOW}4. SSH service status:${NC}"
systemctl status sshd --no-pager

echo -e "\n${GREEN}Setup complete!${NC}"
echo -e "${YELLOW}If you experience connection issues, check:${NC}"
echo "1. SSH service is running: systemctl status sshd"
echo "2. Firewall allows SSH: sudo ufw status"
echo "3. SSH logs: sudo tail -f /var/log/auth.log"
