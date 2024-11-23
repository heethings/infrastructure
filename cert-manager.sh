#!/bin/bash

# Configuration
DOMAINS=(
    "auth.heethings.io"
    "api.heethings.io"
    "lb.heethings.io"
    "lb.performans.com"
)
EMAIL="admin@heethings.io"
HAPROXY_CERT_DIR="/etc/haproxy/certs"
BACKUP_DIR="/etc/haproxy/certs/backup"
LOG_DIR="/var/log/haproxy/cert-manager"
LOG_FILE="$LOG_DIR/cert-manager.log"

# HAProxy user and group
HAPROXY_USER="haproxy"
HAPROXY_GROUP="haproxy"

# Secondary HAProxy nodes
SECONDARY_NODES=(
    "lb-02"
    "lb-03"
)

# SSH Configuration
SSH_USER="haproxy"
SSH_KEY="/home/haproxy/.ssh/id_rsa"
MAX_RETRIES=3
RETRY_DELAY=5

# Email Configuration
ENABLE_SMTP=false  # Set to true to enable email notifications
SMTP_SERVER="smtp.heethings.io"
SMTP_PORT="587"
SMTP_USER="notifications@heethings.io"
SMTP_PASS="your-smtp-password"
NOTIFICATION_EMAIL="admin@heethings.io"

# Ensure directories exist
mkdir -p $HAPROXY_CERT_DIR $BACKUP_DIR $LOG_DIR

# Initialize log file
touch $LOG_FILE
chmod 640 $LOG_FILE

# Logging function
log() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> $LOG_FILE
    
    # Print to stdout if not running in cron
    if [ -t 1 ]; then
        echo "[$timestamp] [$level] $message"
    fi
}

# Email notification function
send_notification() {
    local subject=$1
    local message=$2
    
    if [ "$ENABLE_SMTP" = "true" ]; then
        echo "$message" | mail -s "$subject" \
            -S smtp="$SMTP_SERVER:$SMTP_PORT" \
            -S smtp-use-starttls \
            -S smtp-auth=login \
            -S smtp-auth-user="$SMTP_USER" \
            -S smtp-auth-password="$SMTP_PASS" \
            $NOTIFICATION_EMAIL
        
        if [ $? -eq 0 ]; then
            log "INFO" "Email notification sent: $subject"
        else
            log "ERROR" "Failed to send email notification: $subject"
        fi
    else
        log "DEBUG" "Email notifications are disabled. Would have sent: $subject"
    fi
}

# Backup function
backup_cert() {
    local domain=$1
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_path="$BACKUP_DIR/${domain}_${timestamp}.pem"
    
    if [ -f "$HAPROXY_CERT_DIR/$domain.pem" ]; then
        cp "$HAPROXY_CERT_DIR/$domain.pem" "$backup_path"
        log "INFO" "Backed up certificate for $domain to $backup_path"
        
        # Keep only last 5 backups
        ls -t "$BACKUP_DIR/${domain}_"* 2>/dev/null | tail -n +6 | xargs -r rm
    fi
}

# Function to sync certificates to secondary nodes with retry
sync_certificates() {
    local domain=$1
    local cert_file="$HAPROXY_CERT_DIR/$domain.pem"
    local retry_count=0
    local sync_status=0
    
    for node in "${SECONDARY_NODES[@]}"; do
        retry_count=0
        sync_status=1
        
        while [ $retry_count -lt $MAX_RETRIES ] && [ $sync_status -ne 0 ]; do
            log "INFO" "Attempting to sync certificates to $node (attempt $((retry_count + 1)))"
            
            # Create remote directory if it doesn't exist and set permissions
            ssh -i $SSH_KEY $SSH_USER@$node "sudo mkdir -p $HAPROXY_CERT_DIR && sudo chown $HAPROXY_USER:$HAPROXY_GROUP $HAPROXY_CERT_DIR && sudo chmod 755 $HAPROXY_CERT_DIR" &>/dev/null
            
            # Copy certificate
            scp -i $SSH_KEY "$cert_file" "$SSH_USER@$node:/tmp/$domain.pem" &>/dev/null
            
            # Move certificate to final location and set proper ownership and permissions
            ssh -i $SSH_KEY $SSH_USER@$node "sudo mv /tmp/$domain.pem $HAPROXY_CERT_DIR/$domain.pem && sudo chown $HAPROXY_USER:$HAPROXY_GROUP $HAPROXY_CERT_DIR/$domain.pem && sudo chmod 644 $HAPROXY_CERT_DIR/$domain.pem && sudo systemctl reload haproxy" &>/dev/null
            
            sync_status=$?
            
            if [ $sync_status -eq 0 ]; then
                log "INFO" "Successfully synced certificates to $node"
                break
            else
                retry_count=$((retry_count + 1))
                log "WARN" "Failed to sync certificates to $node, attempt $retry_count of $MAX_RETRIES"
                
                if [ $retry_count -lt $MAX_RETRIES ]; then
                    sleep $RETRY_DELAY
                fi
            fi
        done
        
        if [ $sync_status -ne 0 ]; then
            log "ERROR" "Failed to sync certificates to $node after $MAX_RETRIES attempts"
            send_notification "Certificate Sync Failed" "Failed to sync certificates for $domain to $node after $MAX_RETRIES attempts"
        fi
    done
}

# Function to check if this is the primary node
is_primary_node() {
    # Check if this node has the private VIP
    ip addr show | grep -q "10.0.0.10"
    return $?
}

# Function to create/renew certificate
create_or_renew_cert() {
    local domain=$1
    
    # Only run acme.sh on the primary node
    if is_primary_node; then
        log "INFO" "Starting certificate renewal process for $domain"
        
        # Backup existing certificate
        backup_cert $domain
        
        # Issue/renew certificate using ALPN validation
        $HOME/.acme.sh/acme.sh --issue \
            -d $domain \
            --alpn \
            --keylength 2048 \
            --server letsencrypt \
            --reloadcmd "systemctl reload haproxy" \
            --log $LOG_FILE
            
        if [ $? -ne 0 ]; then
            log "ERROR" "Failed to issue/renew certificate for $domain"
            send_notification "Certificate Renewal Failed" "Failed to issue/renew certificate for $domain"
            return 1
        fi
        
        # Install certificate for HAProxy
        $HOME/.acme.sh/acme.sh --install-cert -d $domain \
            --key-file "$HAPROXY_CERT_DIR/$domain.key" \
            --fullchain-file "$HAPROXY_CERT_DIR/$domain.crt" \
            --reloadcmd "cat $HAPROXY_CERT_DIR/$domain.crt $HAPROXY_CERT_DIR/$domain.key > $HAPROXY_CERT_DIR/$domain.pem && systemctl reload haproxy" \
            --log $LOG_FILE
            
        if [ $? -ne 0 ]; then
            log "ERROR" "Failed to install certificate for $domain"
            send_notification "Certificate Installation Failed" "Failed to install certificate for $domain"
            return 1
        fi
        
        # Set proper permissions
        chmod 644 "$HAPROXY_CERT_DIR/$domain.pem"
        
        # Sync to secondary nodes
        sync_certificates $domain
        
        log "INFO" "Certificate renewal process completed successfully for $domain"
        send_notification "Certificate Renewal Success" "Successfully renewed and deployed certificate for $domain"
    fi
}

# Cleanup old log files (keep last 30 days)
find $LOG_DIR -name "*.log" -mtime +30 -delete

# Process each domain
for domain in "${DOMAINS[@]}"; do
    create_or_renew_cert $domain
done

# Rotate log file if it's too large (>10MB)
if [ -f "$LOG_FILE" ] && [ $(stat -f%z "$LOG_FILE") -gt 10485760 ]; then
    mv "$LOG_FILE" "$LOG_FILE.$(date '+%Y%m%d')"
    touch "$LOG_FILE"
    chmod 640 "$LOG_FILE"
fi
