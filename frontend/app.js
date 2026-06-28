document.addEventListener('alpine:init', () => {
    const API_HEADERS = {
        'Content-Type': 'application/json',
        'X-API-Key': 'ankavm-secure-dev-token-2026'
    };

    const API_BASE = '/api';
    const WS_BASE = `${window.location.protocol === 'https:' ? 'wss' : 'ws'}://${window.location.host}`;

    Alpine.data('vmPanel', () => ({
        // Tab system
        activeTab: 'dashboard', // dashboard, vms, networks, ipam, storage, settings, license
        
        // Data States
        vms: [],
        networks: [],
        storagePools: [],
        images: [],
        activityLogs: [],
        ipPools: [],
        ipLeases: [],
        ipamLogs: [],
        wiseCpOrders: [],
        selectedVmSnapshots: [],
        consoleTab: 'vnc', // 'vnc' or 'serial'
        vncConnected: false,
        vncBootState: 0, // 0: offline, 1: booting bios, 2: kernel load, 3: fully loaded shell
        
        licenseStatus: {
            is_licensed: false,
            owner_name: 'Sistem Yükleniyor...',
            allowed_ip: '',
            allowed_domain: '',
            expires_at: '',
            hardware_id: '',
            detail: ''
        },
        hostStats: {
            cpu_usage: 0,
            ram_total_gb: 0,
            ram_used_gb: 0,
            ram_free_gb: 0,
            ram_usage_percent: 0,
            disk_total_gb: 0,
            disk_used_gb: 0,
            disk_free_gb: 0,
            disk_usage_percent: 0,
            vms_running: 0,
            vms_total: 0
        },
        
        // VDS Inspector Details
        selectedVmName: null,
        selectedVmTelemetry: null,
        selectedVmTraffic: null,
        telemetryHistory: {
            cpu: [],
            ram: [],
            timestamps: []
        },
        
        // Filters & Sorting & Searches
        searchQuery: '',
        statusFilter: 'all',
        sortBy: 'name',
        sortDesc: false,
        loading: true,
        toasts: [],
        
        // Modal Overlays
        showCreateModal: false,
        showCreateNetModal: false,
        showCreatePoolModal: false,
        showConsoleModal: false,
        showWiseCpSimulateModal: false,
        licenseKeyInput: '',
        
        // VCenter State
        vcenterConfig: {
            host: '',
            username: '',
            password: '',
            is_active: false
        },
        vcenterDiscovery: [],
        
        // Modules & Cloud Images State
        cloudImages: [
            { name: 'Windows Server 2012 R2', url: 'http://iso.ankavm.net/win2012r2.iso', icon: 'fa-windows' },
            { name: 'Windows Server 2016', url: 'http://iso.ankavm.net/win2016.iso', icon: 'fa-windows' },
            { name: 'Windows Server 2019', url: 'http://iso.ankavm.net/win2019.iso', icon: 'fa-windows' },
            { name: 'Ubuntu 22.04 LTS Server', url: 'http://iso.ankavm.net/ubuntu2204.iso', icon: 'fa-linux' }
        ],
        
        systemModules: [
            { id: 'webconsole', name: 'Gelişmiş Web Console', desc: 'VCenter MKS protokolünü WebSockets üzerinden güvenli aktarır.', icon: 'fa-terminal', active: true },
            { id: 'autopass', name: 'Otomatik Şifre Yönetimi (WiseCP)', desc: 'VM kurulumu sonrası OS şifrelerini otomatik sıfırlar ve müşteriye gösterir.', icon: 'fa-key', active: true },
            { id: 'osselect', name: 'İşletim Sistemi Seçme (Auto)', desc: 'Müşterinin satın alım sırasında OS seçmesini ve otomatik kurulmasını sağlar.', icon: 'fa-compact-disc', active: true },
            { id: 'backup', name: 'Yedekleme & Snapshot Otomasyonu', desc: 'Sistemi zamanlanmış görevlerle tam yedekler.', icon: 'fa-clock-rotate-left', active: false },
            { id: 'vlan', name: 'Gelişmiş Ağ İzolasyonu (VLAN)', desc: 'Müşteriler arası trafiği Layer-2 bazında izole eder.', icon: 'fa-network-wired', active: false },
            { id: 'loadbalancer', name: 'Yük Dengeleyici (HA)', desc: 'Sunucular arası trafik yükünü dengeler.', icon: 'fa-scale-balanced', active: false },
            { id: 'ddos', name: 'DDoS Koruma & Firewall', desc: 'Gelişmiş paket analizi ile port bazlı saldırıları engeller.', icon: 'fa-shield-virus', active: false },
            { id: 'whmcs', name: 'WHMCS Tam Entegrasyon', desc: 'WHMCS ile çift yönlü tam otomasyon.', icon: 'fa-plug', active: false },
            { id: 'docker', name: 'Docker & Container Yönetimi', desc: 'LXC ve Docker container oluşturma motoru.', icon: 'fa-docker', active: false },
            { id: 'vgpu', name: 'GPU Passthrough & vGPU', desc: 'Sanal makinelere fiziksel ekran kartı ataması yapar.', icon: 'fa-microchip', active: false }
        ],
        
        // Provisioning forms
        createForm: {
            name: '',
            cpu: 2,
            ram_mb: 2048,
            disk_gb: 40,
            disk_pool: 'default-dir',
            os_template: 'ubuntu-22.04',
            root_password: 'AnkaVM-Secure-Root-2026',
            ssh_key: ''
        },
        createNetForm: {
            name: '',
            bridge: '',
            ip: '192.168.100.1',
            dhcp_start: '192.168.100.2',
            dhcp_end: '192.168.100.100'
        },
        createPoolForm: {
            name: '',
            cidr: '192.168.110.0/24',
            gateway: '192.168.110.1',
            dns_primary: '8.8.8.8',
            dns_secondary: '1.1.1.1'
        },
        snapshotForm: {
            name: '',
            description: 'Manuel Yedekleme'
        },
        wiseCpSimulateForm: {
            order_id: '',
            product_id: 'vds-custom-saas',
            name: 'ws-demo-vds',
            cpu: 2,
            ram_mb: 4096,
            disk_gb: 80,
            disk_pool: 'default-dir',
            os_template: 'ubuntu-22.04',
            root_password: 'WiseCPPassWord123!'
        },
 
        // Charts
        hostCpuChart: null,
        hostRamChart: null,
        hostDiskChart: null,
        vmPerformanceChart: null,
 
        // Websockets console
        wsConsole: null,
        termInstance: null,
        vncSimulationTimer: null,
        vncCanvasContent: '',
 
        async init() {
            console.log("Initializing Corporate SaaS Dashboard Controller with Watchdog & Licensing...");
            
            toggleSkeletonLoaders(true);
            
            // İlk olarak lisans durumunu kontrol et
            await this.fetchLicenseStatus();
            
            // Lisans yoksa veri çekmeyi ve interval'ları başlatma
            if (!this.licenseStatus.is_licensed) {
                this.loading = false;
                toggleSkeletonLoaders(false);
                return;
            }
            
            // Lisanslıysa tüm sistemi başlat
            await this.bootSystem();
        },

        async bootSystem() {
            toggleSkeletonLoaders(true);
            await Promise.all([
                this.fetchVms(),
                this.fetchHostStats(),
                this.fetchNetworks(),
                this.fetchStorage(),
                this.fetchLogs(),
                this.fetchIpamData(),
                this.fetchIpLogs(),
                this.fetchWiseCpOrders(),
                this.fetchVcenterConfig()
            ]);
            
            // If vcenter is active, fetch discovery
            if (this.vcenterConfig.is_active) {
                this.fetchVcenterDiscovery();
            }
            
            // Fetch images after vcenter is loaded
            await this.fetchImages();
            
            this.loading = false;
            toggleSkeletonLoaders(false);
            
            // Set up charts on next tick
            this.$nextTick(() => {
                this.initHostCharts();
                this.renderApexStorageCharts();
            });
 
            // Set up timers for data sync
            if(!this._intervalsStarted) {
                setInterval(() => this.fetchHostStats(), 4000);
                setInterval(() => this.fetchVms(), 5000);
                setInterval(() => this.fetchActiveVmTelemetry(), 3000);
                setInterval(() => this.fetchActiveVmTraffic(), 3000);
                setInterval(() => this.fetchLogs(), 6000);
                setInterval(() => this.fetchLicenseStatus(), 15000);
                setInterval(() => this.fetchWiseCpOrders(), 5000);
                setInterval(() => {
                    if (this.activeTab === 'networks') this.fetchNetworks();
                    if (this.activeTab === 'storage') this.fetchStorage();
                    if (this.activeTab === 'ipam') {
                        this.fetchIpamData();
                        this.fetchIpLogs();
                    }
                }, 8000);
                this._intervalsStarted = true;
            }
        },

        setTab(tabName) {
            this.activeTab = tabName;
            
            if (tabName === 'dashboard') {
                this.$nextTick(() => {
                    this.initHostCharts();
                    this.updateHostCharts();
                    this.renderApexStorageCharts();
                });
            }
            
            if (tabName === 'vms' && this.selectedVmName) {
                this.$nextTick(() => {
                    this.initVmPerformanceChart();
                });
            }
        },

        // --- Fetch actions ---

        async fetchLicenseStatus() {
            try {
                const res = await fetch(`${API_BASE}/license/status`);
                if (res.ok) {
                    this.licenseStatus = await res.json();
                }
            } catch (err) {
                console.error("License check fail", err);
            }
        },

        async updateLicense() {
            if (!this.licenseKeyInput) {
                this.showToast("Lütfen lisans anahtarınızı girin.", "warning");
                return;
            }
            this.showToast("Lisans anahtarı güncelleniyor...", "info");
            try {
                const res = await fetch(`${API_BASE}/license/update`, {
                    method: 'POST',
                    headers: API_HEADERS,
                    body: JSON.stringify({ license_key: this.licenseKeyInput })
                });
                const data = await res.json();
                if (res.ok) {
                    this.showToast(data.message, "success");
                    this.licenseKeyInput = '';
                    await this.fetchLicenseStatus();
                    if (this.licenseStatus.is_licensed) {
                        await this.bootSystem();
                    }
                } else {
                    throw new Error(data.detail);
                }
            } catch (err) {
                this.showToast(err.message, "error");
            }
        },

        async fetchVms() {
            try {
                const res = await fetch(`${API_BASE}/vms`, { headers: API_HEADERS });
                if (res.ok) this.vms = await res.json();
            } catch (err) {
                console.error("VMS fetch failure", err);
            }
        },

        async fetchHostStats() {
            try {
                const res = await fetch(`${API_BASE}/host/stats`, { headers: API_HEADERS });
                if (res.ok) {
                    this.hostStats = await res.json();
                    this.updateHostCharts();
                }
            } catch (err) {
                console.error("Host stats fetch failure", err);
            }
        },

        async fetchNetworks() {
            try {
                const res = await fetch(`${API_BASE}/networks`, { headers: API_HEADERS });
                if (res.ok) this.networks = await res.json();
            } catch (err) {
                console.error("Networks fetch failure", err);
            }
        },

        async fetchVcenterConfig() {
            try {
                const res = await fetch(`${API_BASE}/vcenter/config`, { headers: API_HEADERS });
                if (res.ok) {
                    const data = await res.json();
                    this.vcenterConfig.host = data.host;
                    this.vcenterConfig.username = data.username;
                    this.vcenterConfig.is_active = data.is_active;
                }
            } catch (err) {
                console.error("VCenter fetch failure", err);
            }
        },

        async saveVcenterConfig() {
            this.showToast("VCenter'a bağlanılıyor...", "info");
            try {
                const res = await fetch(`${API_BASE}/vcenter/config`, {
                    method: 'POST',
                    headers: API_HEADERS,
                    body: JSON.stringify({
                        host: this.vcenterConfig.host,
                        username: this.vcenterConfig.username,
                        password: this.vcenterConfig.password
                    })
                });
                const data = await res.json();
                if (res.ok) {
                    this.showToast(data.message, "success");
                    this.vcenterConfig.is_active = true;
                    this.vcenterConfig.password = ''; // clear for security
                    await this.fetchVcenterDiscovery();
                } else {
                    throw new Error(data.detail || "VCenter bağlantı hatası");
                }
            } catch (err) {
                this.showToast(err.message, "error");
            }
        },

        async fetchVcenterDiscovery() {
            try {
                const res = await fetch(`${API_BASE}/vcenter/discovery`, { headers: API_HEADERS });
                if (res.ok) {
                    this.vcenterDiscovery = await res.json();
                }
            } catch (err) {
                console.error("VCenter discovery fetch failure", err);
            }
        },

        async fetchStorage() {
            try {
                const res = await fetch(`${API_BASE}/storage/pools`, { headers: API_HEADERS });
                if (res.ok) {
                    this.storagePools = await res.json();
                    this.renderApexStorageCharts();
                }
            } catch (err) {
                console.error("Storage fetch failure", err);
            }
        },

        async fetchLogs() {
            try {
                const res = await fetch(`${API_BASE}/logs`, { headers: API_HEADERS });
                if (res.ok) this.activityLogs = await res.json();
            } catch (err) {
                console.error("Logs fetch failure", err);
            }
        },

        async fetchImages() {
            try {
                const res = await fetch(`${API_BASE}/images`, { headers: API_HEADERS });
                if (res.ok) this.images = await res.json();
            } catch (err) {
                console.error("Images fetch failure", err);
            }
        },

        async downloadCloudImage(name, url) {
            try {
                this.showToast(`Bulut indirici başlatılıyor: ${name}`, 'info');
                const response = await fetchHelper(`${API_BASE}/images/download`, {
                    method: 'POST',
                    headers: API_HEADERS,
                    body: JSON.stringify({ name: name, url: url })
                });
                if(response.error) throw new Error(response.error);
                this.showToast(`${name} başarıyla indirme kuyruğuna eklendi!`, 'success');
                this.fetchImages(); // Refresh local list
            } catch(e) {
                this.showToast(`İndirme başlatılamadı: ${e.message}`, 'error');
            }
        },

        async uploadImage(event) {
            const file = event.target.files[0];
            if (!file) return;

            this.showToast("İmaj yükleniyor, lütfen bekleyin...", "info");
            const formData = new FormData();
            formData.append("file", file);

            try {
                const res = await fetch(`${API_BASE}/images/upload`, {
                    method: 'POST',
                    headers: { 'X-API-Key': API_HEADERS['X-API-Key'] },
                    body: formData
                });
                const data = await res.json();
                if (res.ok) {
                    this.showToast(data.message, "success");
                    await this.fetchImages();
                } else {
                    throw new Error(data.detail);
                }
            } catch (err) {
                this.showToast(err.message, "error");
            } finally {
                event.target.value = ''; // Reset input
            }
        },

        async fetchIpamData() {
            try {
                const [poolsRes, leasesRes] = await Promise.all([
                    fetch(`${API_BASE}/ipam/pools`, { headers: API_HEADERS }),
                    fetch(`${API_BASE}/ipam/leases`, { headers: API_HEADERS })
                ]);
                
                if (poolsRes.ok) this.ipPools = await poolsRes.json();
                if (leasesRes.ok) this.ipLeases = await leasesRes.json();
            } catch (err) {
                console.error("IPAM fetch failure", err);
            }
        },

        async fetchIpLogs() {
            try {
                const res = await fetch(`${API_BASE}/ipam/logs`, { headers: API_HEADERS });
                if (res.ok) this.ipamLogs = await res.json();
            } catch (err) {
                console.error("IPAM logs fetch failure", err);
            }
        },

        // --- VM actions ---

        async fetchActiveVmTelemetry() {
            if (!this.selectedVmName || this.activeTab !== 'vms') return;
            
            const activeVm = this.vms.find(v => v.name === this.selectedVmName);
            if (!activeVm || activeVm.status !== 'running') {
                this.selectedVmTelemetry = null;
                return;
            }

            try {
                const res = await fetch(`${API_BASE}/vms/${this.selectedVmName}/telemetry`, { headers: API_HEADERS });
                if (res.ok) {
                    const tel = await res.json();
                    this.selectedVmTelemetry = tel;
                    
                    const now = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
                    this.telemetryHistory.timestamps.push(now);
                    this.telemetryHistory.cpu.push(tel.cpu_usage_percent);
                    this.telemetryHistory.ram.push(tel.ram_usage_percent);

                    if (this.telemetryHistory.timestamps.length > 12) {
                        this.telemetryHistory.timestamps.shift();
                        this.telemetryHistory.cpu.shift();
                        this.telemetryHistory.ram.shift();
                    }

                    this.updateVmPerformanceChart();
                }
            } catch (err) {
                console.error("VM telemetry fetch failure", err);
            }
        },

        async fetchActiveVmTraffic() {
            if (!this.selectedVmName || this.activeTab !== 'vms') return;
            const activeVm = this.vms.find(v => v.name === this.selectedVmName);
            if (!activeVm || activeVm.status !== 'running') {
                this.selectedVmTraffic = null;
                return;
            }
            try {
                const res = await fetch(`${API_BASE}/vms/${this.selectedVmName}/traffic`, { headers: API_HEADERS });
                if (res.ok) {
                    const traffic = await res.json();
                    this.selectedVmTraffic = traffic;
                    if (traffic.ddos_alert) {
                        this.showToast(`🚨 UYARI: ${this.selectedVmName} sanal sunucusunda yüksek trafik (DDoS olasılığı) tespit edildi!`, 'warning');
                    }
                }
            } catch (err) {
                console.error("VM traffic metrics load failure", err);
            }
        },

        selectVm(name) {
            if (this.selectedVmName === name) {
                this.selectedVmName = null;
                this.selectedVmTelemetry = null;
                this.selectedVmTraffic = null;
                this.selectedVmSnapshots = [];
                this.telemetryHistory = { cpu: [], ram: [], timestamps: [] };
                return;
            }
            this.selectedVmName = name;
            this.selectedVmSnapshots = [];
            this.telemetryHistory = { cpu: [], ram: [], timestamps: [] };
            
            this.$nextTick(() => {
                this.initVmPerformanceChart();
                this.fetchActiveVmTelemetry();
                this.fetchActiveVmTraffic();
                this.fetchVmSnapshots(name);
            });
        },

        async triggerAction(name, action) {
            this.showToast(`Eylem gönderiliyor: ${action} -> ${name}`, 'info');
            try {
                const res = await fetch(`${API_BASE}/vms/${name}/action`, {
                    method: 'POST',
                    headers: API_HEADERS,
                    body: JSON.stringify({ action })
                });
                const data = await res.json();
                if (!res.ok) throw new Error(data.detail || "İşlem başarısız.");
                
                this.showToast(data.message, 'success');
                await Promise.all([this.fetchVms(), this.fetchLogs()]);
            } catch (err) {
                this.showToast(err.message, 'error');
            }
        },

        async provisionVm() {
            this.showToast(`Yeni VDS kuruluyor: ${this.createForm.name}`, 'info');
            this.showCreateModal = false;
            try {
                const res = await fetch(`${API_BASE}/vms`, {
                    method: 'POST',
                    headers: API_HEADERS,
                    body: JSON.stringify(this.createForm)
                });
                const data = await res.json();
                if (!res.ok) throw new Error(data.detail || "Kurulum başarısız.");
                
                this.showToast(`VDS '${data.name}' başarıyla oluşturuldu ve başlatıldı.`, 'success');
                this.createForm = { name: '', cpu: 2, ram_mb: 2048, disk_gb: 40, disk_pool: 'default-dir', os_template: 'ubuntu-22.04', root_password: 'AnkaVM-Secure-Root-2026', ssh_key: '' };
                await Promise.all([this.fetchVms(), this.fetchLogs(), this.fetchIpamData()]);
            } catch (err) {
                this.showToast(err.message, 'error');
            }
        },

        async deleteVm(name) {
            if (!confirm(`DİKKAT: '${name}' sunucusunu tamamen silmek istediğinize emin misiniz?\nBu işlem disk imajını ve tüm verileri kalıcı olarak yok edecektir.`)) {
                return;
            }
            this.showToast(`Sunucu siliniyor: ${name}`, 'warning');
            try {
                const res = await fetch(`${API_BASE}/vms/${name}`, {
                    method: 'DELETE',
                    headers: API_HEADERS
                });
                const data = await res.json();
                if (!res.ok) throw new Error(data.detail || "Silme işlemi başarısız.");
                
                this.showToast(data.message, 'success');
                if (this.selectedVmName === name) this.selectedVmName = null;
                await Promise.all([this.fetchVms(), this.fetchLogs(), this.fetchIpamData(), this.fetchIpLogs()]);
            } catch (err) {
                this.showToast(err.message, 'error');
            }
        },

        // --- Network & IPAM Actions ---

        async provisionNetwork() {
            this.showToast(`Sanal ağ tanımlanıyor: ${this.createNetForm.name}`, 'info');
            this.showCreateNetModal = false;
            try {
                const res = await fetch(`${API_BASE}/networks`, {
                    method: 'POST',
                    headers: API_HEADERS,
                    body: JSON.stringify(this.createNetForm)
                });
                const data = await res.json();
                if (!res.ok) throw new Error(data.detail || "Sanal ağ kurulumu başarısız.");
                
                this.showToast(`Ağ '${this.createNetForm.name}' başarıyla oluşturuldu.`, 'success');
                this.createNetForm = { name: '', bridge: '', ip: '192.168.100.1', dhcp_start: '192.168.100.2', dhcp_end: '192.168.100.100' };
                await Promise.all([this.fetchNetworks(), this.fetchLogs(), this.fetchIpamData()]);
            } catch (err) {
                this.showToast(err.message, 'error');
            }
        },

        async provisionIpPool() {
            this.showToast(`IP Havuzu ekleniyor: ${this.createPoolForm.name}`, 'info');
            this.showCreatePoolModal = false;
            
            const mockNet = {
                name: this.createPoolForm.name,
                bridge: 'virbr' + (this.networks.length + 1),
                ip: this.createPoolForm.gateway,
                dhcp_start: this.createPoolForm.dns_primary,
                dhcp_end: this.createPoolForm.dns_secondary
            };
            
            try {
                const res = await fetch(`${API_BASE}/networks`, {
                    method: 'POST',
                    headers: API_HEADERS,
                    body: JSON.stringify(mockNet)
                });
                if (res.ok) {
                    this.showToast(`IP Havuzu '${this.createPoolForm.name}' başarıyla tanımlandı.`, 'success');
                    this.createPoolForm = { name: '', cidr: '192.168.110.0/24', gateway: '192.168.110.1', dns_primary: '8.8.8.8', dns_secondary: '1.1.1.1' };
                    await Promise.all([this.fetchIpamData(), this.fetchLogs()]);
                }
            } catch (err) {
                this.showToast(err.message, 'error');
            }
        },

        // --- Render ApexCharts ---

        renderApexStorageCharts() {
            if (this.storagePools.length > 0) {
                const allocated = this.storagePools.map(p => parseFloat(p.allocated_gb));
                const free = this.storagePools.map(p => parseFloat(p.free_gb));
                const categories = this.storagePools.map(p => p.name);
                
                this.$nextTick(() => {
                    initStorageHealthChart('storagePoolApexChart', allocated, free, categories);
                });
            }
        },

        // --- Live Chart.js Visualizations ---
        
        initHostCharts() {
            const cpuEl = document.getElementById('cpuChartCanvas');
            const ramEl = document.getElementById('ramChartCanvas');
            const diskEl = document.getElementById('diskChartCanvas');

            if (!cpuEl || !ramEl || !diskEl) return;

            const chartConfig = (color) => ({
                type: 'doughnut',
                data: {
                    datasets: [{
                        data: [0, 100],
                        backgroundColor: [color, 'rgba(255, 255, 255, 0.05)'],
                        borderWidth: 0,
                        circumference: 270,
                        rotation: 225,
                        borderRadius: 10
                    }]
                },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    cutout: '80%',
                    plugins: {
                        legend: { display: false },
                        tooltip: { enabled: false }
                    }
                }
            });

            if (this.hostCpuChart) this.hostCpuChart.destroy();
            if (this.hostRamChart) this.hostRamChart.destroy();
            if (this.hostDiskChart) this.hostDiskChart.destroy();

            this.hostCpuChart = new Chart(cpuEl, chartConfig('#3b82f6'));
            this.hostRamChart = new Chart(ramEl, chartConfig('#10b981'));
            this.hostDiskChart = new Chart(diskEl, chartConfig('#ef4444'));
        },

        updateHostCharts() {
            if (!this.hostCpuChart || this.activeTab !== 'dashboard') return;
            
            this.hostCpuChart.data.datasets[0].data = [this.hostStats.cpu_usage, 100 - this.hostStats.cpu_usage];
            this.hostCpuChart.update('none');

            this.hostRamChart.data.datasets[0].data = [this.hostStats.ram_usage_percent, 100 - this.hostStats.ram_usage_percent];
            this.hostRamChart.update('none');

            this.hostDiskChart.data.datasets[0].data = [this.hostStats.disk_usage_percent, 100 - this.hostStats.disk_usage_percent];
            this.hostDiskChart.update('none');
        },

        initVmPerformanceChart() {
            const ctx = document.getElementById('vmPerformanceChartCanvas');
            if (!ctx) return;

            if (this.vmPerformanceChart) {
                this.vmPerformanceChart.destroy();
            }

            this.vmPerformanceChart = new Chart(ctx, {
                type: 'line',
                data: {
                    labels: this.telemetryHistory.timestamps,
                    datasets: [
                        {
                            label: 'CPU Kullanımı (%)',
                            data: this.telemetryHistory.cpu,
                            borderColor: '#3b82f6',
                            backgroundColor: 'rgba(59, 130, 246, 0.05)',
                            fill: true,
                            tension: 0.4,
                            borderWidth: 2,
                            pointRadius: 1
                        },
                        {
                            label: 'RAM Yükü (%)',
                            data: this.telemetryHistory.ram,
                            borderColor: '#10b981',
                            backgroundColor: 'rgba(16, 185, 129, 0.05)',
                            fill: true,
                            tension: 0.4,
                            borderWidth: 2,
                            pointRadius: 1
                        }
                    ]
                },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    scales: {
                        x: {
                            grid: { color: 'rgba(255, 255, 255, 0.04)' },
                            ticks: { color: '#8a9ab5', font: { size: 9 } }
                        },
                        y: {
                            min: 0,
                            max: 100,
                            grid: { color: 'rgba(255, 255, 255, 0.04)' },
                            ticks: { color: '#8a9ab5', font: { size: 9 } }
                        }
                    },
                    plugins: {
                        legend: {
                            labels: { color: '#e2e8f0', font: { size: 10 } }
                        }
                    }
                }
            });
        },

        updateVmPerformanceChart() {
            if (!this.vmPerformanceChart || this.activeTab !== 'vms') return;
            this.vmPerformanceChart.data.labels = this.telemetryHistory.timestamps;
            this.vmPerformanceChart.data.datasets[0].data = this.telemetryHistory.cpu;
            this.vmPerformanceChart.data.datasets[1].data = this.telemetryHistory.ram;
            this.vmPerformanceChart.update('none');
        },

        // --- Xterm.js Terminal Console ---

        openConsole(vmName) {
            this.showConsoleModal = true;
            this.$nextTick(() => {
                this.initTerminal(vmName);
            });
        },

        closeConsole() {
            this.showConsoleModal = false;
            if (this.wsConsole) {
                this.wsConsole.close();
                this.wsConsole = null;
            }
            if (this.termInstance) {
                this.termInstance.dispose();
                this.termInstance = null;
            }
            const container = document.getElementById('terminal-container');
            if (container) container.innerHTML = '';
        },

        initTerminal(vmName) {
            const terminalContainer = document.getElementById('terminal-container');
            if (!terminalContainer) return;

            terminalContainer.innerHTML = '';

            this.termInstance = new Terminal({
                theme: {
                    background: '#070a13',
                    foreground: '#3b82f6',
                    cursor: '#3b82f6',
                    selectionBackground: 'rgba(59, 130, 246, 0.3)',
                    black: '#000000',
                    red: '#ff3838',
                    green: '#10b981',
                    yellow: '#ffd700',
                    blue: '#3b82f6',
                    magenta: '#d946ef',
                    cyan: '#06b6d4',
                    white: '#ffffff'
                },
                cursorBlink: true,
                fontSize: 13,
                fontFamily: 'JetBrains Mono, monospace',
                rows: 22,
                cols: 80
            });

            this.termInstance.open(terminalContainer);
            this.termInstance.focus();

            const socketUrl = `${WS_BASE}/ws/vms/${vmName}/console`;
            this.wsConsole = new WebSocket(socketUrl);

            this.wsConsole.onmessage = (event) => {
                this.termInstance.write(event.data);
            };

            this.wsConsole.onclose = () => {
                this.termInstance.write("\r\n\r\n\x1b[31;1m[Konsol Bağlantısı Sonlandırıldı]\x1b[0m\r\n");
            };

            this.wsConsole.onerror = (err) => {
                this.termInstance.write("\r\n\r\n\x1b[31;1m[WebSocket Bağlantı Hatası! API'yi kontrol edin.]\x1b[0m\r\n");
            };

            this.termInstance.onData((data) => {
                if (this.wsConsole && this.wsConsole.readyState === WebSocket.OPEN) {
                    this.wsConsole.send(data);
                }
            });
        },

        // --- Data Tables Search & Sort ---

        get filteredVms() {
            return this.vms
                .filter(vm => {
                    const query = this.searchQuery.toLowerCase();
                    const nameMatch = vm.name.toLowerCase().includes(query);
                    const osMatch = vm.os_template.toLowerCase().includes(query);
                    const ipMatch = vm.ip_address && vm.ip_address.includes(query);
                    const searchMatch = nameMatch || osMatch || ipMatch;

                    let statusMatch = true;
                    if (this.statusFilter === 'running') {
                        statusMatch = vm.status === 'running';
                    } else if (this.statusFilter === 'offline') {
                        statusMatch = vm.status !== 'running';
                    }

                    return searchMatch && statusMatch;
                })
                .sort((a, b) => {
                    let fieldA = a[this.sortBy];
                    let fieldB = b[this.sortBy];

                    if (fieldA === undefined || fieldA === null) fieldA = '';
                    if (fieldB === undefined || fieldB === null) fieldB = '';

                    if (typeof fieldA === 'string') {
                        fieldA = fieldA.toLowerCase();
                        fieldB = fieldB.toLowerCase();
                    }

                    let comparison = 0;
                    if (fieldA < fieldB) comparison = -1;
                    if (fieldA > fieldB) comparison = 1;

                    return this.sortDesc ? comparison * -1 : comparison;
                });
        },

        setSort(field) {
            if (this.sortBy === field) {
                this.sortDesc = !this.sortDesc;
            } else {
                this.sortBy = field;
                this.sortDesc = false;
            }
        },

        // --- WiseCP & Snapshots & VNC Console Operations ---

        async fetchWiseCpOrders() {
            try {
                const res = await fetch(`${API_BASE}/wisecp/orders`, { headers: API_HEADERS });
                if (res.ok) this.wiseCpOrders = await res.json();
            } catch (err) {
                console.error("WiseCP orders fetch failure", err);
            }
        },

        async fetchVmSnapshots(vmName) {
            if (!vmName) return;
            try {
                const res = await fetch(`${API_BASE}/vms/${vmName}/snapshots`, { headers: API_HEADERS });
                if (res.ok) {
                    this.selectedVmSnapshots = await res.json();
                }
            } catch (err) {
                console.error("Snapshots fetch failure", err);
            }
        },

        async createSnapshot() {
            if (!this.selectedVmName) return;
            if (!this.snapshotForm.name) {
                this.showToast("Lütfen bir snapshot adı girin.", "warning");
                return;
            }
            this.showToast(`Snapshot alınıyor: ${this.snapshotForm.name}`, "info");
            try {
                const res = await fetch(`${API_BASE}/vms/${this.selectedVmName}/snapshots`, {
                    method: 'POST',
                    headers: API_HEADERS,
                    body: JSON.stringify({
                        snapshot_name: this.snapshotForm.name,
                        description: this.snapshotForm.description
                    })
                });
                const data = await res.json();
                if (res.ok) {
                    this.showToast(data.message, "success");
                    this.snapshotForm.name = '';
                    await this.fetchVmSnapshots(this.selectedVmName);
                } else {
                    throw new Error(data.detail);
                }
            } catch (err) {
                this.showToast(err.message, "error");
            }
        },

        async revertSnapshot(snapName) {
            if (!this.selectedVmName || !snapName) return;
            if (!confirm(`DİKKAT: Sunucuyu '${snapName}' anlık görüntüsüne geri döndürmek istediğinizden emin misiniz?\nGeçerli tüm kaydedilmemiş veriler kaybolacaktır.`)) {
                return;
            }
            this.showToast(`Snapshot geri yükleniyor: ${snapName}`, "info");
            try {
                const res = await fetch(`${API_BASE}/vms/${this.selectedVmName}/snapshots/revert`, {
                    method: 'POST',
                    headers: API_HEADERS,
                    body: JSON.stringify({ snapshot_name: snapName })
                });
                const data = await res.json();
                if (res.ok) {
                    this.showToast(data.message, "success");
                    await this.fetchVms();
                } else {
                    throw new Error(data.detail);
                }
            } catch (err) {
                this.showToast(err.message, "error");
            }
        },

        async simulateWiseCpOrder() {
            this.showToast("WiseCP Sipariş talebi gönderiliyor...", "info");
            this.showWiseCpSimulateModal = false;
            
            // Auto generate an order_id if empty
            if (!this.wiseCpSimulateForm.order_id) {
                this.wiseCpSimulateForm.order_id = 'ws-order-' + Math.floor(1000 + Math.random() * 9000);
            }
            
            try {
                const res = await fetch(`${API_BASE}/wisecp/deploy`, {
                    method: 'POST',
                    headers: API_HEADERS,
                    body: JSON.stringify(this.wiseCpSimulateForm)
                });
                const data = await res.json();
                if (res.ok) {
                    this.showToast("Sipariş WiseCP API kuyruğuna alındı ve arka planda kurulum başladı!", "success");
                    this.wiseCpSimulateForm.order_id = '';
                    await this.fetchWiseCpOrders();
                } else {
                    throw new Error(data.detail);
                }
            } catch (err) {
                this.showToast(err.message, "error");
            }
        },

        // VNC Simulation Console helper
        startVncSimulation(vmName) {
            if (this.vncSimulationTimer) clearInterval(this.vncSimulationTimer);
            this.vncBootState = 1;
            this.vncConnected = false;
            this.vncCanvasContent = "Bağlanıyor...";
            
            setTimeout(() => {
                this.vncConnected = true;
                this.vncBootState = 1;
                this.vncCanvasContent = `AnkaVM Virtual VNC v1.5\r\nBIOS v1.5 Initializing...\r\nCPU: AMD EPYC Core / Intel Xeon @ 2.20GHz\r\nRAM: 4096 MB OK\r\nHard Disk: /dev/vda (QCOW2 Block Store)\r\nBooting Linux image...`;
            }, 1000);

            this.vncSimulationTimer = setInterval(() => {
                if (this.vncBootState === 1) {
                    this.vncBootState = 2;
                    this.vncCanvasContent = `[    0.000000] Booting Linux kernel on physical CPU 0x0\r\n[    0.000000] Linux version 5.15.0-88-generic\r\n[    0.052021] CPU0: Intel(R) Xeon(R) Gold\r\n[    1.218903] ACPI: Core revision 20210604\r\n[    2.148102] ext4-fs (vda): mounted filesystem with ordered data mode.\r\n[    3.029810] systemd[1]: Started Journal Service.\r\n[    3.901021] systemd[1]: Started AnkaVM Guest Telemetry Agent.\r\n[    4.208102] systemd[1]: Reached target Multi-User System.`;
                } else if (this.vncBootState === 2) {
                    this.vncBootState = 3;
                    const activeVm = this.vms.find(v => v.name === vmName);
                    const ip = activeVm ? activeVm.ip_address : '192.168.122.100';
                    const ram = activeVm ? activeVm.ram_mb : 2048;
                    const cpu = activeVm ? activeVm.cpu : 2;
                    this.vncCanvasContent = `Ubuntu 22.04 LTS ${vmName} tty1\r\n\r\n${vmName} login: root\r\nPassword: \r\nLast login: Mon Jun 22 21:20:56 2026 on tty1\r\n\r\nWelcome to Ubuntu 22.04 LTS (GNU/Linux 5.15.0-88-generic x86_64)\r\n\r\nSystem information:\r\n  System load:  0.08              Processes:             98\r\n  Usage of /:   12.4% of 38.21GB  Memory usage:          12%\r\n  VDS IP Address:                 ${ip}\r\n  VDS Core Config:                ${cpu} Cores / ${ram} MB RAM\r\n\r\n* AnkaVM hypervisor guest agents operational.\r\n* VNC graphics desktop display is active.\r\n\r\nroot@${vmName}:~# _`;
                    clearInterval(this.vncSimulationTimer);
                }
            }, 2500);
        },

        sendCtrlAltDel(vmName) {
            this.showToast("Ctrl+Alt+Del sinyali gönderildi. Sunucu yeniden başlatılıyor...", "info");
            this.startVncSimulation(vmName);
        },

        // --- Toast Management ---
        
        showToast(message, type = 'info') {
            const id = Date.now() + Math.random();
            this.toasts.push({ id, message, type });
            
            setTimeout(() => {
                this.toasts = this.toasts.filter(t => t.id !== id);
            }, 4000);
        },

        removeToast(id) {
            this.toasts = this.toasts.filter(t => t.id !== id);
        }
    }));
});
