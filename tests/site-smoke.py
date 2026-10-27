from html.parser import HTMLParser
from pathlib import Path

class Parser(HTMLParser):
    pass

html = Path('index.html').read_text()
version = Path('VERSION').read_text().strip()
Parser().feed(html)
for identifier in ('install-command-form', 'builder-app-domain', 'builder-api-domain', 'builder-backup', 'generated-command'):
    assert f'id="{identifier}"' in html, f'missing {identifier}'
assert '--backup-mode' in html and '--version' in html
assert f"--version '{version}'" in html
assert f'NUSAAS_VERSION=\"${{NUSAAS_VERSION:-{version}}}\"' in Path('install.sh').read_text()
assert f'NUSAAS_VERSION={version}' in Path('.env.selfhosted').read_text()
assert 'Passwords and generated secrets are never collected here' in html
compose = Path('docker-compose.yml').read_text()
assert 'nusaas-docs' not in compose and '\n  docs:' not in compose
assert 'watchtower' not in compose
assert 'nusaas-backend:${NUSAAS_VERSION' in compose
assert 'nusaas-frontend:${NUSAAS_VERSION' in compose
assert 'caddy:2.11.7-alpine' in compose
print('Installer site checks passed')

assert 'id="business-integrations"' in html
assert 'Launch Console' not in html
assert 'https://docs.nusaas.com/settings/kra-etims' in html
assert 'https://docs.nusaas.com/settings/mpesa' in html
