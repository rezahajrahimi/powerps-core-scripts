#!/bin/bash

# Color codes
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Fail fast and safer shell options
set -o errexit
set -o nounset
set -o pipefail

# Error handler
error_handler() {
 local exit_code=$?
 echo -e "${RED}Error: Script exited with code ${exit_code}${NC}"
 echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Script exited with code ${exit_code}" | sudo tee -a /var/log/powerps_install.log >/dev/null
 exit ${exit_code}
}
trap error_handler ERR

# Ensure log file exists and is writable
sudo mkdir -p /var/log
sudo touch /var/log/powerps_install.log
sudo chown $(whoami):$(whoami) /var/log/powerps_install.log
sudo chmod 640 /var/log/powerps_install.log

# Helper: check command result and log
check_command() {
 if [ $? -ne 0 ]; then
 echo -e "${RED}$1${NC}"
 echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" | sudo tee -a /var/log/powerps_install.log >/dev/null
 exit 1
 fi
}

# Backup helper (defined globally so any path can call it)
backup_existing() {
 if [ -d "$1" ]; then
 backup_dir="${1}_backup_$(date +%Y%m%d_%H%M%S)"
 mv "$1" "$backup_dir"
 echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backed up $1 to $backup_dir" | sudo tee -a /var/log/powerps_install.log >/dev/null
 fi
}

# Update existing powerps-core checkout without failing on server-side file drift
update_powerps_core_repo() {
 local app_dir="/var/www/html/laravel-app"
 local backup_dir="/tmp/powerps-core-update-$(date +%Y%m%d%H%M%S)"

 echo -e "${GREEN}Updating the Laravel project repository...${NC}"
 mkdir -p "${backup_dir}"

 if [ -f "${app_dir}/.env" ]; then
 cp "${app_dir}/.env" "${backup_dir}/.env"
 fi
 if [ -d "${app_dir}/public/images/qrcodes" ]; then
 cp -a "${app_dir}/public/images/qrcodes" "${backup_dir}/"
 fi
 if [ -d "${app_dir}/public/images/transaction_images" ]; then
 cp -a "${app_dir}/public/images/transaction_images" "${backup_dir}/"
 fi

 cd "${app_dir}"
 git fetch origin main
 git reset --hard origin/main

 if [ -f "${backup_dir}/.env" ]; then
 cp "${backup_dir}/.env" "${app_dir}/.env"
 fi
 if [ -d "${backup_dir}/qrcodes" ]; then
 mkdir -p "${app_dir}/public/images/qrcodes"
 cp -a "${backup_dir}/qrcodes/." "${app_dir}/public/images/qrcodes/"
 fi
 if [ -d "${backup_dir}/transaction_images" ]; then
 mkdir -p "${app_dir}/public/images/transaction_images"
 cp -a "${backup_dir}/transaction_images/." "${app_dir}/public/images/transaction_images/"
 fi

 rm -rf "${backup_dir}"
 echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: powerps-core updated to origin/main" | sudo tee -a /var/log/powerps_install.log >/dev/null
}

LARAVEL_ENV_FILE="/var/www/html/laravel-app/.env"

read_env_value() {
 local key="$1"
 if [ ! -f "${LARAVEL_ENV_FILE}" ]; then
 return 0
 fi
 grep -m1 "^${key}=" "${LARAVEL_ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'" | tr -d '[:space:]'
}

set_env_value() {
 local key="$1"
 local value="$2"
 ensure_env_file_ready
 awk -v key="${key}" -v val="${value}" '
  BEGIN { found=0 }
  index($0, key "=") == 1 {
   if (!found) {
    print key "=" val
    found=1
   }
   next
  }
  { print }
  END { if (!found) print key "=" val }
 ' "${LARAVEL_ENV_FILE}" > "${LARAVEL_ENV_FILE}.tmp"
 mv "${LARAVEL_ENV_FILE}.tmp" "${LARAVEL_ENV_FILE}"
 ensure_env_file_ready
}

ensure_env_file_ready() {
 if [ ! -f "${LARAVEL_ENV_FILE}" ]; then
 return 0
 fi
 if [ ! -s "${LARAVEL_ENV_FILE}" ]; then
 return 0
 fi
 if [ "$(tail -c 1 "${LARAVEL_ENV_FILE}" | wc -l)" -eq 0 ]; then
 echo "" >> "${LARAVEL_ENV_FILE}"
 fi
}

repair_merged_env_lines() {
 if [ ! -f "${LARAVEL_ENV_FILE}" ]; then
 return 0
 fi
 # Fix missing newlines, e.g. ..."${PUSHER_APP_CLUSTER}"APP_NAME=Laravel
 sed -i -E 's/(")([A-Z][A-Z0-9_]*)=/\1\n\2=/g' "${LARAVEL_ENV_FILE}" 2>/dev/null || true
 ensure_env_file_ready
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

 if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${existing_token:-}" ]; then
 TELEGRAM_BOT_TOKEN="${existing_token}"
 fi
 if [ -z "${TELEGRAM_ADMIN_ID:-}" ] && [ -n "${existing_admin:-}" ]; then
 TELEGRAM_ADMIN_ID="${existing_admin}"
 fi

 if valid_telegram_token "${TELEGRAM_BOT_TOKEN:-}" && [[ "${TELEGRAM_ADMIN_ID:-}" =~ ^[0-9]{6,}$ ]]; then
 echo -e "${GREEN}Telegram bot token and admin ID already configured.${NC}"
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
 if valid_telegram_token "${TELEGRAM_BOT_TOKEN}"; then
 break
 fi
 echo -e "${YELLOW}Invalid bot token format. Copy the token from @BotFather (with or without the bot prefix).${NC}"
 done
 set_env_value TELEGRAM_BOT_TOKEN "${TELEGRAM_BOT_TOKEN}"

 while true; do
 read -e -p "Enter your Bot admin ID (e.g., 123456789): " TELEGRAM_ADMIN_ID
 if [[ "${TELEGRAM_ADMIN_ID}" =~ ^[0-9]{6,}$ ]]; then
 break
 fi
 echo -e "${YELLOW}Invalid admin ID format. It should be a number with at least 6 digits.${NC}"
 done
 set_env_value TELEGRAM_ADMIN_ID "${TELEGRAM_ADMIN_ID}"
 set_env_value TELEGRAM_API_ENDPOINT "https://api.telegram.org"
 echo ""
}

ensure_laravel_env_file() {
 if [ -f "${LARAVEL_ENV_FILE}" ]; then
 return 0
 fi

 if [ -f "/var/www/html/laravel-app/.env.example" ]; then
 cp /var/www/html/laravel-app/.env.example "${LARAVEL_ENV_FILE}"
 ensure_env_file_ready
 else
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
 fi
}

# Detect required PHP version from powerps-core release metadata
detect_php_version() {
 local version_file="/var/www/html/laravel-app/.powerps-php-version"
 if [ -f "${version_file}" ]; then
 tr -d '[:space:]' < "${version_file}"
 return 0
 fi
 echo "8.4"
}

# Pick bolt.so for current CPU architecture
pick_bolt_source() {
 local app_dir="/var/www/html/laravel-app"
 local arch
 arch="$(uname -m)"
 case "${arch}" in
 x86_64|amd64)
 if [ -f "${app_dir}/bolt-x86_64.so" ]; then
 echo "${app_dir}/bolt-x86_64.so"
 elif [ -f "${app_dir}/bolt.so" ]; then
 echo "${app_dir}/bolt.so"
 fi
 ;;
 aarch64|arm64)
 if [ -f "${app_dir}/bolt-aarch64.so" ]; then
 echo "${app_dir}/bolt-aarch64.so"
 elif [ -f "${app_dir}/bolt.so" ]; then
 echo "${app_dir}/bolt.so"
 fi
 ;;
 *)
 if [ -f "${app_dir}/bolt.so" ]; then
 echo "${app_dir}/bolt.so"
 fi
 ;;
 esac
}

log_step() {
 echo -e "$1"
 echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $2" | sudo tee -a /var/log/powerps_install.log >/dev/null
}

resolve_php_extension_dir() {
 local php_version="$1"
 local php_bin="php${php_version}"
 local php_ext_dir

 # Use -n so a broken phpBolt from a partial install cannot hang or crash PHP CLI.
 php_ext_dir="$(${php_bin} -n -i 2>/dev/null | awk -F'=> ' '/^extension_dir/{print $2; exit}')"
 if [ -z "${php_ext_dir}" ]; then
 case "${php_version}" in
 8.4) php_ext_dir="/usr/lib/php/20240924" ;;
 8.3) php_ext_dir="/usr/lib/php/20230831" ;;
 *) php_ext_dir="/usr/lib/php/${php_version}" ;;
 esac
 fi
 echo "${php_ext_dir}"
}

cleanup_stale_bolt_config() {
 local php_version="$1"
 local php_ext_dir="$2"
 local ini_file="/etc/php/${php_version}/mods-available/bolt.ini"
 local cli_conf_dir="/etc/php/${php_version}/cli/conf.d"
 local apache_conf_dir="/etc/php/${php_version}/apache2/conf.d"

 sudo rm -f \
  "${cli_conf_dir}/99-bolt.ini" \
  "${apache_conf_dir}/99-bolt.ini" \
  "${cli_conf_dir}"/*bolt*.ini \
  "${apache_conf_dir}"/*bolt*.ini \
  "${ini_file}" \
  "${php_ext_dir}/bolt.so" 2>/dev/null || true
 if command -v phpdismod >/dev/null 2>&1; then
  sudo phpdismod -v "${php_version}" bolt 2>/dev/null || true
 fi
}

ensure_laravel_directories() {
 local app_dir="/var/www/html/laravel-app"
 local dir

 for dir in \
  "${app_dir}/storage" \
  "${app_dir}/storage/app" \
  "${app_dir}/storage/framework" \
  "${app_dir}/storage/framework/cache" \
  "${app_dir}/storage/framework/sessions" \
  "${app_dir}/storage/framework/views" \
  "${app_dir}/storage/logs" \
  "${app_dir}/bootstrap/cache" \
  "${app_dir}/public/images" \
  "${app_dir}/public/images/qrcodes" \
  "${app_dir}/public/images/transaction_images"
 do
  sudo mkdir -p "${dir}"
 done
}

# Configure phpBolt extension for Apache and CLI
configure_bolt() {
 local php_version="$1"
 local bolt_src
 local bolt_test_err
 local php_ext_dir
 local php_bin="php${php_version}"
 local ini_file="/etc/php/${php_version}/mods-available/bolt.ini"
 local cli_conf_dir="/etc/php/${php_version}/cli/conf.d"
 local apache_conf_dir="/etc/php/${php_version}/apache2/conf.d"
 local bolt_ini_line

 if ! command -v "${php_bin}" >/dev/null 2>&1; then
 echo -e "${RED}Error: ${php_bin} is not installed.${NC}"
 exit 1
 fi

 php_ext_dir="$(resolve_php_extension_dir "${php_version}")"
 cleanup_stale_bolt_config "${php_version}" "${php_ext_dir}"

 bolt_src="$(pick_bolt_source)"
 if [ -z "${bolt_src}" ] || [ ! -f "${bolt_src}" ]; then
 echo -e "${RED}Error: bolt.so not found in /var/www/html/laravel-app (bolt.so, bolt-x86_64.so, bolt-aarch64.so).${NC}"
 echo -e "${YELLOW}Run install again after powerps-core is fully cloned, or restore bolt*.so from the repo.${NC}"
 exit 1
 fi

 bolt_test_err="$(${php_bin} -n -d "extension=${bolt_src}" -r 'exit(function_exists("bolt_decrypt")?0:1);' 2>&1)" || {
 echo -e "${RED}Error: bolt binary is incompatible with ${php_bin}.${NC}"
 if [ -n "${bolt_test_err}" ]; then
 echo -e "${YELLOW}${bolt_test_err}${NC}"
 fi
 exit 1
 }

 echo -e "${GREEN}Configuring phpBolt (${bolt_src}) for PHP ${php_version}...${NC}"
 echo -e "${CYAN}phpBolt is bundled in powerps-core repo (not downloaded separately).${NC}"
 sudo mkdir -p "${php_ext_dir}"
 sudo cp "${bolt_src}" "${php_ext_dir}/bolt.so"
 sudo chmod 644 "${php_ext_dir}/bolt.so"

 bolt_ini_line="extension=${php_ext_dir}/bolt.so"

 # Write conf.d directly for CLI and Apache (do not also phpenmod or bolt loads twice).
 sudo mkdir -p "${cli_conf_dir}" "${apache_conf_dir}"
 echo "${bolt_ini_line}" | sudo tee "${cli_conf_dir}/99-bolt.ini" >/dev/null
 echo "${bolt_ini_line}" | sudo tee "${apache_conf_dir}/99-bolt.ini" >/dev/null

 bolt_count="$(${php_bin} -m 2>&1 | grep -ci '^bolt$' || true)"
 if [ "${bolt_count}" -gt 1 ]; then
 echo -e "${YELLOW}Warning: phpBolt loaded ${bolt_count} times; cleaning duplicate bolt ini files...${NC}"
 cleanup_stale_bolt_config "${php_version}" "${php_ext_dir}"
 echo "${bolt_ini_line}" | sudo tee "${cli_conf_dir}/99-bolt.ini" >/dev/null
 echo "${bolt_ini_line}" | sudo tee "${apache_conf_dir}/99-bolt.ini" >/dev/null
 fi

 if ! ${php_bin} -m 2>/dev/null | grep -qi '^bolt$'; then
 echo -e "${RED}Error: phpBolt is not loading for ${php_bin}.${NC}"
 echo -e "${YELLOW}Debug:${NC}"
 ${php_bin} -m 2>&1 | tail -5 || true
 ${php_bin} --ini 2>&1 | head -10 || true
 ls -la "${php_ext_dir}/bolt.so" 2>/dev/null || true
 exit 1
 fi
 echo -e "${GREEN}phpBolt verified for ${php_bin}.${NC}"
}

# Make the PowerPs PHP version the default `php` binary (artisan uses /usr/bin/env php)
ensure_php_default() {
 local php_version="$1"
 local php_bin="/usr/bin/php${php_version}"

 if [ ! -x "${php_bin}" ]; then
 echo -e "${RED}Error: ${php_bin} not found.${NC}"
 exit 1
 fi

 sudo update-alternatives --install /usr/bin/php php "${php_bin}" 100 2>/dev/null || true
 sudo update-alternatives --set php "${php_bin}" 2>/dev/null || true

 if ! php -m 2>/dev/null | grep -qi '^bolt$'; then
 echo -e "${RED}Error: default 'php' does not load phpBolt.${NC}"
 echo -e "${YELLOW}Current php: $(php -v 2>/dev/null | head -1)${NC}"
 echo -e "${YELLOW}Use: ${php_bin} artisan migrate --force${NC}"
 exit 1
 fi
 echo -e "${GREEN}Default php is ${php_bin} with phpBolt loaded.${NC}"
}

# Re-configure phpBolt if missing (e.g. partial install or PHP package refresh)
verify_bolt_or_configure() {
 local php_version="$1"
 local php_bin="php${php_version}"
 if ${php_bin} -m 2>/dev/null | grep -qi '^bolt$'; then
 return 0
 fi
 echo -e "${YELLOW}phpBolt not loaded; configuring now...${NC}"
 configure_bolt "${php_version}"
 ensure_php_default "${php_version}"
}

# run command with retries
run_with_retry() {
 local cmd="$1"
 local retries=${2:-3}
 local delay=${3:-5}
 local attempt=1
 until eval "$cmd"; do
 if [ "$attempt" -ge "$retries" ]; then
 echo -e "${RED}Command failed after ${attempt} attempts: $cmd${NC}"
 return 1
 fi
 echo "Attempt ${attempt} failed; retrying in ${delay}s..."
 attempt=$((attempt + 1))
 sleep "$delay"
 done
 return 0
}

ensure_ondrej_php_ppa() {
 local codename=""

 if grep -Rqs 'ppa.launchpadcontent.net/ondrej/php' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
 echo -e "${GREEN}ondrej/php PPA already configured; skipping add-apt-repository.${NC}"
 return 0
 fi

 codename="$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}")"
 if [ -z "${codename}" ]; then
 codename="$(lsb_release -sc 2>/dev/null || true)"
 fi

 echo -e "${GREEN}Adding ondrej/php PPA...${NC}"
 if sudo add-apt-repository -y ppa:ondrej/php 2>/dev/null; then
 return 0
 fi

 echo -e "${YELLOW}add-apt-repository failed (often DNS/Launchpad). Adding PPA list directly...${NC}"
 if [ -z "${codename}" ]; then
 echo -e "${RED}Could not detect Ubuntu codename for ondrej/php PPA.${NC}"
 exit 1
 fi

 echo "deb https://ppa.launchpadcontent.net/ondrej/php/ubuntu ${codename} main" | \
 sudo tee "/etc/apt/sources.list.d/ondrej-ubuntu-php-${codename}.list" >/dev/null
}

sanitize_release_composer_json() {
 local composer_file="$1"
 [ -f "${composer_file}" ] || return 0

 php -r '
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
file_put_contents(
 $path,
 json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n"
);
' "${composer_file}"
}

prepare_composer_for_install() {
 local app_dir="/var/www/html/laravel-app"
 local composer_bin="/usr/bin/composer"

 cd "${app_dir}" || exit 1

 if ! php${PHP_VERSION} "${composer_bin}" validate --no-check-publish --no-interaction >/dev/null 2>&1; then
 echo -e "${YELLOW}Composer files out of sync; removing build-only dev dependencies from composer.json...${NC}"
 sanitize_release_composer_json "${app_dir}/composer.json"
 php${PHP_VERSION} "${composer_bin}" update --lock --no-install --no-dev --no-interaction --ignore-platform-reqs --no-scripts >/dev/null 2>&1 || true
 fi
}

install_composer_dependencies() {
 local app_dir="/var/www/html/laravel-app"
 local composer_bin="/usr/bin/composer"
 local install_cmd="php${PHP_VERSION} ${composer_bin} install --no-dev --no-interaction --no-progress --prefer-dist --optimize-autoloader --no-scripts"

 cd "${app_dir}" || exit 1
 prepare_composer_for_install

 echo -e "${GREEN}Installing Composer dependencies...${NC}"
 run_with_retry "${install_cmd}" 3 5 || {
 echo -e "${RED}Composer install failed. Trying with --ignore-platform-reqs...${NC}"
 run_with_retry "${install_cmd} --ignore-platform-reqs" 3 5 || {
 echo -e "${RED}Composer install failed even with --ignore-platform-reqs${NC}"
 echo -e "${YELLOW}Run manually: cd ${app_dir} && php${PHP_VERSION} ${composer_bin} validate${NC}"
 exit 1
 }
 }

 php${PHP_VERSION} "${composer_bin}" dump-autoload --no-dev --optimize --no-interaction --ignore-platform-reqs >/dev/null 2>&1 || true
}

# Function to setup SSL certificates
setup_ssl() {
 echo -e "${GREEN}Obtaining TLS certificates for ${LARAVEL_SUBDOMAIN} and ${HTML5_SUBDOMAIN}...${NC}"
 
 # Ensure certbot is installed
 if ! command -v certbot >/dev/null 2>&1; then
 echo -e "${YELLOW}Certbot not found. Installing...${NC}"
 sudo apt-get update
 sudo apt-get install -y python3-certbot-apache certbot
 fi

 # Use default email if user leaves empty
 read -e -p "Enter email for Let's Encrypt notifications (press Enter to use admin@${LARAVEL_SUBDOMAIN#*.}): " CERTBOT_EMAIL
 if [ -z "${CERTBOT_EMAIL}" ]; then
 CERTBOT_EMAIL="admin@${LARAVEL_SUBDOMAIN#*.}"
 fi
 for domain in "${LARAVEL_SUBDOMAIN}" "${HTML5_SUBDOMAIN}"; do
 if [ -d "/etc/letsencrypt/live/${domain}" ]; then
 echo -e "${YELLOW}Certificate already exists for ${domain}, skipping...${NC}"
 continue
 fi
 run_with_retry "sudo certbot --apache --non-interactive --agree-tos --email ${CERTBOT_EMAIL} -d ${domain} --redirect" 3 5 || {
 echo -e "${YELLOW}Warning: Failed to obtain certificate for ${domain}. Please run: sudo certbot --apache -d ${domain} --email ${CERTBOT_EMAIL} --agree-tos --redirect${NC}"
 echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: Failed to obtain certificate for ${domain}" | sudo tee -a /var/log/powerps_install.log >/dev/null
 }
 done
}

# Pretty title
echo -e "${CYAN}==============================${NC}"
echo -e "${YELLOW} Setting up or Updating your core and WebApp PowerPs${NC}"
echo -e "${CYAN}==============================${NC}"

# Run requirement checks
check_requirements() {
 # بررسی فضای دیسک
 free_space=$(df -m / | awk 'NR==2 {print $4}')
 if [ "$free_space" -lt 1000 ]; then
 echo -e "${RED}Not enough disk space. At least 1GB required${NC}"
 exit 1
 fi
 
 # بررسی رم
 total_ram=$(free -m | awk '/^Mem:/{print $2}')
 if [ "$total_ram" -lt 256 ]; then
 echo -e "${YELLOW}Warning: Less than 256MB RAM available${NC}"
 fi
}
check_requirements

# Persisted state directory (do NOT depend on current working directory)
STATE_DIR="/var/lib/powerps"
SUBDOMAIN_FILE="${STATE_DIR}/subdomains.conf"

# Ensure state dir exists (works for sudo bash -c ...)
sudo mkdir -p "${STATE_DIR}"
sudo chown "$(whoami)":"$(whoami)" "${STATE_DIR}" 2>/dev/null || true

# --- Detect existing install (subdomains.conf, legacy paths, Apache, .env) ---
load_subdomains_from_file() {
 local file="$1"
 if [ ! -f "$file" ]; then
 return 1
 fi
 # shellcheck disable=SC1090
 source "$file"
 if [ -n "${LARAVEL_SUBDOMAIN:-}" ] && [ -n "${HTML5_SUBDOMAIN:-}" ]; then
 return 0
 fi
 return 1
}

persist_subdomains() {
 echo "LARAVEL_SUBDOMAIN=$LARAVEL_SUBDOMAIN" | sudo tee "$SUBDOMAIN_FILE" >/dev/null
 echo "HTML5_SUBDOMAIN=$HTML5_SUBDOMAIN" | sudo tee -a "$SUBDOMAIN_FILE" >/dev/null
}

detect_subdomains_from_apache() {
 local core_conf="/etc/apache2/sites-available/powerps-core.conf"
 local web_conf="/etc/apache2/sites-available/powerps-webapp.conf"
 if [ -f "$core_conf" ]; then
 LARAVEL_SUBDOMAIN=$(grep -E '^\s*ServerName\s+' "$core_conf" 2>/dev/null | awk '{print $2}' | head -1)
 fi
 if [ -f "$web_conf" ]; then
 HTML5_SUBDOMAIN=$(grep -E '^\s*ServerName\s+' "$web_conf" 2>/dev/null | awk '{print $2}' | head -1)
 fi
}

strip_url_host() {
 local url="$1"
 url="${url#https://}"
 url="${url#http://}"
 url="${url%%/*}"
 echo "$url"
}

detect_subdomains_from_env() {
 local env_file="/var/www/html/laravel-app/.env"
 if [ ! -f "$env_file" ]; then
 return 1
 fi
 local app_url front_url
 app_url=$(grep -m1 '^APP_URL=' "$env_file" | cut -d= -f2- | tr -d '"' | tr -d "'")
 front_url=$(grep -m1 '^FRONT_URL=' "$env_file" | cut -d= -f2- | tr -d '"' | tr -d "'")
 if [ -n "$app_url" ]; then
 LARAVEL_SUBDOMAIN=$(strip_url_host "$app_url")
 fi
 if [ -n "$front_url" ]; then
 HTML5_SUBDOMAIN=$(strip_url_host "$front_url")
 fi
}

powerps_is_installed() {
 [ -d "/var/www/html/laravel-app/.git" ] || [ -d "/var/www/html/laravel-app" ]
}

show_powerps_menu() {
 echo -e "${YELLOW}Subdomains are already set (${LARAVEL_SUBDOMAIN}, ${HTML5_SUBDOMAIN}).${NC}"
 echo -e "${CYAN}Please choose an option:${NC}"
 echo "1) Install / Update"
 echo "2) Uninstall"
 echo "3) SSL Certificate (Certbot)"
 while true; do
 read -p "Enter choice [1-3]: " choice
 case $choice in
 1)
 echo -e "${GREEN}Proceeding with Installation...${NC}"
 return 0
 ;;
 2)
 echo -e "${GREEN}Starting uninstallation process...${NC}"
 # 1. Stop running services
 echo -e "${GREEN}Stopping services...${NC}"
 sudo pkill -f artisan || true
 sudo pkill -f "php artisan" || true
 if systemctl list-unit-files | grep -q '^laravel-queue\.service'; then
 echo -e "${GREEN}Stopping and removing Laravel Queue Service...${NC}"
 sudo systemctl stop laravel-queue || true
 sudo systemctl disable laravel-queue || true
 sudo rm -f /etc/systemd/system/laravel-queue.service || true
 sudo systemctl daemon-reload || true
 fi
 echo -e "${GREEN}Removing Laravel application...${NC}"
 DB_NAME_LOCAL=""
 DB_USER_LOCAL=""
 if [ -f "/var/www/html/laravel-app/.env" ]; then
 DB_NAME_LOCAL=$(grep '^DB_DATABASE=' /var/www/html/laravel-app/.env | cut -d'=' -f2)
 DB_USER_LOCAL=$(grep '^DB_USERNAME=' /var/www/html/laravel-app/.env | cut -d'=' -f2)
 fi
 if [ -d "/var/www/html/laravel-app" ]; then
 backup_existing "/var/www/html/laravel-app"
 sudo rm -rf /var/www/html/laravel-app || true
 fi
 echo -e "${GREEN}Removing WebApp...${NC}"
 if [ -d "/var/www/html/powerps-webapp" ]; then
 backup_existing "/var/www/html/powerps-webapp"
 sudo rm -rf /var/www/html/powerps-webapp || true
 fi
 echo -e "${GREEN}Removing database and user...${NC}"
 DB_NAME_LOCAL=${DB_NAME_LOCAL:-powerps_db}
 DB_USER_LOCAL=${DB_USER_LOCAL:-powerps_user}
 sudo mysql -e "DROP DATABASE IF EXISTS ${DB_NAME_LOCAL};" || true
 sudo mysql -e "DROP USER IF EXISTS '${DB_USER_LOCAL}'@'localhost';" || true
 sudo mysql -e "FLUSH PRIVILEGES;" || true
 echo -e "${GREEN}Removing Apache configurations...${NC}"
 if [ -f "/etc/apache2/sites-available/powerps-core.conf" ]; then
 sudo a2dissite powerps-core || true
 sudo rm -f /etc/apache2/sites-available/powerps-core.conf || true
 fi
 if [ -f "/etc/apache2/sites-available/powerps-webapp.conf" ]; then
 sudo a2dissite powerps-webapp || true
 sudo rm -f /etc/apache2/sites-available/powerps-webapp.conf || true
 fi
 echo -e "${GREEN}Restarting Apache...${NC}"
 sudo systemctl restart apache2 || true
 if [ -d "/var/www/html/phpmyadmin" ]; then
 echo -e "${GREEN}Removing PHPMyAdmin...${NC}"
 sudo rm -rf /var/www/html/phpmyadmin || true
 fi
 echo -e "${GREEN}Removing cron jobs...${NC}"
 crontab -l 2>/dev/null | grep -v 'laravel-app' | grep -v 'powerps' | grep -v 'artisan' | crontab - || true
 if [ -f "$SUBDOMAIN_FILE" ]; then
 rm -f "$SUBDOMAIN_FILE" || true
 fi
 if [ -n "${LARAVEL_SUBDOMAIN:-}" ] && [ -n "${HTML5_SUBDOMAIN:-}" ]; then
 sudo sed -i "/${LARAVEL_SUBDOMAIN}/d" /etc/hosts || true
 sudo sed -i "/${HTML5_SUBDOMAIN}/d" /etc/hosts || true
 fi
 sudo rm -f /var/log/laravel-queue.log /var/log/laravel-queue.error.log || true
 if systemctl list-unit-files | grep -q '^certbot-renew\.timer'; then
 echo -e "${GREEN}Stopping and removing certbot renewal timer/service...${NC}"
 sudo systemctl stop certbot-renew.timer || true
 sudo systemctl disable certbot-renew.timer || true
 sudo rm -f /etc/systemd/system/certbot-renew.timer /etc/systemd/system/certbot-renew.service || true
 sudo systemctl daemon-reload || true
 fi
 if command -v certbot >/dev/null 2>&1; then
 read -r -p "Also delete Let's Encrypt certs for ${LARAVEL_SUBDOMAIN} and ${HTML5_SUBDOMAIN}? (y/N): " DELCERTS
 if [[ "$DELCERTS" =~ ^[Yy]$ ]]; then
 sudo certbot delete --cert-name "${LARAVEL_SUBDOMAIN}" || true
 sudo certbot delete --cert-name "${HTML5_SUBDOMAIN}" || true
 fi
 fi
 sudo rm -f /root/.mysql_root_pass || true
 echo -e "${GREEN}Uninstallation completed successfully!${NC}"
 exit 0
 ;;
 3)
 setup_ssl
 echo -e "${GREEN}SSL setup process finished.${NC}"
 exit 0
 ;;
 *)
 echo -e "${RED}Invalid option. Please enter 1, 2, or 3.${NC}"
 ;;
 esac
 done
}

prompt_for_subdomains() {
 while true; do
 read -e -p "Enter your Core subdomain (e.g., core.domain.com): " LARAVEL_SUBDOMAIN
 if [[ $LARAVEL_SUBDOMAIN =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}$ ]]; then
 break
 else
 echo -e "${YELLOW}Invalid domain format. Please try again.${NC}"
 fi
 done
 while true; do
 read -e -p "Enter your WebApp subdomain (e.g., web.domain.com): " HTML5_SUBDOMAIN
 if [[ $HTML5_SUBDOMAIN =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}$ ]]; then
 break
 else
 echo -e "${YELLOW}Invalid domain format. Please try again.${NC}"
 fi
 done
 persist_subdomains
}

LARAVEL_SUBDOMAIN=""
HTML5_SUBDOMAIN=""

if load_subdomains_from_file "$SUBDOMAIN_FILE"; then
 :
else
 for legacy in "/root/subdomains.conf" "$HOME/subdomains.conf" "./subdomains.conf"; do
 if load_subdomains_from_file "$legacy"; then
 echo -e "${CYAN}Migrating subdomains from ${legacy} -> ${SUBDOMAIN_FILE}${NC}"
 persist_subdomains
 break
 fi
 done
fi

if { [ -z "${LARAVEL_SUBDOMAIN:-}" ] || [ -z "${HTML5_SUBDOMAIN:-}" ]; } && powerps_is_installed; then
 detect_subdomains_from_apache
 if [ -z "${LARAVEL_SUBDOMAIN:-}" ] || [ -z "${HTML5_SUBDOMAIN:-}" ]; then
 detect_subdomains_from_env
 fi
 if [ -n "${LARAVEL_SUBDOMAIN:-}" ] && [ -n "${HTML5_SUBDOMAIN:-}" ]; then
 persist_subdomains
 echo -e "${CYAN}Detected existing install from server config (${LARAVEL_SUBDOMAIN}, ${HTML5_SUBDOMAIN})${NC}"
 fi
fi

if [ -n "${LARAVEL_SUBDOMAIN:-}" ] && [ -n "${HTML5_SUBDOMAIN:-}" ]; then
 show_powerps_menu
elif powerps_is_installed; then
 echo -e "${YELLOW}PowerPs is installed but subdomains were not found.${NC}"
 echo -e "${YELLOW}Enter them once; they will be saved to ${SUBDOMAIN_FILE}${NC}"
 prompt_for_subdomains
 show_powerps_menu
else
 prompt_for_subdomains
fi
# Update package lists and install necessary packages
echo -e "${GREEN}Updating package lists and installing necessary packages...${NC}"
sudo apt-get update
sudo apt-get install -y software-properties-common curl openssl
ensure_ondrej_php_ppa
sudo apt-get update

# Install PHP and specific extensions (version detected after clone/update)
PHP_VERSION="${PHP_VERSION:-8.4}"
echo -e "${GREEN}Installing PHP ${PHP_VERSION} and required packages...${NC}"
sudo apt-get install -y apache2 mysql-server \
 "php${PHP_VERSION}" "php${PHP_VERSION}-mysql" "libapache2-mod-php${PHP_VERSION}" "php${PHP_VERSION}-cli" "php${PHP_VERSION}-zip" \
 "php${PHP_VERSION}-xml" "php${PHP_VERSION}-dom" "php${PHP_VERSION}-mbstring" "php${PHP_VERSION}-curl" "php${PHP_VERSION}-gd" \
 "php${PHP_VERSION}-bcmath" "php${PHP_VERSION}-intl" "php${PHP_VERSION}-imagick" "php${PHP_VERSION}-readline" \
 php-imagick libmagickwand-dev composer unzip git expect \
 python3-certbot-apache certbot || {
 echo -e "${RED}خطا در نصب پکیج‌ها${NC}"
 exit 1
}

# Force selected PHP version as default
echo -e "${GREEN}Setting PHP ${PHP_VERSION} as default...${NC}"
sudo update-alternatives --set php "/usr/bin/php${PHP_VERSION}" || true
sudo a2enmod "php${PHP_VERSION}" || true
sudo systemctl restart apache2

# Ensure MySQL is running
echo -e "${GREEN}Ensuring MySQL service is running...${NC}"
# Create socket directory if it doesn't exist (common issue in some environments)
sudo mkdir -p /var/run/mysqld
sudo chown mysql:mysql /var/run/mysqld

# Try to start MySQL with a fallback to re-configuration
if ! sudo systemctl start mysql; then
 echo -e "${YELLOW}MySQL failed to start. Attempting to fix dependencies and re-configure...${NC}"
 sudo apt-get install -f -y
 sudo dpkg --configure -a
 sudo systemctl daemon-reload
 
 # Try starting again
 if ! sudo systemctl start mysql; then
 echo -e "${RED}MySQL still failing to start. Checking logs for clues...${NC}"
 if [ -f /var/log/mysql/error.log ]; then
 sudo tail -n 20 /var/log/mysql/error.log
 else
 sudo journalctl -xeu mysql.service --no-pager | tail -n 20
 fi
 exit 1
 fi
fi
sudo systemctl enable mysql

# Wait for MySQL socket to be available
echo -e "${GREEN}Waiting for MySQL socket...${NC}"
for i in {1..30}; do
 if [ -S /var/run/mysqld/mysqld.sock ] || [ -S /var/lib/mysql/mysql.sock ]; then
 break
 fi
 echo -n "."
 sleep 1
done
echo

# Secure MySQL Installation using expect
echo -e "${GREEN}Securing MySQL Installation...${NC}"

# Check if we already have a saved root password
if [ -f /root/.mysql_root_pass ]; then
 EXISTING_ROOT_PASS=$(sudo cat /root/.mysql_root_pass)
 echo -e "${YELLOW}Existing MySQL root password found in /root/.mysql_root_pass.${NC}"
fi

# Prompt for MySQL root password
read -s -e -p "Enter desired MySQL root password (leave empty to use existing or generate one): " MYSQL_ROOT_PASSWORD
echo

if [ -z "${MYSQL_ROOT_PASSWORD}" ]; then
 if [ -n "${EXISTING_ROOT_PASS:-}" ]; then
 MYSQL_ROOT_PASSWORD="${EXISTING_ROOT_PASS}"
 echo "Using existing MySQL root password."
 else
 MYSQL_ROOT_PASSWORD=$(openssl rand -base64 16)
 echo "Generated new MySQL root password: (will be saved to /root/.mysql_root_pass)"
 echo "${MYSQL_ROOT_PASSWORD}" | sudo tee /root/.mysql_root_pass >/dev/null
 sudo chmod 600 /root/.mysql_root_pass
 fi
else
 # Update the saved password file if user provided a new one
 echo "${MYSQL_ROOT_PASSWORD}" | sudo tee /root/.mysql_root_pass >/dev/null
 sudo chmod 600 /root/.mysql_root_pass
fi

# Use expect to automate mysql_secure_installation
# We handle both cases: no password set yet, or password already set
SECURE_MYSQL=$(expect -c "
set timeout 10
spawn sudo mysql_secure_installation
expect {
 \"Enter password for user root:\" {
 send \"${MYSQL_ROOT_PASSWORD}\r\"
 exp_continue
 }
 \"Enter current password for root\" {
 send \"${MYSQL_ROOT_PASSWORD}\r\"
 exp_continue
 }
 \"VALIDATE PASSWORD COMPONENT\" {
 send \"n\r\"
 exp_continue
 }
 \"New password:\" {
 send \"${MYSQL_ROOT_PASSWORD}\r\"
 exp_continue
 }
 \"Re-enter new password:\" {
 send \"${MYSQL_ROOT_PASSWORD}\r\"
 exp_continue
 }
 \"Change the password for root?\" {
 send \"n\r\"
 exp_continue
 }
 \"Do you wish to continue with the password provided?\" {
 send \"y\r\"
 exp_continue
 }
 \"Remove anonymous users?\" {
 send \"y\r\"
 exp_continue
 }
 \"Disallow root login remotely?\" {
 send \"y\r\"
 exp_continue
 }
 \"Remove test database and access to it?\" {
 send \"y\r\"
 exp_continue
 }
 \"Reload privilege tables now?\" {
 send \"y\r\"
 exp_continue
 }
 eof
}
")
echo "$SECURE_MYSQL"
# Do not log or print the MySQL root password anywhere else

# Create MySQL database and user
DB_NAME='powerps_db'
DB_USER='powerps_user'

# Check if .env already exists to reuse password
if [ -f "/var/www/html/laravel-app/.env" ]; then
 echo -e "${YELLOW}Existing .env found. Extracting database credentials...${NC}"
 DB_PASS=$(grep '^DB_PASSWORD=' /var/www/html/laravel-app/.env | cut -d'=' -f2)
fi

# If DB_PASS is still empty (no .env or no password in it), generate new one
if [ -z "${DB_PASS:-}" ]; then
 DB_PASS=$(openssl rand -base64 12)
fi

echo -e "${GREEN}Creating MySQL database and user (if not exists)...${NC}"
sudo mysql -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME};" || check_command "Failed to create database ${DB_NAME}"
sudo mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';" || check_command "Failed to create database user ${DB_USER}"
# Update password in case it changed or user existed with different pass
sudo mysql -e "ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';" || check_command "Failed to update database user password"
sudo mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';" || check_command "Failed to grant privileges on ${DB_NAME}"
sudo mysql -e "FLUSH PRIVILEGES;" || check_command "Failed to flush privileges"

# Check if the Laravel project directory exists
if [ -d "/var/www/html/laravel-app/.git" ]; then
 update_powerps_core_repo
 cd /var/www/html/laravel-app
else
 # Clone the Laravel project repository
 echo -e "${GREEN}Cloning Laravel project repository...${NC}"
 run_with_retry "git clone https://github.com/rezahajrahimi/powerps-core /var/www/html/laravel-app" 3 5 || {
 echo -e "${RED}خطا در کلون کردن مخزن${NC}"
 echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Failed to clone laravel repository" | sudo tee -a /var/log/powerps_install.log >/dev/null
 exit 1
 }
 cd /var/www/html/laravel-app
fi

PHP_VERSION="$(detect_php_version)"
echo -e "${GREEN}Detected PowerPs release target: PHP ${PHP_VERSION}${NC}"
if [ -f "/var/www/html/laravel-app/.powerps-bolt-version" ]; then
 echo -e "${GREEN}phpBolt version: $(tr -d '[:space:]' < /var/www/html/laravel-app/.powerps-bolt-version)${NC}"
fi

# Ensure required PHP version is installed (supports upgrades from older releases)
sudo apt-get install -y \
 "php${PHP_VERSION}" "php${PHP_VERSION}-mysql" "libapache2-mod-php${PHP_VERSION}" "php${PHP_VERSION}-cli" "php${PHP_VERSION}-zip" \
 "php${PHP_VERSION}-xml" "php${PHP_VERSION}-dom" "php${PHP_VERSION}-mbstring" "php${PHP_VERSION}-curl" "php${PHP_VERSION}-gd" \
 "php${PHP_VERSION}-bcmath" "php${PHP_VERSION}-intl" "php${PHP_VERSION}-imagick" "php${PHP_VERSION}-readline" || {
 echo -e "${RED}Failed to install PHP ${PHP_VERSION} packages${NC}"
 exit 1
}
sudo update-alternatives --set php "/usr/bin/php${PHP_VERSION}" || true
sudo a2enmod "php${PHP_VERSION}" || true

# Configure Bolt extension
log_step "${GREEN}Preparing phpBolt for PHP ${PHP_VERSION}...${NC}" "Starting configure_bolt for PHP ${PHP_VERSION}"
configure_bolt "${PHP_VERSION}"
ensure_php_default "${PHP_VERSION}"
log_step "${GREEN}phpBolt setup finished.${NC}" "configure_bolt completed for PHP ${PHP_VERSION}"

# تنظیم مجوزها در هر دو حالت نصب اولیه و نصب مجدد
log_step "${GREEN}Setting permissions for Laravel directories...${NC}" "Ensuring Laravel directories and permissions"
ensure_laravel_directories
sudo chown -R www-data:www-data /var/www/html/laravel-app/storage
sudo chown -R www-data:www-data /var/www/html/laravel-app/bootstrap/cache
sudo chown -R www-data:www-data /var/www/html/laravel-app/public
sudo chown -R www-data:www-data /var/www/html/laravel-app/public/images

sudo chown -R www-data:www-data /var/www/html/laravel-app/public/images/qrcodes
sudo chmod -R 775 /var/www/html/laravel-app/storage
sudo chmod -R 775 /var/www/html/laravel-app/bootstrap/cache
sudo chmod -R 775 /var/www/html/laravel-app/public
sudo chmod -R 775 /var/www/html/laravel-app/public/images
sudo chmod -R 775 /var/www/html/laravel-app/public/images/qrcodes

# Restart Apache to apply changes
echo -e "${GREEN}Restarting Apache to apply changes...${NC}"
sudo systemctl restart apache2

# Install Composer dependencies
install_composer_dependencies

# Set up environment variables if not already set
echo -e "${GREEN}Setting up environment variables...${NC}"
ensure_laravel_env_file
repair_merged_env_lines

if [ ! -s "${LARAVEL_ENV_FILE}" ] || ! grep -q '^APP_NAME=' "${LARAVEL_ENV_FILE}"; then
 echo -e "${YELLOW}Warning: .env was missing or incomplete; recreating base settings.${NC}"
 ensure_laravel_env_file
fi

set_env_value APP_NAME "Laravel"
set_env_value APP_ENV "production"
if ! grep -q '^APP_KEY=.\+' "${LARAVEL_ENV_FILE}"; then
 set_env_value APP_KEY ""
fi
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

existing_zarinpal="$(read_env_value ZARINPAL_MERCHANT_ID || true)"
if [ -z "${existing_zarinpal:-}" ]; then
 read -e -p "Enter your Zarinpal Merchant ID (optional, press Enter to skip): " ZARINPAL_MERCHANT_ID
 if [ ! -z "$ZARINPAL_MERCHANT_ID" ]; then
 if [[ $ZARINPAL_MERCHANT_ID =~ ^[a-zA-Z0-9]{8}-[a-zA-Z0-9]{4}-[a-zA-Z0-9]{4}-[a-zA-Z0-9]{4}-[a-zA-Z0-9]{12}$ ]]; then
 set_env_value ZARINPAL_MERCHANT_ID "${ZARINPAL_MERCHANT_ID}"
 else
 echo -e "${YELLOW}Invalid Zarinpal Merchant ID format. Setting empty value.${NC}"
 set_env_value ZARINPAL_MERCHANT_ID ""
 fi
 else
 set_env_value ZARINPAL_MERCHANT_ID ""
 fi
fi

existing_nowpayments="$(read_env_value NOWPAYMENTS_API_KEY || true)"
if [ -z "${existing_nowpayments:-}" ]; then
 read -e -p "Enter your NOWPAYMENTS API KEY (optional, press Enter to skip): " NOWPAYMENTS_API_KEY
 if [ ! -z "$NOWPAYMENTS_API_KEY" ]; then
 if [[ $NOWPAYMENTS_API_KEY =~ ^[A-Za-z0-9-]{36}$ ]]; then
 set_env_value NOWPAYMENTS_API_KEY "${NOWPAYMENTS_API_KEY}"
 else
 echo -e "${YELLOW}Invalid NOWPayments API key format. Setting empty value.${NC}"
 set_env_value NOWPAYMENTS_API_KEY ""
 fi
 else
 set_env_value NOWPAYMENTS_API_KEY ""
 fi
fi

# Secure .env file: restrict permissions and owner
sudo chown www-data:www-data /var/www/html/laravel-app/.env || true
sudo chmod 600 /var/www/html/laravel-app/.env || true

# Ensure phpBolt is loaded before any artisan command (encrypted source)
verify_bolt_or_configure "${PHP_VERSION}"

# Generate app key (first install only; --force required in production when APP_KEY is empty)
if grep -qE '^APP_KEY=base64:.+' "${LARAVEL_ENV_FILE}"; then
 echo -e "${GREEN}APP_KEY already set; skipping key generation.${NC}"
else
 echo -e "${GREEN}Generating app key...${NC}"
 php${PHP_VERSION} artisan key:generate --force
fi

# Run migrations
echo -e "${GREEN}Running migrations...${NC}"
php${PHP_VERSION} artisan migrate --force || {
 echo -e "${RED}Migration failed. Checking database connection...${NC}"
 exit 1
}

# Run Link Storage
echo -e "${GREEN}Linking storage...${NC}"
php${PHP_VERSION} artisan storage:link --force || true
# Check if phpMyAdmin is installed
if [ -d "/var/www/html/phpmyadmin" ]; then
 echo -e "${GREEN}phpMyAdmin is already installed.${NC}"
else
 # Install PHPMyAdmin
 echo -e "${GREEN}Installing PHPMyAdmin...${NC}"
 cd /var/www/html
 run_with_retry "wget -q https://www.phpmyadmin.net/downloads/phpMyAdmin-latest-all-languages.zip -O phpMyAdmin-latest-all-languages.zip" 3 5 || { echo -e "${RED}Failed to download phpMyAdmin${NC}"; exit 1; }
 unzip phpMyAdmin-latest-all-languages.zip || { echo -e "${RED}Failed to unzip phpMyAdmin archive${NC}"; exit 1; }
 mv phpMyAdmin-*-all-languages phpmyadmin || { echo -e "${RED}Failed to move phpMyAdmin directory${NC}"; exit 1; }
 rm phpMyAdmin-latest-all-languages.zip
fi

# Set up Apache virtual host for Laravel
echo -e "${GREEN}Setting up Apache virtual host for Laravel...${NC}"
sudo bash -c "cat <<EOT > /etc/apache2/sites-available/powerps-core.conf
<VirtualHost *:80>
    ServerName ${LARAVEL_SUBDOMAIN}
    DocumentRoot /var/www/html/laravel-app/public
    <Directory /var/www/html/laravel-app/public>
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/laravel-error.log
    CustomLog \${APACHE_LOG_DIR}/laravel-access.log combined
</VirtualHost>
EOT"

# Check if the HTML5 project directory exists
if [ -d "/var/www/html/powerps-webapp" ]; then
 echo -e "${GREEN}Removing existing HTML5 project directory...${NC}"
 backup_existing "/var/www/html/powerps-webapp"
 sudo rm -rf /var/www/html/powerps-webapp || true
fi

# Clone the HTML5 project repository
echo -e "${GREEN}Cloning HTML5 project repository...${NC}"
run_with_retry "git clone https://github.com/rezahajrahimi/powerps-webapp /var/www/html/powerps-webapp" 3 5 || {
 echo -e "${RED}خطا در کلون کردن مخزن${NC}"
 echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Failed to clone webapp repository" | sudo tee -a /var/log/powerps_install.log >/dev/null
 exit 1
}

# Change to project directory
cd /var/www/html/powerps-webapp

# Create new .env file with BASE_URL
echo "BASE_URL=https://${LARAVEL_SUBDOMAIN}" > assets/.env
sudo chown www-data:www-data assets/.env || true
sudo chmod 640 assets/.env || true

# Set up Apache virtual host for HTML5 project
echo -e "${GREEN}Setting up Apache virtual host for HTML5 project...${NC}"
sudo bash -c "cat <<EOT > /etc/apache2/sites-available/powerps-webapp.conf
<VirtualHost *:80>
    ServerName ${HTML5_SUBDOMAIN}
    DocumentRoot /var/www/html/powerps-webapp
    <Directory /var/www/html/powerps-webapp>
        AllowOverride All
        Options Indexes FollowSymLinks
        Require all granted
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/html5-error.log
    CustomLog \${APACHE_LOG_DIR}/html5-access.log combined
</VirtualHost>
EOT"

# Enable Apache virtual hosts
sudo a2ensite powerps-core || check_command "Failed to enable powerps-core site"
sudo a2ensite powerps-webapp || check_command "Failed to enable powerps-webapp site"
sudo a2enmod rewrite || check_command "Failed to enable rewrite module"
sudo systemctl restart apache2 || check_command "Failed to restart apache2"

# Obtain TLS certificates for subdomains using Certbot (Let's Encrypt)
setup_ssl

# Add domain entries to /etc/hosts (avoid duplicates)
for domain in "${LARAVEL_SUBDOMAIN}" "${HTML5_SUBDOMAIN}"; do
 if ! grep -q "$domain" /etc/hosts; then
 echo "127.0.0.1 $domain" | sudo tee -a /etc/hosts
 fi
done

# Add schedule to cron job (avoid duplicates)
echo -e "${GREEN}Adding schedule to cron job...${NC}"
CRON_JOB="* * * * * cd /var/www/html/laravel-app && /usr/bin/php${PHP_VERSION} artisan schedule:run >> /dev/null 2>&1"
(crontab -l 2>/dev/null | grep -v "artisan schedule:run" ; echo "$CRON_JOB") | crontab -

# Ensure services start on reboot (avoid duplicates)
echo -e "${GREEN}Ensuring services start on reboot...${NC}"
(crontab -l 2>/dev/null | grep -v "@reboot systemctl restart apache2" ; echo "@reboot systemctl restart apache2") | crontab -
(crontab -l 2>/dev/null | grep -v "@reboot systemctl restart mysql" ; echo "@reboot systemctl restart mysql") | crontab -

# Completion message
echo -e "${CYAN}==============================${NC}"
echo -e "${YELLOW} Setup Complete!${NC}"
echo -e "${CYAN}==============================${NC}"

# Set Telegram Webhook
echo -e "${GREEN}Setting up Telegram webhook...${NC}"
if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
 TELEGRAM_BOT_TOKEN="$(read_env_value TELEGRAM_BOT_TOKEN || true)"
fi
if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
 echo -e "${YELLOW}Warning: Telegram bot token is not set. Skipping webhook setup.${NC}"
else
WEBHOOK_URL="https://${LARAVEL_SUBDOMAIN}/api/telegram/webhooks/inbound"
TELEGRAM_API="https://api.telegram.org/${TELEGRAM_BOT_TOKEN}/setWebhook?url=${WEBHOOK_URL}"

# Send request to set webhook
WEBHOOK_RESPONSE=$(curl -s "$TELEGRAM_API")

# Check if webhook was set successfully
if [[ $WEBHOOK_RESPONSE == *"\"ok\":true"* ]]; then
 echo -e "${GREEN}Telegram webhook set successfully!${NC}"
 echo -e "${GREEN}Webhook URL: ${WEBHOOK_URL}${NC}"
else
 masked_token="${TELEGRAM_BOT_TOKEN:0:4}...${TELEGRAM_BOT_TOKEN: -4}"
 echo -e "${YELLOW}Warning: Failed to set Telegram webhook. You can set it manually.${NC}"
 echo -e "${YELLOW}Masked bot token: ${masked_token}${NC}"
 echo -e "${YELLOW}Run: curl -F \"url=${WEBHOOK_URL}\" https://api.telegram.org/bot /setWebhook${NC}"
fi
fi

echo -e "${GREEN}PowerPs installation complete!${NC}"

# Create and configure Laravel Queue Service (systemd supervised)
echo -e "${GREEN}Setting up Laravel Queue Service...${NC}"
sudo bash -c "cat > /etc/systemd/system/laravel-queue.service << EOL
[Unit]
Description=Laravel Queue Worker
After=network.target mysql.service apache2.service

[Service]
User=www-data
Group=www-data
# Keep the worker running and limit restart storms
Restart=always
RestartSec=5
StartLimitIntervalSec=60
StartLimitBurst=5
ExecStart=/usr/bin/php${PHP_VERSION} /var/www/html/laravel-app/artisan queue:work --sleep=3 --tries=3 --timeout=0
StandardOutput=append:/var/log/laravel-queue.log
StandardError=append:/var/log/laravel-queue.error.log

[Install]
WantedBy=multi-user.target
EOL"

# Ensure log files exist and have correct permissions
sudo touch /var/log/laravel-queue.log /var/log/laravel-queue.error.log || true
sudo chown www-data:www-data /var/log/laravel-queue.log /var/log/laravel-queue.error.log || true
sudo chmod 640 /var/log/laravel-queue.log /var/log/laravel-queue.error.log || true

# Reload systemd and start queue service
sudo systemctl daemon-reload || check_command "Failed to reload systemd"
sudo systemctl enable --now laravel-queue || check_command "Failed to enable/start laravel-queue"

# Create Certbot renewal systemd service and timer to renew SSL and reload Apache
echo -e "${GREEN}Setting up Certbot renewal timer...${NC}"
sudo bash -c "cat > /etc/systemd/system/certbot-renew.service << 'EOL'
[Unit]
Description=Run Certbot renewal and reload Apache if certificates changed
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew --quiet --post-hook 'systemctl reload apache2'
EOL"

sudo bash -c "cat > /etc/systemd/system/certbot-renew.timer << 'EOL'
[Unit]
Description=Timer to run Certbot renewal daily

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=3600

[Install]
WantedBy=timers.target
EOL"

# Reload systemd and enable timer
sudo systemctl daemon-reload || check_command "Failed to reload systemd after adding certbot units"
sudo systemctl enable --now certbot-renew.timer || check_command "Failed to enable/start certbot-renew.timer"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: certbot-renew.timer enabled" | sudo tee -a /var/log/powerps_install.log >/dev/null

# Remove old artisan serve from cron
crontab -l | grep -v '/usr/bin/php /var/www/html/laravel-app/artisan serve' | crontab -
