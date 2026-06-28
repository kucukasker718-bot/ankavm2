import os
import asyncio
import urllib.request
import json
from fastapi import FastAPI, Depends, Security, HTTPException, status, WebSocket, WebSocketDisconnect, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.security.api_key import APIKeyHeader
from pydantic import BaseModel
from typing import List, Dict, Any, Optional

from backend.config import API_KEY, API_PORT, API_HOST, IS_MOCK, LICENSE_KEY
from backend.schemas import VMCreate, VMResponse, HostStats, VMTelemetry, VMAction, NetworkCreate, WiseCPDeploy
from backend.vm_manager import VMManager
from backend.license_check import check_license_validity
from backend import routers_vcenter
from backend import routers_images
from backend import routers_wisecp

app = FastAPI(
    title="AnkaVM API Gateway",
    description="Enterprise KVM & VDS Virtualization SaaS Automation Server",
    version="1.5.0"
)

# CORS Policy
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(routers_vcenter.router)
app.include_router(routers_images.router)
app.include_router(routers_wisecp.router)

# API Security token header
api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)
vm_manager = VMManager()

# Global Licensing State cache
LICENSE_STATUS = {
    "is_licensed": False,
    "owner_name": "Unregistered Node",
    "allowed_ip": "",
    "allowed_domain": "",
    "expires_at": "",
    "hardware_id": "Retrieving...",
    "detail": "License verification pending."
}

def sync_license_status():
    """Triggers node license verification and updates local cache state."""
    global LICENSE_STATUS
    res = check_license_validity()
    LICENSE_STATUS.update(res)

# Run initial licensing verification check at boot
sync_license_status()

async def check_global_license(request: Request):
    """Enforces active node licensing. Lockout applies to all API routes except status / update."""
    path = request.url.path
    if path == "/api/license/status" or path == "/api/license/update" or not path.startswith("/api"):
        return
    if not LICENSE_STATUS["is_licensed"]:
        # Try a quick hot reload sync check in case the license server just booted
        sync_license_status()
        if not LICENSE_STATUS["is_licensed"]:
            raise HTTPException(
                status_code=status.HTTP_402_PAYMENT_REQUIRED,
                detail=f"License Check Failed. Hypervisor API Locked. Reason: {LICENSE_STATUS['detail']}"
            )

# Apply HWID based licensing middleware check
from backend.license_middleware import hwid_license_middleware
app.middleware("http")(hwid_license_middleware)

from fastapi.responses import JSONResponse

async def verify_api_key(header_value: str = Security(api_key_header)):
    if not header_value:
        return None
    if header_value != API_KEY:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Forbidden: Invalid AnkaVM API Key."
        )
    return header_value

# --- 1. Core Licensing Endpoints ---

@app.get("/api/license/status")
def get_license_status():
    """Lisans durumunu ve bitiş tarihini döndürür."""
    from backend.license_middleware import (
        read_license_file, verify_license_key_signature,
        is_license_expired
    )
    import subprocess
    import datetime

    data = read_license_file()

    if not data:
        try:
            result = subprocess.run(
                ["dmidecode", "-s", "system-uuid"],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
            )
            hwid = result.stdout.strip() or "Alınamadı"
        except Exception:
            hwid = "Alınamadı"
        return {
            "is_licensed": False,
            "owner_name": "Lisanssız Sunucu",
            "hardware_id": hwid,
            "expires_at": None,
            "detail": "Lisans anahtarınızı giriniz."
        }

    valid, expiry_date_str = verify_license_key_signature(data["license_key"])
    if not valid:
        return {
            "is_licensed": False,
            "owner_name": "Geçersiz Lisans",
            "hardware_id": data.get("hwid", "?"),
            "expires_at": None,
            "detail": "Lisans anahtarı geçersiz veya değiştirilmiş."
        }

    if is_license_expired(expiry_date_str):
        return {
            "is_licensed": False,
            "owner_name": "Süresi Dolmuş",
            "hardware_id": data["hwid"],
            "expires_at": expiry_date_str,
            "detail": f"Lisans süresi doldu! Lütfen yenileyin."
        }

    # Bitiş tarihi göstergesi
    if expiry_date_str == "99991231":
        expires_display = "Sonsuz (Lifetime)"
    else:
        d = datetime.datetime.strptime(expiry_date_str, "%Y%m%d").date()
        expires_display = d.strftime("%d.%m.%Y")

    return {
        "is_licensed": True,
        "owner_name": "AnkaVM Lisanslı Sunucu",
        "hardware_id": data["hwid"],
        "expires_at": expires_display,
        "detail": "Lisans aktif ve doğrulandı."
    }


class LicenseUpdatePayload(BaseModel):
    license_key: str


@app.post("/api/license/update")
def update_license_key(payload: LicenseUpdatePayload):
    """Frontend'den girilen lisans anahtarını doğrular ve license.key dosyasını oluşturur."""
    import subprocess
    import base64
    from backend.license_middleware import (
        LICENSE_FILE_PATH, SALT,
        verify_license_key_signature, is_license_expired
    )

    entered_key = payload.license_key.strip()

    # 1. HMAC imza + format doğrulama
    valid, expiry_date_str = verify_license_key_signature(entered_key)
    if not valid:
        raise HTTPException(
            status_code=400,
            detail="Geçersiz Lisans Anahtarı! Bu anahtar yetkili bir kaynak tarafından üretilmemiş."
        )

    # 2. Bitiş tarihi kontrolü
    if is_license_expired(expiry_date_str):
        raise HTTPException(
            status_code=400,
            detail=f"Bu lisans anahtarının süresi dolmuş! ({expiry_date_str})"
        )

    # 3. Sunucunun HWID'ini al
    try:
        result = subprocess.run(
            ["dmidecode", "-s", "system-uuid"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=True
        )
        hwid = result.stdout.strip()
        if not hwid:
            raise ValueError("HWID boş döndü")
    except Exception as e:
        raise HTTPException(
            status_code=400,
            detail=f"Sistem HWID alınamadı. install.sh root olarak çalıştırıldı mı? ({e})"
        )

    # 4. license.key dosyasını yaz: base64(hwid|license_key|SALT)
    try:
        raw = f"{hwid}|{entered_key}|{SALT}"
        encoded = base64.b64encode(raw.encode('utf-8')).decode('utf-8')
        os.makedirs(os.path.dirname(LICENSE_FILE_PATH), exist_ok=True)
        with open(LICENSE_FILE_PATH, 'w') as f:
            f.write(encoded)
        os.chmod(LICENSE_FILE_PATH, 0o600)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Lisans dosyası yazılamadı: {e}")

    # 5. DB kayıt (opsiyonel)
    try:
        from backend.database import SessionLocal
        from backend.models import License
        import datetime
        db = SessionLocal()
        expire_dt = None if expiry_date_str == "99991231" else \
            datetime.datetime.strptime(expiry_date_str, "%Y%m%d")
        existing = db.query(License).filter(License.hwid == hwid).first()
        if not existing:
            db.add(License(hwid=hwid, status="active", expire_date=expire_dt))
            db.commit()
        else:
            existing.status = "active"
            existing.expire_date = expire_dt
            db.commit()
        db.close()
    except Exception:
        pass

    import datetime
    if expiry_date_str == "99991231":
        expires_display = "Sonsuz (Lifetime)"
    else:
        d = datetime.datetime.strptime(expiry_date_str, "%Y%m%d").date()
        expires_display = d.strftime("%d.%m.%Y")

    return {
        "status": "success",
        "message": f"Lisans başarıyla aktive edildi! Geçerlilik: {expires_display}"
    }



# --- 2. Storage Pool Management ---

@app.get("/api/storage/pools")
def get_storage_pools(api_key: str = Depends(verify_api_key)):
    """Scans and lists capacity metrics for Directory, LVM, and ZFS disk stores."""
    return vm_manager.list_storage_pools()

# --- 3. IPAM Audit Logs ---

@app.get("/api/ipam/logs")
def get_ipam_audit_logs(api_key: str = Depends(verify_api_key)):
    """Fetches transactional IP leasing records."""
    return vm_manager.get_ipam_logs()

# --- 4. Backups & Snapshots ---

class SnapshotCreate(BaseModel):
    snapshot_name: str
    description: Optional[str] = "Manual Snapshot"

@app.post("/api/vms/{name}/snapshots", status_code=201)
def create_vm_snapshot(name: str, payload: SnapshotCreate, api_key: str = Depends(verify_api_key)):
    """Generates a restore checkpoint using KVM backing chains."""
    try:
        msg = vm_manager.create_snapshot(name, payload.snapshot_name, payload.description)
        return {"status": "success", "message": msg}
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

class SnapshotRevert(BaseModel):
    snapshot_name: str

@app.get("/api/vms/{name}/snapshots")
def get_vm_snapshots(name: str, api_key: str = Depends(verify_api_key)):
    """Lists snapshots for a specific VM."""
    try:
        return vm_manager.list_snapshots(name)
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

@app.post("/api/vms/{name}/snapshots/revert")
def revert_vm_snapshot(name: str, payload: SnapshotRevert, api_key: str = Depends(verify_api_key)):
    """Reverts a VDS to a target snapshot point."""
    try:
        msg = vm_manager.revert_snapshot(name, payload.snapshot_name)
        return {"status": "success", "message": msg}
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

# --- 5. Rescue Boot Mode ---

class RescueModePayload(BaseModel):
    action: str  # 'enable' or 'disable'
    iso_path: Optional[str] = "/var/lib/libvirt/images/rescue.iso"

@app.post("/api/vms/{name}/rescue")
def toggle_rescue_mode(name: str, payload: RescueModePayload, api_key: str = Depends(verify_api_key)):
    """Alters boot target order to start VDS via Live ISO recovery environment."""
    try:
        if payload.action.lower() == "enable":
            msg = vm_manager.enable_rescue_mode(name, payload.iso_path)
        else:
            msg = vm_manager.disable_rescue_mode(name)
        return {"status": "success", "message": msg}
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

# --- 6. vnstat Traffic Monitoring ---

@app.get("/api/vms/{name}/traffic")
def get_vm_network_traffic(name: str, api_key: str = Depends(verify_api_key)):
    """Checks live network interface stats for DDoS warning thresholds."""
    return vm_manager.get_vm_traffic(name)

# --- 7. WiseCP Deployment Worker System ---

# In-memory WiseCP Order Database for Live UI Tracking
from datetime import datetime
WISECP_ORDERS = [
    {
        "order_id": "ws-order-4812",
        "product_id": "vds-pro-saas",
        "name": "web-prod-01",
        "cpu": 4,
        "ram_mb": 8192,
        "disk_gb": 120,
        "status": "COMPLETED",
        "ip_address": "192.168.122.10",
        "created_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    },
    {
        "order_id": "ws-order-9921",
        "product_id": "vds-starter",
        "name": "db-replica-02",
        "cpu": 8,
        "ram_mb": 16384,
        "disk_gb": 350,
        "status": "COMPLETED",
        "ip_address": "192.168.122.25",
        "created_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    }
]

async def deploy_wisecp_order_task(order: WiseCPDeploy):
    """Executes asynchronous background deployment and alerts WiseCP hook callback."""
    # Find order in track list
    order_record = next((o for o in WISECP_ORDERS if o["order_id"] == order.order_id), None)
    try:
        await asyncio.sleep(2)  # Short delay to allow REST call completion
        
        # Build VMCreate request payload
        vm_payload = VMCreate(
            name=order.name,
            cpu=order.cpu,
            ram_mb=order.ram_mb,
            disk_gb=order.disk_gb,
            disk_pool=order.disk_pool,
            os_template=order.os_template,
            root_password=order.root_password
        )
        
        # Run provisioning
        print(f"[WiseCP Worker] Provisioning virtual machine: {order.name}")
        vm_res = vm_manager.create_vm(vm_payload)
        
        # Update record
        if order_record:
            order_record["status"] = "COMPLETED"
            order_record["ip_address"] = vm_res.ip_address
        
        # Send Callback
        if order.callback_url:
            print(f"[WiseCP Worker] Posting success callback for order {order.order_id}")
            cb_data = json.dumps({
                "status": "success",
                "order_id": order.order_id,
                "ip": vm_res.ip_address,
                "root_password": order.root_password,
                "vnc_port": vm_res.vnc_port,
                "message": f"Server {order.name} successfully provisioned."
            }).encode("utf-8")
            
            cb_req = urllib.request.Request(
                order.callback_url,
                data=cb_data,
                headers={"Content-Type": "application/json"},
                method="POST"
            )
            try:
                with urllib.request.urlopen(cb_req, timeout=5) as res:
                    print(f"[WiseCP Worker] Hook response code: {res.status}")
            except Exception as cb_err:
                print(f"[WiseCP Worker] Webhook call warning: {cb_err}")
                
    except Exception as e:
        print(f"[WiseCP Worker] Deployment failed for order {order.order_id}: {e}")
        if order_record:
            order_record["status"] = "FAILED"
            order_record["error"] = str(e)
            
        if order.callback_url:
            try:
                cb_data = json.dumps({
                    "status": "failed",
                    "order_id": order.order_id,
                    "message": str(e)
                }).encode("utf-8")
                cb_req = urllib.request.Request(
                    order.callback_url,
                    data=cb_data,
                    headers={"Content-Type": "application/json"},
                    method="POST"
                )
                with urllib.request.urlopen(cb_req, timeout=5):
                    pass
            except Exception:
                pass

@app.post("/api/wisecp/deploy", status_code=202)
def deploy_wisecp_order(order: WiseCPDeploy, api_key: str = Depends(verify_api_key)):
    """Receives server orders from WiseCP, returning immediate 202 and spawning background build tasks."""
    # Register order in list
    WISECP_ORDERS.insert(0, {
        "order_id": order.order_id,
        "product_id": order.product_id,
        "name": order.name,
        "cpu": order.cpu,
        "ram_mb": order.ram_mb,
        "disk_gb": order.disk_gb,
        "status": "PROVISIONING",
        "ip_address": "",
        "created_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    })
    asyncio.create_task(deploy_wisecp_order_task(order))
    return {
        "status": "PROVISIONING",
        "message": f"VM deployment for order {order.order_id} queued successfully."
    }

@app.get("/api/wisecp/orders")
def get_wisecp_orders(api_key: str = Depends(verify_api_key)):
    """Lists registered WiseCP automation orders."""
    return WISECP_ORDERS

# --- 8. Existing Standard VM Management Endpoints ---

@app.get("/api/vms", response_model=List[VMResponse])
def get_vms(api_key: str = Depends(verify_api_key)):
    return vm_manager.list_vms()

@app.post("/api/vms", response_model=VMResponse, status_code=201)
def create_vm(vm: VMCreate, api_key: str = Depends(verify_api_key)):
    try:
        return vm_manager.create_vm(vm)
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

@app.post("/api/vms/{name}/action")
def execute_vm_action(name: str, payload: VMAction, api_key: str = Depends(verify_api_key)):
    try:
        msg = vm_manager.execute_action(name, payload.action)
        return {"status": "success", "message": msg}
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

@app.delete("/api/vms/{name}")
def delete_vm(name: str, api_key: str = Depends(verify_api_key)):
    try:
        msg = vm_manager.delete_vm(name)
        return {"status": "success", "message": msg}
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

@app.get("/api/host/stats", response_model=HostStats)
def get_host_stats(api_key: str = Depends(verify_api_key)):
    return vm_manager.get_host_stats()

@app.get("/api/vms/{name}/telemetry", response_model=VMTelemetry)
def get_vm_telemetry(name: str, api_key: str = Depends(verify_api_key)):
    try:
        return vm_manager.get_vm_telemetry(name)
    except Exception as e:
        raise HTTPException(status_code=404, detail=str(e))

@app.get("/api/networks")
def get_networks(api_key: str = Depends(verify_api_key)):
    return vm_manager.list_networks()

@app.post("/api/networks", status_code=201)
def create_network(net: NetworkCreate, api_key: str = Depends(verify_api_key)):
    try:
        msg = vm_manager.create_network(net.name, net.bridge, net.ip, net.dhcp_start, net.dhcp_end)
        return {"status": "success", "message": msg}
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

@app.get("/api/storage")
def get_storage(api_key: str = Depends(verify_api_key)):
    return vm_manager.list_storage_pools()

@app.get("/api/logs")
def get_logs(api_key: str = Depends(verify_api_key)):
    return vm_manager.get_logs()

@app.get("/api/ipam/pools")
def get_ipam_pools(api_key: str = Depends(verify_api_key)):
    return vm_manager.ipam.list_pools()

@app.get("/api/ipam/leases")
def get_ipam_leases(api_key: str = Depends(verify_api_key)):
    return vm_manager.ipam.list_leases()

# --- 9. WebSocket Console Connection ---

@app.websocket("/ws/vms/{name}/console")
async def vm_console_websocket(websocket: WebSocket, name: str):
    await websocket.accept()
    try:
        vms = vm_manager.list_vms()
        vm = next((v for v in vms if v.name == name), None)
        if not vm:
            await websocket.send_text("\r\n\x1b[31;1mError: VM not found.\x1b[0m\r\n")
            await websocket.close()
            return
        if vm.status != "running":
            await websocket.send_text(f"\r\n\x1b[33;1mWarning: VM '{name}' is offline.\x1b[0m\r\n")
        await websocket.send_text(f"\x1b[36;1m[AnkaVM Console Wrapper V1.5 - Secure Session Started]\x1b[0m\r\nConnecting domain console...\r\n")
        
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
                        await websocket.send_text(f"Password: \r\nWelcome to Ubuntu 22.04 LTS\r\n\r\n{prompt}")
                    else:
                        await websocket.send_text("Invalid login.\r\n\r\nubuntu login: ")
                    current_line = ""
                    continue
                if cmd == "help":
                    await websocket.send_text("Available: status, neofetch, exit\r\n")
                elif cmd == "status":
                    await websocket.send_text(f"VM: {name} | CPU: {vm.cpu} | RAM: {vm.ram_mb}MB | IP: {vm.ip_address}\r\n")
                elif cmd == "neofetch":
                    await websocket.send_text("AnkaVM Hypervisor Host Shell Console\r\n")
                elif cmd == "exit":
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
            else:
                current_line += data
                await websocket.send_text(data)
    except WebSocketDisconnect:
        pass

# --- 10. Serve Frontend Static Assets ---
from backend.routers_vcenter import router as vcenter_router
from backend.routers_license import router as license_router
app.include_router(vcenter_router)
app.include_router(license_router)

FRONTEND_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "frontend"))
if os.path.exists(FRONTEND_DIR):
    app.mount("/", StaticFiles(directory=FRONTEND_DIR, html=True), name="static")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("backend.main:app", host=API_HOST, port=API_PORT, reload=True)
