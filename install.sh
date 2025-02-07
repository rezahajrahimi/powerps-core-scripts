#!/bin/bash

# Color codes
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Pretty title
echo -e "${CYAN}==============================${NC}"
echo -e "${YELLOW}  Setting up or Updating your core and WebApp PowerPs${NC}"
echo -e "${CYAN}==============================${NC}"

# File to store subdomains
SUBDOMAIN_FILE="subdomains.conf"

# Check if the subdomains file exists
if [ -f "$SUBDOMAIN_FILE" ]; then
    source $SUBDOMAIN_FILE

    # Ask user if they want to install or uninstall
    echo -e "${YELLOW}Subdomains are already set. Do you want to install or uninstall?${NC}"
    select choice in "Install" "Uninstall"; do
        case $choice in
            Install)
                break
                ;;
            Uninstall)
                echo -e "${GREEN}Starting uninstallation process...${NC}"
                
                # Function to log errors
                log_error() {
                    echo -e "${RED}Error: $1${NC}"
                }

                # Function to check if a command succeeded
                check_command() {
                    if [ $? -ne 0 ]; then
                        log_error "$1"
                        return 1
                    fi
                    return 0
                }

                # 1. Stop running services
                echo -e "${GREEN}Stopping services...${NC}"
                # Stop Laravel processes
                if pgrep -f artisan > /dev/null; then
                    pkill -f artisan
                    check_command "Failed to stop Laravel processes"
                fi

                # 2. Remove Laravel application
                echo -e "${GREEN}Removing Laravel application...${NC}"
                if [ -d "/var/www/html/laravel-app" ]; then
                    sudo rm -rf /var/www/html/laravel-app
                    check_command "Failed to remove Laravel application directory"
                fi

                # 3. Remove WebApp
                echo -e "${GREEN}Removing WebApp...${NC}"
                if [ -d "/var/www/html/powerps-webapp" ]; then
                    sudo rm -rf /var/www/html/powerps-webapp
                    check_command "Failed to remove WebApp directory"
                fi

                # 4. Remove Database and User
                echo -e "${GREEN}Removing database and user...${NC}"
                if mysql -e "USE ${DB_NAME}" 2>/dev/null; then
                    sudo mysql -e "DROP DATABASE IF EXISTS ${DB_NAME};"
                    check_command "Failed to drop database"
                    
                    sudo mysql -e "DROP USER IF EXISTS '${DB_USER}'@'localhost';"
                    check_command "Failed to drop database user"
                    
                    sudo mysql -e "FLUSH PRIVILEGES;"
                    check_command "Failed to flush privileges"
                fi

                # 5. Remove Apache Configurations
                echo -e "${GREEN}Removing Apache configurations...${NC}"
                if [ -f "/etc/apache2/sites-available/powerps-core.conf" ]; then
                    sudo a2dissite powerps-core 2>/dev/null
                    sudo rm -f /etc/apache2/sites-available/powerps-core.conf
                    check_command "Failed to remove core virtual host"
                fi

                if [ -f "/etc/apache2/sites-available/powerps-webapp.conf" ]; then
                    sudo a2dissite powerps-webapp 2>/dev/null
                    sudo rm -f /etc/apache2/sites-available/powerps-webapp.conf
                    check_command "Failed to remove webapp virtual host"
                fi

                # 6. Restart Apache if it's running
                if systemctl is-active --quiet apache2; then
                    echo -e "${GREEN}Restarting Apache...${NC}"
                    sudo systemctl restart apache2
                    check_command "Failed to restart Apache"
                fi

                # 7. Remove PHPMyAdmin if exists
                if [ -d "/var/www/html/phpmyadmin" ]; then
                    echo -e "${GREEN}Removing PHPMyAdmin...${NC}"
                    sudo rm -rf /var/www/html/phpmyadmin
                    check_command "Failed to remove PHPMyAdmin"
                fi

                # 8. Remove Cron Jobs
                echo -e "${GREEN}Removing cron jobs...${NC}"
                TEMP_CRON=$(mktemp)
                crontab -l 2>/dev/null | grep -v 'laravel-app' | grep -v 'powerps' | grep -v 'artisan' > "$TEMP_CRON"
                crontab "$TEMP_CRON"
                rm -f "$TEMP_CRON"
                check_command "Failed to update cron jobs"

                # 9. Remove configuration file
                if [ -f "$SUBDOMAIN_FILE" ]; then
                    rm -f "$SUBDOMAIN_FILE"
                    check_command "Failed to remove subdomain configuration file"
                fi

                # 10. Remove hosts entries
                if [ -n "$LARAVEL_SUBDOMAIN" ] && [ -n "$HTML5_SUBDOMAIN" ]; then
                    sudo sed -i "/${LARAVEL_SUBDOMAIN}/d" /etc/hosts
                    sudo sed -i "/${HTML5_SUBDOMAIN}/d" /etc/hosts
                    check_command "Failed to remove hosts entries"
                fi

                # Stop Laravel Queue Service
                if systemctl is-active --quiet laravel-queue; then
                    echo -e "${GREEN}Stopping Laravel Queue Service...${NC}"
                    sudo systemctl stop laravel-queue
                    sudo systemctl disable laravel-queue
                    sudo rm -f /etc/systemd/system/laravel-queue.service
                    sudo systemctl daemon-reload
                fi

                echo -e "${GREEN}Uninstallation completed successfully!${NC}"
                echo -e "${YELLOW}Note: Some system packages (Apache, MySQL, PHP) were left installed.${NC}"
                echo -e "${YELLOW}If you want to remove them, please use: sudo apt remove apache2 mysql-server php8.3${NC}"
                exit 0
                ;;
        esac
    done
else
    # Enable line editing
    if [ -t 0 ]; then
        stty -echo
        stty icanon
    fi

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

    # Reset terminal settings
    if [ -t 0 ]; then
        stty echo
    fi

    echo "LARAVEL_SUBDOMAIN=$LARAVEL_SUBDOMAIN" > $SUBDOMAIN_FILE
    echo "HTML5_SUBDOMAIN=$HTML5_SUBDOMAIN" >> $SUBDOMAIN_FILE
fi
# Update package lists and install necessary packages
echo -e "${GREEN}Updating package lists and installing necessary packages...${NC}"
sudo apt-get update
sudo apt-get install -y apache2 mysql-server php8.3 php8.3-mysql libapache2-mod-php8.3 php8.3-cli php8.3-zip php8.3-xml php8.3-mbstring php8.3-curl php8.3-gd php-imagick libmagickwand-dev composer unzip git expect || {
    echo -e "${RED}خطا در نصب پکیج‌ها${NC}"
    exit 1
}

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
DB_NAME='powerps_db'
DB_USER='powerps_user'
DB_PASS=$(openssl rand -base64 12)

echo -e "${GREEN}Creating MySQL database and user...${NC}"
sudo mysql -e "CREATE DATABASE ${DB_NAME};"
sudo mysql -e "CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
sudo mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';"
sudo mysql -e "FLUSH PRIVILEGES;"

# Check if the Laravel project directory exists
if [ -d "/var/www/html/laravel-app" ]; then
    # If it exists, update the repository
    echo -e "${GREEN}Updating the Laravel project repository...${NC}"
    cd /var/www/html/laravel-app
    git pull origin main
else
    # Clone the Laravel project repository
    echo -e "${GREEN}Cloning Laravel project repository...${NC}"
    git clone https://github.com/rezahajrahimi/powerps-core /var/www/html/laravel-app || {
        echo -e "${RED}خطا در کلون کردن مخزن${NC}"
        exit 1
    }
    cd /var/www/html/laravel-app
fi

# تنظیم مجوزها در هر دو حالت نصب اولیه و نصب مجدد
echo -e "${GREEN}Setting permissions for Laravel directories...${NC}"
sudo chown -R www-data:www-data /var/www/html/laravel-app/storage
sudo chown -R www-data:www-data /var/www/html/laravel-app/bootstrap/cache
sudo chmod -R 775 /var/www/html/laravel-app/storage
sudo chmod -R 775 /var/www/html/laravel-app/bootstrap/cache

# Restart Apache to apply changes
echo -e "${GREEN}Restarting Apache to apply changes...${NC}"
sudo systemctl restart apache2

# Install Composer dependencies
echo -e "${GREEN}Installing Composer dependencies...${NC}"
composer install


# Set up environment variables if not already set
echo -e "${GREEN}Setting up environment variables...${NC}"
if [ ! -f "/var/www/html/laravel-app/.env" ]; then
    cp /var/www/html/laravel-app/.env.example /var/www/html/laravel-app/.env
    sed -i '/APP_NAME/d' /var/www/html/laravel-app/.env
    echo "APP_NAME=Laravel" >> /var/www/html/laravel-app/.env

    // check if APP_ENV is already set remove it and add it again
    sed -i '/APP_ENV/d' /var/www/html/laravel-app/.env
    echo "APP_ENV=production" >> /var/www/html/laravel-app/.env
    sed -i '/APP_KEY/d' /var/www/html/laravel-app/.env
    echo "APP_KEY=" >> /var/www/html/laravel-app/.env

    sed -i '/APP_DEBUG/d' /var/www/html/laravel-app/.env
    echo "APP_DEBUG=true" >> /var/www/html/laravel-app/.env

    sed -i '/APP_URL/d' /var/www/html/laravel-app/.env
    echo "APP_URL=https://${LARAVEL_SUBDOMAIN}" >> /var/www/html/laravel-app/.env
    echo "FRONT_URL=https://${HTML5_SUBDOMAIN}" >> /var/www/html/laravel-app/.env

    sed -i '/DB_CONNECTION/d' /var/www/html/laravel-app/.env
    echo "DB_CONNECTION=mysql" >> /var/www/html/laravel-app/.env
    sed -i '/DB_HOST/d' /var/www/html/laravel-app/.env
    echo "DB_HOST=127.0.0.1" >> /var/www/html/laravel-app/.env
    sed -i '/DB_PORT/d' /var/www/html/laravel-app/.env
    echo "DB_PORT=3306" >> /var/www/html/laravel-app/.env
    sed -i '/DB_DATABASE/d' /var/www/html/laravel-app/.env
    sed -i '/DB_USERNAME/d' /var/www/html/laravel-app/.env
    sed -i '/DB_PASSWORD/d' /var/www/html/laravel-app/.env
    echo "DB_DATABASE=${DB_NAME}" >> /var/www/html/laravel-app/.env
    echo "DB_USERNAME=${DB_USER}" >> /var/www/html/laravel-app/.env
    echo "DB_PASSWORD=${DB_PASS}" >> /var/www/html/laravel-app/.env
    # read & set telegram token
    # Enable line editing
    if [ -t 0 ]; then
        stty -echo
        stty icanon
    fi

    # Telegram Bot Token validation
    while true; do
        read -e -p "Enter your Bot token (e.g., botxxxxxxxxxxxxxxx): " TELEGRAM_BOT_TOKEN
        if [[ $TELEGRAM_BOT_TOKEN =~ ^bot[0-9]{8,}:[A-Za-z0-9_-]{35,}$ ]]; then
            break
        else
            echo -e "${YELLOW}Invalid bot token format. It should start with 'bot' followed by numbers and characters.${NC}"
        fi
    done
    sed -i '/TELEGRAM_BOT_TOKEN/d' /var/www/html/laravel-app/.env
    echo "TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}" >> /var/www/html/laravel-app/.env

    # Telegram Admin ID validation
    while true; do
        read -e -p "Enter your Bot admin ID (e.g., 123456789): " TELEGRAM_ADMIN_ID
        if [[ $TELEGRAM_ADMIN_ID =~ ^[0-9]{6,}$ ]]; then
            break
        else
            echo -e "${YELLOW}Invalid admin ID format. It should be a number with at least 6 digits.${NC}"
        fi
    done
    sed -i '/TELEGRAM_ADMIN_ID/d' /var/www/html/laravel-app/.env
    echo "TELEGRAM_ADMIN_ID=${TELEGRAM_ADMIN_ID}" >> /var/www/html/laravel-app/.env

    # Set Telegram API endpoint
    sed -i '/TELEGRAM_API_ENDPOINT/d' /var/www/html/laravel-app/.env
    echo "TELEGRAM_API_ENDPOINT=https://api.telegram.org" >> /var/www/html/laravel-app/.env

    # Optional Zarinpal Merchant ID
    read -e -p "Enter your Zarinpal Merchant ID (optional, press Enter to skip): " ZARINPAL_MERCHANT_ID
    if [ ! -z "$ZARINPAL_MERCHANT_ID" ]; then
        if [[ $ZARINPAL_MERCHANT_ID =~ ^[a-zA-Z0-9]{8}-[a-zA-Z0-9]{4}-[a-zA-Z0-9]{4}-[a-zA-Z0-9]{4}-[a-zA-Z0-9]{12}$ ]]; then
            sed -i '/ZARINPAL_MERCHANT_ID/d' /var/www/html/laravel-app/.env
            echo "ZARINPAL_MERCHANT_ID=${ZARINPAL_MERCHANT_ID}" >> /var/www/html/laravel-app/.env
        else
            echo -e "${YELLOW}Invalid Zarinpal Merchant ID format. Setting empty value.${NC}"
            sed -i '/ZARINPAL_MERCHANT_ID/d' /var/www/html/laravel-app/.env
            echo "ZARINPAL_MERCHANT_ID=" >> /var/www/html/laravel-app/.env
        fi
    else
        sed -i '/ZARINPAL_MERCHANT_ID/d' /var/www/html/laravel-app/.env
        echo "ZARINPAL_MERCHANT_ID=" >> /var/www/html/laravel-app/.env
    fi

    # Optional NOWPayments API Key
    read -e -p "Enter your NOWPAYMENTS API KEY (optional, press Enter to skip): " NOWPAYMENTS_API_KEY
    if [ ! -z "$NOWPAYMENTS_API_KEY" ]; then
        if [[ $NOWPAYMENTS_API_KEY =~ ^[A-Za-z0-9-]{36}$ ]]; then
            sed -i '/NOWPAYMENTS_API_KEY/d' /var/www/html/laravel-app/.env
            echo "NOWPAYMENTS_API_KEY=${NOWPAYMENTS_API_KEY}" >> /var/www/html/laravel-app/.env
        else
            echo -e "${YELLOW}Invalid NOWPayments API key format. Setting empty value.${NC}"
            sed -i '/NOWPAYMENTS_API_KEY/d' /var/www/html/laravel-app/.env
            echo "NOWPAYMENTS_API_KEY=" >> /var/www/html/laravel-app/.env
        fi
    else
        sed -i '/NOWPAYMENTS_API_KEY/d' /var/www/html/laravel-app/.env
        echo "NOWPAYMENTS_API_KEY=" >> /var/www/html/laravel-app/.env
    fi

    # Reset terminal settings
    if [ -t 0 ]; then
        stty echo
    fi

fi
# Generate app key
echo -e "${GREEN}Generating app key...${NC}"
php artisan key:generate

# Run migrations
echo -e "${GREEN}Running migrations...${NC}"
php artisan migrate
# Run Link Storage
php artisan storage:link
# Check if phpMyAdmin is installed
if [ -d "/var/www/html/phpmyadmin" ]; then
    echo -e "${GREEN}phpMyAdmin is already installed.${NC}"
else
    # Install PHPMyAdmin
    echo -e "${GREEN}Installing PHPMyAdmin...${NC}"
    cd /var/www/html
    wget https://www.phpmyadmin.net/downloads/phpMyAdmin-latest-all-languages.zip
    unzip phpMyAdmin-latest-all-languages.zip
    mv phpMyAdmin-*-all-languages phpmyadmin
    rm phpMyAdmin-latest-all-languages.zip
fi

# Set up Apache virtual host for Laravel
echo -e "${GREEN}Setting up Apache virtual host for Laravel...${NC}"
sudo bash -c "cat <<EOT > /etc/apache2/sites-available/powerps-core.conf
<VirtualHost *:80>
    ServerName ${LARAVEL_SUBDOMAIN}
    DocumentRoot /var/www/html/laravel-app/public
    <Directory /var/www/html/laravel-app>
        AllowOverride All
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/laravel-error.log
    CustomLog \${APACHE_LOG_DIR}/laravel-access.log combined
</VirtualHost>
EOT"

# Check if the HTML5 project directory exists
if [ -d "/var/www/html/powerps-webapp" ]; then
    echo -e "${GREEN}Removing existing HTML5 project directory...${NC}"
    sudo rm -rf /var/www/html/powerps-webapp
fi

# Clone the HTML5 project repository
echo -e "${GREEN}Cloning HTML5 project repository...${NC}"
git clone https://github.com/rezahajrahimi/powerps-webapp /var/www/html/powerps-webapp || {
    echo -e "${RED}خطا در کلون کردن مخزن${NC}"
    exit 1
}

# Change to project directory
cd /var/www/html/powerps-webapp

# Create new .env file with BASE_URL
echo "BASE_URL=https://${LARAVEL_SUBDOMAIN}" > assets/.env

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
sudo a2ensite powerps-core
sudo a2ensite powerps-webapp
sudo a2enmod rewrite
sudo systemctl restart apache2

# Add domain entries to /etc/hosts
echo "127.0.0.1 ${LARAVEL_SUBDOMAIN}" | sudo tee -a /etc/hosts
echo "127.0.0.1 ${HTML5_SUBDOMAIN}" | sudo tee -a /etc/hosts

# Add schedule to cron job
echo -e "${GREEN}Adding schedule to cron job...${NC}"
(crontab -l ; echo "* * * * * cd /var/www/html/laravel-app && php artisan schedule:run >> /dev/null 2>&1") | crontab -

# Ensure services start on reboot
echo -e "${GREEN}Ensuring services start on reboot...${NC}"
(crontab -l ; echo "@reboot systemctl restart apache2") | crontab -
(crontab -l ; echo "@reboot systemctl restart mysql") | crontab -
(crontab -l ; echo "@reboot /usr/bin/php /var/www/html/laravel-app/artisan serve &") | crontab -

# Completion message
echo -e "${CYAN}==============================${NC}"
echo -e "${YELLOW}  Setup Complete!${NC}"
echo -e "${CYAN}==============================${NC}"

# Set Telegram Webhook
echo -e "${GREEN}Setting up Telegram webhook...${NC}"
WEBHOOK_URL="https://${LARAVEL_SUBDOMAIN}/api/telegram/webhooks/inbound"
TELEGRAM_API="https://api.telegram.org/${TELEGRAM_BOT_TOKEN}/setWebhook?url=${WEBHOOK_URL}"

# Send request to set webhook
WEBHOOK_RESPONSE=$(curl -s "$TELEGRAM_API")

# Check if webhook was set successfully
if [[ $WEBHOOK_RESPONSE == *"\"ok\":true"* ]]; then
    echo -e "${GREEN}Telegram webhook set successfully!${NC}"
    echo -e "${GREEN}Webhook URL: ${WEBHOOK_URL}${NC}"
else
    echo -e "${YELLOW}Warning: Failed to set Telegram webhook. Please set it manually:${NC}"
    echo -e "${YELLOW}${TELEGRAM_API}${NC}"
fi

echo -e "${GREEN}PowerPs installation complete!${NC}"

# اضافه کردن لاگ
log_file="/var/log/powerps_install.log"
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$log_file"
}

# اضافه کردن تابع پشتیبان‌گیری
backup_existing() {
    if [ -d "$1" ]; then
        backup_dir="${1}_backup_$(date +%Y%m%d_%H%M%S)"
        mv "$1" "$backup_dir"
        log_message "Backed up $1 to $backup_dir"
    fi
}

# اضافه کردن بررسی پیش‌نیازها
check_requirements() {
    # بررسی فضای دیسک
    free_space=$(df -m / | awk 'NR==2 {print $4}')
    if [ "$free_space" -lt 1000 ]; then
        echo -e "${RED}Not enough disk space. At least 1GB required${NC}"
        exit 1
    fi
    
    # بررسی رم
    total_ram=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$total_ram" -lt 1024 ]; then
        echo -e "${YELLOW}Warning: Less than 1GB RAM available${NC}"
    fi
}

# Create and configure Laravel Queue Service
echo -e "${GREEN}Setting up Laravel Queue Service...${NC}"
sudo bash -c "cat > /etc/systemd/system/laravel-queue.service << 'EOL'
[Unit]
Description=Laravel Queue Worker
After=network.target mysql.service apache2.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/html/laravel-app/artisan queue:work
StandardOutput=append:/var/log/laravel-queue.log
StandardError=append:/var/log/laravel-queue.error.log

[Install]
WantedBy=multi-user.target
EOL"

# Reload systemd and start queue service
sudo systemctl daemon-reload
sudo systemctl enable laravel-queue
sudo systemctl start laravel-queue

# Remove old artisan serve from cron
crontab -l | grep -v '/usr/bin/php /var/www/html/laravel-app/artisan serve' | crontab -
