#!/bin/bash
# Remove legacy phpBolt configuration from older PowerPs installs.
# Open-source releases no longer need the bolt extension. Safe to re-run.
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

trim_whitespace() {
 local s="$1"
 s="${s#"${s%%[![:space:]]*}"}"
 s="${s%"${s##*[![:space:]]}"}"
 printf '%s' "${s}"
}

php_bin="php${PHP_VERSION}"
if ! command -v "${php_bin}" >/dev/null 2>&1; then
 if command -v php >/dev/null 2>&1; then
  php_bin="php"
  PHP_VERSION="$("${php_bin}" -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
 else
  echo -e "${RED}Error: PHP is not installed. Run install.sh first.${NC}" >&2
  exit 1
 fi
fi

php_ext_dir="$(trim_whitespace "$(${php_bin} -n -i 2>/dev/null | awk -F'=> ' '/^extension_dir/{print $2; exit}')")"
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

found=0
for path in \
 "${cli_conf_dir}/99-bolt.ini" \
 "${apache_conf_dir}/99-bolt.ini" \
 "${ini_file}" \
 "${php_ext_dir}/bolt.so" \
 "${php_ext_dir} /bolt.so"
do
 if [ -f "${path}" ]; then
  found=1
  break
 fi
done

if [ "${found}" -eq 0 ]; then
 shopt -s nullglob
 for path in \
  "${cli_conf_dir}"/*bolt*.ini \
  "${apache_conf_dir}"/*bolt*.ini
 do
  if [ -f "${path}" ]; then
   found=1
   break
  fi
 done
 shopt -u nullglob
fi

if [ "${found}" -eq 0 ]; then
 echo -e "${GREEN}No legacy phpBolt configuration found. Nothing to remove.${NC}"
 exit 0
fi

echo -e "${YELLOW}Removing legacy phpBolt configuration...${NC}"
sudo rm -f \
 "${cli_conf_dir}/99-bolt.ini" \
 "${apache_conf_dir}/99-bolt.ini" \
 "${cli_conf_dir}"/*bolt*.ini \
 "${apache_conf_dir}"/*bolt*.ini \
 "${ini_file}" \
 "${php_ext_dir}/bolt.so" \
 "${php_ext_dir} /bolt.so" 2>/dev/null || true
if command -v phpdismod >/dev/null 2>&1; then
 sudo phpdismod -v "${PHP_VERSION}" bolt 2>/dev/null || true
fi
sudo rmdir "${php_ext_dir} " 2>/dev/null || true

if command -v apache2ctl >/dev/null 2>&1; then
 sudo systemctl restart apache2 2>/dev/null || sudo service apache2 restart 2>/dev/null || true
fi

echo -e "${GREEN}Legacy phpBolt configuration removed.${NC}"
echo -e "${GREEN}Run install/update again, then migrate:${NC}"
echo "  sudo bash -c \"\$(curl -sL https://raw.githubusercontent.com/rezahajrahimi/powerps-core-scripts/refs/heads/main/install.sh)\" @ install"
echo "  cd ${APP_DIR} && php artisan migrate --force"
