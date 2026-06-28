import os

workspace_root = r"c:\Users\Administrator\Desktop\ankavm"
output_script = os.path.join(workspace_root, "scripts", "install.sh")

# List of files to embed, as (workspace_relative_path, target_path_on_destination)
files_to_embed = [
    ("backend/requirements.txt", "/opt/ankavm/backend/requirements.txt"),
    ("backend/config.py", "/opt/ankavm/backend/config.py"),
    ("backend/schemas.py", "/opt/ankavm/backend/schemas.py"),
    ("backend/cloud_init.py", "/opt/ankavm/backend/cloud_init.py"),
    ("backend/ipam.py", "/opt/ankavm/backend/ipam.py"),
    ("backend/vm_manager.py", "/opt/ankavm/backend/vm_manager.py"),
    ("backend/main.py", "/opt/ankavm/backend/main.py"),
    ("backend/license_check.py", "/opt/ankavm/backend/license_check.py"),
    ("backend/license_server.py", "/opt/ankavm/backend/license_server.py"),
    ("scripts/auto_repair_daemon.py", "/opt/ankavm/scripts/auto_repair_daemon.py"),
    ("frontend/style.css", "/opt/ankavm/frontend/style.css"),
    ("frontend/fetch_helpers.js", "/opt/ankavm/frontend/fetch_helpers.js"),
    ("frontend/app.js", "/opt/ankavm/frontend/app.js"),
    ("frontend/index.html", "/opt/ankavm/frontend/index.html"),
    ("nginx/ankavm.conf", "/opt/ankavm/nginx/ankavm.conf"),
    ("systemd/ankavm.service", "/opt/ankavm/systemd/ankavm.service"),
]

installer_header = """#!/usr/bin/env bash
# ==============================================================================
# AnkaVM - Production-Ready Self-Contained Automated Installer for Ubuntu
# ==============================================================================
#
# This single script contains the entire application codebase (FastAPI backend,
# license check clients, watchdog auto-repair daemons, frontend portal, Nginx proxy).
# It will automatically write all files and configure KVM virtualization.
#
# Run as root or with sudo:
#   chmod +x install.sh
#   sudo ./install.sh
#
# ==============================================================================

set -e

# Visual formatting variables
RED='\\033[0;31m'
GREEN='\\033[0;32m'
CYAN='\\033[0;36m'
YELLOW='\\033[1;33m'
NC='\\033[0m' # No Color

echo -e "${CYAN}==================================================================${NC}"
echo -e "${CYAN}             ANKAVM SELF-CONTAINED INSTALLATION ENGINE            ${NC}"
echo -e "${CYAN}==================================================================${NC}"
echo -e "Starting system provisioning and file deployment...\\n"

# Verify root privileges
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: This script must be run as root (use sudo).${NC}"
  exit 1
fi

# 1. Install virtualization and platform packages
echo -e "${YELLOW}[1/7] Installing KVM, QEMU and System Dependencies...${NC}"
apt-get update
apt-get install -y \\
  qemu-kvm \\
  libvirt-daemon-system \\
  libvirt-clients \\
  bridge-utils \\
  virtinst \\
  python3 \\
  python3-pip \\
  python3-venv \\
  nginx \\
  curl \\
  util-linux \\
  genisoimage \\
  vnstat

# Ensure libvirtd service is active
systemctl enable --now libvirtd
systemctl enable --now vnstat
echo -e "${GREEN}✓ Hypervisor and monitoring engines active.${NC}\\n"

# 2. Provision dedicated system user
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
echo -e "${GREEN}✓ Security groups configured.${NC}\\n"

# 3. Create the secure sudo wrapper rules
echo -e "${YELLOW}[3/7] Setting up secure KVM sudo wrapper rules...${NC}"
SUDOERS_FILE="/etc/sudoers.d/ankavm"
cat << 'EOF' > "$SUDOERS_FILE"
# Secure sudo command wrapper limits for AnkaVM VDS Manager
ankavm ALL=(root) NOPASSWD: /usr/bin/virsh *
ankavm ALL=(root) NOPASSWD: /usr/bin/qemu-img *
ankavm ALL=(root) NOPASSWD: /usr/bin/virt-install *
ankavm ALL=(root) NOPASSWD: /sbin/vgs *
ankavm ALL=(root) NOPASSWD: /sbin/lvs *
ankavm ALL=(root) NOPASSWD: /sbin/lvcreate *
ankavm ALL=(root) NOPASSWD: /sbin/lvremove *
ankavm ALL=(root) NOPASSWD: /sbin/lvresize *
ankavm ALL=(root) NOPASSWD: /sbin/zpool *
ankavm ALL=(root) NOPASSWD: /sbin/zfs *
EOF
chmod 0440 "$SUDOERS_FILE"
echo -e "${GREEN}✓ Sudo wrapper limits written to $SUDOERS_FILE.${NC}\\n"

# 4. Deploy codebase dynamically from script payload
echo -e "${YELLOW}[4/7] Deploying application codebase to /opt/ankavm...${NC}"
mkdir -p /opt/ankavm/backend
mkdir -p /opt/ankavm/frontend
mkdir -p /opt/ankavm/nginx
mkdir -p /opt/ankavm/systemd
mkdir -p /opt/ankavm/scripts

"""

installer_footer = """
# Write systemd watchdog service
cat << '_ANKAVM_EOF_' > /opt/ankavm/systemd/ankavm-watchdog.service
[Unit]
Description=AnkaVM KVM Auto-Repair Watchdog Daemon
After=network.target libvirtd.service
Requires=libvirtd.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/ankavm
ExecStart=/usr/bin/python3 /opt/ankavm/scripts/auto_repair_daemon.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
_ANKAVM_EOF_

# Write systemd local licensing server service
cat << '_ANKAVM_EOF_' > /opt/ankavm/systemd/ankavm-licensing.service
[Unit]
Description=AnkaVM Local Licensing Authority Server
After=network.target

[Service]
Type=simple
User=ankavm
Group=ankavm
WorkingDirectory=/opt/ankavm
Environment=PATH=/opt/ankavm/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/opt/ankavm/venv/bin/python3 /opt/ankavm/backend/license_server.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
_ANKAVM_EOF_

# Set permissions
chmod +x /opt/ankavm/scripts/auto_repair_daemon.py
chown -R ankavm:ankavm /opt/ankavm
echo -e "${GREEN}✓ Codebase files written and ownership set.${NC}\\n"

# 5. Initialize Python Virtual Environment & dependencies
echo -e "${YELLOW}[5/7] Constructing Python Virtual Environment...${NC}"
python3 -m venv /opt/ankavm/venv
/opt/ankavm/venv/bin/pip install --upgrade pip
/opt/ankavm/venv/bin/pip install -r /opt/ankavm/backend/requirements.txt
chown -R ankavm:ankavm /opt/ankavm/venv
echo -e "${GREEN}✓ Virtual environment dependencies installed.${NC}\\n"

# 6. Deploy Systemd service units
echo -e "${YELLOW}[6/7] Deploying systemd daemon controllers...${NC}"
cp /opt/ankavm/systemd/ankavm.service /etc/systemd/system/
cp /opt/ankavm/systemd/ankavm-watchdog.service /etc/systemd/system/
cp /opt/ankavm/systemd/ankavm-licensing.service /etc/systemd/system/

systemctl daemon-reload

# Start licensing server first, then the main backend and watchdog
systemctl enable --now ankavm-licensing
systemctl enable --now ankavm
systemctl enable --now ankavm-watchdog

echo -e "${GREEN}✓ All daemon controllers enabled and running.${NC}\\n"

# 7. Configure Nginx reverse proxy
echo -e "${YELLOW}[7/7] Installing Nginx Reverse Proxy...${NC}"
cp /opt/ankavm/nginx/ankavm.conf /etc/nginx/sites-available/ankavm
rm -f /etc/nginx/sites-enabled/ankavm
ln -s /etc/nginx/sites-available/ankavm /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Verify configurations and reload Nginx
if nginx -t; then
  systemctl restart nginx
  echo -e "${GREEN}✓ Nginx reverse proxy active on port 80.${NC}\\n"
else
  echo -e "${RED}Warning: Nginx configuration test failed. Please check /etc/nginx/sites-available/ankavm${NC}\\n"
fi

# ==============================================================================
# Complete installation printout
# ==============================================================================
SERVER_IP=$(curl -s https://ifconfig.me || hostname -I | awk '{print $1}')

echo -e "${GREEN}==================================================================${NC}"
echo -e "${GREEN}                   INSTALLATION COMPLETE!                         ${NC}"
echo -e "${GREEN}==================================================================${NC}"
echo -e "AnkaVM VDS Virtualization Platform is successfully configured and active."
echo -e ""
echo -e "Dashboard URL:      ${CYAN}http://${SERVER_IP}/${NC} (Port 80 Nginx Proxy)"
echo -e "Backend Server:     ${CYAN}http://${SERVER_IP}:8086/${NC}"
echo -e "License server:     ${CYAN}http://127.0.0.1:8087/verify${NC}"
echo -e "API Access Key:     ${YELLOW}ankavm-secure-dev-token-2026${NC}"
echo -e "Default Lic Key:    ${YELLOW}ANKAVM-PRO-SAAS-9999-KEY${NC}"
echo -e ""
echo -e "Watchdog logs:      ${CYAN}journalctl -u ankavm-watchdog.service -f${NC}"
echo -e "Licensing logs:     ${CYAN}journalctl -u ankavm-licensing.service -f${NC}"
echo -e "Backend API logs:   ${CYAN}journalctl -u ankavm.service -f${NC}"
echo -e "=================================================================="
echo -e "System running on mock fallback? Check ${CYAN}/opt/ankavm/backend/config.py${NC}"
"""

# Ensure scripts directory exists
os.makedirs(os.path.dirname(output_script), exist_ok=True)

with open(output_script, "w", encoding="utf-8", newline="\n") as out:
    out.write(installer_header)
    
    for rel_path, dest_path in files_to_embed:
        full_src_path = os.path.join(workspace_root, rel_path.replace("/", os.sep))
        print(f"Embedding {full_src_path} -> {dest_path}...")
        
        with open(full_src_path, "r", encoding="utf-8") as f:
            content = f.read()
            
        out.write(f"# Write {rel_path}\n")
        out.write(f"cat << '_ANKAVM_EOF_' > {dest_path}\n")
        out.write(content)
        if not content.endswith("\n"):
            out.write("\n")
        out.write("_ANKAVM_EOF_\n\n")
        
    out.write(installer_footer)

print(f"Successfully generated self-contained installer script at: {output_script}")
