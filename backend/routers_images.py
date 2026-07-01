import os
import shutil
from fastapi import APIRouter, Depends, HTTPException, UploadFile, File, BackgroundTasks
from sqlalchemy.orm import Session
from backend.database import get_db
from backend.models import Image, ImageStatus
from pydantic import BaseModel
from typing import List

router = APIRouter(prefix="/api/images", tags=["images"])

from backend.config import LIBVIRT_IMAGES_DIR

# Use the configured images directory (Desktop/AnkaVM_ISOs on Windows)
UPLOAD_DIR = LIBVIRT_IMAGES_DIR
os.makedirs(UPLOAD_DIR, exist_ok=True)

class ImageResponse(BaseModel):
    id: int
    name: str
    filename: str
    is_template: bool
    status: str

    class Config:
        from_attributes = True

@router.get("", response_model=List[ImageResponse])
def get_images(db: Session = Depends(get_db)):
    images = db.query(Image).all()
    # If no images, let's create a default one to show in UI
    if not images:
        default_img = Image(
            name="Ubuntu 22.04 LTS",
            filename="ubuntu-22.04-server-cloudimg-amd64.img",
            is_template=True,
            status=ImageStatus.READY
        )
        db.add(default_img)
        db.commit()
        db.refresh(default_img)
        images = [default_img]
    return images

import urllib.request

# Global dictionary to track download progress
DOWNLOAD_PROGRESS = {}

class ImageDownloadRequest(BaseModel):
    name: str
    url: str

def download_image_task(url: str, filename: str, image_name: str):
    import os
    from backend.config import LIBVIRT_IMAGES_DIR
    os.makedirs(LIBVIRT_IMAGES_DIR, exist_ok=True)
    target_path = os.path.join(LIBVIRT_IMAGES_DIR, filename)
    
    DOWNLOAD_PROGRESS[filename] = {"status": "downloading", "progress": 0}
    
    def reporthook(blocknum, blocksize, totalsize):
        readsofar = blocknum * blocksize
        if totalsize > 0:
            percent = (readsofar * 100) / totalsize
            if percent > 100:
                percent = 100
            DOWNLOAD_PROGRESS[filename]["progress"] = int(percent)
    
    try:
        urllib.request.urlretrieve(url, target_path, reporthook)
        DOWNLOAD_PROGRESS[filename]["status"] = "completed"
        DOWNLOAD_PROGRESS[filename]["progress"] = 100
        print(f"[Download Task] Success: {filename}")
        
        # Add to DB
        from backend.database import SessionLocal
        from backend.models import Image, ImageStatus
        db = SessionLocal()
        existing = db.query(Image).filter(Image.filename == filename).first()
        if not existing:
            new_image = Image(
                name=image_name,
                filename=filename,
                is_template=False,
                status=ImageStatus.READY
            )
            db.add(new_image)
        else:
            existing.status = ImageStatus.READY
        db.commit()
        db.close()
    except Exception as e:
        DOWNLOAD_PROGRESS[filename]["status"] = "failed"
        DOWNLOAD_PROGRESS[filename]["error"] = str(e)
        print(f"[Download Task] Failed: {e}")

@router.post("/download")
async def download_image(req: ImageDownloadRequest, background_tasks: BackgroundTasks, db: Session = Depends(get_db)):
    # Slugify: lowercase and replace spaces with underscores (matches frontend)
    filename = req.name.lower().replace(" ", "_") + ".iso"
    
    # Send to background task so it doesn't block FastAPI
    background_tasks.add_task(download_image_task, req.url, filename, req.name)
    
    return {"message": "Download started in background", "filename": filename}

@router.get("/downloads")
def get_downloads():
    return DOWNLOAD_PROGRESS

@router.post("/upload")
async def upload_image(file: UploadFile = File(...), db: Session = Depends(get_db)):
    if not file.filename.endswith(('.iso', '.img', '.qcow2', '.ova', '.vmdk')):
        raise HTTPException(status_code=400, detail="Sadece ISO, IMG, QCOW2, OVA ve VMDK desteklenmektedir.")
    
    file_location = os.path.join(UPLOAD_DIR, file.filename)
    
    # Create DB record in UPLOADING state
    new_image = Image(
        name=file.filename,
        filename=file.filename,
        is_template=False,
        status=ImageStatus.UPLOADING
    )
    db.add(new_image)
    db.commit()
    db.refresh(new_image)
    
    try:
        with open(file_location, "wb+") as file_object:
            shutil.copyfileobj(file.file, file_object)
        
        # After upload finishes, set to READY
        new_image.status = ImageStatus.READY
        db.commit()
    except Exception as e:
        new_image.status = ImageStatus.FAILED
        db.commit()
        raise HTTPException(status_code=500, detail=f"Yükleme hatası: {str(e)}")
        
    return {"message": "İmaj başarıyla yüklendi", "image_id": new_image.id}
