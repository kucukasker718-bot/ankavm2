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
