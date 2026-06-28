import os
import re
import shutil
import urllib.request
from urllib.parse import urlparse
from fastapi import APIRouter, Depends, HTTPException, UploadFile, File, BackgroundTasks
from sqlalchemy.orm import Session
from backend.database import get_db, SessionLocal
from backend.models import Image, ImageStatus
from pydantic import BaseModel
from typing import List

router = APIRouter(prefix="/api/images", tags=["images"])

# In a real environment, this should be /var/lib/libvirt/images
# For dev/windows, we'll use a local folder
UPLOAD_DIR = os.path.join(os.getcwd(), "storage_images")
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

# Global dictionary to track download progress
DOWNLOAD_PROGRESS = {}

class ImageDownloadRequest(BaseModel):
    name: str
    url: str

def derive_download_filename(name: str, url: str) -> str:
    parsed = urlparse(url)
    basename = os.path.basename(parsed.path)
    if basename and "." in basename:
        return basename

    slug = re.sub(r"[^A-Za-z0-9._-]+", "_", name.strip().lower()).strip("._-")
    return f"{slug}.iso"


def download_image_task(url: str, filename: str):
    from backend.config import LIBVIRT_IMAGES_DIR

    target_dir = LIBVIRT_IMAGES_DIR or os.path.join(os.getcwd(), "storage_images")
    os.makedirs(target_dir, exist_ok=True)
    target_path = os.path.join(target_dir, filename)

    DOWNLOAD_PROGRESS[filename] = {"status": "downloading", "progress": 0}

    db = SessionLocal()
    image = None

    def reporthook(blocknum, blocksize, totalsize):
        readsofar = blocknum * blocksize
        if totalsize > 0:
            percent = (readsofar * 100) / totalsize
            if percent > 100:
                percent = 100
            DOWNLOAD_PROGRESS[filename]["progress"] = int(percent)

    try:
        image = db.query(Image).filter(Image.filename == filename).first()
        if not image:
            image = Image(name=filename, filename=filename, is_template=False, status=ImageStatus.SYNCING)
            db.add(image)
            db.commit()
            db.refresh(image)
        else:
            image.status = ImageStatus.SYNCING
            db.commit()

        urllib.request.urlretrieve(url, target_path, reporthook)
        DOWNLOAD_PROGRESS[filename]["status"] = "completed"
        DOWNLOAD_PROGRESS[filename]["progress"] = 100

        if image:
            image.status = ImageStatus.READY
            db.commit()

        print(f"[Download Task] Success: {filename}")
    except Exception as e:
        DOWNLOAD_PROGRESS[filename]["status"] = "failed"
        DOWNLOAD_PROGRESS[filename]["error"] = str(e)
        if image:
            image.status = ImageStatus.FAILED
            db.commit()
        print(f"[Download Task] Failed: {e}")
    finally:
        db.close()

@router.post("/download")
async def download_image(req: ImageDownloadRequest, background_tasks: BackgroundTasks, db: Session = Depends(get_db)):
    filename = derive_download_filename(req.name, req.url)

    background_tasks.add_task(download_image_task, req.url, filename)

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
