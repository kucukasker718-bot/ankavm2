<?php
/**
 * ==============================================================================
 * WiseCP Server Virtualization Integration Module - AnkaVM
 * ==============================================================================
 * 
 * This module allows WiseCP to automate KVM/Libvirt VDS provisioning, IPAM
 * allocation, and power cycles.
 * 
 * Path to upload: /cpanel/modules/Servers/AnkaVM/AnkaVM.php
 * ==============================================================================
 */

class AnkaVM {
    private $apiUrl;
    private $apiKey;

    public function __construct($apiUrl, $apiKey) {
        $this->apiUrl = rtrim($apiUrl, '/');
        $this->apiKey = $apiKey;
    }

    /**
     * Executes HTTP requests to AnkaVM API Gateway
     */
    private function call($endpoint, $method = 'GET', $data = null) {
        $ch = curl_init();
        $url = $this->apiUrl . '/' . ltrim($endpoint, '/');

        $headers = [
            'X-API-Key: ' . $this->apiKey,
            'Content-Type: application/json',
            'Accept: application/json'
        ];

        curl_setopt($ch, CURLOPT_URL, $url);
        curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
        curl_setopt($ch, CURLOPT_TIMEOUT, 30);
        curl_setopt($ch, CURLOPT_HTTPHEADER, $headers);
        curl_setopt($ch, CURLOPT_CUSTOMREQUEST, $method);

        if ($data) {
            curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($data));
        }

        // Disable SSL verification for local KVM hosts
        curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, false);
        curl_setopt($ch, CURLOPT_SSL_VERIFYHOST, false);

        $response = curl_exec($ch);
        $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
        $error = curl_error($ch);
        curl_close($ch);

        if ($error) {
            return ['status' => 'error', 'message' => 'API Gateway Connection Error: ' . $error];
        }

        $decoded = json_decode($response, true);
        if ($httpCode >= 200 && $httpCode < 300) {
            return ['status' => 'success', 'data' => $decoded];
        } else {
            $msg = isset($decoded['detail']) ? $decoded['detail'] : 'HTTP API Error: ' . $httpCode;
            return ['status' => 'error', 'message' => $msg];
        }
    }

    // --- WiseCP Action Wrappers ---

    public function testConnection() {
        return $this->call('/api/host/stats');
    }

    public function createServer($vmName, $cpu, $ramMb, $diskGb, $osTemplate, $rootPassword, $sshKey = '') {
        $payload = [
            'name' => $vmName,
            'cpu' => (int)$cpu,
            'ram_mb' => (int)$ramMb,
            'disk_gb' => (int)$diskGb,
            'os_template' => $osTemplate,
            'root_password' => $rootPassword,
            'ssh_key' => $sshKey ? $sshKey : null
        ];
        return $this->call('/api/vms', 'POST', $payload);
    }

    public function suspendServer($vmName) {
        return $this->call("/api/vms/{$vmName}/action", 'POST', ['action' => 'stop']);
    }

    public function unsuspendServer($vmName) {
        return $this->call("/api/vms/{$vmName}/action", 'POST', ['action' => 'start']);
    }

    public function terminateServer($vmName) {
        return $this->call("/api/vms/{$vmName}", 'DELETE');
    }

    public function rebootServer($vmName) {
        return $this->call("/api/vms/{$vmName}/action", 'POST', ['action' => 'restart']);
    }

    public function getTelemetry($vmName) {
        return $this->call("/api/vms/{$vmName}/telemetry");
    }
}

// ==============================================================================
// WiseCP Standard Module Hook Callbacks
// ==============================================================================

/**
 * Returns configuration options for the admin panel module setup
 */
function AnkaVM_fields() {
    return [
        'api_url' => [
            'name' => 'API Gateway URL',
            'type' => 'text',
            'default' => 'http://127.0.0.1:8086',
            'description' => 'FastAPI background gateway address'
        ],
        'api_key' => [
            'name' => 'API Access Token',
            'type' => 'password',
            'default' => 'ankavm-secure-dev-token-2026',
            'description' => 'X-API-Key credentials parameter'
        ],
        'os_template' => [
            'name' => 'Default OS Template',
            'type' => 'select',
            'options' => [
                'ubuntu-22.04' => 'Ubuntu 22.04 LTS (Jammy Jellyfish)',
                'debian-12' => 'Debian 12 Bookworm',
                'rockylinux-9' => 'Rocky Linux 9'
            ],
            'description' => 'Default OS distributions backing chain image'
        ]
    ];
}

/**
 * Audit credentials connection to hypervisor API
 */
function AnkaVM_test_connection($params) {
    $connector = new AnkaVM($params['api_url'], $params['api_key']);
    $result = $connector->testConnection();
    
    if ($result['status'] === 'success') {
        return ['status' => 'success', 'message' => 'Connection to AnkaVM Hypervisor successfully verified.'];
    } else {
        return ['status' => 'error', 'message' => 'Connection Failed: ' . $result['message']];
    }
}

/**
 * provision VM from WiseCP order
 */
function AnkaVM_create($params) {
    $connector = new AnkaVM($params['api_url'], $params['api_key']);
    
    $vmName = $params['options']['server_name'];
    $cpu = $params['options']['cpu_cores'];
    $ram = $params['options']['ram_mb'];
    $disk = $params['options']['disk_gb'];
    $template = isset($params['options']['os_template']) ? $params['options']['os_template'] : $params['os_template'];
    $rootPass = $params['options']['root_password'];
    $sshKey = isset($params['options']['ssh_key']) ? $params['options']['ssh_key'] : '';

    $result = $connector->createServer($vmName, $cpu, $ram, $disk, $template, $rootPass, $sshKey);

    if ($result['status'] === 'success') {
        return [
            'status' => 'success',
            'message' => 'VDS provisioned successfully with Cloud-init static IP and password.',
            'assigned_ip' => $result['data']['ip_address']
        ];
    } else {
        return [
            'status' => 'error',
            'message' => 'Creation Failed: ' . $result['message']
        ];
    }
}

/**
 * Suspend VM
 */
function AnkaVM_suspend($params) {
    $connector = new AnkaVM($params['api_url'], $params['api_key']);
    $vmName = $params['options']['server_name'];
    
    $result = $connector->suspendServer($vmName);
    return $result['status'] === 'success' 
        ? ['status' => 'success', 'message' => 'VDS Suspended successfully.'] 
        : ['status' => 'error', 'message' => $result['message']];
}

/**
 * Unsuspend VM
 */
function AnkaVM_unsuspend($params) {
    $connector = new AnkaVM($params['api_url'], $params['api_key']);
    $vmName = $params['options']['server_name'];
    
    $result = $connector->unsuspendServer($vmName);
    return $result['status'] === 'success' 
        ? ['status' => 'success', 'message' => 'VDS Unsuspended successfully.'] 
        : ['status' => 'error', 'message' => $result['message']];
}

/**
 * Delete VM and wipe storage blocks
 */
function AnkaVM_terminate($params) {
    $connector = new AnkaVM($params['api_url'], $params['api_key']);
    $vmName = $params['options']['server_name'];
    
    $result = $connector->terminateServer($vmName);
    return $result['status'] === 'success' 
        ? ['status' => 'success', 'message' => 'VDS Terminated and disk volume purged.'] 
        : ['status' => 'error', 'message' => $result['message']];
}

/**
 * Reboot VM
 */
function AnkaVM_reboot($params) {
    $connector = new AnkaVM($params['api_url'], $params['api_key']);
    $vmName = $params['options']['server_name'];
    
    $result = $connector->rebootServer($vmName);
    return $result['status'] === 'success' 
        ? ['status' => 'success', 'message' => 'VDS Rebooted.'] 
        : ['status' => 'error', 'message' => $result['message']];
}
