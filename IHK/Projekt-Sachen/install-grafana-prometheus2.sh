#!/bin/bash

################################################################################
# Grafana and Prometheus Installer for Ubuntu 24.04
# This script automates the installation and configuration of:
# - Grafana (with Nginx reverse proxy)
# - Prometheus
# - node_exporter
#
# Enhanced with comprehensive checks and error handling
################################################################################

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored messages
print_message() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_skip() {
    echo -e "${BLUE}[SKIP]${NC} $1"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    print_error "Please run this script as root or with sudo"
    exit 1
fi

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check if service exists
service_exists() {
    systemctl list-unit-files | grep -q "^$1.service"
}

# Function to check if user exists
user_exists() {
    id "$1" >/dev/null 2>&1
}

# Function to check if group exists
group_exists() {
    getent group "$1" >/dev/null 2>&1
}

# Function to check if directory exists
dir_exists() {
    [ -d "$1" ]
}

# Function to check if file exists
file_exists() {
    [ -f "$1" ]
}

# Function to prompt for user input
prompt_input() {
    local prompt_text=$1
    local default_value=$2
    local var_name=$3
    
    if [ -n "$default_value" ]; then
        read -p "$prompt_text [$default_value]: " input
        eval $var_name="${input:-$default_value}"
    else
        read -p "$prompt_text: " input
        eval $var_name="$input"
    fi
}

# Function to prompt for password
prompt_password() {
    local prompt_text=$1
    local var_name=$2
    
    read -sp "$prompt_text: " password
    echo
    read -sp "Confirm password: " password_confirm
    echo
    
    if [ "$password" != "$password_confirm" ]; then
        print_error "Passwords do not match!"
        exit 1
    fi
    
    eval $var_name="$password"
}

################################################################################
# Gather Configuration
################################################################################

print_message "=== Grafana and Prometheus Installation Configuration ==="
echo

prompt_input "Enter domain name for Grafana" "grafana.example.com" GRAFANA_DOMAIN
prompt_input "Enter Grafana HTTP port" "3000" GRAFANA_PORT
prompt_input "Enter Prometheus username" "admin" PROMETHEUS_USER
prompt_password "Enter Prometheus password" PROMETHEUS_PASS
prompt_input "Enter your server IP address" "127.0.0.1" SERVER_IP

echo
print_message "Configuration:"
print_message "  Grafana Domain: $GRAFANA_DOMAIN"
print_message "  Grafana Port: $GRAFANA_PORT"
print_message "  Prometheus User: $PROMETHEUS_USER"
print_message "  Server IP: $SERVER_IP"
echo
read -p "Continue with installation? (y/n): " confirm

if [[ ! $confirm =~ ^[Yy]$ ]]; then
    print_error "Installation cancelled"
    exit 1
fi

################################################################################
# Step 0: Install Essential Dependencies
################################################################################

print_message "Step 0: Checking and installing essential dependencies..."

apt update

# List of essential packages
ESSENTIAL_PACKAGES="gnupg2 apt-transport-https software-properties-common wget curl tar gzip"

for pkg in $ESSENTIAL_PACKAGES; do
    if dpkg -l | grep -q "^ii  $pkg "; then
        print_skip "$pkg is already installed"
    else
        print_message "Installing $pkg..."
        apt install -y $pkg
    fi
done

print_success "All essential dependencies are installed"

################################################################################
# Step 1: Add Grafana Repository
################################################################################

print_message "Step 1: Adding Grafana repository..."

# Check if Grafana repository already exists
if file_exists /etc/apt/sources.list.d/grafana.list; then
    print_skip "Grafana repository already exists"
else
    # Download and add Grafana GPG key
    if ! file_exists /etc/apt/trusted.gpg.d/grafana.gpg; then
        print_message "Adding Grafana GPG key..."
        wget -q -O - https://packages.grafana.com/gpg.key > /tmp/grafana.key
        cat /tmp/grafana.key | gpg --dearmor | tee /etc/apt/trusted.gpg.d/grafana.gpg > /dev/null
        rm -f /tmp/grafana.key
    else
        print_skip "Grafana GPG key already exists"
    fi

    # Add Grafana repository
    print_message "Adding Grafana repository to sources..."
    echo 'deb [signed-by=/etc/apt/trusted.gpg.d/grafana.gpg] https://packages.grafana.com/oss/deb stable main' | tee /etc/apt/sources.list.d/grafana.list
    
    # Update repository index
    apt update
fi

print_success "Grafana repository configured"

################################################################################
# Step 2: Install and Configure Grafana
################################################################################

print_message "Step 2: Installing and configuring Grafana..."

# Check if Grafana is already installed
if command_exists grafana-server; then
    print_skip "Grafana is already installed"
else
    print_message "Installing Grafana..."
    apt install -y grafana
fi

# Check if Grafana config file exists
if file_exists /etc/grafana/grafana.ini; then
    print_message "Configuring Grafana..."
    
    # Backup original config if not already backed up
    if ! file_exists /etc/grafana/grafana.ini.bak; then
        cp /etc/grafana/grafana.ini /etc/grafana/grafana.ini.bak
    fi
    
    # Configure Grafana
    sed -i "s/^;*http_addr =.*/http_addr = 127.0.0.1/" /etc/grafana/grafana.ini
    sed -i "s/^;*http_port =.*/http_port = $GRAFANA_PORT/" /etc/grafana/grafana.ini
    sed -i "s/^;*domain =.*/domain = $GRAFANA_DOMAIN/" /etc/grafana/grafana.ini
else
    print_error "Grafana configuration file not found!"
    exit 1
fi

# Reload systemd daemon
systemctl daemon-reload

# Start and enable Grafana service
if service_exists grafana-server; then
    systemctl start grafana-server || true
    systemctl enable grafana-server
    print_success "Grafana service started and enabled"
else
    print_error "Grafana service not found!"
    exit 1
fi

print_success "Grafana installed and configured"

################################################################################
# Step 3: Install and Configure Nginx
################################################################################

print_message "Step 3: Installing and configuring Nginx..."

# Check if Nginx is already installed
if command_exists nginx; then
    print_skip "Nginx is already installed"
else
    print_message "Installing Nginx..."
    apt install -y nginx
fi

# Create Nginx virtual host configuration
if file_exists /etc/nginx/conf.d/grafana.conf; then
    print_warning "Nginx Grafana configuration already exists, backing up and overwriting..."
    cp /etc/nginx/conf.d/grafana.conf /etc/nginx/conf.d/grafana.conf.bak.$(date +%s)
fi

print_message "Creating Nginx configuration for Grafana..."
cat > /etc/nginx/conf.d/grafana.conf << EOF
# This is required to proxy Grafana Live WebSocket connections.
map \$http_upgrade \$connection_upgrade {
  default upgrade;
  '' close;
}

server {
  listen      80;
  server_name $GRAFANA_DOMAIN;

  access_log /var/log/nginx/grafana-access.log;
  error_log /var/log/nginx/grafana-error.log;

  location / {
    proxy_set_header Host \$http_host;
    proxy_pass http://localhost:$GRAFANA_PORT/;
  }

  # Proxy Grafana Live WebSocket connections.
  location /api/live {
    rewrite  ^/(.*)\$  /\$1 break;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;
    proxy_set_header Host \$http_host;
    proxy_pass http://localhost:$GRAFANA_PORT/;
  }
}
EOF

# Test Nginx configuration
if nginx -t 2>/dev/null; then
    print_message "Nginx configuration is valid"
    systemctl restart nginx
    systemctl enable nginx
    print_success "Nginx configured and restarted"
else
    print_error "Nginx configuration test failed!"
    exit 1
fi

################################################################################
# Step 4: Install and Configure Prometheus
################################################################################

print_message "Step 4: Installing and configuring Prometheus..."

# Create Prometheus user and group if they don't exist
if group_exists prometheus; then
    print_skip "Prometheus group already exists"
else
    print_message "Creating prometheus group..."
    groupadd --system prometheus
fi

if user_exists prometheus; then
    print_skip "Prometheus user already exists"
else
    print_message "Creating prometheus user..."
    useradd -s /sbin/nologin --system -g prometheus prometheus
fi

# Create required directories if they don't exist
print_message "Creating Prometheus directories..."
mkdir -p /var/lib/prometheus
for i in rules rules.d files_sd; do 
    mkdir -p /etc/prometheus/${i}
done

# Check if Prometheus is already installed
if command_exists prometheus; then
    print_skip "Prometheus binary already exists"
    PROMETHEUS_VERSION=$(prometheus --version 2>&1 | head -n1)
    print_message "Current version: $PROMETHEUS_VERSION"
    read -p "Do you want to reinstall/update Prometheus? (y/n): " reinstall
    if [[ ! $reinstall =~ ^[Yy]$ ]]; then
        print_skip "Skipping Prometheus installation"
        SKIP_PROMETHEUS_INSTALL=true
    fi
fi

if [ "$SKIP_PROMETHEUS_INSTALL" != "true" ]; then
    # Download latest Prometheus
    print_message "Downloading latest Prometheus..."
    cd /tmp
    
    PROMETHEUS_URL=$(curl -s https://api.github.com/repos/prometheus/prometheus/releases/latest | grep browser_download_url | grep linux-amd64 | grep -v sha256 | cut -d '"' -f 4)
    
    if [ -z "$PROMETHEUS_URL" ]; then
        print_error "Failed to get Prometheus download URL"
        exit 1
    fi
    
    print_message "Downloading from: $PROMETHEUS_URL"
    wget -q --show-progress "$PROMETHEUS_URL" -O prometheus.tar.gz
    
    # Extract and install
    print_message "Extracting Prometheus..."
    tar xzf prometheus.tar.gz
    cd prometheus-*/
    
    # Stop Prometheus if running
    if service_exists prometheus; then
        systemctl stop prometheus || true
    fi
    
    mv prometheus promtool /usr/local/bin/
    
    # Only copy default config if one doesn't exist
    if ! file_exists /etc/prometheus/prometheus.yml; then
        mv prometheus.yml /etc/prometheus/
    fi
    
    print_success "Prometheus binaries installed"
fi

# Set permissions
print_message "Setting Prometheus permissions..."
for i in rules rules.d files_sd; do 
    chown -R prometheus:prometheus /etc/prometheus/${i}
    chmod -R 775 /etc/prometheus/${i}
done
chown -R prometheus:prometheus /var/lib/prometheus/

# Install Apache utils for htpasswd if not installed
if command_exists htpasswd; then
    print_skip "apache2-utils already installed"
else
    print_message "Installing apache2-utils..."
    apt install -y apache2-utils
fi

# Create Prometheus web configuration
print_message "Creating Prometheus authentication configuration..."
PROMETHEUS_HASH=$(htpasswd -nbB "$PROMETHEUS_USER" "$PROMETHEUS_PASS" | cut -d ":" -f 2)

cat > /etc/prometheus/web.yml << EOF
basic_auth_users:
  $PROMETHEUS_USER: $PROMETHEUS_HASH
EOF

chown prometheus:prometheus /etc/prometheus/web.yml
chmod 640 /etc/prometheus/web.yml

# Update Prometheus configuration
print_message "Updating Prometheus main configuration..."

# Backup existing config
if file_exists /etc/prometheus/prometheus.yml; then
    if ! file_exists /etc/prometheus/prometheus.yml.bak; then
        cp /etc/prometheus/prometheus.yml /etc/prometheus/prometheus.yml.bak
    fi
fi

cat > /etc/prometheus/prometheus.yml << EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: "prometheus"
    basic_auth:
      username: '$PROMETHEUS_USER'
      password: '$PROMETHEUS_PASS'
    static_configs:
      - targets: ["127.0.0.1:9090"]
EOF

chown prometheus:prometheus /etc/prometheus/prometheus.yml

print_success "Prometheus configured"

################################################################################
# Step 5: Create Prometheus Systemd Service
################################################################################

print_message "Step 5: Creating Prometheus systemd service..."

if service_exists prometheus; then
    print_skip "Prometheus service already exists, updating..."
fi

cat > /etc/systemd/system/prometheus.service << 'EOF'
[Unit]
Description=Prometheus
Documentation=https://prometheus.io/docs/introduction/overview/
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=prometheus
Group=prometheus
ExecReload=/bin/kill -HUP $MAINPID
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --web.listen-address=0.0.0.0:9090 \
  --web.config.file=/etc/prometheus/web.yml

SyslogIdentifier=prometheus
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and start Prometheus
systemctl daemon-reload
systemctl enable prometheus

if systemctl is-active --quiet prometheus; then
    print_message "Restarting Prometheus service..."
    systemctl restart prometheus
else
    print_message "Starting Prometheus service..."
    systemctl start prometheus
fi

# Wait a moment for service to start
sleep 2

if systemctl is-active --quiet prometheus; then
    print_success "Prometheus service is running"
else
    print_error "Prometheus service failed to start. Check logs with: journalctl -u prometheus -n 50"
fi

################################################################################
# Step 6: Install node_exporter
################################################################################

print_message "Step 6: Installing node_exporter..."

# Check if node_exporter is already installed
if command_exists node_exporter; then
    print_skip "node_exporter binary already exists"
    NODE_EXPORTER_VERSION=$(node_exporter --version 2>&1 | head -n1)
    print_message "Current version: $NODE_EXPORTER_VERSION"
    read -p "Do you want to reinstall/update node_exporter? (y/n): " reinstall
    if [[ ! $reinstall =~ ^[Yy]$ ]]; then
        print_skip "Skipping node_exporter installation"
        SKIP_NODE_EXPORTER_INSTALL=true
    fi
fi

if [ "$SKIP_NODE_EXPORTER_INSTALL" != "true" ]; then
    # Download latest node_exporter
    print_message "Downloading latest node_exporter..."
    cd /tmp
    
    NODE_EXPORTER_URL=$(curl -s https://api.github.com/repos/prometheus/node_exporter/releases/latest | grep browser_download_url | grep linux-amd64 | grep -v sha256 | cut -d '"' -f 4)
    
    if [ -z "$NODE_EXPORTER_URL" ]; then
        print_error "Failed to get node_exporter download URL"
        exit 1
    fi
    
    print_message "Downloading from: $NODE_EXPORTER_URL"
    wget -q --show-progress "$NODE_EXPORTER_URL" -O node_exporter.tar.gz
    
    # Extract and install
    print_message "Extracting node_exporter..."
    tar xzf node_exporter.tar.gz
    cd node_exporter-*/
    
    # Stop node_exporter if running
    if service_exists node_exporter; then
        systemctl stop node_exporter || true
    fi
    
    cp node_exporter /usr/local/bin/
    
    print_success "node_exporter binary installed"
fi

# Create systemd service
print_message "Creating node_exporter systemd service..."

if service_exists node_exporter; then
    print_skip "node_exporter service already exists, updating..."
fi

cat > /etc/systemd/system/node_exporter.service << EOF
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
ExecStart=/usr/local/bin/node_exporter

[Install]
WantedBy=default.target
EOF

# Reload systemd and start node_exporter
systemctl daemon-reload
systemctl enable node_exporter

if systemctl is-active --quiet node_exporter; then
    print_message "Restarting node_exporter service..."
    systemctl restart node_exporter
else
    print_message "Starting node_exporter service..."
    systemctl start node_exporter
fi

# Wait a moment for service to start
sleep 2

if systemctl is-active --quiet node_exporter; then
    print_success "node_exporter service is running"
else
    print_error "node_exporter service failed to start. Check logs with: journalctl -u node_exporter -n 50"
fi

################################################################################
# Step 7: Add node_exporter to Prometheus
################################################################################

print_message "Step 7: Adding node_exporter to Prometheus configuration..."

# Check if node_exporter job already exists in config
if grep -q "job_name.*node_exporter" /etc/prometheus/prometheus.yml; then
    print_skip "node_exporter job already exists in Prometheus config"
else
    # Append node_exporter job to Prometheus config
    cat >> /etc/prometheus/prometheus.yml << EOF

  - job_name: "node_exporter"
    static_configs:
      - targets: ["$SERVER_IP:9100"]
EOF
    
    print_message "node_exporter job added to Prometheus config"
    
    # Restart Prometheus to apply changes
    systemctl restart prometheus
    sleep 2
    print_success "Prometheus restarted with new configuration"
fi

################################################################################
# Installation Complete
################################################################################

echo
print_success "=========================================="
print_success "Installation completed successfully!"
print_success "=========================================="
echo
print_message "Access Information:"
print_message "  Grafana Web UI: http://$GRAFANA_DOMAIN"
print_message "  Default Grafana credentials: admin/admin (you'll be prompted to change)"
echo
print_message "  Prometheus Web UI: http://$SERVER_IP:9090"
print_message "  Prometheus credentials: $PROMETHEUS_USER / [your configured password]"
echo
print_message "Service Status:"
echo "Grafana:"
systemctl status grafana-server --no-pager | head -3
echo
echo "Nginx:"
systemctl status nginx --no-pager | head -3
echo
echo "Prometheus:"
systemctl status prometheus --no-pager | head -3
echo
echo "Node Exporter:"
systemctl status node_exporter --no-pager | head -3
echo
print_message "Next Steps:"
print_message "1. Configure your DNS to point $GRAFANA_DOMAIN to this server ($SERVER_IP)"
print_message "2. Access Grafana at http://$GRAFANA_DOMAIN and log in with admin/admin"
print_message "3. Add Prometheus as a data source in Grafana:"
print_message "   - URL: http://localhost:9090"
print_message "   - Auth: Basic Authentication"
print_message "   - User: $PROMETHEUS_USER"
print_message "   - Password: [your configured password]"
print_message "4. Import dashboard templates for node_exporter (Dashboard ID: 1860)"
print_message "5. Consider setting up SSL/TLS with Let's Encrypt for production use"
echo
print_warning "Security Notes:"
print_message "- Default Grafana password is 'admin'. You will be prompted to change it on first login."
print_message "- Prometheus is accessible on port 9090 with authentication"
print_message "- Consider restricting access with firewall rules (ufw/iptables)"
echo
print_message "Useful Commands:"
print_message "  Check logs: journalctl -u grafana-server -f"
print_message "  Check logs: journalctl -u prometheus -f"
print_message "  Check logs: journalctl -u node_exporter -f"
print_message "  Restart services: systemctl restart [grafana-server|prometheus|node_exporter]"
echo