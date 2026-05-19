# Vendored CLI binaries

## `z8l`

Linux x86_64 binary copied into the Docker image at build time (`COPY bin/z8l`).

**Refresh** when upgrading z8l (one-time download, then commit):

```bash
export Z8L_DOWNLOAD_URL='https://.../z8l_Linux_x86_64.zip?token=...'
./scripts/vendor-z8l.sh
git add bin/z8l
```

Current version: **0.1.12** (check with `./bin/z8l version`).

SpecStory and Cursor Agent are installed from upstream during `docker build` (see `docker/install-tools.sh`).
