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
