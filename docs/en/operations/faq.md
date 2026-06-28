# FAQ

## Which version does the installer install by default?

It installs the latest version from GitHub Releases. The script default is `CLICD_VERSION=latest`, which downloads the Linux AMD64 artifact from `releases/latest`.

## Can I pin a specific version?

Yes:

```bash
curl -fsSL https://raw.githubusercontent.com/MengMengCode/CLICD/main/install.sh | sudo CLICD_VERSION=v1.1.6 sh
```

## Can sub-users see every container?

No. Sub-users only see containers authorized by the administrator.

## Is an API key the same as the login password?

No. API keys are created on the API Integration page for programmatic access. The login password is used for the web panel.

## What happens after a container reaches its traffic limit?

The container is automatically shut down to avoid further overage. The administrator can adjust the limit or reset traffic usage.

## Why is IPv6 unreachable after assignment?

IPv6 reachability depends on the host and upstream network. Confirm that the host has a routable IPv6 prefix and that routing, firewall, neighbor discovery, or proxy configuration is correct.
