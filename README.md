# PowerPs Core Install Scripts

اسکریپت نصب و به‌روزرسانی خودکار [powerps-core](https://github.com/rezahajrahimi/powerps-core) و [powerps-webapp](https://github.com/rezahajrahimi/powerps-webapp).

## نصب سریع (Ubuntu 24.04)

```sh
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/rezahajrahimi/powerps-core-scripts/refs/heads/main/install.sh)" @ install
```

## این اسکریپت چه کار می‌کند؟

1. PHP **8.4** و پکیج‌های لازم را نصب می‌کند
2. ریپوی [powerps-core](https://github.com/rezahajrahimi/powerps-core) را clone یا update می‌کند
3. **phpBolt** را از فایل‌های داخل همان ریپو فعال می‌کند
4. Composer، migrate، cron، queue worker و SSL را راه‌اندازی می‌کند
5. [powerps-webapp](https://github.com/rezahajrahimi/powerps-webapp) را نصب می‌کند
6. اگر **Bot Token** یا **Admin ID** در `.env` خالی باشد، از شما می‌پرسد (نصب اولیه و به‌روزرسانی)

## bolt.so از کجا می‌آید؟

روی سرور **دانلود جداگانه ندارد**. فایل‌های زیر داخل ریپوی `powerps-core` commit شده‌اند و با `git clone` / `git pull` روی سرور می‌آیند:

- `bolt.so` (پیش‌فرض x86_64)
- `bolt-x86_64.so`
- `bolt-aarch64.so`

اسکریپت نصب فایل مناسب معماری CPU را انتخاب و در مسیر اکستنشن PHP کپی می‌کند. نسخه PHP و phpBolt از فایل‌های `.powerps-php-version` و `.powerps-bolt-version` خوانده می‌شود.

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

همان دستور نصب را دوباره اجرا کنید و گزینه **Install / Update** را بزنید. اسکریپت `git pull` می‌زند و PHP/phpBolt را با نسخه جدید ریپو هماهنگ می‌کند.

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

## خطای `bolt_decrypt()` در migrate

اگر `php artisan migrate` خطای `Call to undefined function bolt_decrypt()` داد، یعنی **phpBolt برای PHP CLI لود نشده** یا دستور `php` به نسخه اشتباه اشاره می‌کند.

اگر `install.sh` بعد از `Module php8.4 already enabled` متوقف شد، احتمالاً **phpBolt از نصب ناقص قبلی** باعث hang یا crash در PHP CLI شده. اول `fix-phpbolt.sh` را اجرا کنید، بعد دوباره install:

```sh
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/rezahajrahimi/powerps-core-scripts/refs/heads/main/fix-phpbolt.sh)"
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/rezahajrahimi/powerps-core-scripts/refs/heads/main/install.sh)" @ install
```

لاگ نصب: `/var/log/powerps_install.log`

```sh
# تشخیص
php -v
php8.4 -m | grep -i bolt

# تعمیر سریع
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/rezahajrahimi/powerps-core-scripts/refs/heads/main/fix-phpbolt.sh)"

# migrate
cd /var/www/html/laravel-app
php artisan migrate --force
```

اگر `php -m | grep bolt` خالی بود ولی `php8.4 -m | grep bolt` کار کرد، از `php8.4 artisan migrate --force` استفاده کنید.

## خطای `phpBolt failed to load in php8.4`

معمولاً از **پیکربندی قدیمی bolt** (دو بار لود شدن با `phpenmod` + `99-bolt.ini`) یا ini با مسیر مطلق اشتباه است.

روی سرور:

```sh
# پاک‌سازی و نصب مجدد bolt
sudo rm -f /etc/php/8.4/cli/conf.d/*bolt* /etc/php/8.4/apache2/conf.d/*bolt*
sudo rm -f /etc/php/8.4/mods-available/bolt.ini
sudo phpdismod -v 8.4 bolt 2>/dev/null || true
sudo rm -f /usr/lib/php/20240924/bolt.so
sudo rm -f "/usr/lib/php/20240924 /bolt.so" 2>/dev/null || true
sudo rmdir "/usr/lib/php/20240924 " 2>/dev/null || true

sudo bash -c "$(curl -sL https://raw.githubusercontent.com/rezahajrahimi/powerps-core-scripts/refs/heads/main/fix-phpbolt.sh)"

# تست
php8.4 -r 'var_dump(function_exists("bolt_decrypt"));'   # باید bool(true) باشد
```

اگر باز هم خطا داد، خروجی این دستورات را بفرستید:

```sh
file /var/www/html/laravel-app/bolt-x86_64.so
php8.4 --ini
cat /etc/php/8.4/cli/conf.d/99-bolt.ini
php8.4 -r 'var_dump(function_exists("bolt_decrypt"));' 2>&1
```

## English

Automated installer for PowerPs Core (Laravel backend) and PowerPs WebApp.

```sh
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/rezahajrahimi/powerps-core-scripts/refs/heads/main/install.sh)" @ install
```

**phpBolt:** bundled inside `powerps-core` repo, copied to PHP extension dir by this script — not downloaded separately.
