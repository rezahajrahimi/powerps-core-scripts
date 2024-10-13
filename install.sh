#!/bin/bash

# Set error handling
set -e

# Define variables with quotes
APP_NAME="powerps-core"
DB_PASSWORD=$(openssl rand -base64 32)
REPO_URL="https://github.com/rezahajrahimi/powerps-core.git"

# Define configurable paths
INSTALL_DIR="/var/www/html/${APP_NAME}"
HTML_DIR="${INSTALL_DIR}/html"
COMPOSER_DIR="${INSTALL_DIR}/composer"
LOG_DIR="${INSTALL_DIR}/logs"
APACHE_CONF="${INSTALL_DIR}/apache.conf"

# Check for dependencies
# if ! command -v git &> /dev/null; then
#   echo "Error: git is not installed. Please install git and try again."
#   exit 1
# fi

# if ! command -v composer &> /dev/null; then
#   echo "Error: composer is not installed. Please install composer and try again."
#   exit 1
# fi

# if ! command -v apache2 &> /dev/null; then
#   echo "Error: apache2 is not installed. Please install apache2 and try again."
#   exit 1
# fi

# Install PHP 8.3 with necessary extensions
sudo add-apt-repository ppa:ondrej/php
sudo apt-get update
sudo apt-get install -y php8.3 php8.3-fpm php8.3-mysql php8.3-curl php8.3-gd php8.3-mbstring php8.3-xml php8.3-zip php8.3-bcmath php8.3-opcache

# Install other dependencies
sudo apt-get install -y git composer apache2 mysql-server

# Create install directory
if [ -d "${INSTALL_DIR}" ]; then
  echo "Directory ${INSTALL_DIR} already exists. Deleting it..."
  sudo rm -rf "${INSTALL_DIR}"
fi

sudo mkdir -p "${INSTALL_DIR}"
sudo chown -R "$USER:$USER" "${INSTALL_DIR}"

# Clone repository
git clone "${REPO_URL}" "${INSTALL_DIR}"

# Install composer dependencies
cd "${INSTALL_DIR}"
composer install

# Check if Apache configuration file exists
if [ -f "/etc/apache2/sites-available/${APP_NAME}.conf" ]; then
  echo "Error: Apache configuration file already exists. Please choose a different name for your app."
  exit 1
fi

# Configure apache
sudo cp "${INSTALL_DIR}/${APACHE_CONF}" /etc/apache2/sites-available/
sudo a2ensite "${APP_NAME}"
sudo service apache2 restart

# Create logs directory
sudo mkdir -p "${LOG_DIR}"
sudo chown -R "$USER:$USER" "${LOG_DIR}"

# Create html directory
sudo mkdir -p "${HTML_DIR}"
sudo chown -R "$USER:$USER" "${HTML_DIR}"

# Create symbolic link
sudo ln -s "${INSTALL_DIR}/public" "${HTML_DIR}"

# Check if database exists
if mysql -u root -p${DB_PASSWORD} -e "SHOW DATABASES LIKE '${APP_NAME}';" &> /dev/null; then
  echo "Error: Database already exists. Please choose a different name for your app."
  exit 1
fi

# Create database and user
mysql -u root -p${DB_PASSWORD} -e "CREATE DATABASE ${APP_NAME};"
mysql -u root -p${DB_PASSWORD} -e "GRANT ALL ON ${APP_NAME}.* TO ${APP_NAME}@localhost IDENTIFIED BY '${DB_PASSWORD}';"
mysql -u root -p${DB_PASSWORD} -e "FLUSH PRIVILEGES;"

# Set database password
sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=${DB_PASSWORD}/" "${INSTALL_DIR}/.env"

# Load bolt extension
echo "extension=bolt.so" | sudo tee -a /etc/php/8.3/apache2/php.ini
sudo service apache2 restart

# Log success
echo "Installation complete!"

# Display instructions
echo "Please visit http://${APP_NAME}.localhost in your web browser to access the application."
echo "Please note that you may need to configure your hosts file to access the application."
