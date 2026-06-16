#!/bin/bash
# Repair phpBolt loading for PowerPs (CLI + Apache). Safe to re-run.
set -o errexit
set -o nounset
set -o pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

APP_DIR="/var/www/html/laravel-app"
PHP_VERSION="8.4"

if [ -f "${APP_DIR}/.powerps-php-version" ]; then
 PHP_VERSION="$(tr -d '[:space:]' < "${APP_DIR}/.powerps-php-version")"
fi

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
 return 1
}

php_bin="php${PHP_VERSION}"
if ! command -v "${php_bin}" >/dev/null 2>&1; then
 echo -e "${RED}Error: ${php_bin} is not installed. Run install.sh first.${NC}" >&2
 exit 1
fi

bolt_src="$(pick_bolt_source)" || {
 echo -e "${RED}Error: bolt.so not found in ${APP_DIR}${NC}" >&2
 ls -la "${APP_DIR}"/bolt*.so 2>/dev/null || true
 exit 1
}

php_ext_dir="$(${php_bin} -i 2>/dev/null | awk -F'=> ' '/^extension_dir/{print $2; exit}')"
if [ -z "${php_ext_dir}" ]; then
 case "${PHP_VERSION}" in
 8.4) php_ext_dir="/usr/lib/php/20240924" ;;
 8.3) php_ext_dir="/usr/lib/php/20230831" ;;
 *) php_ext_dir="/usr/lib/php/${PHP_VERSION}" ;;
 esac
fi

cli_conf_dir="/etc/php/${PHP_VERSION}/cli/conf.d"
apache_conf_dir="/etc/php/${PHP_VERSION}/apache2/conf.d"
ini_file="/etc/php/${PHP_VERSION}/mods-available/bolt.ini"
bolt_ini_line="extension=${php_ext_dir}/bolt.so"

echo -e "${GREEN}Installing phpBolt from ${bolt_src} -> ${php_ext_dir}/bolt.so${NC}"
sudo mkdir -p "${php_ext_dir}"
sudo cp "${bolt_src}" "${php_ext_dir}/bolt.so"
sudo chmod 644 "${php_ext_dir}/bolt.so"

sudo mkdir -p "$(dirname "${ini_file}")" "${cli_conf_dir}" "${apache_conf_dir}"
echo "${bolt_ini_line}" | sudo tee "${ini_file}" >/dev/null
echo "${bolt_ini_line}" | sudo tee "${cli_conf_dir}/99-bolt.ini" >/dev/null
echo "${bolt_ini_line}" | sudo tee "${apache_conf_dir}/99-bolt.ini" >/dev/null
command -v phpenmod >/dev/null 2>&1 && sudo phpenmod -v "${PHP_VERSION}" bolt 2>/dev/null || true

sudo update-alternatives --install /usr/bin/php php "/usr/bin/${php_bin}" 100 2>/dev/null || true
sudo update-alternatives --set php "/usr/bin/${php_bin}" 2>/dev/null || true

if ! ${php_bin} -m 2>/dev/null | grep -qi '^bolt$'; then
 echo -e "${RED}Error: ${php_bin} still does not load bolt.${NC}" >&2
 ${php_bin} -m 2>&1 | tail -10 || true
 exit 1
fi

if ! php -m 2>/dev/null | grep -qi '^bolt$'; then
 echo -e "${YELLOW}Warning: default 'php' is not ${php_bin}. Use: ${php_bin} artisan ...${NC}" >&2
else
 echo -e "${GREEN}Default php loads phpBolt.${NC}"
fi

echo -e "${GREEN}phpBolt OK. Run migrations with:${NC}"
echo "  cd ${APP_DIR} && php artisan migrate --force"
echo "  # or: ${php_bin} artisan migrate --force"
