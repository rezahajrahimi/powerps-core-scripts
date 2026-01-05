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

# Pretty title
echo -e "${CYAN}==============================${NC}"
echo -e "${YELLOW}  Setting up or Updating your core and WebApp PowerPs${NC}"
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

# File to store subdomains
SUBDOMAIN_FILE="subdomains.conf"

# Check if the subdomains file exists
if [ -f "$SUBDOMAIN_FILE" ]; then
    source "$SUBDOMAIN_FILE"

    # Ask user if they want to install or uninstall
    echo -e "${YELLOW}Subdomains are already set. Do you want to install or uninstall?${NC}"
    select choice in "Install" "Uninstall"; do

        case $choice in
            Install)
                break
                ;;
            Uninstall)
                echo -e "${GREEN}Starting uninstallation process...${NC}"
                


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
                    backup_existing "/var/www/html/laravel-app"
                    sudo rm -rf /var/www/html/laravel-app || true
                    check_command "Failed to remove Laravel application directory"
                fi

                # 3. Remove WebApp
                echo -e "${GREEN}Removing WebApp...${NC}"
                if [ -d "/var/www/html/powerps-webapp" ]; then
                    backup_existing "/var/www/html/powerps-webapp"
                    sudo rm -rf /var/www/html/powerps-webapp || true
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

                # Confirm destructive action
                read -r -p "This will remove the application, database, and configs. Continue? (y/N): " CONFIRM_UNINSTALL
                if [[ ! "$CONFIRM_UNINSTALL" =~ ^[Yy]$ ]]; then
                    echo -e "${YELLOW}Uninstall cancelled by user.${NC}"
                    exit 0
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
                    sudo sed -i "/${LARAVEL_SUBDOMAIN}/d" /etc/hosts || true
                    sudo sed -i "/${HTML5_SUBDOMAIN}/d" /etc/hosts || true
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: Removed hosts entries for ${LARAVEL_SUBDOMAIN} and ${HTML5_SUBDOMAIN}" | sudo tee -a /var/log/powerps_install.log >/dev/null
                fi

                # Stop and remove Laravel Queue Service
                if systemctl list-unit-files | grep -q '^laravel-queue\.service'; then
                    echo -e "${GREEN}Stopping and removing Laravel Queue Service...${NC}"
                    sudo systemctl stop laravel-queue || true
                    sudo systemctl disable laravel-queue || true
                    sudo rm -f /etc/systemd/system/laravel-queue.service || true
                    sudo systemctl daemon-reload || true
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: laravel-queue service removed" | sudo tee -a /var/log/powerps_install.log >/dev/null
                fi

                # Remove queue logs (optional)
                if [ -f /var/log/laravel-queue.log ] || [ -f /var/log/laravel-queue.error.log ]; then
                    echo -e "${GREEN}Archiving and removing Laravel queue logs...${NC}"
                    sudo mv /var/log/laravel-queue.log /var/log/laravel-queue.log.bak_$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
                    sudo mv /var/log/laravel-queue.error.log /var/log/laravel-queue.error.log.bak_$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: Archived laravel queue logs" | sudo tee -a /var/log/powerps_install.log >/dev/null
                fi

                # Stop and remove Certbot timer/service (if present)
                if systemctl list-unit-files | grep -q '^certbot-renew\.timer'; then
                    echo -e "${GREEN}Stopping and removing certbot renewal timer/service...${NC}"
                    sudo systemctl stop certbot-renew.timer || true
                    sudo systemctl disable certbot-renew.timer || true
                    sudo rm -f /etc/systemd/system/certbot-renew.timer /etc/systemd/system/certbot-renew.service || true
                    sudo systemctl daemon-reload || true
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: certbot renewal units removed" | sudo tee -a /var/log/powerps_install.log >/dev/null
                fi

                # Optionally delete Let's Encrypt certs
                if command -v certbot >/dev/null 2>&1; then
                    read -r -p "Also delete Let's Encrypt certs for ${LARAVEL_SUBDOMAIN} and ${HTML5_SUBDOMAIN}? (y/N): " DELCERTS
                    if [[ "$DELCERTS" =~ ^[Yy]$ ]]; then
                        sudo certbot delete --cert-name "${LARAVEL_SUBDOMAIN}" || true
                        sudo certbot delete --cert-name "${HTML5_SUBDOMAIN}" || true
                        echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: Requested deletion of certs for ${LARAVEL_SUBDOMAIN} and ${HTML5_SUBDOMAIN}" | sudo tee -a /var/log/powerps_install.log >/dev/null
                    fi
                fi

                # Remove stored MySQL root password file if exists
                if [ -f /root/.mysql_root_pass ]; then
                    sudo rm -f /root/.mysql_root_pass || true
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: Removed /root/.mysql_root_pass" | sudo tee -a /var/log/powerps_install.log >/dev/null
                fi

                echo -e "${GREEN}Uninstallation completed successfully!${NC}"
                echo -e "${YELLOW}Note: Some system packages (Apache, MySQL, PHP) were left installed.${NC}"
                echo -e "${YELLOW}If you want to remove them, please use: sudo apt remove apache2 mysql-server php8.3${NC}"
                exit 0
                ;;
        esac
    done
else
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

    echo "LARAVEL_SUBDOMAIN=$LARAVEL_SUBDOMAIN" > "$SUBDOMAIN_FILE"
    echo "HTML5_SUBDOMAIN=$HTML5_SUBDOMAIN" >> "$SUBDOMAIN_FILE"
fi
# Update package lists and install necessary packages
echo -e "${GREEN}Updating package lists and installing necessary packages...${NC}"
sudo apt-get update
sudo apt-get install -y software-properties-common curl openssl
sudo add-apt-repository -y ppa:ondrej/php
sudo apt-get update

# Install PHP 8.3 and specific extensions
sudo apt-get install -y apache2 mysql-server \
    php8.3 php8.3-mysql libapache2-mod-php8.3 php8.3-cli php8.3-zip \
    php8.3-xml php8.3-dom php8.3-mbstring php8.3-curl php8.3-gd \
    php8.3-bcmath php8.3-intl php8.3-readline \
    php-imagick libmagickwand-dev composer unzip git expect \
    python3-certbot-apache certbot || {
    echo -e "${RED}خطا در نصب پکیج‌ها${NC}"
    exit 1
}

# Force PHP 8.3 as default
echo -e "${GREEN}Setting PHP 8.3 as default...${NC}"
sudo update-alternatives --set php /usr/bin/php8.3
sudo a2enmod php8.3
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
# Prompt for MySQL root password to use for mysql_secure_installation (or press Enter to auto-generate a strong one)
read -s -e -p "Enter desired MySQL root password (leave empty to generate one): " MYSQL_ROOT_PASSWORD
echo
if [ -z "${MYSQL_ROOT_PASSWORD}" ]; then
    MYSQL_ROOT_PASSWORD=$(openssl rand -base64 16)
    echo "Generated MySQL root password: (will be saved to /root/.mysql_root_pass - permissions restricted)"
    echo "${MYSQL_ROOT_PASSWORD}" | sudo tee /root/.mysql_root_pass >/dev/null
    sudo chmod 600 /root/.mysql_root_pass
fi
# Use expect to automate mysql_secure_installation with provided password
SECURE_MYSQL=$(expect -c "
set timeout 10
spawn sudo mysql_secure_installation
expect {
    \"Enter password for user root:\" {
        send \"\r\"
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
DB_PASS=$(openssl rand -base64 12)

echo -e "${GREEN}Creating MySQL database and user...${NC}"
sudo mysql -e "CREATE DATABASE ${DB_NAME};" || check_command "Failed to create database ${DB_NAME}"
sudo mysql -e "CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';" || check_command "Failed to create database user ${DB_USER}"
sudo mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';" || check_command "Failed to grant privileges on ${DB_NAME}"
sudo mysql -e "FLUSH PRIVILEGES;" || check_command "Failed to flush privileges"

# Check if the Laravel project directory exists
if [ -d "/var/www/html/laravel-app" ]; then
    # If it exists, update the repository
    echo -e "${GREEN}Updating the Laravel project repository...${NC}"
    cd /var/www/html/laravel-app
    git pull origin main
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

# Configure Bolt extension
echo -e "${GREEN}Configuring Bolt extension...${NC}"
if [ -f "/var/www/html/laravel-app/bolt.so" ]; then
    # Get PHP extension directory dynamically
    PHP_EXT_DIR=$(php -i | grep '^extension_dir' | awk '{print $3}')
    if [ -z "$PHP_EXT_DIR" ]; then
        PHP_EXT_DIR="/usr/lib/php/20230831"
    fi
    
    sudo mkdir -p "$PHP_EXT_DIR"
    sudo cp /var/www/html/laravel-app/bolt.so "$PHP_EXT_DIR/"
    
    # Add Bolt extension to PHP configurations if not already added
    for ini in /etc/php/8.3/apache2/php.ini /etc/php/8.3/cli/php.ini; do
        if [ -f "$ini" ]; then
            if ! grep -q "extension=bolt.so" "$ini"; then
                echo "extension=bolt.so" | sudo tee -a "$ini"
            fi
        fi
    done
    
    echo -e "${GREEN}Bolt extension configured successfully in $PHP_EXT_DIR${NC}"
    
    # Verify extension is loaded
    if php8.3 -m | grep -q "bolt"; then
        echo -e "${GREEN}Bolt extension verified and loaded.${NC}"
    else
        echo -e "${RED}Error: Bolt extension is not loading. Please check PHP logs.${NC}"
        # Don't exit yet, maybe it needs a restart or manual check
    fi
else
    echo -e "${YELLOW}Warning: bolt.so not found in laravel-app directory${NC}"
fi


# تنظیم مجوزها در هر دو حالت نصب اولیه و نصب مجدد
echo -e "${GREEN}Setting permissions for Laravel directories...${NC}"
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
echo -e "${GREEN}Installing Composer dependencies...${NC}"
# Use php8.3 explicitly for composer to avoid version conflicts
run_with_retry "php8.3 /usr/bin/composer install --no-interaction --no-progress --prefer-dist" 3 5 || {
    echo -e "${RED}Composer install failed. Trying with --ignore-platform-reqs...${NC}"
    run_with_retry "php8.3 /usr/bin/composer install --no-interaction --no-progress --prefer-dist --ignore-platform-reqs" 3 5 || {
        echo -e "${RED}Composer install failed even with --ignore-platform-reqs${NC}"
        exit 1
    }
}


# Set up environment variables if not already set
echo -e "${GREEN}Setting up environment variables...${NC}"
if [ ! -f "/var/www/html/laravel-app/.env" ]; then
    cp /var/www/html/laravel-app/.env.example /var/www/html/laravel-app/.env
    sed -i '/APP_NAME/d' /var/www/html/laravel-app/.env
    echo "APP_NAME=Laravel" >> /var/www/html/laravel-app/.env

    # check if APP_ENV is already set remove it and add it again
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

fi
# Secure .env file: restrict permissions and owner
sudo chown www-data:www-data /var/www/html/laravel-app/.env || true
sudo chmod 600 /var/www/html/laravel-app/.env || true
# Generate app key
echo -e "${GREEN}Generating app key...${NC}"
php8.3 artisan key:generate

# Run migrations
echo -e "${GREEN}Running migrations...${NC}"
php8.3 artisan migrate --force || {
    echo -e "${RED}Migration failed. Checking database connection...${NC}"
    exit 1
}

# Run Link Storage
echo -e "${GREEN}Linking storage...${NC}"
php8.3 artisan storage:link --force || true
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
echo -e "${GREEN}Obtaining TLS certificates for ${LARAVEL_SUBDOMAIN} and ${HTML5_SUBDOMAIN}...${NC}"
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

# Add domain entries to /etc/hosts
echo "127.0.0.1 ${LARAVEL_SUBDOMAIN}" | sudo tee -a /etc/hosts
echo "127.0.0.1 ${HTML5_SUBDOMAIN}" | sudo tee -a /etc/hosts

# Add schedule to cron job
echo -e "${GREEN}Adding schedule to cron job...${NC}"
(crontab -l ; echo "* * * * * cd /var/www/html/laravel-app && /usr/bin/php8.3 artisan schedule:run >> /dev/null 2>&1") | crontab -

# Ensure services start on reboot
echo -e "${GREEN}Ensuring services start on reboot...${NC}"
(crontab -l ; echo "@reboot systemctl restart apache2") | crontab -
(crontab -l ; echo "@reboot systemctl restart mysql") | crontab -

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
    masked_token="${TELEGRAM_BOT_TOKEN:0:4}...${TELEGRAM_BOT_TOKEN: -4}"
    echo -e "${YELLOW}Warning: Failed to set Telegram webhook. You can set it manually.${NC}"
    echo -e "${YELLOW}Masked bot token: ${masked_token}${NC}"
    echo -e "${YELLOW}Run: curl -F \"url=${WEBHOOK_URL}\" https://api.telegram.org/bot<your-bot-token>/setWebhook${NC}"
fi

echo -e "${GREEN}PowerPs installation complete!${NC}"

# Create and configure Laravel Queue Service (systemd supervised)
echo -e "${GREEN}Setting up Laravel Queue Service...${NC}"
sudo bash -c "cat > /etc/systemd/system/laravel-queue.service << 'EOL'
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
ExecStart=/usr/bin/php8.3 /var/www/html/laravel-app/artisan queue:work --sleep=3 --tries=3 --timeout=0
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
