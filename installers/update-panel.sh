#!/bin/bash

set -e

source /tmp/lib.sh

run_with_retry() {
    local cmd="$1"
    local max_attempts=3
    local timeout_seconds=60
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        output "Attempt $attempt of $max_attempts: $cmd"
        if timeout $timeout_seconds bash -c "$cmd"; then
            return 0
        fi
        attempt=$((attempt + 1))
        if [ $attempt -le $max_attempts ]; then
            sleep $((2 ** (attempt - 1)))
        fi
    done
    return 1
}

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
output "Creating backup at $BACKUP_DIR..."
cp -r $PANEL_DIR $BACKUP_DIR 2>/dev/null || true

if [ -z "$PANEL_DL_URL" ]; then
  PANEL_DL_URL="https://github.com/YanIanZ/KaNeil-Panel/releases/download/experimental-latest/panel.tar.gz"
fi

output "Downloading panel from $PANEL_DL_URL ..."
cd /tmp
rm -f panel.tar.gz
curl -sSL -o panel.tar.gz "$PANEL_DL_URL"

if [ ! -f panel.tar.gz ] || [ $(stat -c%s panel.tar.gz 2>/dev/null || stat -f%z panel.tar.gz 2>/dev/null || echo 0) -lt 100000 ]; then
  error "Failed to download panel.tar.gz or file too small ($PANEL_DL_URL)"
  exit 1
fi
output "Downloaded panel.tar.gz successfully"

# Verify tar archive is not corrupted
if ! tar -tzf panel.tar.gz > /dev/null 2>&1; then
  error "Downloaded panel.tar.gz is corrupted (tar -tzf failed)"
  rm -f panel.tar.gz
  exit 1
fi
output "Tar archive integrity verified"

output "Removing old files (keeping .env)..."
cd $PANEL_DIR
find . -mindepth 1 -maxdepth 1 ! -name '.env' ! -name 'storage' -exec rm -rf {} + 2>/dev/null || true
rm -rf storage/framework/views/* storage/framework/cache/* storage/framework/sessions/* 2>/dev/null || true
rm -rf bootstrap/cache/* 2>/dev/null || true
rm -rf vendor 2>/dev/null || true

output "Extracting fresh panel..."
tar -xzf /tmp/panel.tar.gz
rm -f /tmp/panel.tar.gz

output "Restoring .env file..."
cp /tmp/kaneil.env.backup $PANEL_DIR/.env
rm -f /tmp/kaneil.env.backup

# Create storage dirs if missing after extract
mkdir -p $PANEL_DIR/storage/framework/views $PANEL_DIR/storage/framework/cache $PANEL_DIR/storage/framework/sessions $PANEL_DIR/storage/logs $PANEL_DIR/storage/app

output "Updating composer dependencies (with retry)..."
if ! run_with_retry "cd $PANEL_DIR && composer install --no-dev --optimize-autoloader --no-interaction"; then
  COMPOSER_OUTPUT=$(cd $PANEL_DIR && composer install --no-dev --optimize-autoloader --no-interaction 2>&1)
  error "Composer update failed after 3 retries:"
  echo "$COMPOSER_OUTPUT" | tail -20
  error "Rolling back..."
  rm -rf $PANEL_DIR/*
  cp -r $BACKUP_DIR/* $PANEL_DIR/
  php artisan up 2>/dev/null || true
  exit 1
fi

# Branch tarballs don't ship built JS assets - run yarn build.
if [ -f $PANEL_DIR/package.json ] && [ ! -d $PANEL_DIR/public/build ]; then
  output "Building frontend assets..."
  if ! command -v node >/dev/null 2>&1; then
    output "Installing Node.js 22.x..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1 || true
    apt-get install -y nodejs >/dev/null 2>&1 || true
  fi
  if ! command -v yarn >/dev/null 2>&1; then
    npm install -g yarn >/dev/null 2>&1 || true
  fi
  if command -v yarn >/dev/null 2>&1; then
    (cd $PANEL_DIR && yarn install --frozen-lockfile >/dev/null 2>&1 && yarn build 2>&1 | tail -10) || output "WARNING: yarn build failed - panel may render without assets"
  else
    output "WARNING: yarn not available - frontend assets not built"
  fi
fi

output "Running database migrations (with retry)..."
if ! run_with_retry "cd $PANEL_DIR && timeout 120 php artisan migrate --force"; then
  MIGRATE_OUTPUT=$(cd $PANEL_DIR && timeout 120 php artisan migrate --force 2>&1)
  error "Migrations failed after 3 retries:"
  echo "$MIGRATE_OUTPUT" | tail -10
fi

output "Publishing filament assets..."
php artisan filament:assets 2>/dev/null || true
php artisan filament:upgrade 2>/dev/null || true

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

# Run repair pass (docker_images, startup_commands, variables, server image refs)
if php artisan list 2>/dev/null | grep -q "p:repair"; then
  output "Running data repair (p:repair)..."
  php artisan p:repair 2>&1 | tail -30 || true
fi

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
  (crontab -l 2>/dev/null; echo "* * * * * php $PANEL_DIR/artisan schedule:run >> /dev/null 2>&1") | crontab -
fi

# Repair queue worker unit if missing
if [ ! -f /etc/systemd/system/kaneil.service ]; then
  output "kaneil.service missing - reinstalling queue worker unit..."
  GITHUB_URL="${GITHUB_URL:-https://raw.githubusercontent.com/YanIanZ/KaNeil-Installer/main}"
  if curl -fSL -o /etc/systemd/system/kaneil.service "$GITHUB_URL"/configs/kaneil.service && [ -s /etc/systemd/system/kaneil.service ]; then
    if [ -f /etc/os-release ] && grep -qi "ubuntu\|debian" /etc/os-release; then
      sed -i -e "s@<user>@www-data@g" /etc/systemd/system/kaneil.service
    else
      sed -i -e "s@<user>@nginx@g" /etc/systemd/system/kaneil.service
    fi
    systemctl daemon-reload
    systemctl enable kaneil.service 2>/dev/null || true
  fi
fi

# Restart (or start) queue worker
if [ -f /etc/systemd/system/kaneil.service ]; then
  output "Restarting KaNeil queue worker..."
  systemctl restart kaneil 2>/dev/null || systemctl start kaneil 2>/dev/null || true
  sleep 2
  if ! systemctl is-active --quiet kaneil; then
    output "WARNING: kaneil queue worker not active - check: journalctl -u kaneil -n 50"
  fi
fi

# Restart ship to refetch repaired vessel configs
if systemctl is-active --quiet ship 2>/dev/null; then
  output "Restarting ship to refetch vessel configs..."
  systemctl restart ship 2>/dev/null || true
fi

# Ensure GUZZLE_TIMEOUT >= 30 in .env (panel->ship callback can exceed 15s)
if [ -f "$PANEL_DIR/.env" ]; then
  if ! grep -q "^GUZZLE_TIMEOUT=" "$PANEL_DIR/.env"; then
    echo "GUZZLE_TIMEOUT=30" >> "$PANEL_DIR/.env"
  fi
  if ! grep -q "^GUZZLE_CONNECT_TIMEOUT=" "$PANEL_DIR/.env"; then
    echo "GUZZLE_CONNECT_TIMEOUT=10" >> "$PANEL_DIR/.env"
  fi
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
if timeout 30 php artisan about 2>&1 | grep -q 'KaNeil'; then
  success "Panel health check passed!"
else
  error "Panel health check failed. Checking logs..."
  echo "--- Last 20 lines of laravel.log ---"
  tail -20 $PANEL_DIR/storage/logs/laravel.log 2>/dev/null || echo "No log file found."
  echo "--- PHP errors ---"
  php -r "require '$PANEL_DIR/vendor/autoload.php';" 2>&1 | head -3
fi
output ""
