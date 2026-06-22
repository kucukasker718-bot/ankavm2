import os
import shutil

# API Configurations
API_HOST = os.getenv("ANKAVM_HOST", "0.0.0.0")
API_PORT = int(os.getenv("ANKAVM_PORT", "8086"))
API_KEY = os.getenv("ANKAVM_API_KEY", "ankavm-secure-dev-token-2026")
LICENSE_KEY = os.getenv("ANKAVM_LICENSE_KEY", "ANKAVM-TRIAL-KEY-2026")

# Libvirt Configurations
LIBVIRT_IMAGES_DIR = os.getenv("ANKAVM_IMAGES_DIR", "/var/lib/libvirt/images")
DEFAULT_BRIDGE = os.getenv("ANKAVM_BRIDGE", "virbr0")

# Auto-detect if we should run in Mock mode (e.g. if virsh is not available)
# This enables the app to run and serve the full dashboard interface for demo and local development.
HAS_VIRSH = shutil.which("virsh") is not None
IS_MOCK = os.getenv("ANKAVM_MOCK", str(not HAS_VIRSH)).lower() in ("true", "1", "yes")

print(f"[AnkaVM] Config loaded. IS_MOCK={IS_MOCK}, Host={API_HOST}:{API_PORT}")
