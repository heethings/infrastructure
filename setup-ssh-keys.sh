#!/bin/bash

# Default values
DEFAULT_SSH_USER="haproxy"
DEFAULT_NODES=("10.0.0.12" "10.0.0.13")

# Configuration
SSH_USER="$DEFAULT_SSH_USER"
NODES=("${DEFAULT_NODES[@]}")

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Help message
usage() {
    echo "Usage: $0 [-h|--help] [-t|--test] [-u|--user SSH_USER] [-n|--nodes 'node1 node2 ...']"
    echo "Options:"
    echo "  -h, --help              Show this help message"
    echo "  -t, --test              Test SSH connections to secondary nodes"
    echo "  -u, --user SSH_USER     Specify the SSH user (default: $DEFAULT_SSH_USER)"
    echo "  -n, --nodes 'NODES'     Space-separated list of nodes (default: ${DEFAULT_NODES[*]})"
    echo
    echo "Example:"
    echo "  $0 --user myuser --nodes '192.168.1.10 192.168.1.11'"
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

# Function to test SSH connection with debugging
test_ssh_connection() {
    local node=$1
    echo -e "\nTesting connection to ${node}..."
    
    # Check if we can resolve the hostname
    if ! ping -c 1 $node >/dev/null 2>&1; then
        echo -e "${RED}✗ Cannot ping $node. Check if the node is reachable.${NC}"
        return 1
    fi
    
    # Create known_hosts file if it doesn't exist
    if [ ! -f "$SSH_KEY_PATH/known_hosts" ]; then
        touch "$SSH_KEY_PATH/known_hosts"
        chown $SSH_USER:$SSH_USER "$SSH_KEY_PATH/known_hosts"
        chmod 644 "$SSH_KEY_PATH/known_hosts"
    fi
    
    # First try a quiet connection
    SSH_CMD="ssh -q -o UserKnownHostsFile=$SSH_KEY_PATH/known_hosts -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 -i $SSH_KEY_PATH/id_rsa $node 'echo 2>/dev/null'"
    
    # Run the SSH command as the specified user
    if su - $SSH_USER -c "$SSH_CMD" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Successfully connected to ${node}${NC}"
        return 0
    else
        local exit_code=$?
        echo -e "${RED}✗ Failed to connect to ${node} (Exit code: $exit_code)${NC}"
        
        # Check common issues
        echo -e "\n${YELLOW}Checking for common issues:${NC}"
        
        # Check if private key exists
        if [ ! -f "$SSH_KEY_PATH/id_rsa" ]; then
            echo -e "${RED}- SSH private key not found at $SSH_KEY_PATH/id_rsa${NC}"
        fi
        
        # Check key permissions
        if [ -f "$SSH_KEY_PATH/id_rsa" ]; then
            local key_perms=$(stat -c "%a" "$SSH_KEY_PATH/id_rsa")
            if [ "$key_perms" != "600" ]; then
                echo -e "${RED}- Incorrect permissions on private key ($key_perms). Should be 600.${NC}"
                chmod 600 "$SSH_KEY_PATH/id_rsa"
                echo -e "${GREEN}- Fixed private key permissions${NC}"
            fi
        fi
        
        # Try to connect with verbose output only on failure
        echo -e "\n${YELLOW}Detailed connection attempt:${NC}"
        SSH_DEBUG_CMD="ssh -vvv -o UserKnownHostsFile=$SSH_KEY_PATH/known_hosts -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 -i $SSH_KEY_PATH/id_rsa $node 'echo 2>&1'"
        su - $SSH_USER -c "$SSH_DEBUG_CMD" 2>&1 | grep -v "debug1: " | grep -v "debug2: " || true
        
        # Show authorized_keys content on remote host if root access is available
        echo -e "\n${YELLOW}Checking authorized_keys on remote host:${NC}"
        ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 root@$node "cat /home/$SSH_USER/.ssh/authorized_keys" 2>/dev/null || echo -e "${RED}Could not check remote authorized_keys (requires root access)${NC}"
        
        return 1
    fi
}

# Function to test all connections
test_all_connections() {
    local failed=0
    echo -e "${YELLOW}Testing SSH connections to all secondary nodes...${NC}"
    
    # First, check local SSH setup
    echo -e "\n${YELLOW}Checking local SSH configuration:${NC}"
    if [ ! -d "$SSH_KEY_PATH" ]; then
        echo -e "${RED}- SSH directory not found at $SSH_KEY_PATH${NC}"
        failed=1
    else
        echo -e "${GREEN}- SSH directory exists${NC}"
        
        # Check SSH directory permissions
        local dir_perms=$(stat -c "%a" "$SSH_KEY_PATH")
        if [ "$dir_perms" != "700" ]; then
            echo -e "${RED}- Incorrect permissions on $SSH_KEY_PATH ($dir_perms). Should be 700.${NC}"
            failed=1
        else
            echo -e "${GREEN}- SSH directory permissions correct${NC}"
        fi
        
        # Check key existence and permissions
        if [ -f "$SSH_KEY_PATH/id_rsa" ]; then
            echo -e "${GREEN}- Private key exists${NC}"
            local key_perms=$(stat -c "%a" "$SSH_KEY_PATH/id_rsa")
            if [ "$key_perms" != "600" ]; then
                echo -e "${RED}- Incorrect permissions on private key ($key_perms). Should be 600.${NC}"
                chmod 600 "$SSH_KEY_PATH/id_rsa"
                echo -e "${GREEN}- Fixed private key permissions${NC}"
            else
                echo -e "${GREEN}- Private key permissions correct${NC}"
            fi
        else
            echo -e "${RED}- Private key not found${NC}"
            failed=1
        fi
    fi
    
    # Test connections to each node
    for node in "${NODES[@]}"; do
        if ! test_ssh_connection "$node"; then
            failed=1
        fi
    done
    
    if [ $failed -eq 0 ]; then
        echo -e "\n${GREEN}All connections successful!${NC}"
    else
        echo -e "\n${RED}Some connections failed. Please check the above error messages.${NC}"
        echo -e "${YELLOW}Common solutions:${NC}"
        echo "1. Verify that setup-secondary.sh was run successfully on the secondary nodes"
        echo "2. Check that the SSH key was properly copied to the secondary nodes"
        echo "3. Verify that the $SSH_USER user exists and has proper permissions on secondary nodes"
        echo "4. Check network connectivity between nodes"
        echo -e "\nTo verify the setup on secondary nodes, run these commands on each node:"
        echo "sudo ls -la /home/$SSH_USER/.ssh/authorized_keys"
        echo "sudo cat /home/$SSH_USER/.ssh/authorized_keys"
        echo "sudo systemctl status sshd"
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
            DO_TEST=1
            shift
            ;;
        -u|--user)
            SSH_USER="$2"
            shift 2
            ;;
        -n|--nodes)
            IFS=' ' read -r -a NODES <<< "$2"
            shift 2
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            usage
            ;;
    esac
done

# Update SSH_KEY_PATH based on SSH_USER
SSH_KEY_PATH="/home/$SSH_USER/.ssh"

# If test flag is set, run tests and exit
if [ -n "$DO_TEST" ]; then
    test_all_connections
fi

# Check if the specified user exists
if ! id "$SSH_USER" &>/dev/null; then
    echo -e "${GREEN}Creating $SSH_USER user...${NC}"
    # Create user with home directory and shell
    useradd -m -s /bin/bash $SSH_USER
    # Set password to disabled
    passwd -l $SSH_USER
else
    echo -e "${GREEN}Configuring existing $SSH_USER user...${NC}"
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

# Create sudoers file for the specified user
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
echo "curl -sSL https://raw.githubusercontent.com/heethings/infrastructure/refs/heads/main/setup-secondary.sh | sudo bash -s -- '$SSH_USER' '$PUBLIC_KEY'"
echo -e "\n${YELLOW}After setting up secondary nodes, test the connections with:${NC}"
echo "$0 --test --user $SSH_USER --nodes '${NODES[*]}'"
