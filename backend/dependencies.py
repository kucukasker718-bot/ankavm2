from fastapi import Depends, HTTPException, status, Header
from sqlalchemy.orm import Session
from datetime import datetime
from .database import get_db
from .models import UserModule, Module

def get_current_user_id(x_user_id: str = Header(..., description="WiseCP User ID")):
    try:
        return int(x_user_id)
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid User ID format")

def require_module(module_name: str):
    def module_checker(
        user_id: int = Depends(get_current_user_id),
        db: Session = Depends(get_db)
    ):
        # Find the module
        module = db.query(Module).filter(Module.name == module_name).first()
        if not module:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"Module '{module_name}' does not exist in the system."
            )
        
        # Check user license
        user_module = db.query(UserModule).filter(
            UserModule.user_id == user_id,
            UserModule.module_id == module.id,
            UserModule.is_active == True
        ).first()
        
        if not user_module:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"Active license required for module '{module_name}'."
            )
            
        if user_module.expires_at and user_module.expires_at < datetime.utcnow():
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"License for module '{module_name}' has expired."
            )
            
        return user_module
    
    return module_checker
