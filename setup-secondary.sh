#!/bin/bash

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if we have the required arguments
if [ "$#" -lt 2 ]; then
    echo "Usage: $0 SSH_USER SSH_PUBLIC_KEY"
    echo "Example: $0 haproxy 'ssh-rsa AAAA...'"
    exit 1
fi

SSH_USER="$1"
SSH_PUBLIC_KEY="$2"
SSH_DIR="/home/$SSH_USER/.ssh"

# Function to check and fix permissions
check_fix_permissions() {
    local path="$1"
    local expected_perms="$2"
    local current_perms=$(stat -c "%a" "$path")
    
    if [ "$current_perms" != "$expected_perms" ]; then
        echo -e "${YELLOW}Fixing permissions for $path (current: $current_perms, expected: $expected_perms)${NC}"
        chmod "$expected_perms" "$path"
        echo -e "${GREEN}✓ Fixed permissions for $path${NC}"
    else
        echo -e "${GREEN}✓ Permissions correct for $path ($expected_perms)${NC}"
    fi
}

# Create user if it doesn't exist
if ! id "$SSH_USER" &>/dev/null; then
    echo -e "${GREEN}Creating $SSH_USER user...${NC}"
    useradd -m -s /bin/bash "$SSH_USER"
    passwd -l "$SSH_USER"
else
    echo -e "${GREEN}User $SSH_USER already exists${NC}"
fi

# Add to sudo group (needed for HAProxy reload)
usermod -aG sudo "$SSH_USER"

# Configure sudo permissions
echo -e "${GREEN}Configuring sudo permissions...${NC}"
if [ ! -d "/etc/sudoers.d" ]; then
    mkdir -p /etc/sudoers.d
    chmod 750 /etc/sudoers.d
fi

SUDOERS_FILE="/etc/sudoers.d/$SSH_USER"
echo -e "${GREEN}Creating sudoers file: $SUDOERS_FILE${NC}"
cat << EOF | sudo tee "$SUDOERS_FILE" > /dev/null
$SSH_USER ALL=(ALL) NOPASSWD: /usr/sbin/haproxy, /bin/systemctl reload haproxy, /bin/systemctl restart haproxy
EOF
chmod 440 "$SUDOERS_FILE"

# Create .ssh directory if it doesn't exist
echo -e "${GREEN}Setting up SSH directory...${NC}"
mkdir -p "$SSH_DIR"
chown "$SSH_USER:$SSH_USER" "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Add the SSH public key
echo -e "${GREEN}Adding SSH public key...${NC}"
echo "$SSH_PUBLIC_KEY" > "$SSH_DIR/authorized_keys"
chown "$SSH_USER:$SSH_USER" "$SSH_DIR/authorized_keys"
chmod 644 "$SSH_DIR/authorized_keys"

# Verify the setup
echo -e "\n${GREEN}Verifying setup:${NC}"
echo -e "\n${YELLOW}SSH directory permissions:${NC}"
ls -la "$SSH_DIR"

echo -e "\n${YELLOW}Authorized keys content:${NC}"
cat "$SSH_DIR/authorized_keys"

echo -e "\n${YELLOW}Sudo access:${NC}"
cat "$SUDOERS_FILE"

echo -e "\n${YELLOW}SSH service status:${NC}"
systemctl status sshd --no-pager

echo -e "\n${GREEN}Setup complete!${NC}"
echo -e "${YELLOW}If you experience any issues, check:${NC}"
echo "1. SSH service status: systemctl status sshd"
echo "2. Firewall status: ufw status"
echo "3. SSH logs: tail -f /var/log/auth.log"
