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
