#!/usr/bin/env python3
import os
import time
import subprocess
import urllib.request
import json
from datetime import datetime

# Configuration Settings
CHECK_INTERVAL_SECONDS = 15
DISCORD_WEBHOOK_URL = os.getenv("ANKAVM_DISCORD_WEBHOOK", "")
HOSTNAME = subprocess.check_output(["hostname"], text=True).strip()

SERVICES_TO_MONITOR = [
    {"name": "libvirtd", "desc": "Libvirt Hypervisor Daemon"},
    {"name": "nginx", "desc": "Nginx Reverse Proxy API Gate"},
    {"name": "systemd-resolved", "desc": "System DNS Resolver"}
]

BRIDGES_TO_MONITOR = ["virbr0"]

def send_discord_alert(title: str, message: str, color: int = 16711680):
    """Dispatches webhook payload embeds to configured Discord channel."""
    if not DISCORD_WEBHOOK_URL:
        print(f"[Watchdog Notification Skipped] Title: {title} | Message: {message}")
        return

    payload = {
        "username": "AnkaVM Watchdog",
        "avatar_url": "https://cdn-icons-png.flaticon.com/512/564/564619.png",
        "embeds": [{
            "title": f"⚠️ {title}",
            "description": message,
            "color": color,
            "timestamp": datetime.utcnow().isoformat() + "Z",
            "footer": {"text": f"Node Hostname: {HOSTNAME}"}
        }]
    }

    try:
        req = urllib.request.Request(
            DISCORD_WEBHOOK_URL,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST"
        )
        with urllib.request.urlopen(req, timeout=5) as res:
            if res.status != 204:
                print(f"[Watchdog Webhook Alert Error] Discord API returned code {res.status}")
    except Exception as e:
        print(f"[Watchdog Webhook Delivery Error] FAILED: {e}")

def check_service_status(service_name: str) -> bool:
    """Verifies systemd service activation."""
    try:
        # systemctl is-active exits with 0 if running, non-zero otherwise
        res = subprocess.run(
            ["systemctl", "is-active", "--quiet", service_name],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )
        return res.returncode == 0
    except Exception:
        return False

def restart_service(service_name: str) -> bool:
    """Attempts service restoration command."""
    try:
        res = subprocess.run(
            ["sudo", "systemctl", "restart", service_name],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        return res.returncode == 0
    except Exception:
        return False

def check_bridge_interface(bridge_name: str) -> bool:
    """Checks if target networking bridge exists on host."""
    try:
        res = subprocess.run(
            ["ip", "link", "show", bridge_name],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )
        return res.returncode == 0
    except Exception:
        return False

def restore_bridge_interface(bridge_name: str) -> bool:
    """Attempts to start default network bridge via virsh."""
    try:
        res = subprocess.run(
            ["sudo", "virsh", "net-start", "default"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        return res.returncode == 0
    except Exception:
        return False

def main():
    print(f"==================================================================")
    print(f"       ANKAVM AUTO-REPAIR WATCHDOG DAEMON ACTIVE                  ")
    print(f"==================================================================")
    print(f"Node Monitoring Interval: {CHECK_INTERVAL_SECONDS} seconds")
    print(f"Alert Webhook Status: {'Configured' if DISCORD_WEBHOOK_URL else 'Not Set'}\n")

    send_discord_alert(
        "Watchdog Daemon Initialized",
        "AnkaVM virtualization node watchdog service has successfully started monitoring KVM hypervisor components.",
        color=65280 # Green color
    )

    while True:
        # 1. Monitor Systemd Services
        for svc in SERVICES_TO_MONITOR:
            name = svc["name"]
            desc = svc["desc"]
            
            if not check_service_status(name):
                log_msg = f"CRITICAL: Service '{name}' ({desc}) is crashed or stopped. Executing auto-repair..."
                print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {log_msg}")
                
                send_discord_alert(
                    "Service Outage Detected",
                    f"Service **{name}** ({desc}) was found offline. Watchdog is executing automated restoration checks."
                )

                if restart_service(name):
                    success_msg = f"SUCCESS: Service '{name}' was successfully restarted and is operational."
                    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {success_msg}")
                    send_discord_alert(
                        "Service Auto-Repaired",
                        f"Watchdog successfully restored **{name}** on this node.",
                        color=3066993 # Blue color
                    )
                else:
                    fail_msg = f"FATAL: Service '{name}' auto-restart failed! Manual sysadmin inspection required."
                    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {fail_msg}")
                    send_discord_alert(
                        "Service Restoration FAILED",
                        f"Watchdog could not restore service **{name}**. Node is degraded!",
                        color=15158332 # Dark Red color
                    )

        # 2. Monitor Network Bridge Interfaces
        for bridge in BRIDGES_TO_MONITOR:
            if not check_bridge_interface(bridge):
                log_msg = f"CRITICAL: Network bridge interface '{bridge}' is missing or inactive. Attempting restoration..."
                print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {log_msg}")
                
                send_discord_alert(
                    "Network Bridge Outage",
                    f"Virtual bridge interface **{bridge}** is down. Attempting virsh net-start default execution."
                )

                if restore_bridge_interface(bridge):
                    success_msg = f"SUCCESS: Network bridge '{bridge}' was successfully restored."
                    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {success_msg}")
                    send_discord_alert(
                        "Network Restored",
                        f"Network bridge **{bridge}** was successfully brought back online.",
                        color=3066993
                    )
                else:
                    fail_msg = f"FATAL: Network bridge '{bridge}' restoration failed!"
                    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {fail_msg}")
                    send_discord_alert(
                        "Network Restoration FAILED",
                        f"Could not restore bridge **{bridge}** on the node.",
                        color=15158332
                    )

        time.sleep(CHECK_INTERVAL_SECONDS)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nStopping Watchdog daemon.")
