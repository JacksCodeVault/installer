from pathlib import Path
import re

# Prevent accidental copying of a private deployment environment into downloads.
for name in ('.env.selfhosted', '.env.frontend'):
    text = Path(name).read_text()
    keys = set(re.findall(r'^([A-Z][A-Z0-9_]*)=', text, re.M))
    assert not any(key.startswith(('PLATFORM_', 'WHATSAPP_HOSTING_', 'INITIAL_ADMIN_', 'STRIPE_')) for key in keys), name
    assert not any(key.startswith(('MPESA_', 'ETIMS_COMMUNICATION_', 'KRA_')) for key in keys), name
    assert not re.search(r'(?:staff-api|console|nusaas-wa-api)\.nusaas\.com|/root/docker/|/home/jack/', text), name
backend = Path('.env.selfhosted').read_text()
assert 'APP_DEPLOYMENT=self-hosted' in backend
assert 'BILLING_ENABLED=false' in backend
assert 'ETIMS_PRODUCTION_ENABLED=false' in backend
assert re.search(r'^ETIMS_APPROVED_PRODUCTION_TENANTS=$', backend, re.M)
frontend = Path('.env.frontend').read_text()
assert 'VITE_DEPLOYMENT=self-hosted' in frontend
assert 'VITE_BILLING_ENABLED=false' in frontend
assert 'VITE_DOCS_URL=https://docs.nusaas.com' in frontend
compose = Path('docker-compose.yml').read_text()
for flag in ('BILLING_ENABLED', 'PLATFORM_ADMIN_ENABLED', 'WHATSAPP_HOSTING_CHECKOUT_ENABLED', 'WHATSAPP_HOSTING_LIVE_PLAN_CREATION_ENABLED'):
    assert f'{flag}: "false"' in compose
assert not re.search(r'^  (?:console|platform|docs|watchtower):', compose, re.M)
print('Self-hosted environment boundary checked')
