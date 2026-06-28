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
