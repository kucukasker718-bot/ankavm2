// AnkaVM Dashboard Client Fetch Helper Modules

const API_HEADERS = {
    'Content-Type': 'application/json',
    'X-API-Key': 'ankavm-secure-dev-token-2026'
};

async function fetchHelper(url, options = {}) {
    const response = await fetch(url, options);
    const contentType = response.headers.get('content-type') || '';
    let data = null;

    if (contentType.includes('application/json')) {
        data = await response.json();
    } else {
        data = await response.text();
    }

    if (!response.ok) {
        const errorMessage = typeof data === 'object'
            ? (data.detail || data.message || data.error || 'İstek başarısız oldu.')
            : (data || 'İstek başarısız oldu.');
        throw new Error(errorMessage);
    }

    return data;
}

/**
 * Renders the color-coded Proxmox-style disk progress bar based on percentage capacity.
 * Red indicator starts above 90% load.
 */
function renderProxmoxProgressBar(usedGb, totalGb) {
    const pct = totalGb > 0 ? Math.round((usedGb / totalGb) * 100) : 0;
    const colorClass = pct >= 90 ? 'bg-red-500 shadow-[0_0_8px_rgba(239,68,68,0.5)]' : 'bg-brand-500';
    
    return `
        <div class="space-y-1 font-mono text-[10px] w-full">
            <div class="flex justify-between text-slate-400">
                <span>Disk: ${usedGb}G / ${totalGb}G</span>
                <span class="${pct >= 90 ? 'text-red-400 font-bold' : ''}">${pct}%</span>
            </div>
            <div class="w-full bg-slate-900 rounded-full h-1.5 overflow-hidden border border-slate-800">
                <div class="h-full rounded-full transition-all duration-500 ${colorClass}" style="width: ${pct}%"></div>
            </div>
        </div>
    `;
}

/**
 * Toggles skeleton loaders overlay indicators on dashboard tables and charts.
 */
function toggleSkeletonLoaders(isLoading) {
    const skeletons = document.querySelectorAll('.skeleton-wrapper');
    const actualContent = document.querySelectorAll('.data-content-wrapper');
    
    skeletons.forEach(el => {
        if (isLoading) el.classList.remove('hidden');
        else el.classList.add('hidden');
    });
    
    actualContent.forEach(el => {
        if (isLoading) el.classList.add('opacity-40');
        else el.classList.remove('opacity-40');
    });
}

/**
 * Initializes physical storage health ApexCharts
 */
let storageHealthChart = null;
function initStorageHealthChart(containerId, allocatedData = [], freeData = [], categories = []) {
    const el = document.getElementById(containerId);
    if (!el) return;

    const options = {
        series: [{
            name: 'Allocated Space (GB)',
            data: allocatedData
        }, {
            name: 'Free Space (GB)',
            data: freeData
        }],
        chart: {
            type: 'bar',
            height: 220,
            stacked: true,
            toolbar: { show: false },
            background: 'transparent'
        },
        theme: { mode: 'dark' },
        colors: ['#3b82f6', '#10b981'],
        plotOptions: {
            bar: {
                horizontal: true,
                borderRadius: 4
            }
        },
        xaxis: {
            categories: categories,
            labels: { style: { colors: '#9ca3af' } }
        },
        yaxis: {
            labels: { style: { colors: '#9ca3af' } }
        },
        legend: {
            position: 'top',
            labels: { colors: '#e5e7eb' }
        },
        grid: {
            borderColor: '#1f2937'
        }
    };

    if (storageHealthChart) {
        storageHealthChart.destroy();
    }
    storageHealthChart = new ApexCharts(el, options);
    storageHealthChart.render();
}

/**
 * Updates storage charts with active statistics
 */
function updateStorageHealthChart(pools) {
    if (!storageHealthChart) return;
    
    const allocated = pools.map(p => p.allocated_gb);
    const free = pools.map(p => p.free_gb);
    const names = pools.map(p => p.name);
    
    storageHealthChart.updateSeries([{
        name: 'Allocated Space (GB)',
        data: allocated
    }, {
        name: 'Free Space (GB)',
        data: free
    }]);
    
    storageHealthChart.updateOptions({
        xaxis: { categories: names }
    });
}

/**
 * Live polling loop that pulls hypervisor status statistics
 */
async function startLivePolling(onUpdateCallback, intervalMs = 2000) {
    toggleSkeletonLoaders(true);
    
    // Initial fetch
    try {
        const res = await fetch('/api/storage/pools', { headers: API_HEADERS });
        if (res.ok) {
            const pools = await res.json();
            onUpdateCallback(pools);
            toggleSkeletonLoaders(false);
        }
    } catch (err) {
        console.error("Dashboard init load warning: ", err);
    }
    
    // Polling loop
    setInterval(async () => {
        try {
            const res = await fetch('/api/storage/pools', { headers: API_HEADERS });
            if (res.ok) {
                const pools = await res.json();
                onUpdateCallback(pools);
            }
        } catch (err) {
            console.error("Outage during live stats polling: ", err);
        }
    }, intervalMs);
}
