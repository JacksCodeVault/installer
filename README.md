# NuSaaS self-hosted installer

This repository is the public source of truth for `https://get.nusaas.com` installation assets. The self-hosted stack contains the NuSaaS backend and frontend plus their private infrastructure services. Product documentation remains managed at `https://docs.nusaas.com` and is not distributed as a self-hosted container.

The browser form generates a command containing only non-secret choices. `install.sh` validates the host and DNS, generates secrets on the server, configures Caddy automatic TLS, installs a pinned application release, and creates local database-and-upload backup tooling. Local backups are explicitly same-disk protection; users should add off-server storage when available.

Run validation before publishing:

```bash
bash -n install.sh
python3 tests/site-smoke.py
bash tests/install-smoke.sh
```
