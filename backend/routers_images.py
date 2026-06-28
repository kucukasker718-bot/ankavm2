import os
import shutil
from fastapi import APIRouter, Depends, HTTPException, UploadFile, File
from sqlalchemy.orm import Session
from backend.database import get_db
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
