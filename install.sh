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
# Windows users: run inside WSL2 (Ubuntu) or Git Bash.
#                For manual deployment without bash, download the compose
#                file and run: docker compose -f docker-compose.yml up -d
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

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

NUSAAS_VERSION="${NUSAAS_VERSION:-latest}"
COMPOSE_FILE="docker-compose.yml"
COMPOSE_URL="https://get.nusaas.com/${COMPOSE_FILE}"
WATCHTOWER_POLL_INTERVAL="${WATCHTOWER_POLL_INTERVAL:-86400}"

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

command -v docker &>/dev/null    || die "Docker is not installed. Visit https://docs.docker.com/get-docker/"
command -v openssl &>/dev/null   || die "openssl is required but not found."

# Docker Compose v2 (plugin) or v1 (standalone)
if docker compose version &>/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
  COMPOSE_CMD="docker-compose"
else
  die "Docker Compose is not installed. Visit https://docs.docker.com/compose/install/"
fi

DOCKER_VERSION=$(docker --version | awk '{print $3}' | tr -d ',')
success "Docker ${DOCKER_VERSION} detected"
success "Docker Compose detected (${COMPOSE_CMD})"

# Ensure Docker daemon is running
docker info &>/dev/null || die "Docker daemon is not running. Start Docker and try again."

# ── 2. Working directory ──────────────────────────────────────────────────────
INSTALL_DIR="${INSTALL_DIR:-$(pwd)/nusaas}"
info "Install directory: ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}" "${INSTALL_DIR}/web"
cd "${INSTALL_DIR}"

# ── 3. Download compose file ──────────────────────────────────────────────────
if [[ ! -f "${COMPOSE_FILE}" ]]; then
  info "Downloading ${COMPOSE_FILE}..."
  curl -fsSL "${COMPOSE_URL}" -o "${COMPOSE_FILE}" \
    || die "Failed to download ${COMPOSE_FILE}. Check your internet connection."
  success "Downloaded ${COMPOSE_FILE}"
else
  warn "${COMPOSE_FILE} already exists — skipping download."
fi

# ── 4. Interactive configuration ──────────────────────────────────────────────
echo
echo -e "${BOLD}━━━ Application Configuration ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo

prompt "App Name (your business name)"  "MyERP"      APP_NAME
prompt "API URL  (e.g. https://api.erp.example.com)"  "" APP_URL
prompt "Frontend URL (e.g. https://app.erp.example.com)" "" FRONTEND_URL
prompt "Documentation URL (e.g. https://docs.erp.example.com)" "" DOCS_URL
[[ -n "${APP_URL}" && -n "${FRONTEND_URL}" && -n "${DOCS_URL}" ]] \
  || die "API, frontend, and documentation URLs are required."
prompt "App timezone (e.g. Africa/Nairobi)" "Africa/Nairobi" APP_TIMEZONE
prompt "Default currency (e.g. KES)"     "KES"        APP_CURRENCY
prompt "Support email"                   "support@${APP_URL#*://}" SUPPORT_EMAIL

# Normalize URLs to ensure they contain a scheme (default to https://, or http:// for localhost/127.0.0.1)
if [[ ! "$APP_URL" =~ ^https?:// ]]; then
  if [[ "$APP_URL" == *"localhost"* || "$APP_URL" == *"127.0.0.1"* ]]; then
    APP_URL="http://${APP_URL}"
  else
    APP_URL="https://${APP_URL}"
  fi
fi

if [[ ! "$FRONTEND_URL" =~ ^https?:// ]]; then
  if [[ "$FRONTEND_URL" == *"localhost"* || "$FRONTEND_URL" == *"127.0.0.1"* ]]; then
    FRONTEND_URL="http://${FRONTEND_URL}"
  else
    FRONTEND_URL="https://${FRONTEND_URL}"
  fi
fi

if [[ ! "$DOCS_URL" =~ ^https?:// ]]; then
  if [[ "$DOCS_URL" == *"localhost"* || "$DOCS_URL" == *"127.0.0.1"* ]]; then
    DOCS_URL="http://${DOCS_URL}"
  else
    DOCS_URL="https://${DOCS_URL}"
  fi
fi

# Dots must be escaped because this value is consumed as a regular expression.
CORS_FRONTEND_URL="${FRONTEND_URL//./\\.}"

echo
echo -e "${BOLD}━━━ Database ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo
info "The public compose stack includes a private MySQL 8 container."
DB_CONNECTION="mysql"
DB_HOST="db"
DB_PORT="3306"
prompt "DB name"     "nusaas" DB_DATABASE
prompt "DB username (do not use root)" "nusaas" DB_USERNAME
[[ "${DB_USERNAME}" != "root" ]] || die "DB username must not be root."
prompt_secret "DB password" DB_PASSWORD
[[ -n "${DB_PASSWORD}" ]] || die "DB password cannot be empty."
prompt_secret "DB root password (use a different value)" DB_ROOT_PASSWORD
[[ -n "${DB_ROOT_PASSWORD}" ]] || die "DB root password cannot be empty."

echo
echo -e "${BOLD}━━━ Initial Administrator ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo
prompt "Initial admin email" "admin@${FRONTEND_URL#*://}" INITIAL_ADMIN_EMAIL
prompt_secret "Initial admin password" INITIAL_ADMIN_PASSWORD
[[ -n "${INITIAL_ADMIN_PASSWORD}" ]] || die "Initial admin password cannot be empty."

echo
echo -e "${BOLD}━━━ Mail ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo
prompt "SMTP host"       "smtp.mailgun.org"  MAIL_HOST
prompt "SMTP port"       "587"               MAIL_PORT
prompt "SMTP username"   ""                  MAIL_USERNAME
prompt_secret "SMTP password" MAIL_PASSWORD
prompt "Mail from address" "noreply@${APP_URL#*://}" MAIL_FROM_ADDRESS

if [[ "${MAIL_PORT}" == "465" ]]; then
  MAIL_SCHEME="smtps"
else
  MAIL_SCHEME="null"
fi

echo
echo -e "${BOLD}━━━ Meilisearch ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo
warn "Set a strong Meilisearch master key. Remember this — you will need it for re-installs."
prompt_secret "Meilisearch master key (leave blank to auto-generate)" MEILISEARCH_KEY
if [[ -z "${MEILISEARCH_KEY}" ]]; then
  MEILISEARCH_KEY=$(gen_secret)
  info "Auto-generated Meilisearch key: ${MEILISEARCH_KEY}"
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
warn "Full setup guide: docs/firebase-setup.md"
echo
read -rp "$(echo -e "${BOLD}Enable Firebase push notifications? [y/N]: ${RESET}")" ENABLE_FIREBASE
if [[ "${ENABLE_FIREBASE,,}" == "y" ]]; then
  warn "Place your Firebase service account JSON at: ${INSTALL_DIR}/firebase/service-account.json"
  warn "Then restart after setup: docker compose -f ${COMPOSE_FILE} restart api worker"
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

  info "Firebase skipped. You can enable it later — see docs/firebase-setup.md."
fi

# ── 5. Generate secrets ────────────────────────────────────────────────────────
info "Generating cryptographic secrets..."

APP_KEY=$(gen_key)
JWT_SECRET=$(gen_secret)
REVERB_APP_ID=$(gen_secret | head -c 16)
REVERB_APP_KEY=$(gen_secret | head -c 20)
REVERB_APP_SECRET=$(gen_secret)

success "Secrets generated."

# ── 6. Write .env ─────────────────────────────────────────────────────
info "Writing .env..."

APP_NAME_ENV=$(dotenv_quote "${APP_NAME}")
DB_PASSWORD_ENV=$(dotenv_quote "${DB_PASSWORD}")
DB_ROOT_PASSWORD_ENV=$(dotenv_quote "${DB_ROOT_PASSWORD}")
MAIL_USERNAME_ENV=$(dotenv_quote "${MAIL_USERNAME}")
MAIL_PASSWORD_ENV=$(dotenv_quote "${MAIL_PASSWORD}")
INITIAL_ADMIN_PASSWORD_ENV=$(dotenv_quote "${INITIAL_ADMIN_PASSWORD}")

cat > .env << EOF
# =============================================================================
# NuSaaS Backend Environment
# Generated by NuSaaS installer on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# =============================================================================

APP_DEPLOYMENT=self-hosted
APP_NAME=${APP_NAME_ENV}
APP_DISPLAY_NAME=${APP_NAME_ENV}
APP_ENV=production
APP_DEBUG=false
APP_KEY=${APP_KEY}
APP_URL=${APP_URL}
FRONTEND_URL=${FRONTEND_URL}
PUBLIC_FRONTEND_URL=${FRONTEND_URL}
WHATSAPP_CALLBACK_BASE_URL=${APP_URL}
APP_TIMEZONE=${APP_TIMEZONE}
APP_CURRENCY=${APP_CURRENCY}
APP_LOCALE=en
APP_FALLBACK_LOCALE=en

SUPPORT_EMAIL=${SUPPORT_EMAIL}
SUPPORT_WEBSITE=${FRONTEND_URL}
COMPANY_COUNTRY=KE
PRIVACY_EMAIL=${SUPPORT_EMAIL}
CORS_ALLOWED_ORIGIN_PATTERNS='#^${CORS_FRONTEND_URL}$#'
TRUSTED_PROXIES=*
BCRYPT_ROUNDS=12

# Database (${DB_CONNECTION})
DB_CONNECTION=${DB_CONNECTION}
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
DB_DATABASE=${DB_DATABASE}
DB_USERNAME=${DB_USERNAME}
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
MEILISEARCH_KEY=${MEILISEARCH_KEY}
SCOUT_QUEUE=true

# JWT
JWT_SECRET=${JWT_SECRET}
JWT_TTL=60
JWT_REFRESH_TTL=20160

# Mail
MAIL_MAILER=smtp
MAIL_SCHEME=${MAIL_SCHEME}
MAIL_HOST=${MAIL_HOST}
MAIL_PORT=${MAIL_PORT}
MAIL_USERNAME=${MAIL_USERNAME_ENV}
MAIL_PASSWORD=${MAIL_PASSWORD_ENV}
MAIL_FROM_ADDRESS=${MAIL_FROM_ADDRESS}
MAIL_FROM_NAME="\${APP_NAME}"
MAIL_SUPPORT_ADDRESS=${SUPPORT_EMAIL}
MAIL_BRAND_HOME_URL=${FRONTEND_URL}
MAIL_BRAND_LOGO_URL=${APP_URL}/brand/nusaas-logo.png

# WebSocket (Reverb — managed by this compose stack)
BROADCAST_CONNECTION=reverb
REVERB_APP_ID=${REVERB_APP_ID}
REVERB_APP_KEY=${REVERB_APP_KEY}
REVERB_APP_SECRET=${REVERB_APP_SECRET}
REVERB_HOST=ws
REVERB_PORT=8083
REVERB_SCHEME=http

# Auto-Updates (Watchtower)
WATCHTOWER_POLL_INTERVAL=${WATCHTOWER_POLL_INTERVAL}

# Google Social Login (${SOCIAL_LOGIN_ENABLED})
GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID}
GOOGLE_CLIENT_SECRET=${GOOGLE_CLIENT_SECRET}
GOOGLE_REDIRECT_URI=${GOOGLE_REDIRECT_URI}

# Firebase Push Notifications (${PUSH_NOTIFICATIONS_ENABLED})
FIREBASE_CREDENTIALS_PATH=${FIREBASE_CREDENTIALS_PATH}

# Sentry (optional)
SENTRY_LARAVEL_DSN=
SENTRY_ENVIRONMENT=production

# Backups
BACKUP_FILENAME_PREFIX=nusaas-backup
BACKUP_ADMIN_EMAIL=${SUPPORT_EMAIL}

# Initial system administrator (created by migrate --seed)
INITIAL_ADMIN_NAME="System Administrator"
INITIAL_ADMIN_EMAIL=${INITIAL_ADMIN_EMAIL}
INITIAL_ADMIN_PASSWORD=${INITIAL_ADMIN_PASSWORD_ENV}

# Host ports
BACKEND_PORT=4000
FRONTEND_PORT=4001
DOCS_PORT=4002
REVERB_EXTERNAL_PORT=8083
REDIS_MAXMEMORY=512mb
EOF

success ".env written."

# ── 7. Write web/.env.frontend ─────────────────────────────────────────────────
info "Writing web/.env.frontend..."

# Extract Reverb public host from APP_URL
REVERB_PUBLIC_HOST="${APP_URL#*://}"

cat > web/.env.frontend << EOF
# =============================================================================
# NuSaaS Frontend Environment
# Generated by NuSaaS installer on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# =============================================================================

# Deployment mode
VITE_DEPLOYMENT=self-hosted

# API
VITE_API_URL=${APP_URL}
VITE_API_BASE_URL=${APP_URL}

# Branding
VITE_APP_NAME="${APP_NAME}"
VITE_APP_DISPLAY_NAME="${APP_NAME}"
VITE_APP_TAGLINE="ERP & POS for East Africa"
VITE_APP_DESCRIPTION="Self-hosted ERP and POS platform."
VITE_APP_ENV=production
VITE_SUPPORT_EMAIL=${SUPPORT_EMAIL}
VITE_SUPPORT_WEBSITE=${FRONTEND_URL}
VITE_LEGAL_COMPANY_NAME="${APP_NAME}"
VITE_LEGAL_COPYRIGHT_NAME="${APP_NAME}"
VITE_PRIVACY_EMAIL=${SUPPORT_EMAIL}
VITE_DOCS_URL=${DOCS_URL}

# Feature Flags
VITE_BILLING_ENABLED=false
VITE_SOCIAL_LOGIN_ENABLED=${SOCIAL_LOGIN_ENABLED}
VITE_PUSH_NOTIFICATIONS_ENABLED=${PUSH_NOTIFICATIONS_ENABLED}
VITE_DISABLE_RIGHT_CLICK=false

# Google OAuth (when enabled)
VITE_GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID}
VITE_GOOGLE_REDIRECT_URI=${GOOGLE_REDIRECT_URI}

# Firebase browser push (when enabled)
VITE_FIREBASE_API_KEY=${VITE_FIREBASE_API_KEY}
VITE_FIREBASE_AUTH_DOMAIN=${VITE_FIREBASE_AUTH_DOMAIN}
VITE_FIREBASE_PROJECT_ID=${VITE_FIREBASE_PROJECT_ID}
VITE_FIREBASE_STORAGE_BUCKET=${VITE_FIREBASE_STORAGE_BUCKET}
VITE_FIREBASE_MESSAGING_SENDER_ID=${VITE_FIREBASE_MESSAGING_SENDER_ID}
VITE_FIREBASE_APP_ID=${VITE_FIREBASE_APP_ID}
VITE_FIREBASE_VAPID_KEY=${VITE_FIREBASE_VAPID_KEY}

# WebSocket — Laravel Reverb
VITE_REVERB_APP_KEY=${REVERB_APP_KEY}
VITE_REVERB_HOST=${REVERB_PUBLIC_HOST}
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
info "Running database migrations and seeding core configuration..."
${COMPOSE_CMD} -f "${COMPOSE_FILE}" exec -T api \
  php artisan migrate --seed --force

info "Warming search index..."
${COMPOSE_CMD} -f "${COMPOSE_FILE}" exec -T api \
  php artisan scout:sync-index-settings || true

info "Caching config, routes, and views for production..."
${COMPOSE_CMD} -f "${COMPOSE_FILE}" exec -T api \
  php artisan optimize

success "Database ready."

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
echo -e "  1. Point your DNS for ${BOLD}${APP_URL#*://}${RESET} and ${BOLD}${FRONTEND_URL#*://}${RESET} to this server."
echo -e "  2. Configure a reverse proxy (Caddy/Nginx/Traefik) for TLS termination."
echo -e "  3. Sign in with ${BOLD}${INITIAL_ADMIN_EMAIL}${RESET} and change the bootstrap password."
echo
echo -e "  ${BOLD}Useful commands:${RESET}"
echo -e "  View logs    : ${CYAN}${COMPOSE_CMD} -f ${COMPOSE_FILE} logs -f${RESET}"
echo -e "  Stop         : ${CYAN}${COMPOSE_CMD} -f ${COMPOSE_FILE} down${RESET}"
echo -e "  Update images: ${CYAN}${COMPOSE_CMD} -f ${COMPOSE_FILE} pull && ${COMPOSE_CMD} -f ${COMPOSE_FILE} up -d${RESET}"
echo
echo -e "  Support: ${CYAN}support@nusaas.com${RESET} | Docs: ${CYAN}https://nusaas.com/docs${RESET}"
echo
echo
