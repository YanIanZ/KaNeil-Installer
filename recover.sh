#!/bin/bash
# KaNeil Panel Recovery - restore from backup, fix perms, clear cache.
# Usage: sudo bash recover.sh
set -u

PANEL_DIR="/var/www/kaneil"
WEB_USER="www-data"
id -u www-data >/dev/null 2>&1 || WEB_USER="nginx"

if [ "$EUID" -ne 0 ]; then
  echo "Run as root: sudo bash recover.sh"
  exit 1
fi

echo "=== 1. Locate latest backup ==="
LATEST_BACKUP=$(ls -dt /var/www/kaneil_backup_* 2>/dev/null | head -n 1)
if [ -z "$LATEST_BACKUP" ]; then
  echo "No backup found. Will only fix perms + clear cache."
else
  echo "Latest backup: $LATEST_BACKUP"
fi

echo ""
echo "=== 2. Bring panel out of maintenance ==="
[ -f "$PANEL_DIR/artisan" ] && (cd "$PANEL_DIR" && php artisan up 2>/dev/null || true)

echo ""
echo "=== 3. Check critical files ==="
NEED_RESTORE=false
[ ! -f "$PANEL_DIR/.env" ] && NEED_RESTORE=true && echo "  .env missing"
[ ! -d "$PANEL_DIR/vendor" ] && NEED_RESTORE=true && echo "  vendor/ missing"
[ ! -f "$PANEL_DIR/artisan" ] && NEED_RESTORE=true && echo "  artisan missing"
[ ! -d "$PANEL_DIR/public" ] && NEED_RESTORE=true && echo "  public/ missing"
if [ "$NEED_RESTORE" = true ] && [ -n "$LATEST_BACKUP" ]; then
  echo "  Restoring from backup..."
  rsync -a --delete "$LATEST_BACKUP/" "$PANEL_DIR/"
  echo "  Restored."
elif [ "$NEED_RESTORE" = true ]; then
  echo "  CRITICAL: files missing and no backup. Reinstall needed."
  exit 1
else
  echo "  All critical files present."
fi

echo ""
echo "=== 4. Fix ownership ==="
chown -R "$WEB_USER":"$WEB_USER" "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" 2>/dev/null
chmod -R 775 "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" 2>/dev/null
chown "$WEB_USER":"$WEB_USER" "$PANEL_DIR/.env" 2>/dev/null
echo "  Owner: $WEB_USER"

echo ""
echo "=== 4b. Ensure config/inertia.php points root view to galleon ==="
if [ -d "$PANEL_DIR/resources/js/galleon" ] && [ -f "$PANEL_DIR/resources/views/galleon.blade.php" ]; then
  if [ ! -f "$PANEL_DIR/config/inertia.php" ] || ! grep -q "galleon" "$PANEL_DIR/config/inertia.php"; then
    cat > "$PANEL_DIR/config/inertia.php" <<'PHP'
<?php
return ['root_view' => 'galleon'];
PHP
    chown "$WEB_USER":"$WEB_USER" "$PANEL_DIR/config/inertia.php"
    echo "  Wrote config/inertia.php"
  else
    echo "  config/inertia.php already correct."
  fi
fi

echo ""
echo "=== 5. Clear stale caches ==="
rm -f "$PANEL_DIR/bootstrap/cache/"*.php 2>/dev/null
rm -rf "$PANEL_DIR/storage/framework/views/"* 2>/dev/null
rm -rf "$PANEL_DIR/storage/framework/cache/data/"* 2>/dev/null
(cd "$PANEL_DIR" && sudo -u "$WEB_USER" HOME=/tmp php artisan optimize:clear 2>&1 | tail -5)

echo ""
echo "=== 6. Ensure composer deps ==="
if [ ! -f "$PANEL_DIR/vendor/autoload.php" ]; then
  echo "  vendor missing, running composer install..."
  (cd "$PANEL_DIR" && composer install --no-dev --optimize-autoloader --no-interaction 2>&1 | tail -5)
  chown -R "$WEB_USER":"$WEB_USER" "$PANEL_DIR/vendor"
fi

echo ""
echo "=== 7. Restart services ==="
for v in php8.5-fpm php8.4-fpm php8.3-fpm php8.2-fpm php-fpm; do
  if systemctl is-active --quiet "$v" 2>/dev/null; then
    systemctl restart "$v"
    echo "  Restarted $v"
    break
  fi
done
systemctl reload nginx 2>/dev/null || true
systemctl restart ship 2>/dev/null || true
systemctl restart kaneil 2>/dev/null || true

echo ""
echo "=== 8. Smoke test ==="
HTTP=$(curl -sk -o /dev/null -w "%{http_code}" https://localhost/ -H "Host: $(hostname -f)" 2>/dev/null)
echo "  Local HTTPS: $HTTP"
(cd "$PANEL_DIR" && sudo -u "$WEB_USER" HOME=/tmp php artisan --version 2>&1 | tail -1)

echo ""
echo "=== 9. Recent errors (if any) ==="
LOG="$PANEL_DIR/storage/logs/laravel-$(date +%Y-%m-%d).log"
if [ -f "$LOG" ]; then
  grep -E "production\.(ERROR|CRITICAL)" "$LOG" 2>/dev/null | tail -5
else
  echo "  No log file for today."
fi

echo ""
echo "DONE. If still 500, run:"
echo "  tail -50 $PANEL_DIR/storage/logs/laravel-\$(date +%Y-%m-%d).log"
