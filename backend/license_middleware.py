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
