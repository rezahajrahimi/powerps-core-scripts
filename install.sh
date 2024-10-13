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

# Install PHP 8.3 with necessary extensions
sudo add-apt-repository ppa:ondrej/php
sudo apt-get update
sudo apt-get install -y php8.3 php8.3-fpm php8.3-mysql php8.3-curl php8.3-gd php8.3-mbstring php8.3-xml php8.3-zip php8.3-bcmath php8.3-opcache

# Copy bolt.so extension to PHP extensions directory
sudo cp "${INSTALL_DIR}/bolt.so" /usr/lib/php/20230831/

# Get the location of the php.ini file
PHP_INI_FILE=$(php --ini | grep "Loaded Configuration File" | cut -d ":" -f 2- | tr -d " ")

# Add bolt.so extension to main php.ini
sudo echo "extension=bolt.so" | sudo tee -a "${PHP_INI_FILE}"

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



    # Generate app key
    echo -e "${GREEN}Generating app key...${NC}"
    php artisan key:generate

    # Run migrations
    echo -e "${GREEN}Running migrations...${NC}"
    php artisan migrate

    # Check if database exists
if mysql -u root -p${DB_PASSWORD} -e "SHOW DATABASES LIKE '${APP_NAME}';" &> /dev/null; then
  echo "Error: Database already exists. Please choose a different name for your app."
  exit 1
fi

    
    # Install PHPMyAdmin
    echo -e "${GREEN}Installing PHPMyAdmin...${NC}"
    cd /var/www/html
    wget https://www.phpmyadmin.net/downloads/phpMyAdmin-latest-all-languages.zip
    unzip phpMyAdmin-latest-all-languages.zip
    mv phpMyAdmin-*-all-languages phpmyadmin
    rm phpMyAdmin-latest-all-languages.zip

    # Restart Apache to apply changes
    echo -e "${GREEN}Restarting Apache to apply changes...${NC}"
    sudo systemctl restart apache2

    # Set up Apache virtual host for Laravel
    echo -e "${GREEN}Setting up Apache virtual host for Laravel...${NC}"
    sudo cat > /etc/apache2/sites-available/laravel.conf <<EOF
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html/laravel-app/public

    <Directory /var/www/html/laravel-app>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF

# Enable new site and rewrite module
    echo -e "${GREEN}Enabling new site and rewrite module...${NC}"
    sudo a2ensite laravel
    sudo a2enmod rewrite
    sudo systemctl restart apache2

    # Add schedule to cron job
    echo -e "${GREEN}Adding schedule to cron job...${NC}"
    (crontab -l ; echo "* * * * * cd /var/www/html/laravel-app && php artisan schedule:run >> /dev/null 2>&1") | crontab -

    # Ensure services start on reboot
    echo -e "${GREEN}Ensuring services start on reboot...${NC}"
    (crontab -l ; echo "@reboot systemctl restart apache2") | crontab -
    (crontab -l ; echo "@reboot systemctl restart mysql") | crontab -
    (crontab -l ; echo "@reboot /usr/bin/php /var/www/html/laravel-app/artisan serve &") | crontab -

    # Start Laravel server
    echo -e "${GREEN}Starting Laravel server...${NC}"
    cd /var/www/html/laravel-app
    php artisan serve &
fi

# Create logs directory
sudo mkdir -p "${LOG_DIR}"
sudo chown -R "$USER:$USER" "${LOG_DIR}"

# Create html directory
sudo mkdir -p "${HTML_DIR}"
sudo chown -R "$USER:$USER" "${HTML_DIR}"

# Create symbolic link
sudo ln -s "${INSTALL_DIR}/public" "${HTML_DIR}"


# Create database and user
mysql -u root -p${DB_PASSWORD} -e "CREATE DATABASE ${APP_NAME};"
mysql -u root -p${DB_PASSWORD} -e "GRANT ALL ON ${APP_NAME}.* TO ${APP_NAME}@localhost IDENTIFIED BY '${DB_PASSWORD}';"
mysql -u root -p${DB_PASSWORD} -e "FLUSH PRIVILEGES;"

# Set database password
sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=${DB_PASSWORD}/" "${INSTALL_DIR}/.env"

# Log success
echo "Installation complete!"

# Display instructions
echo "Please visit http://${APP_NAME}.localhost in your web browser to access the application."
echo "Please note that you may need to configure your hosts file to access the application."
