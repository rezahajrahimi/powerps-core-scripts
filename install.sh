#!/bin/bash

# Color codes
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Pretty title
echo -e "${CYAN}==============================${NC}"
echo -e "${YELLOW}  Setting up or Updating your Laravel Project${NC}"
echo -e "${CYAN}==============================${NC}"

# Updating package lists
echo -e "${GREEN}Updating package lists...${NC}"
sudo apt-get update

# Installing necessary packages
echo -e "${GREEN}Installing necessary packages...${NC}"
sudo apt-get install -y apache2 mysql-server php8.3 php8.3-mysql libapache2-mod-php8.3 php8.3-cli php8.3-zip php8.3-xml php8.3-mbstring php8.3-curl composer unzip git expect

        # Copy bolt.so extension to PHP extensions directory
        echo -e "${GREEN}Copying bolt.so extension...${NC}"
        sudo cp /path/to/your/project/folder/bolt.so /usr/lib/php/20230831/

        # Get the location of the php.ini file
        PHP_INI_FILE=$(php --ini | grep "Loaded Configuration File" | cut -d ":" -f 2- | tr -d " ")


# Secure MySQL Installation using expect
echo -e "${GREEN}Securing MySQL Installation...${NC}"
SECURE_MYSQL=$(expect -c "
set timeout 10
spawn sudo mysql_secure_installation
expect \"VALIDATE PASSWORD COMPONENT can be used to test passwords\"
send \"n\r\"
expect \"New password:\"
send \"yourpassword\r\"
expect \"Re-enter new password:\"
send \"yourpassword\r\"
expect \"Do you wish to continue with the password provided?\"
send \"y\r\"
expect \"Remove anonymous users?\"
send \"y\r\"
expect \"Disallow root login remotely?\"
send \"y\r\"
expect \"Remove test database and access to it?\"
send \"y\r\"
expect \"Reload privilege tables now?\"
send \"y\r\"
expect eof
")

echo "$SECURE_MYSQL"

# Create MySQL database and user
DB_NAME='laravel_db'
DB_USER='laravel_user'
DB_PASS='password'
echo -e "${GREEN}Creating MySQL database and user...${NC}"
sudo mysql -e "CREATE DATABASE ${DB_NAME};"
sudo mysql -e "CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
sudo mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';"
sudo mysql -e "FLUSH PRIVILEGES;"

# Check if the project directory exists
if [ -d "/var/www/html/laravel-app" ]; then
    # If it exists, update the repository
    echo -e "${GREEN}Updating the Laravel project repository...${NC}"
    cd /var/www/html/laravel-app
    git pull origin main

    # Install Composer dependencies
    echo -e "${GREEN}Installing Composer dependencies...${NC}"
    composer install
else
    # Clone the Laravel project repository
    echo -e "${GREEN}Cloning Laravel project repository...${NC}"
    git clone https://github.com/rezahajrahimi/powerps-core /var/www/html/laravel-app
    cd /var/www/html/laravel-app

    # Install Composer dependencies
    echo -e "${GREEN}Installing Composer dependencies...${NC}"
    composer install

    # Prompt user for .env variables only if .env does not exist
    if [ ! -f ".env" ]; then
        echo -e "${CYAN}Please enter the following environment variables for your Laravel project:${NC}"
        read -p "App Name: " APP_NAME
        read -p "Environment (local/production): " APP_ENV
        read -p "App Debug (true/false): " APP_DEBUG
        read -p "App URL: " APP_URL

        read -p "NOWPayments API Key: " NOWPAYMENTS_API_KEY
        read -p "Telegram Bot Token: " TELEGRAM_BOT_TOKEN
        read -p "Telegram Admin ID: " TELEGRAM_ADMIN_ID
        read -p "Zarinpal Merchant ID: " ZARINPAL_MERCHANT_ID
        read -p "URL for Front-End Project: " FRONT_URL

        # Set up Laravel environment
        echo -e "${GREEN}Setting up Laravel environment...${NC}"
        cp .env.example .env

        # Configure .env file with user input
        echo -e "${GREEN}Configuring .env file...${NC}"
        sed -i "s/^APP_NAME=.*/APP_NAME=${APP_NAME}/" .env
        sed -i "s/^APP_ENV=.*/APP_ENV=${APP_ENV}/" .env
        sed -i "s/^APP_DEBUG=.*/APP_DEBUG=${APP_DEBUG}/" .env
        sed -i "s|^APP_URL=.*|APP_URL=${APP_URL}|" .env

        sed -i "s/^DB_DATABASE=.*/DB_DATABASE=${DB_NAME}/" .env
        sed -i "s/^DB_USERNAME=.*/DB_USERNAME=${DB_USER}/" .env
        sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=${DB_PASS}/" .env

        echo "NOWPAYMENTS_API_KEY=${NOWPAYMENTS_API_KEY}" >> .env
        echo "TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}" >> .env
        echo "TELEGRAM_ADMIN_ID=${TELEGRAM_ADMIN_ID}" >> .env
        echo "ZARINPAL_MERCHANT_ID=${ZARINPAL_MERCHANT_ID}" >> .env
        echo "FRONT_URL=${FRONT_URL}" >> .env

        # Generate app key
        echo -e "${GREEN}Generating app key...${NC}"
        php artisan key:generate

        # Run migrations
        echo -e "${GREEN}Running migrations...${NC}"
        php artisan migrate

        # Install PHPMyAdmin
        echo -e "${GREEN}Installing PHPMyAdmin...${NC}"
        cd /var/www/html
        wget https://www.phpmyadmin.net/downloads/phpMyAdmin-latest-all-languages.zip
        unzip phpMyAdmin-latest-all-languages.zip
        mv phpMyAdmin-*-all-languages phpmyadmin
        rm phpMyAdmin-latest-all-languages.zip


        # Add bolt.so extension to main php.ini
        echo -e "${GREEN}Adding bolt.so extension to php.ini...${NC}"
        sudo sh -c "echo 'extension=bolt.so' >> ${PHP_INI_FILE}"

        # Restart Apache to apply changes
        echo -e "${GREEN}Restarting Apache to apply changes...${NC}"
        sudo systemctl restart apache2
    fi
fi

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

echo -e "${CYAN}==============================${NC}"
echo -e "${YELLOW}  Setup Complete!${NC}"
echo -e "${CYAN}==============================${NC}"
echo -e "${GREEN}Laravel project with MySQL, PHPMyAdmin setup, and scheduled command complete!${NC}"
