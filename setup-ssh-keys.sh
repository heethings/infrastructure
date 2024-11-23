#!/bin/bash

# Configuration
SSH_USER="haproxy"
SSH_KEY_PATH="/home/$SSH_USER/.ssh"
NODES=(
    "10.0.0.12"  # Second HAProxy node
    "10.0.0.13"  # Third HAProxy node
)

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Help message
usage() {
    echo "Usage: $0 [-h|--help] [-t|--test]"
    echo "Options:"
    echo "  -h, --help    Show this help message"
    echo "  -t, --test    Test SSH connections to secondary nodes"
    exit 1
}

# Function to check if SSH key exists
check_ssh_key() {
    if [ ! -f "$SSH_KEY_PATH/id_rsa" ]; then
        echo -e "${RED}No SSH key found. Generating new key...${NC}"
        su - $SSH_USER -c "ssh-keygen -t rsa -b 4096 -f $SSH_KEY_PATH/id_rsa -N ''"
    else
        echo -e "${GREEN}SSH key already exists${NC}"
    fi
}

# Function to test SSH connection
test_ssh_connection() {
    local node=$1
    echo -e "\nTesting connection to ${node}..."
    if ssh -o BatchMode=yes -o ConnectTimeout=5 $SSH_USER@${node} 'echo 2>&1' >/dev/null; then
        echo -e "${GREEN}✓ Successfully connected to ${node}${NC}"
        return 0
    else
        echo -e "${RED}✗ Failed to connect to ${node}${NC}"
        return 1
    fi
}

# Function to test all connections
test_all_connections() {
    local failed=0
    echo -e "${YELLOW}Testing SSH connections to all secondary nodes...${NC}"
    for node in "${NODES[@]}"; do
        if ! test_ssh_connection "$node"; then
            failed=1
        fi
    done
    
    if [ $failed -eq 0 ]; then
        echo -e "\n${GREEN}All connections successful!${NC}"
    else
        echo -e "\n${RED}Some connections failed. Please check the configuration on failed nodes.${NC}"
        echo -e "${YELLOW}Make sure you have run setup-secondary.sh with the correct SSH key on those nodes.${NC}"
    fi
    exit $failed
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            ;;
        -t|--test)
            test_all_connections
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            usage
            ;;
    esac
    shift
done

# Check if haproxy user exists
if ! id "$SSH_USER" &>/dev/null; then
    echo -e "${GREEN}Creating haproxy user...${NC}"
    # Create user with home directory and shell
    useradd -m -s /bin/bash $SSH_USER
    # Set password to disabled
    passwd -l $SSH_USER
else
    echo -e "${GREEN}Configuring existing haproxy user...${NC}"
fi

# Ensure home directory exists and has correct permissions
if [ ! -d "/home/$SSH_USER" ]; then
    echo -e "${GREEN}Creating home directory for $SSH_USER...${NC}"
    mkdir -p "/home/$SSH_USER"
fi
chown $SSH_USER:$SSH_USER "/home/$SSH_USER"
usermod -d "/home/$SSH_USER" -s /bin/bash $SSH_USER

# Add to sudo group (needed for HAProxy reload)
usermod -aG sudo $SSH_USER

# Configure sudo permissions
echo -e "${GREEN}Configuring sudo permissions...${NC}"
# Ensure /etc/sudoers.d exists
if [ ! -d "/etc/sudoers.d" ]; then
    echo -e "${GREEN}Creating /etc/sudoers.d directory...${NC}"
    mkdir -p /etc/sudoers.d
    chmod 750 /etc/sudoers.d
fi

# Create sudoers file for haproxy user
SUDOERS_FILE="/etc/sudoers.d/$SSH_USER"
echo -e "${GREEN}Creating sudoers file: $SUDOERS_FILE${NC}"
cat << EOF | sudo tee "$SUDOERS_FILE" > /dev/null
$SSH_USER ALL=(ALL) NOPASSWD: /usr/sbin/haproxy, /bin/systemctl reload haproxy, /bin/systemctl restart haproxy
EOF
chmod 440 "$SUDOERS_FILE"

# Create .ssh directory
mkdir -p $SSH_KEY_PATH
chown $SSH_USER:$SSH_USER $SSH_KEY_PATH
chmod 700 $SSH_KEY_PATH

# Generate SSH key if it doesn't exist
check_ssh_key

# Get and output the public key
PUBLIC_KEY=$(cat $SSH_KEY_PATH/id_rsa.pub)
echo -e "\n${GREEN}Your SSH public key:${NC}"
echo "$PUBLIC_KEY"
echo -e "\n${GREEN}Run this command on secondary nodes:${NC}"
echo "curl -sSL https://raw.githubusercontent.com/heethings/infrastructure/refs/heads/main/setup-secondary.sh | sudo bash -s -- '$(echo "$PUBLIC_KEY")'"
echo -e "\n${YELLOW}After setting up secondary nodes, test the connections with:${NC}"
echo "$0 --test"
