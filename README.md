# PowerPs Core Install Scripts

اسکریپت نصب و به‌روزرسانی خودکار [powerps-core](https://github.com/rezahajrahimi/telegram-vpn-seller-bot-v2) (هستهٔ Laravel) و [powerps-webapp](https://github.com/rezahajrahimi/power_ps_front_3) (وب‌اپ Flutter).

> **نسخهٔ Open Source:** سورس هسته دیگر رمزگذاری (phpBolt) نمی‌شود. نصب و به‌روزرسانی مثل یک پروژهٔ Laravel عادی انجام می‌شود.

## نصب سریع (Ubuntu 24.04)

```sh
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/rezahajrahimi/powerps-core-scripts/refs/heads/main/install.sh)" @ install
```

## این اسکریپت چه کار می‌کند؟

1. PHP **8.4** و پکیج‌های لازم را نصب می‌کند
2. Composer **رسمی ۲.۸+** را در `/usr/local/bin/composer` می‌گذارد (بستهٔ `composer` اوبونتو با PHP 8.4 ناسازگار است)
3. ریپوی هسته را clone یا update می‌کند
4. در صورت وجود، **پیکربندی قدیمی phpBolt** را از نصب‌های قبلی پاک می‌کند
5. `composer install --no-dev`، migrate، cron، queue worker و SSL را راه‌اندازی می‌کند
6. [powerps-webapp](https://github.com/rezahajrahimi/power_ps_front_3) را نصب می‌کند
7. اگر **Bot Token** یا **Admin ID** در `.env` خالی باشد، از شما می‌پرسد (نصب اولیه و به‌روزرسانی)

## گزینه‌های منو

| گزینه | کار |
|-------|-----|
| 1 | نصب / به‌روزرسانی |
| 2 | حذف کامل |
| 3 | تنظیم SSL (Certbot) |

## مسیرهای مهم بعد از نصب

| مسیر | توضیح |
|------|-------|
| `/var/www/html/laravel-app` | بک‌اند PowerPs Core |
| `/var/www/html/powerps-webapp` | وب‌اپ فرانت |
| `/var/www/html/laravel-app/.env` | تنظیمات محیطی |

## به‌روزرسانی

همان دستور نصب را دوباره اجرا کنید و گزینه **Install / Update** را بزنید. اسکریپت `git pull` می‌زند، وابستگی‌ها را نصب می‌کند و migrate/cache را اجرا می‌کند.

اگر install روی `add-apt-repository` یا `api.launchpad.net` خطا داد، یعنی DNS سرور موقتاً مشکل دارد. PPA از قبل اضافه شده باشد، نسخه جدید install آن مرحله را رد می‌کند.

## تنظیم دستی Bot Token و Admin ID

اگر نصب بدون پرسیدن توکن تمام شد، مقادیر را در `.env` بگذارید و دوباره install را اجرا کنید (یا webhook را دستی ست کنید):

```sh
nano /var/www/html/laravel-app/.env
# TELEGRAM_BOT_TOKEN=bot123456789:ABC...
# TELEGRAM_ADMIN_ID=123456789

cd /var/www/html/laravel-app
php artisan config:clear
curl "https://api.telegram.org/bot<TOKEN>/setWebhook?url=https://<core-subdomain>/api/telegram/webhooks/inbound"
```

اگر خطای `The environment file is invalid` دیدید (مثلاً `"${PUSHER_APP_CLUSTER}"APP_NAME=...`)، `.env` خراب شده — خط ادغام‌شده را اصلاح کنید یا این دستور را بزنید و دوباره install:

```sh
sed -i -E 's/(")([A-Z][A-Z0-9_]*)=/\1\n\2=/g' /var/www/html/laravel-app/.env
grep -n '^APP_NAME=' /var/www/html/laravel-app/.env
```

توکن را می‌توانید همان‌طور که @BotFather می‌دهد (بدون پیشوند `bot`) وارد کنید؛ اسکریپت نصب پیشوند را خودش اضافه می‌کند.

## مهاجرت از نسخهٔ قدیمی (phpBolt)

اگر قبلاً نسخهٔ رمزگذاری‌شده نصب کرده بودید و هنوز خطای `bolt_decrypt()` یا مشکل PHP CLI می‌بینید، پیکربندی قدیمی bolt را پاک کنید و دوباره install بزنید:

```sh
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/rezahajrahimi/powerps-core-scripts/refs/heads/main/fix-phpbolt.sh)"
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/rezahajrahimi/powerps-core-scripts/refs/heads/main/install.sh)" @ install
```

`fix-phpbolt.sh` دیگر bolt نصب نمی‌کند؛ فقط ini و `bolt.so` باقی‌مانده از نصب‌های قدیمی را حذف می‌کند.

```sh
cd /var/www/html/laravel-app
php artisan migrate --force
php artisan config:cache
php artisan route:cache
```

لاگ نصب: `/var/log/powerps_install.log`

## خطای `E_STRICT` / `Composer\Pcre\Preg` هنگام Composer

این از **Composer بسته‌بندی‌شده اوبونتو** است (`/usr/bin/composer` → `/usr/share/php/Composer`) که با PHP 8.4 سازگار نیست. نسخهٔ جدید install به‌جای آن Composer رسمی را در `/usr/local/bin/composer` می‌گذارد.

اگر هنوز همان Deprecation Notice را می‌بینید، اسکریپت را از GitHub بگیرید و دوباره Install / Update بزنید. روی سرور می‌توانید دستی هم نصب کنید:

```sh
sudo php8.4 -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
sudo php8.4 composer-setup.php --install-dir=/usr/local/bin --filename=composer
sudo rm composer-setup.php
php8.4 /usr/local/bin/composer --version
```

## English

Automated installer for PowerPs Core (Laravel backend) and PowerPs WebApp.

```sh
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/rezahajrahimi/powerps-core-scripts/refs/heads/main/install.sh)" @ install
```

**Open Source:** the core is plain Laravel source — no phpBolt extension required. Legacy bolt config from older installs is removed automatically during install/update.
