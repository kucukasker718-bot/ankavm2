from sqlalchemy import Column, Integer, String, Boolean, DateTime, ForeignKey, Enum
from sqlalchemy.orm import relationship
import enum
from datetime import datetime
from .database import Base

class ImageStatus(str, enum.Enum):
    UPLOADING = "uploading"
    SYNCING = "syncing"
    READY = "ready"
    FAILED = "failed"

class Image(Base):
    __tablename__ = "images"
    id = Column(Integer, primary_key=True, index=True)
    name = Column(String, index=True)
    filename = Column(String)
    is_template = Column(Boolean, default=False)
    content_library_item_id = Column(String, nullable=True)
    status = Column(Enum(ImageStatus), default=ImageStatus.UPLOADING)
    created_at = Column(DateTime, default=datetime.utcnow)

class Module(Base):
    __tablename__ = "modules"
    id = Column(Integer, primary_key=True, index=True)
    name = Column(String, unique=True, index=True)  # e.g., 'web_console', 'auto_password'
    description = Column(String)
    is_active = Column(Boolean, default=True)

class UserModule(Base):
    __tablename__ = "user_modules"
    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, index=True)  # WiseCP user ID
    module_id = Column(Integer, ForeignKey("modules.id"))
    is_active = Column(Boolean, default=True)
    expires_at = Column(DateTime, nullable=True)

    module = relationship("Module")

class VCenterResource(Base):
    __tablename__ = "vcenter_resources"
    id = Column(Integer, primary_key=True, index=True)
    resource_type = Column(String)  # 'VM', 'Datastore', 'Network'
    local_id = Column(String)
    vcenter_id = Column(String)

class License(Base):
    __tablename__ = "licenses"
    id = Column(Integer, primary_key=True, index=True)
    hwid = Column(String, unique=True, index=True)
    status = Column(String, default="active") # 'active', 'suspended'
    expire_date = Column(DateTime, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)
