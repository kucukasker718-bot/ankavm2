# Upgrade

The CLICD installer and CLI are built around GitHub Release artifacts. Before upgrading, check the current version and back up configuration and database files.

## Check the Version

The current version is shown at the bottom of the web panel sidebar. You can also run:

```bash
curl http://127.0.0.1:8999/api/version
```

Example response:

```json
{
  "success": true,
  "data": {
    "version": "1.1.6"
  }
}
```

## Upgrade with the Installer

The installer uses the latest release by default:

```bash
curl -fsSL https://raw.githubusercontent.com/MengMengCode/CLICD/main/install.sh | sudo sh
```

Install a specific version:

```bash
curl -fsSL https://raw.githubusercontent.com/MengMengCode/CLICD/main/install.sh | sudo CLICD_VERSION=v1.1.6 sh
```

## Pre-upgrade Checklist

- Back up `/root/.clicd/` or the actual configuration directory.
- Make sure no critical tasks are currently running.
- If an image download or snapshot restore is running, wait for it to finish first.
- After upgrading, check `systemctl status clicd` and the version shown in the web panel.
