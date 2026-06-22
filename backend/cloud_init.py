import os
import shutil
import tempfile
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
