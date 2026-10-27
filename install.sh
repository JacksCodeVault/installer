#!/usr/bin/env bash
# =============================================================================
# NuSaaS Installer
# =============================================================================
# Usage:
#   curl -fsSL https://get.nusaas.com/install.sh -o install.sh
#   bash install.sh
#
# Requirements:
#   - Docker (https://docs.docker.com/get-docker/)
#   - openssl (pre-installed on macOS/Linux; Git Bash on Windows includes it)
#
# Windows users: run inside Ubuntu on WSL2 with Docker Desktop integration.
# Native Git Bash/PowerShell installation is not supported; WSL keeps one tested engine.
#
# What this script does:
#   1. Checks system requirements (Docker, Docker Compose)
#   2. Prompts for your configuration (URLs, DB credentials, mail settings)
#   3. Generates cryptographically secure secrets (APP_KEY, JWT_SECRET, etc.)
#   4. Writes .env and web/.env.frontend
#   5. Pulls NuSaaS images from Docker Hub
#   6. Starts all services
#   7. Runs database migrations and seeders
#   8. Prints access information
#
# Support: support@nusaas.com | https://nusaas.com/docs
# =============================================================================

set -euo pipefail
umask 077 # Keep generated credentials private, even if the process exits early.

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

NUSAAS_VERSION="${NUSAAS_VERSION:-1.0.11}"
APP_NAME="${APP_NAME:-}"
APP_URL="${APP_URL:-}"
FRONTEND_URL="${FRONTEND_URL:-}"
APP_TIMEZONE="${APP_TIMEZONE:-Africa/Nairobi}"
APP_CURRENCY="${APP_CURRENCY:-KES}"
BACKUP_MODE="${BACKUP_MODE:-local}"
SKIP_DNS_CHECK=false
COMPOSE_FILE="docker-compose.yml"
COMPOSE_URL="https://get.nusaas.com/${COMPOSE_FILE}"

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}${BOLD}[NuSaaS]${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}[  OK  ]${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[ WARN ]${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}[ERROR ]${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }

prompt() {
  local label="$1" default="${2:-}" var_name="$3"
  if [[ -n "$default" ]]; then
    read -rp "$(echo -e "${BOLD}${label}${RESET} [${default}]: ")" input
    printf -v "${var_name}" '%s' "${input:-$default}"
  else
    read -rp "$(echo -e "${BOLD}${label}${RESET}: ")" input
    printf -v "${var_name}" '%s' "${input}"
  fi
}

prompt_secret() {
  local label="$1" var_name="$2"
  read -rsp "$(echo -e "${BOLD}${label}${RESET}: ")" input
  echo
  printf -v "${var_name}" '%s' "${input}"
}

dotenv_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//\$/\\\$}"
  printf '"%s"' "$value"
}

gen_key() {
  # Generate a 32-byte base64 key (compatible with Laravel's base64: format)
  echo "base64:$(openssl rand -base64 32)"
}

gen_secret() {
  openssl rand -hex 32
}


usage() {
  cat <<'USAGE'
Usage: bash install.sh [options]
  --app-name VALUE       Business/application name
  --api-domain HOST      Public API hostname (for example api.example.com)
  --app-domain HOST      Public frontend hostname (for example app.example.com)
  --timezone VALUE       IANA timezone (default: Africa/Nairobi)
  --currency VALUE       Three-letter currency code (default: KES)
  --backup-mode VALUE    local or later (default: local)
  --version VALUE        Pinned NuSaaS image version
  --install-dir PATH     Installation directory
  --skip-dns-check       Advanced: defer DNS validation (TLS will not issue yet)
USAGE
}

while (( $# )); do
  case "$1" in
    --app-name) APP_NAME="${2:-}"; shift 2 ;;
    --app-name=*) APP_NAME="${1#*=}"; shift ;;
    --api-domain) APP_URL="${2:-}"; shift 2 ;;
    --api-domain=*) APP_URL="${1#*=}"; shift ;;
    --app-domain) FRONTEND_URL="${2:-}"; shift 2 ;;
    --app-domain=*) FRONTEND_URL="${1#*=}"; shift ;;
    --timezone) APP_TIMEZONE="${2:-}"; shift 2 ;;
    --timezone=*) APP_TIMEZONE="${1#*=}"; shift ;;
    --currency) APP_CURRENCY="${2:-}"; shift 2 ;;
    --currency=*) APP_CURRENCY="${1#*=}"; shift ;;
    --backup-mode) BACKUP_MODE="${2:-}"; shift 2 ;;
    --backup-mode=*) BACKUP_MODE="${1#*=}"; shift ;;
    --version) NUSAAS_VERSION="${2:-}"; shift 2 ;;
    --version=*) NUSAAS_VERSION="${1#*=}"; shift ;;
    --install-dir) INSTALL_DIR="${2:-}"; shift 2 ;;
    --install-dir=*) INSTALL_DIR="${1#*=}"; shift ;;
    --skip-dns-check) SKIP_DNS_CHECK=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (use --help)" ;;
  esac
done
[[ "$BACKUP_MODE" == local || "$BACKUP_MODE" == later ]] || die "--backup-mode must be local or later."
[[ "$NUSAAS_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--version must be an exact release such as 1.0.10."

# ── Banner ────────────────────────────────────────────────────────────────────
echo
echo -e "${BLUE}${BOLD}"
cat << 'EOF'
  _   _ _   _ ____    _    _    ____
 | \ | | | | / ___|  / \  / \  / ___|
 |  \| | | | \___ \ / _ \/ _ \ \___ \
 | |\  | |_| |___) / ___ \ ___ \ ___) |
 |_| \_|\___/|____/_/   \_\_/ \_\____/

 ERP & POS Infrastructure for East Africa
EOF
echo -e "${RESET}"
echo -e " Version : ${CYAN}${NUSAAS_VERSION}${RESET}"
echo -e " Docs    : ${CYAN}https://nusaas.com/docs${RESET}"
echo -e " Support : ${CYAN}support@nusaas.com${RESET}"
echo

# ── 1. System requirements ────────────────────────────────────────────────────
info "Checking system requirements..."

[[ "$(uname -s)" == Linux ]] || die "This installer supports Ubuntu/Debian Linux. On Windows, run it inside Ubuntu on WSL2 with Docker Desktop integration."
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  case "${ID:-}" in ubuntu|debian) ;; *) warn "${PRETTY_NAME:-This Linux distribution} is not in the tested Ubuntu/Debian support set." ;; esac
fi
command -v docker &>/dev/null    || die "Docker is not installed. Visit https://docs.docker.com/get-docker/"
command -v openssl &>/dev/null   || die "openssl is required but not found."
command -v curl &>/dev/null      || die "curl is required but not found."

# The distributed compose file requires the v2 plugin.
docker compose version &>/dev/null || die "Docker Compose v2 is required. Visit https://docs.docker.com/compose/install/"
COMPOSE_CMD="docker compose"

DOCKER_VERSION=$(docker --version | awk '{print $3}' | tr -d ',')
success "Docker ${DOCKER_VERSION} detected"
success "Docker Compose detected (${COMPOSE_CMD})"

# Ensure Docker daemon is running
docker info &>/dev/null || die "Docker daemon is not running. Start Docker and try again."

port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    [[ -n "$(ss -H -ltn "sport = :${port}" 2>/dev/null)" ]] && return 0
    [[ "$port" == 443 && -n "$(ss -H -lun "sport = :${port}" 2>/dev/null)" ]] && return 0
  elif command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1 && return 0
  else
    warn "Could not inspect port ${port}; Docker will perform the final bind check."
  fi
  return 1
}
for port in 80 443; do
  port_in_use "$port" && die "Port ${port} is already in use. Stop the existing web server or proxy; NuSaaS uses ports 80/443 for automatic TLS."
done
success "Ports 80 and 443 are available"

# ── 2. Working directory ──────────────────────────────────────────────────────
INSTALL_DIR="${INSTALL_DIR:-$(pwd)/nusaas}"
info "Install directory: ${INSTALL_DIR}"
[[ "$INSTALL_DIR" != *[[:space:]]* ]] || die "Install directory must not contain spaces."
# Never rotate secrets or replace an existing installation during a retry.
if [[ -e "${INSTALL_DIR}/.env" || -e "${INSTALL_DIR}/web/.env.frontend" ]]; then
  die "An installation already exists in ${INSTALL_DIR}. Existing configuration was not changed; see the update instructions at https://docs.nusaas.com/self-hosting/backups-ops."
fi
mkdir -p "${INSTALL_DIR}/web"
cd "${INSTALL_DIR}"

# A failed download must not leave a partial compose file behind.
if [[ ! -f "${COMPOSE_FILE}" ]]; then
  info "Downloading ${COMPOSE_FILE}..."
  curl -fsSL "${COMPOSE_URL}" -o "${COMPOSE_FILE}.tmp" \
    || { rm -f "${COMPOSE_FILE}.tmp"; die "Failed to download ${COMPOSE_FILE}."; }
  mv "${COMPOSE_FILE}.tmp" "${COMPOSE_FILE}"
else
  warn "${COMPOSE_FILE} already exists — using it without modification."
fi
for service in proxy api web worker cron ws db cache search; do
  grep -Eq "^  ${service}:" "${COMPOSE_FILE}" || die "Downloaded compose file is missing the ${service} service."
done
if grep -Eq 'nusaas-docs|^[[:space:]]+(docs|console|platform|watchtower):' "${COMPOSE_FILE}"; then
  die "This compose file includes services outside the self-hosted ERP stack. Download the current self-hosted compose file."
fi

for image in nusaas-backend nusaas-frontend; do
  grep -Fq "ghostdev1/${image}:\${NUSAAS_VERSION" "${COMPOSE_FILE}" || die "Use the published self-hosted backend/frontend images in the base Compose file."
done

# ── 4. Interactive configuration ──────────────────────────────────────────────
echo
echo -e "${BOLD}━━━ Application Configuration ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo

if [[ -z "$APP_NAME" ]]; then prompt "App Name (your business name)" "MyERP" APP_NAME; fi
if [[ -z "$APP_URL" ]]; then prompt "API domain (e.g. api.erp.example.com)" "" APP_URL; fi
if [[ -z "$FRONTEND_URL" ]]; then prompt "Frontend domain (e.g. app.erp.example.com)" "" FRONTEND_URL; fi

normalize_url() {
  local value="$1"
  if [[ ! "$value" =~ ^https?:// ]]; then value="https://${value}"; fi
  [[ "$value" =~ ^https://[a-zA-Z0-9.-]+$ ]] \
    || die "Use a public HTTPS hostname without a path or port (for example app.example.com)."
  printf '%s' "$value"
}
APP_URL=$(normalize_url "$APP_URL")
FRONTEND_URL=$(normalize_url "$FRONTEND_URL")
[[ "$APP_URL" != "$FRONTEND_URL" ]] || die "API and frontend domains must be different."
[[ "$APP_TIMEZONE" =~ ^[A-Za-z_+-]+(/[A-Za-z0-9_+-]+)+$ ]] || die "Enter a valid IANA timezone such as Africa/Nairobi."
APP_CURRENCY=${APP_CURRENCY^^}
[[ "$APP_CURRENCY" =~ ^[A-Z]{3}$ ]] || die "Currency must be a three-letter code such as KES."
CORS_FRONTEND_URL=$(printf '%s' "$FRONTEND_URL" | sed 's/[][\.^$*+?{}()|]/\\&/g')
API_DOMAIN="${APP_URL#*://}"
FRONTEND_DOMAIN="${FRONTEND_URL#*://}"
if [[ "$SKIP_DNS_CHECK" != true ]]; then
  command -v getent >/dev/null 2>&1 || die "getent is required for DNS validation (or use --skip-dns-check to defer TLS)."
  for domain in "$API_DOMAIN" "$FRONTEND_DOMAIN"; do
    getent ahosts "$domain" >/dev/null 2>&1 || die "DNS for ${domain} does not resolve yet. Point it to this server, wait for propagation, and retry."
  done
  success "Frontend and API DNS names resolve"
else
  warn "DNS validation skipped. Caddy cannot issue TLS certificates until both names resolve to this server."
fi
valid_email() { [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]]; }
[[ ${#APP_NAME} -le 100 ]] || die "App name must be 100 characters or fewer."
prompt "Support email" "support@${API_DOMAIN}" SUPPORT_EMAIL
valid_email "$SUPPORT_EMAIL" || die "Enter a valid support email address."

echo
echo -e "${BOLD}━━━ Database ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo
info "The public compose stack includes a private MySQL 8 container."
DB_CONNECTION="mysql"
DB_HOST="db"
DB_PORT="3306"
prompt "DB name"     "nusaas" DB_DATABASE
[[ "$DB_DATABASE" =~ ^[a-zA-Z0-9_]+$ ]] || die "Database name may contain only letters, digits, or underscores."
prompt "DB username (do not use root)" "nusaas" DB_USERNAME
[[ "${DB_USERNAME}" != "root" && "${DB_USERNAME}" =~ ^[a-zA-Z0-9_]+$ ]] || die "Use a non-root database username containing only letters, digits, or underscores."
prompt_secret "DB password" DB_PASSWORD
[[ ${#DB_PASSWORD} -ge 12 ]] || die "Database password must contain at least 12 characters."
prompt_secret "DB root password (use a different value)" DB_ROOT_PASSWORD
[[ ${#DB_ROOT_PASSWORD} -ge 12 ]] || die "Database root password must contain at least 12 characters."
[[ "${DB_PASSWORD}" != "${DB_ROOT_PASSWORD}" ]] || die "Database user and root passwords must differ."

echo
info "Register the business owner in the ERP after installation."

echo
echo -e "${BOLD}━━━ Mail ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo
prompt "SMTP host (leave blank to disable outgoing mail)" "" MAIL_HOST
if [[ -n "$MAIL_HOST" ]]; then
  MAIL_MAILER=smtp
  prompt "SMTP port" "587" MAIL_PORT
  [[ "$MAIL_PORT" =~ ^[0-9]{2,5}$ ]] || die "Enter a valid SMTP port."
  prompt "SMTP username" "" MAIL_USERNAME
  prompt_secret "SMTP password" MAIL_PASSWORD
  [[ -n "$MAIL_USERNAME" && -n "$MAIL_PASSWORD" ]] || die "SMTP username and password are required when outgoing mail is enabled."
  if [[ "$MAIL_PORT" == "465" ]]; then MAIL_SCHEME=smtps; else MAIL_SCHEME=null; fi
else
  MAIL_MAILER=log
  MAIL_PORT=25
  MAIL_USERNAME=""
  MAIL_PASSWORD=""
  MAIL_SCHEME=null
  warn "Email delivery disabled. Password resets and invitations will not reach users until SMTP is configured."
fi
prompt "Mail from address" "noreply@${API_DOMAIN}" MAIL_FROM_ADDRESS
valid_email "$MAIL_FROM_ADDRESS" || die "Enter a valid mail-from address."

echo
echo -e "${BOLD}━━━ Meilisearch ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo
warn "Set a strong Meilisearch master key. Remember this — you will need it for re-installs."
prompt_secret "Meilisearch master key (leave blank to auto-generate)" MEILISEARCH_KEY
if [[ -z "${MEILISEARCH_KEY}" ]]; then
  MEILISEARCH_KEY=$(gen_secret)
  info "Auto-generated a Meilisearch key; store the generated .env securely."
fi

SOCIAL_LOGIN_ENABLED="false"

echo
echo -e "${BOLD}━━━ Optional: Google Social Login ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo
warn "Skip this section if you don't want users to log in with Google."
warn "To enable it later, add GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET to .env."
warn "Setup guide: https://console.cloud.google.com → APIs & Services → Credentials"
echo
read -rp "$(echo -e "${BOLD}Enable Google social login? [y/N]: ${RESET}")" ENABLE_GOOGLE
if [[ "${ENABLE_GOOGLE,,}" == "y" ]]; then
  prompt "Google Client ID"     "" GOOGLE_CLIENT_ID
  prompt "Google Client Secret" "" GOOGLE_CLIENT_SECRET
  GOOGLE_REDIRECT_URI="${APP_URL}/api/auth/google/callback"
  SOCIAL_LOGIN_ENABLED="true"
else
  GOOGLE_CLIENT_ID=""
  GOOGLE_CLIENT_SECRET=""
  GOOGLE_REDIRECT_URI=""
  SOCIAL_LOGIN_ENABLED="false"
  info "Google login skipped. You can enable it later in .env."
fi

echo
echo -e "${BOLD}━━━ Optional: Firebase Push Notifications ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo
warn "Skip this section if you don't need browser push notifications."
warn "Full setup guide: https://docs.nusaas.com"
echo
read -rp "$(echo -e "${BOLD}Enable Firebase push notifications? [y/N]: ${RESET}")" ENABLE_FIREBASE
if [[ "${ENABLE_FIREBASE,,}" == "y" ]]; then
  warn "Place your Firebase service account JSON at: ${INSTALL_DIR}/firebase/service-account.json"
  warn "Then recreate after setup: docker compose -f ${COMPOSE_FILE} up -d --force-recreate api worker"
  mkdir -p "${INSTALL_DIR}/firebase"
  FIREBASE_CREDENTIALS_PATH="firebase/service-account.json"
  prompt "Firebase API key" "" VITE_FIREBASE_API_KEY
  prompt "Firebase auth domain" "" VITE_FIREBASE_AUTH_DOMAIN
  prompt "Firebase project ID" "" VITE_FIREBASE_PROJECT_ID
  prompt "Firebase storage bucket" "" VITE_FIREBASE_STORAGE_BUCKET
  prompt "Firebase messaging sender ID" "" VITE_FIREBASE_MESSAGING_SENDER_ID
  prompt "Firebase app ID" "" VITE_FIREBASE_APP_ID
  prompt "Firebase VAPID key" "" VITE_FIREBASE_VAPID_KEY
  PUSH_NOTIFICATIONS_ENABLED="true"
else
  FIREBASE_CREDENTIALS_PATH=""
  VITE_FIREBASE_API_KEY=""
  VITE_FIREBASE_AUTH_DOMAIN=""
  VITE_FIREBASE_PROJECT_ID=""
  VITE_FIREBASE_STORAGE_BUCKET=""
  VITE_FIREBASE_MESSAGING_SENDER_ID=""
  VITE_FIREBASE_APP_ID=""
  VITE_FIREBASE_VAPID_KEY=""
  PUSH_NOTIFICATIONS_ENABLED="false"

  info "Firebase skipped. You can enable it later using the managed documentation."
fi

# ── 5. Generate secrets ────────────────────────────────────────────────────────
info "Generating cryptographic secrets..."

APP_KEY=$(gen_key)
JWT_SECRET=$(gen_secret)
REVERB_APP_ID=$(openssl rand -hex 8)
REVERB_APP_KEY=$(openssl rand -hex 10)
REVERB_APP_SECRET=$(gen_secret)

success "Secrets generated."

# ── 6. Generate runtime configuration ─────────────────────────────────────────
info "Writing proxy and operations configuration..."
cat > Caddyfile << EOF_CADDY
{
  email ${SUPPORT_EMAIL}
}
${FRONTEND_DOMAIN} {
  encode zstd gzip
  reverse_proxy web:4001
}
${API_DOMAIN} {
  encode zstd gzip
  @reverb path /app/*
  reverse_proxy @reverb ws:8083
  reverse_proxy api:4000
}
EOF_CADDY
mkdir -p scripts backups
chmod 700 scripts backups
cat > scripts/backup.sh <<'BACKUP'
#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
BACKUP_DIR="${BACKUP_DIR:-$PWD/backups}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-}"
STAMP=$(date -u +%Y%m%d_%H%M%S)
mkdir -p "$BACKUP_DIR"
docker compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" mysqldump --single-transaction -u"$MYSQL_USER" "$MYSQL_DATABASE"' | gzip > "$BACKUP_DIR/database-$STAMP.sql.gz"
docker compose exec -T api tar -C /var/www/storage -czf - . > "$BACKUP_DIR/storage-$STAMP.tar.gz"
gzip -t "$BACKUP_DIR/database-$STAMP.sql.gz"
tar -tzf "$BACKUP_DIR/storage-$STAMP.tar.gz" >/dev/null
if [[ -n "$RETENTION_DAYS" ]]; then
  [[ "$RETENTION_DAYS" =~ ^[1-9][0-9]*$ ]] || { echo "BACKUP_RETENTION_DAYS must be a positive integer" >&2; exit 2; }
  find "$BACKUP_DIR" -type f \( -name 'database-*.sql.gz' -o -name 'storage-*.tar.gz' \) -mtime "+$RETENTION_DAYS" -delete
fi
printf 'Backup completed: %s\n' "$STAMP"
BACKUP
chmod 700 scripts/backup.sh
cat > scripts/update.sh <<EOF_UPDATE
#!/usr/bin/env bash
set -euo pipefail
cd "\$(dirname "\$0")/.."
NEW_VERSION="\${1:-}"
[[ "\$NEW_VERSION" =~ ^[0-9]+\\.[0-9]+\\.[0-9]+\$ ]] || { echo "Usage: scripts/update.sh VERSION" >&2; exit 2; }
OLD_VERSION=\$(sed -n 's/^NUSAAS_VERSION=//p' .env)
[[ -n "\$OLD_VERSION" && "\$NEW_VERSION" != "\$OLD_VERSION" ]] || { echo "Choose a version different from \$OLD_VERSION" >&2; exit 2; }
./scripts/backup.sh
sed -i.bak "s/^NUSAAS_VERSION=.*/NUSAAS_VERSION=\$NEW_VERSION/" .env
if ! docker compose config --quiet || ! docker compose pull || ! docker compose up -d || ! docker compose exec -T api php artisan migrate --force || ! curl -fsS --retry 12 --retry-delay 5 "https://${API_DOMAIN}/api/health" >/dev/null; then
  mv .env.bak .env
  docker compose up -d
  echo "Update failed; application images reverted to \$OLD_VERSION. Database changes are not automatically reversed; preserve the new backup." >&2
  exit 1
fi
rm -f .env.bak
echo "Updated NuSaaS from \$OLD_VERSION to \$NEW_VERSION"
EOF_UPDATE
chmod 700 scripts/update.sh

# ── 7. Write environment files ────────────────────────────────────────────────
info "Writing .env..."

APP_NAME_ENV=$(dotenv_quote "${APP_NAME}")
DB_PASSWORD_ENV=$(dotenv_quote "${DB_PASSWORD}")
DB_ROOT_PASSWORD_ENV=$(dotenv_quote "${DB_ROOT_PASSWORD}")
MAIL_USERNAME_ENV=$(dotenv_quote "${MAIL_USERNAME}")
MAIL_PASSWORD_ENV=$(dotenv_quote "${MAIL_PASSWORD}")
APP_URL_ENV=$(dotenv_quote "${APP_URL}")
FRONTEND_URL_ENV=$(dotenv_quote "${FRONTEND_URL}")
APP_TIMEZONE_ENV=$(dotenv_quote "${APP_TIMEZONE}")
APP_CURRENCY_ENV=$(dotenv_quote "${APP_CURRENCY}")
DB_DATABASE_ENV=$(dotenv_quote "${DB_DATABASE}")
DB_USERNAME_ENV=$(dotenv_quote "${DB_USERNAME}")
MAIL_HOST_ENV=$(dotenv_quote "${MAIL_HOST}")
GOOGLE_REDIRECT_URI_ENV=$(dotenv_quote "${GOOGLE_REDIRECT_URI}")
SUPPORT_EMAIL_ENV=$(dotenv_quote "${SUPPORT_EMAIL}")
MAIL_FROM_ADDRESS_ENV=$(dotenv_quote "${MAIL_FROM_ADDRESS}")
GOOGLE_CLIENT_ID_ENV=$(dotenv_quote "${GOOGLE_CLIENT_ID}")
GOOGLE_CLIENT_SECRET_ENV=$(dotenv_quote "${GOOGLE_CLIENT_SECRET}")
MEILISEARCH_KEY_ENV=$(dotenv_quote "${MEILISEARCH_KEY}")
MAIL_BRAND_LOGO_URL_ENV=$(dotenv_quote "${APP_URL}/brand/nusaas-logo.png")

cat > .env << EOF
# =============================================================================
# NuSaaS Backend Environment
# Generated by NuSaaS installer on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# =============================================================================

APP_DEPLOYMENT=self-hosted
BILLING_ENABLED=false
WHATSAPP_EVOLUTION_ENABLED=false
WHATSAPP_SELF_HOSTED_URL=
WHATSAPP_EVOLUTION_NATIVE_BUTTONS=false
WHATSAPP_EVOLUTION_NATIVE_LISTS=false

# Optional customer-owned KRA OSCU integration. Configure sandbox in ERP Settings.
# Leave production off until the business has completed its KRA approval process.
ETIMS_PRODUCTION_ENABLED=false
ETIMS_APPROVED_PRODUCTION_TENANTS=
APP_NAME=${APP_NAME_ENV}
APP_DISPLAY_NAME=${APP_NAME_ENV}
APP_ENV=production
APP_DEBUG=false
APP_KEY=${APP_KEY}
APP_URL=${APP_URL_ENV}
FRONTEND_URL=${FRONTEND_URL_ENV}
PUBLIC_FRONTEND_URL=${FRONTEND_URL_ENV}
WHATSAPP_CALLBACK_BASE_URL=${APP_URL_ENV}
APP_TIMEZONE=${APP_TIMEZONE_ENV}
APP_CURRENCY=${APP_CURRENCY_ENV}
APP_LOCALE=en
APP_FALLBACK_LOCALE=en

SUPPORT_EMAIL=${SUPPORT_EMAIL_ENV}
SUPPORT_WEBSITE=${FRONTEND_URL_ENV}
COMPANY_COUNTRY=KE
PRIVACY_EMAIL=${SUPPORT_EMAIL_ENV}
CORS_ALLOWED_ORIGIN_PATTERNS='#^${CORS_FRONTEND_URL}\$#'
TRUSTED_PROXIES=*
BCRYPT_ROUNDS=12

# Database (${DB_CONNECTION})
DB_CONNECTION=${DB_CONNECTION}
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
DB_DATABASE=${DB_DATABASE_ENV}
DB_USERNAME=${DB_USERNAME_ENV}
DB_PASSWORD=${DB_PASSWORD_ENV}
DB_ROOT_PASSWORD=${DB_ROOT_PASSWORD_ENV}
MYSQL_ATTR_SSL_VERIFY_SERVER_CERT=false

# Redis (managed by this compose stack)
REDIS_HOST=cache
REDIS_PORT=6379
REDIS_CLIENT=predis

# Queue & Session
QUEUE_CONNECTION=redis
SESSION_DRIVER=redis
SESSION_LIFETIME=120
CACHE_STORE=redis

# Logging
LOG_CHANNEL=stack
LOG_LEVEL=error

# Meilisearch (managed by this compose stack)
SCOUT_DRIVER=meilisearch
MEILISEARCH_HOST=http://search:7700
MEILISEARCH_KEY=${MEILISEARCH_KEY_ENV}
SCOUT_QUEUE=true

# JWT
JWT_SECRET=${JWT_SECRET}
JWT_TTL=60
JWT_REFRESH_TTL=20160

# Mail
MAIL_MAILER=${MAIL_MAILER}
MAIL_SCHEME=${MAIL_SCHEME}
MAIL_HOST=${MAIL_HOST_ENV}
MAIL_PORT=${MAIL_PORT}
MAIL_USERNAME=${MAIL_USERNAME_ENV}
MAIL_PASSWORD=${MAIL_PASSWORD_ENV}
MAIL_FROM_ADDRESS=${MAIL_FROM_ADDRESS_ENV}
MAIL_FROM_NAME="\${APP_NAME}"
MAIL_SUPPORT_ADDRESS=${SUPPORT_EMAIL_ENV}
MAIL_BRAND_HOME_URL=${FRONTEND_URL_ENV}
MAIL_BRAND_LOGO_URL=${MAIL_BRAND_LOGO_URL_ENV}

# WebSocket (Reverb — managed by this compose stack)
BROADCAST_CONNECTION=reverb
REVERB_APP_ID=${REVERB_APP_ID}
REVERB_APP_KEY=${REVERB_APP_KEY}
REVERB_APP_SECRET=${REVERB_APP_SECRET}
REVERB_HOST=ws
REVERB_PORT=8083
REVERB_SCHEME=http

# Google Social Login (${SOCIAL_LOGIN_ENABLED})
GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID_ENV}
GOOGLE_CLIENT_SECRET=${GOOGLE_CLIENT_SECRET_ENV}
GOOGLE_REDIRECT_URI=${GOOGLE_REDIRECT_URI_ENV}

# Firebase Push Notifications (${PUSH_NOTIFICATIONS_ENABLED})
FIREBASE_CREDENTIALS_PATH=${FIREBASE_CREDENTIALS_PATH}

# Sentry (optional)
SENTRY_LARAVEL_DSN=
SENTRY_ENVIRONMENT=production

# Backups
BACKUP_FILENAME_PREFIX=nusaas-backup
BACKUP_ADMIN_EMAIL=${SUPPORT_EMAIL_ENV}

# Business owner registration is completed through ERP onboarding.

# Pinned application release, backup state, and runtime limits
NUSAAS_VERSION=${NUSAAS_VERSION}
SELF_HOSTED_BACKUP_MODE=${BACKUP_MODE}
REDIS_MAXMEMORY=512mb
EOF

success ".env written."

# ── 7. Write web/.env.frontend ─────────────────────────────────────────────────
info "Writing web/.env.frontend..."

# Extract Reverb public host from APP_URL
REVERB_PUBLIC_HOST="${API_DOMAIN}"

cat > web/.env.frontend << EOF
# =============================================================================
# NuSaaS Frontend Environment
# Generated by NuSaaS installer on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# =============================================================================

# Deployment mode
VITE_DEPLOYMENT=self-hosted

# API
VITE_API_URL=${APP_URL_ENV}
VITE_API_BASE_URL=${APP_URL_ENV}

# Branding
VITE_APP_NAME=${APP_NAME_ENV}
VITE_APP_DISPLAY_NAME=${APP_NAME_ENV}
VITE_APP_TAGLINE="ERP & POS for East Africa"
VITE_APP_DESCRIPTION="Self-hosted ERP and POS platform."
VITE_APP_ENV=production
VITE_SUPPORT_EMAIL=${SUPPORT_EMAIL_ENV}
VITE_SUPPORT_WEBSITE=${FRONTEND_URL_ENV}
VITE_LEGAL_COMPANY_NAME=${APP_NAME_ENV}
VITE_LEGAL_COPYRIGHT_NAME=${APP_NAME_ENV}
VITE_PRIVACY_EMAIL=${SUPPORT_EMAIL_ENV}
VITE_DOCS_URL=https://docs.nusaas.com

# Feature Flags
VITE_BILLING_ENABLED=false
VITE_SOCIAL_LOGIN_ENABLED=${SOCIAL_LOGIN_ENABLED}
VITE_PUSH_NOTIFICATIONS_ENABLED=${PUSH_NOTIFICATIONS_ENABLED}
VITE_DISABLE_RIGHT_CLICK=false

# Google OAuth (when enabled)
VITE_GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID_ENV}
VITE_GOOGLE_REDIRECT_URI=${GOOGLE_REDIRECT_URI_ENV}

# Firebase browser push (when enabled)
VITE_FIREBASE_API_KEY=$(dotenv_quote "${VITE_FIREBASE_API_KEY}")
VITE_FIREBASE_AUTH_DOMAIN=$(dotenv_quote "${VITE_FIREBASE_AUTH_DOMAIN}")
VITE_FIREBASE_PROJECT_ID=$(dotenv_quote "${VITE_FIREBASE_PROJECT_ID}")
VITE_FIREBASE_STORAGE_BUCKET=$(dotenv_quote "${VITE_FIREBASE_STORAGE_BUCKET}")
VITE_FIREBASE_MESSAGING_SENDER_ID=$(dotenv_quote "${VITE_FIREBASE_MESSAGING_SENDER_ID}")
VITE_FIREBASE_APP_ID=$(dotenv_quote "${VITE_FIREBASE_APP_ID}")
VITE_FIREBASE_VAPID_KEY=$(dotenv_quote "${VITE_FIREBASE_VAPID_KEY}")

# WebSocket — Laravel Reverb
VITE_REVERB_APP_KEY=${REVERB_APP_KEY}
VITE_REVERB_HOST=$(dotenv_quote "${REVERB_PUBLIC_HOST}")
VITE_REVERB_PORT=443
VITE_REVERB_SCHEME=wss

# Sentry (disabled by default for self-hosted)
VITE_ENABLE_SENTRY=false
VITE_SENTRY_DSN=

# Maps
VITE_MAP_TILE_URL=https://tile.openstreetmap.org/{z}/{x}/{y}.png
VITE_MAP_ATTRIBUTION=&copy; OpenStreetMap contributors
VITE_MAP_MAX_ZOOM=19
VITE_MAP_EXTERNAL_LINKS=true
EOF

success "web/.env.frontend written."
${COMPOSE_CMD} -f "${COMPOSE_FILE}" config --quiet >/dev/null || die "Configuration validation failed. Edit .env and web/.env.frontend before starting services."

# ── 8. Pull images ────────────────────────────────────────────────────────────
echo
info "Pulling NuSaaS images from Docker Hub..."
${COMPOSE_CMD} -f "${COMPOSE_FILE}" pull
success "Images pulled."

# ── 9. Start services ─────────────────────────────────────────────────────────
info "Starting services..."
${COMPOSE_CMD} -f "${COMPOSE_FILE}" up -d --remove-orphans
success "Services started."

# ── 10. Wait for backend ──────────────────────────────────────────────────────
info "Waiting for backend to become healthy..."
MAX_WAIT=120
WAITED=0
until ${COMPOSE_CMD} -f "${COMPOSE_FILE}" exec -T api \
      curl -sf http://localhost:4000/api/health &>/dev/null; do
  sleep 3
  WAITED=$((WAITED + 3))
  if [[ ${WAITED} -ge ${MAX_WAIT} ]]; then
    die "Backend did not become healthy within ${MAX_WAIT}s. Check logs: ${COMPOSE_CMD} -f ${COMPOSE_FILE} logs api"
  fi
  echo -n "."
done
echo
success "Backend is healthy."

# ── 11. Run migrations and seeders ────────────────────────────────────────────
info "Seeding core configuration for this new installation (startup has applied migrations)..."
${COMPOSE_CMD} -f "${COMPOSE_FILE}" exec -T api \
  php artisan db:seed --force

info "Warming search index..."
${COMPOSE_CMD} -f "${COMPOSE_FILE}" exec -T api \
  php artisan scout:sync-index-settings || true

info "Caching config, routes, and views for production..."
${COMPOSE_CMD} -f "${COMPOSE_FILE}" exec -T api \
  php artisan optimize

success "Database ready."

if [[ "$BACKUP_MODE" == local ]]; then
  warn "Local backups use the same server disk and do not protect against disk or VPS loss."
  ./scripts/backup.sh
  if command -v crontab >/dev/null 2>&1; then
    CRON_MARKER="# nusaas-local-backup"
    CRON_LINE="15 2 * * * ${INSTALL_DIR}/scripts/backup.sh >> ${INSTALL_DIR}/backups/backup.log 2>&1 ${CRON_MARKER}"
    { crontab -l 2>/dev/null | grep -Fv "$CRON_MARKER" || true; echo "$CRON_LINE"; } | crontab -
    success "Scheduled daily local database and upload backups at 02:15"
  else
    warn "crontab is unavailable. Schedule ${INSTALL_DIR}/scripts/backup.sh with your system scheduler."
  fi
else
  warn "Backups are not configured. Run scripts/backup.sh or configure off-server storage before relying on this installation."
fi

# ── 12. Done ──────────────────────────────────────────────────────────────────
echo
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}${BOLD}  NuSaaS is running!${RESET}"
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo
echo -e "  Web Interface → ${CYAN}${FRONTEND_URL}${RESET}"
echo -e "  API Endpoint  → ${CYAN}${APP_URL}${RESET}"
echo
echo -e "  ${BOLD}Next steps:${RESET}"
echo -e "  1. Caddy manages HTTPS for ${BOLD}${API_DOMAIN}${RESET} and ${BOLD}${FRONTEND_DOMAIN}${RESET}."
echo -e "  2. Register your business owner account, verify its email and complete onboarding."
echo -e "  3. Documentation remains managed at ${BOLD}https://docs.nusaas.com${RESET}."
echo -e "  4. Configure your own M-Pesa account in Settings → Payment Methods → M-Pesa."
echo -e "  5. For KRA OSCU setup and release prerequisites: https://docs.nusaas.com/settings/kra-etims"
info "Integrations are not activated by installation. Provider credentials stay in ERP settings."
echo
echo -e "  ${BOLD}Useful commands:${RESET}"
echo -e "  View logs    : ${CYAN}${COMPOSE_CMD} -f ${COMPOSE_FILE} logs -f${RESET}"
echo -e "  Stop         : ${CYAN}${COMPOSE_CMD} -f ${COMPOSE_FILE} down${RESET}"
echo -e "  Update images: ${CYAN}${COMPOSE_CMD} -f ${COMPOSE_FILE} pull && ${COMPOSE_CMD} -f ${COMPOSE_FILE} up -d${RESET}"
echo
echo -e "  Support: ${CYAN}support@nusaas.com${RESET} | Docs: ${CYAN}https://nusaas.com/docs${RESET}"
echo
echo
