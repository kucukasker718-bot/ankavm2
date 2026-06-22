# AnkaVM REST API Documentation

This document lists the REST API gateway endpoints for **AnkaVM** VDS Virtualization platform integration.

All API routes require the header token signature validation:
`X-API-Key: ankavm-secure-dev-token-2026`

---

## 🔑 1. Licensing Engine APIs

### Get License Verification Status
* **Endpoint**: `GET /api/license/status`
* **Response `200 OK`**:
```json
{
  "is_licensed": true,
  "owner_name": "AnkaVM Enterprise Client",
  "allowed_ip": "127.0.0.1",
  "allowed_domain": "localhost",
  "expires_at": "2027-06-22T17:55:29Z",
  "hardware_id": "ANKAVM-MOCK-DEV-HWID-UUID-1234567890",
  "detail": "Active node license verified successfully."
}
```

### Update Node License Key
* **Endpoint**: `POST /api/license/update`
* **Request Body**:
```json
{
  "license_key": "ANKAVM-PRO-SAAS-9999-KEY"
}
```
* **Response `200 OK`**:
```json
{
  "status": "success",
  "message": "License key updated. Re-triggering node validation handshake..."
}
```

---

## 💾 2. Storage Pool Management APIs

### Scan and List Storage Pools
* **Endpoint**: `GET /api/storage/pools`
* **Description**: Triggers physical LVM volume group and ZFS zpool scans via `vgs` and `zpool list` CLI wrappers on the host.
* **Response `200 OK`**:
```json
[
  {
    "name": "default-dir",
    "pool_type": "DIRECTORY",
    "mount_path": "/var/lib/libvirt/images",
    "capacity_gb": 500.0,
    "allocated_gb": 180.0,
    "free_gb": 320.0,
    "usage_percent": 36.0,
    "is_active": true
  },
  {
    "name": "vg_ankavm_fast",
    "pool_type": "LVM",
    "mount_path": "/dev/vg_ankavm_fast",
    "capacity_gb": 2000.0,
    "allocated_gb": 850.0,
    "free_gb": 1150.0,
    "usage_percent": 42.5,
    "is_active": true
  }
]
```

---

## 🌐 3. IPAM Logs & Address Pools

### Get IPAM Address Audit Logs
* **Endpoint**: `GET /api/ipam/logs`
* **Response `200 OK`**:
```json
[
  {
    "ip_address": "192.168.122.10",
    "action_type": "LEASE",
    "vm_name": "web-prod-01",
    "timestamp": "2026-06-22 17:55:29"
  },
  {
    "ip_address": "192.168.122.10",
    "action_type": "RELEASE",
    "vm_name": "web-prod-01",
    "timestamp": "2026-06-22 17:59:12"
  }
]
```

---

## 🔌 4. WiseCP Billing Integration Hooks

### Deploy Virtual Dedicated Server
* **Endpoint**: `POST /api/wisecp/deploy`
* **Request Body**:
```json
{
  "order_id": "wisecp-service-24152",
  "product_id": "product-vds-pro-01",
  "name": "vds-customer-node",
  "cpu": 4,
  "ram_mb": 8192,
  "disk_gb": 80,
  "disk_pool": "vg_ankavm_fast",
  "os_template": "ubuntu-22.04",
  "root_password": "CustomerSecurePass2026",
  "callback_url": "http://your-wisecp-domain.com/modules/Servers/AnkaVM/callback.php"
}
```
* **Response `202 Accepted`**:
```json
{
  "status": "PROVISIONING",
  "message": "VM deployment queued in background. Dispatching callback on completion."
}
```

---

## 📸 5. Snapshot & Backups

### Create VM Snapshot
* **Endpoint**: `POST /api/vms/{name}/snapshots`
* **Request Body**:
```json
{
  "snapshot_name": "snap_before_update",
  "description": "Pre-system-upgrade state"
}
```
* **Response `201 Created`**:
```json
{
  "status": "success",
  "message": "Snapshot 'snap_before_update' created for VM 'web-prod-01'."
}
```

---

## 📊 6. vnstat Traffic Monitoring

### Get VM Network Traffic Bandwidth
* **Endpoint**: `GET /api/vms/{name}/traffic`
* **Response `200 OK`**:
```json
{
  "vm_name": "web-prod-01",
  "rx_bytes_sec": 1245020,
  "tx_bytes_sec": 412582,
  "rx_packets_sec": 845,
  "tx_packets_sec": 302,
  "ddos_alert": false
}
```
