# Configuration

After installation, CLICD runs as a systemd service. Runtime configuration and the database are stored locally on the host. The exact path may vary with installer options, but the default installation should mainly be checked under `/root/.clicd/`.

## Common Settings

| Setting | Description |
| --- | --- |
| Web port | Defaults to `8999`, listening on `0.0.0.0:8999`. |
| Administrator account | Used to log in to the web panel and manage API keys. |
| Database | SQLite storage for container metadata, sub-users, audit logs, API keys, and more. |
| NAT port range | Used for random ports and port mapping allocation. |
| IPv6 prefixes | Used when the host has routable IPv6 prefixes. |
| Security alerts | Policies such as automatic shutdown can be configured. |

## Service Commands

```bash
systemctl status clicd
systemctl restart clicd
journalctl -u clicd -n 100 --no-pager
```

## Security Recommendations

- Do not expose the web panel directly to untrusted networks.
- Use a strong administrator password and rotate it regularly.
- Split API keys by purpose and avoid long-lived full-access keys.
- WebSSH and WebVNC tickets are short-lived credentials and should not be written to logs or shared publicly.
- Do not paste real IPs, passwords, API keys, or tickets into public docs, screenshots, or support tickets.
