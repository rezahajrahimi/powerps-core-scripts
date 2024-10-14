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

# Update package lists and install necessary packages
echo -e "${GREEN}Updating package lists and installing necessary packages...${NC}"
sudo apt-get update
sudo apt-get install -y apache2 mysql-server php8.3 php8.3-mysql libapache2-mod-php8.3 php8.3-cli php8.3-zip php8.3-xml php8.3-mbstring php8.3-curl php8.3-gd composer unzip git expect

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
else
    # Clone the Laravel project repository
    echo -e "${GREEN}Cloning Laravel project repository...${NC}"
    git clone https://github.com/rezahajrahimi/powerps-core /var/www/html/laravel-app
    cd /var/www/html/laravel-app
fi

# Copy bolt.so extension to PHP extensions directory
echo -e "${GREEN}Copying bolt.so extension...${NC}"
sudo cp /var/www/html/laravel-app/bolt.so /usr/lib/php/20230831/
PHP_INI_FILE=$(php --ini | grep "Loaded Configuration File" | cut -d ":" -f 2- | tr -d " ")

# Add bolt.so extension to main php.ini
echo -e "${GREEN}Adding bolt.so extension to php.ini...${NC}"
sudo sh -c "echo 'extension=bolt.so' >> ${PHP_INI_FILE}"

# Restart Apache to apply changes
echo -e "${GREEN}Restarting Apache to apply changes...${NC}"
sudo systemctl restart apache2

# Install Composer dependencies
echo -e "${GREEN}Installing Composer dependencies...${NC}"
composer install

# Set permissions for Laravel storage and bootstrap/cache directories
echo -e "${GREEN}Setting permissions...${NC}"
sudo chown -R www-data:www-data /var/www/html/laravel-app/storage
sudo chown -R www-data:www-data /var/www/html/laravel-app/bootstrap/cache

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

# Set up Apache virtual host for Laravel
echo -e "${GREEN}Setting up Apache virtual host for Laravel...${NC}"
sudo bash -c 'cat <<EOT > /etc/apache2/sites-available/powerps.conf
<VirtualHost *:80>
    ServerName powerps
    DocumentRoot /var/www/html/laravel-app/public
    <Directory /var/www/html/laravel-app>
        AllowOverride All
    </Directory>
    ErrorLog ${APACHE_LOG_DIR}/laravel-error.log
    CustomLog ${APACHE_LOG_DIR}/laravel-access.log combined
</VirtualHost>
EOT'

# Enable Laravel virtual host
sudo a2ensite powerps
sudo a2enmod rewrite
sudo systemctl restart apache2

# Add test domain entry to /etc/hosts
echo '127.0.0.1 powerps' | sudo tee -a /etc/hosts

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

# Completion message
echo -e "${CYAN}==============================${NC}"
echo -e "${YELLOW}  Setup Complete!${NC}"
echo -e "${CYAN}==============================${NC}"
echo -e "${GREEN}Laravel project with MySQL, PHPMyAdmin setup, and scheduled command complete!${NC}"
