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

output "Backing up .env file..."
cp /var/www/kaneil/.env /tmp/kaneil.env.backup

output "Downloading latest panel release..."
PANEL_DIR=/var/www/kaneil
BACKUP_DIR=/var/www/kaneil_backup_$(date +%Y%m%d_%H%M%S)

# Back up current installation
cp -r $PANEL_DIR $BACKUP_DIR 2>/dev/null || true
output "Backup saved to $BACKUP_DIR"

output "Downloading $PANEL_DL_URL..."
cd $PANEL_DIR
rm -f panel.tar.gz
curl -Lo panel.tar.gz "$PANEL_DL_URL"

output "Extracting panel..."
tar -xzf panel.tar.gz
rm -f panel.tar.gz

output "Restoring .env file..."
cp /tmp/kaneil.env.backup $PANEL_DIR/.env
rm -f /tmp/kaneil.env.backup

# Run migrations
output "Updating composer dependencies..."
composer install --no-dev --optimize-autoloader --no-interaction 2>&1 | tail -5

output "Running database migrations..."
php artisan migrate --force 2>&1 | tail -5

output "Clearing caches..."
php artisan optimize:clear 2>&1 | tail -2

# Set permissions
output "Setting permissions..."
chmod -R 755 storage bootstrap/cache

# Update crontab
if ! crontab -l | grep -q "schedule:run"; then
  output "Re-installing cronjob..."
  crontab -l | { cat; echo "* * * * * php $PANEL_DIR/artisan schedule:run >> /dev/null 2>&1"; } | crontab -
fi

# Restart queue worker
if systemctl is-active --quiet kaneil 2>/dev/null; then
  output "Restarting KaNeil queue worker..."
  systemctl restart kaneil
fi

output ""
success "KaNeil Panel updated successfully!"
output "Panel backup saved at: $BACKUP_DIR"
output ""
