#!/bin/bash

set -e

source /tmp/lib.sh

output ""
output "Starting KaNeil Panel Update..."

# Check if panel is installed
if [ ! -f "/var/www/kaneil/artisan" ]; then
  error "KaNeil Panel is not installed at /var/www/kaneil"
  exit 1
fi

PANEL_DIR=/var/www/kaneil

output "Putting panel in maintenance mode..."
cd $PANEL_DIR
php artisan down 2>/dev/null || true

output "Clearing old caches..."
php artisan config:clear 2>/dev/null || true
php artisan route:clear 2>/dev/null || true
php artisan view:clear 2>/dev/null || true
php artisan cache:clear 2>/dev/null || true

output "Backing up .env file..."
cp $PANEL_DIR/.env /tmp/kaneil.env.backup

BACKUP_DIR=/var/www/kaneil_backup_$(date +%Y%m%d_%H%M%S)
cp -r $PANEL_DIR $BACKUP_DIR 2>/dev/null || true
output "Backup saved to $BACKUP_DIR"

output "Downloading latest panel release..."
cd $PANEL_DIR
rm -f panel.tar.gz
curl -sSL -o panel.tar.gz "$PANEL_DL_URL"

output "Removing old files (keeping .env)..."
# Delete everything except .env, storage/logs, and the fresh tar
find . -mindepth 1 -maxdepth 1 ! -name '.env' ! -name 'panel.tar.gz' ! -name 'storage' -exec rm -rf {} +
# Clean storage but keep logs
rm -rf storage/framework/views/* storage/framework/cache/* storage/framework/sessions/* 2>/dev/null || true
rm -rf bootstrap/cache/* 2>/dev/null || true
rm -rf vendor 2>/dev/null || true

output "Extracting fresh panel..."
tar -xzf panel.tar.gz
rm -f panel.tar.gz

output "Restoring .env file..."
cp /tmp/kaneil.env.backup $PANEL_DIR/.env
rm -f /tmp/kaneil.env.backup

# Create storage dirs if missing after extract
mkdir -p $PANEL_DIR/storage/framework/views $PANEL_DIR/storage/framework/cache $PANEL_DIR/storage/framework/sessions $PANEL_DIR/storage/logs $PANEL_DIR/storage/app

output "Updating composer dependencies..."
COMPOSER_OUTPUT=$(composer install --no-dev --optimize-autoloader --no-interaction 2>&1)
COMPOSER_EXIT=$?
if [ $COMPOSER_EXIT -ne 0 ]; then
  error "Composer update failed (exit $COMPOSER_EXIT):"
  echo "$COMPOSER_OUTPUT" | tail -20
  error "Rolling back..."
  rm -rf $PANEL_DIR/*
  cp -r $BACKUP_DIR/* $PANEL_DIR/
  php artisan up 2>/dev/null || true
  exit 1
fi

output "Running database migrations..."
MIGRATE_OUTPUT=$(php artisan migrate --force 2>&1)
MIGRATE_EXIT=$?
if [ $MIGRATE_EXIT -ne 0 ]; then
  error "Migrations failed (exit $MIGRATE_EXIT):"
  echo "$MIGRATE_OUTPUT" | tail -10
fi

output "Publishing filament assets..."
php artisan filament:assets 2>/dev/null || true
php artisan filament:upgrade 2>/dev/null || true

output "Rebuilding optimized autoload..."
timeout 60 composer dump-autoload -o 2>/dev/null || output "Autoload rebuild skipped (timeout or failed — non-critical)"

output "Clearing all caches..."
php artisan config:clear 2>/dev/null || true
php artisan route:clear 2>/dev/null || true
php artisan view:clear 2>/dev/null || true
php artisan cache:clear 2>/dev/null || true
php artisan event:clear 2>/dev/null || true
php artisan optimize:clear 2>/dev/null || true

output "Setting permissions..."
chmod -R 755 storage bootstrap/cache 2>/dev/null || true
chown -R nginx:nginx storage bootstrap/cache 2>/dev/null || true
chown -R nginx:nginx storage/logs 2>/dev/null || true

# Restart PHP-FPM to clear OPcache
output "Restarting PHP-FPM to clear OPcache..."
if systemctl is-active --quiet php8.5-fpm 2>/dev/null; then
  systemctl restart php8.5-fpm 2>/dev/null || true
elif systemctl is-active --quiet php8.4-fpm 2>/dev/null; then
  systemctl restart php8.4-fpm 2>/dev/null || true
elif systemctl is-active --quiet php-fpm 2>/dev/null; then
  systemctl restart php-fpm 2>/dev/null || true
fi

# Update crontab
if ! crontab -l 2>/dev/null | grep -q "schedule:run"; then
  output "Installing cronjob..."
  crontab -l 2>/dev/null | { cat; echo "* * * * * php $PANEL_DIR/artisan schedule:run >> /dev/null 2>&1"; } | crontab -
fi

# Restart services
if systemctl is-active --quiet kaneil 2>/dev/null; then
  output "Restarting KaNeil queue worker..."
  systemctl restart kaneil 2>/dev/null || true
fi

if systemctl is-active --quiet nginx 2>/dev/null; then
  output "Reloading nginx..."
  systemctl reload nginx 2>/dev/null || true
fi

output "Bringing panel out of maintenance mode..."
php artisan up 2>/dev/null || true

output ""
success "KaNeil Panel updated successfully!"
output "Backup saved at: $BACKUP_DIR"

output ""
output "Running health check..."
if php artisan about 2>&1 | grep -q 'KaNeil'; then
  success "Panel health check passed!"
else
  error "Panel health check failed. Checking logs..."
  echo "--- Last 20 lines of laravel.log ---"
  tail -20 $PANEL_DIR/storage/logs/laravel.log 2>/dev/null || echo "No log file found."
  echo "--- PHP errors ---"
  php -r "require '$PANEL_DIR/vendor/autoload.php';" 2>&1 | head -3
fi
output ""
