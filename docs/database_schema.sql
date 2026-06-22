-- ==============================================================================
-- AnkaVM Automation Database Schema - PostgreSQL Definition
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

-- 2. IP Pools Table (CIDR blocks defining network ranges)
CREATE TABLE ip_pools (
    id SERIAL PRIMARY KEY,
    name VARCHAR(50) UNIQUE NOT NULL,
    cidr VARCHAR(45) NOT NULL,           -- Supports IPv4 or IPv6 CIDRs (e.g. 192.168.10.0/24)
    gateway VARCHAR(45) NOT NULL,        -- Gateway IP address
    dns_primary VARCHAR(45) DEFAULT '8.8.8.8',
    dns_secondary VARCHAR(45) DEFAULT '1.1.1.1',
    vlan_id INTEGER,                     -- Optional VLAN tag for network isolation
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 3. IP Addresses Table (Individual leases inside pools)
CREATE TABLE ip_addresses (
    id SERIAL PRIMARY KEY,
    pool_id INTEGER REFERENCES ip_pools(id) ON DELETE CASCADE,
    ip_address VARCHAR(45) UNIQUE NOT NULL,
    status VARCHAR(20) DEFAULT 'FREE',   -- FREE, ALLOCATED, RESERVED
    allocated_to_vm_id INTEGER,          -- Set dynamically on VM allocation (circular ref handled via NULL)
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_ip_status CHECK (status IN ('FREE', 'ALLOCATED', 'RESERVED'))
);

-- 4. Operating System Templates Table (Cloud-init enabled QCOW2 master templates)
CREATE TABLE os_templates (
    id SERIAL PRIMARY KEY,
    name VARCHAR(50) UNIQUE NOT NULL,     -- e.g. 'ubuntu-24.04', 'debian-12'
    display_name VARCHAR(100) NOT NULL,   -- e.g. 'Ubuntu 24.04 LTS (Noble Numbat)'
    image_path VARCHAR(255) NOT NULL,     -- Full path to backing template: /var/lib/libvirt/images/templates/ubuntu-24.qcow2
    default_user VARCHAR(50) DEFAULT 'root',
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 5. Virtual Dedicated Servers (VMs) Table
CREATE TABLE virtual_servers (
    id SERIAL PRIMARY KEY,
    name VARCHAR(30) UNIQUE NOT NULL,     -- Matches KVM domain name
    owner_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
    cpu_cores INTEGER NOT NULL DEFAULT 1,
    ram_mb INTEGER NOT NULL DEFAULT 1024,
    disk_gb INTEGER NOT NULL DEFAULT 20,
    os_template_id INTEGER REFERENCES os_templates(id) ON DELETE RESTRICT,
    status VARCHAR(20) DEFAULT 'SHUT_OFF', -- RUNNING, SHUT_OFF, SUSPENDED, PAUSED
    vnc_port INTEGER,                     -- Port for remote graphics access (e.g. 5900)
    mac_address VARCHAR(17) UNIQUE,       -- Virtual interface hardware address
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Establish foreign key linking IP leases back to VM instances safely
ALTER TABLE ip_addresses 
ADD CONSTRAINT fk_allocated_vm 
FOREIGN KEY (allocated_to_vm_id) 
REFERENCES virtual_servers(id) ON DELETE SET NULL;

-- 6. API Access Keys Table (For integration with WHMCS / WiseCP)
CREATE TABLE api_keys (
    id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
    key_value VARCHAR(255) UNIQUE NOT NULL,
    description VARCHAR(100),
    is_active BOOLEAN DEFAULT TRUE,
    rate_limit_rpm INTEGER DEFAULT 60,   -- Rate limiting requests per minute
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP WITH TIME ZONE
);

-- 7. Audit System Log Table
CREATE TABLE audit_logs (
    id SERIAL PRIMARY KEY,
    timestamp TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    user_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
    event_level VARCHAR(10) NOT NULL,    -- INFO, SUCCESS, WARNING, ERROR
    action VARCHAR(50) NOT NULL,         -- e.g. 'VM_CREATE', 'IP_ALLOCATE'
    message TEXT NOT NULL
);

-- ==============================================================================
-- Database Indexes for high performance querying
-- ==============================================================================
CREATE INDEX idx_ip_status ON ip_addresses(status);
CREATE INDEX idx_ip_pool ON ip_addresses(pool_id);
CREATE INDEX idx_vm_owner ON virtual_servers(owner_id);
CREATE INDEX idx_audit_timestamp ON audit_logs(timestamp);
