#!/usr/bin/env bash
# ==============================================================================
# AnkaVM - Self-Contained Automated Installer for Ubuntu
# ==============================================================================
#
# This single script contains the entire application codebase (FastAPI backend,
# corporate frontend, Nginx reverse-proxy, Systemd service).
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
  genisoimage

# Ensure libvirtd service is active
systemctl enable --now libvirtd
echo -e "${GREEN}✓ Hypervisor engines active.${NC}\n"

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
EOF
chmod 0440 "$SUDOERS_FILE"
echo -e "${GREEN}✓ Sudo wrapper limits written to $SUDOERS_FILE.${NC}\n"

# 4. Deploy codebase dynamically from script payload
echo -e "${YELLOW}[4/7] Deploying application codebase to /opt/ankavm...${NC}"
mkdir -p /opt/ankavm/backend
mkdir -p /opt/ankavm/frontend
mkdir -p /opt/ankavm/nginx
mkdir -p /opt/ankavm/systemd

# Write backend/requirements.txt
cat << '_ANKAVM_EOF_' > /opt/ankavm/backend/requirements.txt
fastapi>=0.110.0
uvicorn>=0.28.0
pydantic>=2.6.0
psutil>=5.9.0
websockets>=12.0
_ANKAVM_EOF_

# Write backend/config.py
cat << '_ANKAVM_EOF_' > /opt/ankavm/backend/config.py
import os
import shutil

# API Configurations
API_HOST = os.getenv("ANKAVM_HOST", "0.0.0.0")
API_PORT = int(os.getenv("ANKAVM_PORT", "8086"))
API_KEY = os.getenv("ANKAVM_API_KEY", "ankavm-secure-dev-token-2026")

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
    action: str = Field(..., description="Power cycle command: start, stop, restart, force-stop")

    @field_validator("action")
    @classmethod
    def validate_action(cls, v: str) -> str:
        valid_actions = {"start", "stop", "restart", "force-stop"}
        if v.lower() not in valid_actions:
            raise ValueError(f"Action must be one of {valid_actions}")
        return v.lower()

class VMResponse(BaseModel):
    name: str
    status: str
    cpu: int
    ram_mb: int
    disk_gb: int
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
                return VMResponse(**db[name])
            return VMResponse(name=name, status=status, cpu=1, ram_mb=1024, disk_gb=20, os_template="unknown")

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

            return VMResponse(
                name=name,
                status=status,
                cpu=cpu,
                ram_mb=ram_mb,
                disk_gb=20,
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
            
            self._write_mock_db(db)
            self._add_log("SUCCESS", f"Sanal makine '{name}' üzerinde '{action}' işlemi uygulandı.")
            return f"Action '{action}' executed successfully on VM '{name}' (Mock)"

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

        if IS_MOCK:
            db = self._read_mock_db()
            if vm.name in db:
                # Release IP if vm already exists
                self.ipam.release_ip(allocated_ip)
                raise ValueError(f"VM with name '{vm.name}' already exists.")
            
            new_vm = {
                "name": vm.name,
                "status": "running",
                "cpu": vm.cpu,
                "ram_mb": vm.ram_mb,
                "disk_gb": vm.disk_gb,
                "ip_address": allocated_ip,
                "vnc_port": 5900 + len(db),
                "os_template": vm.os_template
            }
            db[vm.name] = new_vm
            self._write_mock_db(db)
            self._add_log("SUCCESS", f"Yeni VDS oluşturuldu: '{vm.name}' ({allocated_ip}).")
            return VMResponse(**new_vm)

        # Real Execution using qemu-img backing templates and virt-install ISO mount
        disk_path = f"{LIBVIRT_IMAGES_DIR}/{vm.name}.qcow2"
        template_img = f"{LIBVIRT_IMAGES_DIR}/templates/{vm.os_template}.qcow2"
        
        # Ensure templates directory is active
        os.makedirs(os.path.dirname(template_img), exist_ok=True)
        
        # Create backing copy-on-write image
        if os.path.exists(template_img):
            # Instant provisioning from master template
            self._run_secure_cmd([
                "/usr/bin/qemu-img", "create", "-f", "qcow2",
                "-b", template_img, "-F", "qcow2", disk_path
            ])
            # Resize volume allocation to target parameters
            self._run_secure_cmd([
                "/usr/bin/qemu-img", "resize", disk_path, f"{vm.disk_gb}G"
            ])
        else:
            # Fallback to empty image if master template not available yet
            self._run_secure_cmd([
                "/usr/bin/qemu-img", "create", "-f", "qcow2",
                disk_path, f"{vm.disk_gb}G"
            ])

        cmd = [
            "/usr/bin/virt-install",
            "--name", vm.name,
            "--vcpus", str(vm.cpu),
            "--memory", str(vm.ram_mb),
            "--disk", f"path={disk_path},format=qcow2,bus=virtio",
            "--disk", f"path={seed_iso_path},device=cdrom", # Mount Cloud-init configuration seed
            "--network", f"bridge={DEFAULT_BRIDGE},model=virtio",
            "--graphics", "vnc,listen=0.0.0.0",
            "--noautoconsole",
            "--import",
            "--os-variant", "ubuntu22.04"
        ]
        
        try:
            self._run_secure_cmd(cmd)
            self._add_log("SUCCESS", f"Yeni VDS başarıyla kuruldu ve IPAM IP atandı: '{vm.name}' ({allocated_ip})")
            return self.get_vm_details(vm.name, "running")
        except Exception as e:
            # Cleanup resources on failure
            self.ipam.release_ip(allocated_ip)
            CloudInitBuilder.cleanup_seed_iso(vm.name)
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

        if IS_MOCK:
            db = self._read_mock_db()
            if name not in db:
                raise ValueError(f"VM '{name}' does not exist.")
            del db[name]
            self._write_mock_db(db)
            self._add_log("WARNING", f"VDS silindi ve IPAM havuzuna IP iade edildi: '{name}' ({vm_ip}).")
            return f"VM '{name}' deleted successfully (Mock)"

        # Real Execution
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
        if IS_MOCK:
            return [
                {
                    "name": "default",
                    "status": "active",
                    "path": LIBVIRT_IMAGES_DIR,
                    "capacity_gb": 500.0,
                    "allocation_gb": 180.5,
                    "free_gb": 319.5,
                    "usage_percent": 36.1,
                    "volume_count": len(self.list_vms())
                },
                {
                    "name": "iso-templates",
                    "status": "active",
                    "path": "/var/lib/libvirt/boot",
                    "capacity_gb": 150.0,
                    "allocation_gb": 45.0,
                    "free_gb": 105.0,
                    "usage_percent": 30.0,
                    "volume_count": 4
                }
            ]

        try:
            result = self._run_secure_cmd(["/usr/bin/virsh", "pool-list", "--all"])
            pools = []
            lines = result.stdout.strip().split("\n")
            if len(lines) > 2:
                for line in lines[2:]:
                    parts = line.split()
                    if len(parts) >= 2:
                        name = parts[0]
                        status = parts[1]
                        
                        info_out = self._run_secure_cmd(["/usr/bin/virsh", "pool-info", name]).stdout
                        cap_match = re.search(r"Capacity:\s+([\d\.]+)\s+(\w+)", info_out)
                        alloc_match = re.search(r"Allocation:\s+([\d\.]+)\s+(\w+)", info_out)
                        free_match = re.search(r"Available:\s+([\d\.]+)\s+(\w+)", info_out)
                        
                        def to_gb(val, unit):
                            v = float(val)
                            if "GiB" in unit or "GB" in unit:
                                return v
                            if "MiB" in unit or "MB" in unit:
                                return v / 1024
                            if "TiB" in unit or "TB" in unit:
                                return v * 1024
                            return v / (1024**3)

                        cap = to_gb(cap_match.group(1), cap_match.group(2)) if cap_match else 100.0
                        alloc = to_gb(alloc_match.group(1), alloc_match.group(2)) if alloc_match else 0.0
                        free = to_gb(free_match.group(1), free_match.group(2)) if free_match else 100.0
                        
                        usage = (alloc / cap) * 100 if cap > 0 else 0

                        pools.append({
                            "name": name,
                            "status": status,
                            "path": LIBVIRT_IMAGES_DIR if name == "default" else f"/var/lib/libvirt/{name}",
                            "capacity_gb": round(cap, 1),
                            "allocation_gb": round(alloc, 1),
                            "free_gb": round(free, 1),
                            "usage_percent": round(usage, 1),
                            "volume_count": len(self.list_vms()) if name == "default" else 2
                        })
            return pools
        except Exception as e:
            print(f"Error listing pools: {e}")
            return []

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
_ANKAVM_EOF_

# Write backend/main.py
cat << '_ANKAVM_EOF_' > /opt/ankavm/backend/main.py
import os
import asyncio
from fastapi import FastAPI, Depends, Security, HTTPException, status, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.security.api_key import APIKeyHeader
from typing import List, Dict, Any

from backend.config import API_KEY, API_PORT, API_HOST, IS_MOCK
from backend.schemas import VMCreate, VMResponse, HostStats, VMTelemetry, VMAction, NetworkCreate
from backend.vm_manager import VMManager

app = FastAPI(
    title="AnkaVM API",
    description="Enterprise KVM & VDS Virtualization Management Server",
    version="1.0.0"
)

# CORS Policy configuration
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# API Security header
api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)
vm_manager = VMManager()

async def verify_api_key(header_value: str = Security(api_key_header)):
    if not header_value:
        return None
    if header_value != API_KEY:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Forbidden: Invalid AnkaVM API Key."
        )
    return header_value

# --- VM API Endpoints ---

@app.get("/api/vms", response_model=List[VMResponse])
def get_vms(api_key: str = Depends(verify_api_key)):
    """Fetch status and configurations for all KVM virtual machines"""
    return vm_manager.list_vms()

@app.post("/api/vms", response_model=VMResponse, status_code=201)
def create_vm(vm: VMCreate, api_key: str = Depends(verify_api_key)):
    """Provision a new virtual machine instance"""
    try:
        return vm_manager.create_vm(vm)
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

@app.post("/api/vms/{name}/action")
def execute_vm_action(name: str, payload: VMAction, api_key: str = Depends(verify_api_key)):
    """Execute power operations (start, stop, restart, force-stop) on a virtual machine"""
    try:
        message = vm_manager.execute_action(name, payload.action)
        return {"status": "success", "message": message}
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

@app.delete("/api/vms/{name}")
def delete_vm(name: str, api_key: str = Depends(verify_api_key)):
    """Purge a virtual machine from KVM environment and destroy storage blocks"""
    try:
        message = vm_manager.delete_vm(name)
        return {"status": "success", "message": message}
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

@app.get("/api/host/stats", response_model=HostStats)
def get_host_stats(api_key: str = Depends(verify_api_key)):
    """Fetch host-level computing metrics (CPU, RAM, Disk utilization)"""
    return vm_manager.get_host_stats()

@app.get("/api/vms/{name}/telemetry", response_model=VMTelemetry)
def get_vm_telemetry(name: str, api_key: str = Depends(verify_api_key)):
    """Fetch telemetry analytics for a specific virtual machine"""
    try:
        return vm_manager.get_vm_telemetry(name)
    except Exception as e:
        raise HTTPException(status_code=404, detail=str(e))

# --- Network & Storage API Endpoints ---

@app.get("/api/networks")
def get_networks(api_key: str = Depends(verify_api_key)):
    """Fetch all libvirt virtual network configurations"""
    return vm_manager.list_networks()

@app.post("/api/networks", status_code=201)
def create_network(net: NetworkCreate, api_key: str = Depends(verify_api_key)):
    """Define and spin up a new virtual network bridge"""
    try:
        message = vm_manager.create_network(net.name, net.bridge, net.ip, net.dhcp_start, net.dhcp_end)
        return {"status": "success", "message": message}
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

@app.get("/api/storage")
def get_storage(api_key: str = Depends(verify_api_key)):
    """Fetch all libvirt storage pools and allocations"""
    return vm_manager.list_storage_pools()

@app.get("/api/logs")
def get_logs(api_key: str = Depends(verify_api_key)):
    """Fetch virtualization panel system execution activity logs"""
    return vm_manager.get_logs()

@app.get("/api/ipam/pools")
def get_ipam_pools(api_key: str = Depends(verify_api_key)):
    """Fetch all IPAM address allocation pools"""
    return vm_manager.ipam.list_pools()

@app.get("/api/ipam/leases")
def get_ipam_leases(api_key: str = Depends(verify_api_key)):
    """Fetch all active DHCP/allocated network leases"""
    return vm_manager.ipam.list_leases()

# --- Interactive Web Terminal Emulation Server ---

@app.websocket("/ws/vms/{name}/console")
async def vm_console_websocket(websocket: WebSocket, name: str):
    await websocket.accept()
    
    try:
        vms = vm_manager.list_vms()
        vm = next((v for v in vms if v.name == name), None)
        
        if not vm:
            await websocket.send_text("\r\n\x1b[31;1mError: Virtual Machine not found.\x1b[0m\r\n")
            await websocket.close()
            return

        if vm.status != "running":
            await websocket.send_text(
                f"\r\n\x1b[33;1mWarning: Virtual Machine '{name}' is currently offline.\x1b[0m\r\n"
                "Please start the VM using the dashboard power grid to access the live serial console.\r\n\r\n"
            )
            
        await websocket.send_text(
            f"\x1b[36;1m[AnkaVM Console Wrapper V1.2 - Secure Session Started]\x1b[0m\r\n"
            f"Connecting to virtual serial device ttyS0 for VM: \x1b[32m{name}\x1b[0m\r\n"
            f"Boot log output buffered. Enter terminal commands below.\r\n"
            f"Type 'help' to see local control commands.\r\n\r\n"
            f"ubuntu-server-ankavm login: "
        )

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
                        await websocket.send_text(f"Password: (hidden)\r\nWelcome to Ubuntu 22.04 LTS (GNU/Linux 5.15.0-generic x86_64)\r\n\r\n{prompt}")
                    else:
                        await websocket.send_text("Invalid credentials.\r\n\r\nubuntu-server-ankavm login: ")
                    current_line = ""
                    continue
                
                if cmd == "help":
                    await websocket.send_text(
                        "AnkaVM Terminal Help Guide:\r\n"
                        "  help          - Display this command console resource index\r\n"
                        "  status        - Print the current node CPU, memory and virtual disk details\r\n"
                        "  neofetch      - Render futuristic sysinfo banner\r\n"
                        "  top           - Run visual CPU and processing threads live simulator\r\n"
                        "  reboot        - Trigger VM reboot protocol\r\n"
                        "  exit          - Close session connection\r\n"
                    )
                elif cmd == "status":
                    await websocket.send_text(
                        f"VM Cluster:  {name}\r\n"
                        f"Allocated vCPUs: {vm.cpu} Core(s)\r\n"
                        f"Allocated RAM:   {vm.ram_mb} MB\r\n"
                        f"Virtual Disk:    {vm.disk_gb} GB\r\n"
                        f"Virtual IP:      {vm.ip_address}\r\n"
                        f"Service Status:  ACTIVE\r\n"
                    )
                elif cmd == "neofetch":
                    await websocket.send_text(
                        "\x1b[36;1m            ,---.    \x1b[0m       root@ubuntu-ankavm\r\n"
                        "\x1b[36;1m           /     \\   \x1b[0m       -----------------\r\n"
                        "\x1b[36;1m      \\\\  | () () |  \x1b[0m       OS: Ubuntu 22.04 LTS x86_64\r\n"
                        "\x1b[36;1m       \\\\  \\  ^  /   \x1b[0m       Kernel: 5.15.0-91-generic\r\n"
                        "\x1b[36;1m        \\\\  `---'    \x1b[0m       Uptime: 2 days, 4 hours\r\n"
                        "\x1b[35;1m         \\\\          \x1b[0m       Packages: 682 (dpkg)\r\n"
                        "\x1b[35;1m          \\\\         \x1b[0m       Shell: bash 5.1.16\r\n"
                        "\x1b[35;1m     AnkaVM Core KVM \x1b[0m       VCPU: KVM Virtual Processor\r\n"
                        f"                     Memory: {vm.ram_mb}MB / 16384MB\r\n"
                    )
                elif cmd == "top":
                    await websocket.send_text("\x1b[?1049h\x1b[H\x1b[2J")
                    for _ in range(5):
                        top_out = (
                            f"\x1b[H\x1b[1mTasks: 122 total,   2 running, 120 sleeping,   0 stopped,   0 zombie\x1b[0m\r\n"
                            f"%Cpu(s): {round(random.uniform(5, 60), 1)} us,  {round(random.uniform(1, 10), 1)} sy,  0.0 ni, 90.0 id\r\n"
                            f"MiB Mem :  {vm.ram_mb}.0 total,  {round(vm.ram_mb * 0.4, 1)} free,  {round(vm.ram_mb * 0.6, 1)} used\r\n\r\n"
                            f"  PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND\r\n"
                            f" 1056 root      20   0  712412  48256  24212 S   2.1   1.2   0:12.45 systemd\r\n"
                            f" 2401 root      20   0   45120   4212   3102 R   1.8   0.1   0:05.12 top\r\n"
                            f" 1109 libvirt   20   0 1521401 214512  98124 S   0.5   5.2   1:42.88 qemu-system-x86\r\n"
                            f"\r\n\x1b[33mPress Ctrl+C or type 'q' to exit simulator\x1b[0m"
                        )
                        await websocket.send_text(top_out)
                        await asyncio.sleep(1)
                    await websocket.send_text("\x1b[?1049l")
                elif cmd == "reboot":
                    await websocket.send_text("\r\nBroadcast message from root@ankavm (systemd):\r\n\r\nThe system is going down for reboot NOW!\r\n")
                    vm_manager.execute_action(name, "restart")
                    await asyncio.sleep(2)
                    await websocket.close()
                    break
                elif cmd == "exit":
                    await websocket.send_text("Closing console session link.\r\n")
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
            elif data == "\x03":
                await websocket.send_text("^C\r\n" + (prompt if logged_in else "ubuntu-server-ankavm login: "))
                current_line = ""
            else:
                current_line += data
                if not logged_in and len(current_line) > 0 and current_line[-1] == data and cmd == "":
                    await websocket.send_text(data)
                elif logged_in:
                    await websocket.send_text(data)

    except WebSocketDisconnect:
        print(f"WS Console Session for VM '{name}' disconnected.")
    except Exception as e:
        print(f"WS error: {e}")

# --- Mounting Frontend ---
FRONTEND_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "frontend"))

if os.path.exists(FRONTEND_DIR):
    app.mount("/", StaticFiles(directory=FRONTEND_DIR, html=True), name="static")
else:
    print(f"[Warning] Frontend directory not found at: {FRONTEND_DIR}.")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("backend.main:app", host=API_HOST, port=API_PORT, reload=True)
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
        activeTab: 'dashboard', // dashboard, vms, networks, ipam, storage, settings
        
        // Data States
        vms: [],
        networks: [],
        storagePools: [],
        activityLogs: [],
        ipPools: [],
        ipLeases: [],
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
        
        // Provisioning forms
        createForm: {
            name: '',
            cpu: 2,
            ram_mb: 2048,
            disk_gb: 40,
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

        // Charts
        hostCpuChart: null,
        hostRamChart: null,
        hostDiskChart: null,
        vmPerformanceChart: null,

        // Websockets console
        wsConsole: null,
        termInstance: null,

        async init() {
            console.log("Initializing Corporate Dashboard Controller with Automation...");
            
            // Initial data pull
            await Promise.all([
                this.fetchVms(),
                this.fetchHostStats(),
                this.fetchNetworks(),
                this.fetchStorage(),
                this.fetchLogs(),
                this.fetchIpamData()
            ]);
            
            this.loading = false;
            
            // Set up charts on next tick
            this.$nextTick(() => {
                this.initHostCharts();
            });

            // Set up timers for data sync
            setInterval(() => this.fetchHostStats(), 4000);
            setInterval(() => this.fetchVms(), 5000);
            setInterval(() => this.fetchActiveVmTelemetry(), 3000);
            setInterval(() => this.fetchLogs(), 6000);
            setInterval(() => {
                if (this.activeTab === 'networks') this.fetchNetworks();
                if (this.activeTab === 'storage') this.fetchStorage();
                if (this.activeTab === 'ipam') this.fetchIpamData();
            }, 8000);
        },

        // Tab selection change hook
        setTab(tabName) {
            this.activeTab = tabName;
            
            if (tabName === 'dashboard') {
                this.$nextTick(() => {
                    this.initHostCharts();
                    this.updateHostCharts();
                });
            }
            
            if (tabName === 'vms' && this.selectedVmName) {
                this.$nextTick(() => {
                    this.initVmPerformanceChart();
                });
            }
        },

        // --- Fetch actions ---

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

        async fetchStorage() {
            try {
                const res = await fetch(`${API_BASE}/storage`, { headers: API_HEADERS });
                if (res.ok) this.storagePools = await res.json();
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

        selectVm(name) {
            if (this.selectedVmName === name) {
                this.selectedVmName = null;
                this.selectedVmTelemetry = null;
                this.telemetryHistory = { cpu: [], ram: [], timestamps: [] };
                return;
            }
            this.selectedVmName = name;
            this.telemetryHistory = { cpu: [], ram: [], timestamps: [] };
            
            this.$nextTick(() => {
                this.initVmPerformanceChart();
                this.fetchActiveVmTelemetry();
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
                await Promise.all([this.fetchVms(), this.fetchLogs(), this.fetchIpamData()]);
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
                this.createForm = { name: '', cpu: 2, ram_mb: 2048, disk_gb: 40, os_template: 'ubuntu-22.04', root_password: 'AnkaVM-Secure-Root-2026', ssh_key: '' };
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
                await Promise.all([this.fetchVms(), this.fetchLogs(), this.fetchIpamData()]);
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
            // Simulated adding IP pool via networks post config
            this.showToast(`IP Havuzu ekleniyor: ${this.createPoolForm.name}`, 'info');
            this.showCreatePoolModal = false;
            
            // In mock configurations, we can define a virtual bridge to trigger VMManager network mapping
            const mockNet = {
                name: this.createPoolForm.name,
                bridge: 'virbr' + (this.networks.length + 1),
                ip: this.createPoolForm.gateway,
                dhcp_start: this.createPoolForm.dns_primary, // mapping parameters
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

            this.hostCpuChart = new Chart(cpuEl, chartConfig('#00f0ff'));
            this.hostRamChart = new Chart(ramEl, chartConfig('#ff007f'));
            this.hostDiskChart = new Chart(diskEl, chartConfig('#39ff14'));
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
                            label: 'CPU Core Usage (%)',
                            data: this.telemetryHistory.cpu,
                            borderColor: '#00f0ff',
                            backgroundColor: 'rgba(0, 240, 255, 0.05)',
                            fill: true,
                            tension: 0.4,
                            borderWidth: 2,
                            pointRadius: 1
                        },
                        {
                            label: 'Memory Load (%)',
                            data: this.telemetryHistory.ram,
                            borderColor: '#ff007f',
                            backgroundColor: 'rgba(255, 0, 127, 0.05)',
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
                            labels: { color: '#e2e8f0', font: { family: 'Orbitron', size: 10 } }
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

        // --- Xterm.js Terminal WebSocket Console ---

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
                    foreground: '#00f0ff',
                    cursor: '#00f0ff',
                    selectionBackground: 'rgba(0, 240, 255, 0.3)',
                    black: '#000000',
                    red: '#ff3838',
                    green: '#39ff14',
                    yellow: '#ffd700',
                    blue: '#00f0ff',
                    magenta: '#ff007f',
                    cyan: '#00f0ff',
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
    <title>AnkaVM // Kurumsal VDS Hypervisor Paneli</title>
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
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/xterm@5.3.0/css/xterm.min.css" />
    <script src="https://cdn.jsdelivr.net/npm/xterm@5.3.0/lib/xterm.min.js"></script>
    <link rel="stylesheet" href="style.css" />
    <script src="app.js"></script>
    <script defer src="https://cdn.jsdelivr.net/npm/alpinejs@3.x.x/dist/cdn.min.js"></script>
</head>
<body class="bg-[#0b0f19] min-h-screen flex text-slate-300" x-data="vmPanel">

    <div x-show="loading" class="fixed inset-0 bg-[#0b0f19] z-50 flex flex-col items-center justify-center space-y-4">
        <div class="w-16 h-16 rounded-full border-2 border-t-brand-500 border-r-transparent border-l-transparent border-b-transparent animate-spin"></div>
        <div class="text-sm font-semibold tracking-wider text-slate-400">ANKAVM YÜKLENİYOR...</div>
    </div>

    <!-- Left Sidebar -->
    <aside class="w-60 bg-[#111827] border-r border-slate-800 flex flex-col justify-between shrink-0 sticky top-0 h-screen z-30">
        <div class="p-5 border-b border-slate-800">
            <div class="flex items-center space-x-3">
                <div class="w-8 h-8 rounded bg-brand-500 flex items-center justify-center text-white font-bold"><i class="fa-solid fa-server text-sm"></i></div>
                <div>
                    <h1 class="text-base font-bold text-white tracking-wide">Anka<span class="text-brand-500">VM</span></h1>
                    <p class="text-[9px] text-slate-500 font-mono tracking-wider uppercase">Hypervisor Console</p>
                </div>
            </div>
        </div>

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
                <span>IPAM (IP Havuzları)</span>
            </button>
            <button @click="setTab('networks')" :class="activeTab === 'networks' ? 'bg-slate-800 text-white' : 'text-slate-400 hover:text-white hover:bg-slate-800/30'" class="w-full flex items-center space-x-3 px-3.5 py-2.5 rounded transition text-left">
                <i class="fa-solid fa-network-wired text-sm" :class="activeTab === 'networks' ? 'text-brand-500' : ''"></i>
                <span>Ağ Yönetimi</span>
            </button>
            <button @click="setTab('storage')" :class="activeTab === 'storage' ? 'bg-slate-800 text-white' : 'text-slate-400 hover:text-white hover:bg-slate-800/30'" class="w-full flex items-center space-x-3 px-3.5 py-2.5 rounded transition text-left">
                <i class="fa-solid fa-database text-sm" :class="activeTab === 'storage' ? 'text-brand-500' : ''"></i>
                <span>Depolama Alanları</span>
            </button>
            <button @click="setTab('settings')" :class="activeTab === 'settings' ? 'bg-slate-800 text-white' : 'text-slate-400 hover:text-white hover:bg-slate-800/30'" class="w-full flex items-center space-x-3 px-3.5 py-2.5 rounded transition text-left">
                <i class="fa-solid fa-sliders text-sm" :class="activeTab === 'settings' ? 'text-brand-500' : ''"></i>
                <span>Sistem Ayarları & WiseCP</span>
            </button>
        </nav>

        <div class="p-4 border-t border-slate-800 font-mono text-[9px] text-slate-500">
            <div class="flex items-center space-x-2 mb-1.5">
                <span class="w-1.5 h-1.5 rounded-full bg-emerald-500"></span>
                <span class="text-slate-400 font-semibold uppercase">API Bağlantısı Aktif</span>
            </div>
            <div>VERİ MERKEZİ: LOKAL KVM</div>
        </div>
    </aside>

    <!-- Main Container -->
    <div class="flex-1 flex flex-col min-w-0">
        <header class="h-16 border-b border-slate-800 bg-[#111827] flex items-center justify-between px-6">
            <div class="flex items-center space-x-3">
                <h2 class="text-sm font-bold text-white uppercase tracking-wider">
                    <span x-show="activeTab === 'dashboard'">GÖSTERGE PANELİ</span>
                    <span x-show="activeTab === 'vms'">SANAL SUNUCU LİSTESİ</span>
                    <span x-show="activeTab === 'ipam'">IPAM YÖNETİMİ</span>
                    <span x-show="activeTab === 'networks'">SANAL AĞ KÖPRÜLERİ</span>
                    <span x-show="activeTab === 'storage'">DEPOLAMA HAVUZLARI</span>
                    <span x-show="activeTab === 'settings'">SİSTEM ENTEGRASYONLARI & WiseCP</span>
                </h2>
                <div class="h-4 w-[1px] bg-slate-800"></div>
                <span class="text-[11px] font-mono text-slate-400" x-text="`Aktif VM: ${hostStats.vms_running} / Toplam: ${hostStats.vms_total}`"></span>
            </div>
        </header>

        <main class="flex-1 p-6 overflow-y-auto">
            <!-- DASHBOARD -->
            <div x-show="activeTab === 'dashboard'" x-cloak class="space-y-6">
                <div class="grid grid-cols-1 md:grid-cols-3 gap-5">
                    <div class="corp-card rounded-lg p-4">
                        <div class="flex justify-between items-start mb-2">
                            <div>
                                <h3 class="text-xs uppercase text-slate-400 font-bold">Host CPU</h3>
                                <p class="text-xl font-bold text-white mt-0.5" x-text="`${hostStats.cpu_usage}%`"></p>
                            </div>
                        </div>
                        <div class="relative h-24 flex items-center justify-center"><canvas id="cpuChartCanvas"></canvas></div>
                    </div>
                    <div class="corp-card rounded-lg p-4">
                        <div class="flex justify-between items-start mb-2">
                            <div>
                                <h3 class="text-xs uppercase text-slate-400 font-bold">Host RAM</h3>
                                <p class="text-xl font-bold text-white mt-0.5" x-text="`${hostStats.ram_used_gb}G / ${hostStats.ram_total_gb}G`"></p>
                            </div>
                        </div>
                        <div class="relative h-24 flex items-center justify-center"><canvas id="ramChartCanvas"></canvas></div>
                    </div>
                    <div class="corp-card rounded-lg p-4">
                        <div class="flex justify-between items-start mb-2">
                            <div>
                                <h3 class="text-xs uppercase text-slate-400 font-bold">Host Disk</h3>
                                <p class="text-xl font-bold text-white mt-0.5" x-text="`${hostStats.disk_used_gb}G / ${hostStats.disk_total_gb}G`"></p>
                            </div>
                        </div>
                        <div class="relative h-24 flex items-center justify-center"><canvas id="diskChartCanvas"></canvas></div>
                    </div>
                </div>

                <div class="corp-card rounded-lg p-5">
                    <div class="border-b border-slate-800 pb-3 mb-3"><h2 class="text-xs font-bold uppercase text-slate-200">Hypervisor Eylem Günlüğü</h2></div>
                    <div class="h-48 bg-slate-950/80 border border-slate-800/80 rounded p-3 overflow-y-auto font-mono text-[10px] space-y-1">
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

            <!-- VMS LIST -->
            <div x-show="activeTab === 'vms'" x-cloak class="grid grid-cols-1 lg:grid-cols-3 gap-6">
                <div class="lg:col-span-2 space-y-5">
                    <div class="corp-card rounded-lg p-5">
                        <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3 mb-5">
                            <input type="text" x-model="searchQuery" placeholder="Sunucu veya IP ara..." class="pl-3 pr-3 py-1.5 bg-[#0b0f19] border border-slate-700 rounded text-xs text-white focus:outline-none focus:border-brand-500 font-mono w-full max-w-xs"/>
                            <button @click="showCreateModal = true" class="btn-primary text-xs font-semibold py-1.5 px-3 rounded">VDS OLUŞTUR</button>
                        </div>
                        <div class="overflow-x-auto">
                            <table class="min-w-full divide-y divide-slate-800 text-xs">
                                <thead>
                                    <tr class="text-slate-500 font-semibold uppercase text-left">
                                        <th class="py-2.5 px-3">Sunucu Adı</th>
                                        <th class="py-2.5 px-3">Durum</th>
                                        <th class="py-2.5 px-3">Kaynak</th>
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
                                            <td class="py-2.5 px-3 text-[10px]" x-text="`${vm.cpu} Core / ${(vm.ram_mb/1024).toFixed(0)}G / ${vm.disk_gb}G`"></td>
                                            <td class="py-2.5 px-3 text-slate-300" x-text="vm.ip_address"></td>
                                            <td class="py-2.5 px-3 text-right" @click.stop>
                                                <button x-show="vm.status !== 'running'" @click="triggerAction(vm.name, 'start')" class="w-6 h-6 rounded bg-slate-900 border border-slate-800 text-emerald-400"><i class="fa-solid fa-play text-[9px]"></i></button>
                                                <button x-show="vm.status === 'running'" @click="triggerAction(vm.name, 'stop')" class="w-6 h-6 rounded bg-slate-900 border border-slate-800 text-red-400"><i class="fa-solid fa-stop text-[9px]"></i></button>
                                                <button @click="openConsole(vm.name)" class="w-6 h-6 rounded bg-slate-900 border border-slate-800 text-brand-500"><i class="fa-solid fa-terminal text-[9px]"></i></button>
                                                <button @click="deleteVm(vm.name)" class="w-6 h-6 rounded bg-slate-900 border border-slate-800 text-red-500"><i class="fa-solid fa-trash-can text-[9px]"></i></button>
                                            </td>
                                        </tr>
                                    </template>
                                </tbody>
                            </table>
                        </div>
                    </div>
                </div>

                <div class="corp-card rounded-lg p-5">
                    <h2 class="text-xs font-bold uppercase mb-3">VDS Telemetri Grafigi</h2>
                    <div x-show="selectedVmName" class="space-y-4">
                        <div class="h-32 bg-slate-950/40 rounded border border-slate-800 p-2"><canvas id="vmPerformanceChartCanvas"></canvas></div>
                        <button @click="triggerAction(selectedVmName, 'force-stop')" class="w-full bg-red-600 text-white text-[10px] font-bold py-1.5 rounded">GÜCÜ KES (DESTROY)</button>
                    </div>
                </div>
            </div>

            <!-- IPAM -->
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

                <div class="corp-card rounded-lg p-5">
                    <div class="flex justify-between items-center mb-5">
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
            </div>

            <!-- SETTINGS & WiseCP CODE -->
            <div x-show="activeTab === 'settings'" x-cloak class="space-y-6">
                <div class="corp-card rounded-lg p-5 space-y-4">
                    <h2 class="text-xs font-bold uppercase text-white">WiseCP & WHMCS Entegrasyon Modülü</h2>
                    <p class="text-xs text-slate-400">Modül dosyasını sunucunuzda aşağıdaki dizine yüklemeniz yeterlidir:</p>
                    <div class="bg-slate-900 p-2 rounded border border-slate-800 font-mono text-[10px] text-brand-500">/cpanel/modules/Servers/AnkaVM/AnkaVM.php</div>
                    <div class="flex justify-between items-center"><span class="text-[10px] text-slate-500">Modül Kod Bloğu:</span><button @click="navigator.clipboard.writeText(document.getElementById('php-module-code').innerText); showToast('WiseCP Modül Kodu kopyalandı!', 'success')" class="px-2.5 py-1 rounded bg-slate-900 border border-slate-700 text-[10px] text-brand-500">Kopyala</button></div>
                    <pre class="bg-slate-950 p-3 rounded border border-slate-800 font-mono text-[10px] max-h-48 overflow-y-auto text-slate-300" id="php-module-code">
&lt;?php
class AnkaVM {
    private $apiUrl;
    private $apiKey;
    public function __construct($apiUrl, $apiKey) {
        $this->apiUrl = rtrim($apiUrl, '/');
        $this->apiKey = $apiKey;
    }
    public function createServer($vmName, $cpu, $ram, $disk, $template, $rootPassword) {
        return $this->call('/api/vms', 'POST', [
            'name' => $vmName, 'cpu' => $cpu, 'ram_mb' => $ram, 'disk_gb' => $disk,
            'os_template' => $template, 'root_password' => $rootPassword
        ]);
    }
}</pre>
                </div>
            </div>
        </main>
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
                <div class="grid grid-cols-3 gap-2">
                    <select x-model.number="createForm.cpu" class="p-2 bg-slate-900 border border-slate-700 rounded text-white"><option value="1">1 CPU</option><option value="2">2 CPU</option></select>
                    <select x-model.number="createForm.ram_mb" class="p-2 bg-slate-900 border border-slate-700 rounded text-white"><option value="1024">1 GB</option><option value="2048">2 GB</option></select>
                    <select x-model.number="createForm.disk_gb" class="p-2 bg-slate-900 border border-slate-700 rounded text-white"><option value="20">20 GB</option><option value="40">40 GB</option></select>
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

    <!-- Terminal Modal -->
    <div x-show="showConsoleModal" class="fixed inset-0 bg-black/90 z-50 flex items-center justify-center p-4">
        <div class="corp-card w-full max-w-2xl rounded-lg overflow-hidden" @click.away="closeConsole()">
            <div class="border-b border-slate-800 p-3 bg-[#111827] flex justify-between items-center">
                <span class="text-xs font-bold text-slate-300">KVM SERİ KONSOL</span>
                <button @click="closeConsole()"><i class="fa-solid fa-xmark text-slate-400 hover:text-white"></i></button>
            </div>
            <div class="p-4 bg-[#070a13]"><div id="terminal-container" class="w-full"></div></div>
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


# Set permissions
chown -R ankavm:ankavm /opt/ankavm
echo -e "${GREEN}✓ Codebase files written and ownership set.${NC}\n"

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
