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
if ! cp -a "$PANEL_DIR" "$BACKUP_DIR"; then
  error "Failed to create backup at $BACKUP_DIR. Aborting update so the live install is not at risk."
  exit 1
fi
if [ ! -f "$BACKUP_DIR/artisan" ]; then
  error "Backup at $BACKUP_DIR looks incomplete (no artisan). Aborting."
  rm -rf "$BACKUP_DIR"
  exit 1
fi

if [ -z "$PANEL_DL_URL" ]; then
  PANEL_DL_URL="https://github.com/YanIanZ/KaNeil-Panel/releases/download/experimental-latest/panel.tar.gz"
fi

output "Downloading panel from $PANEL_DL_URL ..."
cd /tmp
rm -f panel.tar.gz
curl -sSL -o panel.tar.gz "$PANEL_DL_URL"

FILE_SIZE=$(stat -c%s panel.tar.gz 2>/dev/null || stat -f%z panel.tar.gz 2>/dev/null || echo 0)
if [ ! -f panel.tar.gz ] || [ "$FILE_SIZE" -lt 100000 ]; then
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

# Ensure APP_KEY exists (fresh installs or corrupted .env)
if ! grep -q "^APP_KEY=." "$PANEL_DIR/.env"; then
  output "Generating APP_KEY..."
  cd $PANEL_DIR && php artisan key:generate --force 2>/dev/null || true
fi

# Create storage dirs if missing after extract
mkdir -p $PANEL_DIR/storage/framework/views $PANEL_DIR/storage/framework/cache $PANEL_DIR/storage/framework/sessions $PANEL_DIR/storage/logs $PANEL_DIR/storage/app

output "Updating composer dependencies (with retry)..."
if ! run_with_retry "cd $PANEL_DIR && COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction"; then
  COMPOSER_OUTPUT=$(cd $PANEL_DIR && COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction 2>&1)
  error "Composer update failed after 3 retries:"
  echo "$COMPOSER_OUTPUT" | tail -20
  error "Rolling back from $BACKUP_DIR..."
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "$BACKUP_DIR/" "$PANEL_DIR/"
  else
    # Fallback: ensure dotfiles are restored too
    rm -rf "$PANEL_DIR"
    cp -a "$BACKUP_DIR" "$PANEL_DIR"
  fi
  (cd "$PANEL_DIR" && php artisan up 2>/dev/null || true)
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
# Filament panel providers are disabled in experimental/v2.0-EX (Galleon UI).
# Skip filament:assets/upgrade when Galleon is active to avoid errors.
if [ -d "$PANEL_DIR/resources/js/galleon" ] && [ -f "$PANEL_DIR/resources/views/galleon.blade.php" ]; then
  output "Galleon UI detected — skipping Filament asset publishing."
else
  php artisan filament:assets 2>/dev/null || true
  php artisan filament:upgrade 2>/dev/null || true
fi

output "Clearing all caches..."
php artisan config:clear 2>/dev/null || true
php artisan route:clear 2>/dev/null || true
php artisan view:clear 2>/dev/null || true
php artisan cache:clear 2>/dev/null || true
php artisan event:clear 2>/dev/null || true
php artisan optimize:clear 2>/dev/null || true

output "Setting permissions..."
# Detect web user: www-data on Ubuntu/Debian, nginx on Rocky/Alma.
WEB_USER="www-data"
id -u www-data >/dev/null 2>&1 || WEB_USER="nginx"
chown -R "$WEB_USER":"$WEB_USER" $PANEL_DIR/storage $PANEL_DIR/bootstrap/cache 2>/dev/null || true
chmod -R 775 $PANEL_DIR/storage $PANEL_DIR/bootstrap/cache 2>/dev/null || true
# Clear stale compiled caches so cached classes match new file ownership/code.
rm -f $PANEL_DIR/bootstrap/cache/*.php 2>/dev/null || true

# Ensure Inertia root view points at galleon.blade.php (default 'app' missing in this fork)
if [ -d "$PANEL_DIR/resources/js/galleon" ] && [ -f "$PANEL_DIR/resources/views/galleon.blade.php" ]; then
  if [ ! -f "$PANEL_DIR/config/inertia.php" ] || ! grep -q "galleon" "$PANEL_DIR/config/inertia.php"; then
    output "Writing config/inertia.php (root_view = galleon)..."
    cat > "$PANEL_DIR/config/inertia.php" <<'PHP'
<?php
return ['root_view' => 'galleon'];
PHP
    chown "$WEB_USER":"$WEB_USER" "$PANEL_DIR/config/inertia.php" 2>/dev/null || true
  fi
fi

# Sync egg repositories into storage/eggs (used by p:map:import-bulk + p:repair).
output "Syncing reference egg repositories..."
mkdir -p "$PANEL_DIR/storage/eggs"
sync_or_clone() {
  local url="$1" dir="$2"
  if [ -d "$dir/.git" ]; then
    (cd "$dir" && git fetch --quiet --depth 1 origin && git reset --hard --quiet origin/HEAD) || true
  elif [ ! -d "$dir" ]; then
    git clone --quiet --depth 1 "$url" "$dir" 2>&1 | tail -3 || true
  fi
}
sync_or_clone "https://github.com/parkervcp/eggs.git" "$PANEL_DIR/storage/eggs/parkervcp-eggs"
chown -R "$WEB_USER":"$WEB_USER" "$PANEL_DIR/storage/eggs" 2>/dev/null || true

# Bulk-import eggs as maps (idempotent: importer skips existing names).
if php artisan list 2>/dev/null | grep -q "p:map:import-bulk"; then
  D="$PANEL_DIR/storage/eggs/parkervcp-eggs"
  if [ -d "$D" ]; then
    output "Importing maps from $(basename "$D")..."
    (cd "$PANEL_DIR" && sudo -u "$WEB_USER" HOME=/tmp php artisan p:map:import-bulk "$D" 2>&1 | tail -10) || true
  fi
fi

# Run repair pass (docker_images, startup_commands, variables, server image refs).
if php artisan list 2>/dev/null | grep -q "p:repair"; then
  output "Running data repair (p:repair)..."
  (cd "$PANEL_DIR" && sudo -u "$WEB_USER" HOME=/tmp php artisan p:repair 2>&1 | tail -30) || true
fi

# Restart PHP-FPM to clear OPcache
output "Restarting PHP-FPM to clear OPcache..."
PHP_FPM_RESTARTED=false
for v in php8.5-fpm php8.4-fpm php8.3-fpm php8.2-fpm php-fpm; do
  if systemctl is-active --quiet "$v" 2>/dev/null; then
    systemctl restart "$v" 2>/dev/null || true
    output "  Restarted $v"
    PHP_FPM_RESTARTED=true
    break
  fi
done
if [ "$PHP_FPM_RESTARTED" = false ]; then
  output "WARNING: no active php-fpm service detected to restart."
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
HEALTH_OK=true
if ! timeout 30 php artisan about 2>&1 | grep -q 'KaNeil'; then
  HEALTH_OK=false
  error "artisan about did not return KaNeil signature"
fi

# HTTP smoke test - hit local nginx with correct Host header. Only 2xx/3xx is OK.
SMOKE_HOST=$(grep -E '^APP_URL=' "$PANEL_DIR/.env" 2>/dev/null | sed -E 's@^APP_URL=https?://([^/]+).*@\1@')
[ -z "$SMOKE_HOST" ] && SMOKE_HOST=$(hostname -f 2>/dev/null || hostname)
HTTP=$(curl -sk -o /tmp/smoke.html -w "%{http_code}" --max-time 15 -H "Host: $SMOKE_HOST" "https://127.0.0.1/" 2>/dev/null || echo "000")
if ! [[ "$HTTP" =~ ^[23][0-9][0-9]$ ]]; then
  HEALTH_OK=false
  error "HTTP smoke test returned $HTTP for Host $SMOKE_HOST (expected 2xx/3xx)"
fi

if [ "$HEALTH_OK" = true ]; then
  success "Panel health check passed (HTTP $HTTP)!"
else
  error "Panel health check FAILED."
  echo "--- Last 20 lines of laravel log ---"
  tail -20 "$PANEL_DIR"/storage/logs/laravel-"$(date +%Y-%m-%d)".log 2>/dev/null \
    || tail -20 "$PANEL_DIR"/storage/logs/laravel.log 2>/dev/null \
    || echo "No log file found."
  echo ""
  if [ -d "$BACKUP_DIR" ]; then
    echo "Auto-rollback: restoring $BACKUP_DIR -> $PANEL_DIR"
    php artisan down 2>/dev/null || true
    rsync -a --delete "$BACKUP_DIR/" "$PANEL_DIR/"
    chown -R "$WEB_USER":"$WEB_USER" "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" 2>/dev/null || true
    (cd "$PANEL_DIR" && sudo -u "$WEB_USER" HOME=/tmp php artisan optimize:clear >/dev/null 2>&1 || true)
    (cd "$PANEL_DIR" && php artisan up 2>/dev/null || true)
    for v in php8.5-fpm php8.4-fpm php8.3-fpm php8.2-fpm php-fpm; do
      systemctl is-active --quiet "$v" 2>/dev/null && systemctl restart "$v" && break
    done
    error "Update reverted. Inspect $BACKUP_DIR and logs above before retrying."
    exit 1
  else
    error "No backup directory at $BACKUP_DIR - manual recovery required."
    exit 1
  fi
fi
output ""
