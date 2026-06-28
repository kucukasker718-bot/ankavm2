from fastapi import APIRouter, Depends, HTTPException, UploadFile, File, BackgroundTasks
from sqlalchemy.orm import Session
from typing import List
import os
import shutil

from .database import get_db
from .models import Image, ImageStatus, Module, UserModule
from .dependencies import get_current_user_id, require_module

router = APIRouter(prefix="/api/v1")

# Directories
UPLOAD_DIR = "/var/lib/ankavm/uploads"
os.makedirs(UPLOAD_DIR, exist_ok=True)

# -----------------
# IMAGES ENDPOINTS
# -----------------
@router.post("/images/upload")
async def upload_image(
    background_tasks: BackgroundTasks,
    file: UploadFile = File(...),
    db: Session = Depends(get_db)
    # Require admin or specific module? Assuming open for admin for now.
):
    """Uploads an ISO or Template for VCenter sync"""
    file_path = os.path.join(UPLOAD_DIR, file.filename)
    
    with open(file_path, "wb") as buffer:
        shutil.copyfileobj(file.file, buffer)
        
    db_image = Image(
        name=file.filename,
        filename=file.filename,
        status=ImageStatus.UPLOADING
    )
    db.add(db_image)
    db.commit()
    db.refresh(db_image)
    
    # Trigger Celery task (mocked here, should use celery .delay())
    # from .celery_app import sync_image_to_vcenter
    # sync_image_to_vcenter.delay(db_image.id, file_path)
    
    return {"message": "Image upload started", "image_id": db_image.id}

@router.get("/images")
async def list_images(db: Session = Depends(get_db)):
    """List available images for VDS provisioning"""
    images = db.query(Image).all()
    return images

# -----------------
# MODULES ENDPOINTS
# -----------------
@router.post("/modules/activate")
async def activate_module(
    module_name: str,
    user_id: int,
    db: Session = Depends(get_db)
    # Requires webhook authentication here
):
    """WiseCP webhook endpoint to activate a module (feature:activate)"""
    module = db.query(Module).filter(Module.name == module_name).first()
    if not module:
        # Create module if it doesn't exist
        module = Module(name=module_name, description=f"Auto-generated {module_name}")
        db.add(module)
        db.commit()
        db.refresh(module)
        
    user_module = db.query(UserModule).filter(
        UserModule.user_id == user_id,
        UserModule.module_id == module.id
    ).first()
    
    if user_module:
        user_module.is_active = True
    else:
        user_module = UserModule(user_id=user_id, module_id=module.id, is_active=True)
        db.add(user_module)
        
    db.commit()
    return {"status": "success", "message": f"Module {module_name} activated for user {user_id}"}

@router.get("/modules")
async def list_user_modules(
    user_id: int = Depends(get_current_user_id),
    db: Session = Depends(get_db)
):
    """List active modules for the user"""
    user_modules = db.query(UserModule).filter(
        UserModule.user_id == user_id,
        UserModule.is_active == True
    ).all()
    
    return [{"module_name": um.module.name, "expires_at": um.expires_at} for um in user_modules]

# -----------------
# DEMO PROTECTED ENDPOINT
# -----------------
@router.get("/web-console/ticket", dependencies=[Depends(require_module("web_console"))])
async def get_web_console_ticket(vm_id: str):
    """Generates an MKS ticket for VCenter Web Console (requires web_console module)"""
    # ... VCenter logic to generate ticket
    return {"ticket": "mks-ticket-12345", "vm_id": vm_id}
