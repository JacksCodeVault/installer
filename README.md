# NuSaaS self-hosted installer

This repository is the public source of truth for `https://get.nusaas.com` installation assets. The self-hosted stack contains the NuSaaS backend and frontend plus their private infrastructure services. Product documentation remains managed at `https://docs.nusaas.com` and is not distributed as a self-hosted container.

The browser form generates a command containing only non-secret choices. `install.sh` validates the host and DNS, generates secrets on the server, configures Caddy automatic TLS, installs a pinned application release, and creates local database-and-upload backup tooling. Local backups are explicitly same-disk protection; users should add off-server storage when available.

Run validation before publishing:

```bash
bash -n install.sh
python3 tests/site-smoke.py
python3 tests/selfhost-boundary.py
bash tests/install-smoke.sh
```


## Revised image distribution 1.0.11

Backend/frontend images 1.0.11 are published for linux/amd64. Use these matching installer assets for that release. The application repository remains private. This public installer repository contains deployment scripts/configuration, not ERP or console source.

The revised images exclude the private console, NuSaaS subscription/trial billing and paid Hosted WhatsApp. Business owners register, verify email and onboard in the ERP; no internal platform-admin account is created. Backup helpers retain local archives by default; deleting old copies requires an explicit positive `BACKUP_RETENTION_DAYS` process setting. Local helper output is not encrypted or automatically copied off-server.

Optional files: `docker-compose.cloudflare.yml`, `docker-compose.evolution.yml`, `.env.evolution.example` and `Caddyfile.example`. Use your own Cloudflare account and scoped gateway credentials. All application image versions and optional infrastructure image digests must be selected before startup. The base update script does not automatically discover overlays; adapt it before operating a custom stack.

Operator guides: https://docs.nusaas.com/self-hosting/system-requirements (use the guides matching your selected release).


## Business integrations and environment boundary

The public environment templates contain operator-owned runtime configuration.
Do not copy the managed-cloud environment, merchant keys, staff enrollment,
subscription plans or hosted gateway credentials into this repository. Cloud
features are hard-disabled by the public image/Compose; they are not installer
options. The installer does not create an internal administrator account.

M-Pesa credentials and KRA taxpayer/device details are entered in the ERP.
OSCU production transmission defaults off. Only the installation operator can
explicitly allow its own approved workspace IDs after the applicable KRA process.
No payment, KRA initialization or gateway registration runs during installation.

The current published images remain 1.0.11. The queued eTIMS product setup and
new fiscal-receipt flows require a newer published image release. Do not bump
VERSION or advertise the newer workflows as installed until matching artifacts
have been built, tested and published. Documentation and environment changes do
not upgrade the application image.

Guides: https://docs.nusaas.com/settings/kra-etims and
https://docs.nusaas.com/settings/mpesa.
