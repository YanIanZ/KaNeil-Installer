#!/bin/bash
# KaNeil Full Fix - Run on EC2 as root
set -e

echo "=== 1. Stop services ==="
systemctl stop ship 2>/dev/null || true

echo "=== 2. Remove old wings binary ==="
rm -f /usr/local/bin/wings

echo "=== 3. Download new ship binary ==="
curl -sSL -o /usr/local/bin/ship https://github.com/YanIanZ/KaNeil-Ship/releases/latest/download/ship_linux_amd64
chmod +x /usr/local/bin/ship
echo "Ship version: $(/usr/local/bin/ship --version 2>/dev/null || echo 'v1.0.0')"

echo "=== 4. Update panel ==="
cd /var/www/kaneil
cp .env /tmp/kaneil.env.bak
PANEL_DL_URL="${PANEL_DL_URL:-https://github.com/YanIanZ/KaNeil-Panel/releases/download/experimental-latest/panel.tar.gz}"
curl -fsSL -o /tmp/panel.tar.gz "$PANEL_DL_URL"
tar -xzf /tmp/panel.tar.gz --overwrite
cp /tmp/kaneil.env.bak .env
rm -f /tmp/panel.tar.gz /tmp/kaneil.env.bak

# Detect web user (www-data on Ubuntu/Debian, nginx elsewhere)
WEB_USER="www-data"
id -u www-data >/dev/null 2>&1 || WEB_USER="nginx"

echo "=== 5. Composer install ==="
composer install --no-dev --optimize-autoloader --no-interaction 2>&1 | tail -3

echo "=== 6. Run migrations ==="
php artisan migrate --force 2>&1 | tail -3

echo "=== 7. Import game wings ==="
php artisan p:map:import-bulk storage/eggs/game-wings 2>&1 | tail -5

echo "=== 8. Import application wings ==="  
php artisan p:map:import-bulk storage/eggs/application-wings 2>&1 | tail -5

echo "=== 9. Clear all caches ==="
php artisan optimize:clear 2>&1 | tail -3

echo "=== 10. Set permissions ==="
chmod -R 775 storage bootstrap/cache
chown -R "$WEB_USER":"$WEB_USER" storage bootstrap/cache 2>/dev/null || true

echo "=== 11. Ensure GUZZLE_TIMEOUT in .env ==="
if ! grep -q "^GUZZLE_TIMEOUT=" /var/www/kaneil/.env; then
  echo "GUZZLE_TIMEOUT=30" >> /var/www/kaneil/.env
fi
if ! grep -q "^GUZZLE_CONNECT_TIMEOUT=" /var/www/kaneil/.env; then
  echo "GUZZLE_CONNECT_TIMEOUT=10" >> /var/www/kaneil/.env
fi
php artisan config:clear 2>/dev/null || true

echo "=== 12. Ensure cronjob ==="
if ! crontab -l 2>/dev/null | grep -q "kaneil/artisan schedule:run"; then
  (crontab -l 2>/dev/null; echo "* * * * * php /var/www/kaneil/artisan schedule:run >> /dev/null 2>&1") | crontab -
  echo "Cronjob added."
else
  echo "Cronjob already present."
fi

echo "=== 13. Ensure kaneil queue worker ==="
GITHUB_URL="${GITHUB_URL:-https://raw.githubusercontent.com/YanIanZ/KaNeil-Installer/main}"
if [ ! -f /etc/systemd/system/kaneil.service ]; then
  echo "Fetching kaneil.service..."
  curl -fSL -o /etc/systemd/system/kaneil.service "$GITHUB_URL"/configs/kaneil.service
  if grep -qi "ubuntu\|debian" /etc/os-release; then
    sed -i -e "s@<user>@www-data@g" /etc/systemd/system/kaneil.service
  else
    sed -i -e "s@<user>@nginx@g" /etc/systemd/system/kaneil.service
  fi
  systemctl daemon-reload
  systemctl enable kaneil.service
fi
systemctl restart kaneil 2>/dev/null || systemctl start kaneil 2>/dev/null || true
sleep 2
if systemctl is-active --quiet kaneil; then
  echo "kaneil queue worker active."
else
  echo "WARNING: kaneil queue worker NOT active - run: journalctl -u kaneil -n 50"
fi

echo "=== 14. Restart services ==="
for v in php8.5-fpm php8.4-fpm php8.3-fpm php8.2-fpm php-fpm; do
  if systemctl is-active --quiet "$v" 2>/dev/null; then
    systemctl restart "$v" && echo "  Restarted $v"
    break
  fi
done
systemctl restart nginx 2>/dev/null || true
systemctl restart ship 2>/dev/null || true

echo ""
APP_URL=$(grep -E '^APP_URL=' /var/www/kaneil/.env 2>/dev/null | cut -d= -f2-)
echo "DONE. Panel: ${APP_URL:-(set APP_URL in .env)}"
echo "Maps:  ${APP_URL:-...}/admin/maps"
echo "Queue: systemctl status kaneil"
echo "Cron:  crontab -l"
