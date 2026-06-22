import os
import asyncio
from fastapi import FastAPI, Depends, Security, HTTPException, status, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.security.api_key import APIKeyHeader
from typing import List, Dict, Any

from backend.config import API_KEY, API_PORT, API_HOST, IS_MOCK
from backend.schemas import VMCreate, VMResponse, HostStats, VMTelemetry, VMAction, NetworkCreate
from backend.vm_manager import VMManager

app = FastAPI(
    title="AnkaVM API",
    description="Enterprise KVM & VDS Virtualization Management Server",
    version="1.0.0"
)

# CORS Policy configuration
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# API Security header
api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)
vm_manager = VMManager()

async def verify_api_key(header_value: str = Security(api_key_header)):
    if not header_value:
        return None
    if header_value != API_KEY:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Forbidden: Invalid AnkaVM API Key."
        )
    return header_value

# --- VM API Endpoints ---

@app.get("/api/vms", response_model=List[VMResponse])
def get_vms(api_key: str = Depends(verify_api_key)):
    """Fetch status and configurations for all KVM virtual machines"""
    return vm_manager.list_vms()

@app.post("/api/vms", response_model=VMResponse, status_code=201)
def create_vm(vm: VMCreate, api_key: str = Depends(verify_api_key)):
    """Provision a new virtual machine instance"""
    try:
        return vm_manager.create_vm(vm)
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

@app.post("/api/vms/{name}/action")
def execute_vm_action(name: str, payload: VMAction, api_key: str = Depends(verify_api_key)):
    """Execute power operations (start, stop, restart, force-stop) on a virtual machine"""
    try:
        message = vm_manager.execute_action(name, payload.action)
        return {"status": "success", "message": message}
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

@app.delete("/api/vms/{name}")
def delete_vm(name: str, api_key: str = Depends(verify_api_key)):
    """Purge a virtual machine from KVM environment and destroy storage blocks"""
    try:
        message = vm_manager.delete_vm(name)
        return {"status": "success", "message": message}
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

@app.get("/api/host/stats", response_model=HostStats)
def get_host_stats(api_key: str = Depends(verify_api_key)):
    """Fetch host-level computing metrics (CPU, RAM, Disk utilization)"""
    return vm_manager.get_host_stats()

@app.get("/api/vms/{name}/telemetry", response_model=VMTelemetry)
def get_vm_telemetry(name: str, api_key: str = Depends(verify_api_key)):
    """Fetch telemetry analytics for a specific virtual machine"""
    try:
        return vm_manager.get_vm_telemetry(name)
    except Exception as e:
        raise HTTPException(status_code=404, detail=str(e))

# --- Network & Storage API Endpoints ---

@app.get("/api/networks")
def get_networks(api_key: str = Depends(verify_api_key)):
    """Fetch all libvirt virtual network configurations"""
    return vm_manager.list_networks()

@app.post("/api/networks", status_code=201)
def create_network(net: NetworkCreate, api_key: str = Depends(verify_api_key)):
    """Define and spin up a new virtual network bridge"""
    try:
        message = vm_manager.create_network(net.name, net.bridge, net.ip, net.dhcp_start, net.dhcp_end)
        return {"status": "success", "message": message}
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

@app.get("/api/storage")
def get_storage(api_key: str = Depends(verify_api_key)):
    """Fetch all libvirt storage pools and allocations"""
    return vm_manager.list_storage_pools()

@app.get("/api/logs")
def get_logs(api_key: str = Depends(verify_api_key)):
    """Fetch virtualization panel system execution activity logs"""
    return vm_manager.get_logs()

@app.get("/api/ipam/pools")
def get_ipam_pools(api_key: str = Depends(verify_api_key)):
    """Fetch all IPAM address allocation pools"""
    return vm_manager.ipam.list_pools()

@app.get("/api/ipam/leases")
def get_ipam_leases(api_key: str = Depends(verify_api_key)):
    """Fetch all active DHCP/allocated network leases"""
    return vm_manager.ipam.list_leases()

# --- Interactive Web Terminal Emulation Server ---

@app.websocket("/ws/vms/{name}/console")
async def vm_console_websocket(websocket: WebSocket, name: str):
    await websocket.accept()
    
    try:
        vms = vm_manager.list_vms()
        vm = next((v for v in vms if v.name == name), None)
        
        if not vm:
            await websocket.send_text("\r\n\x1b[31;1mError: Virtual Machine not found.\x1b[0m\r\n")
            await websocket.close()
            return

        if vm.status != "running":
            await websocket.send_text(
                f"\r\n\x1b[33;1mWarning: Virtual Machine '{name}' is currently offline.\x1b[0m\r\n"
                "Please start the VM using the dashboard power grid to access the live serial console.\r\n\r\n"
            )
            
        await websocket.send_text(
            f"\x1b[36;1m[AnkaVM Console Wrapper V1.2 - Secure Session Started]\x1b[0m\r\n"
            f"Connecting to virtual serial device ttyS0 for VM: \x1b[32m{name}\x1b[0m\r\n"
            f"Boot log output buffered. Enter terminal commands below.\r\n"
            f"Type 'help' to see local control commands.\r\n\r\n"
            f"ubuntu-server-ankavm login: "
        )

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
                        await websocket.send_text(f"Password: (hidden)\r\nWelcome to Ubuntu 22.04 LTS (GNU/Linux 5.15.0-generic x86_64)\r\n\r\n{prompt}")
                    else:
                        await websocket.send_text("Invalid credentials.\r\n\r\nubuntu-server-ankavm login: ")
                    current_line = ""
                    continue
                
                if cmd == "help":
                    await websocket.send_text(
                        "AnkaVM Terminal Help Guide:\r\n"
                        "  help          - Display this command console resource index\r\n"
                        "  status        - Print the current node CPU, memory and virtual disk details\r\n"
                        "  neofetch      - Render futuristic sysinfo banner\r\n"
                        "  top           - Run visual CPU and processing threads live simulator\r\n"
                        "  reboot        - Trigger VM reboot protocol\r\n"
                        "  exit          - Close session connection\r\n"
                    )
                elif cmd == "status":
                    await websocket.send_text(
                        f"VM Cluster:  {name}\r\n"
                        f"Allocated vCPUs: {vm.cpu} Core(s)\r\n"
                        f"Allocated RAM:   {vm.ram_mb} MB\r\n"
                        f"Virtual Disk:    {vm.disk_gb} GB\r\n"
                        f"Virtual IP:      {vm.ip_address}\r\n"
                        f"Service Status:  ACTIVE\r\n"
                    )
                elif cmd == "neofetch":
                    await websocket.send_text(
                        "\x1b[36;1m            ,---.    \x1b[0m       root@ubuntu-ankavm\r\n"
                        "\x1b[36;1m           /     \\   \x1b[0m       -----------------\r\n"
                        "\x1b[36;1m      \\\\  | () () |  \x1b[0m       OS: Ubuntu 22.04 LTS x86_64\r\n"
                        "\x1b[36;1m       \\\\  \\  ^  /   \x1b[0m       Kernel: 5.15.0-91-generic\r\n"
                        "\x1b[36;1m        \\\\  `---'    \x1b[0m       Uptime: 2 days, 4 hours\r\n"
                        "\x1b[35;1m         \\\\          \x1b[0m       Packages: 682 (dpkg)\r\n"
                        "\x1b[35;1m          \\\\         \x1b[0m       Shell: bash 5.1.16\r\n"
                        "\x1b[35;1m     AnkaVM Core KVM \x1b[0m       VCPU: KVM Virtual Processor\r\n"
                        f"                     Memory: {vm.ram_mb}MB / 16384MB\r\n"
                    )
                elif cmd == "top":
                    await websocket.send_text("\x1b[?1049h\x1b[H\x1b[2J")
                    for _ in range(5):
                        top_out = (
                            f"\x1b[H\x1b[1mTasks: 122 total,   2 running, 120 sleeping,   0 stopped,   0 zombie\x1b[0m\r\n"
                            f"%Cpu(s): {round(random.uniform(5, 60), 1)} us,  {round(random.uniform(1, 10), 1)} sy,  0.0 ni, 90.0 id\r\n"
                            f"MiB Mem :  {vm.ram_mb}.0 total,  {round(vm.ram_mb * 0.4, 1)} free,  {round(vm.ram_mb * 0.6, 1)} used\r\n\r\n"
                            f"  PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND\r\n"
                            f" 1056 root      20   0  712412  48256  24212 S   2.1   1.2   0:12.45 systemd\r\n"
                            f" 2401 root      20   0   45120   4212   3102 R   1.8   0.1   0:05.12 top\r\n"
                            f" 1109 libvirt   20   0 1521401 214512  98124 S   0.5   5.2   1:42.88 qemu-system-x86\r\n"
                            f"\r\n\x1b[33mPress Ctrl+C or type 'q' to exit simulator\x1b[0m"
                        )
                        await websocket.send_text(top_out)
                        await asyncio.sleep(1)
                    await websocket.send_text("\x1b[?1049l")
                elif cmd == "reboot":
                    await websocket.send_text("\r\nBroadcast message from root@ankavm (systemd):\r\n\r\nThe system is going down for reboot NOW!\r\n")
                    vm_manager.execute_action(name, "restart")
                    await asyncio.sleep(2)
                    await websocket.close()
                    break
                elif cmd == "exit":
                    await websocket.send_text("Closing console session link.\r\n")
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
            elif data == "\x03":
                await websocket.send_text("^C\r\n" + (prompt if logged_in else "ubuntu-server-ankavm login: "))
                current_line = ""
            else:
                current_line += data
                if not logged_in and len(current_line) > 0 and current_line[-1] == data and cmd == "":
                    await websocket.send_text(data)
                elif logged_in:
                    await websocket.send_text(data)

    except WebSocketDisconnect:
        print(f"WS Console Session for VM '{name}' disconnected.")
    except Exception as e:
        print(f"WS error: {e}")

# --- Mounting Frontend ---
FRONTEND_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "frontend"))

if os.path.exists(FRONTEND_DIR):
    app.mount("/", StaticFiles(directory=FRONTEND_DIR, html=True), name="static")
else:
    print(f"[Warning] Frontend directory not found at: {FRONTEND_DIR}.")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("backend.main:app", host=API_HOST, port=API_PORT, reload=True)
