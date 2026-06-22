#!/usr/bin/env bash
# ==============================================================================
# AnkaVM - Automated KVM & VDS Management System Installer for Ubuntu
# ==============================================================================
#
# This script installs and configures the AnkaVM daemon, Nginx reverse proxy,
# KVM virtualization dependencies, and security wrappers.
#
# Run as root or with sudo:
#   chmod +x install.sh
#   sudo ./install.sh
#
# ==============================================================================

# Exit immediately if a command exits with a non-zero status
set -e

# Visual formatting variables
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${CYAN}==================================================================${NC}"
echo -e "${CYAN}               ANKAVM AUTOMATED INSTALLATION ENGINE               ${NC}"
echo -e "${CYAN}==================================================================${NC}"
echo -e "Starting system verification and package provisioning...\n"

# Verify root privileges
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: This script must be run as root (use sudo).${NC}"
  exit 1
fi

# 1. Install virtualization and platform packages
echo -e "${YELLOW}[1/7] Installing KVM, QEMU and System Dependencies...${NC}"
apt-get update
apt-get install -y \
  qemu-kvm \
  libvirt-daemon-system \
  libvirt-clients \
  bridge-utils \
  virtinst \
  python3 \
  python3-pip \
  python3-venv \
  nginx \
  curl \
  util-linux

# Ensure libvirtd service is active
systemctl enable --now libvirtd
echo -e "${GREEN}✓ Hypervisor engines active.${NC}\n"

# 2. Provision restricted system user account
echo -e "${YELLOW}[2/7] Provisioning dedicated 'ankavm' system user...${NC}"
if ! id "ankavm" &>/dev/null; then
  useradd -r -s /usr/sbin/nologin -m -d /opt/ankavm ankavm
  echo -e "${GREEN}✓ System account 'ankavm' created.${NC}"
else
  echo -e "Account 'ankavm' already exists. Skipping."
fi

# Register user into virtualization groups
usermod -aG libvirt ankavm
usermod -aG kvm ankavm
echo -e "${GREEN}✓ Security groups configured.${NC}\n"

# 3. Create the secure sudo wrapper rules
echo -e "${YELLOW}[3/7] Setting up secure sudo wrapper limits...${NC}"
SUDOERS_FILE="/etc/sudoers.d/ankavm"

# Only allow the 'ankavm' user to execute specific KVM and virtual disk management operations
cat << 'EOF' > "$SUDOERS_FILE"
# Secure sudo command wrapper limits for AnkaVM VDS Manager
ankavm ALL=(root) NOPASSWD: /usr/bin/virsh *
ankavm ALL=(root) NOPASSWD: /usr/bin/qemu-img *
ankavm ALL=(root) NOPASSWD: /usr/bin/virt-install *
EOF

chmod 0440 "$SUDOERS_FILE"
echo -e "${GREEN}✓ Restricted sudo rules written to ${SUDOERS_FILE}.${NC}\n"

# 4. Deploy Application Files to /opt/ankavm
echo -e "${YELLOW}[4/7] Deploying application codebase to /opt/ankavm...${NC}"
mkdir -p /opt/ankavm

# Determine directory of this installer script and copy source
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cp -r "$PROJECT_ROOT/backend" /opt/ankavm/
cp -r "$PROJECT_ROOT/frontend" /opt/ankavm/
cp -r "$PROJECT_ROOT/nginx" /opt/ankavm/
cp -r "$PROJECT_ROOT/systemd" /opt/ankavm/

# Set permissions
chown -R ankavm:ankavm /opt/ankavm
echo -e "${GREEN}✓ Files deployed and ownership set.${NC}\n"

# 5. Initialize Python Virtual Environment & dependencies
echo -e "${YELLOW}[5/7] Constructing Python Virtual Environment...${NC}"
python3 -m venv /opt/ankavm/venv
/opt/ankavm/venv/bin/pip install --upgrade pip
/opt/ankavm/venv/bin/pip install -r /opt/ankavm/backend/requirements.txt
chown -R ankavm:ankavm /opt/ankavm/venv
echo -e "${GREEN}✓ Virtual environment dependencies installed.${NC}\n"

# 6. Deploy Systemd service unit
echo -e "${YELLOW}[6/7] Deploying systemd backend daemon...${NC}"
cp /opt/ankavm/systemd/ankavm.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now ankavm
echo -e "${GREEN}✓ Daemon service 'ankavm.service' enabled and running.${NC}\n"

# 7. Configure Nginx reverse proxy
echo -e "${YELLOW}[7/7] Installing Nginx Reverse Proxy...${NC}"
cp /opt/ankavm/nginx/ankavm.conf /etc/nginx/sites-available/ankavm
rm -f /etc/nginx/sites-enabled/ankavm
ln -s /etc/nginx/sites-available/ankavm /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Verify configurations and reload Nginx
nginx -t
systemctl restart nginx
echo -e "${GREEN}✓ Nginx reverse proxy active on port 80.${NC}\n"

# ==============================================================================
# Complete installation printout
# ==============================================================================
SERVER_IP=$(curl -s https://ifconfig.me || hostname -I | awk '{print $1}')

echo -e "${GREEN}==================================================================${NC}"
echo -e "${GREEN}                   INSTALLATION COMPLETE!                         ${NC}"
echo -e "${GREEN}==================================================================${NC}"
echo -e "AnkaVM VDS Management System is successfully configured and active."
echo -e ""
echo -e "Dashboard URL:      ${CYAN}http://${SERVER_IP}/${NC} (Port 80 Nginx Proxy)"
echo -e "Backend Server:     ${CYAN}http://${SERVER_IP}:8086/${NC}"
echo -e "API Access Key:     ${YELLOW}ankavm-secure-dev-token-2026${NC}"
echo -e ""
echo -e "Systemd command logs:      ${CYAN}journalctl -u ankavm.service -f${NC}"
echo -e "Nginx server logs:         ${CYAN}tail -f /var/log/nginx/access.log${NC}"
echo -e "=================================================================="
echo -e "System running on mock fallback? Check ${CYAN}/opt/ankavm/backend/config.py${NC}"
EOF
