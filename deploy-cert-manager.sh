#!/bin/bash

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function for logging
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
    exit 1
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    error "Please run as root"
fi

# Create necessary directories
log "Creating necessary directories..."
mkdir -p /var/log/haproxy/cert-manager || error "Failed to create log directory"
mkdir -p /etc/haproxy/certs/backup || error "Failed to create certificate directories"

# Set proper permissions
log "Setting proper permissions..."
chown -R haproxy:haproxy /var/log/haproxy/cert-manager
chown -R haproxy:haproxy /etc/haproxy/certs
chmod 755 /etc/haproxy/certs
chmod 755 /etc/haproxy/certs/backup

# Install acme.sh if not already installed
if [ ! -f "/root/.acme.sh/acme.sh" ]; then
    log "Installing acme.sh..."
    curl https://get.acme.sh | sh || error "Failed to install acme.sh"
    
    # Configure acme.sh
    /root/.acme.sh/acme.sh --register-account -m admin@heethings.io || error "Failed to register acme.sh account"
fi

# Copy certificate manager script
log "Installing certificate manager script..."
cp cert-manager.sh /usr/local/bin/ || error "Failed to copy cert-manager script"
chmod +x /usr/local/bin/cert-manager.sh || error "Failed to set permissions on cert-manager script"

# Install systemd service and timer
log "Installing systemd service and timer..."
cp haproxy-cert-manager.service /etc/systemd/system/ || error "Failed to copy service file"
cp haproxy-cert-manager.timer /etc/systemd/system/ || error "Failed to copy timer file"

# Reload systemd and enable services
log "Configuring systemd..."
systemctl daemon-reload || error "Failed to reload systemd"
systemctl enable haproxy-cert-manager.timer || error "Failed to enable cert-manager timer"
systemctl start haproxy-cert-manager.timer || error "Failed to start cert-manager timer"

# Initial certificate request
log "Performing initial certificate request..."
/usr/local/bin/cert-manager.sh || error "Failed initial certificate request"

# Verify setup
log "Verifying setup..."
if systemctl is-active --quiet haproxy-cert-manager.timer; then
    log "Certificate manager timer is active"
else
    error "Certificate manager timer is not active"
fi

if [ -d "/etc/haproxy/certs" ] && [ -d "/var/log/haproxy/cert-manager" ]; then
    log "Directory structure is correct"
else
    error "Directory structure is incorrect"
fi

log "Certificate manager deployment completed successfully!"
log "Next certificate renewal will occur within 24 hours"
log "You can force a renewal by running: systemctl start haproxy-cert-manager.service"
