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
if ! composer install --no-dev --optimize-autoloader --no-interaction 2>&1; then
  error "Composer update failed. Rolling back..."
  rm -rf $PANEL_DIR/*
  cp -r $BACKUP_DIR/* $PANEL_DIR/
  php artisan up 2>/dev/null || true
  exit 1
fi

output "Running database migrations..."
if ! php artisan migrate --force 2>&1; then
  error "Migrations failed. Check logs."
fi

output "Clearing all caches..."
php artisan config:clear 2>/dev/null || true
php artisan route:clear 2>/dev/null || true
php artisan view:clear 2>/dev/null || true
php artisan cache:clear 2>/dev/null || true
php artisan optimize:clear 2>/dev/null || true

output "Setting permissions..."
chmod -R 755 storage bootstrap/cache 2>/dev/null || true
chown -R nginx:nginx storage bootstrap/cache 2>/dev/null || true

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
output "If errors persist, check logs: tail -100 /var/www/kaneil/storage/logs/laravel.log"
output ""
