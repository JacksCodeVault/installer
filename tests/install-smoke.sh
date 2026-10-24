#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=$(pwd)
export REAL_DOCKER=$(command -v docker)
TMP=$(mktemp -d "${REPO}/.installer-test.XXXXXXXX")
[[ "${KEEP_INSTALLER_TEST:-}" == 1 ]] || trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
case "$*" in
  'compose version') printf 'Docker Compose version v2\n' ;;
  '--version') printf 'Docker version 28.0.0, build test\n' ;;
  'info') exit 0 ;;
  *' config --quiet') exec "$REAL_DOCKER" "$@" ;;
  *'exec -T db sh -c'*) printf '%s\n' '-- SQL backup' ;;
  *'exec -T api tar'*) tar -czf - --files-from /dev/null ;;
  *) exit 0 ;;
esac
DOCKER
cat > "$TMP/bin/curl" <<'CURL'
#!/usr/bin/env bash
while (( $# )); do
  if [[ "$1" == '-o' ]]; then
    if [[ "${INSTALLER_CURL_FAIL:-}" == 1 ]]; then printf incomplete > "$2"; exit 22; fi
    cp "$INSTALLER_COMPOSE_SOURCE" "$2"; exit
  fi
  shift
done
exit 0
CURL
cat > "$TMP/bin/ss" <<'SS'
#!/bin/sh
if [ "${TEST_BUSY_PORT:-}" = 1 ]; then echo 'LISTEN 0 4096 0.0.0.0:80'; fi
exit 0
SS
cat > "$TMP/bin/crontab" <<'CRON'
#!/usr/bin/env bash
if [[ "${1:-}" == -l ]]; then cat "${TEST_CRONTAB_FILE}" 2>/dev/null || true; else cat > "${TEST_CRONTAB_FILE}"; fi
CRON
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH" INSTALLER_COMPOSE_SOURCE="$REPO/docker-compose.yml" INSTALL_DIR="$TMP/instance" TEST_CRONTAB_FILE="$TMP/crontab"
cat > "$TMP/answers" <<'ANSWERS'



test$pass!123
root$pass!234




n
n
ANSWERS
bash install.sh --app-name 'Test "Store"' --api-domain api.test.example --app-domain app.test.example --timezone Africa/Nairobi --currency kes --backup-mode local --version 1.0.10 --skip-dns-check < "$TMP/answers" > "$TMP/install.log" 2>&1
"$REAL_DOCKER" compose -f "$INSTALL_DIR/docker-compose.yml" --project-directory "$INSTALL_DIR" config --quiet
"$REAL_DOCKER" compose -f "$INSTALL_DIR/docker-compose.yml" --project-directory "$INSTALL_DIR" config --format json > "$TMP/config.json"
python3 - "$TMP" <<'PY'
from pathlib import Path
import json, sys
p=Path(sys.argv[1]); root=p/'instance'; backend=(root/'.env').read_text(); frontend=(root/'web/.env.frontend').read_text(); compose=(root/'docker-compose.yml').read_text(); log=(p/'install.log').read_text(); resolved=json.loads((p/'config.json').read_text())['services']
assert resolved['db']['environment']['MYSQL_PASSWORD'].replace('$$','$') == 'test$pass!123'
assert "CORS_ALLOWED_ORIGIN_PATTERNS='#^https://app\\.test\\.example$#'" in backend
assert 'NUSAAS_VERSION=1.0.10' in backend
assert 'INITIAL_ADMIN_EMAIL=""' in backend
assert 'Register your business owner account' in log
assert 'RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-}"' in (root/'scripts/backup.sh').read_text()
assert 'VITE_API_URL="https://api.test.example"' in frontend
assert 'VITE_DOCS_URL=https://docs.nusaas.com' in frontend
assert r'VITE_APP_NAME="Test \"Store\""' in frontend
assert 'nusaas-docs' not in compose and '\n  docs:' not in compose
assert 'nusaas-backend:${NUSAAS_VERSION' in compose and 'nusaas-frontend:${NUSAAS_VERSION' in compose
assert 'api.test.example' in (root/'Caddyfile').read_text()
assert (root/'scripts/backup.sh').exists() and (root/'scripts/update.sh').exists()
assert list((root/'backups').glob('database-*.sql.gz'))
assert list((root/'backups').glob('storage-*.tar.gz'))
assert 'nusaas-local-backup' in (p/'crontab').read_text()
for secret in ('test$pass!123','root$pass!234','admin$pass!345'): assert secret not in log
assert (root/'.env').stat().st_mode & 0o077 == 0
PY
cp "$INSTALL_DIR/.env" "$TMP/original-env"
if bash install.sh --skip-dns-check </dev/null > "$TMP/retry.log" 2>&1; then exit 1; fi
cmp "$INSTALL_DIR/.env" "$TMP/original-env"
export INSTALL_DIR="$TMP/invalid"
if bash install.sh --app-name Test --api-domain 'api.test.example/path' --app-domain app.test.example --skip-dns-check </dev/null > "$TMP/invalid.log" 2>&1; then exit 1; fi
test ! -e "$INSTALL_DIR/.env"
export INSTALL_DIR="$TMP/download-error" INSTALLER_CURL_FAIL=1
if bash install.sh --app-name Test --api-domain api.test.example --app-domain app.test.example --skip-dns-check </dev/null > "$TMP/download.log" 2>&1; then exit 1; fi
test ! -e "$INSTALL_DIR/docker-compose.yml"; test ! -e "$INSTALL_DIR/docker-compose.yml.tmp"
# Occupied TLS ports must stop installation before configuration is written.
unset INSTALLER_CURL_FAIL
export INSTALL_DIR="$TMP/busy-port" TEST_BUSY_PORT=1
if bash install.sh --app-name Test --api-domain api.test.example --app-domain app.test.example --skip-dns-check </dev/null > "$TMP/busy-port.log" 2>&1; then exit 1; fi
grep -q 'Port 80 is already in use' "$TMP/busy-port.log"
test ! -e "$INSTALL_DIR/.env"
echo 'Installer smoke checks passed'
