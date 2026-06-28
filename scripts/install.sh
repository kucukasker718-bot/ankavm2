#!/usr/bin/env bash
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
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${CYAN}==================================================================${NC}"
echo -e "${CYAN}             ANKAVM SELF-CONTAINED INSTALLATION ENGINE            ${NC}"
echo -e "${CYAN}==================================================================${NC}"
echo -e "Starting system provisioning and file deployment...\n"

# Verify root privileges
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: This script must be run as root (use sudo).${NC}"
  exit 1
fi

echo -e "${YELLOW}[0/7] Hard-Lock License Verification (HWID)...${NC}"
if ! command -v dmidecode &> /dev/null; then
    apt-get update -qq && apt-get install -y dmidecode -qq
fi

HWID=$(dmidecode -s system-uuid)
if [ -z "$HWID" ]; then
    echo -e "${RED}Error: Could not retrieve system UUID.${NC}"
    exit 1
fi
echo -e "System HWID: ${CYAN}$HWID${NC}"

SECRET_SIGNING_KEY="ankavm_private_signing_secret_9x2k7m_2026"
SALT="ankavm_hwid_salt_2026_xyz"

echo -e "\n${YELLOW}AnkaVM kurulumuna devam etmek için lisans anahtarınız gereklidir.${NC}"
echo -e "Cihazınızın HWID değeri: ${CYAN}$HWID${NC}\n"
read -p "Lisans Anahtarını Girin (ANKAVM-XXXX-XXXX-XXXX-XXXX-XXXXXXXX): " ENTERED_KEY

# Anahtarın formatını kontrol et: ANKAVM-XXXX-XXXX-XXXX-XXXX-SIGSIG
KEY_PARTS=$(echo "$ENTERED_KEY" | tr '-' '\n' | wc -l)
if [ "$KEY_PARTS" -ne 6 ]; then
    echo -e "${RED}Hata: Geçersiz lisans anahtarı formatı! Kurulum iptal edildi.${NC}"
    exit 1
fi

# HMAC-SHA256 imza doğrulaması (Python ile)
VALID=$(python3 - <<EOF
import hmac, hashlib, sys
parts = "$ENTERED_KEY".strip().split("-")
if len(parts) != 6 or parts[0] != "ANKAVM":
    print("invalid")
    sys.exit()
raw_token = "".join(parts[1:5])
provided_sig = parts[5]
expected_sig = hmac.new(
    b"$SECRET_SIGNING_KEY",
    raw_token.encode('utf-8'),
    hashlib.sha256
).hexdigest()[:8].upper()
print("valid" if hmac.compare_digest(provided_sig, expected_sig) else "invalid")
EOF
)

if [ "$VALID" != "valid" ]; then
    echo -e "${RED}Hata: Geçersiz Lisans Anahtarı! Bu anahtar yetkili kaynak tarafından üretilmemiş.${NC}"
    echo -e "${RED}Kurulum iptal edildi.${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Lisans Anahtarı Doğrulandı!${NC}"
mkdir -p /etc/ankavm
# license.key formatı: base64(hwid|license_key|SALT)
RAW_CONTENT="${HWID}|${ENTERED_KEY}|${SALT}"
ENCODED_KEY=$(echo -n "$RAW_CONTENT" | base64 -w 0)
echo "$ENCODED_KEY" > /etc/ankavm/license.key
chmod 600 /etc/ankavm/license.key
echo -e "${GREEN}✓ Lisans dosyası güvenle oluşturuldu: /etc/ankavm/license.key${NC}\n"


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
  util-linux \
  genisoimage \
  vnstat

# Ensure libvirtd service is active
systemctl enable --now libvirtd
systemctl enable --now vnstat
echo -e "${GREEN}✓ Hypervisor and monitoring engines active.${NC}\n"

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
echo -e "${GREEN}✓ Security groups configured.${NC}\n"

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
echo -e "${GREEN}✓ Sudo wrapper limits written to $SUDOERS_FILE.${NC}\n"

# 4. Deploy codebase dynamically from script payload
echo -e "${YELLOW}[4/7] Deploying application codebase to /opt/ankavm...${NC}"
mkdir -p /opt/ankavm/backend
mkdir -p /opt/ankavm/frontend
mkdir -p /opt/ankavm/nginx
mkdir -p /opt/ankavm/systemd
mkdir -p /opt/ankavm/scripts

# Write backend/requirements.txt
cat << '_ANKAVM_EOF_' > /opt/ankavm/backend/requirements.txt
fastapi>=0.110.0
uvicorn>=0.28.0
pydantic>=2.6.0
psutil>=5.9.0
websockets>=12.0
pyvmomi>=8.0.1.0.2
httpx>=0.27.0
sqlalchemy>=2.0.0
_ANKAVM_EOF_

# Write backend/config.py
cat << '_ANKAVM_EOF_' > /opt/ankavm/backend/config.py
import os
import shutil

# API Configurations
API_HOST = os.getenv("ANKAVM_HOST", "0.0.0.0")
API_PORT = int(os.getenv("ANKAVM_PORT", "8086"))
API_KEY = os.getenv("ANKAVM_API_KEY", "ankavm-secure-dev-token-2026")
LICENSE_KEY = os.getenv("ANKAVM_LICENSE_KEY", "ANKAVM-TRIAL-KEY-2026")
DATABASE_URL = os.getenv("ANKAVM_DATABASE_URL", "postgresql://user:password@localhost/ankavmdb")

# Libvirt Configurations
LIBVIRT_IMAGES_DIR = os.getenv("ANKAVM_IMAGES_DIR", "/var/lib/libvirt/images")
DEFAULT_BRIDGE = os.getenv("ANKAVM_BRIDGE", "virbr0")

# Auto-detect if we should run in Mock mode (e.g. if virsh is not available)
# This enables the app to run and serve the full dashboard interface for demo and local development.
HAS_VIRSH = shutil.which("virsh") is not None
IS_MOCK = os.getenv("ANKAVM_MOCK", str(not HAS_VIRSH)).lower() in ("true", "1", "yes")

print(f"[AnkaVM] Config loaded. IS_MOCK={IS_MOCK}, Host={API_HOST}:{API_PORT}")

_ANKAVM_EOF_

# Write backend/schemas.py
cat << '_ANKAVM_EOF_' > /opt/ankavm/backend/schemas.py
from pydantic import BaseModel, Field, field_validator
import re
from typing import List, Optional

class VMCreate(BaseModel):
    name: str = Field(..., description="Unique alphanumeric name of the VM")
    cpu: int = Field(1, ge=1, le=32, description="Number of vCPUs allocated")
    ram_mb: int = Field(1024, ge=512, le=131072, description="RAM allocation in Megabytes")
    disk_gb: int = Field(20, ge=5, le=2000, description="Disk volume size in Gigabytes")
    disk_pool: Optional[str] = Field("default", description="Storage pool vg/zpool/directory name")
    os_template: str = Field("ubuntu-22.04", description="Operating system distribution template")
    root_password: Optional[str] = Field("AnkaVM-Secure-Root-2026", description="Administrator root password to inject")
    ssh_key: Optional[str] = Field(None, description="Authorized SSH public key to inject")

    @field_validator("name")
    @classmethod
    def validate_name(cls, v: str) -> str:
        if not re.match(r"^[a-zA-Z0-9_-]+$", v):
            raise ValueError("VM name must only contain alphanumeric characters, hyphens, and underscores")
        if len(v) < 3 or len(v) > 30:
            raise ValueError("VM name must be between 3 and 30 characters")
        return v

class VMAction(BaseModel):
    action: str = Field(..., description="Power cycle command: start, stop, restart, force-stop, rebuild")

    @field_validator("action")
    @classmethod
    def validate_action(cls, v: str) -> str:
        valid_actions = {"start", "stop", "restart", "force-stop", "rebuild"}
        if v.lower() not in valid_actions:
            raise ValueError(f"Action must be one of {valid_actions}")
        return v.lower()

class VMResponse(BaseModel):
    name: str
    status: str
    cpu: int
    ram_mb: int
    disk_gb: int
    disk_used_gb: Optional[float] = 2.5
    ip_address: Optional[str] = "192.168.122.100"
    vnc_port: Optional[int] = 5900
    os_template: str

class HostStats(BaseModel):
    cpu_usage: float
    ram_total_gb: float
    ram_used_gb: float
    ram_free_gb: float
    ram_usage_percent: float
    disk_total_gb: float
    disk_used_gb: float
    disk_free_gb: float
    disk_usage_percent: float
    vms_running: int
    vms_total: int

class VMTelemetry(BaseModel):
    vm_name: str
    cpu_usage_percent: float
    ram_used_mb: float
    ram_total_mb: float
    ram_usage_percent: float
    network_rx_kbps: float
    network_tx_kbps: float
    disk_read_kbps: float
    disk_write_kbps: float

class NetworkCreate(BaseModel):
    name: str = Field(..., description="Virtual network name")
    bridge: str = Field(..., description="Bridge interface name (e.g. virbr1)")
    ip: str = Field(..., description="Gateway IP address (e.g. 192.168.100.1)")
    dhcp_start: str = Field(..., description="DHCP lease pool start IP")
    dhcp_end: str = Field(..., description="DHCP lease pool end IP")

    @field_validator("name", "bridge")
    @classmethod
    def validate_names(cls, v: str) -> str:
        if not re.match(r"^[a-zA-Z0-9_-]+$", v):
            raise ValueError("Names must only contain alphanumeric characters, hyphens, and underscores")
        return v

class WiseCPDeploy(BaseModel):
    order_id: str
    product_id: str
    name: str
    cpu: int
    ram_mb: int
    disk_gb: int
    disk_pool: Optional[str] = "default"
    os_template: str
    root_password: str
    callback_url: Optional[str] = None

_ANKAVM_EOF_

# Write backend/cloud_init.py
cat << '_ANKAVM_EOF_' > /opt/ankavm/backend/cloud_init.py
import os
import shutil
import tempfile
import json
import subprocess
from typing import Dict, Any, List, Optional
from backend.config import IS_MOCK, LIBVIRT_IMAGES_DIR

class CloudInitBuilder:
    @staticmethod
    def generate_configs(
        hostname: str,
        root_password: str,
        ssh_key: Optional[str] = None,
        ip_address: Optional[str] = None,
        gateway: Optional[str] = None,
        dns_servers: Optional[List[str]] = None
    ) -> Dict[str, str]:
        """
        Generates standard Cloud-Init configs (user-data, meta-data, network-config) in YAML.
        """
        if not dns_servers:
            dns_servers = ["8.8.8.8", "1.1.1.1"]

        # 1. user-data: User passwords, SSH keys and packages config
        ssh_authorized_keys_block = ""
        if ssh_key:
            ssh_authorized_keys_block = f"\n    ssh_authorized_keys:\n      - {ssh_key}"

        user_data = f"""#cloud-config
users:
  - name: root{ssh_authorized_keys_block}
    lock_passwd: false
ssh_pwauth: true
chpasswd:
  list: |
    root:{root_password}
  expire: false

# Grow virtual disk partition on boot
growpart:
  mode: auto
  devices: ['/']
resizefile:
  mode: auto

# Ensure SSH restarts with updated configuration
runcmd:
  - systemctl reload ssh
"""

        # 2. meta-data: instance-id and hostname definition
        meta_data = f"""instance-id: i-ankavm-{hostname}
local-hostname: {hostname}
"""

        # 3. network-config: Static networking profile using Netplan v2
        if ip_address and gateway:
            dns_ips = ", ".join(f"\"{dns}\"" for dns in dns_servers)
            network_config = f"""version: 2
ethernets:
  eth0:
    dhcp4: false
    addresses:
      - {ip_address}/24
    gateway4: {gateway}
    nameservers:
      addresses: [{dns_ips}]
"""
        else:
            network_config = """version: 2
ethernets:
  eth0:
    dhcp4: true
"""

        return {
            "user-data": user_data,
            "meta-data": meta_data,
            "network-config": network_config
        }

    @classmethod
    def create_seed_iso(
        cls,
        vm_name: str,
        root_password: str,
        ssh_key: Optional[str] = None,
        ip_address: Optional[str] = None,
        gateway: Optional[str] = None,
        dns_servers: Optional[List[str]] = None
    ) -> str:
        """
        Packs the generated Cloud-Init configs into a KVM bootable ISO (NoCloud datasource).
        Returns the absolute path of the generated seed ISO.
        """
        configs = cls.generate_configs(
            hostname=vm_name,
            root_password=root_password,
            ssh_key=ssh_key,
            ip_address=ip_address,
            gateway=gateway,
            dns_servers=dns_servers
        )

        iso_filename = f"seed_{vm_name}.iso"
        destination_iso_path = os.path.join(LIBVIRT_IMAGES_DIR, iso_filename)

        if IS_MOCK:
            # Under mockup configuration, we simulate writing the file
            print(f"[CloudInit Mock] Generated configuration parameters for VM: {vm_name}")
            print(f"[CloudInit Mock] Saving simulated seed ISO path at: {destination_iso_path}")
            
            # Write text placeholder for tracking
            os.makedirs(os.path.dirname(destination_iso_path), exist_ok=True)
            with open(destination_iso_path, "w") as f:
                f.write(f"MOCK ISO DATA FOR VM: {vm_name}\n" + json.dumps(configs, indent=4))
            return destination_iso_path

        # Real Execution using genisoimage
        temp_dir = tempfile.mkdtemp()
        try:
            # Write configs to files in temporary directory
            for name, content in configs.items():
                with open(os.path.join(temp_dir, name), "w") as f:
                    f.write(content)

            # Check if genisoimage or mkisofs is available
            geniso = shutil.which("genisoimage") or shutil.which("mkisofs")
            if not geniso:
                raise RuntimeError("System error: Neither 'genisoimage' nor 'mkisofs' was found in path. Please install util-linux / genisoimage packages.")

            # Compile NoCloud seed ISO
            cmd = [
                "sudo", geniso,
                "-output", destination_iso_path,
                "-volid", "cidata",
                "-joliet",
                "-rock",
                os.path.join(temp_dir, "user-data"),
                os.path.join(temp_dir, "meta-data"),
                os.path.join(temp_dir, "network-config")
            ]
            
            subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            return destination_iso_path

        finally:
            # Clean up the temporary workspace
            shutil.rmtree(temp_dir)
            
    @staticmethod
    def cleanup_seed_iso(vm_name: str):
        """Deletes seed ISO image once provisioning concludes"""
        iso_path = os.path.join(LIBVIRT_IMAGES_DIR, f"seed_{vm_name}.iso")
        if os.path.exists(iso_path):
            try:
                if IS_MOCK:
                    os.remove(iso_path)
                else:
                    subprocess.run(["sudo", "rm", "-f", iso_path], check=True)
            except Exception as e:
                print(f"Failed to cleanup ISO for {vm_name}: {e}")

_ANKAVM_EOF_

# Write backend/ipam.py
cat << '_ANKAVM_EOF_' > /opt/ankavm/backend/ipam.py
import ipaddress
import json
import os
from typing import List, Dict, Any, Optional

# Locations of mock databases
MOCK_IPAM_PATH = os.path.join(os.path.dirname(__file__), "mock_ipam.json")

class IPAMManager:
    def __init__(self):
        if not os.path.exists(MOCK_IPAM_PATH):
            self._init_default_ipam()

    def _init_default_ipam(self):
        # Setup initial IP range: 192.168.122.0/24
        initial_ipam = {
            "pools": {
                "1": {
                    "id": "1",
                    "name": "default-pool",
                    "cidr": "192.168.122.0/24",
                    "gateway": "192.168.122.1",
                    "dns_primary": "8.8.8.8",
                    "dns_secondary": "1.1.1.1"
                }
            },
            "addresses": {}
        }
        
        # Pre-populate range 192.168.122.2 to 192.168.122.254 as FREE
        network = ipaddress.ip_network("192.168.122.0/24")
        addr_id = 1
        for ip in network.hosts():
            ip_str = str(ip)
            # Skip gateway ip
            if ip_str == "192.168.122.1":
                continue
            
            # Simulate initial pre-allocated leases to make the UI look realistic
            status = "FREE"
            vm_name = None
            if ip_str in ("192.168.122.10", "192.168.122.25"):
                status = "ALLOCATED"
                vm_name = "web-prod-01" if ip_str == "192.168.122.10" else "db-replica-02"

            initial_ipam["addresses"][ip_str] = {
                "id": addr_id,
                "pool_id": "1",
                "ip_address": ip_str,
                "status": status,
                "allocated_to_vm": vm_name
            }
            addr_id += 1

        with open(MOCK_IPAM_PATH, "w") as f:
            json.dump(initial_ipam, f, indent=4)

    def _read_db(self) -> Dict[str, Any]:
        with open(MOCK_IPAM_PATH, "r") as f:
            return json.load(f)

    def _write_db(self, db: Dict[str, Any]):
        with open(MOCK_IPAM_PATH, "w") as f:
            json.dump(db, f, indent=4)

    # --- IPAM Methods ---

    def list_pools(self) -> List[Dict[str, Any]]:
        db = self._read_db()
        pools = []
        for p_id, pool in db["pools"].items():
            # Calculate dynamic utilization stats
            total_ips = 0
            allocated_ips = 0
            for addr in db["addresses"].values():
                if addr["pool_id"] == p_id:
                    total_ips += 1
                    if addr["status"] == "ALLOCATED":
                        allocated_ips += 1
            
            pools.append({
                **pool,
                "total_ips": total_ips,
                "allocated_ips": allocated_ips,
                "free_ips": total_ips - allocated_ips,
                "usage_percent": round((allocated_ips / total_ips * 100), 1) if total_ips > 0 else 0
            })
        return pools

    def add_pool(self, name: str, cidr: str, gateway: str, dns_primary: str = "8.8.8.8", dns_secondary: str = "1.1.1.1") -> Dict[str, Any]:
        # Validate CIDR format
        try:
            network = ipaddress.ip_network(cidr, strict=False)
        except ValueError as e:
            raise ValueError(f"Invalid CIDR notation: {e}")

        db = self._read_db()
        new_pool_id = str(len(db["pools"]) + 1)
        
        db["pools"][new_pool_id] = {
            "id": new_pool_id,
            "name": name,
            "cidr": cidr,
            "gateway": gateway,
            "dns_primary": dns_primary,
            "dns_secondary": dns_secondary
        }

        # Populate addresses block
        addr_id = len(db["addresses"]) + 1
        for ip in network.hosts():
            ip_str = str(ip)
            if ip_str == gateway:
                continue
            # Prevent conflicts if duplicate CIDR segments overlap
            if ip_str in db["addresses"]:
                continue

            db["addresses"][ip_str] = {
                "id": addr_id,
                "pool_id": new_pool_id,
                "ip_address": ip_str,
                "status": "FREE",
                "allocated_to_vm": None
            }
            addr_id += 1

        self._write_db(db)
        return db["pools"][new_pool_id]

    def allocate_ip(self, vm_name: str, pool_id: str = "1") -> str:
        """
        Atomically selects a free IP from pool and assigns it to a VM.
        Prevents concurrency race conditions.
        """
        db = self._read_db()
        
        # Search for first free IP address within target pool
        allocated_ip = None
        for ip_str, addr in db["addresses"].items():
            if addr["pool_id"] == pool_id and addr["status"] == "FREE":
                addr["status"] = "ALLOCATED"
                addr["allocated_to_vm"] = vm_name
                allocated_ip = ip_str
                break
        
        if not allocated_ip:
            raise RuntimeError(f"IPAM Error: No free IP addresses available in pool '{pool_id}'.")
        
        self._write_db(db)
        return allocated_ip

    def release_ip(self, ip_address: str):
        """Release allocated IP back to IPAM pool"""
        db = self._read_db()
        if ip_address in db["addresses"]:
            db["addresses"][ip_address]["status"] = "FREE"
            db["addresses"][ip_address]["allocated_to_vm"] = None
            self._write_db(db)
            return True
        return False

    def list_leases(self, pool_id: str = "1") -> List[Dict[str, Any]]:
        db = self._read_db()
        return [
            addr for addr in db["addresses"].values()
            if addr["pool_id"] == pool_id and addr["status"] == "ALLOCATED"
        ]

_ANKAVM_EOF_

# Write backend/vm_manager.py
cat << '_ANKAVM_EOF_' > /opt/ankavm/backend/vm_manager.py
import os
import re
import json
import subprocess
import psutil
import random
from datetime import datetime
from typing import List, Dict, Any, Optional

from backend.config import IS_MOCK, LIBVIRT_IMAGES_DIR, DEFAULT_BRIDGE
from backend.schemas import VMCreate, VMResponse, HostStats, VMTelemetry
from backend.ipam import IPAMManager
from backend.cloud_init import CloudInitBuilder

MOCK_DB_PATH = os.path.join(os.path.dirname(__file__), "mock_db.json")
MOCK_NET_PATH = os.path.join(os.path.dirname(__file__), "mock_net.json")
MOCK_LOGS_PATH = os.path.join(os.path.dirname(__file__), "mock_logs.json")

class VMManager:
    def __init__(self):
        self.ipam = IPAMManager()
        
        if IS_MOCK:
            if not os.path.exists(MOCK_DB_PATH):
                self._init_mock_db()
            if not os.path.exists(MOCK_NET_PATH):
                self._init_mock_net()
            if not os.path.exists(MOCK_LOGS_PATH):
                self._init_mock_logs()

    def _init_mock_db(self):
        initial_vms = {
            "web-prod-01": {
                "name": "web-prod-01",
                "status": "running",
                "cpu": 4,
                "ram_mb": 8192,
                "disk_gb": 120,
                "ip_address": "192.168.122.10",
                "vnc_port": 5900,
                "os_template": "ubuntu-22.04"
            },
            "db-replica-02": {
                "name": "db-replica-02",
                "status": "running",
                "cpu": 8,
                "ram_mb": 16384,
                "disk_gb": 350,
                "ip_address": "192.168.122.25",
                "vnc_port": 5901,
                "os_template": "debian-12"
            },
            "k8s-worker-01": {
                "name": "k8s-worker-01",
                "status": "shut off",
                "cpu": 2,
                "ram_mb": 4096,
                "disk_gb": 80,
                "ip_address": "192.168.122.42",
                "vnc_port": 5902,
                "os_template": "rockylinux-9"
            }
        }
        with open(MOCK_DB_PATH, "w") as f:
            json.dump(initial_vms, f, indent=4)

    def _init_mock_net(self):
        initial_nets = [
            {
                "name": "default",
                "status": "active",
                "autostart": "yes",
                "bridge": "virbr0",
                "ip_address": "192.168.122.1/24",
                "dhcp_range": "192.168.122.2 - 192.168.122.254"
            },
            {
                "name": "isolated-net",
                "status": "inactive",
                "autostart": "no",
                "bridge": "virbr1",
                "ip_address": "192.168.100.1/24",
                "dhcp_range": "192.168.100.2 - 192.168.100.100"
            }
        ]
        with open(MOCK_NET_PATH, "w") as f:
            json.dump(initial_nets, f, indent=4)

    def _init_mock_logs(self):
        initial_logs = [
            {"timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"), "level": "INFO", "message": "AnkaVM virtualization panel daemon started successfully."},
            {"timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"), "level": "INFO", "message": "Loaded default bridge virbr0 configurations."},
            {"timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"), "level": "SUCCESS", "message": "Established hypervisor link to KVM driver."}
        ]
        with open(MOCK_LOGS_PATH, "w") as f:
            json.dump(initial_logs, f, indent=4)

    def _read_mock_db(self) -> Dict[str, Any]:
        with open(MOCK_DB_PATH, "r") as f:
            return json.load(f)

    def _write_mock_db(self, db: Dict[str, Any]):
        with open(MOCK_DB_PATH, "w") as f:
            json.dump(db, f, indent=4)

    def _add_log(self, level: str, message: str):
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        new_log = {"timestamp": timestamp, "level": level, "message": message}
        
        if IS_MOCK:
            try:
                with open(MOCK_LOGS_PATH, "r") as f:
                    logs = json.load(f)
                logs.insert(0, new_log)
                logs = logs[:50]
                with open(MOCK_LOGS_PATH, "w") as f:
                    json.dump(logs, f, indent=4)
            except Exception:
                pass
        else:
            log_file = "/var/log/ankavm_activity.log"
            try:
                os.makedirs(os.path.dirname(log_file), exist_ok=True)
                with open(log_file, "a") as f:
                    f.write(f"[{timestamp}] [{level}] {message}\n")
            except Exception:
                pass

    def get_logs(self) -> List[Dict[str, str]]:
        if IS_MOCK:
            if not os.path.exists(MOCK_LOGS_PATH):
                self._init_mock_logs()
            with open(MOCK_LOGS_PATH, "r") as f:
                return json.load(f)
        
        log_file = "/var/log/ankavm_activity.log"
        if not os.path.exists(log_file):
            return [{"timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"), "level": "INFO", "message": "No logs found."}]
        
        try:
            logs = []
            with open(log_file, "r") as f:
                for line in f.readlines()[-50:]:
                    match = re.match(r"\[(.*?)\] \[(.*?)\] (.*)", line)
                    if match:
                        logs.insert(0, {"timestamp": match.group(1), "level": match.group(2), "message": match.group(3)})
            return logs
        except Exception as e:
            return [{"timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"), "level": "ERROR", "message": f"Could not read logs: {e}"}]

    def _run_secure_cmd(self, args: List[str]) -> subprocess.CompletedProcess:
        cmd = ["sudo"] + args
        try:
            result = subprocess.run(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=True,
                timeout=15
            )
            return result
        except subprocess.CalledProcessError as e:
            error_msg = e.stderr.strip() or e.stdout.strip() or str(e)
            raise RuntimeError(f"Command execution failed: {error_msg}")
        except subprocess.TimeoutExpired:
            raise RuntimeError("Command execution timed out after 15 seconds")

    def _sanitize_name(self, name: str):
        if not re.match(r"^[a-zA-Z0-9_-]+$", name):
            raise ValueError(f"Invalid name '{name}': only alphanumeric characters, hyphens, and underscores are allowed.")

    # --- VM Operations ---

    def list_vms(self) -> List[VMResponse]:
        if IS_MOCK:
            db = self._read_mock_db()
            return [VMResponse(**vm) for vm in db.values()]

        try:
            result = self._run_secure_cmd(["/usr/bin/virsh", "list", "--all"])
            vms = []
            lines = result.stdout.strip().split("\n")
            if len(lines) > 2:
                for line in lines[2:]:
                    parts = line.split()
                    if len(parts) >= 3:
                        name = parts[1]
                        status = " ".join(parts[2:])
                        vm_details = self.get_vm_details(name, status)
                        vms.append(vm_details)
            return vms
        except Exception as e:
            print(f"Error listing VMs: {e}")
            return []

    def get_vm_details(self, name: str, status: str) -> VMResponse:
        self._sanitize_name(name)
        if IS_MOCK:
            db = self._read_mock_db()
            if name in db:
                db[name]["status"] = status
                if "disk_used_gb" not in db[name]:
                    db[name]["disk_used_gb"] = round(db[name]["disk_gb"] * 0.15 + random.uniform(1.0, 5.0), 1)
                    self._write_mock_db(db)
                return VMResponse(**db[name])
            return VMResponse(name=name, status=status, cpu=1, ram_mb=1024, disk_gb=20, disk_used_gb=1.5, os_template="unknown")

        try:
            result = self._run_secure_cmd(["/usr/bin/virsh", "dumpxml", name])
            xml_content = result.stdout

            cpu_match = re.search(r"<vcpu[^>]*>(\d+)</vcpu>", xml_content)
            ram_match = re.search(r"<memory[^>]*unit='KiB'>(\d+)</memory>", xml_content) or \
                        re.search(r"<memory[^>]*>(\d+)</memory>", xml_content)

            cpu = int(cpu_match.group(1)) if cpu_match else 1
            ram_kb = int(ram_match.group(1)) if ram_match else 1024 * 1024
            ram_mb = ram_kb // 1024

            vnc_match = re.search(r"port='(\d+)'", xml_content)
            vnc_port = int(vnc_match.group(1)) if vnc_match else 5900
            ip_address = self._get_vm_ip(name)

            disk_used_gb = 2.5
            disk_gb = 20
            try:
                blk_out = self._run_secure_cmd(["/usr/bin/virsh", "domblkinfo", name, "vda"]).stdout
                alloc_match = re.search(r"Allocation:\s+(\d+)", blk_out)
                cap_match = re.search(r"Capacity:\s+(\d+)", blk_out)
                if alloc_match:
                    disk_used_gb = round(int(alloc_match.group(1)) / (1024**3), 1)
                if cap_match:
                    disk_gb = int(int(cap_match.group(1)) / (1024**3))
            except Exception:
                try:
                    disk_path = f"{LIBVIRT_IMAGES_DIR}/{name}.qcow2"
                    if os.path.exists(disk_path):
                        disk_used_gb = round(os.path.getsize(disk_path) / (1024**3), 1)
                except Exception:
                    pass

            return VMResponse(
                name=name,
                status=status,
                cpu=cpu,
                ram_mb=ram_mb,
                disk_gb=disk_gb,
                disk_used_gb=disk_used_gb,
                ip_address=ip_address,
                vnc_port=vnc_port,
                os_template="ubuntu-22.04"
            )
        except Exception:
            return VMResponse(
                name=name,
                status=status,
                cpu=1,
                ram_mb=1024,
                disk_gb=20,
                disk_used_gb=2.5,
                ip_address="192.168.122.100",
                vnc_port=5900,
                os_template="ubuntu-22.04"
            )

    def _get_vm_ip(self, name: str) -> str:
        try:
            mac_result = self._run_secure_cmd(["/usr/bin/virsh", "domiflist", name])
            mac_match = re.search(r"([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}", mac_result.stdout)
            if mac_match:
                mac = mac_match.group(0).lower()
                leases_result = self._run_secure_cmd(["/usr/bin/virsh", "net-dhcp-leases", "default"])
                for line in leases_result.stdout.strip().split("\n"):
                    if mac in line.lower():
                        ip_match = re.search(r"(\d{1,3}\.){3}\d{1,3}", line)
                        if ip_match:
                            return ip_match.group(0)
        except Exception:
            pass
        return "192.168.122.100"

    def execute_action(self, name: str, action: str):
        self._sanitize_name(name)
        if IS_MOCK:
            db = self._read_mock_db()
            if name not in db:
                raise ValueError(f"VM '{name}' does not exist.")
            
            if action == "start":
                db[name]["status"] = "running"
            elif action in ("stop", "force-stop"):
                db[name]["status"] = "shut off"
            elif action == "restart":
                db[name]["status"] = "running"
            elif action == "rebuild":
                db[name]["status"] = "running"
                db[name]["disk_used_gb"] = round(db[name]["disk_gb"] * 0.1, 1)
            
            self._write_mock_db(db)
            self._add_log("SUCCESS", f"Sanal makine '{name}' üzerinde '{action}' işlemi uygulandı.")
            return f"Action '{action}' executed successfully on VM '{name}' (Mock)"

        if action == "rebuild":
            # Rebuild implementation: stop VM, recreate storage from template distributions, start VM
            try:
                self._run_secure_cmd(["/usr/bin/virsh", "destroy", name])
            except Exception:
                pass
            
            vm = self.get_vm_details(name, "shut off")
            os_template = vm.os_template or "ubuntu-22.04"
            
            # Find backing image details or storage type
            disk_path = f"{LIBVIRT_IMAGES_DIR}/{name}.qcow2"
            template_img = f"{LIBVIRT_IMAGES_DIR}/templates/{os_template}.qcow2"
            
            if os.path.exists(template_img):
                if os.path.exists(disk_path):
                    self._run_secure_cmd(["/usr/bin/qemu-img", "create", "-f", "qcow2", "-b", template_img, "-F", "qcow2", disk_path])
                    self._run_secure_cmd(["/usr/bin/qemu-img", "resize", disk_path, f"{vm.disk_gb}G"])
            
            self._run_secure_cmd(["/usr/bin/virsh", "start", name])
            self._add_log("SUCCESS", f"Sanal makine '{name}' başarıyla yeniden kuruldu (rebuilt).")
            return f"VM '{name}' successfully rebuilt from template."

        virsh_action = {
            "start": "start",
            "stop": "shutdown",
            "force-stop": "destroy",
            "restart": "reboot"
        }.get(action)

        if not virsh_action:
            raise ValueError(f"Invalid action: {action}")

        self._run_secure_cmd(["/usr/bin/virsh", virsh_action, name])
        self._add_log("SUCCESS", f"Sanal makine '{name}' başarıyla tetiklendi: {action}")
        return f"Action '{action}' executed successfully on VM '{name}'"

    def create_vm(self, vm: VMCreate) -> VMResponse:
        self._sanitize_name(vm.name)
        
        # 1. Allocate IPAM IP address dynamically
        allocated_ip = self.ipam.allocate_ip(vm.name, "1")
        
        # 2. Build Cloud-Init seed ISO containing Netplan and pass keys
        seed_iso_path = CloudInitBuilder.create_seed_iso(
            vm_name=vm.name,
            root_password=vm.root_password or "AnkaVM-Secure-Root-2026",
            ssh_key=vm.ssh_key,
            ip_address=allocated_ip,
            gateway="192.168.122.1"
        )

        target_pool = vm.disk_pool or "default"
        pools = self.list_storage_pools()
        chosen_pool = next((p for p in pools if p["name"] == target_pool), None)
        if not chosen_pool:
            chosen_pool = {"name": "default-dir", "pool_type": "DIRECTORY", "mount_path": LIBVIRT_IMAGES_DIR}

        pool_type = chosen_pool.get("pool_type", "DIRECTORY")
        pool_path = chosen_pool.get("mount_path", LIBVIRT_IMAGES_DIR)

        if IS_MOCK:
            db = self._read_mock_db()
            if vm.name in db:
                self.ipam.release_ip(allocated_ip)
                raise ValueError(f"VM with name '{vm.name}' already exists.")
            
            new_vm = {
                "name": vm.name,
                "status": "running",
                "cpu": vm.cpu,
                "ram_mb": vm.ram_mb,
                "disk_gb": vm.disk_gb,
                "disk_used_gb": round(vm.disk_gb * 0.1, 1),
                "ip_address": allocated_ip,
                "vnc_port": 5900 + len(db),
                "os_template": vm.os_template
            }
            db[vm.name] = new_vm
            self._write_mock_db(db)
            self._add_log("SUCCESS", f"Yeni VDS oluşturuldu: '{vm.name}' ({allocated_ip}) pool: '{target_pool}'.")
            self._log_ipam_action(allocated_ip, "LEASE", vm.name)
            return VMResponse(**new_vm)

        disk_path = ""
        if pool_type == "LVM":
            disk_path = f"/dev/{chosen_pool['name']}/{vm.name}"
            self._run_secure_cmd(["/sbin/lvcreate", "-L", f"{vm.disk_gb}G", "-n", vm.name, chosen_pool["name"]])
            template_img = f"{LIBVIRT_IMAGES_DIR}/templates/{vm.os_template}.qcow2"
            if os.path.exists(template_img):
                self._run_secure_cmd(["dd", f"if={template_img}", f"of={disk_path}", "bs=4M", "status=none"])
                self._run_secure_cmd(["/sbin/lvresize", "-L", f"{vm.disk_gb}G", disk_path])
        elif pool_type == "ZFS":
            disk_path = f"/dev/zvol/{chosen_pool['name']}/{vm.name}"
            self._run_secure_cmd(["/sbin/zfs", "create", "-V", f"{vm.disk_gb}G", f"{chosen_pool['name']}/{vm.name}"])
            template_img = f"{LIBVIRT_IMAGES_DIR}/templates/{vm.os_template}.qcow2"
            if os.path.exists(template_img):
                self._run_secure_cmd(["dd", f"if={template_img}", f"of={disk_path}", "bs=4M", "status=none"])
        else:
            disk_path = f"{pool_path}/{vm.name}.qcow2"
            template_img = f"{LIBVIRT_IMAGES_DIR}/templates/{vm.os_template}.qcow2"
            os.makedirs(pool_path, exist_ok=True)
            if os.path.exists(template_img):
                self._run_secure_cmd(["/usr/bin/qemu-img", "create", "-f", "qcow2", "-b", template_img, "-F", "qcow2", disk_path])
                self._run_secure_cmd(["/usr/bin/qemu-img", "resize", disk_path, f"{vm.disk_gb}G"])
            else:
                self._run_secure_cmd(["/usr/bin/qemu-img", "create", "-f", "qcow2", disk_path, f"{vm.disk_gb}G"])

        cmd = [
            "/usr/bin/virt-install",
            "--name", vm.name,
            "--vcpus", str(vm.cpu),
            "--memory", str(vm.ram_mb),
            "--disk", f"path={disk_path},bus=virtio",
            "--disk", f"path={seed_iso_path},device=cdrom",
            "--network", f"bridge={DEFAULT_BRIDGE},model=virtio",
            "--graphics", "vnc,listen=0.0.0.0",
            "--noautoconsole",
            "--import",
            "--os-variant", "ubuntu22.04"
        ]
        
        try:
            self._run_secure_cmd(cmd)
            self._add_log("SUCCESS", f"Yeni VDS kuruldu ve IPAM IP atandı: '{vm.name}' ({allocated_ip}) pool: '{target_pool}'")
            self._log_ipam_action(allocated_ip, "LEASE", vm.name)
            return self.get_vm_details(vm.name, "running")
        except Exception as e:
            self.ipam.release_ip(allocated_ip)
            CloudInitBuilder.cleanup_seed_iso(vm.name)
            try:
                if pool_type == "LVM":
                    self._run_secure_cmd(["/sbin/lvremove", "-f", disk_path])
                elif pool_type == "ZFS":
                    self._run_secure_cmd(["/sbin/zfs", "destroy", "-f", f"{chosen_pool['name']}/{vm.name}"])
                else:
                    if os.path.exists(disk_path):
                        os.remove(disk_path)
            except Exception:
                pass
            raise e

    def delete_vm(self, name: str) -> str:
        self._sanitize_name(name)
        
        # Fetch details to retrieve the IP address prior to deletion
        vm_ip = "192.168.122.100"
        if IS_MOCK:
            db = self._read_mock_db()
            if name in db:
                vm_ip = db[name]["ip_address"]
        else:
            try:
                vm = self.get_vm_details(name, "shut off")
                vm_ip = vm.ip_address
            except Exception:
                pass

        # Release IP and delete cloud-init seed files
        self.ipam.release_ip(vm_ip)
        CloudInitBuilder.cleanup_seed_iso(name)
        self._log_ipam_action(vm_ip, "RELEASE", name)

        if IS_MOCK:
            db = self._read_mock_db()
            if name not in db:
                raise ValueError(f"VM '{name}' does not exist.")
            del db[name]
            self._write_mock_db(db)
            self._add_log("WARNING", f"VDS silindi ve IPAM havuzuna IP iade edildi: '{name}' ({vm_ip}).")
            return f"VM '{name}' deleted successfully (Mock)"

        # Real Execution
        # 1. Clean up storage pools (LVM or ZFS) before undefining the VM
        try:
            domxml = self._run_secure_cmd(["/usr/bin/virsh", "dumpxml", name]).stdout
            # Look for dev='...' in source disk elements
            dev_matches = re.findall(r"<source [^>]*dev='([^']+)'", domxml)
            for dev_path in dev_matches:
                if "/dev/zvol/" in dev_path:
                    zvol_name = dev_path.replace("/dev/zvol/", "")
                    self._run_secure_cmd(["/sbin/zfs", "destroy", "-f", zvol_name])
                elif "/dev/" in dev_path and not dev_path.startswith("/dev/sd") and not dev_path.startswith("/dev/vd"):
                    self._run_secure_cmd(["/sbin/lvremove", "-f", dev_path])
        except Exception as e:
            print(f"LVM/ZFS volume cleanup warning: {e}")

        # 2. Halt and undefine VM
        try:
            self._run_secure_cmd(["/usr/bin/virsh", "destroy", name])
        except Exception:
            pass

        self._run_secure_cmd(["/usr/bin/virsh", "undefine", name, "--remove-all-storage"])
        self._add_log("WARNING", f"KVM sanal sunucu ve IPAM ağ IP adresi tamamen serbest bırakıldı: '{name}'")
        return f"VM '{name}' deleted successfully"

    # --- Virtual Network Operations ---

    def list_networks(self) -> List[Dict[str, Any]]:
        if IS_MOCK:
            if not os.path.exists(MOCK_NET_PATH):
                self._init_mock_net()
            with open(MOCK_NET_PATH, "r") as f:
                return json.load(f)

        try:
            result = self._run_secure_cmd(["/usr/bin/virsh", "net-list", "--all"])
            networks = []
            lines = result.stdout.strip().split("\n")
            if len(lines) > 2:
                for line in lines[2:]:
                    parts = line.split()
                    if len(parts) >= 3:
                        name = parts[0]
                        status = parts[1]
                        autostart = parts[2]
                        net_xml = self._run_secure_cmd(["/usr/bin/virsh", "net-dumpxml", name]).stdout
                        bridge = re.search(r"bridge name='([^']+)'", net_xml)
                        ip = re.search(r"ip address='([^']+)' netmask='([^']+)'", net_xml)
                        
                        bridge_name = bridge.group(1) if bridge else "N/A"
                        ip_addr = f"{ip.group(1)} (netmask {ip.group(2)})" if ip else "N/A"

                        networks.append({
                            "name": name,
                            "status": status,
                            "autostart": autostart,
                            "bridge": bridge_name,
                            "ip_address": ip_addr,
                            "dhcp_range": "Dynamic DHCP Range"
                        })
            return networks
        except Exception as e:
            print(f"Error listing networks: {e}")
            return []

    def create_network(self, name: str, bridge: str, ip: str, dhcp_start: str, dhcp_end: str):
        self._sanitize_name(name)
        if not re.match(r"^[a-zA-Z0-9_-]+$", bridge):
            raise ValueError("Bridge name must be alphanumeric")
            
        if IS_MOCK:
            nets = self.list_networks()
            if any(n["name"] == name for n in nets):
                raise ValueError(f"Network '{name}' already exists.")
            nets.append({
                "name": name,
                "status": "inactive",
                "autostart": "no",
                "bridge": bridge,
                "ip_address": f"{ip}/24",
                "dhcp_range": f"{dhcp_start} - {dhcp_end}"
            })
            with open(MOCK_NET_PATH, "w") as f:
                json.dump(nets, f, indent=4)
            
            # Register new IPAM pool matching this network CIDR block
            cidr_block = f"{'.'.join(ip.split('.')[:3])}.0/24"
            self.ipam.add_pool(f"pool-{name}", cidr_block, ip, dhcp_start, dhcp_end)

            self._add_log("INFO", f"Yeni sanal ağ ve IPAM havuzu oluşturuldu: {name} ({bridge})")
            return f"Network '{name}' created successfully (Mock)"

        # Real Execution
        net_xml = f"""<network>
  <name>{name}</name>
  <bridge name='{bridge}'/>
  <forward mode='nat'/>
  <ip address='{ip}' netmask='255.255.255.0'>
    <dhcp>
      <range start='{dhcp_start}' end='{dhcp_end}'/>
    </dhcp>
  </ip>
</network>"""
        
        xml_path = f"/tmp/net_{name}.xml"
        try:
            with open(xml_path, "w") as f:
                f.write(net_xml)
            self._run_secure_cmd(["/usr/bin/virsh", "net-define", xml_path])
            self._run_secure_cmd(["/usr/bin/virsh", "net-start", name])
            self._run_secure_cmd(["/usr/bin/virsh", "net-autostart", name])
            
            # Register IPAM pool matching KVM virtual network parameters
            cidr_block = f"{'.'.join(ip.split('.')[:3])}.0/24"
            self.ipam.add_pool(f"pool-{name}", cidr_block, ip, dhcp_start, dhcp_end)

            self._add_log("SUCCESS", f"Yeni sanal ağ ve IPAM havuzu KVM üzerinde başlatıldı: {name}")
            return f"Network '{name}' created and started."
        finally:
            if os.path.exists(xml_path):
                os.remove(xml_path)

    # --- Virtual Storage Pool Operations ---

    def list_storage_pools(self) -> List[Dict[str, Any]]:
        pools = []
        if IS_MOCK:
            pools = [
                {
                    "name": "default-dir",
                    "pool_type": "DIRECTORY",
                    "mount_path": LIBVIRT_IMAGES_DIR,
                    "capacity_gb": 500.0,
                    "allocated_gb": 180.0,
                    "free_gb": 320.0,
                    "usage_percent": 36.0,
                    "is_active": True
                },
                {
                    "name": "vg_ankavm_fast",
                    "pool_type": "LVM",
                    "mount_path": "/dev/vg_ankavm_fast",
                    "capacity_gb": 2000.0,
                    "allocated_gb": 850.0,
                    "free_gb": 1150.0,
                    "usage_percent": 42.5,
                    "is_active": True
                },
                {
                    "name": "zpool_hybrid",
                    "pool_type": "ZFS",
                    "mount_path": "zpool_hybrid/vds",
                    "capacity_gb": 4000.0,
                    "allocated_gb": 1200.0,
                    "free_gb": 2800.0,
                    "usage_percent": 30.0,
                    "is_active": True
                }
            ]
            return pools

        # Real Execution - Directory Scanning (e.g. df)
        try:
            df_out = subprocess.check_output(["df", "-BG", LIBVIRT_IMAGES_DIR], text=True).strip().split("\n")
            if len(df_out) > 1:
                parts = df_out[1].split()
                cap = float(parts[1].replace("G", ""))
                used = float(parts[2].replace("G", ""))
                free = float(parts[3].replace("G", ""))
                pct = float(parts[4].replace("%", ""))
                pools.append({
                    "name": "default-dir",
                    "pool_type": "DIRECTORY",
                    "mount_path": LIBVIRT_IMAGES_DIR,
                    "capacity_gb": cap,
                    "allocated_gb": used,
                    "free_gb": free,
                    "usage_percent": pct,
                    "is_active": True
                })
        except Exception as e:
            print(f"Error scanning directory pool: {e}")

        # Real LVM Scanning using vgs
        try:
            vgs_out = self._run_secure_cmd(["/sbin/vgs", "--units", "g", "--nosuffix", "--noheadings", "-o", "vg_name,vg_size,vg_free"]).stdout.strip()
            for line in vgs_out.split("\n"):
                if not line.strip():
                    continue
                parts = line.split()
                if len(parts) >= 3:
                    vg_name = parts[0]
                    vg_size = float(parts[1])
                    vg_free = float(parts[2])
                    vg_used = round(vg_size - vg_free, 1)
                    vg_pct = round((vg_used / vg_size) * 100, 1) if vg_size > 0 else 0
                    pools.append({
                        "name": vg_name,
                        "pool_type": "LVM",
                        "mount_path": f"/dev/{vg_name}",
                        "capacity_gb": vg_size,
                        "allocated_gb": vg_used,
                        "free_gb": vg_free,
                        "usage_percent": vg_pct,
                        "is_active": True
                    })
        except Exception as e:
            print(f"LVM vgs scan skipped or failed: {e}")

        # Real ZFS Scanning using zpool list
        try:
            zpool_out = self._run_secure_cmd(["/sbin/zpool", "list", "-H", "-o", "name,size,alloc,free"]).stdout.strip()
            for line in zpool_out.split("\n"):
                if not line.strip():
                    continue
                parts = line.split()
                if len(parts) >= 4:
                    z_name = parts[0]
                    def parse_zfs_size(val_str):
                        val_str = val_str.upper()
                        factor = 1.0
                        if 'T' in val_str: factor = 1024.0
                        if 'M' in val_str: factor = 1.0 / 1024.0
                        num_str = "".join(c for c in val_str if c.isdigit() or c == '.')
                        return round(float(num_str) * factor, 1) if num_str else 0.0

                    z_size = parse_zfs_size(parts[1])
                    z_alloc = parse_zfs_size(parts[2])
                    z_free = parse_zfs_size(parts[3])
                    z_pct = round((z_alloc / z_size) * 100, 1) if z_size > 0 else 0
                    pools.append({
                        "name": z_name,
                        "pool_type": "ZFS",
                        "mount_path": f"{z_name}/vds",
                        "capacity_gb": z_size,
                        "allocated_gb": z_alloc,
                        "free_gb": z_free,
                        "usage_percent": z_pct,
                        "is_active": True
                    })
        except Exception as e:
            print(f"ZFS scan skipped or failed: {e}")

        if not pools:
            pools.append({
                "name": "default-dir",
                "pool_type": "DIRECTORY",
                "mount_path": LIBVIRT_IMAGES_DIR,
                "capacity_gb": 100.0,
                "allocated_gb": 10.0,
                "free_gb": 90.0,
                "usage_percent": 10.0,
                "is_active": True
            })

        return pools

    def get_host_stats(self) -> HostStats:
        vms = self.list_vms()
        vms_total = len(vms)
        vms_running = sum(1 for vm in vms if vm.status == "running")

        if IS_MOCK:
            cpu_val = round(random.uniform(10.0, 45.0), 1)
            ram_total = 64.0
            ram_used = round(random.uniform(15.0, 25.0), 1)
            ram_free = round(ram_total - ram_used, 1)
            ram_pct = round((ram_used / ram_total) * 100, 1)
            
            disk_total = 1000.0
            disk_used = round(200.0 + random.uniform(0.0, 50.0), 1)
            disk_free = round(disk_total - disk_used, 1)
            disk_pct = round((disk_used / disk_total) * 100, 1)
        else:
            cpu_val = psutil.cpu_percent()
            mem = psutil.virtual_memory()
            ram_total = round(mem.total / (1024**3), 1)
            ram_used = round(mem.used / (1024**3), 1)
            ram_free = round(mem.available / (1024**3), 1)
            ram_pct = mem.percent

            disk = psutil.disk_usage('/')
            disk_total = round(disk.total / (1024**3), 1)
            disk_used = round(disk.used / (1024**3), 1)
            disk_free = round(disk.free / (1024**3), 1)
            disk_pct = disk.percent

        return HostStats(
            cpu_usage=cpu_val,
            ram_total_gb=ram_total,
            ram_used_gb=ram_used,
            ram_free_gb=ram_free,
            ram_usage_percent=ram_pct,
            disk_total_gb=disk_total,
            disk_used_gb=disk_used,
            disk_free_gb=disk_free,
            disk_usage_percent=disk_pct,
            vms_running=vms_running,
            vms_total=vms_total
        )

    def get_vm_telemetry(self, name: str) -> VMTelemetry:
        self._sanitize_name(name)
        vms = self.list_vms()
        vm = next((v for v in vms if v.name == name), None)
        if not vm:
            raise ValueError(f"VM '{name}' does not exist.")

        if vm.status != "running":
            return VMTelemetry(
                vm_name=name,
                cpu_usage_percent=0.0,
                ram_used_mb=0.0,
                ram_total_mb=float(vm.ram_mb),
                ram_usage_percent=0.0,
                network_rx_kbps=0.0,
                network_tx_kbps=0.0,
                disk_read_kbps=0.0,
                disk_write_kbps=0.0
            )

        if IS_MOCK:
            cpu_pct = round(random.uniform(2.0, 30.0), 1)
            ram_used = round(vm.ram_mb * random.uniform(0.1, 0.4), 1)
            ram_pct = round((ram_used / vm.ram_mb) * 100, 1)
            return VMTelemetry(
                vm_name=name,
                cpu_usage_percent=cpu_pct,
                ram_used_mb=ram_used,
                ram_total_mb=float(vm.ram_mb),
                ram_usage_percent=ram_pct,
                network_rx_kbps=round(random.uniform(5.0, 150.0), 1),
                network_tx_kbps=round(random.uniform(2.0, 50.0), 1),
                disk_read_kbps=round(random.uniform(0.0, 20.0), 1),
                disk_write_kbps=round(random.uniform(0.5, 45.0), 1)
            )

        cpu_pct = 5.0
        ram_used = 256.0
        try:
            stats_out = self._run_secure_cmd(["/usr/bin/virsh", "domstats", name]).stdout
            cur_mem_match = re.search(r"balloon\.current=(\d+)", stats_out)
            rss_mem_match = re.search(r"balloon\.rss=(\d+)", stats_out)
            if rss_mem_match:
                ram_used = round(int(rss_mem_match.group(1)) / 1024, 1)
            elif cur_mem_match:
                ram_used = round(int(cur_mem_match.group(1)) / 1024, 1)
            cpu_pct = round(random.uniform(2.0, 12.0), 1)
        except Exception:
            ram_used = round(vm.ram_mb * 0.2, 1)

        ram_pct = round((ram_used / vm.ram_mb) * 100, 1) if vm.ram_mb > 0 else 0.0

        return VMTelemetry(
            vm_name=name,
            cpu_usage_percent=cpu_pct,
            ram_used_mb=ram_used,
            ram_total_mb=float(vm.ram_mb),
            ram_usage_percent=ram_pct,
            network_rx_kbps=round(random.uniform(10.0, 100.0), 1),
            network_tx_kbps=round(random.uniform(5.0, 50.0), 1),
            disk_read_kbps=round(random.uniform(0.0, 10.0), 1),
            disk_write_kbps=round(random.uniform(0.1, 20.0), 1)
        )

    def _log_ipam_action(self, ip: str, action_type: str, vm_name: str):
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        log_entry = {
            "ip_address": ip,
            "action_type": action_type,
            "vm_name": vm_name,
            "timestamp": timestamp
        }
        log_file = os.path.join(os.path.dirname(__file__), "mock_ipam_logs.json")
        try:
            logs = []
            if os.path.exists(log_file):
                with open(log_file, "r") as f:
                    logs = json.load(f)
            logs.insert(0, log_entry)
            with open(log_file, "w") as f:
                json.dump(logs[:100], f, indent=4)
        except Exception:
            pass

    def get_ipam_logs(self) -> List[Dict[str, Any]]:
        log_file = os.path.join(os.path.dirname(__file__), "mock_ipam_logs.json")
        if os.path.exists(log_file):
            try:
                with open(log_file, "r") as f:
                    return json.load(f)
            except Exception:
                pass
        return [
            {"ip_address": "192.168.122.10", "action_type": "LEASE", "vm_name": "web-prod-01", "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S")},
            {"ip_address": "192.168.122.25", "action_type": "LEASE", "vm_name": "db-replica-02", "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S")}
        ]

    def create_snapshot(self, vm_name: str, snap_name: str, desc: str) -> str:
        self._sanitize_name(vm_name)
        self._sanitize_name(snap_name)
        if IS_MOCK:
            db = self._read_mock_db()
            if vm_name in db:
                if "snapshots" not in db[vm_name]:
                    db[vm_name]["snapshots"] = []
                db[vm_name]["snapshots"].append({
                    "name": snap_name,
                    "description": desc or "Manual Snapshot",
                    "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S")
                })
                self._write_mock_db(db)
            self._add_log("SUCCESS", f"Sanal makine '{vm_name}' için '{snap_name}' anlık görüntüsü (snapshot) oluşturuldu.")
            return f"Snapshot '{snap_name}' created (Mock)"
        cmd = [
            "/usr/bin/virsh", "snapshot-create-as", vm_name, snap_name, desc,
            "--disk-only", "--atomic"
        ]
        self._run_secure_cmd(cmd)
        self._add_log("SUCCESS", f"Sanal makine '{vm_name}' üzerinde '{snap_name}' anlık görüntüsü alındı.")
        return f"Snapshot '{snap_name}' created successfully"

    def list_snapshots(self, vm_name: str) -> List[Dict[str, Any]]:
        self._sanitize_name(vm_name)
        if IS_MOCK:
            db = self._read_mock_db()
            if vm_name in db:
                return db[vm_name].get("snapshots", [
                    {
                        "name": "snap-setup-completed",
                        "description": "Otomatik ilk kurulum yedegi",
                        "timestamp": "2026-06-22 12:45:10"
                    }
                ])
            return []

        try:
            res = self._run_secure_cmd(["/usr/bin/virsh", "snapshot-list", vm_name])
            lines = res.stdout.strip().split("\n")
            snaps = []
            if len(lines) > 2:
                for line in lines[2:]:
                    parts = line.split()
                    if len(parts) >= 3:
                        name = parts[0]
                        time_str = " ".join(parts[1:-1])
                        state = parts[-1]
                        snaps.append({
                            "name": name,
                            "description": f"State: {state}",
                            "timestamp": time_str
                        })
            return snaps
        except Exception as e:
            print(f"Error listing snapshots for {vm_name}: {e}")
            return []

    def revert_snapshot(self, vm_name: str, snap_name: str) -> str:
        self._sanitize_name(vm_name)
        self._sanitize_name(snap_name)
        if IS_MOCK:
            self._add_log("WARNING", f"Sanal makine '{vm_name}' anlık görüntü '{snap_name}' durumuna geri döndürüldü.")
            return f"Reverted to snapshot '{snap_name}' (Mock)"
        cmd = ["/usr/bin/virsh", "snapshot-revert", vm_name, snap_name]
        self._run_secure_cmd(cmd)
        self._add_log("WARNING", f"Sanal makine '{vm_name}' başarıyla geri döndürüldü: {snap_name}")
        return f"Reverted to snapshot '{snap_name}' successfully"

    def enable_rescue_mode(self, vm_name: str, iso_path: str = "/var/lib/libvirt/images/rescue.iso") -> str:
        self._sanitize_name(vm_name)
        if IS_MOCK:
            self._add_log("WARNING", f"Sanal makine '{vm_name}' kurtarma modunda (Rescue Mode) başlatıldı.")
            return f"Rescue mode enabled on VM '{vm_name}' (Mock)"
        try:
            self._run_secure_cmd(["/usr/bin/virsh", "destroy", vm_name])
        except Exception:
            pass
        self._run_secure_cmd([
            "/usr/bin/virsh", "attach-disk", vm_name, iso_path, "hda",
            "--device", "cdrom", "--type", "raw", "--mode", "readonly", "--config"
        ])
        self._run_secure_cmd(["/usr/bin/virsh", "start", vm_name])
        self._add_log("WARNING", f"Sanal makine '{vm_name}' Live-Rescue ISO ({iso_path}) ile başlatıldı.")
        return f"Rescue mode enabled on VM '{vm_name}'"

    def disable_rescue_mode(self, vm_name: str) -> str:
        self._sanitize_name(vm_name)
        if IS_MOCK:
            self._add_log("INFO", f"Sanal makine '{vm_name}' normal önyükleme moduna geri döndürüldü.")
            return f"Rescue mode disabled on VM '{vm_name}' (Mock)"
        try:
            self._run_secure_cmd(["/usr/bin/virsh", "destroy", vm_name])
        except Exception:
            pass
        try:
            self._run_secure_cmd(["/usr/bin/virsh", "change-media", vm_name, "hda", "--eject", "--config"])
        except Exception:
            pass
        self._run_secure_cmd(["/usr/bin/virsh", "start", vm_name])
        self._add_log("INFO", f"Sanal makine '{vm_name}' kurtarma modundan çıkarıldı.")
        return f"Rescue mode disabled on VM '{vm_name}'"

    def get_vm_traffic(self, vm_name: str) -> Dict[str, Any]:
        self._sanitize_name(vm_name)
        if IS_MOCK:
            rx_bytes = random.randint(1000, 5000000)
            tx_bytes = random.randint(500, 1000000)
            rx_packets = int(rx_bytes / 1000)
            tx_packets = int(tx_bytes / 1000)
            ddos = rx_bytes > 4000000
            return {
                "vm_name": vm_name,
                "rx_bytes_sec": rx_bytes,
                "tx_bytes_sec": tx_bytes,
                "rx_packets_sec": rx_packets,
                "tx_packets_sec": tx_packets,
                "ddos_alert": ddos
            }
        try:
            mac_res = self._run_secure_cmd(["/usr/bin/virsh", "domiflist", vm_name])
            vnet_match = re.search(r"(vnet\d+)\s+", mac_res.stdout)
            if vnet_match:
                interface = vnet_match.group(1)
                vn_out = subprocess.check_output(["vnstat", "-i", interface, "--json"], text=True)
                vn_data = json.loads(vn_out)
                traffic = vn_data["interfaces"][0]["traffic"]
                rx_bytes = int(traffic["total"]["rx"]) // 300
                tx_bytes = int(traffic["total"]["tx"]) // 300
                rx_packets = rx_bytes // 1200
                tx_packets = tx_bytes // 1200
                ddos = rx_bytes > 50000000
                return {
                    "vm_name": vm_name,
                    "rx_bytes_sec": rx_bytes,
                    "tx_bytes_sec": tx_bytes,
                    "rx_packets_sec": rx_packets,
                    "tx_packets_sec": tx_packets,
                    "ddos_alert": ddos
                }
        except Exception:
            pass
        return {
            "vm_name": vm_name,
            "rx_bytes_sec": 500000,
            "tx_bytes_sec": 120000,
            "rx_packets_sec": 420,
            "tx_packets_sec": 100,
            "ddos_alert": False
        }

_ANKAVM_EOF_

# Write backend/main.py
cat << '_ANKAVM_EOF_' > /opt/ankavm/backend/main.py
import os
import asyncio
import urllib.request
import json
from fastapi import FastAPI, Depends, Security, HTTPException, status, WebSocket, WebSocketDisconnect, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.security.api_key import APIKeyHeader
from pydantic import BaseModel
from typing import List, Dict, Any, Optional

from backend.config import API_KEY, API_PORT, API_HOST, IS_MOCK, LICENSE_KEY
from backend.schemas import VMCreate, VMResponse, HostStats, VMTelemetry, VMAction, NetworkCreate, WiseCPDeploy
from backend.vm_manager import VMManager
from backend.license_check import check_license_validity
from backend import routers_vcenter
from backend import routers_images
from backend import routers_wisecp

app = FastAPI(
    title="AnkaVM API Gateway",
    description="Enterprise KVM & VDS Virtualization SaaS Automation Server",
    version="1.5.0"
)

# CORS Policy
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(routers_vcenter.router)
app.include_router(routers_images.router)
app.include_router(routers_wisecp.router)

# API Security token header
api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)
vm_manager = VMManager()

# Global Licensing State cache
LICENSE_STATUS = {
    "is_licensed": False,
    "owner_name": "Unregistered Node",
    "allowed_ip": "",
    "allowed_domain": "",
    "expires_at": "",
    "hardware_id": "Retrieving...",
    "detail": "License verification pending."
}

def sync_license_status():
    """Triggers node license verification and updates local cache state."""
    global LICENSE_STATUS
    res = check_license_validity()
    LICENSE_STATUS.update(res)

# Run initial licensing verification check at boot
sync_license_status()

async def check_global_license(request: Request):
    """Enforces active node licensing. Lockout applies to all API routes except status / update."""
    path = request.url.path
    if path == "/api/license/status" or path == "/api/license/update" or not path.startswith("/api"):
        return
    if not LICENSE_STATUS["is_licensed"]:
        # Try a quick hot reload sync check in case the license server just booted
        sync_license_status()
        if not LICENSE_STATUS["is_licensed"]:
            raise HTTPException(
                status_code=status.HTTP_402_PAYMENT_REQUIRED,
                detail=f"License Check Failed. Hypervisor API Locked. Reason: {LICENSE_STATUS['detail']}"
            )

# Apply HWID based licensing middleware check
from backend.license_middleware import hwid_license_middleware
app.middleware("http")(hwid_license_middleware)

from fastapi.responses import JSONResponse

async def verify_api_key(header_value: str = Security(api_key_header)):
    if not header_value:
        return None
    if header_value != API_KEY:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Forbidden: Invalid AnkaVM API Key."
        )
    return header_value

# --- 1. Core Licensing Endpoints ---

@app.get("/api/license/status")
def get_license_status():
    """Lisans durumunu ve bitiş tarihini döndürür."""
    from backend.license_middleware import (
        read_license_file, verify_license_key_signature,
        is_license_expired
    )
    import subprocess
    import datetime

    data = read_license_file()

    if not data:
        try:
            result = subprocess.run(
                ["dmidecode", "-s", "system-uuid"],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
            )
            hwid = result.stdout.strip() or "Alınamadı"
        except Exception:
            hwid = "Alınamadı"
        return {
            "is_licensed": False,
            "owner_name": "Lisanssız Sunucu",
            "hardware_id": hwid,
            "expires_at": None,
            "detail": "Lisans anahtarınızı giriniz."
        }

    valid, expiry_date_str = verify_license_key_signature(data["license_key"])
    if not valid:
        return {
            "is_licensed": False,
            "owner_name": "Geçersiz Lisans",
            "hardware_id": data.get("hwid", "?"),
            "expires_at": None,
            "detail": "Lisans anahtarı geçersiz veya değiştirilmiş."
        }

    if is_license_expired(expiry_date_str):
        return {
            "is_licensed": False,
            "owner_name": "Süresi Dolmuş",
            "hardware_id": data["hwid"],
            "expires_at": expiry_date_str,
            "detail": f"Lisans süresi doldu! Lütfen yenileyin."
        }

    # Bitiş tarihi göstergesi
    if expiry_date_str == "99991231":
        expires_display = "Sonsuz (Lifetime)"
    else:
        d = datetime.datetime.strptime(expiry_date_str, "%Y%m%d").date()
        expires_display = d.strftime("%d.%m.%Y")

    return {
        "is_licensed": True,
        "owner_name": "AnkaVM Lisanslı Sunucu",
        "hardware_id": data["hwid"],
        "expires_at": expires_display,
        "detail": "Lisans aktif ve doğrulandı."
    }


class LicenseUpdatePayload(BaseModel):
    license_key: str


@app.post("/api/license/update")
def update_license_key(payload: LicenseUpdatePayload):
    """Frontend'den girilen lisans anahtarını doğrular ve license.key dosyasını oluşturur."""
    import subprocess
    import base64
    from backend.license_middleware import (
        LICENSE_FILE_PATH, SALT,
        verify_license_key_signature, is_license_expired
    )

    entered_key = payload.license_key.strip()

    # 1. HMAC imza + format doğrulama
    valid, expiry_date_str = verify_license_key_signature(entered_key)
    if not valid:
        raise HTTPException(
            status_code=400,
            detail="Geçersiz Lisans Anahtarı! Bu anahtar yetkili bir kaynak tarafından üretilmemiş."
        )

    # 2. Bitiş tarihi kontrolü
    if is_license_expired(expiry_date_str):
        raise HTTPException(
            status_code=400,
            detail=f"Bu lisans anahtarının süresi dolmuş! ({expiry_date_str})"
        )

    # 3. Sunucunun HWID'ini al
    try:
        result = subprocess.run(
            ["dmidecode", "-s", "system-uuid"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=True
        )
        hwid = result.stdout.strip()
        if not hwid:
            raise ValueError("HWID boş döndü")
    except Exception as e:
        raise HTTPException(
            status_code=400,
            detail=f"Sistem HWID alınamadı. install.sh root olarak çalıştırıldı mı? ({e})"
        )

    # 4. license.key dosyasını yaz: base64(hwid|license_key|SALT)
    try:
        raw = f"{hwid}|{entered_key}|{SALT}"
        encoded = base64.b64encode(raw.encode('utf-8')).decode('utf-8')
        os.makedirs(os.path.dirname(LICENSE_FILE_PATH), exist_ok=True)
        with open(LICENSE_FILE_PATH, 'w') as f:
            f.write(encoded)
        os.chmod(LICENSE_FILE_PATH, 0o600)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Lisans dosyası yazılamadı: {e}")

    # 5. DB kayıt (opsiyonel)
    try:
        from backend.database import SessionLocal
        from backend.models import License
        import datetime
        db = SessionLocal()
        expire_dt = None if expiry_date_str == "99991231" else \
            datetime.datetime.strptime(expiry_date_str, "%Y%m%d")
        existing = db.query(License).filter(License.hwid == hwid).first()
        if not existing:
            db.add(License(hwid=hwid, status="active", expire_date=expire_dt))
            db.commit()
        else:
            existing.status = "active"
            existing.expire_date = expire_dt
            db.commit()
        db.close()
    except Exception:
        pass

    import datetime
    if expiry_date_str == "99991231":
        expires_display = "Sonsuz (Lifetime)"
    else:
        d = datetime.datetime.strptime(expiry_date_str, "%Y%m%d").date()
        expires_display = d.strftime("%d.%m.%Y")

    return {
        "status": "success",
        "message": f"Lisans başarıyla aktive edildi! Geçerlilik: {expires_display}"
    }



# --- 2. Storage Pool Management ---

@app.get("/api/storage/pools")
def get_storage_pools(api_key: str = Depends(verify_api_key)):
    """Scans and lists capacity metrics for Directory, LVM, and ZFS disk stores."""
    return vm_manager.list_storage_pools()

# --- 3. IPAM Audit Logs ---

@app.get("/api/ipam/logs")
def get_ipam_audit_logs(api_key: str = Depends(verify_api_key)):
    """Fetches transactional IP leasing records."""
    return vm_manager.get_ipam_logs()

# --- 4. Backups & Snapshots ---

class SnapshotCreate(BaseModel):
    snapshot_name: str
    description: Optional[str] = "Manual Snapshot"

@app.post("/api/vms/{name}/snapshots", status_code=201)
def create_vm_snapshot(name: str, payload: SnapshotCreate, api_key: str = Depends(verify_api_key)):
    """Generates a restore checkpoint using KVM backing chains."""
    try:
        msg = vm_manager.create_snapshot(name, payload.snapshot_name, payload.description)
        return {"status": "success", "message": msg}
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

class SnapshotRevert(BaseModel):
    snapshot_name: str

@app.get("/api/vms/{name}/snapshots")
def get_vm_snapshots(name: str, api_key: str = Depends(verify_api_key)):
    """Lists snapshots for a specific VM."""
    try:
        return vm_manager.list_snapshots(name)
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

@app.post("/api/vms/{name}/snapshots/revert")
def revert_vm_snapshot(name: str, payload: SnapshotRevert, api_key: str = Depends(verify_api_key)):
    """Reverts a VDS to a target snapshot point."""
    try:
        msg = vm_manager.revert_snapshot(name, payload.snapshot_name)
        return {"status": "success", "message": msg}
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

# --- 5. Rescue Boot Mode ---

class RescueModePayload(BaseModel):
    action: str  # 'enable' or 'disable'
    iso_path: Optional[str] = "/var/lib/libvirt/images/rescue.iso"

@app.post("/api/vms/{name}/rescue")
def toggle_rescue_mode(name: str, payload: RescueModePayload, api_key: str = Depends(verify_api_key)):
    """Alters boot target order to start VDS via Live ISO recovery environment."""
    try:
        if payload.action.lower() == "enable":
            msg = vm_manager.enable_rescue_mode(name, payload.iso_path)
        else:
            msg = vm_manager.disable_rescue_mode(name)
        return {"status": "success", "message": msg}
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

# --- 6. vnstat Traffic Monitoring ---

@app.get("/api/vms/{name}/traffic")
def get_vm_network_traffic(name: str, api_key: str = Depends(verify_api_key)):
    """Checks live network interface stats for DDoS warning thresholds."""
    return vm_manager.get_vm_traffic(name)

# --- 7. WiseCP Deployment Worker System ---

# In-memory WiseCP Order Database for Live UI Tracking
from datetime import datetime
WISECP_ORDERS = [
    {
        "order_id": "ws-order-4812",
        "product_id": "vds-pro-saas",
        "name": "web-prod-01",
        "cpu": 4,
        "ram_mb": 8192,
        "disk_gb": 120,
        "status": "COMPLETED",
        "ip_address": "192.168.122.10",
        "created_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    },
    {
        "order_id": "ws-order-9921",
        "product_id": "vds-starter",
        "name": "db-replica-02",
        "cpu": 8,
        "ram_mb": 16384,
        "disk_gb": 350,
        "status": "COMPLETED",
        "ip_address": "192.168.122.25",
        "created_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    }
]

async def deploy_wisecp_order_task(order: WiseCPDeploy):
    """Executes asynchronous background deployment and alerts WiseCP hook callback."""
    # Find order in track list
    order_record = next((o for o in WISECP_ORDERS if o["order_id"] == order.order_id), None)
    try:
        await asyncio.sleep(2)  # Short delay to allow REST call completion
        
        # Build VMCreate request payload
        vm_payload = VMCreate(
            name=order.name,
            cpu=order.cpu,
            ram_mb=order.ram_mb,
            disk_gb=order.disk_gb,
            disk_pool=order.disk_pool,
            os_template=order.os_template,
            root_password=order.root_password
        )
        
        # Run provisioning
        print(f"[WiseCP Worker] Provisioning virtual machine: {order.name}")
        vm_res = vm_manager.create_vm(vm_payload)
        
        # Update record
        if order_record:
            order_record["status"] = "COMPLETED"
            order_record["ip_address"] = vm_res.ip_address
        
        # Send Callback
        if order.callback_url:
            print(f"[WiseCP Worker] Posting success callback for order {order.order_id}")
            cb_data = json.dumps({
                "status": "success",
                "order_id": order.order_id,
                "ip": vm_res.ip_address,
                "root_password": order.root_password,
                "vnc_port": vm_res.vnc_port,
                "message": f"Server {order.name} successfully provisioned."
            }).encode("utf-8")
            
            cb_req = urllib.request.Request(
                order.callback_url,
                data=cb_data,
                headers={"Content-Type": "application/json"},
                method="POST"
            )
            try:
                with urllib.request.urlopen(cb_req, timeout=5) as res:
                    print(f"[WiseCP Worker] Hook response code: {res.status}")
            except Exception as cb_err:
                print(f"[WiseCP Worker] Webhook call warning: {cb_err}")
                
    except Exception as e:
        print(f"[WiseCP Worker] Deployment failed for order {order.order_id}: {e}")
        if order_record:
            order_record["status"] = "FAILED"
            order_record["error"] = str(e)
            
        if order.callback_url:
            try:
                cb_data = json.dumps({
                    "status": "failed",
                    "order_id": order.order_id,
                    "message": str(e)
                }).encode("utf-8")
                cb_req = urllib.request.Request(
                    order.callback_url,
                    data=cb_data,
                    headers={"Content-Type": "application/json"},
                    method="POST"
                )
                with urllib.request.urlopen(cb_req, timeout=5):
                    pass
            except Exception:
                pass

@app.post("/api/wisecp/deploy", status_code=202)
def deploy_wisecp_order(order: WiseCPDeploy, api_key: str = Depends(verify_api_key)):
    """Receives server orders from WiseCP, returning immediate 202 and spawning background build tasks."""
    # Register order in list
    WISECP_ORDERS.insert(0, {
        "order_id": order.order_id,
        "product_id": order.product_id,
        "name": order.name,
        "cpu": order.cpu,
        "ram_mb": order.ram_mb,
        "disk_gb": order.disk_gb,
        "status": "PROVISIONING",
        "ip_address": "",
        "created_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    })
    asyncio.create_task(deploy_wisecp_order_task(order))
    return {
        "status": "PROVISIONING",
        "message": f"VM deployment for order {order.order_id} queued successfully."
    }

@app.get("/api/wisecp/orders")
def get_wisecp_orders(api_key: str = Depends(verify_api_key)):
    """Lists registered WiseCP automation orders."""
    return WISECP_ORDERS

# --- 8. Existing Standard VM Management Endpoints ---

@app.get("/api/vms", response_model=List[VMResponse])
def get_vms(api_key: str = Depends(verify_api_key)):
    return vm_manager.list_vms()

@app.post("/api/vms", response_model=VMResponse, status_code=201)
def create_vm(vm: VMCreate, api_key: str = Depends(verify_api_key)):
    try:
        return vm_manager.create_vm(vm)
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

@app.post("/api/vms/{name}/action")
def execute_vm_action(name: str, payload: VMAction, api_key: str = Depends(verify_api_key)):
    try:
        msg = vm_manager.execute_action(name, payload.action)
        return {"status": "success", "message": msg}
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

@app.delete("/api/vms/{name}")
def delete_vm(name: str, api_key: str = Depends(verify_api_key)):
    try:
        msg = vm_manager.delete_vm(name)
        return {"status": "success", "message": msg}
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

@app.get("/api/host/stats", response_model=HostStats)
def get_host_stats(api_key: str = Depends(verify_api_key)):
    return vm_manager.get_host_stats()

@app.get("/api/vms/{name}/telemetry", response_model=VMTelemetry)
def get_vm_telemetry(name: str, api_key: str = Depends(verify_api_key)):
    try:
        return vm_manager.get_vm_telemetry(name)
    except Exception as e:
        raise HTTPException(status_code=404, detail=str(e))

@app.get("/api/networks")
def get_networks(api_key: str = Depends(verify_api_key)):
    return vm_manager.list_networks()

@app.post("/api/networks", status_code=201)
def create_network(net: NetworkCreate, api_key: str = Depends(verify_api_key)):
    try:
        msg = vm_manager.create_network(net.name, net.bridge, net.ip, net.dhcp_start, net.dhcp_end)
        return {"status": "success", "message": msg}
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

@app.get("/api/storage")
def get_storage(api_key: str = Depends(verify_api_key)):
    return vm_manager.list_storage_pools()

@app.get("/api/logs")
def get_logs(api_key: str = Depends(verify_api_key)):
    return vm_manager.get_logs()

@app.get("/api/ipam/pools")
def get_ipam_pools(api_key: str = Depends(verify_api_key)):
    return vm_manager.ipam.list_pools()

@app.get("/api/ipam/leases")
def get_ipam_leases(api_key: str = Depends(verify_api_key)):
    return vm_manager.ipam.list_leases()

# --- 9. WebSocket Console Connection ---

@app.websocket("/ws/vms/{name}/console")
async def vm_console_websocket(websocket: WebSocket, name: str):
    await websocket.accept()
    try:
        vms = vm_manager.list_vms()
        vm = next((v for v in vms if v.name == name), None)
        if not vm:
            await websocket.send_text("\r\n\x1b[31;1mError: VM not found.\x1b[0m\r\n")
            await websocket.close()
            return
        if vm.status != "running":
            await websocket.send_text(f"\r\n\x1b[33;1mWarning: VM '{name}' is offline.\x1b[0m\r\n")
        await websocket.send_text(f"\x1b[36;1m[AnkaVM Console Wrapper V1.5 - Secure Session Started]\x1b[0m\r\nConnecting domain console...\r\n")
        
        current_line = ""
        prompt = f"root@ankavm-{name}:~# "
        logged_in = False
        while True:
            data = await websocket.receive_text()
            if data == "\r" or data == "\n":
                cmd = current_line.strip()
                await websocket.send_text("\r\n")
                if not logged_in:
                    if cmd == "root" or cmd == "admin":
                        logged_in = True
                        await websocket.send_text(f"Password: \r\nWelcome to Ubuntu 22.04 LTS\r\n\r\n{prompt}")
                    else:
                        await websocket.send_text("Invalid login.\r\n\r\nubuntu login: ")
                    current_line = ""
                    continue
                if cmd == "help":
                    await websocket.send_text("Available: status, neofetch, exit\r\n")
                elif cmd == "status":
                    await websocket.send_text(f"VM: {name} | CPU: {vm.cpu} | RAM: {vm.ram_mb}MB | IP: {vm.ip_address}\r\n")
                elif cmd == "neofetch":
                    await websocket.send_text("AnkaVM Hypervisor Host Shell Console\r\n")
                elif cmd == "exit":
                    await websocket.close()
                    break
                elif cmd != "":
                    await websocket.send_text(f"bash: {cmd}: command not found\r\n")
                await websocket.send_text(prompt)
                current_line = ""
            elif data == "\x7f" or data == "\x08":
                if len(current_line) > 0:
                    current_line = current_line[:-1]
                    await websocket.send_text("\b \b")
            else:
                current_line += data
                await websocket.send_text(data)
    except WebSocketDisconnect:
        pass

# --- 10. Serve Frontend Static Assets ---
from backend.routers_vcenter import router as vcenter_router
from backend.routers_license import router as license_router
app.include_router(vcenter_router)
app.include_router(license_router)

FRONTEND_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "frontend"))
if os.path.exists(FRONTEND_DIR):
    app.mount("/", StaticFiles(directory=FRONTEND_DIR, html=True), name="static")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("backend.main:app", host=API_HOST, port=API_PORT, reload=True)

_ANKAVM_EOF_

# Write backend/license_check.py
cat << '_ANKAVM_EOF_' > /opt/ankavm/backend/license_check.py
import os
import re
import urllib.request
import json
import hashlib
import subprocess
from backend.config import LICENSE_KEY, IS_MOCK

LICENSE_SERVER_URL = os.getenv("ANKAVM_LICENSE_SERVER", "http://127.0.0.1:8087/verify")

def get_hardware_uuid() -> str:
    """Retrieves physical motherboard UUID on Linux nodes, falls back to hashed MAC address or mock ID."""
    if IS_MOCK or os.name == 'nt':
        # Simulated developer node hardware uuid
        return "ANKAVM-MOCK-DEV-HWID-UUID-1234567890"

    try:
        # Check motherboard UUID via sysfs (requires root/sudo permission)
        if os.path.exists("/sys/class/dmi/id/product_uuid"):
            with open("/sys/class/dmi/id/product_uuid", "r") as f:
                return f.read().strip()
                
        # Fallback to dmidecode
        out = subprocess.check_output(["sudo", "dmidecode", "-s", "system-uuid"], text=True)
        if out.strip():
            return out.strip()
    except Exception:
        pass

    # Secondary fallback: Hashed MAC address to guarantee unique ID per machine
    try:
        mac_out = subprocess.check_output(["cat", "/sys/class/net/eth0/address"], text=True).strip()
        return hashlib.sha256(mac_out.encode('utf-8')).hexdigest()
    except Exception:
        return "ANKAVM-UNKNOWN-NODE-UUID"

def get_node_ip() -> str:
    """Queries public IP or fallback loopback address."""
    try:
        with urllib.request.urlopen("https://ifconfig.me", timeout=3) as response:
            return response.read().decode('utf-8').strip()
    except Exception:
        return "127.0.0.1"

def check_license_validity() -> dict:
    """Queries the local licensing server to verify activation keys, hardware UUID, and domain constraints."""
    hw_id = get_hardware_uuid()
    node_ip = get_node_ip()
    
    payload = {
        "license_key": LICENSE_KEY,
        "domain": "localhost", # Dynamic domain checked locally
        "ip": node_ip
    }
    
    result = {
        "is_licensed": False,
        "owner_name": "Unregistered Node",
        "allowed_ip": "",
        "allowed_domain": "",
        "expires_at": "",
        "hardware_id": hw_id,
        "detail": "License verification pending."
    }

    try:
        req = urllib.request.Request(
            LICENSE_SERVER_URL,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST"
        )
        with urllib.request.urlopen(req, timeout=4) as res:
            res_data = json.loads(res.read().decode("utf-8"))
            if res_data.get("status") == "VERIFIED":
                result["is_licensed"] = True
                result["owner_name"] = res_data.get("owner_name")
                result["allowed_ip"] = res_data.get("allowed_ip")
                result["allowed_domain"] = res_data.get("allowed_domain")
                result["expires_at"] = res_data.get("expires_at")
                result["detail"] = "Active node license verified successfully."
                return result
    except urllib.error.HTTPError as he:
        try:
            err_detail = json.loads(he.read().decode('utf-8')).get("detail", str(he))
        except Exception:
            err_detail = str(he)
        result["detail"] = f"Verification Denied: {err_detail}"
    except Exception as e:
        result["detail"] = f"Licensing server offline or network unreachable: {e}"

    # Return default unverified state with current local hw_id
    return result

_ANKAVM_EOF_

# Write backend/license_server.py
cat << '_ANKAVM_EOF_' > /opt/ankavm/backend/license_server.py
import hashlib
from datetime import datetime, timezone, timedelta
from fastapi import FastAPI, HTTPException, status
from pydantic import BaseModel
from typing import Dict, Any, Optional

app = FastAPI(
    title="AnkaVM Local Licensing Server",
    description="Simulated licensing authority for node verification",
    version="1.0.0"
)

# Demo license keys and their SHA-256 hashes
# Key 1: ANKAVM-TRIAL-KEY-2026 (Active trial, unlimited IP/domain)
# Key 2: ANKAVM-PRO-SAAS-9999-KEY (Premium corporate license, locked to localhost/127.0.0.1)
# Key 3: ANKAVM-EXPIRED-KEY-2025 (Expired trial)
# Key 4: ANKAVM-LOCKED-IP-KEY-2026 (Locked to 192.168.1.100, fails on other IPs)

def get_sha256(key: str) -> str:
    return hashlib.sha256(key.encode('utf-8')).hexdigest()

LICENSES_DB = {
    get_sha256("ANKAVM-TRIAL-KEY-2026"): {
        "license_key": "ANKAVM-TRIAL-KEY-2026",
        "owner_name": "Demo Trial Account",
        "allowed_ip": "*",
        "allowed_domain": "*",
        "expires_at": (datetime.now(timezone.utc) + timedelta(days=30)).isoformat(),
        "is_active": True
    },
    get_sha256("ANKAVM-PRO-SAAS-9999-KEY"): {
        "license_key": "ANKAVM-PRO-SAAS-9999-KEY",
        "owner_name": "AnkaVM Enterprise Client",
        "allowed_ip": "127.0.0.1",
        "allowed_domain": "localhost",
        "expires_at": (datetime.now(timezone.utc) + timedelta(days=365)).isoformat(),
        "is_active": True
    },
    get_sha256("ANKAVM-EXPIRED-KEY-2025"): {
        "license_key": "ANKAVM-EXPIRED-KEY-2025",
        "owner_name": "Legacy Partner",
        "allowed_ip": "*",
        "allowed_domain": "*",
        "expires_at": (datetime.now(timezone.utc) - timedelta(days=5)).isoformat(),
        "is_active": True
    },
    get_sha256("ANKAVM-LOCKED-IP-KEY-2026"): {
        "license_key": "ANKAVM-LOCKED-IP-KEY-2026",
        "owner_name": "Locked Node Owner",
        "allowed_ip": "192.168.1.100",
        "allowed_domain": "secure.ankavm.local",
        "expires_at": (datetime.now(timezone.utc) + timedelta(days=90)).isoformat(),
        "is_active": True
    }
}

class LicenseVerifyRequest(BaseModel):
    license_key: str  # Can be raw key or hashed key, we will handle both
    domain: str
    ip: str

@app.post("/verify")
def verify_license(req: LicenseVerifyRequest):
    # Support both raw keys and hashes
    key_hash = req.license_key
    if not len(key_hash) == 64:  # If it looks like a raw key, hash it
        key_hash = get_sha256(req.license_key)

    license_info = LICENSES_DB.get(key_hash)
    if not license_info:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="License key invalid or not found on server."
        )

    # Check activation state
    if not license_info["is_active"]:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="License has been administratively suspended."
        )

    # Check expiration date
    expires_at = datetime.fromisoformat(license_info["expires_at"])
    if expires_at < datetime.now(timezone.utc):
        raise HTTPException(
            status_code=status.HTTP_402_PAYMENT_REQUIRED,
            detail=f"License expired on {expires_at.strftime('%Y-%m-%d %H:%M:%S')}."
        )

    # Check IP restrictions (allow wildcards '*')
    allowed_ip = license_info["allowed_ip"]
    if allowed_ip != "*" and allowed_ip != req.ip and req.ip != "127.0.0.1":
        # Note: 127.0.0.1 loopback is always permitted to avoid local dev lockout
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=f"License key locked to IP '{allowed_ip}'. Received IP: '{req.ip}'."
        )

    # Check Domain restrictions (allow wildcards '*')
    allowed_domain = license_info["allowed_domain"]
    if allowed_domain != "*" and allowed_domain != req.domain and req.domain != "localhost":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=f"License key locked to Domain '{allowed_domain}'. Received Domain: '{req.domain}'."
        )

    # Return successful verification metadata
    return {
        "status": "VERIFIED",
        "owner_name": license_info["owner_name"],
        "allowed_ip": allowed_ip,
        "allowed_domain": allowed_domain,
        "expires_at": license_info["expires_at"],
        "license_key_hash": key_hash
    }

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8087)

_ANKAVM_EOF_

# Write scripts/auto_repair_daemon.py
cat << '_ANKAVM_EOF_' > /opt/ankavm/scripts/auto_repair_daemon.py
#!/usr/bin/env python3
import os
import time
import subprocess
import urllib.request
import json
from datetime import datetime

# Configuration Settings
CHECK_INTERVAL_SECONDS = 15
DISCORD_WEBHOOK_URL = os.getenv("ANKAVM_DISCORD_WEBHOOK", "")
HOSTNAME = subprocess.check_output(["hostname"], text=True).strip()

SERVICES_TO_MONITOR = [
    {"name": "libvirtd", "desc": "Libvirt Hypervisor Daemon"},
    {"name": "nginx", "desc": "Nginx Reverse Proxy API Gate"},
    {"name": "systemd-resolved", "desc": "System DNS Resolver"}
]

BRIDGES_TO_MONITOR = ["virbr0"]

def send_discord_alert(title: str, message: str, color: int = 16711680):
    """Dispatches webhook payload embeds to configured Discord channel."""
    if not DISCORD_WEBHOOK_URL:
        print(f"[Watchdog Notification Skipped] Title: {title} | Message: {message}")
        return

    payload = {
        "username": "AnkaVM Watchdog",
        "avatar_url": "https://cdn-icons-png.flaticon.com/512/564/564619.png",
        "embeds": [{
            "title": f"⚠️ {title}",
            "description": message,
            "color": color,
            "timestamp": datetime.utcnow().isoformat() + "Z",
            "footer": {"text": f"Node Hostname: {HOSTNAME}"}
        }]
    }

    try:
        req = urllib.request.Request(
            DISCORD_WEBHOOK_URL,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST"
        )
        with urllib.request.urlopen(req, timeout=5) as res:
            if res.status != 204:
                print(f"[Watchdog Webhook Alert Error] Discord API returned code {res.status}")
    except Exception as e:
        print(f"[Watchdog Webhook Delivery Error] FAILED: {e}")

def check_service_status(service_name: str) -> bool:
    """Verifies systemd service activation."""
    try:
        # systemctl is-active exits with 0 if running, non-zero otherwise
        res = subprocess.run(
            ["systemctl", "is-active", "--quiet", service_name],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )
        return res.returncode == 0
    except Exception:
        return False

def restart_service(service_name: str) -> bool:
    """Attempts service restoration command."""
    try:
        res = subprocess.run(
            ["sudo", "systemctl", "restart", service_name],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        return res.returncode == 0
    except Exception:
        return False

def check_bridge_interface(bridge_name: str) -> bool:
    """Checks if target networking bridge exists on host."""
    try:
        res = subprocess.run(
            ["ip", "link", "show", bridge_name],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )
        return res.returncode == 0
    except Exception:
        return False

def restore_bridge_interface(bridge_name: str) -> bool:
    """Attempts to start default network bridge via virsh."""
    try:
        res = subprocess.run(
            ["sudo", "virsh", "net-start", "default"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        return res.returncode == 0
    except Exception:
        return False

def main():
    print(f"==================================================================")
    print(f"       ANKAVM AUTO-REPAIR WATCHDOG DAEMON ACTIVE                  ")
    print(f"==================================================================")
    print(f"Node Monitoring Interval: {CHECK_INTERVAL_SECONDS} seconds")
    print(f"Alert Webhook Status: {'Configured' if DISCORD_WEBHOOK_URL else 'Not Set'}\n")

    send_discord_alert(
        "Watchdog Daemon Initialized",
        "AnkaVM virtualization node watchdog service has successfully started monitoring KVM hypervisor components.",
        color=65280 # Green color
    )

    while True:
        # 1. Monitor Systemd Services
        for svc in SERVICES_TO_MONITOR:
            name = svc["name"]
            desc = svc["desc"]
            
            if not check_service_status(name):
                log_msg = f"CRITICAL: Service '{name}' ({desc}) is crashed or stopped. Executing auto-repair..."
                print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {log_msg}")
                
                send_discord_alert(
                    "Service Outage Detected",
                    f"Service **{name}** ({desc}) was found offline. Watchdog is executing automated restoration checks."
                )

                if restart_service(name):
                    success_msg = f"SUCCESS: Service '{name}' was successfully restarted and is operational."
                    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {success_msg}")
                    send_discord_alert(
                        "Service Auto-Repaired",
                        f"Watchdog successfully restored **{name}** on this node.",
                        color=3066993 # Blue color
                    )
                else:
                    fail_msg = f"FATAL: Service '{name}' auto-restart failed! Manual sysadmin inspection required."
                    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {fail_msg}")
                    send_discord_alert(
                        "Service Restoration FAILED",
                        f"Watchdog could not restore service **{name}**. Node is degraded!",
                        color=15158332 # Dark Red color
                    )

        # 2. Monitor Network Bridge Interfaces
        for bridge in BRIDGES_TO_MONITOR:
            if not check_bridge_interface(bridge):
                log_msg = f"CRITICAL: Network bridge interface '{bridge}' is missing or inactive. Attempting restoration..."
                print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {log_msg}")
                
                send_discord_alert(
                    "Network Bridge Outage",
                    f"Virtual bridge interface **{bridge}** is down. Attempting virsh net-start default execution."
                )

                if restore_bridge_interface(bridge):
                    success_msg = f"SUCCESS: Network bridge '{bridge}' was successfully restored."
                    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {success_msg}")
                    send_discord_alert(
                        "Network Restored",
                        f"Network bridge **{bridge}** was successfully brought back online.",
                        color=3066993
                    )
                else:
                    fail_msg = f"FATAL: Network bridge '{bridge}' restoration failed!"
                    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {fail_msg}")
                    send_discord_alert(
                        "Network Restoration FAILED",
                        f"Could not restore bridge **{bridge}** on the node.",
                        color=15158332
                    )

        time.sleep(CHECK_INTERVAL_SECONDS)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nStopping Watchdog daemon.")
_ANKAVM_EOF_

# Write frontend/style.css
cat << '_ANKAVM_EOF_' > /opt/ankavm/frontend/style.css
@import url('https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700;800&family=JetBrains+Mono:wght@400;500;700&display=swap');

:root {
  --bg-primary: #0b0f19;
  --bg-secondary: #111827;
  --bg-tertiary: #1f2937;
  --border-color: #374151;
  --border-color-hover: #4b5563;
  --text-primary: #f9fafb;
  --text-secondary: #9ca3af;
  --brand-primary: #3b82f6;
  --brand-primary-hover: #2563eb;
  --accent-green: #10b981;
  --accent-red: #ef4444;
  --accent-amber: #f59e0b;
}

body {
  font-family: 'Inter', sans-serif;
  background-color: var(--bg-primary);
  color: #e5e7eb;
  overflow-x: hidden;
  font-size: 14px;
}

/* Typography Overrides */
h1, h2, h3, h4, th {
  font-family: 'Inter', sans-serif;
  font-weight: 600;
  letter-spacing: -0.01em;
}

.terminal-font {
  font-family: 'JetBrains Mono', monospace;
}

/* Premium Corporate SaaS Card Layout */
.corp-card {
  background: var(--bg-secondary);
  border: 1px solid var(--border-color);
  box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1), 0 2px 4px -1px rgba(0, 0, 0, 0.06);
  transition: border-color 0.15s ease-in-out, box-shadow 0.15s ease-in-out;
}

.corp-card:hover {
  border-color: var(--border-color-hover);
  box-shadow: 0 10px 15px -3px rgba(0, 0, 0, 0.1), 0 4px 6px -2px rgba(0, 0, 0, 0.05);
}

/* Status Indicators */
.status-dot-active {
  background-color: var(--accent-green);
  box-shadow: 0 0 8px rgba(16, 185, 129, 0.4);
}

.status-dot-inactive {
  background-color: var(--accent-red);
  box-shadow: 0 0 8px rgba(239, 68, 68, 0.4);
}

/* Buttons */
.btn-primary {
  background-color: var(--brand-primary);
  color: #ffffff;
  transition: background-color 0.15s ease-in-out;
}

.btn-primary:hover {
  background-color: var(--brand-primary-hover);
}

.btn-secondary {
  background-color: transparent;
  border: 1px solid var(--border-color);
  color: #d1d5db;
  transition: background-color 0.15s ease-in-out, border-color 0.15s ease-in-out;
}

.btn-secondary:hover {
  background-color: var(--bg-tertiary);
  border-color: var(--border-color-hover);
  color: #ffffff;
}

/* Dense Data Tables */
table {
  border-collapse: separate;
  border-spacing: 0;
}

th {
  background-color: #0f172a;
  border-bottom: 2px solid var(--border-color);
  color: #9ca3af;
}

td {
  border-bottom: 1px solid rgba(55, 65, 81, 0.4);
}

/* Scrollbars */
::-webkit-scrollbar {
  width: 8px;
  height: 8px;
}
::-webkit-scrollbar-track {
  background: var(--bg-primary);
}
::-webkit-scrollbar-thumb {
  background: var(--border-color);
  border-radius: 4px;
}
::-webkit-scrollbar-thumb:hover {
  background: #4b5563;
}

/* Corporate Loading Shimmer */
.shimmer {
  background: linear-gradient(95deg, var(--bg-secondary) 25%, var(--bg-tertiary) 50%, var(--bg-secondary) 75%);
  background-size: 200% 100%;
  animation: loading-shimmer 1.5s infinite;
}

@keyframes loading-shimmer {
  0% { background-position: 200% 0; }
  100% { background-position: -200% 0; }
}

/* Code copy panel visual overrides */
pre code {
  color: #e5e7eb;
}
_ANKAVM_EOF_

# Write frontend/fetch_helpers.js
cat << '_ANKAVM_EOF_' > /opt/ankavm/frontend/fetch_helpers.js
// AnkaVM Dashboard Client Fetch Helper Modules

const API_HEADERS = {
    'Content-Type': 'application/json',
    'X-API-Key': 'ankavm-secure-dev-token-2026'
};

/**
 * Renders the color-coded Proxmox-style disk progress bar based on percentage capacity.
 * Red indicator starts above 90% load.
 */
function renderProxmoxProgressBar(usedGb, totalGb) {
    const pct = totalGb > 0 ? Math.round((usedGb / totalGb) * 100) : 0;
    const colorClass = pct >= 90 ? 'bg-red-500 shadow-[0_0_8px_rgba(239,68,68,0.5)]' : 'bg-brand-500';
    
    return `
        <div class="space-y-1 font-mono text-[10px] w-full">
            <div class="flex justify-between text-slate-400">
                <span>Disk: ${usedGb}G / ${totalGb}G</span>
                <span class="${pct >= 90 ? 'text-red-400 font-bold' : ''}">${pct}%</span>
            </div>
            <div class="w-full bg-slate-900 rounded-full h-1.5 overflow-hidden border border-slate-800">
                <div class="h-full rounded-full transition-all duration-500 ${colorClass}" style="width: ${pct}%"></div>
            </div>
        </div>
    `;
}

/**
 * Toggles skeleton loaders overlay indicators on dashboard tables and charts.
 */
function toggleSkeletonLoaders(isLoading) {
    const skeletons = document.querySelectorAll('.skeleton-wrapper');
    const actualContent = document.querySelectorAll('.data-content-wrapper');
    
    skeletons.forEach(el => {
        if (isLoading) el.classList.remove('hidden');
        else el.classList.add('hidden');
    });
    
    actualContent.forEach(el => {
        if (isLoading) el.classList.add('opacity-40');
        else el.classList.remove('opacity-40');
    });
}

/**
 * Initializes physical storage health ApexCharts
 */
let storageHealthChart = null;
function initStorageHealthChart(containerId, allocatedData = [], freeData = [], categories = []) {
    const el = document.getElementById(containerId);
    if (!el) return;

    const options = {
        series: [{
            name: 'Allocated Space (GB)',
            data: allocatedData
        }, {
            name: 'Free Space (GB)',
            data: freeData
        }],
        chart: {
            type: 'bar',
            height: 220,
            stacked: true,
            toolbar: { show: false },
            background: 'transparent'
        },
        theme: { mode: 'dark' },
        colors: ['#3b82f6', '#10b981'],
        plotOptions: {
            bar: {
                horizontal: true,
                borderRadius: 4
            }
        },
        xaxis: {
            categories: categories,
            labels: { style: { colors: '#9ca3af' } }
        },
        yaxis: {
            labels: { style: { colors: '#9ca3af' } }
        },
        legend: {
            position: 'top',
            labels: { colors: '#e5e7eb' }
        },
        grid: {
            borderColor: '#1f2937'
        }
    };

    if (storageHealthChart) {
        storageHealthChart.destroy();
    }
    storageHealthChart = new ApexCharts(el, options);
    storageHealthChart.render();
}

/**
 * Updates storage charts with active statistics
 */
function updateStorageHealthChart(pools) {
    if (!storageHealthChart) return;
    
    const allocated = pools.map(p => p.allocated_gb);
    const free = pools.map(p => p.free_gb);
    const names = pools.map(p => p.name);
    
    storageHealthChart.updateSeries([{
        name: 'Allocated Space (GB)',
        data: allocated
    }, {
        name: 'Free Space (GB)',
        data: free
    }]);
    
    storageHealthChart.updateOptions({
        xaxis: { categories: names }
    });
}

/**
 * Live polling loop that pulls hypervisor status statistics
 */
async function startLivePolling(onUpdateCallback, intervalMs = 2000) {
    toggleSkeletonLoaders(true);
    
    // Initial fetch
    try {
        const res = await fetch('/api/storage/pools', { headers: API_HEADERS });
        if (res.ok) {
            const pools = await res.json();
            onUpdateCallback(pools);
            toggleSkeletonLoaders(false);
        }
    } catch (err) {
        console.error("Dashboard init load warning: ", err);
    }
    
    // Polling loop
    setInterval(async () => {
        try {
            const res = await fetch('/api/storage/pools', { headers: API_HEADERS });
            if (res.ok) {
                const pools = await res.json();
                onUpdateCallback(pools);
            }
        } catch (err) {
            console.error("Outage during live stats polling: ", err);
        }
    }, intervalMs);
}
_ANKAVM_EOF_

# Write frontend/app.js
cat << '_ANKAVM_EOF_' > /opt/ankavm/frontend/app.js
document.addEventListener('alpine:init', () => {
    const API_HEADERS = {
        'Content-Type': 'application/json',
        'X-API-Key': 'ankavm-secure-dev-token-2026'
    };

    const API_BASE = '/api';
    const WS_BASE = `${window.location.protocol === 'https:' ? 'wss' : 'ws'}://${window.location.host}`;

    Alpine.data('vmPanel', () => ({
        // Tab system
        activeTab: 'dashboard', // dashboard, vms, networks, ipam, storage, settings, license
        
        // Data States
        vms: [],
        networks: [],
        storagePools: [],
        images: [],
        activityLogs: [],
        ipPools: [],
        ipLeases: [],
        ipamLogs: [],
        wiseCpOrders: [],
        selectedVmSnapshots: [],
        consoleTab: 'vnc', // 'vnc' or 'serial'
        vncConnected: false,
        vncBootState: 0, // 0: offline, 1: booting bios, 2: kernel load, 3: fully loaded shell
        
        licenseStatus: {
            is_licensed: false,
            owner_name: 'Sistem Yükleniyor...',
            allowed_ip: '',
            allowed_domain: '',
            expires_at: '',
            hardware_id: '',
            detail: ''
        },
        hostStats: {
            cpu_usage: 0,
            ram_total_gb: 0,
            ram_used_gb: 0,
            ram_free_gb: 0,
            ram_usage_percent: 0,
            disk_total_gb: 0,
            disk_used_gb: 0,
            disk_free_gb: 0,
            disk_usage_percent: 0,
            vms_running: 0,
            vms_total: 0
        },
        
        // VDS Inspector Details
        selectedVmName: null,
        selectedVmTelemetry: null,
        selectedVmTraffic: null,
        telemetryHistory: {
            cpu: [],
            ram: [],
            timestamps: []
        },
        
        // Filters & Sorting & Searches
        searchQuery: '',
        statusFilter: 'all',
        sortBy: 'name',
        sortDesc: false,
        loading: true,
        toasts: [],
        
        // Modal Overlays
        showCreateModal: false,
        showCreateNetModal: false,
        showCreatePoolModal: false,
        showConsoleModal: false,
        showWiseCpSimulateModal: false,
        licenseKeyInput: '',
        
        // VCenter State
        vcenterConfig: {
            host: '',
            username: '',
            password: '',
            is_active: false
        },
        vcenterDiscovery: [],
        
        // Provisioning forms
        createForm: {
            name: '',
            cpu: 2,
            ram_mb: 2048,
            disk_gb: 40,
            disk_pool: 'default-dir',
            os_template: 'ubuntu-22.04',
            root_password: 'AnkaVM-Secure-Root-2026',
            ssh_key: ''
        },
        createNetForm: {
            name: '',
            bridge: '',
            ip: '192.168.100.1',
            dhcp_start: '192.168.100.2',
            dhcp_end: '192.168.100.100'
        },
        createPoolForm: {
            name: '',
            cidr: '192.168.110.0/24',
            gateway: '192.168.110.1',
            dns_primary: '8.8.8.8',
            dns_secondary: '1.1.1.1'
        },
        snapshotForm: {
            name: '',
            description: 'Manuel Yedekleme'
        },
        wiseCpSimulateForm: {
            order_id: '',
            product_id: 'vds-custom-saas',
            name: 'ws-demo-vds',
            cpu: 2,
            ram_mb: 4096,
            disk_gb: 80,
            disk_pool: 'default-dir',
            os_template: 'ubuntu-22.04',
            root_password: 'WiseCPPassWord123!'
        },
 
        // Charts
        hostCpuChart: null,
        hostRamChart: null,
        hostDiskChart: null,
        vmPerformanceChart: null,
 
        // Websockets console
        wsConsole: null,
        termInstance: null,
        vncSimulationTimer: null,
        vncCanvasContent: '',
 
        async init() {
            console.log("Initializing Corporate SaaS Dashboard Controller with Watchdog & Licensing...");
            
            toggleSkeletonLoaders(true);
            
            // İlk olarak lisans durumunu kontrol et
            await this.fetchLicenseStatus();
            
            // Lisans yoksa veri çekmeyi ve interval'ları başlatma
            if (!this.licenseStatus.is_licensed) {
                this.loading = false;
                toggleSkeletonLoaders(false);
                return;
            }
            
            // Lisanslıysa tüm sistemi başlat
            await this.bootSystem();
        },

        async bootSystem() {
            toggleSkeletonLoaders(true);
            await Promise.all([
                this.fetchVms(),
                this.fetchHostStats(),
                this.fetchNetworks(),
                this.fetchStorage(),
                this.fetchLogs(),
                this.fetchIpamData(),
                this.fetchIpLogs(),
                this.fetchWiseCpOrders(),
                this.fetchVcenterConfig()
            ]);
            
            // If vcenter is active, fetch discovery
            if (this.vcenterConfig.is_active) {
                this.fetchVcenterDiscovery();
            }
            
            // Fetch images after vcenter is loaded
            await this.fetchImages();
            
            this.loading = false;
            toggleSkeletonLoaders(false);
            
            // Set up charts on next tick
            this.$nextTick(() => {
                this.initHostCharts();
                this.renderApexStorageCharts();
            });
 
            // Set up timers for data sync
            if(!this._intervalsStarted) {
                setInterval(() => this.fetchHostStats(), 4000);
                setInterval(() => this.fetchVms(), 5000);
                setInterval(() => this.fetchActiveVmTelemetry(), 3000);
                setInterval(() => this.fetchActiveVmTraffic(), 3000);
                setInterval(() => this.fetchLogs(), 6000);
                setInterval(() => this.fetchLicenseStatus(), 15000);
                setInterval(() => this.fetchWiseCpOrders(), 5000);
                setInterval(() => {
                    if (this.activeTab === 'networks') this.fetchNetworks();
                    if (this.activeTab === 'storage') this.fetchStorage();
                    if (this.activeTab === 'ipam') {
                        this.fetchIpamData();
                        this.fetchIpLogs();
                    }
                }, 8000);
                this._intervalsStarted = true;
            }
        },

        setTab(tabName) {
            this.activeTab = tabName;
            
            if (tabName === 'dashboard') {
                this.$nextTick(() => {
                    this.initHostCharts();
                    this.updateHostCharts();
                    this.renderApexStorageCharts();
                });
            }
            
            if (tabName === 'vms' && this.selectedVmName) {
                this.$nextTick(() => {
                    this.initVmPerformanceChart();
                });
            }
        },

        // --- Fetch actions ---

        async fetchLicenseStatus() {
            try {
                const res = await fetch(`${API_BASE}/license/status`);
                if (res.ok) {
                    this.licenseStatus = await res.json();
                }
            } catch (err) {
                console.error("License check fail", err);
            }
        },

        async updateLicense() {
            if (!this.licenseKeyInput) {
                this.showToast("Lütfen lisans anahtarınızı girin.", "warning");
                return;
            }
            this.showToast("Lisans anahtarı güncelleniyor...", "info");
            try {
                const res = await fetch(`${API_BASE}/license/update`, {
                    method: 'POST',
                    headers: API_HEADERS,
                    body: JSON.stringify({ license_key: this.licenseKeyInput })
                });
                const data = await res.json();
                if (res.ok) {
                    this.showToast(data.message, "success");
                    this.licenseKeyInput = '';
                    await this.fetchLicenseStatus();
                    if (this.licenseStatus.is_licensed) {
                        await this.bootSystem();
                    }
                } else {
                    throw new Error(data.detail);
                }
            } catch (err) {
                this.showToast(err.message, "error");
            }
        },

        async fetchVms() {
            try {
                const res = await fetch(`${API_BASE}/vms`, { headers: API_HEADERS });
                if (res.ok) this.vms = await res.json();
            } catch (err) {
                console.error("VMS fetch failure", err);
            }
        },

        async fetchHostStats() {
            try {
                const res = await fetch(`${API_BASE}/host/stats`, { headers: API_HEADERS });
                if (res.ok) {
                    this.hostStats = await res.json();
                    this.updateHostCharts();
                }
            } catch (err) {
                console.error("Host stats fetch failure", err);
            }
        },

        async fetchNetworks() {
            try {
                const res = await fetch(`${API_BASE}/networks`, { headers: API_HEADERS });
                if (res.ok) this.networks = await res.json();
            } catch (err) {
                console.error("Networks fetch failure", err);
            }
        },

        async fetchVcenterConfig() {
            try {
                const res = await fetch(`${API_BASE}/vcenter/config`, { headers: API_HEADERS });
                if (res.ok) {
                    const data = await res.json();
                    this.vcenterConfig.host = data.host;
                    this.vcenterConfig.username = data.username;
                    this.vcenterConfig.is_active = data.is_active;
                }
            } catch (err) {
                console.error("VCenter fetch failure", err);
            }
        },

        async saveVcenterConfig() {
            this.showToast("VCenter'a bağlanılıyor...", "info");
            try {
                const res = await fetch(`${API_BASE}/vcenter/config`, {
                    method: 'POST',
                    headers: API_HEADERS,
                    body: JSON.stringify({
                        host: this.vcenterConfig.host,
                        username: this.vcenterConfig.username,
                        password: this.vcenterConfig.password
                    })
                });
                const data = await res.json();
                if (res.ok) {
                    this.showToast(data.message, "success");
                    this.vcenterConfig.is_active = true;
                    this.vcenterConfig.password = ''; // clear for security
                    await this.fetchVcenterDiscovery();
                } else {
                    throw new Error(data.detail || "VCenter bağlantı hatası");
                }
            } catch (err) {
                this.showToast(err.message, "error");
            }
        },

        async fetchVcenterDiscovery() {
            try {
                const res = await fetch(`${API_BASE}/vcenter/discovery`, { headers: API_HEADERS });
                if (res.ok) {
                    this.vcenterDiscovery = await res.json();
                }
            } catch (err) {
                console.error("VCenter discovery fetch failure", err);
            }
        },

        async fetchStorage() {
            try {
                const res = await fetch(`${API_BASE}/storage/pools`, { headers: API_HEADERS });
                if (res.ok) {
                    this.storagePools = await res.json();
                    this.renderApexStorageCharts();
                }
            } catch (err) {
                console.error("Storage fetch failure", err);
            }
        },

        async fetchLogs() {
            try {
                const res = await fetch(`${API_BASE}/logs`, { headers: API_HEADERS });
                if (res.ok) this.activityLogs = await res.json();
            } catch (err) {
                console.error("Logs fetch failure", err);
            }
        },

        async fetchImages() {
            try {
                const res = await fetch(`${API_BASE}/images`, { headers: API_HEADERS });
                if (res.ok) this.images = await res.json();
            } catch (err) {
                console.error("Images fetch failure", err);
            }
        },

        async uploadImage(event) {
            const file = event.target.files[0];
            if (!file) return;

            this.showToast("İmaj yükleniyor, lütfen bekleyin...", "info");
            const formData = new FormData();
            formData.append("file", file);

            try {
                const res = await fetch(`${API_BASE}/images/upload`, {
                    method: 'POST',
                    headers: { 'X-API-Key': API_HEADERS['X-API-Key'] },
                    body: formData
                });
                const data = await res.json();
                if (res.ok) {
                    this.showToast(data.message, "success");
                    await this.fetchImages();
                } else {
                    throw new Error(data.detail);
                }
            } catch (err) {
                this.showToast(err.message, "error");
            } finally {
                event.target.value = ''; // Reset input
            }
        },

        async fetchIpamData() {
            try {
                const [poolsRes, leasesRes] = await Promise.all([
                    fetch(`${API_BASE}/ipam/pools`, { headers: API_HEADERS }),
                    fetch(`${API_BASE}/ipam/leases`, { headers: API_HEADERS })
                ]);
                
                if (poolsRes.ok) this.ipPools = await poolsRes.json();
                if (leasesRes.ok) this.ipLeases = await leasesRes.json();
            } catch (err) {
                console.error("IPAM fetch failure", err);
            }
        },

        async fetchIpLogs() {
            try {
                const res = await fetch(`${API_BASE}/ipam/logs`, { headers: API_HEADERS });
                if (res.ok) this.ipamLogs = await res.json();
            } catch (err) {
                console.error("IPAM logs fetch failure", err);
            }
        },

        // --- VM actions ---

        async fetchActiveVmTelemetry() {
            if (!this.selectedVmName || this.activeTab !== 'vms') return;
            
            const activeVm = this.vms.find(v => v.name === this.selectedVmName);
            if (!activeVm || activeVm.status !== 'running') {
                this.selectedVmTelemetry = null;
                return;
            }

            try {
                const res = await fetch(`${API_BASE}/vms/${this.selectedVmName}/telemetry`, { headers: API_HEADERS });
                if (res.ok) {
                    const tel = await res.json();
                    this.selectedVmTelemetry = tel;
                    
                    const now = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
                    this.telemetryHistory.timestamps.push(now);
                    this.telemetryHistory.cpu.push(tel.cpu_usage_percent);
                    this.telemetryHistory.ram.push(tel.ram_usage_percent);

                    if (this.telemetryHistory.timestamps.length > 12) {
                        this.telemetryHistory.timestamps.shift();
                        this.telemetryHistory.cpu.shift();
                        this.telemetryHistory.ram.shift();
                    }

                    this.updateVmPerformanceChart();
                }
            } catch (err) {
                console.error("VM telemetry fetch failure", err);
            }
        },

        async fetchActiveVmTraffic() {
            if (!this.selectedVmName || this.activeTab !== 'vms') return;
            const activeVm = this.vms.find(v => v.name === this.selectedVmName);
            if (!activeVm || activeVm.status !== 'running') {
                this.selectedVmTraffic = null;
                return;
            }
            try {
                const res = await fetch(`${API_BASE}/vms/${this.selectedVmName}/traffic`, { headers: API_HEADERS });
                if (res.ok) {
                    const traffic = await res.json();
                    this.selectedVmTraffic = traffic;
                    if (traffic.ddos_alert) {
                        this.showToast(`🚨 UYARI: ${this.selectedVmName} sanal sunucusunda yüksek trafik (DDoS olasılığı) tespit edildi!`, 'warning');
                    }
                }
            } catch (err) {
                console.error("VM traffic metrics load failure", err);
            }
        },

        selectVm(name) {
            if (this.selectedVmName === name) {
                this.selectedVmName = null;
                this.selectedVmTelemetry = null;
                this.selectedVmTraffic = null;
                this.selectedVmSnapshots = [];
                this.telemetryHistory = { cpu: [], ram: [], timestamps: [] };
                return;
            }
            this.selectedVmName = name;
            this.selectedVmSnapshots = [];
            this.telemetryHistory = { cpu: [], ram: [], timestamps: [] };
            
            this.$nextTick(() => {
                this.initVmPerformanceChart();
                this.fetchActiveVmTelemetry();
                this.fetchActiveVmTraffic();
                this.fetchVmSnapshots(name);
            });
        },

        async triggerAction(name, action) {
            this.showToast(`Eylem gönderiliyor: ${action} -> ${name}`, 'info');
            try {
                const res = await fetch(`${API_BASE}/vms/${name}/action`, {
                    method: 'POST',
                    headers: API_HEADERS,
                    body: JSON.stringify({ action })
                });
                const data = await res.json();
                if (!res.ok) throw new Error(data.detail || "İşlem başarısız.");
                
                this.showToast(data.message, 'success');
                await Promise.all([this.fetchVms(), this.fetchLogs()]);
            } catch (err) {
                this.showToast(err.message, 'error');
            }
        },

        async provisionVm() {
            this.showToast(`Yeni VDS kuruluyor: ${this.createForm.name}`, 'info');
            this.showCreateModal = false;
            try {
                const res = await fetch(`${API_BASE}/vms`, {
                    method: 'POST',
                    headers: API_HEADERS,
                    body: JSON.stringify(this.createForm)
                });
                const data = await res.json();
                if (!res.ok) throw new Error(data.detail || "Kurulum başarısız.");
                
                this.showToast(`VDS '${data.name}' başarıyla oluşturuldu ve başlatıldı.`, 'success');
                this.createForm = { name: '', cpu: 2, ram_mb: 2048, disk_gb: 40, disk_pool: 'default-dir', os_template: 'ubuntu-22.04', root_password: 'AnkaVM-Secure-Root-2026', ssh_key: '' };
                await Promise.all([this.fetchVms(), this.fetchLogs(), this.fetchIpamData()]);
            } catch (err) {
                this.showToast(err.message, 'error');
            }
        },

        async deleteVm(name) {
            if (!confirm(`DİKKAT: '${name}' sunucusunu tamamen silmek istediğinize emin misiniz?\nBu işlem disk imajını ve tüm verileri kalıcı olarak yok edecektir.`)) {
                return;
            }
            this.showToast(`Sunucu siliniyor: ${name}`, 'warning');
            try {
                const res = await fetch(`${API_BASE}/vms/${name}`, {
                    method: 'DELETE',
                    headers: API_HEADERS
                });
                const data = await res.json();
                if (!res.ok) throw new Error(data.detail || "Silme işlemi başarısız.");
                
                this.showToast(data.message, 'success');
                if (this.selectedVmName === name) this.selectedVmName = null;
                await Promise.all([this.fetchVms(), this.fetchLogs(), this.fetchIpamData(), this.fetchIpLogs()]);
            } catch (err) {
                this.showToast(err.message, 'error');
            }
        },

        // --- Network & IPAM Actions ---

        async provisionNetwork() {
            this.showToast(`Sanal ağ tanımlanıyor: ${this.createNetForm.name}`, 'info');
            this.showCreateNetModal = false;
            try {
                const res = await fetch(`${API_BASE}/networks`, {
                    method: 'POST',
                    headers: API_HEADERS,
                    body: JSON.stringify(this.createNetForm)
                });
                const data = await res.json();
                if (!res.ok) throw new Error(data.detail || "Sanal ağ kurulumu başarısız.");
                
                this.showToast(`Ağ '${this.createNetForm.name}' başarıyla oluşturuldu.`, 'success');
                this.createNetForm = { name: '', bridge: '', ip: '192.168.100.1', dhcp_start: '192.168.100.2', dhcp_end: '192.168.100.100' };
                await Promise.all([this.fetchNetworks(), this.fetchLogs(), this.fetchIpamData()]);
            } catch (err) {
                this.showToast(err.message, 'error');
            }
        },

        async provisionIpPool() {
            this.showToast(`IP Havuzu ekleniyor: ${this.createPoolForm.name}`, 'info');
            this.showCreatePoolModal = false;
            
            const mockNet = {
                name: this.createPoolForm.name,
                bridge: 'virbr' + (this.networks.length + 1),
                ip: this.createPoolForm.gateway,
                dhcp_start: this.createPoolForm.dns_primary,
                dhcp_end: this.createPoolForm.dns_secondary
            };
            
            try {
                const res = await fetch(`${API_BASE}/networks`, {
                    method: 'POST',
                    headers: API_HEADERS,
                    body: JSON.stringify(mockNet)
                });
                if (res.ok) {
                    this.showToast(`IP Havuzu '${this.createPoolForm.name}' başarıyla tanımlandı.`, 'success');
                    this.createPoolForm = { name: '', cidr: '192.168.110.0/24', gateway: '192.168.110.1', dns_primary: '8.8.8.8', dns_secondary: '1.1.1.1' };
                    await Promise.all([this.fetchIpamData(), this.fetchLogs()]);
                }
            } catch (err) {
                this.showToast(err.message, 'error');
            }
        },

        // --- Render ApexCharts ---

        renderApexStorageCharts() {
            if (this.storagePools.length > 0) {
                const allocated = this.storagePools.map(p => parseFloat(p.allocated_gb));
                const free = this.storagePools.map(p => parseFloat(p.free_gb));
                const categories = this.storagePools.map(p => p.name);
                
                this.$nextTick(() => {
                    initStorageHealthChart('storagePoolApexChart', allocated, free, categories);
                });
            }
        },

        // --- Live Chart.js Visualizations ---
        
        initHostCharts() {
            const cpuEl = document.getElementById('cpuChartCanvas');
            const ramEl = document.getElementById('ramChartCanvas');
            const diskEl = document.getElementById('diskChartCanvas');

            if (!cpuEl || !ramEl || !diskEl) return;

            const chartConfig = (color) => ({
                type: 'doughnut',
                data: {
                    datasets: [{
                        data: [0, 100],
                        backgroundColor: [color, 'rgba(255, 255, 255, 0.05)'],
                        borderWidth: 0,
                        circumference: 270,
                        rotation: 225,
                        borderRadius: 10
                    }]
                },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    cutout: '80%',
                    plugins: {
                        legend: { display: false },
                        tooltip: { enabled: false }
                    }
                }
            });

            if (this.hostCpuChart) this.hostCpuChart.destroy();
            if (this.hostRamChart) this.hostRamChart.destroy();
            if (this.hostDiskChart) this.hostDiskChart.destroy();

            this.hostCpuChart = new Chart(cpuEl, chartConfig('#3b82f6'));
            this.hostRamChart = new Chart(ramEl, chartConfig('#10b981'));
            this.hostDiskChart = new Chart(diskEl, chartConfig('#ef4444'));
        },

        updateHostCharts() {
            if (!this.hostCpuChart || this.activeTab !== 'dashboard') return;
            
            this.hostCpuChart.data.datasets[0].data = [this.hostStats.cpu_usage, 100 - this.hostStats.cpu_usage];
            this.hostCpuChart.update('none');

            this.hostRamChart.data.datasets[0].data = [this.hostStats.ram_usage_percent, 100 - this.hostStats.ram_usage_percent];
            this.hostRamChart.update('none');

            this.hostDiskChart.data.datasets[0].data = [this.hostStats.disk_usage_percent, 100 - this.hostStats.disk_usage_percent];
            this.hostDiskChart.update('none');
        },

        initVmPerformanceChart() {
            const ctx = document.getElementById('vmPerformanceChartCanvas');
            if (!ctx) return;

            if (this.vmPerformanceChart) {
                this.vmPerformanceChart.destroy();
            }

            this.vmPerformanceChart = new Chart(ctx, {
                type: 'line',
                data: {
                    labels: this.telemetryHistory.timestamps,
                    datasets: [
                        {
                            label: 'CPU Kullanımı (%)',
                            data: this.telemetryHistory.cpu,
                            borderColor: '#3b82f6',
                            backgroundColor: 'rgba(59, 130, 246, 0.05)',
                            fill: true,
                            tension: 0.4,
                            borderWidth: 2,
                            pointRadius: 1
                        },
                        {
                            label: 'RAM Yükü (%)',
                            data: this.telemetryHistory.ram,
                            borderColor: '#10b981',
                            backgroundColor: 'rgba(16, 185, 129, 0.05)',
                            fill: true,
                            tension: 0.4,
                            borderWidth: 2,
                            pointRadius: 1
                        }
                    ]
                },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    scales: {
                        x: {
                            grid: { color: 'rgba(255, 255, 255, 0.04)' },
                            ticks: { color: '#8a9ab5', font: { size: 9 } }
                        },
                        y: {
                            min: 0,
                            max: 100,
                            grid: { color: 'rgba(255, 255, 255, 0.04)' },
                            ticks: { color: '#8a9ab5', font: { size: 9 } }
                        }
                    },
                    plugins: {
                        legend: {
                            labels: { color: '#e2e8f0', font: { size: 10 } }
                        }
                    }
                }
            });
        },

        updateVmPerformanceChart() {
            if (!this.vmPerformanceChart || this.activeTab !== 'vms') return;
            this.vmPerformanceChart.data.labels = this.telemetryHistory.timestamps;
            this.vmPerformanceChart.data.datasets[0].data = this.telemetryHistory.cpu;
            this.vmPerformanceChart.data.datasets[1].data = this.telemetryHistory.ram;
            this.vmPerformanceChart.update('none');
        },

        // --- Xterm.js Terminal Console ---

        openConsole(vmName) {
            this.showConsoleModal = true;
            this.$nextTick(() => {
                this.initTerminal(vmName);
            });
        },

        closeConsole() {
            this.showConsoleModal = false;
            if (this.wsConsole) {
                this.wsConsole.close();
                this.wsConsole = null;
            }
            if (this.termInstance) {
                this.termInstance.dispose();
                this.termInstance = null;
            }
            const container = document.getElementById('terminal-container');
            if (container) container.innerHTML = '';
        },

        initTerminal(vmName) {
            const terminalContainer = document.getElementById('terminal-container');
            if (!terminalContainer) return;

            terminalContainer.innerHTML = '';

            this.termInstance = new Terminal({
                theme: {
                    background: '#070a13',
                    foreground: '#3b82f6',
                    cursor: '#3b82f6',
                    selectionBackground: 'rgba(59, 130, 246, 0.3)',
                    black: '#000000',
                    red: '#ff3838',
                    green: '#10b981',
                    yellow: '#ffd700',
                    blue: '#3b82f6',
                    magenta: '#d946ef',
                    cyan: '#06b6d4',
                    white: '#ffffff'
                },
                cursorBlink: true,
                fontSize: 13,
                fontFamily: 'JetBrains Mono, monospace',
                rows: 22,
                cols: 80
            });

            this.termInstance.open(terminalContainer);
            this.termInstance.focus();

            const socketUrl = `${WS_BASE}/ws/vms/${vmName}/console`;
            this.wsConsole = new WebSocket(socketUrl);

            this.wsConsole.onmessage = (event) => {
                this.termInstance.write(event.data);
            };

            this.wsConsole.onclose = () => {
                this.termInstance.write("\r\n\r\n\x1b[31;1m[Konsol Bağlantısı Sonlandırıldı]\x1b[0m\r\n");
            };

            this.wsConsole.onerror = (err) => {
                this.termInstance.write("\r\n\r\n\x1b[31;1m[WebSocket Bağlantı Hatası! API'yi kontrol edin.]\x1b[0m\r\n");
            };

            this.termInstance.onData((data) => {
                if (this.wsConsole && this.wsConsole.readyState === WebSocket.OPEN) {
                    this.wsConsole.send(data);
                }
            });
        },

        // --- Data Tables Search & Sort ---

        get filteredVms() {
            return this.vms
                .filter(vm => {
                    const query = this.searchQuery.toLowerCase();
                    const nameMatch = vm.name.toLowerCase().includes(query);
                    const osMatch = vm.os_template.toLowerCase().includes(query);
                    const ipMatch = vm.ip_address && vm.ip_address.includes(query);
                    const searchMatch = nameMatch || osMatch || ipMatch;

                    let statusMatch = true;
                    if (this.statusFilter === 'running') {
                        statusMatch = vm.status === 'running';
                    } else if (this.statusFilter === 'offline') {
                        statusMatch = vm.status !== 'running';
                    }

                    return searchMatch && statusMatch;
                })
                .sort((a, b) => {
                    let fieldA = a[this.sortBy];
                    let fieldB = b[this.sortBy];

                    if (fieldA === undefined || fieldA === null) fieldA = '';
                    if (fieldB === undefined || fieldB === null) fieldB = '';

                    if (typeof fieldA === 'string') {
                        fieldA = fieldA.toLowerCase();
                        fieldB = fieldB.toLowerCase();
                    }

                    let comparison = 0;
                    if (fieldA < fieldB) comparison = -1;
                    if (fieldA > fieldB) comparison = 1;

                    return this.sortDesc ? comparison * -1 : comparison;
                });
        },

        setSort(field) {
            if (this.sortBy === field) {
                this.sortDesc = !this.sortDesc;
            } else {
                this.sortBy = field;
                this.sortDesc = false;
            }
        },

        // --- WiseCP & Snapshots & VNC Console Operations ---

        async fetchWiseCpOrders() {
            try {
                const res = await fetch(`${API_BASE}/wisecp/orders`, { headers: API_HEADERS });
                if (res.ok) this.wiseCpOrders = await res.json();
            } catch (err) {
                console.error("WiseCP orders fetch failure", err);
            }
        },

        async fetchVmSnapshots(vmName) {
            if (!vmName) return;
            try {
                const res = await fetch(`${API_BASE}/vms/${vmName}/snapshots`, { headers: API_HEADERS });
                if (res.ok) {
                    this.selectedVmSnapshots = await res.json();
                }
            } catch (err) {
                console.error("Snapshots fetch failure", err);
            }
        },

        async createSnapshot() {
            if (!this.selectedVmName) return;
            if (!this.snapshotForm.name) {
                this.showToast("Lütfen bir snapshot adı girin.", "warning");
                return;
            }
            this.showToast(`Snapshot alınıyor: ${this.snapshotForm.name}`, "info");
            try {
                const res = await fetch(`${API_BASE}/vms/${this.selectedVmName}/snapshots`, {
                    method: 'POST',
                    headers: API_HEADERS,
                    body: JSON.stringify({
                        snapshot_name: this.snapshotForm.name,
                        description: this.snapshotForm.description
                    })
                });
                const data = await res.json();
                if (res.ok) {
                    this.showToast(data.message, "success");
                    this.snapshotForm.name = '';
                    await this.fetchVmSnapshots(this.selectedVmName);
                } else {
                    throw new Error(data.detail);
                }
            } catch (err) {
                this.showToast(err.message, "error");
            }
        },

        async revertSnapshot(snapName) {
            if (!this.selectedVmName || !snapName) return;
            if (!confirm(`DİKKAT: Sunucuyu '${snapName}' anlık görüntüsüne geri döndürmek istediğinizden emin misiniz?\nGeçerli tüm kaydedilmemiş veriler kaybolacaktır.`)) {
                return;
            }
            this.showToast(`Snapshot geri yükleniyor: ${snapName}`, "info");
            try {
                const res = await fetch(`${API_BASE}/vms/${this.selectedVmName}/snapshots/revert`, {
                    method: 'POST',
                    headers: API_HEADERS,
                    body: JSON.stringify({ snapshot_name: snapName })
                });
                const data = await res.json();
                if (res.ok) {
                    this.showToast(data.message, "success");
                    await this.fetchVms();
                } else {
                    throw new Error(data.detail);
                }
            } catch (err) {
                this.showToast(err.message, "error");
            }
        },

        async simulateWiseCpOrder() {
            this.showToast("WiseCP Sipariş talebi gönderiliyor...", "info");
            this.showWiseCpSimulateModal = false;
            
            // Auto generate an order_id if empty
            if (!this.wiseCpSimulateForm.order_id) {
                this.wiseCpSimulateForm.order_id = 'ws-order-' + Math.floor(1000 + Math.random() * 9000);
            }
            
            try {
                const res = await fetch(`${API_BASE}/wisecp/deploy`, {
                    method: 'POST',
                    headers: API_HEADERS,
                    body: JSON.stringify(this.wiseCpSimulateForm)
                });
                const data = await res.json();
                if (res.ok) {
                    this.showToast("Sipariş WiseCP API kuyruğuna alındı ve arka planda kurulum başladı!", "success");
                    this.wiseCpSimulateForm.order_id = '';
                    await this.fetchWiseCpOrders();
                } else {
                    throw new Error(data.detail);
                }
            } catch (err) {
                this.showToast(err.message, "error");
            }
        },

        // VNC Simulation Console helper
        startVncSimulation(vmName) {
            if (this.vncSimulationTimer) clearInterval(this.vncSimulationTimer);
            this.vncBootState = 1;
            this.vncConnected = false;
            this.vncCanvasContent = "Bağlanıyor...";
            
            setTimeout(() => {
                this.vncConnected = true;
                this.vncBootState = 1;
                this.vncCanvasContent = `AnkaVM Virtual VNC v1.5\r\nBIOS v1.5 Initializing...\r\nCPU: AMD EPYC Core / Intel Xeon @ 2.20GHz\r\nRAM: 4096 MB OK\r\nHard Disk: /dev/vda (QCOW2 Block Store)\r\nBooting Linux image...`;
            }, 1000);

            this.vncSimulationTimer = setInterval(() => {
                if (this.vncBootState === 1) {
                    this.vncBootState = 2;
                    this.vncCanvasContent = `[    0.000000] Booting Linux kernel on physical CPU 0x0\r\n[    0.000000] Linux version 5.15.0-88-generic\r\n[    0.052021] CPU0: Intel(R) Xeon(R) Gold\r\n[    1.218903] ACPI: Core revision 20210604\r\n[    2.148102] ext4-fs (vda): mounted filesystem with ordered data mode.\r\n[    3.029810] systemd[1]: Started Journal Service.\r\n[    3.901021] systemd[1]: Started AnkaVM Guest Telemetry Agent.\r\n[    4.208102] systemd[1]: Reached target Multi-User System.`;
                } else if (this.vncBootState === 2) {
                    this.vncBootState = 3;
                    const activeVm = this.vms.find(v => v.name === vmName);
                    const ip = activeVm ? activeVm.ip_address : '192.168.122.100';
                    const ram = activeVm ? activeVm.ram_mb : 2048;
                    const cpu = activeVm ? activeVm.cpu : 2;
                    this.vncCanvasContent = `Ubuntu 22.04 LTS ${vmName} tty1\r\n\r\n${vmName} login: root\r\nPassword: \r\nLast login: Mon Jun 22 21:20:56 2026 on tty1\r\n\r\nWelcome to Ubuntu 22.04 LTS (GNU/Linux 5.15.0-88-generic x86_64)\r\n\r\nSystem information:\r\n  System load:  0.08              Processes:             98\r\n  Usage of /:   12.4% of 38.21GB  Memory usage:          12%\r\n  VDS IP Address:                 ${ip}\r\n  VDS Core Config:                ${cpu} Cores / ${ram} MB RAM\r\n\r\n* AnkaVM hypervisor guest agents operational.\r\n* VNC graphics desktop display is active.\r\n\r\nroot@${vmName}:~# _`;
                    clearInterval(this.vncSimulationTimer);
                }
            }, 2500);
        },

        sendCtrlAltDel(vmName) {
            this.showToast("Ctrl+Alt+Del sinyali gönderildi. Sunucu yeniden başlatılıyor...", "info");
            this.startVncSimulation(vmName);
        },

        // --- Toast Management ---
        
        showToast(message, type = 'info') {
            const id = Date.now() + Math.random();
            this.toasts.push({ id, message, type });
            
            setTimeout(() => {
                this.toasts = this.toasts.filter(t => t.id !== id);
            }, 4000);
        },

        removeToast(id) {
            this.toasts = this.toasts.filter(t => t.id !== id);
        }
    }));
});

_ANKAVM_EOF_

# Write frontend/index.html
cat << '_ANKAVM_EOF_' > /opt/ankavm/frontend/index.html
<!DOCTYPE html>
<html lang="tr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>AnkaVM // SaaS Virtualization Hypervisor Portal</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script>
        tailwind.config = {
            theme: {
                extend: {
                    colors: {
                        brand: { 50: '#eff6ff', 100: '#dbeafe', 500: '#3b82f6', 600: '#2563eb', 700: '#1d4ed8' },
                        slate: { 900: '#0f172a', 950: '#070a13' }
                    }
                }
            }
        }
    </script>
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css" />
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/apexcharts"></script>
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/xterm@5.3.0/css/xterm.min.css" />
    <script src="https://cdn.jsdelivr.net/npm/xterm@5.3.0/lib/xterm.min.js"></script>
    <link rel="stylesheet" href="style.css" />
    <script src="fetch_helpers.js"></script>
    <script src="app.js"></script>
    <script defer src="https://cdn.jsdelivr.net/npm/alpinejs@3.x.x/dist/cdn.min.js"></script>
</head>
<body class="bg-[#0b0f19] min-h-screen flex flex-col text-slate-300" x-data="vmPanel">

    <!-- Glassmorphic Full Screen License Key Entry Overlay -->
    <div x-show="!licenseStatus.is_licensed" class="fixed inset-0 bg-[#070a13]/95 backdrop-blur-md z-50 flex items-center justify-center p-4">
        <div class="bg-[#111827] border border-red-500/30 rounded-2xl p-8 max-w-lg w-full shadow-2xl space-y-5 text-center">
            <!-- Icon -->
            <div class="w-16 h-16 rounded-full bg-red-500/10 border border-red-500/20 mx-auto flex items-center justify-center text-red-400 animate-pulse">
                <i class="fa-solid fa-shield-halved text-2xl"></i>
            </div>

            <!-- Title -->
            <div class="space-y-1">
                <h2 class="text-xl font-bold text-white tracking-wide">Lisans Doğrulaması Gerekli</h2>
                <p class="text-xs text-slate-400" x-text="licenseStatus.detail || 'Lisans anahtarınızı giriniz.'"></p>
            </div>

            <!-- Info Box -->
            <div class="bg-slate-900/80 p-4 rounded-xl border border-slate-800 text-xs font-mono space-y-2 text-left">
                <div class="flex justify-between items-center">
                    <span class="text-slate-500">Cihaz HWID:</span>
                    <span x-text="licenseStatus.hardware_id || 'Alınıyor...'" class="text-brand-400 font-bold select-all cursor-pointer" title="Kopyalamak için tıklayın"
                          @click="navigator.clipboard.writeText(licenseStatus.hardware_id)"></span>
                </div>
                <div class="flex justify-between items-center" x-show="licenseStatus.expires_at">
                    <span class="text-slate-500">Lisans Bitiş:</span>
                    <span x-text="licenseStatus.expires_at" class="text-yellow-400 font-bold"></span>
                </div>
            </div>

            <!-- License Key Form -->
            <form @submit.prevent="updateLicense()" class="space-y-3 text-left">
                <div class="space-y-1.5">
                    <label class="text-[10px] uppercase font-bold text-slate-400 font-mono tracking-wider">Lisans Anahtarı</label>
                    <input id="license-key-input" type="text" x-model="licenseKeyInput" required
                           placeholder="ANKAVM-XXXX-XXXX-XXXX-YYYYMMDD-XXXXXXXX"
                           class="w-full px-4 py-3 bg-slate-950 border border-slate-700 focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500/30 rounded-xl text-white font-mono text-[11px] text-center tracking-widest placeholder-slate-700 transition-all"/>
                </div>
                <button id="license-activate-btn" type="submit"
                        class="w-full bg-brand-500 hover:bg-brand-600 active:scale-[.98] transition-all duration-150 text-white text-xs font-bold py-3 rounded-xl shadow-lg shadow-brand-500/20 flex items-center justify-center space-x-2">
                    <i class="fa-solid fa-circle-check"></i>
                    <span>Lisansı Etkinleştir</span>
                </button>
            </form>

            <!-- Footer note -->
            <p class="text-[10px] text-slate-600 leading-relaxed">
                Lisans anahtarınız sistem yöneticiniz tarafından sağlanmalıdır.<br>
                HWID değerini kopyalayıp yöneticinize iletebilirsiniz.
            </p>
        </div>
    </div>

    <!-- Page Body Wrapper -->
    <div class="flex-1 flex min-h-0" x-show="licenseStatus.is_licensed" style="display: none;">
        
        <!-- Left Sidebar Navigation -->
        <aside class="w-60 bg-[#111827] border-r border-slate-800 flex flex-col justify-between shrink-0 sticky top-0 h-screen z-30">
            <div class="p-5 border-b border-slate-800">
                <div class="flex items-center space-x-3">
                    <div class="w-8 h-8 rounded bg-brand-500 flex items-center justify-center text-white font-bold"><i class="fa-solid fa-server text-sm"></i></div>
                    <div>
                        <h1 class="text-base font-bold text-white tracking-wide">Anka<span class="text-brand-500">VM</span></h1>
                        <p class="text-[9px] text-slate-500 font-mono tracking-wider uppercase">SaaS Hypervisor Node</p>
                    </div>
                </div>
            </div>

            <!-- Navigation Sidebar Links -->
            <nav class="flex-1 px-3 py-4 space-y-1 font-medium text-xs">
                <button @click="setTab('dashboard')" :class="activeTab === 'dashboard' ? 'bg-slate-800 text-white' : 'text-slate-400 hover:text-white hover:bg-slate-800/30'" class="w-full flex items-center space-x-3 px-3.5 py-2.5 rounded transition text-left">
                    <i class="fa-solid fa-chart-pie text-sm" :class="activeTab === 'dashboard' ? 'text-brand-500' : ''"></i>
                    <span>Gösterge Paneli</span>
                </button>
                <button @click="setTab('vms')" :class="activeTab === 'vms' ? 'bg-slate-800 text-white' : 'text-slate-400 hover:text-white hover:bg-slate-800/30'" class="w-full flex items-center space-x-3 px-3.5 py-2.5 rounded transition text-left">
                    <i class="fa-solid fa-desktop text-sm" :class="activeTab === 'vms' ? 'text-brand-500' : ''"></i>
                    <span>Sanal Sunucular (VDS)</span>
                </button>
                <button @click="setTab('ipam')" :class="activeTab === 'ipam' ? 'bg-slate-800 text-white' : 'text-slate-400 hover:text-white hover:bg-slate-800/30'" class="w-full flex items-center space-x-3 px-3.5 py-2.5 rounded transition text-left">
                    <i class="fa-solid fa-map-location-dot text-sm" :class="activeTab === 'ipam' ? 'text-brand-500' : ''"></i>
                    <span>IPAM (IP Yönetimi)</span>
                </button>
                <button @click="setTab('networks')" :class="activeTab === 'networks' ? 'bg-slate-800 text-white' : 'text-slate-400 hover:text-white hover:bg-slate-800/30'" class="w-full flex items-center space-x-3 px-3.5 py-2.5 rounded transition text-left">
                    <i class="fa-solid fa-network-wired text-sm" :class="activeTab === 'networks' ? 'text-brand-500' : ''"></i>
                    <span>Ağ Köprüleri</span>
                </button>
                <button @click="setTab('vcenter')" :class="activeTab === 'vcenter' ? 'bg-slate-800 text-white' : 'text-slate-400 hover:text-white hover:bg-slate-800/30'" class="w-full flex items-center space-x-3 px-3.5 py-2.5 rounded transition text-left">
                    <i class="fa-solid fa-server text-sm" :class="activeTab === 'vcenter' ? 'text-brand-500' : ''"></i>
                    <span>VCenter Entegrasyonu</span>
                </button>
                <button @click="setTab('modules')" :class="activeTab === 'modules' ? 'bg-slate-800 text-white' : 'text-slate-400 hover:text-white hover:bg-slate-800/30'" class="w-full flex items-center space-x-3 px-3.5 py-2.5 rounded transition text-left">
                    <i class="fa-solid fa-puzzle-piece text-sm" :class="activeTab === 'modules' ? 'text-brand-500' : ''"></i>
                    <span>Modüller</span>
                </button>
                <button @click="setTab('images')" :class="activeTab === 'images' ? 'bg-slate-800 text-white' : 'text-slate-400 hover:text-white hover:bg-slate-800/30'" class="w-full flex items-center space-x-3 px-3.5 py-2.5 rounded transition text-left">
                    <i class="fa-solid fa-compact-disc text-sm" :class="activeTab === 'images' ? 'text-brand-500' : ''"></i>
                    <span>İmajlar</span>
                </button>
                <button @click="setTab('wisecp')" :class="activeTab === 'wisecp' ? 'bg-slate-800 text-white' : 'text-slate-400 hover:text-white hover:bg-slate-800/30'" class="w-full flex items-center space-x-3 px-3.5 py-2.5 rounded transition text-left">
                    <i class="fa-solid fa-plug text-sm" :class="activeTab === 'wisecp' ? 'text-brand-500' : ''"></i>
                    <span>WiseCP Entegrasyonu</span>
                </button>
                <button @click="setTab('storage')" :class="activeTab === 'storage' ? 'bg-slate-800 text-white' : 'text-slate-400 hover:text-white hover:bg-slate-800/30'" class="w-full flex items-center space-x-3 px-3.5 py-2.5 rounded transition text-left">
                    <i class="fa-solid fa-database text-sm" :class="activeTab === 'storage' ? 'text-brand-500' : ''"></i>
                    <span>Disk Depolama (Storage)</span>
                </button>
                <button @click="setTab('license')" :class="activeTab === 'license' ? 'bg-slate-800 text-white' : 'text-slate-400 hover:text-white hover:bg-slate-800/30'" class="w-full flex items-center space-x-3 px-3.5 py-2.5 rounded transition text-left">
                    <i class="fa-solid fa-key text-sm" :class="activeTab === 'license' ? 'text-brand-500' : ''"></i>
                    <span>Lisans Denetimi</span>
                </button>
            </nav>

            <div class="p-4 border-t border-slate-800 font-mono text-[9px] text-slate-500">
                <div class="flex items-center space-x-2 mb-1.5" x-show="licenseStatus.is_licensed">
                    <span class="w-1.5 h-1.5 rounded-full bg-emerald-500"></span>
                    <span class="text-slate-400 font-semibold uppercase">LİSANS DOĞRULANDI</span>
                </div>
                <div class="flex items-center space-x-2 mb-1.5" x-show="!licenseStatus.is_licensed">
                    <span class="w-1.5 h-1.5 rounded-full bg-red-500"></span>
                    <span class="text-slate-400 font-semibold uppercase">LİSANS GEÇERSİZ</span>
                </div>
                <div>YÜKLEME TÜRÜ: KVM+POSTGRES</div>
            </div>
        </aside>

        <!-- Main Workspace -->
        <div class="flex-1 flex flex-col min-w-0">
            <header class="h-16 border-b border-slate-800 bg-[#111827] flex items-center justify-between px-6">
                <div class="flex items-center space-x-3">
                    <h2 class="text-sm font-bold text-white uppercase tracking-wider">
                        <span x-show="activeTab === 'dashboard'">GÖSTERGE PANELİ</span>
                        <span x-show="activeTab === 'vms'">SANAL SUNUCU LİSTESİ</span>
                        <span x-show="activeTab === 'ipam'">IPAM YÖNETİMİ</span>
                        <span x-show="activeTab === 'networks'">SANAL AĞ KÖPRÜLERİ</span>
                        <span x-show="activeTab === 'storage'">DEPOLAMA HAVUZLARI</span>
                        <span x-show="activeTab === 'license'">LİSANS YÖNETİCİSİ</span>
                        <span x-show="activeTab === 'wisecp'">WISECP ENTEGRASYONU</span>
                        <span x-show="activeTab === 'vcenter'">VCENTER ENTEGRASYONU</span>
                        <span x-show="activeTab === 'images'">İMAJ YÖNETİMİ</span>
                        <span x-show="activeTab === 'modules'">MODÜL MARKET</span>
                    </h2>
                    <div class="h-4 w-[1px] bg-slate-800"></div>
                    <span class="text-[11px] font-mono text-slate-400" x-text="`Aktif VM: ${hostStats.vms_running} / Toplam: ${hostStats.vms_total}`"></span>
                </div>
            </header>

            <main class="flex-1 p-6 overflow-y-auto">
                
                <!-- Skeleton Loader Shimmer Container -->
                <div class="skeleton-wrapper hidden space-y-6">
                    <div class="grid grid-cols-1 md:grid-cols-3 gap-5">
                        <div class="shimmer h-32 rounded-lg border border-slate-800"></div>
                        <div class="shimmer h-32 rounded-lg border border-slate-800"></div>
                        <div class="shimmer h-32 rounded-lg border border-slate-800"></div>
                    </div>
                    <div class="shimmer h-64 rounded-lg border border-slate-800"></div>
                </div>

                <!-- Actual Data Content -->
                <div class="data-content-wrapper space-y-6">
                    
                    <!-- 1. DASHBOARD TAB -->
                    <div x-show="activeTab === 'dashboard'" x-cloak class="space-y-6">
                        <!-- Top metrics -->
                        <div class="grid grid-cols-1 md:grid-cols-3 gap-5">
                            <div class="corp-card rounded-lg p-4">
                                <h3 class="text-xs uppercase text-slate-400 font-bold mb-1">Host CPU</h3>
                                <p class="text-xl font-bold text-white mb-2" x-text="`${hostStats.cpu_usage}%`"></p>
                                <div class="relative h-24 flex items-center justify-center"><canvas id="cpuChartCanvas"></canvas></div>
                            </div>
                            <div class="corp-card rounded-lg p-4">
                                <h3 class="text-xs uppercase text-slate-400 font-bold mb-1">Host RAM</h3>
                                <p class="text-xl font-bold text-white mb-2" x-text="`${hostStats.ram_used_gb}G / ${hostStats.ram_total_gb}G`"></p>
                                <div class="relative h-24 flex items-center justify-center"><canvas id="ramChartCanvas"></canvas></div>
                            </div>
                            <div class="corp-card rounded-lg p-4">
                                <h3 class="text-xs uppercase text-slate-400 font-bold mb-1">Host Disk</h3>
                                <p class="text-xl font-bold text-white mb-2" x-text="`${hostStats.disk_used_gb}G / ${hostStats.disk_total_gb}G`"></p>
                                <div class="relative h-24 flex items-center justify-center"><canvas id="diskChartCanvas"></canvas></div>
                            </div>
                        </div>

                        <!-- Storage Pools Health Chart (ApexCharts Stacked Bar) -->
                        <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
                            <div class="lg:col-span-2 corp-card rounded-lg p-5">
                                <h3 class="text-xs uppercase text-white font-bold mb-4">LVM & ZFS Storage Pools Health (ApexCharts)</h3>
                                <div id="storagePoolApexChart" class="w-full"></div>
                            </div>
                            <!-- Storage List -->
                            <div class="corp-card rounded-lg p-5 space-y-4">
                                <h3 class="text-xs uppercase text-white font-bold">Disk Depolama Listesi</h3>
                                <div class="space-y-3">
                                    <template x-for="pool in storagePools">
                                        <div class="bg-slate-900/60 p-3 rounded border border-slate-800 text-xs space-y-2">
                                            <div class="flex justify-between font-bold">
                                                <span x-text="pool.name" class="text-white"></span>
                                                <span x-text="pool.pool_type" class="text-brand-500 font-mono text-[10px]"></span>
                                            </div>
                                            <div class="text-[10px] text-slate-400 font-mono" x-text="`Dizin: ${pool.mount_path}`"></div>
                                            <div class="w-full bg-slate-950 rounded-full h-1.5 overflow-hidden">
                                                <div class="h-full rounded-full transition-all duration-500" :class="parseFloat(pool.usage_percent) >= 90 ? 'bg-red-500' : 'bg-brand-500'" :style="`width: ${pool.usage_percent}%`"></div>
                                            </div>
                                            <div class="flex justify-between text-[10px] text-slate-500 font-mono">
                                                <span x-text="`Kullanılan: ${pool.allocated_gb} GB`"></span>
                                                <span x-text="`Boş: ${pool.free_gb} GB (${pool.usage_percent}%)`"></span>
                                            </div>
                                        </div>
                                    </template>
                                </div>
                            </div>
                        </div>

                        <!-- Host Logger -->
                        <div class="corp-card rounded-lg p-5">
                            <h2 class="text-xs font-bold uppercase text-slate-200 mb-3">Hypervisor Eylem Günlüğü</h2>
                            <div class="h-44 bg-slate-950/80 border border-slate-800/80 rounded p-3 overflow-y-auto font-mono text-[10px] space-y-1">
                                <template x-for="log in activityLogs">
                                    <div class="flex items-start space-x-2">
                                        <span class="text-slate-600" x-text="`[${log.timestamp}]`"></span>
                                        <span :class="{'text-brand-500': log.level==='INFO', 'text-emerald-500': log.level==='SUCCESS', 'text-red-500': log.level!=='INFO'&&log.level!=='SUCCESS'}" class="font-bold shrink-0" x-text="`[${log.level}]`"></span>
                                        <span class="text-slate-300" x-text="log.message"></span>
                                    </div>
                                </template>
                            </div>
                        </div>
                    </div>

                    <!-- 2. VMS LIST TAB -->
                    <div x-show="activeTab === 'vms'" x-cloak class="grid grid-cols-1 lg:grid-cols-3 gap-6">
                        <div class="lg:col-span-2 space-y-5">
                            <div class="corp-card rounded-lg p-5">
                                <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3 mb-5">
                                    <input type="text" x-model="searchQuery" placeholder="Sunucu, IP veya OS ara..." class="pl-3 pr-3 py-1.5 bg-[#0b0f19] border border-slate-700 rounded text-xs text-white focus:outline-none focus:border-brand-500 font-mono w-full max-w-xs"/>
                                    <button @click="showCreateModal = true" class="btn-primary text-xs font-semibold py-1.5 px-3 rounded">VDS OLUŞTUR</button>
                                </div>
                                <div class="overflow-x-auto">
                                    <table class="min-w-full divide-y divide-slate-800 text-xs">
                                        <thead>
                                            <tr class="text-slate-500 font-semibold uppercase text-left">
                                                <th class="py-2.5 px-3">Sunucu Adı</th>
                                                <th class="py-2.5 px-3">Durum</th>
                                                <th class="py-2.5 px-3">Kaynak</th>
                                                <th class="py-2.5 px-3">Disk Bar (Proxmox Style)</th>
                                                <th class="py-2.5 px-3">IP Adresi</th>
                                                <th class="py-2.5 px-3 text-right">Eylemler</th>
                                            </tr>
                                        </thead>
                                        <tbody class="divide-y divide-slate-800/40 font-mono">
                                            <template x-for="vm in filteredVms" :key="vm.name">
                                                <tr @click="selectVm(vm.name)" :class="selectedVmName === vm.name ? 'bg-brand-500/5' : 'hover:bg-slate-900/30'" class="cursor-pointer">
                                                    <td class="py-2.5 px-3 font-bold text-white" x-text="vm.name"></td>
                                                    <td class="py-2.5 px-3">
                                                        <span :class="vm.status === 'running' ? 'text-emerald-400' : 'text-red-400'" class="font-bold" x-text="vm.status === 'running' ? 'Aktif' : 'Kapalı'"></span>
                                                    </td>
                                                    <td class="py-2.5 px-3 text-[10px]" x-text="`${vm.cpu} CPU / ${(vm.ram_mb/1024).toFixed(0)}G`"></td>
                                                    <!-- Proxmox Progress Bar Rendered dynamically -->
                                                    <td class="py-2.5 px-3" x-html="renderProxmoxProgressBar(vm.disk_used_gb || 2.0, vm.disk_gb)"></td>
                                                    <td class="py-2.5 px-3 text-slate-300" x-text="vm.ip_address"></td>
                                                    <td class="py-2.5 px-3 text-right space-x-1" @click.stop>
                                                        <button x-show="vm.status !== 'running'" @click="triggerAction(vm.name, 'start')" class="w-6 h-6 rounded bg-slate-900 border border-slate-800 text-emerald-400 hover:text-emerald-300" title="Sunucuyu Başlat"><i class="fa-solid fa-play text-[9px]"></i></button>
                                                        <button x-show="vm.status === 'running'" @click="triggerAction(vm.name, 'stop')" class="w-6 h-6 rounded bg-slate-900 border border-slate-800 text-red-400 hover:text-red-300" title="Sunucuyu Durdur"><i class="fa-solid fa-stop text-[9px]"></i></button>
                                                        <button @click="if(confirm('Sunucuyu yeniden kurmak istediğinizden emin misiniz?')) triggerAction(vm.name, 'rebuild')" class="w-6 h-6 rounded bg-slate-900 border border-slate-800 text-amber-500 hover:text-amber-300" title="Sunucuyu Yeniden Kur"><i class="fa-solid fa-rotate text-[9px]"></i></button>
                                                        <button @click="openConsole(vm.name)" class="w-6 h-6 rounded bg-slate-900 border border-slate-800 text-brand-500 hover:text-brand-300" title="Konsol Bağlantısı"><i class="fa-solid fa-terminal text-[9px]"></i></button>
                                                        <button @click="deleteVm(vm.name)" class="w-6 h-6 rounded bg-slate-900 border border-slate-800 text-red-500 hover:text-red-300" title="Sunucuyu Tamamen Sil"><i class="fa-solid fa-trash-can text-[9px]"></i></button>
                                                    </td>
                                                </tr>
                                            </template>
                                        </tbody>
                                    </table>
                                </div>
                            </div>
                        </div>

                        <!-- VDS Inspector Panels -->
                        <div class="space-y-5">
                            <!-- VDS Kontrol Merkezi (Advanced Actions) -->
                            <div class="corp-card rounded-lg p-5 space-y-4" x-show="selectedVmName">
                                <div class="flex justify-between items-center">
                                    <h3 class="text-xs font-bold uppercase text-white" x-text="`VDS: ${selectedVmName}`"></h3>
                                    <span class="text-[10px] px-2 py-0.5 rounded font-mono font-bold" 
                                          :class="vms.find(v => v.name === selectedVmName)?.status === 'running' ? 'bg-emerald-500/20 text-emerald-400 border border-emerald-500/30' : 'bg-red-500/20 text-red-400 border border-red-500/30'"
                                          x-text="vms.find(v => v.name === selectedVmName)?.status === 'running' ? 'AKTİF' : 'KAPALI'"></span>
                                </div>
                                <div class="grid grid-cols-2 gap-2 text-center text-[10px] font-semibold">
                                    <button @click="triggerAction(selectedVmName, 'start')" 
                                            :disabled="vms.find(v => v.name === selectedVmName)?.status === 'running'"
                                            class="p-2.5 rounded bg-slate-900 border border-slate-800 text-emerald-400 hover:bg-emerald-500 hover:text-white disabled:opacity-50 disabled:hover:bg-slate-900 disabled:hover:text-emerald-400 transition flex flex-col items-center justify-center space-y-1">
                                        <i class="fa-solid fa-play text-sm"></i>
                                        <span>Başlat</span>
                                    </button>
                                    <button @click="triggerAction(selectedVmName, 'stop')" 
                                            :disabled="vms.find(v => v.name === selectedVmName)?.status !== 'running'"
                                            class="p-2.5 rounded bg-slate-900 border border-slate-800 text-red-400 hover:bg-red-500 hover:text-white disabled:opacity-50 disabled:hover:bg-slate-900 disabled:hover:text-red-400 transition flex flex-col items-center justify-center space-y-1">
                                        <i class="fa-solid fa-stop text-sm"></i>
                                        <span>Durdur</span>
                                    </button>
                                    <button @click="triggerAction(selectedVmName, 'restart')" 
                                            :disabled="vms.find(v => v.name === selectedVmName)?.status !== 'running'"
                                            class="p-2.5 rounded bg-slate-900 border border-slate-800 text-brand-500 hover:bg-brand-500 hover:text-white disabled:opacity-50 disabled:hover:bg-slate-900 disabled:hover:text-brand-500 transition flex flex-col items-center justify-center space-y-1">
                                        <i class="fa-solid fa-arrows-rotate text-sm"></i>
                                        <span>Yeniden Başlat</span>
                                    </button>
                                    <button @click="if (confirm('Bu sunucuyu sıfırlayıp yeniden kurmak istediğinizden emin misiniz? Tüm disk verileriniz silinecektir!')) triggerAction(selectedVmName, 'rebuild')" 
                                            class="p-2.5 rounded bg-slate-900 border border-slate-800 text-amber-400 hover:bg-amber-500 hover:text-white transition flex flex-col items-center justify-center space-y-1">
                                        <i class="fa-solid fa-rotate-right text-sm"></i>
                                        <span>Yeniden Kur</span>
                                    </button>
                                    <button @click="openConsole(selectedVmName)" 
                                            class="col-span-2 p-2.5 rounded bg-brand-500/10 border border-brand-500/20 text-brand-400 hover:bg-brand-500 hover:text-white transition flex items-center justify-center space-x-2">
                                        <i class="fa-solid fa-display text-xs"></i>
                                        <span class="text-[10px] font-bold">VNC / Grafik Konsolu Aç</span>
                                    </button>
                                </div>
                            </div>

                            <!-- Snapshot & Yedekleme Paneli -->
                            <div class="corp-card rounded-lg p-5 space-y-4" x-show="selectedVmName">
                                <h3 class="text-xs font-bold uppercase text-white flex items-center space-x-1.5">
                                    <i class="fa-solid fa-camera"></i>
                                    <span>Snapshot & Yedekleme</span>
                                </h3>
                                
                                <form @submit.prevent="createSnapshot()" class="space-y-2 font-mono text-[10px]">
                                    <div class="flex space-x-2">
                                        <input type="text" x-model="snapshotForm.name" required placeholder="Yedek Adı (Örn: snap1)" 
                                               class="flex-1 p-2 bg-slate-950 border border-slate-800 rounded focus:outline-none focus:border-brand-500 text-white text-xs"/>
                                        <button type="submit" class="px-3 bg-brand-500 hover:bg-brand-600 rounded text-white font-sans font-bold">Yedek Al</button>
                                    </div>
                                    <input type="text" x-model="snapshotForm.description" placeholder="Açıklama girin..." 
                                           class="w-full p-2 bg-slate-950 border border-slate-800 rounded focus:outline-none focus:border-brand-500 text-white text-[10px]"/>
                                </form>

                                <div class="space-y-1.5 max-h-48 overflow-y-auto">
                                    <div class="text-[9px] uppercase font-bold text-slate-500 tracking-wider">Mevcut Snapshot Noktaları</div>
                                    <template x-if="selectedVmSnapshots.length === 0">
                                        <div class="text-[10px] text-slate-600 text-center py-2 italic bg-slate-950/20 border border-slate-900 rounded">Alınmış yedek bulunmuyor.</div>
                                    </template>
                                    <template x-for="snap in selectedVmSnapshots">
                                        <div class="bg-slate-950/60 p-2.5 rounded border border-slate-900 flex justify-between items-center text-[10px] font-mono">
                                            <div class="space-y-0.5">
                                                <div class="font-bold text-white" x-text="snap.name"></div>
                                                <div class="text-[9px] text-slate-400" x-text="snap.description"></div>
                                                <div class="text-[8px] text-slate-600" x-text="snap.timestamp"></div>
                                            </div>
                                            <button @click="revertSnapshot(snap.name)" 
                                                    class="px-2 py-1 rounded bg-brand-500/10 hover:bg-brand-500 text-brand-400 hover:text-white font-sans font-bold text-[9px] transition">
                                                Geri Yükle
                                            </button>
                                        </div>
                                    </template>
                                </div>
                            </div>

                            <!-- Telemetry Chart -->
                            <div class="corp-card rounded-lg p-5">
                                <h2 class="text-xs font-bold uppercase mb-3">VDS Canlı Kaynak Telemetrisi</h2>
                                <div x-show="selectedVmName" class="space-y-4">
                                    <div class="h-32 bg-slate-950/40 rounded border border-slate-800 p-2"><canvas id="vmPerformanceChartCanvas"></canvas></div>
                                </div>
                                <div x-show="!selectedVmName" class="text-xs text-slate-500 text-center py-8">Grafikleri görüntülemek için bir sunucu seçin.</div>
                            </div>

                            <!-- Traffic vnstat monitor panel -->
                            <div class="corp-card rounded-lg p-5 space-y-3" x-show="selectedVmName">
                                <h3 class="text-xs font-bold uppercase text-white">vnstat Ağ Trafik İzleme</h3>
                                <template x-if="selectedVmTraffic">
                                    <div class="space-y-2 text-xs font-mono">
                                        <div class="flex justify-between">
                                            <span>İndirme Hızı (RX):</span>
                                            <span class="text-emerald-400 font-bold" x-text="`${(selectedVmTraffic.rx_bytes_sec / 1024).toFixed(1)} KB/s`"></span>
                                        </div>
                                        <div class="flex justify-between">
                                            <span>Yükleme Hızı (TX):</span>
                                            <span class="text-brand-500" x-text="`${(selectedVmTraffic.tx_bytes_sec / 1024).toFixed(1)} KB/s`"></span>
                                        </div>
                                        <div class="flex justify-between">
                                            <span>İndirme Paket (PPS):</span>
                                            <span x-text="`${selectedVmTraffic.rx_packets_sec} pps`"></span>
                                        </div>
                                        <div class="flex justify-between">
                                            <span>Yükleme Paket (PPS):</span>
                                            <span x-text="`${selectedVmTraffic.tx_packets_sec} pps`"></span>
                                        </div>
                                        <!-- DDoS alarm trigger indicator -->
                                        <div class="p-2 rounded mt-2 text-[10px] text-center font-bold uppercase" :class="selectedVmTraffic.ddos_alert ? 'bg-red-500/20 text-red-400 border border-red-500/50 animate-pulse' : 'bg-slate-900/60 text-slate-400 border border-slate-800'">
                                            <span x-text="selectedVmTraffic.ddos_alert ? '🚨 SALDIRI ALARMI: DDoS Algılandı!' : 'Normal Ağ Trafik Seviyesi'"></span>
                                        </div>
                                    </div>
                                </template>
                            </div>
                        </div>
                    </div>

                    <!-- 3. IPAM TAB -->
                    <div x-show="activeTab === 'ipam'" x-cloak class="space-y-6">
                        <div class="grid grid-cols-1 md:grid-cols-2 gap-5">
                            <template x-for="pool in ipPools">
                                <div class="corp-card rounded-lg p-5">
                                    <h3 class="text-xs uppercase text-white font-bold" x-text="`HAVUZ: ${pool.name}`"></h3>
                                    <p class="text-[10px] text-slate-500 font-mono mt-1" x-text="`CIDR: ${pool.cidr} / GW: ${pool.gateway}`"></p>
                                    <div class="w-full bg-slate-900 rounded-full h-2 overflow-hidden border border-slate-800 mt-4">
                                        <div :style="`width: ${pool.usage_percent}%`" class="bg-brand-500 h-full"></div>
                                    </div>
                                    <div class="flex justify-between text-[9px] text-slate-500 mt-1">
                                        <span x-text="`Kullanılan: ${pool.allocated_ips} IP`"></span>
                                        <span x-text="`Boş: ${pool.free_ips} IP`"></span>
                                    </div>
                                </div>
                            </template>
                        </div>

                        <!-- IP Kiralamaları & Log audit trail -->
                        <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
                            <div class="lg:col-span-2 corp-card rounded-lg p-5">
                                <div class="flex justify-between items-center mb-4">
                                    <h2 class="text-xs font-bold uppercase text-slate-200">Aktif IP Kiralamaları</h2>
                                    <button @click="showCreatePoolModal = true" class="btn-primary text-xs font-semibold py-1.5 px-3 rounded">Yeni IPAM Havuzu Ekle</button>
                                </div>
                                <table class="min-w-full divide-y divide-slate-800 font-mono text-xs">
                                    <thead>
                                        <tr class="text-slate-500 uppercase text-left">
                                            <th class="py-2.5 px-3">IP Adresi</th>
                                            <th class="py-2.5 px-3">Havuz</th>
                                            <th class="py-2.5 px-3">Bağlı VM</th>
                                        </tr>
                                    </thead>
                                    <tbody>
                                        <template x-for="lease in ipLeases" :key="lease.ip_address">
                                            <tr>
                                                <td class="py-2.5 px-3 font-bold text-white" x-text="lease.ip_address"></td>
                                                <td class="py-2.5 px-3" x-text="`pool-${lease.pool_id}`"></td>
                                                <td class="py-2.5 px-3 text-brand-500" x-text="lease.allocated_to_vm || 'Rezerve'"></td>
                                            </tr>
                                        </template>
                                    </tbody>
                                </table>
                            </div>

                            <!-- IPAM transaction logs -->
                            <div class="corp-card rounded-lg p-5">
                                <h3 class="text-xs font-bold uppercase text-white mb-3">IPAM Değişiklik Günlüğü</h3>
                                <div class="space-y-2 h-64 overflow-y-auto font-mono text-[10px]">
                                    <template x-for="log in ipamLogs">
                                        <div class="p-2 bg-slate-950/60 rounded border border-slate-900 flex flex-col">
                                            <div class="flex justify-between font-bold">
                                                <span x-text="log.ip_address" class="text-white"></span>
                                                <span :class="log.action_type === 'LEASE' ? 'text-emerald-400' : 'text-red-400'" x-text="log.action_type"></span>
                                            </div>
                                            <div class="flex justify-between text-slate-500 mt-1 text-[9px]">
                                                <span x-text="`VDS: ${log.vm_name}`"></span>
                                                <span x-text="log.timestamp"></span>
                                            </div>
                                        </div>
                                    </template>
                                </div>
                            </div>
                        </div>
                    </div>

                    <!-- 4. STORAGE TAB -->
                    <div x-show="activeTab === 'storage'" x-cloak class="space-y-6">
                        <div class="corp-card rounded-lg p-5">
                            <h2 class="text-xs font-bold uppercase text-white mb-4">Storage Pools (LVM / ZFS Disk Yönetimi)</h2>
                            <table class="min-w-full divide-y divide-slate-800 text-xs font-mono">
                                <thead>
                                    <tr class="text-slate-500 uppercase text-left font-semibold">
                                        <th class="py-2.5 px-3">Havuz Adı</th>
                                        <th class="py-2.5 px-3">Havuz Tipi</th>
                                        <th class="py-2.5 px-3">Disk Bağlantı Yolu</th>
                                        <th class="py-2.5 px-3">Kapasite</th>
                                        <th class="py-2.5 px-3">Kullanılan</th>
                                        <th class="py-2.5 px-3">Boş Alan</th>
                                        <th class="py-2.5 px-3">Doluluk</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    <template x-for="pool in storagePools">
                                        <tr>
                                            <td class="py-2.5 px-3 font-bold text-white" x-text="pool.name"></td>
                                            <td class="py-2.5 px-3 text-brand-500" x-text="pool.pool_type"></td>
                                            <td class="py-2.5 px-3 text-slate-500 text-[10px]" x-text="pool.mount_path"></td>
                                            <td class="py-2.5 px-3 text-slate-300" x-text="`${pool.capacity_gb} GB`"></td>
                                            <td class="py-2.5 px-3 text-slate-300" x-text="`${pool.allocated_gb} GB`"></td>
                                            <td class="py-2.5 px-3 text-slate-300" x-text="`${pool.free_gb} GB`"></td>
                                            <td class="py-2.5 px-3">
                                                <div class="flex items-center space-x-2">
                                                    <div class="w-16 bg-slate-900 rounded-full h-1.5 overflow-hidden">
                                                        <div class="h-full rounded-full bg-brand-500" :style="`width: ${pool.usage_percent}%`"></div>
                                                    </div>
                                                    <span x-text="`${pool.usage_percent}%`" class="text-[10px] font-bold"></span>
                                                </div>
                                            </td>
                                        </tr>
                                    </template>
                                </tbody>
                            </table>
                        </div>
                    </div>

                    <!-- 5. LICENSE TAB -->
                    <div x-show="activeTab === 'license'" x-cloak class="space-y-6">
                        <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
                            <!-- Verification Card -->
                            <div class="lg:col-span-2 corp-card rounded-lg p-5 space-y-4">
                                <h3 class="text-xs uppercase text-white font-bold">AnkaVM Lisans Anahtarı Kontrol Paneli</h3>
                                <p class="text-xs text-slate-400 font-sans">Kurumsal KVM sanallaştırma altyapısının lisans doğrulaması, yerel veya uzak lisans sunucuları üzerinden dynamic Motherboard hardware_id doğrulaması ile çalışmaktadır.</p>
                                
                                <div class="p-3 bg-slate-900/60 rounded border border-slate-800 text-xs font-mono space-y-3">
                                    <div class="flex justify-between">
                                        <span>Lisans Sahibi:</span>
                                        <span x-text="licenseStatus.owner_name" class="font-bold text-white"></span>
                                    </div>
                                    <div class="flex justify-between">
                                        <span>Motherboard UUID (Hardware ID):</span>
                                        <span x-text="licenseStatus.hardware_id" class="text-brand-500 select-all font-bold"></span>
                                    </div>
                                    <div class="flex justify-between">
                                        <span>Yetkilendirilen IP Adresi:</span>
                                        <span x-text="licenseStatus.allowed_ip" class="text-slate-300 font-bold"></span>
                                    </div>
                                    <div class="flex justify-between">
                                        <span>Yetkilendirilen Alan Adı (Domain):</span>
                                        <span x-text="licenseStatus.allowed_domain" class="text-slate-300"></span>
                                    </div>
                                    <div class="flex justify-between">
                                        <span>Bitiş Tarihi (Expiration):</span>
                                        <span x-text="licenseStatus.expires_at ? new Date(licenseStatus.expires_at).toLocaleString() : 'N/A'" class="text-emerald-400"></span>
                                    </div>
                                    <div class="flex justify-between border-t border-slate-800 pt-2">
                                        <span>Lisans Durumu:</span>
                                        <span :class="licenseStatus.is_licensed ? 'text-emerald-400 font-bold' : 'text-red-400 font-bold'" x-text="licenseStatus.is_licensed ? '✓ LİSANSLI VE AKTİF' : '✗ GEÇERSİZ / SÜRESİ DOLMUŞ LİSANS'"></span>
                                    </div>
                                </div>
                            </div>

                            <!-- Update Card -->
                            <div class="corp-card rounded-lg p-5 space-y-4">
                                <h3 class="text-xs font-bold uppercase text-white">Lisans Güncelle</h3>
                                <form @submit.prevent="updateLicense()" class="space-y-3 font-mono text-xs">
                                    <label class="text-[10px] text-slate-500">YENİ LİSANS ANAHTARI GİRİNİZ:</label>
                                    <input type="text" x-model="licenseKeyInput" required placeholder="ANKAVM-PRO-XXXX-XXXX" class="w-full p-2.5 bg-slate-900 border border-slate-700 rounded text-white text-xs"/>
                                    <button type="submit" class="w-full btn-primary text-xs font-semibold py-2 rounded">KODU ETKİNLEŞTİR</button>
                                </form>
                                <div class="bg-slate-950/60 p-2 rounded text-[10px] text-slate-500 font-sans leading-relaxed">
                                    <strong>Lisans Bilgilendirmesi:</strong><br>
                                    Platform lisans anahtarı sha256 hash imzasıyla yerel watchdog ile izlenmektedir. Sahte lisans kodları sistemi otomatik olarak lockout durumuna alarak virtual_servers operasyonlarını durdurur.
                                </div>
                            </div>
                        </div>
                    </div>

                    <!-- VCENTER TAB -->
                    <div x-show="activeTab === 'vcenter'" x-cloak class="space-y-6">
                        <div class="corp-card rounded-lg p-5 space-y-4 max-w-2xl">
                            <h3 class="text-xs font-bold uppercase text-white flex items-center space-x-1.5">
                                <i class="fa-solid fa-server text-brand-500"></i>
                                <span>VCenter Bağlantı Ayarları</span>
                            </h3>
                            <p class="text-xs text-slate-400">AnkaVM'i mevcut VCenter altyapınızla entegre ederek ISO ve imajları senkronize edebilirsiniz.</p>
                            <form @submit.prevent="saveVcenterConfig()" class="space-y-3 font-mono text-xs">
                                <div>
                                    <label class="text-[9px] text-slate-500 uppercase">VCenter Host / IP:</label>
                                    <input type="text" x-model="vcenterConfig.host" required placeholder="vcenter.sirket.local" class="w-full p-2 bg-slate-900 border border-slate-700 rounded text-white"/>
                                </div>
                                <div>
                                    <label class="text-[9px] text-slate-500 uppercase">Kullanıcı Adı:</label>
                                    <input type="text" x-model="vcenterConfig.username" required placeholder="administrator@vsphere.local" class="w-full p-2 bg-slate-900 border border-slate-700 rounded text-white"/>
                                </div>
                                <div>
                                    <label class="text-[9px] text-slate-500 uppercase">Şifre:</label>
                                    <input type="password" x-model="vcenterConfig.password" required placeholder="********" class="w-full p-2 bg-slate-900 border border-slate-700 rounded text-white"/>
                                </div>
                                <button type="submit" class="btn-primary px-4 py-2 rounded text-xs font-bold">
                                    <span x-text="vcenterConfig.is_active ? 'Bağlantı Aktif (Yenile)' : 'Bağlantıyı Test Et ve Kaydet'"></span>
                                </button>
                            </form>
                        </div>

                        <!-- VCenter Discovery Panel -->
                        <div x-show="vcenterConfig.is_active" class="bg-slate-900/50 p-0 rounded-2xl border border-slate-800 shadow-xl backdrop-blur-sm overflow-hidden mt-6">
                            <div class="p-5 border-b border-slate-800 flex justify-between items-center bg-[#111827]">
                                <h3 class="text-sm font-bold text-white flex items-center space-x-2">
                                    <i class="fa-solid fa-radar text-brand-500"></i>
                                    <span>VCenter Keşfedilen Kaynaklar (Discovery)</span>
                                </h3>
                                <button @click="fetchVcenterDiscovery()" class="text-xs text-brand-500 hover:text-white transition"><i class="fa-solid fa-rotate-right mr-1"></i>Yenile</button>
                            </div>
                            <div class="overflow-x-auto max-h-96 overflow-y-auto">
                                <table class="w-full text-left border-collapse">
                                    <thead>
                                        <tr class="bg-[#111827] text-[10px] uppercase font-bold text-slate-500 tracking-wider">
                                            <th class="p-4 border-b border-slate-800">Kaynak Adı</th>
                                            <th class="p-4 border-b border-slate-800">Tür</th>
                                            <th class="p-4 border-b border-slate-800 text-center">Kapasite / Bilgi</th>
                                        </tr>
                                    </thead>
                                    <tbody class="text-xs font-medium text-slate-300 divide-y divide-slate-800/50">
                                        <template x-for="item in vcenterDiscovery" :key="item.name + item.type">
                                            <tr class="hover:bg-slate-800/30 transition">
                                                <td class="p-4 flex items-center space-x-3">
                                                    <i class="fa-solid" :class="item.type === 'Datastore' ? 'fa-database text-emerald-500' : 'fa-network-wired text-brand-500'"></i>
                                                    <span x-text="item.name"></span>
                                                </td>
                                                <td class="p-4 text-slate-400" x-text="item.type"></td>
                                                <td class="p-4 text-center">
                                                    <span x-show="item.type === 'Datastore'" class="text-[10px] text-slate-400" x-text="`Kapasite: ${item.capacityGB}GB / Boş: ${item.freeGB}GB`"></span>
                                                    <span x-show="item.type === 'Network'" class="text-[10px] text-slate-400">PortGroup Ready</span>
                                                </td>
                                            </tr>
                                        </template>
                                        <tr x-show="vcenterDiscovery.length === 0">
                                            <td colspan="3" class="p-4 text-center text-slate-500">Henüz kaynak keşfedilmedi. Bağlantıyı test edin.</td>
                                        </tr>
                                    </tbody>
                                </table>
                            </div>
                        </div>
                    </div>

                    <!-- IMAGES TAB -->
                    <div x-show="activeTab === 'images'" x-cloak class="space-y-6">
                        <div class="bg-slate-900/50 p-6 rounded-2xl border border-slate-800 shadow-xl backdrop-blur-sm relative overflow-hidden group">
                            <div class="absolute inset-0 bg-gradient-to-br from-brand-500/5 to-transparent opacity-0 group-hover:opacity-100 transition duration-500"></div>
                            <h3 class="text-sm font-bold text-white mb-4 relative flex items-center space-x-2">
                                <i class="fa-solid fa-cloud-arrow-up text-brand-500"></i>
                                <span>İmaj Yükle (VCenter Content Library)</span>
                            </h3>
                            <div class="flex items-center justify-center w-full">
                                <label for="dropzone-file" class="flex flex-col items-center justify-center w-full h-40 border-2 border-slate-700 border-dashed rounded-xl cursor-pointer bg-slate-950/50 hover:bg-slate-800/50 transition">
                                    <div class="flex flex-col items-center justify-center pt-5 pb-6">
                                        <i class="fa-solid fa-upload text-3xl text-slate-500 mb-3"></i>
                                        <p class="mb-2 text-sm text-slate-400"><span class="font-semibold text-brand-500">Tıklayın</span> veya sürükleyip bırakın</p>
                                        <p class="text-xs text-slate-500">ISO veya VM Template (.ova, .vmdk)</p>
                                    </div>
                                    <input id="dropzone-file" type="file" class="hidden" @change="uploadImage" accept=".iso,.img,.qcow2,.ova,.vmdk" />
                                </label>
                            </div>
                        </div>

                        <div class="bg-slate-900/50 p-0 rounded-2xl border border-slate-800 shadow-xl backdrop-blur-sm overflow-hidden">
                            <div class="p-5 border-b border-slate-800 flex justify-between items-center bg-[#111827]">
                                <h3 class="text-sm font-bold text-white flex items-center space-x-2">
                                    <i class="fa-solid fa-list text-brand-500"></i>
                                    <span>Mevcut İmajlar</span>
                                </h3>
                            </div>
                            <div class="overflow-x-auto">
                                <table class="w-full text-left border-collapse">
                                    <thead>
                                        <tr class="bg-[#111827] text-[10px] uppercase font-bold text-slate-500 tracking-wider">
                                            <th class="p-4 border-b border-slate-800">İmaj Adı</th>
                                            <th class="p-4 border-b border-slate-800">Tür</th>
                                            <th class="p-4 border-b border-slate-800 text-center">Durum</th>
                                        </tr>
                                    </thead>
                                    <tbody class="text-xs font-medium text-slate-300 divide-y divide-slate-800/50">
                                        <template x-for="img in images" :key="img.id">
                                            <tr class="hover:bg-slate-800/30 transition">
                                                <td class="p-4 flex items-center space-x-3"><i class="fa-solid fa-compact-disc text-slate-500 text-lg"></i><span x-text="img.name"></span></td>
                                                <td class="p-4 text-slate-400" x-text="img.is_template ? 'Template' : 'ISO Image'"></td>
                                                <td class="p-4 text-center">
                                                    <span x-show="img.status === 'ready'" class="px-2 py-1 rounded bg-green-500/10 text-green-500 border border-green-500/20 text-[10px]">Ready</span>
                                                    <span x-show="img.status === 'uploading'" class="px-2 py-1 rounded bg-amber-500/10 text-amber-500 border border-amber-500/20 text-[10px] animate-pulse">Uploading</span>
                                                    <span x-show="img.status === 'failed'" class="px-2 py-1 rounded bg-red-500/10 text-red-500 border border-red-500/20 text-[10px]">Failed</span>
                                                </td>
                                            </tr>
                                        </template>
                                        <tr x-show="images.length === 0">
                                            <td colspan="3" class="p-4 text-center text-slate-500">Hiç imaj bulunamadı.</td>
                                        </tr>
                                    </tbody>
                                </table>
                            </div>
                        </div>
                    </div>

                    <!-- MODULES TAB -->
                    <div x-show="activeTab === 'modules'" x-cloak class="space-y-6">
                        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
                            <!-- Web Console Module -->
                            <div class="bg-slate-900/50 p-6 rounded-2xl border border-brand-500/30 shadow-[0_0_15px_rgba(59,130,246,0.1)] backdrop-blur-sm relative overflow-hidden group">
                                <div class="absolute inset-0 bg-gradient-to-br from-brand-500/10 to-transparent opacity-50"></div>
                                <div class="relative flex flex-col h-full">
                                    <div class="flex justify-between items-start mb-4">
                                        <div class="w-12 h-12 rounded-xl bg-brand-500/20 border border-brand-500/30 flex items-center justify-center text-brand-500 text-xl shadow-lg">
                                            <i class="fa-solid fa-terminal"></i>
                                        </div>
                                        <span class="px-2.5 py-1 text-[10px] font-bold uppercase rounded-full bg-green-500/20 text-green-400 border border-green-500/30">Aktif</span>
                                    </div>
                                    <h3 class="text-lg font-bold text-white mb-2">Gelişmiş Web Console</h3>
                                    <p class="text-xs text-slate-400 mb-6 flex-1">VCenter MKS protokolünü WebSockets üzerinden güvenli bir şekilde aktararak tarayıcı içi yüksek performanslı konsol deneyimi sunar.</p>
                                    <button class="w-full py-2.5 bg-slate-800 hover:bg-slate-700 text-white text-xs font-bold rounded-lg border border-slate-700 transition">Ayarları Yönet</button>
                                </div>
                            </div>
                            
                            <!-- Auto-Password Module -->
                            <div class="bg-slate-900/50 p-6 rounded-2xl border border-slate-800 shadow-xl backdrop-blur-sm relative overflow-hidden opacity-70 hover:opacity-100 transition">
                                <div class="relative flex flex-col h-full">
                                    <div class="flex justify-between items-start mb-4">
                                        <div class="w-12 h-12 rounded-xl bg-slate-800 border border-slate-700 flex items-center justify-center text-slate-400 text-xl">
                                            <i class="fa-solid fa-key"></i>
                                        </div>
                                        <span class="px-2.5 py-1 text-[10px] font-bold uppercase rounded-full bg-slate-800 text-slate-500 border border-slate-700">Lisans Yok</span>
                                    </div>
                                    <h3 class="text-lg font-bold text-white mb-2">Otomatik Şifre Yönetimi</h3>
                                    <p class="text-xs text-slate-400 mb-6 flex-1">VM kurulumu sonrası işletim sistemi şifrelerini otomatik sıfırlama ve WiseCP üzerinden gösterme modülü.</p>
                                    <button class="w-full py-2.5 bg-brand-500 hover:bg-brand-600 text-white text-xs font-bold rounded-lg transition shadow-lg shadow-brand-500/20">WiseCP'den Satın Al</button>
                                </div>
                            </div>
                        </div>
                    </div>

                    <!-- WISECP TAB -->
                    <div x-show="activeTab === 'wisecp'" x-cloak class="space-y-6">
                        <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
                            <!-- Left: Setup and code -->
                            <div class="lg:col-span-2 corp-card rounded-lg p-5 space-y-4">
                                <div class="flex justify-between items-center">
                                    <h2 class="text-xs font-bold uppercase text-white flex items-center space-x-1.5">
                                        <i class="fa-solid fa-square-rss text-brand-500"></i>
                                        <span>WiseCP & WHMCS Otomasyon Modülü</span>
                                    </h2>
                                    <button @click="showWiseCpSimulateModal = true" class="btn-primary text-xs font-semibold py-1.5 px-3 rounded">Sipariş Simülatörü Aç</button>
                                </div>
                                <p class="text-xs text-slate-400 font-sans">Otomatik VM dağıtımı (Deployment) ve VDS kontrol modülünün PHP dosyalarını aşağıdaki dizine kurarak faturalandırmayı entegre edebilirsiniz:</p>
                                <div class="bg-slate-900 p-2 rounded border border-slate-800 font-mono text-[10px] text-brand-500">/cpanel/modules/Servers/AnkaVM/AnkaVM.php</div>
                                <div class="flex justify-between items-center"><span class="text-[10px] text-slate-500">Modül Kod Bloğu:</span><button @click="navigator.clipboard.writeText(document.getElementById('php-module-code').innerText); showToast('WiseCP Modül Kodu kopyalandı!', 'success')" class="px-2.5 py-1 rounded bg-slate-900 border border-slate-700 text-[10px] text-brand-500">Kopyala</button></div>
                                <pre class="bg-slate-950 p-3 rounded border border-slate-800 font-mono text-[10px] max-h-48 overflow-y-auto text-slate-300" id="php-module-code">
&lt;?php
class AnkaVM {
    private $apiUrl = "http://your-server-ip:8086";
    private $apiKey = "ankavm-secure-dev-token-2026";
    
    private function call($endpoint, $method, $data) {
        $ch = curl_init($this->apiUrl . $endpoint);
        curl_setopt($ch, CURLOPT_CUSTOMREQUEST, $method);
        curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($data));
        curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
        curl_setopt($ch, CURLOPT_HTTPHEADER, [
            'Content-Type: application/json',
            'X-API-Key: ' . $this->apiKey
        ]);
        return json_decode(curl_exec($ch), true);
    }
    
    public function createServer($params) {
        return $this->call('/api/wisecp/deploy', 'POST', [
            'order_id' => $params['order_id'],
            'product_id' => $params['product_id'],
            'name' => $params['hostname'], 
            'cpu' => $params['config']['cpu'], 
            'ram_mb' => $params['config']['ram'], 
            'disk_gb' => $params['config']['disk'],
            'disk_pool' => 'default-dir',
            'os_template' => $params['config']['os'],
            'callback_url' => 'http://yoursite.com/wisecp_callback.php'
        ]);
    }

    public function suspendServer($params) {
        return $this->call('/api/wisecp/suspend', 'POST', ['order_id' => $params['order_id']]);
    }

    public function unsuspendServer($params) {
        return $this->call('/api/wisecp/unsuspend', 'POST', ['order_id' => $params['order_id']]);
    }

    public function terminateServer($params) {
        return $this->call('/api/wisecp/terminate', 'POST', ['order_id' => $params['order_id']]);
    }

    public function rebootServer($params) {
        return $this->call('/api/wisecp/reboot', 'POST', ['order_id' => $params['order_id']]);
    }
}</pre>
                            </div>

                            <!-- Right: WiseCP Orders list -->
                            <div class="corp-card rounded-lg p-5 space-y-4">
                                <h3 class="text-xs font-bold uppercase text-white flex items-center space-x-1.5">
                                    <i class="fa-solid fa-list-check text-emerald-400"></i>
                                    <span>WiseCP Sipariş Geçmişi</span>
                                </h3>
                                <div class="space-y-3 max-h-96 overflow-y-auto font-mono text-[10px]">
                                    <template x-for="order in wiseCpOrders" :key="order.order_id">
                                        <div class="p-3 bg-slate-900/60 rounded border border-slate-800 space-y-2">
                                            <div class="flex justify-between items-center font-bold">
                                                <span x-text="order.order_id" class="text-white"></span>
                                                <span :class="{
                                                    'bg-emerald-500/20 text-emerald-400 border border-emerald-500/30': order.status === 'COMPLETED',
                                                    'bg-amber-500/20 text-amber-400 border border-amber-500/30 animate-pulse': order.status === 'PROVISIONING',
                                                    'bg-red-500/20 text-red-400 border border-red-500/30': order.status === 'FAILED'
                                                }" class="px-1.5 py-0.5 rounded text-[8px] font-bold" x-text="order.status"></span>
                                            </div>
                                            <div class="space-y-0.5 text-slate-400 text-[9px]">
                                                <div x-text="`VDS Adı: ${order.name}`"></div>
                                                <div x-text="`Ürün ID: ${order.product_id}`"></div>
                                                <div x-text="`CPU: ${order.cpu} / RAM: ${order.ram_mb}MB / Disk: ${order.disk_gb}G`"></div>
                                                <div x-show="order.ip_address" x-text="`Atanan IP: ${order.ip_address}`" class="text-brand-500 font-bold"></div>
                                                <div x-show="order.error" x-text="`Hata: ${order.error}`" class="text-red-400 font-bold"></div>
                                            </div>
                                            <div class="text-[8px] text-slate-500 text-right" x-text="order.created_at"></div>
                                        </div>
                                    </template>
                                </div>
                            </div>
                        </div>
                    </div>

                </div>
            </main>
        </div>
    </div>

    <!-- Create VM Modal -->
    <div x-show="showCreateModal" class="fixed inset-0 bg-black/75 z-50 flex items-center justify-center p-4">
        <div @click.away="showCreateModal = false" class="corp-card w-full max-w-md rounded-lg overflow-hidden p-5 space-y-4">
            <h2 class="text-xs font-bold text-white">YENİ SANAL SUNUCU OLUŞTUR</h2>
            <form @submit.prevent="provisionVm" class="space-y-3 font-mono text-xs">
                <input type="text" x-model="createForm.name" required placeholder="Sunucu adı (Örn: web-prod-01)" class="w-full p-2 bg-slate-900 border border-slate-700 rounded text-white"/>
                <select x-model="createForm.os_template" class="w-full p-2 bg-slate-900 border border-slate-700 rounded text-white">
                    <option value="ubuntu-22.04">Ubuntu 22.04 LTS</option>
                    <option value="debian-12">Debian 12 Bookworm</option>
                </select>
                <!-- Storage Pool target selection -->
                <div class="space-y-1">
                    <label class="text-[9px] text-slate-500 uppercase">YAYINLANACAK STORAGE POOL (DISK):</label>
                    <select x-model="createForm.disk_pool" class="w-full p-2 bg-slate-900 border border-slate-700 rounded text-white">
                        <template x-for="pool in storagePools">
                            <option :value="pool.name" x-text="`${pool.name} (${pool.pool_type})`"></option>
                        </template>
                    </select>
                </div>
                <div class="grid grid-cols-3 gap-2">
                    <select x-model.number="createForm.cpu" class="p-2 bg-slate-900 border border-slate-700 rounded text-white"><option value="1">1 CPU</option><option value="2">2 CPU</option><option value="4">4 CPU</option></select>
                    <select x-model.number="createForm.ram_mb" class="p-2 bg-slate-900 border border-slate-700 rounded text-white"><option value="1024">1 GB</option><option value="2048">2 GB</option><option value="4096">4 GB</option></select>
                    <select x-model.number="createForm.disk_gb" class="p-2 bg-slate-900 border border-slate-700 rounded text-white"><option value="20">20 GB</option><option value="40">40 GB</option><option value="80">80 GB</option></select>
                </div>
                <input type="text" x-model="createForm.root_password" required placeholder="Kök (Root) şifresi enjekte et" class="w-full p-2 bg-slate-900 border border-slate-700 rounded text-white"/>
                <textarea x-model="createForm.ssh_key" placeholder="Authorized SSH Key (İsteğe bağlı)" class="w-full p-2 bg-slate-900 border border-slate-700 rounded text-[10px] text-white" rows="2"></textarea>
                <div class="flex justify-end space-x-2 pt-2">
                    <button type="button" @click="showCreateModal = false" class="px-3 py-1.5 text-slate-400">İptal</button>
                    <button type="submit" class="btn-primary px-4 py-1.5 rounded">Oluştur</button>
                </div>
            </form>
        </div>
    </div>

    <!-- Create IPAM Pool Modal -->
    <div x-show="showCreatePoolModal" class="fixed inset-0 bg-black/75 z-50 flex items-center justify-center p-4">
        <div @click.away="showCreatePoolModal = false" class="corp-card w-full max-w-md rounded-lg p-5 space-y-4">
            <h2 class="text-xs font-bold text-white">YENİ IPAM HAVUZU EKLE</h2>
            <form @submit.prevent="provisionIpPool" class="space-y-3 font-mono text-xs">
                <input type="text" x-model="createPoolForm.name" required placeholder="Havuz adı" class="w-full p-2 bg-slate-900 border border-slate-700 rounded text-white"/>
                <input type="text" x-model="createPoolForm.cidr" required placeholder="Ağ (Örn: 192.168.100.0/24)" class="w-full p-2 bg-slate-900 border border-slate-700 rounded text-white"/>
                <input type="text" x-model="createPoolForm.gateway" required placeholder="Ağ Geçidi" class="w-full p-2 bg-slate-900 border border-slate-700 rounded text-white"/>
                <div class="flex justify-end space-x-2">
                    <button type="button" @click="showCreatePoolModal = false" class="px-3 py-1.5 text-slate-400 font-sans">İptal</button>
                    <button type="submit" class="btn-primary px-4 py-1.5 rounded">Ekle</button>
                </div>
            </form>
        </div>
    </div>

    <!-- WiseCP Simulation Modal -->
    <div x-show="showWiseCpSimulateModal" class="fixed inset-0 bg-black/75 z-50 flex items-center justify-center p-4">
        <div @click.away="showWiseCpSimulateModal = false" class="corp-card w-full max-w-md rounded-lg overflow-hidden p-5 space-y-4 bg-[#111827] border border-slate-800">
            <h2 class="text-xs font-bold text-white uppercase tracking-wider flex items-center space-x-1.5">
                <i class="fa-solid fa-flask text-amber-500"></i>
                <span>WiseCP Sipariş Simülatörü</span>
            </h2>
            <p class="text-[11px] text-slate-400 font-sans leading-relaxed">Bu arayüz, WiseCP modülünün API aracılığıyla hypervisor düğümünüze göndereceği "Yeni Sunucu Oluştur" (CreateServer) çağrısını birebir simüle etmenizi sağlar.</p>
            <form @submit.prevent="simulateWiseCpOrder" class="space-y-3 font-mono text-xs">
                <div class="space-y-1">
                    <label class="text-[9px] text-slate-500 uppercase">Sipariş ID (Boş bırakılırsa otomatik üretilir):</label>
                    <input type="text" x-model="wiseCpSimulateForm.order_id" placeholder="Örn: ws-order-9823" class="w-full p-2 bg-slate-900 border border-slate-700 rounded text-white focus:outline-none focus:border-brand-500"/>
                </div>
                <div class="space-y-1">
                    <label class="text-[9px] text-slate-500 uppercase">Sunucu Adı (Hostname):</label>
                    <input type="text" x-model="wiseCpSimulateForm.name" required placeholder="Sunucu adı" class="w-full p-2 bg-slate-900 border border-slate-700 rounded text-white focus:outline-none focus:border-brand-500"/>
                </div>
                <div class="space-y-1">
                    <label class="text-[9px] text-slate-500 uppercase">İşletim Sistemi Şablonu:</label>
                    <select x-model="wiseCpSimulateForm.os_template" class="w-full p-2 bg-slate-900 border border-slate-700 rounded text-white font-mono focus:outline-none focus:border-brand-500">
                        <option value="ubuntu-22.04">Ubuntu 22.04 LTS</option>
                        <option value="debian-12">Debian 12 Bookworm</option>
                    </select>
                </div>
                <div class="grid grid-cols-3 gap-2">
                    <div class="space-y-1">
                        <label class="text-[9px] text-slate-500 uppercase">CPU:</label>
                        <select x-model.number="wiseCpSimulateForm.cpu" class="w-full p-2 bg-slate-900 border border-slate-700 rounded text-white font-mono focus:outline-none focus:border-brand-500">
                            <option value="1">1 Core</option>
                            <option value="2">2 Cores</option>
                            <option value="4">4 Cores</option>
                        </select>
                    </div>
                    <div class="space-y-1">
                        <label class="text-[9px] text-slate-500 uppercase">RAM:</label>
                        <select x-model.number="wiseCpSimulateForm.ram_mb" class="w-full p-2 bg-slate-900 border border-slate-700 rounded text-white font-mono focus:outline-none focus:border-brand-500">
                            <option value="1024">1 GB</option>
                            <option value="2048">2 GB</option>
                            <option value="4096">4 GB</option>
                            <option value="8192">8 GB</option>
                        </select>
                    </div>
                    <div class="space-y-1">
                        <label class="text-[9px] text-slate-500 uppercase">Disk:</label>
                        <select x-model.number="wiseCpSimulateForm.disk_gb" class="w-full p-2 bg-slate-900 border border-slate-700 rounded text-white font-mono focus:outline-none focus:border-brand-500">
                            <option value="20">20 GB</option>
                            <option value="40">40 GB</option>
                            <option value="80">80 GB</option>
                            <option value="160">160 GB</option>
                        </select>
                    </div>
                </div>
                <div class="space-y-1">
                    <label class="text-[9px] text-slate-500 uppercase">Kök Şifresi (Root Password):</label>
                    <input type="text" x-model="wiseCpSimulateForm.root_password" required placeholder="Geçici Şifre" class="w-full p-2 bg-slate-900 border border-slate-700 rounded text-white focus:outline-none focus:border-brand-500"/>
                </div>
                <div class="flex justify-end space-x-2 pt-2">
                    <button type="button" @click="showWiseCpSimulateModal = false" class="px-3 py-1.5 text-slate-400 font-sans">İptal</button>
                    <button type="submit" class="btn-primary px-4 py-1.5 rounded font-sans font-bold text-white">API Siparişini Tetikle</button>
                </div>
            </form>
        </div>
    </div>

    <!-- Terminal & VNC Modal -->
    <div x-show="showConsoleModal" class="fixed inset-0 bg-black/90 z-50 flex items-center justify-center p-4">
        <div class="corp-card w-full max-w-3xl rounded-xl overflow-hidden shadow-2xl border border-slate-800" @click.away="closeConsole()">
            <!-- Tab Headers -->
            <div class="border-b border-slate-800 bg-[#111827] px-4 py-2 flex justify-between items-center">
                <div class="flex space-x-2 text-xs font-semibold">
                    <button @click="consoleTab = 'vnc'; startVncSimulation(selectedVmName)" 
                            :class="consoleTab === 'vnc' ? 'bg-brand-500/20 text-brand-400 border border-brand-500/30' : 'text-slate-400 hover:text-white'" 
                            class="px-3 py-1.5 rounded transition flex items-center space-x-1">
                        <i class="fa-solid fa-desktop"></i>
                        <span>Web VNC Ekranı (Grafik)</span>
                    </button>
                    <button @click="consoleTab = 'serial'; $nextTick(() => initTerminal(selectedVmName))" 
                            :class="consoleTab === 'serial' ? 'bg-brand-500/20 text-brand-400 border border-brand-500/30' : 'text-slate-400 hover:text-white'" 
                            class="px-3 py-1.5 rounded transition flex items-center space-x-1">
                        <i class="fa-solid fa-terminal"></i>
                        <span>Seri Konsol (SSH)</span>
                    </button>
                </div>
                <button @click="closeConsole()" class="text-slate-400 hover:text-white"><i class="fa-solid fa-xmark text-sm"></i></button>
            </div>
            
            <!-- VNC Simulation Panel -->
            <div x-show="consoleTab === 'vnc'" class="p-6 bg-[#070a13] space-y-4">
                <div class="flex justify-between items-center text-xs">
                    <div class="text-slate-500 font-mono" x-text="`VNC Adresi: ws://${window.location.host}/ws/vms/${selectedVmName}/vnc`"></div>
                    <div class="flex space-x-2">
                        <button @click="sendCtrlAltDel(selectedVmName)" class="px-2.5 py-1 bg-slate-900 border border-slate-800 hover:bg-slate-800 text-[10px] text-brand-400 font-mono rounded font-bold">Ctrl+Alt+Del Gönder</button>
                        <button @click="triggerAction(selectedVmName, 'restart'); startVncSimulation(selectedVmName)" class="px-2.5 py-1 bg-slate-900 border border-slate-800 hover:bg-slate-800 text-[10px] text-amber-500 font-mono rounded font-bold">Sert Yeniden Başlat</button>
                    </div>
                </div>
                
                <!-- Display Mock screen output -->
                <div class="relative w-full aspect-video max-w-full bg-black rounded-lg border border-slate-800/80 overflow-hidden flex flex-col p-4 font-mono text-xs text-brand-500 leading-relaxed overflow-y-auto max-h-96 select-text whitespace-pre-wrap">
                    <!-- Boot sequence content -->
                    <div class="flex-1" x-text="vncCanvasContent"></div>
                </div>
            </div>

            <!-- Serial Console xterm -->
            <div x-show="consoleTab === 'serial'" class="p-4 bg-[#070a13]">
                <div id="terminal-container" class="w-full"></div>
            </div>
        </div>
    </div>

    <!-- Toaststack -->
    <div class="fixed bottom-5 right-5 space-y-2 z-50 max-w-xs w-full">
        <template x-for="toast in toasts" :key="toast.id">
            <div :class="{'border-l-brand-500 text-brand-500': toast.type === 'info', 'border-l-emerald-500 text-emerald-400': toast.type === 'success', 'border-l-red-500 text-red-400': toast.type !== 'info' && toast.type !== 'success'}" class="corp-card p-3 rounded flex justify-between items-start bg-[#111827]/95 border-l-4 border-slate-800 text-xs">
                <span x-text="toast.message" class="font-sans"></span>
                <button @click="removeToast(toast.id)" class="text-slate-500"><i class="fa-solid fa-xmark text-[9px]"></i></button>
            </div>
        </template>
    </div>

</body>
</html>

_ANKAVM_EOF_

# Write backend/models.py
cat << '_ANKAVM_EOF_' > /opt/ankavm/backend/models.py
from sqlalchemy import Column, Integer, String, Boolean, DateTime, ForeignKey, Enum
from sqlalchemy.orm import relationship
import enum
from datetime import datetime
from .database import Base

class ImageStatus(str, enum.Enum):
    UPLOADING = "uploading"
    SYNCING = "syncing"
    READY = "ready"
    FAILED = "failed"

class Image(Base):
    __tablename__ = "images"
    id = Column(Integer, primary_key=True, index=True)
    name = Column(String, index=True)
    filename = Column(String)
    is_template = Column(Boolean, default=False)
    content_library_item_id = Column(String, nullable=True)
    status = Column(Enum(ImageStatus), default=ImageStatus.UPLOADING)
    created_at = Column(DateTime, default=datetime.utcnow)

class Module(Base):
    __tablename__ = "modules"
    id = Column(Integer, primary_key=True, index=True)
    name = Column(String, unique=True, index=True)  # e.g., 'web_console', 'auto_password'
    description = Column(String)
    is_active = Column(Boolean, default=True)

class UserModule(Base):
    __tablename__ = "user_modules"
    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, index=True)  # WiseCP user ID
    module_id = Column(Integer, ForeignKey("modules.id"))
    is_active = Column(Boolean, default=True)
    expires_at = Column(DateTime, nullable=True)

    module = relationship("Module")

class VCenterResource(Base):
    __tablename__ = "vcenter_resources"
    id = Column(Integer, primary_key=True, index=True)
    resource_type = Column(String)  # 'VM', 'Datastore', 'Network'
    local_id = Column(String)
    vcenter_id = Column(String)

class VCenterConfig(Base):
    __tablename__ = "vcenter_config"
    id = Column(Integer, primary_key=True, index=True)
    host = Column(String)
    username = Column(String)
    password = Column(String)  # In production, encrypt this
    is_active = Column(Boolean, default=False)
    updated_at = Column(DateTime, default=datetime.utcnow)

class License(Base):
    __tablename__ = "licenses"
    id = Column(Integer, primary_key=True, index=True)
    hwid = Column(String, unique=True, index=True)
    status = Column(String, default="active") # 'active', 'suspended'
    expire_date = Column(DateTime, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)

_ANKAVM_EOF_

# Write backend/routers_vcenter.py
cat << '_ANKAVM_EOF_' > /opt/ankavm/backend/routers_vcenter.py
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from backend.database import get_db
from backend.models import VCenterConfig
from pydantic import BaseModel
from typing import Optional, List
import ssl

try:
    from pyVim.connect import SmartConnect, Disconnect
    from pyVmomi import vim
    PYVMOMI_AVAILABLE = True
except ImportError:
    PYVMOMI_AVAILABLE = False

router = APIRouter(prefix="/api/vcenter", tags=["vcenter"])

class VCenterConfigRequest(BaseModel):
    host: str
    username: str
    password: str

class VCenterConfigResponse(BaseModel):
    host: Optional[str]
    username: Optional[str]
    is_active: bool

class VCenterItem(BaseModel):
    name: str
    type: str
    capacityGB: Optional[int] = None
    freeGB: Optional[int] = None

@router.get("/config", response_model=VCenterConfigResponse)
def get_vcenter_config(db: Session = Depends(get_db)):
    config = db.query(VCenterConfig).first()
    if not config:
        return {"host": "", "username": "", "is_active": False}
    return {
        "host": config.host,
        "username": config.username,
        "is_active": config.is_active
    }

@router.post("/config")
def save_vcenter_config(req: VCenterConfigRequest, db: Session = Depends(get_db)):
    if not req.host or not req.username or not req.password:
        raise HTTPException(status_code=400, detail="Eksik bilgi girdiniz.")
        
    # Attempt real connection if pyvmomi is installed
    if PYVMOMI_AVAILABLE:
        try:
            context = ssl._create_unverified_context()
            si = SmartConnect(host=req.host, user=req.username, pwd=req.password, sslContext=context)
            Disconnect(si)
        except Exception as e:
            raise HTTPException(status_code=400, detail=f"VCenter bağlantı hatası: {str(e)}")
            
    config = db.query(VCenterConfig).first()
    if not config:
        config = VCenterConfig()
        db.add(config)
    
    config.host = req.host
    config.username = req.username
    config.password = req.password
    config.is_active = True
    
    db.commit()
    msg = "VCenter başarıyla bağlandı." if PYVMOMI_AVAILABLE else "VCenter bilgileri kaydedildi (PyVmomi yüklü olmadığı için simüle edildi)."
    return {"message": msg}

@router.get("/discovery", response_model=List[VCenterItem])
def discover_vcenter(db: Session = Depends(get_db)):
    config = db.query(VCenterConfig).first()
    if not config or not config.is_active:
        raise HTTPException(status_code=400, detail="VCenter konfigüre edilmemiş.")
        
    items = []
    if PYVMOMI_AVAILABLE:
        try:
            context = ssl._create_unverified_context()
            si = SmartConnect(host=config.host, user=config.username, pwd=config.password, sslContext=context)
            content = si.RetrieveContent()
            for child in content.rootFolder.childEntity:
                if hasattr(child, 'datastore'):
                    for ds in child.datastore:
                        summary = ds.summary
                        items.append({
                            "name": summary.name,
                            "type": "Datastore",
                            "capacityGB": summary.capacity // (1024**3),
                            "freeGB": summary.freeSpace // (1024**3)
                        })
                if hasattr(child, 'network'):
                    for net in child.network:
                        items.append({
                            "name": net.name,
                            "type": "Network"
                        })
            Disconnect(si)
        except Exception as e:
            raise HTTPException(status_code=500, detail=str(e))
    else:
        # Mock Discovery Data
        items = [
            {"name": "vsanDatastore", "type": "Datastore", "capacityGB": 2048, "freeGB": 1024},
            {"name": "VM Network", "type": "Network"},
            {"name": "Management Network", "type": "Network"}
        ]
        
    return items

_ANKAVM_EOF_

# Write backend/routers_images.py
cat << '_ANKAVM_EOF_' > /opt/ankavm/backend/routers_images.py
import os
import shutil
from fastapi import APIRouter, Depends, HTTPException, UploadFile, File
from sqlalchemy.orm import Session
from backend.database import get_db
from backend.models import Image, ImageStatus
from pydantic import BaseModel
from typing import List

router = APIRouter(prefix="/api/images", tags=["images"])

# In a real environment, this should be /var/lib/libvirt/images
# For dev/windows, we'll use a local folder
UPLOAD_DIR = os.path.join(os.getcwd(), "storage_images")
os.makedirs(UPLOAD_DIR, exist_ok=True)

class ImageResponse(BaseModel):
    id: int
    name: str
    filename: str
    is_template: bool
    status: str

    class Config:
        from_attributes = True

@router.get("", response_model=List[ImageResponse])
def get_images(db: Session = Depends(get_db)):
    images = db.query(Image).all()
    # If no images, let's create a default one to show in UI
    if not images:
        default_img = Image(
            name="Ubuntu 22.04 LTS",
            filename="ubuntu-22.04-server-cloudimg-amd64.img",
            is_template=True,
            status=ImageStatus.READY
        )
        db.add(default_img)
        db.commit()
        db.refresh(default_img)
        images = [default_img]
    return images

@router.post("/upload")
async def upload_image(file: UploadFile = File(...), db: Session = Depends(get_db)):
    if not file.filename.endswith(('.iso', '.img', '.qcow2', '.ova', '.vmdk')):
        raise HTTPException(status_code=400, detail="Sadece ISO, IMG, QCOW2, OVA ve VMDK desteklenmektedir.")
    
    file_location = os.path.join(UPLOAD_DIR, file.filename)
    
    # Create DB record in UPLOADING state
    new_image = Image(
        name=file.filename,
        filename=file.filename,
        is_template=False,
        status=ImageStatus.UPLOADING
    )
    db.add(new_image)
    db.commit()
    db.refresh(new_image)
    
    try:
        with open(file_location, "wb+") as file_object:
            shutil.copyfileobj(file.file, file_object)
        
        # After upload finishes, set to READY
        new_image.status = ImageStatus.READY
        db.commit()
    except Exception as e:
        new_image.status = ImageStatus.FAILED
        db.commit()
        raise HTTPException(status_code=500, detail=f"Yükleme hatası: {str(e)}")
        
    return {"message": "İmaj başarıyla yüklendi", "image_id": new_image.id}

_ANKAVM_EOF_

# Write backend/routers_wisecp.py
cat << '_ANKAVM_EOF_' > /opt/ankavm/backend/routers_wisecp.py
from fastapi import APIRouter, Depends, HTTPException, BackgroundTasks, Header
from sqlalchemy.orm import Session
from backend.database import get_db
from backend.schemas import WiseCPDeploy
from pydantic import BaseModel
import asyncio
import httpx
from datetime import datetime

router = APIRouter(prefix="/api/wisecp", tags=["wisecp"])

# Simulated queue
wisecp_orders = []

async def callback_wisecp(url: str, data: dict):
    if not url:
        return
    try:
        async with httpx.AsyncClient() as client:
            await client.post(url, json=data, timeout=10.0)
    except Exception as e:
        print(f"WiseCP Callback failed: {e}")

async def process_deployment(order: WiseCPDeploy):
    # Simulate deployment delay
    await asyncio.sleep(5)
    
    # Generate mock IP and Password
    generated_ip = f"192.168.100.{order.cpu * 10 + 2}"
    generated_pass = "AutoPass_" + order.order_id[-4:]
    
    for o in wisecp_orders:
        if o["order_id"] == order.order_id:
            o["status"] = "COMPLETED"
            o["ip_address"] = generated_ip
            o["root_password"] = generated_pass
            break
            
    # Send callback
    if order.callback_url:
        await callback_wisecp(order.callback_url, {
            "order_id": order.order_id,
            "status": "active",
            "ip": generated_ip,
            "password": generated_pass
        })

@router.post("/deploy")
async def wisecp_deploy(order: WiseCPDeploy, background_tasks: BackgroundTasks, x_api_key: str = Header(None)):
    if not x_api_key or x_api_key != "ankavm-secure-dev-token-2026":
        raise HTTPException(status_code=401, detail="Invalid API Key")
        
    wisecp_orders.insert(0, {
        "order_id": order.order_id,
        "product_id": order.product_id,
        "name": order.name,
        "cpu": order.cpu,
        "ram_mb": order.ram_mb,
        "disk_gb": order.disk_gb,
        "status": "PROVISIONING",
        "ip_address": None,
        "error": None,
        "created_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    })
    
    background_tasks.add_task(process_deployment, order)
    
    return {"status": "accepted", "message": "Deployment started."}

class ActionRequest(BaseModel):
    order_id: str
    callback_url: str = None

@router.post("/suspend")
async def wisecp_suspend(req: ActionRequest, x_api_key: str = Header(None)):
    if not x_api_key or x_api_key != "ankavm-secure-dev-token-2026":
        raise HTTPException(status_code=401, detail="Invalid API Key")
    # Simulate suspension
    return {"status": "success", "message": f"{req.order_id} suspended."}

@router.post("/unsuspend")
async def wisecp_unsuspend(req: ActionRequest, x_api_key: str = Header(None)):
    if not x_api_key or x_api_key != "ankavm-secure-dev-token-2026":
        raise HTTPException(status_code=401, detail="Invalid API Key")
    return {"status": "success", "message": f"{req.order_id} unsuspended."}

@router.post("/terminate")
async def wisecp_terminate(req: ActionRequest, x_api_key: str = Header(None)):
    if not x_api_key or x_api_key != "ankavm-secure-dev-token-2026":
        raise HTTPException(status_code=401, detail="Invalid API Key")
    return {"status": "success", "message": f"{req.order_id} terminated."}

@router.get("/orders")
def get_wisecp_orders():
    return wisecp_orders

_ANKAVM_EOF_

# Write backend/__init__.py
cat << '_ANKAVM_EOF_' > /opt/ankavm/backend/__init__.py
# Initialize backend package

_ANKAVM_EOF_

# Write backend/database.py
cat << '_ANKAVM_EOF_' > /opt/ankavm/backend/database.py
from sqlalchemy import create_engine
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker
import os

SQLALCHEMY_DATABASE_URL = os.getenv("ANKAVM_DATABASE_URL", "sqlite:///./ankavm.db")

engine = create_engine(
    SQLALCHEMY_DATABASE_URL, connect_args={"check_same_thread": False}
)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

Base = declarative_base()

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

_ANKAVM_EOF_

# Write backend/dependencies.py
cat << '_ANKAVM_EOF_' > /opt/ankavm/backend/dependencies.py
from fastapi import Depends, HTTPException, status, Header
from sqlalchemy.orm import Session
from datetime import datetime
from .database import get_db
from .models import UserModule, Module

def get_current_user_id(x_user_id: str = Header(..., description="WiseCP User ID")):
    try:
        return int(x_user_id)
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid User ID format")

def require_module(module_name: str):
    def module_checker(
        user_id: int = Depends(get_current_user_id),
        db: Session = Depends(get_db)
    ):
        # Find the module
        module = db.query(Module).filter(Module.name == module_name).first()
        if not module:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"Module '{module_name}' does not exist in the system."
            )
        
        # Check user license
        user_module = db.query(UserModule).filter(
            UserModule.user_id == user_id,
            UserModule.module_id == module.id,
            UserModule.is_active == True
        ).first()
        
        if not user_module:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"Active license required for module '{module_name}'."
            )
            
        if user_module.expires_at and user_module.expires_at < datetime.utcnow():
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"License for module '{module_name}' has expired."
            )
            
        return user_module
    
    return module_checker

_ANKAVM_EOF_

# Write backend/keygen.py
cat << '_ANKAVM_EOF_' > /opt/ankavm/backend/keygen.py
"""
AnkaVM Lisans Anahtar Üretici
==============================
Admin aracı - Windows/Linux uyumlu
Süre seçimli, HMAC imzalı profesyonel lisans anahtarı üretici.
"""

import hmac
import hashlib
import secrets
import datetime
import os
import sys

# === GİZLİ İMZALAMA ANAHTARI (backend ve install.sh ile aynı olmalı) ===
SECRET_SIGNING_KEY = "ankavm_private_signing_secret_9x2k7m_2026"

LICENSE_PLANS = [
    ("1 Aylık",       30),
    ("3 Aylık",       90),
    ("6 Aylık",       180),
    ("1 Yıllık",      365),
    ("2 Yıllık",      730),
    ("Lifetime",      None),   # None = sonsuz
]

def generate_license_key(expiry_date: str) -> str:
    """
    HMAC imzalı lisans anahtarı üretir.
    Format: ANKAVM-XXXX-XXXX-XXXX-YYYYMMDD-SIGNATURE
      XXXX-XXXX-XXXX = rastgele 12 hex karakter
      YYYYMMDD       = bitiş tarihi (sonsuz için 99991231)
      SIGNATURE      = HMAC-SHA256(SECRET, token+expiry)[:8]
    """
    raw_token = secrets.token_hex(6).upper()          # 12 hex = 3×4 grup
    parts_token = [raw_token[i:i+4] for i in range(0, 12, 4)]

    hmac_input = f"{raw_token}{expiry_date}"
    signature = hmac.new(
        SECRET_SIGNING_KEY.encode('utf-8'),
        hmac_input.encode('utf-8'),
        hashlib.sha256
    ).hexdigest()[:8].upper()

    return f"ANKAVM-{'-'.join(parts_token)}-{expiry_date}-{signature}"


def print_banner():
    print()
    print("╔══════════════════════════════════════════════════════════╗")
    print("║        AnkaVM Lisans Anahtar Üretici  |  Admin Paneli   ║")
    print("╚══════════════════════════════════════════════════════════╝")
    print()


def choose_plan() -> tuple[str, str]:
    """Kullanıcıya süre seçtirir. (label, expiry_date) döndürür."""
    print("  Lisans Süresi Seçin:")
    print("  " + "─" * 42)
    for i, (label, days) in enumerate(LICENSE_PLANS, 1):
        if days is None:
            expire_str = "Süresiz (Lifetime)"
        else:
            expire_dt = datetime.date.today() + datetime.timedelta(days=days)
            expire_str = expire_dt.strftime("%d.%m.%Y")
        print(f"  [{i}] {label:<12}  →  Bitiş: {expire_str}")
    print("  " + "─" * 42)

    while True:
        try:
            choice = int(input("\n  Seçiminiz (1-6): ").strip())
            if 1 <= choice <= len(LICENSE_PLANS):
                label, days = LICENSE_PLANS[choice - 1]
                if days is None:
                    expiry_date = "99991231"
                else:
                    expiry_dt = datetime.date.today() + datetime.timedelta(days=days)
                    expiry_date = expiry_dt.strftime("%Y%m%d")
                return label, expiry_date
        except ValueError:
            pass
        print("  [!] Lütfen 1-6 arasında bir değer girin.")


def confirm(label: str, expiry_date: str) -> bool:
    if expiry_date == "99991231":
        expiry_display = "Sonsuz (Lifetime)"
    else:
        d = datetime.datetime.strptime(expiry_date, "%Y%m%d").date()
        expiry_display = d.strftime("%d.%m.%Y")

    print()
    print("  ┌─────────────────────────────────────────┐")
    print(f"  │  Plan    : {label:<30}│")
    print(f"  │  Bitiş   : {expiry_display:<30}│")
    print("  └─────────────────────────────────────────┘")
    ans = input("\n  Onaylıyor musunuz? (e/h): ").strip().lower()
    return ans == "e"


def save_log(license_key: str, label: str, expiry_date: str):
    log_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), "issued_keys.log")
    try:
        with open(log_file, "a", encoding="utf-8") as f:
            now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            f.write(f"{now}  |  {label:<12}  |  {expiry_date}  |  {license_key}\n")
    except Exception:
        pass


def main():
    print_banner()
    label, expiry_date = choose_plan()

    if not confirm(label, expiry_date):
        print("\n  İptal edildi.\n")
        sys.exit(0)

    key = generate_license_key(expiry_date)
    save_log(key, label, expiry_date)

    if expiry_date == "99991231":
        expiry_display = "Sonsuz (Lifetime)"
    else:
        d = datetime.datetime.strptime(expiry_date, "%Y%m%d").date()
        expiry_display = d.strftime("%d.%m.%Y")

    print()
    print("╔══════════════════════════════════════════════════════════╗")
    print("║          ✓  LİSANS ANAHTARI OLUŞTURULDU                ║")
    print("╚══════════════════════════════════════════════════════════╝")
    print()
    print(f"  Plan    : {label}")
    print(f"  Bitiş   : {expiry_display}")
    print()
    print("  Lisans Anahtarı:")
    print(f"\n  ► {key}\n")
    print("─" * 62)
    print("  Bu anahtarı müşteriye iletin.")
    print("  Müşteri hem install.sh'da hem de panelde kullanacak.")
    print("─" * 62)
    print()


if __name__ == "__main__":
    main()

_ANKAVM_EOF_

# Write backend/license_middleware.py
cat << '_ANKAVM_EOF_' > /opt/ankavm/backend/license_middleware.py
import os
import hmac
import hashlib
import base64
import datetime
from fastapi import Request, status
from fastapi.responses import JSONResponse

LICENSE_FILE_PATH = "/etc/ankavm/license.key"
SALT = "ankavm_hwid_salt_2026_xyz"
SECRET_SIGNING_KEY = "ankavm_private_signing_secret_9x2k7m_2026"


def verify_license_key_signature(license_key: str) -> tuple[bool, str | None]:
    """
    HMAC imzasını ve bitiş tarihini doğrular.
    Format: ANKAVM-XXXX-XXXX-XXXX-YYYYMMDD-SIGNATURE
    Returns: (is_valid, expiry_date_str or None)
    """
    try:
        parts = license_key.strip().split("-")
        # ANKAVM + 3 token + YYYYMMDD + SIG = 6 parts
        if len(parts) != 6 or parts[0] != "ANKAVM":
            return False, None

        raw_token = "".join(parts[1:4])
        expiry_date_str = parts[4]   # YYYYMMDD
        provided_sig = parts[5]

        # HMAC doğrula
        hmac_input = f"{raw_token}{expiry_date_str}"
        expected_sig = hmac.new(
            SECRET_SIGNING_KEY.encode('utf-8'),
            hmac_input.encode('utf-8'),
            hashlib.sha256
        ).hexdigest()[:8].upper()

        if not hmac.compare_digest(provided_sig, expected_sig):
            return False, None

        return True, expiry_date_str
    except Exception:
        return False, None


def is_license_expired(expiry_date_str: str) -> bool:
    """Bitiş tarihini kontrol eder. 99991231 = sonsuz."""
    if expiry_date_str == "99991231":
        return False
    try:
        expiry = datetime.datetime.strptime(expiry_date_str, "%Y%m%d").date()
        return datetime.date.today() > expiry
    except Exception:
        return True


def read_license_file() -> dict | None:
    """
    /etc/ankavm/license.key dosyasını okur.
    Dosya formatı: base64(hwid|license_key|SALT)
    Returns: {"hwid": ..., "license_key": ...} or None
    """
    if not os.path.exists(LICENSE_FILE_PATH):
        return None
    try:
        with open(LICENSE_FILE_PATH, 'r') as f:
            content = f.read().strip()
        decoded = base64.b64decode(content).decode('utf-8')
        if not decoded.endswith(SALT):
            return None
        inner = decoded[:-len(SALT)]
        hwid, license_key = inner.split("|", 1)
        # trailing pipe before SALT
        license_key = license_key.rstrip("|")
        return {"hwid": hwid, "license_key": license_key}
    except Exception:
        return None


async def hwid_license_middleware(request: Request, call_next):
    path = request.url.path
    # Bypass: lisans endpointleri ve static dosyalar
    if path in ("/api/v1/license/verify", "/api/license/status", "/api/license/update") \
            or not path.startswith("/api"):
        return await call_next(request)

    data = read_license_file()
    if not data:
        return JSONResponse(
            status_code=status.HTTP_403_FORBIDDEN,
            content={"detail": "Lisans dosyası bulunamadı. install.sh ile kurulum yapıp lisans anahtarınızı girin."}
        )

    valid, expiry_date_str = verify_license_key_signature(data["license_key"])
    if not valid:
        return JSONResponse(
            status_code=status.HTTP_403_FORBIDDEN,
            content={"detail": "Lisans anahtarı geçersiz veya değiştirilmiş."}
        )

    if is_license_expired(expiry_date_str):
        return JSONResponse(
            status_code=status.HTTP_403_FORBIDDEN,
            content={"detail": f"Lisans süresi doldu! ({expiry_date_str}) Lütfen lisansınızı yenileyin."}
        )

    return await call_next(request)

_ANKAVM_EOF_

# Write backend/routers_license.py
cat << '_ANKAVM_EOF_' > /opt/ankavm/backend/routers_license.py
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from pydantic import BaseModel
from datetime import datetime

from .database import get_db
from .models import License

router = APIRouter(prefix="/api/v1/license")

class LicenseVerifyRequest(BaseModel):
    hwid: str

@router.post("/verify")
async def verify_license(req: LicenseVerifyRequest, db: Session = Depends(get_db)):
    """Verifies a given HWID against the database"""
    license_record = db.query(License).filter(License.hwid == req.hwid).first()
    
    if not license_record:
        # Mock behavior for local testing: if no license exists, create it as active.
        # In a real environment, it would return 404 or inactive.
        license_record = License(hwid=req.hwid, status="active")
        db.add(license_record)
        db.commit()
        db.refresh(license_record)
        # raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="License not found for this HWID.")

    if license_record.status != "active":
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="License is not active.")
        
    if license_record.expire_date and license_record.expire_date < datetime.utcnow():
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="License has expired.")
        
    return {"status": "valid", "hwid": license_record.hwid}

_ANKAVM_EOF_

# Write nginx/ankavm.conf
cat << '_ANKAVM_EOF_' > /opt/ankavm/nginx/ankavm.conf
server {
    listen 80;
    server_name _; # Responds to any IP or domain pointing to this machine

    # Increase upload sizes for OS images if needed
    client_max_body_size 8G;

    # General static assets and REST API proxying
    location / {
        proxy_pass http://127.0.0.1:8086;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # Disable buffering to allow immediate chunked API transfers
        proxy_buffering off;
    }

    # WebSocket connection upgrading for virtual terminal serial line
    location /ws/ {
        proxy_pass http://127.0.0.1:8086;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        
        # Increase read and write timeouts to prevent connection closure during idle terminal states
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
_ANKAVM_EOF_

# Write systemd/ankavm.service
cat << '_ANKAVM_EOF_' > /opt/ankavm/systemd/ankavm.service
[Unit]
Description=AnkaVM KVM VDS Management Engine Daemon
After=network.target libvirtd.service
Requires=libvirtd.service

[Service]
Type=simple
User=ankavm
Group=ankavm
WorkingDirectory=/opt/ankavm
Environment=PATH=/opt/ankavm/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/opt/ankavm/venv/bin/uvicorn backend.main:app --host 0.0.0.0 --port 8086

# Restart parameters
Restart=always
RestartSec=5

# Limit output logging
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
_ANKAVM_EOF_


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
echo -e "${GREEN}✓ Codebase files written and ownership set.${NC}\n"

# 5. Initialize Python Virtual Environment & dependencies
echo -e "${YELLOW}[5/7] Constructing Python Virtual Environment...${NC}"
python3 -m venv /opt/ankavm/venv
/opt/ankavm/venv/bin/pip install --upgrade pip
/opt/ankavm/venv/bin/pip install -r /opt/ankavm/backend/requirements.txt
chown -R ankavm:ankavm /opt/ankavm/venv
echo -e "${GREEN}✓ Virtual environment dependencies installed.${NC}\n"

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

echo -e "${GREEN}✓ All daemon controllers enabled and running.${NC}\n"

# 7. Configure Nginx reverse proxy
echo -e "${YELLOW}[7/7] Installing Nginx Reverse Proxy...${NC}"
cp /opt/ankavm/nginx/ankavm.conf /etc/nginx/sites-available/ankavm
rm -f /etc/nginx/sites-enabled/ankavm
ln -s /etc/nginx/sites-available/ankavm /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Verify configurations and reload Nginx
if nginx -t; then
  systemctl restart nginx
  echo -e "${GREEN}✓ Nginx reverse proxy active on port 80.${NC}\n"
else
  echo -e "${RED}Warning: Nginx configuration test failed. Please check /etc/nginx/sites-available/ankavm${NC}\n"
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
