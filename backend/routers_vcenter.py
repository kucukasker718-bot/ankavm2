from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from backend.database import get_db
from backend.models import VCenterConfig
from pydantic import BaseModel
from typing import Optional, List
import ssl

try:
    from pyVim.connect import SmartConnect, Disconnect
    from pyVmomi import vim
    PYVMOMI_AVAILABLE = True
except ImportError:
    PYVMOMI_AVAILABLE = False

router = APIRouter(prefix="/api/vcenter", tags=["vcenter"])

class VCenterConfigRequest(BaseModel):
    host: str
    username: str
    password: str

class VCenterConfigResponse(BaseModel):
    host: Optional[str]
    username: Optional[str]
    is_active: bool

class VCenterItem(BaseModel):
    name: str
    type: str
    capacityGB: Optional[int] = None
    freeGB: Optional[int] = None

@router.get("/config", response_model=VCenterConfigResponse)
def get_vcenter_config(db: Session = Depends(get_db)):
    config = db.query(VCenterConfig).first()
    if not config:
        return {"host": "", "username": "", "is_active": False}
    return {
        "host": config.host,
        "username": config.username,
        "is_active": config.is_active
    }

@router.post("/config")
def save_vcenter_config(req: VCenterConfigRequest, db: Session = Depends(get_db)):
    if not req.host or not req.username or not req.password:
        raise HTTPException(status_code=400, detail="Eksik bilgi girdiniz.")
        
    # Attempt real connection if pyvmomi is installed
    if PYVMOMI_AVAILABLE:
        try:
            context = ssl._create_unverified_context()
            si = SmartConnect(host=req.host, user=req.username, pwd=req.password, sslContext=context)
            Disconnect(si)
        except Exception as e:
            raise HTTPException(status_code=400, detail=f"VCenter bağlantı hatası: {str(e)}")
            
    config = db.query(VCenterConfig).first()
    if not config:
        config = VCenterConfig()
        db.add(config)
    
    config.host = req.host
    config.username = req.username
    config.password = req.password
    config.is_active = True
    
    db.commit()
    msg = "VCenter başarıyla bağlandı." if PYVMOMI_AVAILABLE else "VCenter bilgileri kaydedildi (PyVmomi yüklü olmadığı için simüle edildi)."
    return {"message": msg}

@router.get("/discovery", response_model=List[VCenterItem])
def discover_vcenter(db: Session = Depends(get_db)):
    config = db.query(VCenterConfig).first()
    if not config or not config.is_active:
        raise HTTPException(status_code=400, detail="VCenter konfigüre edilmemiş.")
        
    items = []
    if PYVMOMI_AVAILABLE:
        try:
            context = ssl._create_unverified_context()
            si = SmartConnect(host=config.host, user=config.username, pwd=config.password, sslContext=context)
            content = si.RetrieveContent()
            for child in content.rootFolder.childEntity:
                if hasattr(child, 'datastore'):
                    for ds in child.datastore:
                        summary = ds.summary
                        items.append({
                            "name": summary.name,
                            "type": "Datastore",
                            "capacityGB": summary.capacity // (1024**3),
                            "freeGB": summary.freeSpace // (1024**3)
                        })
                if hasattr(child, 'network'):
                    for net in child.network:
                        items.append({
                            "name": net.name,
                            "type": "Network"
                        })
            Disconnect(si)
        except Exception as e:
            raise HTTPException(status_code=500, detail=str(e))
    else:
        # Mock Discovery Data
        items = [
            {"name": "vsanDatastore", "type": "Datastore", "capacityGB": 2048, "freeGB": 1024},
            {"name": "VM Network", "type": "Network"},
            {"name": "Management Network", "type": "Network"}
        ]
        
    return items
