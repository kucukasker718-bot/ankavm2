-- ==============================================================================
-- AnkaVM Production Database Schema - PostgreSQL Definition
-- ==============================================================================

-- 1. Users Table (System Administrators and API Accounts)
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    username VARCHAR(50) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 2. Licensing Table (Hardware-locked License Key System)
CREATE TABLE license_records (
    id SERIAL PRIMARY KEY,
    license_key VARCHAR(64) UNIQUE NOT NULL,      -- SHA-256 hash of license key
    owner_name VARCHAR(100) NOT NULL,
    hardware_id VARCHAR(64) NOT NULL,            -- Locked to host motherboard UUID / CPU ID
    allowed_ip VARCHAR(45) NOT NULL,             -- Locked to primary public IP
    allowed_domain VARCHAR(100) NOT NULL,         -- Locked to dashboard domain
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    is_active BOOLEAN DEFAULT TRUE,
    last_verified_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 3. Storage Pools Table (LVM VGs, ZFS Pools, and Directory Paths)
CREATE TABLE storage_pools (
    id SERIAL PRIMARY KEY,
    name VARCHAR(50) UNIQUE NOT NULL,            -- e.g. 'vg_ankavm_fast', 'zpool_hybrid'
    pool_type VARCHAR(20) NOT NULL,             -- 'LVM', 'ZFS', 'DIRECTORY'
    mount_path VARCHAR(255) NOT NULL,            -- e.g. '/dev/vg0', '/var/lib/libvirt/images'
    capacity_gb NUMERIC(10, 2) NOT NULL,
    allocated_gb NUMERIC(10, 2) NOT NULL,
    free_gb NUMERIC(10, 2) NOT NULL,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 4. IP Pools Table (CIDR Blocks defining network ranges)
CREATE TABLE ip_pools (
    id SERIAL PRIMARY KEY,
    name VARCHAR(50) UNIQUE NOT NULL,
    cidr VARCHAR(45) NOT NULL,                  -- Supports IPv4/IPv6 CIDRs
    gateway VARCHAR(45) NOT NULL,               -- Gateway IP address
    dns_primary VARCHAR(45) DEFAULT '8.8.8.8',
    dns_secondary VARCHAR(45) DEFAULT '1.1.1.1',
    vlan_id INTEGER,                            -- Optional VLAN tag for network isolation
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 5. Operating System Templates Table (Cloud-init enabled QCOW2 master templates)
CREATE TABLE os_templates (
    id SERIAL PRIMARY KEY,
    name VARCHAR(50) UNIQUE NOT NULL,            -- e.g. 'ubuntu-24.04', 'debian-12'
    display_name VARCHAR(100) NOT NULL,          -- e.g. 'Ubuntu 24.04 LTS (Noble Numbat)'
    image_path VARCHAR(255) NOT NULL,            -- Backing template path
    default_user VARCHAR(50) DEFAULT 'root',
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 6. Virtual Dedicated Servers (VMs) Table
CREATE TABLE virtual_servers (
    id SERIAL PRIMARY KEY,
    name VARCHAR(30) UNIQUE NOT NULL,            -- Matches KVM domain name
    owner_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
    cpu_cores INTEGER NOT NULL DEFAULT 1,
    ram_mb INTEGER NOT NULL DEFAULT 1024,
    disk_gb INTEGER NOT NULL DEFAULT 20,
    disk_pool_id INTEGER REFERENCES storage_pools(id) ON DELETE RESTRICT,
    os_template_id INTEGER REFERENCES os_templates(id) ON DELETE RESTRICT,
    status VARCHAR(20) DEFAULT 'SHUT_OFF',        -- RUNNING, SHUT_OFF, PAUSED, RESCUE
    vnc_port INTEGER,                            -- Allocated VNC graphics port
    mac_address VARCHAR(17) UNIQUE,              -- Interface hardware address
    rescue_iso_path VARCHAR(255),                 -- Set if VM booted in Rescue Mode
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 7. IP Addresses Table (Individual leases inside pools linked to VMs)
CREATE TABLE ip_addresses (
    id SERIAL PRIMARY KEY,
    pool_id INTEGER REFERENCES ip_pools(id) ON DELETE CASCADE,
    ip_address VARCHAR(45) UNIQUE NOT NULL,
    status VARCHAR(20) DEFAULT 'FREE',          -- FREE, ALLOCATED, RESERVED
    allocated_to_vm_id INTEGER REFERENCES virtual_servers(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_ip_status CHECK (status IN ('FREE', 'ALLOCATED', 'RESERVED'))
);

-- 8. IP Logs Table (Audit trail for IP leases and releases)
CREATE TABLE ip_logs (
    id SERIAL PRIMARY KEY,
    ip_address VARCHAR(45) NOT NULL,
    action_type VARCHAR(20) NOT NULL,            -- 'LEASE', 'RELEASE', 'BLOCK'
    vm_name VARCHAR(50) NOT NULL,
    user_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
    timestamp TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 9. VDS Snapshots Table (Backing chain snapshot records)
CREATE TABLE snapshots (
    id SERIAL PRIMARY KEY,
    vm_id INTEGER REFERENCES virtual_servers(id) ON DELETE CASCADE,
    snapshot_name VARCHAR(50) NOT NULL,
    description TEXT,
    is_active_state BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 10. DDoS & Traffic Monitor Metrics Table (vnstat traffic logger)
CREATE TABLE traffic_metrics (
    id SERIAL PRIMARY KEY,
    vm_id INTEGER REFERENCES virtual_servers(id) ON DELETE CASCADE,
    rx_bytes_sec BIGINT DEFAULT 0,
    tx_bytes_sec BIGINT DEFAULT 0,
    rx_packets_sec INTEGER DEFAULT 0,
    tx_packets_sec INTEGER DEFAULT 0,
    ddos_alert_triggered BOOLEAN DEFAULT FALSE,
    threshold_limit_kbps INTEGER DEFAULT 100000, -- 100 Mbps warning line
    recorded_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 11. WiseCP Orders Table (WiseCP / WHMCS remote billing queue)
CREATE TABLE wisecp_orders (
    id SERIAL PRIMARY KEY,
    order_id VARCHAR(50) UNIQUE NOT NULL,          -- WiseCP order reference ID
    product_id VARCHAR(50) NOT NULL,
    cpu_cores INTEGER NOT NULL,
    ram_mb INTEGER NOT NULL,
    disk_gb INTEGER NOT NULL,
    ip_address VARCHAR(45),
    root_password VARCHAR(255) NOT NULL,
    status VARCHAR(30) DEFAULT 'PENDING',          -- PENDING, PROVISIONING, COMPLETED, FAILED
    callback_url TEXT,
    callback_status VARCHAR(20),                   -- SUCCESS, FAILED
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    completed_at TIMESTAMP WITH TIME ZONE
);

-- 12. Audit System Log Table
CREATE TABLE audit_logs (
    id SERIAL PRIMARY KEY,
    timestamp TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    user_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
    event_level VARCHAR(10) NOT NULL,            -- INFO, SUCCESS, WARNING, ERROR
    action VARCHAR(50) NOT NULL,                 -- e.g. 'VM_CREATE', 'IP_ALLOCATE'
    message TEXT NOT NULL
);

-- ==============================================================================
-- Database Indexes for high performance querying
-- ==============================================================================
CREATE INDEX idx_ip_status ON ip_addresses(status);
CREATE INDEX idx_ip_pool ON ip_addresses(pool_id);
CREATE INDEX idx_vm_owner ON virtual_servers(owner_id);
CREATE INDEX idx_storage_pool_type ON storage_pools(pool_type);
CREATE INDEX idx_license_key ON license_records(license_key);
CREATE INDEX idx_ip_log_ip ON ip_logs(ip_address);
CREATE INDEX idx_snapshots_vm ON snapshots(vm_id);
CREATE INDEX idx_traffic_vm ON traffic_metrics(recorded_at, vm_id);
CREATE INDEX idx_wisecp_order ON wisecp_orders(order_id);
CREATE INDEX idx_audit_timestamp ON audit_logs(timestamp);
