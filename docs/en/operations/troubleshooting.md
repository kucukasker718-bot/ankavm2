# Troubleshooting

## Service Not Reachable

Check service status:

```bash
systemctl status clicd
journalctl -u clicd -n 100 --no-pager
```

Check port listening:

```bash
ss -lntp | grep 8999
```

If a reverse proxy is used, check proxy logs and upstream address settings as well.

## Image Download Failed

- Make sure the host can access image sources and GitHub Releases.
- Check disk space.
- Review the failure reason in the task queue.
- If a download is stuck, cancel it and start again.

## Container Cannot Access the Network

- Check host NAT and forwarding rules.
- Confirm that the container IP was assigned successfully.
- Check whether the firewall is blocking forwarded traffic.
- For IPv6, confirm that the upstream network routes the prefix to the host.

## WebSSH or WebVNC Connection Failed

- Confirm that the container or virtual machine is running.
- WebSSH requires SSH service inside the container.
- WebVNC requires the KVM console to be reachable.
- Tickets expire quickly. Create a new ticket after expiration.

## API Returns Unauthorized

- Confirm that the API key is not disabled.
- Use `X-API-Key` or `Authorization: Bearer`.
- Confirm that the key scope covers the target endpoint.
- Do not use the panel login password as an API key.
