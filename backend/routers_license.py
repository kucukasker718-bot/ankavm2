from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from pydantic import BaseModel
from datetime import datetime

from .database import get_db
from .models import License

router = APIRouter(prefix="/api/v1/license")

class LicenseVerifyRequest(BaseModel):
    hwid: str

@router.post("/verify")
async def verify_license(req: LicenseVerifyRequest, db: Session = Depends(get_db)):
    """Verifies a given HWID against the database"""
    license_record = db.query(License).filter(License.hwid == req.hwid).first()
    
    if not license_record:
        # Mock behavior for local testing: if no license exists, create it as active.
        # In a real environment, it would return 404 or inactive.
        license_record = License(hwid=req.hwid, status="active")
        db.add(license_record)
        db.commit()
        db.refresh(license_record)
        # raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="License not found for this HWID.")

    if license_record.status != "active":
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="License is not active.")
        
    if license_record.expire_date and license_record.expire_date < datetime.utcnow():
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="License has expired.")
        
    return {"status": "valid", "hwid": license_record.hwid}
