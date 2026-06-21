#!/bin/bash
#
# PowerPs Core + WebApp installer / updater
# Usage: sudo bash install.sh   OR   curl ... | sudo bash

set -o errexit
set -o nounset
set -o pipefail

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

APP_DIR="/var/www/html/laravel-app"
WEBAPP_DIR="/var/www/html/powerps-webapp"
LARAVEL_ENV_FILE="${APP_DIR}/.env"
STATE_DIR="/var/lib/powerps"
SUBDOMAIN_FILE="${STATE_DIR}/subdomains.conf"
LOG_FILE="/var/log/powerps_install.log"

DB_NAME="powerps_db"
DB_USER="powerps_user"
DB_PASS=""
PHP_VERSION="8.4"
COMPOSER_BIN="/usr/bin/composer"

LARAVEL_SUBDOMAIN=""
HTML5_SUBDOMAIN=""
TELEGRAM_BOT_TOKEN=""
TELEGRAM_ADMIN_ID=""

# ---------------------------------------------------------------------------
# Logging / helpers
# ---------------------------------------------------------------------------
init_logging() {
 sudo mkdir -p /var/log "${STATE_DIR}"
 sudo touch "${LOG_FILE}"
 sudo chown "$(whoami):$(whoami)" "${LOG_FILE}" 2>/dev/null || true
 sudo chmod 640 "${LOG_FILE}" 2>/dev/null || true
 sudo mkdir -p "${STATE_DIR}"
 sudo chown "$(whoami):$(whoami)" "${STATE_DIR}" 2>/dev/null || true
}

log_info() {
 echo -e "${GREEN}$1${NC}"
 echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1" | sudo tee -a "${LOG_FILE}" >/dev/null
}

log_warn() {
 echo -e "${YELLOW}$1${NC}"
 echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $1" | sudo tee -a "${LOG_FILE}" >/dev/null
}

log_error() {
 echo -e "${RED}$1${NC}" >&2
 echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" | sudo tee -a "${LOG_FILE}" >/dev/null
}

die() {
 log_error "$1"
 exit 1
}

run_with_retry() {
 local cmd="$1"
 local retries="${2:-3}"
 local delay="${3:-5}"
 local attempt=1
 until eval "$cmd"; do
  if [ "${attempt}" -ge "${retries}" ]; then
   return 1
  fi
  log_warn "Attempt ${attempt} failed; retrying in ${delay}s..."
  attempt=$((attempt + 1))
  sleep "${delay}"
 done
}

backup_existing() {
 if [ -d "$1" ]; then
  local backup_dir="${1}_backup_$(date +%Y%m%d_%H%M%S)"
  mv "$1" "${backup_dir}"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backed up $1 to ${backup_dir}" | sudo tee -a "${LOG_FILE}" >/dev/null
 fi
}

php_bin() {
 echo "php${PHP_VERSION}"
}

trim_whitespace() {
 local s="$1"
 s="${s#"${s%%[![:space:]]*}"}"
 s="${s%"${s##*[![:space:]]}"}"
 printf '%s' "${s}"
}

artisan() {
 cd "${APP_DIR}"
 "$(php_bin)" artisan "$@"
}

start_service() {
 local svc="$1"
 if command -v systemctl >/dev/null 2>&1 && systemctl start "${svc}" 2>/dev/null; then
  return 0
 fi
 if command -v service >/dev/null 2>&1 && service "${svc}" start 2>/dev/null; then
  return 0
 fi
 return 1
}

restart_service() {
 local svc="$1"
 if command -v systemctl >/dev/null 2>&1 && systemctl restart "${svc}" 2>/dev/null; then
  return 0
 fi
 if command -v service >/dev/null 2>&1 && service "${svc}" restart 2>/dev/null; then
  return 0
 fi
 return 1
}

enable_service() {
 local svc="$1"
 systemctl enable "${svc}" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Subdomain state
# ---------------------------------------------------------------------------
load_subdomains_from_file() {
 local file="$1"
 [ -f "${file}" ] || return 1
 # shellcheck disable=SC1090
 source "${file}"
 [ -n "${LARAVEL_SUBDOMAIN:-}" ] && [ -n "${HTML5_SUBDOMAIN:-}" ]
}

persist_subdomains() {
 echo "LARAVEL_SUBDOMAIN=${LARAVEL_SUBDOMAIN}" | sudo tee "${SUBDOMAIN_FILE}" >/dev/null
 echo "HTML5_SUBDOMAIN=${HTML5_SUBDOMAIN}" | sudo tee -a "${SUBDOMAIN_FILE}" >/dev/null
}

detect_subdomains_from_apache() {
 local core_conf="/etc/apache2/sites-available/powerps-core.conf"
 local web_conf="/etc/apache2/sites-available/powerps-webapp.conf"
 if [ -f "${core_conf}" ]; then
  LARAVEL_SUBDOMAIN="$(grep -E '^\s*ServerName\s+' "${core_conf}" 2>/dev/null | awk '{print $2}' | head -1)"
 fi
 if [ -f "${web_conf}" ]; then
  HTML5_SUBDOMAIN="$(grep -E '^\s*ServerName\s+' "${web_conf}" 2>/dev/null | awk '{print $2}' | head -1)"
 fi
}

strip_url_host() {
 local url="$1"
 url="${url#https://}"
 url="${url#http://}"
 url="${url%%/*}"
 echo "${url}"
}

detect_subdomains_from_env() {
 [ -f "${LARAVEL_ENV_FILE}" ] || return 1
 local app_url front_url
 app_url="$(grep -m1 '^APP_URL=' "${LARAVEL_ENV_FILE}" | cut -d= -f2- | tr -d '"' | tr -d "'")"
 front_url="$(grep -m1 '^FRONT_URL=' "${LARAVEL_ENV_FILE}" | cut -d= -f2- | tr -d '"' | tr -d "'")"
 [ -n "${app_url}" ] && LARAVEL_SUBDOMAIN="$(strip_url_host "${app_url}")"
 [ -n "${front_url}" ] && HTML5_SUBDOMAIN="$(strip_url_host "${front_url}")"
}

powerps_is_installed() {
 [ -d "${APP_DIR}/.git" ] || [ -d "${APP_DIR}" ]
}

prompt_for_subdomains() {
 while true; do
  read -e -p "Enter your Core subdomain (e.g., core.domain.com): " LARAVEL_SUBDOMAIN
  [[ "${LARAVEL_SUBDOMAIN}" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}$ ]] && break
  log_warn "Invalid domain format. Please try again."
 done
 while true; do
  read -e -p "Enter your WebApp subdomain (e.g., web.domain.com): " HTML5_SUBDOMAIN
  [[ "${HTML5_SUBDOMAIN}" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}$ ]] && break
  log_warn "Invalid domain format. Please try again."
 done
 persist_subdomains
}

resolve_subdomains() {
 if ! load_subdomains_from_file "${SUBDOMAIN_FILE}"; then
  for legacy in "/root/subdomains.conf" "${HOME}/subdomains.conf" "./subdomains.conf"; do
   if load_subdomains_from_file "${legacy}"; then
    log_info "Migrating subdomains from ${legacy} -> ${SUBDOMAIN_FILE}"
    persist_subdomains
    break
   fi
  done
 fi

 if { [ -z "${LARAVEL_SUBDOMAIN:-}" ] || [ -z "${HTML5_SUBDOMAIN:-}" ]; } && powerps_is_installed; then
  detect_subdomains_from_apache
  [ -z "${LARAVEL_SUBDOMAIN:-}" ] || [ -z "${HTML5_SUBDOMAIN:-}" ] && detect_subdomains_from_env || true
  if [ -n "${LARAVEL_SUBDOMAIN:-}" ] && [ -n "${HTML5_SUBDOMAIN:-}" ]; then
   persist_subdomains
   log_info "Detected existing install (${LARAVEL_SUBDOMAIN}, ${HTML5_SUBDOMAIN})"
  fi
 fi

 if [ -n "${LARAVEL_SUBDOMAIN:-}" ] && [ -n "${HTML5_SUBDOMAIN:-}" ]; then
  return 0
 fi

 if powerps_is_installed; then
  log_warn "PowerPs is installed but subdomains were not found."
  log_warn "Enter them once; they will be saved to ${SUBDOMAIN_FILE}"
 fi
 prompt_for_subdomains
}

# ---------------------------------------------------------------------------
# .env helpers
# ---------------------------------------------------------------------------
read_env_value() {
 local key="$1"
 [ -f "${LARAVEL_ENV_FILE}" ] || return 0
 grep -m1 "^${key}=" "${LARAVEL_ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'" | tr -d '[:space:]'
}

ensure_env_file_ready() {
 [ -f "${LARAVEL_ENV_FILE}" ] && [ -s "${LARAVEL_ENV_FILE}" ] || return 0
 if [ "$(tail -c 1 "${LARAVEL_ENV_FILE}" | wc -l)" -eq 0 ]; then
  echo "" >> "${LARAVEL_ENV_FILE}"
 fi
}

set_env_value() {
 local key="$1"
 local value="$2"
 ensure_env_file_ready
 awk -v key="${key}" -v val="${value}" '
  BEGIN { found=0 }
  index($0, key "=") == 1 {
   if (!found) { print key "=" val; found=1 }
   next
  }
  { print }
  END { if (!found) print key "=" val }
 ' "${LARAVEL_ENV_FILE}" > "${LARAVEL_ENV_FILE}.tmp"
 mv "${LARAVEL_ENV_FILE}.tmp" "${LARAVEL_ENV_FILE}"
 ensure_env_file_ready
}

repair_merged_env_lines() {
 [ -f "${LARAVEL_ENV_FILE}" ] || return 0
 sed -i -E 's/(")([A-Z][A-Z0-9_]*)=/\1\n\2=/g' "${LARAVEL_ENV_FILE}" 2>/dev/null || true
 ensure_env_file_ready
}

ensure_laravel_env_file() {
 [ -f "${LARAVEL_ENV_FILE}" ] && return 0
 if [ -f "${APP_DIR}/.env.example" ]; then
  cp "${APP_DIR}/.env.example" "${LARAVEL_ENV_FILE}"
  ensure_env_file_ready
  return 0
 fi
 cat > "${LARAVEL_ENV_FILE}" <<'EOF'
APP_NAME=Laravel
APP_ENV=production
APP_KEY=
APP_DEBUG=true
APP_URL=
FRONT_URL=
LICENSE_CHECK_URL=http://127.0.0.1
LOG_CHANNEL=stack
LOG_LEVEL=debug
DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=
DB_USERNAME=
DB_PASSWORD=
TELEGRAM_BOT_TOKEN=
TELEGRAM_API_ENDPOINT=https://api.telegram.org
TELEGRAM_ADMIN_ID=
ZARINPAL_MERCHANT_ID=
NOWPAYMENTS_API_KEY=
BROADCAST_DRIVER=log
CACHE_DRIVER=file
FILESYSTEM_DISK=local
QUEUE_CONNECTION=sync
SESSION_DRIVER=file
SESSION_LIFETIME=120
EOF
}

normalize_telegram_token() {
 local token="$1"
 token="${token#"${token%%[![:space:]]*}"}"
 token="${token%"${token##*[![:space:]]}"}"
 if [[ "${token}" =~ ^bot[0-9]+:[A-Za-z0-9_-]+$ ]]; then
  echo "${token}"
 elif [[ "${token}" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
  echo "bot${token}"
 else
  echo "${token}"
 fi
}

valid_telegram_token() {
 local token="$1"
 [[ "${token}" =~ ^bot[0-9]{8,}:[A-Za-z0-9_-]{35,}$ ]]
}

prompt_telegram_config() {
 local existing_token existing_admin
 existing_token="$(read_env_value TELEGRAM_BOT_TOKEN || true)"
 existing_admin="$(read_env_value TELEGRAM_ADMIN_ID || true)"

 [ -z "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${existing_token:-}" ] && TELEGRAM_BOT_TOKEN="${existing_token}"
 [ -z "${TELEGRAM_ADMIN_ID:-}" ] && [ -n "${existing_admin:-}" ] && TELEGRAM_ADMIN_ID="${existing_admin}"

 if valid_telegram_token "${TELEGRAM_BOT_TOKEN:-}" && [[ "${TELEGRAM_ADMIN_ID:-}" =~ ^[0-9]{6,}$ ]]; then
  log_info "Telegram bot token and admin ID already configured."
  set_env_value TELEGRAM_BOT_TOKEN "${TELEGRAM_BOT_TOKEN}"
  set_env_value TELEGRAM_ADMIN_ID "${TELEGRAM_ADMIN_ID}"
  set_env_value TELEGRAM_API_ENDPOINT "https://api.telegram.org"
  return 0
 fi

 echo ""
 echo -e "${CYAN}======== Telegram Bot Configuration ========${NC}"
 echo -e "${CYAN}Enter your bot token from @BotFather and your Telegram user ID.${NC}"
 echo ""
 while true; do
  read -e -p "Enter your Bot token (e.g. 123456789:ABC... or bot123456789:ABC...): " TELEGRAM_BOT_TOKEN
  TELEGRAM_BOT_TOKEN="$(normalize_telegram_token "${TELEGRAM_BOT_TOKEN}")"
  valid_telegram_token "${TELEGRAM_BOT_TOKEN}" && break
  log_warn "Invalid bot token format."
 done
 set_env_value TELEGRAM_BOT_TOKEN "${TELEGRAM_BOT_TOKEN}"

 while true; do
  read -e -p "Enter your Bot admin ID (e.g., 123456789): " TELEGRAM_ADMIN_ID
  [[ "${TELEGRAM_ADMIN_ID}" =~ ^[0-9]{6,}$ ]] && break
  log_warn "Invalid admin ID format."
 done
 set_env_value TELEGRAM_ADMIN_ID "${TELEGRAM_ADMIN_ID}"
 set_env_value TELEGRAM_API_ENDPOINT "https://api.telegram.org"
 echo ""
}

setup_laravel_env() {
 log_info "Setting up environment variables..."
 ensure_laravel_env_file
 repair_merged_env_lines

 if [ ! -s "${LARAVEL_ENV_FILE}" ] || ! grep -q '^APP_NAME=' "${LARAVEL_ENV_FILE}"; then
  log_warn ".env was missing or incomplete; recreating base settings."
  rm -f "${LARAVEL_ENV_FILE}"
  ensure_laravel_env_file
 fi

 set_env_value APP_NAME "Laravel"
 set_env_value APP_ENV "production"
 grep -q '^APP_KEY=.\+' "${LARAVEL_ENV_FILE}" || set_env_value APP_KEY ""
 set_env_value APP_DEBUG "true"
 set_env_value APP_URL "https://${LARAVEL_SUBDOMAIN}"
 set_env_value FRONT_URL "https://${HTML5_SUBDOMAIN}"
 set_env_value DB_CONNECTION "mysql"
 set_env_value DB_HOST "127.0.0.1"
 set_env_value DB_PORT "3306"
 set_env_value DB_DATABASE "${DB_NAME}"
 set_env_value DB_USERNAME "${DB_USER}"
 set_env_value DB_PASSWORD "${DB_PASS}"

 prompt_telegram_config

 local existing_zarinpal existing_nowpayments
 existing_zarinpal="$(read_env_value ZARINPAL_MERCHANT_ID || true)"
 if [ -z "${existing_zarinpal:-}" ]; then
  read -e -p "Enter your Zarinpal Merchant ID (optional, press Enter to skip): " ZARINPAL_MERCHANT_ID
  if [ -n "${ZARINPAL_MERCHANT_ID:-}" ] && [[ "${ZARINPAL_MERCHANT_ID}" =~ ^[a-zA-Z0-9]{8}-[a-zA-Z0-9]{4}-[a-zA-Z0-9]{4}-[a-zA-Z0-9]{4}-[a-zA-Z0-9]{12}$ ]]; then
   set_env_value ZARINPAL_MERCHANT_ID "${ZARINPAL_MERCHANT_ID}"
  else
   set_env_value ZARINPAL_MERCHANT_ID ""
  fi
 fi

 existing_nowpayments="$(read_env_value NOWPAYMENTS_API_KEY || true)"
 if [ -z "${existing_nowpayments:-}" ]; then
  read -e -p "Enter your NOWPAYMENTS API KEY (optional, press Enter to skip): " NOWPAYMENTS_API_KEY
  if [ -n "${NOWPAYMENTS_API_KEY:-}" ] && [[ "${NOWPAYMENTS_API_KEY}" =~ ^[A-Za-z0-9-]{36}$ ]]; then
   set_env_value NOWPAYMENTS_API_KEY "${NOWPAYMENTS_API_KEY}"
  else
   set_env_value NOWPAYMENTS_API_KEY ""
  fi
 fi

 sudo chown www-data:www-data "${LARAVEL_ENV_FILE}" 2>/dev/null || true
 sudo chmod 600 "${LARAVEL_ENV_FILE}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# System packages
# ---------------------------------------------------------------------------
ensure_ondrej_php_ppa() {
 local codename=""
 if grep -Rqs 'ppa.launchpadcontent.net/ondrej/php' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
  log_info "ondrej/php PPA already configured."
  return 0
 fi
 codename="$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}")"
 [ -z "${codename}" ] && codename="$(lsb_release -sc 2>/dev/null || true)"
 if [ -z "${codename}" ]; then
  die "Could not detect Ubuntu codename for ondrej/php PPA."
 fi
 if sudo add-apt-repository -y ppa:ondrej/php 2>/dev/null; then
  return 0
 fi
 log_warn "add-apt-repository failed; adding PPA list directly."
 echo "deb https://ppa.launchpadcontent.net/ondrej/php/ubuntu ${codename} main" | \
  sudo tee "/etc/apt/sources.list.d/ondrej-ubuntu-php-${codename}.list" >/dev/null
}

install_base_packages() {
 log_info "Installing system packages..."
 sudo apt-get update
 sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  software-properties-common curl openssl ca-certificates \
  apache2 mysql-server composer unzip git cron \
  python3-certbot-apache certbot \
  php-imagick libmagickwand-dev || die "Failed to install base packages."
 ensure_ondrej_php_ppa
 sudo apt-get update
}

install_php_packages() {
 log_info "Installing PHP ${PHP_VERSION} extensions..."
 sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  "php${PHP_VERSION}" "php${PHP_VERSION}-mysql" "libapache2-mod-php${PHP_VERSION}" \
  "php${PHP_VERSION}-cli" "php${PHP_VERSION}-zip" "php${PHP_VERSION}-xml" "php${PHP_VERSION}-dom" \
  "php${PHP_VERSION}-mbstring" "php${PHP_VERSION}-curl" "php${PHP_VERSION}-gd" \
  "php${PHP_VERSION}-bcmath" "php${PHP_VERSION}-intl" "php${PHP_VERSION}-imagick" \
  "php${PHP_VERSION}-readline" || die "Failed to install PHP ${PHP_VERSION} packages."

 sudo update-alternatives --install /usr/bin/php php "/usr/bin/php${PHP_VERSION}" 100 2>/dev/null || true
 sudo update-alternatives --set php "/usr/bin/php${PHP_VERSION}" 2>/dev/null || true
 sudo ln -sfn "/usr/bin/php${PHP_VERSION}" /usr/bin/php 2>/dev/null || true
 sudo ln -sfn "/usr/bin/php${PHP_VERSION}" /usr/local/bin/php 2>/dev/null || true
 sudo a2enmod "php${PHP_VERSION}" 2>/dev/null || true
 hash -r 2>/dev/null || true
 export PATH="/usr/bin:/bin:/sbin:${PATH}"
}

detect_php_version() {
 local version_file="${APP_DIR}/.powerps-php-version"
 if [ -f "${version_file}" ]; then
  tr -d '[:space:]' < "${version_file}"
  return 0
 fi
 echo "8.4"
}

# ---------------------------------------------------------------------------
# MySQL — fully automatic (no prompts)
# ---------------------------------------------------------------------------
ensure_mysql_running() {
 log_info "Ensuring MySQL is running..."
 sudo mkdir -p /var/run/mysqld
 sudo chown mysql:mysql /var/run/mysqld 2>/dev/null || true
 if ! start_service mysql; then
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -f -y || true
  sudo dpkg --configure -a || true
  systemctl daemon-reload 2>/dev/null || true
  start_service mysql || die "MySQL failed to start. Check: journalctl -xeu mysql.service"
 fi
 enable_service mysql

 local i
 for i in $(seq 1 30); do
  if [ -S /var/run/mysqld/mysqld.sock ] || [ -S /var/lib/mysql/mysql.sock ]; then
   return 0
  fi
  sleep 1
 done
 die "MySQL socket not available after 30s."
}

load_db_password() {
 if [ -f "${LARAVEL_ENV_FILE}" ]; then
  DB_PASS="$(grep -m1 '^DB_PASSWORD=' "${LARAVEL_ENV_FILE}" | cut -d= -f2- | tr -d '"' | tr -d "'")"
 fi
 if [ -z "${DB_PASS:-}" ]; then
  DB_PASS="$(openssl rand -base64 12 | tr -d '/+=' | head -c 16)"
 fi
}

setup_powerps_database() {
 log_info "Creating MySQL database and user (automatic)..."
 load_db_password

 sudo mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
}

# ---------------------------------------------------------------------------
# phpBolt — install only when missing (no re-check loop on update)
# ---------------------------------------------------------------------------
pick_bolt_source() {
 local arch
 arch="$(uname -m)"
 case "${arch}" in
  x86_64|amd64)
   [ -f "${APP_DIR}/bolt-x86_64.so" ] && echo "${APP_DIR}/bolt-x86_64.so" && return
   [ -f "${APP_DIR}/bolt.so" ] && echo "${APP_DIR}/bolt.so" && return
   ;;
  aarch64|arm64)
   [ -f "${APP_DIR}/bolt-aarch64.so" ] && echo "${APP_DIR}/bolt-aarch64.so" && return
   [ -f "${APP_DIR}/bolt.so" ] && echo "${APP_DIR}/bolt.so" && return
   ;;
  *)
   [ -f "${APP_DIR}/bolt.so" ] && echo "${APP_DIR}/bolt.so" && return
   ;;
 esac
}

resolve_php_extension_dir() {
 local php_ext_dir
 php_ext_dir="$(trim_whitespace "$("$(php_bin)" -n -i 2>/dev/null | awk -F'=> ' '/^extension_dir/{print $2; exit}')")"
 if [ -z "${php_ext_dir}" ]; then
  case "${PHP_VERSION}" in
   8.4) php_ext_dir="/usr/lib/php/20240924" ;;
   8.3) php_ext_dir="/usr/lib/php/20230831" ;;
   *) php_ext_dir="/usr/lib/php/${PHP_VERSION}" ;;
  esac
 fi
 echo "${php_ext_dir}"
}

phpbolt_loaded() {
 "$(php_bin)" -r 'exit(function_exists("bolt_decrypt") ? 0 : 1);' 2>/dev/null
}

cleanup_old_bolt_config() {
 local php_ext_dir cli_conf_dir apache_conf_dir ini_file
 php_ext_dir="$(resolve_php_extension_dir)"
 cli_conf_dir="/etc/php/${PHP_VERSION}/cli/conf.d"
 apache_conf_dir="/etc/php/${PHP_VERSION}/apache2/conf.d"
 ini_file="/etc/php/${PHP_VERSION}/mods-available/bolt.ini"

 sudo rm -f \
  "${cli_conf_dir}/99-bolt.ini" \
  "${apache_conf_dir}/99-bolt.ini" \
  "${cli_conf_dir}"/*bolt*.ini \
  "${apache_conf_dir}"/*bolt*.ini \
  "${ini_file}" \
  "${php_ext_dir}/bolt.so" 2>/dev/null || true
 if command -v phpdismod >/dev/null 2>&1; then
  sudo phpdismod -v "${PHP_VERSION}" bolt 2>/dev/null || true
 fi
 # Previous installs could copy bolt.so into a dir with trailing whitespace in the path.
 sudo rm -f "${php_ext_dir} /bolt.so" 2>/dev/null || true
 sudo rmdir "${php_ext_dir} " 2>/dev/null || true
}

report_phpbolt_load_failure() {
 local php_ext_dir cli_conf_dir err_file="/tmp/powerps-bolt-load.err"
 php_ext_dir="$(resolve_php_extension_dir)"
 cli_conf_dir="/etc/php/${PHP_VERSION}/cli/conf.d"

 log_error "phpBolt failed to load in $(php_bin)."
 log_error "--- $(php_bin) startup errors ---"
 [ -f "${err_file}" ] && cat "${err_file}" >&2 || true
 log_error "--- $(php_bin) --ini ---"
 "$(php_bin)" --ini 2>&1 | head -20 >&2 || true
 log_error "--- ${cli_conf_dir}/99-bolt.ini ---"
 cat "${cli_conf_dir}/99-bolt.ini" 2>&1 >&2 || true
 log_error "--- extension file ---"
 ls -la "${php_ext_dir}/bolt.so" 2>&1 >&2 || true
 file "${php_ext_dir}/bolt.so" 2>&1 >&2 || true
 log_error "--- direct load test ---"
 "$(php_bin)" -n -d "extension=${php_ext_dir}/bolt.so" -r 'echo function_exists("bolt_decrypt")?"OK":"FAIL";' 2>&1 >&2 || true
 log_error "Try: sudo bash fix-phpbolt.sh"
 rm -f "${err_file}"
}

install_phpbolt() {
 if phpbolt_loaded; then
  log_info "phpBolt already loaded; skipping."
  return 0
 fi

 local bolt_src php_ext_dir cli_conf_dir apache_conf_dir err_file="/tmp/powerps-bolt-load.err"
 bolt_src="$(pick_bolt_source)"
 [ -n "${bolt_src}" ] && [ -f "${bolt_src}" ] || die "bolt.so not found in ${APP_DIR}"

 if ! "$(php_bin)" -n -d "extension=${bolt_src}" -r 'exit(function_exists("bolt_decrypt")?0:1);' 2>"${err_file}"; then
  log_error "bolt binary is incompatible with $(php_bin)."
  [ -s "${err_file}" ] && cat "${err_file}" >&2 || true
  rm -f "${err_file}"
  die "bolt binary is incompatible with $(php_bin). Check: file ${bolt_src} && ldd ${bolt_src}"
 fi
 rm -f "${err_file}"

 php_ext_dir="$(resolve_php_extension_dir)"
 cli_conf_dir="/etc/php/${PHP_VERSION}/cli/conf.d"
 apache_conf_dir="/etc/php/${PHP_VERSION}/apache2/conf.d"

 log_info "Installing phpBolt from ${bolt_src}..."
 log_info "PHP extension dir: ${php_ext_dir}"
 cleanup_old_bolt_config

 sudo mkdir -p "${php_ext_dir}" "${cli_conf_dir}" "${apache_conf_dir}"
 sudo cp "${bolt_src}" "${php_ext_dir}/bolt.so"
 sudo chmod 644 "${php_ext_dir}/bolt.so"

 if ! "$(php_bin)" -n -d "extension=${php_ext_dir}/bolt.so" -r 'exit(function_exists("bolt_decrypt")?0:1);' 2>"${err_file}"; then
  log_error "Copied bolt.so cannot load from ${php_ext_dir}."
  report_phpbolt_load_failure
  die "phpBolt copy failed in ${php_ext_dir}."
 fi
 rm -f "${err_file}"

 # Relative name — avoids duplicate/conflicting absolute-path ini entries.
 echo "extension=bolt.so" | sudo tee "${cli_conf_dir}/99-bolt.ini" >/dev/null
 echo "extension=bolt.so" | sudo tee "${apache_conf_dir}/99-bolt.ini" >/dev/null

 hash -r 2>/dev/null || true

 if ! phpbolt_loaded 2>"${err_file}"; then
  report_phpbolt_load_failure
  die "phpBolt failed to load in $(php_bin)."
 fi
 rm -f "${err_file}"

 if ! php -r 'exit(function_exists("bolt_decrypt") ? 0 : 1);' 2>/dev/null; then
  log_warn "Default 'php' does not load phpBolt; migrations use $(php_bin) artisan."
 else
  log_info "Default php loads phpBolt."
 fi
 log_info "phpBolt installed."
}

# ---------------------------------------------------------------------------
# Repositories
# ---------------------------------------------------------------------------
update_laravel_repo() {
 local backup_dir="/tmp/powerps-core-update-$(date +%Y%m%d%H%M%S)"
 log_info "Updating powerps-core (git)..."
 mkdir -p "${backup_dir}"
 [ -f "${APP_DIR}/.env" ] && cp "${APP_DIR}/.env" "${backup_dir}/.env"
 [ -d "${APP_DIR}/public/images/qrcodes" ] && cp -a "${APP_DIR}/public/images/qrcodes" "${backup_dir}/" || true
 [ -d "${APP_DIR}/public/images/transaction_images" ] && cp -a "${APP_DIR}/public/images/transaction_images" "${backup_dir}/" || true

 cd "${APP_DIR}"
 git fetch origin main
 git reset --hard origin/main

 [ -f "${backup_dir}/.env" ] && cp "${backup_dir}/.env" "${APP_DIR}/.env"
 if [ -d "${backup_dir}/qrcodes" ]; then
  mkdir -p "${APP_DIR}/public/images/qrcodes"
  cp -a "${backup_dir}/qrcodes/." "${APP_DIR}/public/images/qrcodes/"
 fi
 if [ -d "${backup_dir}/transaction_images" ]; then
  mkdir -p "${APP_DIR}/public/images/transaction_images"
  cp -a "${backup_dir}/transaction_images/." "${APP_DIR}/public/images/transaction_images/"
 fi
 rm -rf "${backup_dir}"
}

sync_laravel_repo() {
 if [ -d "${APP_DIR}/.git" ]; then
  update_laravel_repo
 else
  log_info "Cloning powerps-core..."
  run_with_retry "git clone https://github.com/rezahajrahimi/powerps-core ${APP_DIR}" 3 5 \
   || die "Failed to clone powerps-core."
 fi
 cd "${APP_DIR}"
}

sync_webapp_repo() {
 local web_env_backup="/tmp/powerps-webapp-env-$(date +%Y%m%d%H%M%S)"
 if [ -f "${WEBAPP_DIR}/assets/.env" ]; then
  cp "${WEBAPP_DIR}/assets/.env" "${web_env_backup}"
 fi

 if [ -d "${WEBAPP_DIR}/.git" ]; then
  log_info "Updating powerps-webapp (git)..."
  cd "${WEBAPP_DIR}"
  git fetch origin main
  git reset --hard origin/main
 else
  log_info "Cloning powerps-webapp..."
  run_with_retry "git clone https://github.com/rezahajrahimi/powerps-webapp ${WEBAPP_DIR}" 3 5 \
   || die "Failed to clone powerps-webapp."
 fi

 mkdir -p "${WEBAPP_DIR}/assets"
 if [ -f "${web_env_backup}" ]; then
  cp "${web_env_backup}" "${WEBAPP_DIR}/assets/.env"
  rm -f "${web_env_backup}"
 else
  echo "BASE_URL=https://${LARAVEL_SUBDOMAIN}" > "${WEBAPP_DIR}/assets/.env"
 fi
 sudo chown www-data:www-data "${WEBAPP_DIR}/assets/.env" 2>/dev/null || true
 sudo chmod 640 "${WEBAPP_DIR}/assets/.env" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Laravel app setup
# ---------------------------------------------------------------------------
ensure_laravel_directories() {
 local dir
 for dir in \
  "${APP_DIR}/storage" "${APP_DIR}/storage/app" \
  "${APP_DIR}/storage/framework" "${APP_DIR}/storage/framework/cache" \
  "${APP_DIR}/storage/framework/sessions" "${APP_DIR}/storage/framework/views" \
  "${APP_DIR}/storage/logs" "${APP_DIR}/bootstrap/cache" \
  "${APP_DIR}/public/images" "${APP_DIR}/public/images/qrcodes" \
  "${APP_DIR}/public/images/transaction_images"
 do
  sudo mkdir -p "${dir}"
 done
}

fix_laravel_permissions() {
 log_info "Setting Laravel permissions..."
 ensure_laravel_directories
 sudo chown -R www-data:www-data "${APP_DIR}/storage" "${APP_DIR}/bootstrap/cache" \
  "${APP_DIR}/public" "${APP_DIR}/public/images" 2>/dev/null || true
 sudo chmod -R 775 "${APP_DIR}/storage" "${APP_DIR}/bootstrap/cache" \
  "${APP_DIR}/public" "${APP_DIR}/public/images" 2>/dev/null || true
}

sanitize_release_composer_json() {
 local composer_file="$1"
 [ -f "${composer_file}" ] || return 0
 "$(php_bin)" -r '
$path = $argv[1];
$data = json_decode(file_get_contents($path), true);
if (!is_array($data)) { exit(1); }
unset($data["require-dev"]["sbamtr/laravel-source-encrypter"]);
if (isset($data["autoload-dev"]["psr-4"]["sbamtr\\LaravelSourceEncrypter\\"])) {
 unset($data["autoload-dev"]["psr-4"]["sbamtr\\LaravelSourceEncrypter\\"]);
}
if (!empty($data["repositories"])) {
 $data["repositories"] = array_values(array_filter(
  $data["repositories"],
  fn($repo) => ($repo["type"] ?? "") !== "path"
 ));
}
file_put_contents($path, json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
' "${composer_file}"
}

install_composer_dependencies() {
 log_info "Installing Composer dependencies..."
 cd "${APP_DIR}"
 export COMPOSER_ALLOW_SUPERUSER=1

 if ! "$(php_bin)" "${COMPOSER_BIN}" validate --no-check-publish --no-interaction >/dev/null 2>&1; then
  log_warn "Composer lock out of sync; fixing composer.json for production..."
  sanitize_release_composer_json "${APP_DIR}/composer.json"
  "$(php_bin)" "${COMPOSER_BIN}" update --lock --no-install --no-dev --no-interaction \
   --ignore-platform-reqs --no-scripts >/dev/null 2>&1 || true
 fi

 local install_cmd
 install_cmd="$(php_bin) ${COMPOSER_BIN} install --no-dev --no-interaction --no-progress --prefer-dist --optimize-autoloader --no-scripts"

 if ! run_with_retry "${install_cmd}" 3 5; then
  log_warn "Composer install failed; retrying with --ignore-platform-reqs..."
  run_with_retry "${install_cmd} --ignore-platform-reqs" 3 5 \
   || die "Composer install failed. Run: cd ${APP_DIR} && $(php_bin) ${COMPOSER_BIN} validate"
 fi

 "$(php_bin)" "${COMPOSER_BIN}" dump-autoload --no-dev --optimize --no-interaction \
  --ignore-platform-reqs --no-scripts >/dev/null 2>&1 || true
}

run_laravel_artisan_steps() {
 log_info "Running Laravel setup (key, migrate, storage)..."
 cd "${APP_DIR}"

 if grep -qE '^APP_KEY=base64:.+' "${LARAVEL_ENV_FILE}"; then
  log_info "APP_KEY already set; skipping key generation."
 else
  "$(php_bin)" artisan key:generate --force --no-interaction
 fi

 if ! "$(php_bin)" artisan migrate --force --no-interaction; then
  die "Migration failed. Check DB credentials in ${LARAVEL_ENV_FILE}"
 fi

 "$(php_bin)" artisan storage:link --force --no-interaction 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Apache / SSL / services
# ---------------------------------------------------------------------------
setup_apache_vhosts() {
 log_info "Configuring Apache virtual hosts..."
 sudo bash -c "cat > /etc/apache2/sites-available/powerps-core.conf" <<EOT
<VirtualHost *:80>
    ServerName ${LARAVEL_SUBDOMAIN}
    DocumentRoot ${APP_DIR}/public
    <Directory ${APP_DIR}/public>
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/laravel-error.log
    CustomLog \${APACHE_LOG_DIR}/laravel-access.log combined
</VirtualHost>
EOT

 sudo bash -c "cat > /etc/apache2/sites-available/powerps-webapp.conf" <<EOT
<VirtualHost *:80>
    ServerName ${HTML5_SUBDOMAIN}
    DocumentRoot ${WEBAPP_DIR}
    <Directory ${WEBAPP_DIR}>
        AllowOverride All
        Options Indexes FollowSymLinks
        Require all granted
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/html5-error.log
    CustomLog \${APACHE_LOG_DIR}/html5-access.log combined
</VirtualHost>
EOT

 sudo a2ensite powerps-core powerps-webapp 2>/dev/null || true
 sudo a2enmod rewrite 2>/dev/null || true
 restart_service apache2 2>/dev/null || true
}

install_phpmyadmin_if_missing() {
 if [ -d "/var/www/html/phpmyadmin" ]; then
  log_info "phpMyAdmin already installed."
  return 0
 fi
 log_info "Installing phpMyAdmin..."
 cd /var/www/html
 run_with_retry "wget -q https://www.phpmyadmin.net/downloads/phpMyAdmin-latest-all-languages.zip -O phpMyAdmin.zip" 3 5 \
  || { log_warn "phpMyAdmin download failed; skipping."; return 0; }
 unzip -q phpMyAdmin.zip && mv phpMyAdmin-*-all-languages phpmyadmin && rm -f phpMyAdmin.zip || log_warn "phpMyAdmin install failed; skipping."
}

setup_ssl() {
 local email="${1:-}"
 log_info "Setting up SSL certificates..."
 if ! command -v certbot >/dev/null 2>&1; then
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3-certbot-apache certbot
 fi
 if [ -z "${email}" ]; then
  read -e -p "Enter email for Let's Encrypt (Enter for admin@${LARAVEL_SUBDOMAIN#*.}): " email
 fi
 email="${email:-admin@${LARAVEL_SUBDOMAIN#*.}}"
 for domain in "${LARAVEL_SUBDOMAIN}" "${HTML5_SUBDOMAIN}"; do
  if [ -d "/etc/letsencrypt/live/${domain}" ]; then
   log_info "Certificate already exists for ${domain}."
   continue
  fi
  run_with_retry "sudo certbot --apache --non-interactive --agree-tos --email ${email} -d ${domain} --redirect" 2 5 \
   || log_warn "SSL failed for ${domain}. Run certbot manually later."
 done
}

setup_ssl_auto() {
 setup_ssl "admin@${LARAVEL_SUBDOMAIN#*.}"
}

setup_cron_and_queue() {
 log_info "Setting up cron and queue worker..."

 if ! command -v crontab >/dev/null 2>&1; then
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y cron || log_warn "Could not install cron package."
 fi

 local cron_job="* * * * * cd ${APP_DIR} && /usr/bin/php${PHP_VERSION} artisan schedule:run >> /dev/null 2>&1"
 if command -v crontab >/dev/null 2>&1; then
  (crontab -l 2>/dev/null | grep -v "artisan schedule:run"; echo "${cron_job}") | crontab - \
   || log_warn "Could not install Laravel schedule cron job."
  (crontab -l 2>/dev/null | grep -v "@reboot systemctl restart apache2"; echo "@reboot systemctl restart apache2") | crontab - \
   || true
  (crontab -l 2>/dev/null | grep -v "@reboot systemctl restart mysql"; echo "@reboot systemctl restart mysql") | crontab - \
   || true
 else
  log_warn "crontab not available; skipping schedule cron jobs."
 fi

 sudo tee /etc/systemd/system/laravel-queue.service >/dev/null <<EOL
[Unit]
Description=Laravel Queue Worker
After=network.target mysql.service apache2.service

[Service]
User=www-data
Group=www-data
Restart=always
RestartSec=5
ExecStart=/usr/bin/php${PHP_VERSION} ${APP_DIR}/artisan queue:work --sleep=3 --tries=3 --timeout=0
StandardOutput=append:/var/log/laravel-queue.log
StandardError=append:/var/log/laravel-queue.error.log

[Install]
WantedBy=multi-user.target
EOL

 if [ ! -f /etc/systemd/system/laravel-queue.service ]; then
  die "Failed to create /etc/systemd/system/laravel-queue.service"
 fi

 sudo touch /var/log/laravel-queue.log /var/log/laravel-queue.error.log
 sudo chown www-data:www-data /var/log/laravel-queue.log /var/log/laravel-queue.error.log

 if command -v systemctl >/dev/null 2>&1; then
  sudo systemctl daemon-reload
  if ! sudo systemctl enable --now laravel-queue; then
   log_warn "Could not start laravel-queue via systemctl. Check: journalctl -u laravel-queue -n 30"
  else
   log_info "laravel-queue service enabled."
  fi
 else
  log_warn "systemctl not available; laravel-queue unit file created but not started."
 fi

 sudo tee /etc/systemd/system/certbot-renew.service >/dev/null <<'EOL'
[Unit]
Description=Run Certbot renewal and reload Apache
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew --quiet --post-hook 'systemctl reload apache2'
EOL

 sudo tee /etc/systemd/system/certbot-renew.timer >/dev/null <<'EOL'
[Unit]
Description=Daily Certbot renewal

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=3600

[Install]
WantedBy=timers.target
EOL

 if command -v systemctl >/dev/null 2>&1; then
  sudo systemctl daemon-reload
  sudo systemctl enable --now certbot-renew.timer 2>/dev/null || log_warn "Could not enable certbot-renew.timer."
 fi
}

setup_telegram_webhook() {
 log_info "Setting up Telegram webhook..."
 [ -n "${TELEGRAM_BOT_TOKEN:-}" ] || TELEGRAM_BOT_TOKEN="$(read_env_value TELEGRAM_BOT_TOKEN || true)"
 if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
  log_warn "Telegram bot token not set; skipping webhook."
  return 0
 fi
 local webhook_url="https://${LARAVEL_SUBDOMAIN}/api/telegram/webhooks/inbound"
 local response
 response="$(curl -s "https://api.telegram.org/${TELEGRAM_BOT_TOKEN}/setWebhook?url=${webhook_url}")"
 if [[ "${response}" == *'"ok":true'* ]]; then
  log_info "Telegram webhook set: ${webhook_url}"
 else
  log_warn "Failed to set Telegram webhook. Set manually later."
 fi
}

add_hosts_entries() {
 for domain in "${LARAVEL_SUBDOMAIN}" "${HTML5_SUBDOMAIN}"; do
  grep -q "${domain}" /etc/hosts 2>/dev/null || echo "127.0.0.1 ${domain}" | sudo tee -a /etc/hosts >/dev/null
 done
}

# ---------------------------------------------------------------------------
# Main install / update pipeline
# ---------------------------------------------------------------------------
run_install_or_update() {
 log_info "=== PowerPs install / update started ==="

 install_base_packages
 ensure_mysql_running
 setup_powerps_database

 sync_laravel_repo
 PHP_VERSION="$(detect_php_version)"
 export PATH="/usr/bin:/bin:/sbin:${PATH}"
 log_info "Target PHP version: ${PHP_VERSION}"
 [ -f "${APP_DIR}/.powerps-bolt-version" ] && \
  log_info "phpBolt version: $(tr -d '[:space:]' < "${APP_DIR}/.powerps-bolt-version")"

 install_php_packages
 install_phpbolt
 fix_laravel_permissions
 restart_service apache2 2>/dev/null || true

 install_composer_dependencies
 setup_laravel_env
 run_laravel_artisan_steps

 install_phpmyadmin_if_missing
 sync_webapp_repo
 setup_apache_vhosts
 add_hosts_entries
 setup_ssl_auto
 setup_cron_and_queue
 setup_telegram_webhook

 echo ""
 echo -e "${CYAN}==============================${NC}"
 echo -e "${YELLOW} PowerPs setup complete!${NC}"
 echo -e "${CYAN}==============================${NC}"
 echo -e "${GREEN}Core:   https://${LARAVEL_SUBDOMAIN}${NC}"
 echo -e "${GREEN}WebApp: https://${HTML5_SUBDOMAIN}${NC}"
 log_info "=== PowerPs install / update finished ==="
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
run_uninstall() {
 log_info "Starting uninstall..."
 sudo pkill -f artisan 2>/dev/null || true
 if systemctl list-unit-files 2>/dev/null | grep -q '^laravel-queue\.service'; then
  sudo systemctl stop laravel-queue 2>/dev/null || true
  sudo systemctl disable laravel-queue 2>/dev/null || true
  sudo rm -f /etc/systemd/system/laravel-queue.service
  sudo systemctl daemon-reload 2>/dev/null || true
 fi

 local db_name="${DB_NAME}" db_user="${DB_USER}"
 if [ -f "${LARAVEL_ENV_FILE}" ]; then
  db_name="$(grep '^DB_DATABASE=' "${LARAVEL_ENV_FILE}" | cut -d= -f2- || echo "${DB_NAME}")"
  db_user="$(grep '^DB_USERNAME=' "${LARAVEL_ENV_FILE}" | cut -d= -f2- || echo "${DB_USER}")"
 fi

 [ -d "${APP_DIR}" ] && backup_existing "${APP_DIR}" && sudo rm -rf "${APP_DIR}"
 [ -d "${WEBAPP_DIR}" ] && backup_existing "${WEBAPP_DIR}" && sudo rm -rf "${WEBAPP_DIR}"
 sudo mysql -e "DROP DATABASE IF EXISTS \`${db_name}\`;" 2>/dev/null || true
 sudo mysql -e "DROP USER IF EXISTS '${db_user}'@'localhost';" 2>/dev/null || true
 sudo mysql -e "FLUSH PRIVILEGES;" 2>/dev/null || true

 sudo a2dissite powerps-core powerps-webapp 2>/dev/null || true
 sudo rm -f /etc/apache2/sites-available/powerps-core.conf /etc/apache2/sites-available/powerps-webapp.conf
 restart_service apache2 2>/dev/null || true
 [ -d "/var/www/html/phpmyadmin" ] && sudo rm -rf /var/www/html/phpmyadmin
 crontab -l 2>/dev/null | grep -v 'laravel-app' | grep -v 'powerps' | grep -v 'artisan' | crontab - 2>/dev/null || true
 [ -f "${SUBDOMAIN_FILE}" ] && rm -f "${SUBDOMAIN_FILE}"
 log_info "Uninstall completed."
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
show_menu() {
 echo -e "${YELLOW}Subdomains: ${LARAVEL_SUBDOMAIN}, ${HTML5_SUBDOMAIN}${NC}"
 echo -e "${CYAN}Choose an option:${NC}"
 echo "1) Install / Update"
 echo "2) Uninstall"
 echo "3) SSL Certificate (Certbot only)"
 while true; do
  read -p "Enter choice [1-3]: " choice
  case "${choice}" in
   1) run_install_or_update; return ;;
   2) run_uninstall; exit 0 ;;
   3) setup_ssl; exit 0 ;;
   *) log_warn "Invalid option. Enter 1, 2, or 3." ;;
  esac
 done
}

# ---------------------------------------------------------------------------
# Self-test (offline): POWERPS_SELFTEST=1 bash install.sh
# ---------------------------------------------------------------------------
run_selftests() {
 local tmpdir pass=0 fail=0
 tmpdir="$(mktemp -d)"

 assert() {
  local label="$1" cmd="$2"
  if eval "${cmd}"; then
   echo "  OK  ${label}"
   pass=$((pass + 1))
  else
   echo "  FAIL ${label}"
   fail=$((fail + 1))
  fi
 }

 echo "==> PowerPs install.sh self-test"
 LARAVEL_ENV_FILE="${tmpdir}/.env"
 printf 'VITE_PUSHER_APP_CLUSTER="${PUSHER_APP_CLUSTER}"APP_NAME=Laravel\n' > "${LARAVEL_ENV_FILE}"
 repair_merged_env_lines
 assert "repair_merged_env_lines splits merged keys" "grep -q '^APP_NAME=Laravel' '${LARAVEL_ENV_FILE}'"

 set_env_value APP_NAME "PowerPs"
 set_env_value DB_PASSWORD "abc/+=special"
 assert "set_env_value updates APP_NAME" "grep -q '^APP_NAME=PowerPs' '${LARAVEL_ENV_FILE}'"
 assert "set_env_value keeps special chars" "grep -q '^DB_PASSWORD=abc/+=special' '${LARAVEL_ENV_FILE}'"

 assert "normalize bot prefix" "[[ \"\$(normalize_telegram_token '12345678901234:AAEDQ8rH0ki0UCEM3Cmv1qQhGRE8_HRoeyo')\" == bot12345678901234:AAEDQ8rH0ki0UCEM3Cmv1qQhGRE8_HRoeyo ]]"
 assert "valid_telegram_token accepts bot token" "valid_telegram_token 'bot12345678901234:AAEDQ8rH0ki0UCEM3Cmv1qQhGRE8_HRoeyo'"

 local script_dir core_dir
 script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
 core_dir="${POWERPS_CORE_DIR:-${script_dir}/../powerps-core}"
 if [ -f "${core_dir}/bolt.so" ] || [ -f "${core_dir}/bolt-x86_64.so" ]; then
  APP_DIR="${core_dir}"
  assert "pick_bolt_source finds bolt" "[ -n \"\$(pick_bolt_source)\" ]"
 fi

 if [ -f "${core_dir}/composer.json" ]; then
  cp "${core_dir}/composer.json" "${tmpdir}/composer.json"
  sanitize_release_composer_json "${tmpdir}/composer.json"
  assert "sanitize removes encrypter from composer.json" "! grep -q 'laravel-source-encrypter' '${tmpdir}/composer.json'"
 fi

 rm -rf "${tmpdir}"
 echo ""
 echo "Self-test: ${pass} passed, ${fail} failed"
 [ "${fail}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------
if [[ "${POWERPS_SELFTEST:-}" == "1" ]]; then
 run_selftests
 exit $?
fi

if [[ "${POWERPS_AUTO_INSTALL:-}" == "1" ]]; then
 init_logging
 echo -e "${CYAN}==============================${NC}"
 echo -e "${YELLOW} PowerPs auto-install mode${NC}"
 echo -e "${CYAN}==============================${NC}"
 resolve_subdomains
 [ -n "${POWERPS_BOT_TOKEN:-}" ] && TELEGRAM_BOT_TOKEN="${POWERPS_BOT_TOKEN}"
 [ -n "${POWERPS_ADMIN_ID:-}" ] && TELEGRAM_ADMIN_ID="${POWERPS_ADMIN_ID}"
 run_install_or_update
 exit 0
fi

init_logging

echo -e "${CYAN}==============================${NC}"
echo -e "${YELLOW} PowerPs Core + WebApp Installer${NC}"
echo -e "${CYAN}==============================${NC}"

free_space="$(df -m / | awk 'NR==2 {print $4}')"
if [ "${free_space}" -lt 500 ]; then
 die "Not enough disk space (need at least 500MB free)."
elif [ "${free_space}" -lt 1000 ]; then
 log_warn "Low disk space (${free_space}MB free)."
fi

resolve_subdomains
show_menu
