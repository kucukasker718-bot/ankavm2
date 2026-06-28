from fastapi import APIRouter, Depends, HTTPException, BackgroundTasks, Header
from sqlalchemy.orm import Session
from backend.database import get_db
from backend.schemas import WiseCPDeploy
from pydantic import BaseModel
import asyncio
import httpx
from datetime import datetime

router = APIRouter(prefix="/api/wisecp", tags=["wisecp"])

# Simulated queue
wisecp_orders = []

async def callback_wisecp(url: str, data: dict):
    if not url:
        return
    try:
        async with httpx.AsyncClient() as client:
            await client.post(url, json=data, timeout=10.0)
    except Exception as e:
        print(f"WiseCP Callback failed: {e}")

async def process_deployment(order: WiseCPDeploy):
    # Simulate deployment delay
    await asyncio.sleep(5)
    
    # Generate mock IP and Password
    generated_ip = f"192.168.100.{order.cpu * 10 + 2}"
    generated_pass = "AutoPass_" + order.order_id[-4:]
    
    for o in wisecp_orders:
        if o["order_id"] == order.order_id:
            o["status"] = "COMPLETED"
            o["ip_address"] = generated_ip
            o["root_password"] = generated_pass
            break
            
    # Send callback
    if order.callback_url:
        await callback_wisecp(order.callback_url, {
            "order_id": order.order_id,
            "status": "active",
            "ip": generated_ip,
            "password": generated_pass
        })

@router.post("/deploy")
async def wisecp_deploy(order: WiseCPDeploy, background_tasks: BackgroundTasks, x_api_key: str = Header(None)):
    if not x_api_key or x_api_key != "ankavm-secure-dev-token-2026":
        raise HTTPException(status_code=401, detail="Invalid API Key")
        
    wisecp_orders.insert(0, {
        "order_id": order.order_id,
        "product_id": order.product_id,
        "name": order.name,
        "cpu": order.cpu,
        "ram_mb": order.ram_mb,
        "disk_gb": order.disk_gb,
        "status": "PROVISIONING",
        "ip_address": None,
        "error": None,
        "created_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    })
    
    background_tasks.add_task(process_deployment, order)
    
    return {"status": "accepted", "message": "Deployment started."}

class ActionRequest(BaseModel):
    order_id: str
    callback_url: str = None

@router.post("/suspend")
async def wisecp_suspend(req: ActionRequest, x_api_key: str = Header(None)):
    if not x_api_key or x_api_key != "ankavm-secure-dev-token-2026":
        raise HTTPException(status_code=401, detail="Invalid API Key")
    # Simulate suspension
    return {"status": "success", "message": f"{req.order_id} suspended."}

@router.post("/unsuspend")
async def wisecp_unsuspend(req: ActionRequest, x_api_key: str = Header(None)):
    if not x_api_key or x_api_key != "ankavm-secure-dev-token-2026":
        raise HTTPException(status_code=401, detail="Invalid API Key")
    return {"status": "success", "message": f"{req.order_id} unsuspended."}

@router.post("/terminate")
async def wisecp_terminate(req: ActionRequest, x_api_key: str = Header(None)):
    if not x_api_key or x_api_key != "ankavm-secure-dev-token-2026":
        raise HTTPException(status_code=401, detail="Invalid API Key")
    return {"status": "success", "message": f"{req.order_id} terminated."}

@router.get("/orders")
def get_wisecp_orders():
    return wisecp_orders
