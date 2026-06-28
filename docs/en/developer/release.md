# Release Process

CLICD installation and upgrade rely on GitHub Release artifacts. Use semantic version tags such as `v1.1.6`.

## Version Number

Check the version in:

- `backend/internal/version/version.go`
- `frontend/package.json`
- Release tag.

## Release Artifacts

The installer first tries to download the Linux AMD64 archive:

```text
clicd-linux-amd64.tar.gz
```

In some cases, it may also try the standalone binary:

```text
clicd-linux-amd64
```

## Installer Behavior

- `CLICD_VERSION=latest`: use GitHub `releases/latest`.
- `CLICD_VERSION=vX.Y.Z`: download artifacts from the specified release tag.

Example:

```bash
CLICD_VERSION=v1.1.6 sh install.sh
```

## Post-release Verification

- The installer can download the new version.
- `systemctl status clicd` is healthy.
- `/api/version` returns the new version.
- The web panel can load frontend assets.
- Container list, task queue, and API Key pages open correctly.
