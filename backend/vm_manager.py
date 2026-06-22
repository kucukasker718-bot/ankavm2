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
