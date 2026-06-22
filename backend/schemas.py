from pydantic import BaseModel, Field, field_validator
import re
from typing import List, Optional

class VMCreate(BaseModel):
    name: str = Field(..., description="Unique alphanumeric name of the VM")
    cpu: int = Field(1, ge=1, le=32, description="Number of vCPUs allocated")
    ram_mb: int = Field(1024, ge=512, le=131072, description="RAM allocation in Megabytes")
    disk_gb: int = Field(20, ge=5, le=2000, description="Disk volume size in Gigabytes")
    os_template: str = Field("ubuntu-22.04", description="Operating system distribution template")
    root_password: Optional[str] = Field("AnkaVM-Secure-Root-2026", description="Administrator root password to inject")
    ssh_key: Optional[str] = Field(None, description="Authorized SSH public key to inject")

    @field_validator("name")
    @classmethod
    def validate_name(cls, v: str) -> str:
        if not re.match(r"^[a-zA-Z0-9_-]+$", v):
            raise ValueError("VM name must only contain alphanumeric characters, hyphens, and underscores")
        if len(v) < 3 or len(v) > 30:
            raise ValueError("VM name must be between 3 and 30 characters")
        return v

class VMAction(BaseModel):
    action: str = Field(..., description="Power cycle command: start, stop, restart, force-stop")

    @field_validator("action")
    @classmethod
    def validate_action(cls, v: str) -> str:
        valid_actions = {"start", "stop", "restart", "force-stop"}
        if v.lower() not in valid_actions:
            raise ValueError(f"Action must be one of {valid_actions}")
        return v.lower()

class VMResponse(BaseModel):
    name: str
    status: str
    cpu: int
    ram_mb: int
    disk_gb: int
    ip_address: Optional[str] = "192.168.122.100"
    vnc_port: Optional[int] = 5900
    os_template: str

class HostStats(BaseModel):
    cpu_usage: float
    ram_total_gb: float
    ram_used_gb: float
    ram_free_gb: float
    ram_usage_percent: float
    disk_total_gb: float
    disk_used_gb: float
    disk_free_gb: float
    disk_usage_percent: float
    vms_running: int
    vms_total: int

class VMTelemetry(BaseModel):
    vm_name: str
    cpu_usage_percent: float
    ram_used_mb: float
    ram_total_mb: float
    ram_usage_percent: float
    network_rx_kbps: float
    network_tx_kbps: float
    disk_read_kbps: float
    disk_write_kbps: float

class NetworkCreate(BaseModel):
    name: str = Field(..., description="Virtual network name")
    bridge: str = Field(..., description="Bridge interface name (e.g. virbr1)")
    ip: str = Field(..., description="Gateway IP address (e.g. 192.168.100.1)")
    dhcp_start: str = Field(..., description="DHCP lease pool start IP")
    dhcp_end: str = Field(..., description="DHCP lease pool end IP")

    @field_validator("name", "bridge")
    @classmethod
    def validate_names(cls, v: str) -> str:
        if not re.match(r"^[a-zA-Z0-9_-]+$", v):
            raise ValueError("Names must only contain alphanumeric characters, hyphens, and underscores")
        return v
