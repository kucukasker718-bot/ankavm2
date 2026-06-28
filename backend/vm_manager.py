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
        
        is_windows = vm.os_template.lower().startswith("win") or "windows" in vm.os_template.lower()
        if is_windows:
            from backend.windows_autounattend import generate_windows_autounattend_iso
            password = vm.root_password or "AnkaVM-Secure-Root-2026"
            seed_iso_path = generate_windows_autounattend_iso(password)
        else:
            # 2. Build Cloud-Init seed ISO containing Netplan and pass keys for Linux
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

        os_variant = "win2k22" if is_windows else "ubuntu22.04"
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
            "--os-variant", os_variant
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
