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
curl -sSL -o /tmp/panel.tar.gz https://github.com/YanIanZ/KaNeil-Panel/releases/latest/download/panel.tar.gz
tar -xzf /tmp/panel.tar.gz --overwrite
cp /tmp/kaneil.env.bak .env
rm -f /tmp/panel.tar.gz /tmp/kaneil.env.bak

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
chmod -R 755 storage bootstrap/cache
chown -R nginx:nginx storage bootstrap/cache 2>/dev/null || true

echo "=== 11. Restart services ==="
systemctl restart php8.5-fpm nginx ship

echo ""
echo "DONE. Panel: https://panel.shandy.live"
echo "Check maps: https://panel.shandy.live/admin/maps"
echo "Check ship: ship diagnostics"
