# Installation

CLICD provides a one-line installer. By default, it installs the latest version from GitHub Releases. You can also pin a specific version with an environment variable.

## Requirements

- Linux x86_64 host.
- Root privileges.
- systemd.
- Network access to GitHub Release downloads.
- LXC runtime support if you want to use LXC.
- KVM virtualization enabled with libvirt/QEMU installed if you want to use KVM.

## Install the Latest Version

```bash
curl -fsSL https://raw.githubusercontent.com/MengMengCode/CLICD/main/install.sh | sudo sh
```

The script defaults to `CLICD_VERSION=latest`, which downloads `clicd-linux-amd64.tar.gz` from `releases/latest`.

## Install a Specific Version

```bash
curl -fsSL https://raw.githubusercontent.com/MengMengCode/CLICD/main/install.sh | sudo CLICD_VERSION=v1.1.6 sh
```

Replace `v1.1.6` with the release tag you want to install.

## Open the Panel

After installation, open:

```text
http://YOUR_SERVER_IP:8999
```

Use the administrator credentials printed by the installer for the first login. In production, restrict access at the firewall or reverse proxy layer and change the default username and password as soon as possible.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/MengMengCode/CLICD/main/install.sh | sudo sh -s -- uninstall
```

Before uninstalling, decide whether you need to keep containers, image cache, database files, or configuration files.
