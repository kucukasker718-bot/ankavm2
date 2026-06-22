document.addEventListener('alpine:init', () => {
    const API_HEADERS = {
        'Content-Type': 'application/json',
        'X-API-Key': 'ankavm-secure-dev-token-2026'
    };

    const API_BASE = '/api';
    const WS_BASE = `${window.location.protocol === 'https:' ? 'wss' : 'ws'}://${window.location.host}`;

    Alpine.data('vmPanel', () => ({
        // Tab system
        activeTab: 'dashboard', // dashboard, vms, networks, ipam, storage, settings
        
        // Data States
        vms: [],
        networks: [],
        storagePools: [],
        activityLogs: [],
        ipPools: [],
        ipLeases: [],
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
        
        // Provisioning forms
        createForm: {
            name: '',
            cpu: 2,
            ram_mb: 2048,
            disk_gb: 40,
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

        // Charts
        hostCpuChart: null,
        hostRamChart: null,
        hostDiskChart: null,
        vmPerformanceChart: null,

        // Websockets console
        wsConsole: null,
        termInstance: null,

        async init() {
            console.log("Initializing Corporate Dashboard Controller with Automation...");
            
            // Initial data pull
            await Promise.all([
                this.fetchVms(),
                this.fetchHostStats(),
                this.fetchNetworks(),
                this.fetchStorage(),
                this.fetchLogs(),
                this.fetchIpamData()
            ]);
            
            this.loading = false;
            
            // Set up charts on next tick
            this.$nextTick(() => {
                this.initHostCharts();
            });

            // Set up timers for data sync
            setInterval(() => this.fetchHostStats(), 4000);
            setInterval(() => this.fetchVms(), 5000);
            setInterval(() => this.fetchActiveVmTelemetry(), 3000);
            setInterval(() => this.fetchLogs(), 6000);
            setInterval(() => {
                if (this.activeTab === 'networks') this.fetchNetworks();
                if (this.activeTab === 'storage') this.fetchStorage();
                if (this.activeTab === 'ipam') this.fetchIpamData();
            }, 8000);
        },

        // Tab selection change hook
        setTab(tabName) {
            this.activeTab = tabName;
            
            if (tabName === 'dashboard') {
                this.$nextTick(() => {
                    this.initHostCharts();
                    this.updateHostCharts();
                });
            }
            
            if (tabName === 'vms' && this.selectedVmName) {
                this.$nextTick(() => {
                    this.initVmPerformanceChart();
                });
            }
        },

        // --- Fetch actions ---

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

        async fetchStorage() {
            try {
                const res = await fetch(`${API_BASE}/storage`, { headers: API_HEADERS });
                if (res.ok) this.storagePools = await res.json();
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

        selectVm(name) {
            if (this.selectedVmName === name) {
                this.selectedVmName = null;
                this.selectedVmTelemetry = null;
                this.telemetryHistory = { cpu: [], ram: [], timestamps: [] };
                return;
            }
            this.selectedVmName = name;
            this.telemetryHistory = { cpu: [], ram: [], timestamps: [] };
            
            this.$nextTick(() => {
                this.initVmPerformanceChart();
                this.fetchActiveVmTelemetry();
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
                await Promise.all([this.fetchVms(), this.fetchLogs(), this.fetchIpamData()]);
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
                this.createForm = { name: '', cpu: 2, ram_mb: 2048, disk_gb: 40, os_template: 'ubuntu-22.04', root_password: 'AnkaVM-Secure-Root-2026', ssh_key: '' };
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
                await Promise.all([this.fetchVms(), this.fetchLogs(), this.fetchIpamData()]);
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
            // Simulated adding IP pool via networks post config
            this.showToast(`IP Havuzu ekleniyor: ${this.createPoolForm.name}`, 'info');
            this.showCreatePoolModal = false;
            
            // In mock configurations, we can define a virtual bridge to trigger VMManager network mapping
            const mockNet = {
                name: this.createPoolForm.name,
                bridge: 'virbr' + (this.networks.length + 1),
                ip: this.createPoolForm.gateway,
                dhcp_start: this.createPoolForm.dns_primary, // mapping parameters
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

            this.hostCpuChart = new Chart(cpuEl, chartConfig('#00f0ff'));
            this.hostRamChart = new Chart(ramEl, chartConfig('#ff007f'));
            this.hostDiskChart = new Chart(diskEl, chartConfig('#39ff14'));
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
                            label: 'CPU Core Usage (%)',
                            data: this.telemetryHistory.cpu,
                            borderColor: '#00f0ff',
                            backgroundColor: 'rgba(0, 240, 255, 0.05)',
                            fill: true,
                            tension: 0.4,
                            borderWidth: 2,
                            pointRadius: 1
                        },
                        {
                            label: 'Memory Load (%)',
                            data: this.telemetryHistory.ram,
                            borderColor: '#ff007f',
                            backgroundColor: 'rgba(255, 0, 127, 0.05)',
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
                            labels: { color: '#e2e8f0', font: { family: 'Orbitron', size: 10 } }
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

        // --- Xterm.js Terminal WebSocket Console ---

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
                    foreground: '#00f0ff',
                    cursor: '#00f0ff',
                    selectionBackground: 'rgba(0, 240, 255, 0.3)',
                    black: '#000000',
                    red: '#ff3838',
                    green: '#39ff14',
                    yellow: '#ffd700',
                    blue: '#00f0ff',
                    magenta: '#ff007f',
                    cyan: '#00f0ff',
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
