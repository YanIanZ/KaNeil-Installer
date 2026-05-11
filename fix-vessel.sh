#!/bin/bash
# KaNeil Fix - Vessel create timeout + schedules not running
# Usage: sudo bash fix-vessel.sh
set -e

PANEL_DIR="${PANEL_DIR:-/var/www/kaneil}"
GITHUB_URL="${GITHUB_URL:-https://raw.githubusercontent.com/YanIanZ/KaNeil-Installer/main}"

if [ "$EUID" -ne 0 ]; then
  echo "Run as root: sudo bash fix-vessel.sh"
  exit 1
fi

if [ ! -d "$PANEL_DIR" ]; then
  echo "Panel dir not found: $PANEL_DIR"
  exit 1
fi

WEB_USER="www-data"
if ! id -u www-data >/dev/null 2>&1; then
  WEB_USER="nginx"
fi

echo "=== 1. Install/repair kaneil queue worker unit ==="
NEED_UNIT=false
if [ ! -f /etc/systemd/system/kaneil.service ]; then
  NEED_UNIT=true
elif ! grep -q "queue:work" /etc/systemd/system/kaneil.service; then
  NEED_UNIT=true
fi

if [ "$NEED_UNIT" = true ]; then
  echo "Fetching kaneil.service..."
  curl -fSL -o /etc/systemd/system/kaneil.service "$GITHUB_URL"/configs/kaneil.service
  sed -i "s@<user>@$WEB_USER@g" /etc/systemd/system/kaneil.service
fi

systemctl daemon-reload
systemctl enable kaneil.service 2>/dev/null || true
systemctl restart kaneil 2>/dev/null || systemctl start kaneil
sleep 2

if systemctl is-active --quiet kaneil; then
  echo "kaneil queue worker: ACTIVE"
else
  echo "WARNING: kaneil queue worker NOT active. journalctl -u kaneil -n 50"
fi

echo ""
echo "=== 2. Ensure GUZZLE_TIMEOUT in .env ==="
if [ -f "$PANEL_DIR/.env" ]; then
  sed -i '/^GUZZLE_TIMEOUT=/d;/^GUZZLE_CONNECT_TIMEOUT=/d' "$PANEL_DIR/.env"
  echo "GUZZLE_TIMEOUT=60" >> "$PANEL_DIR/.env"
  echo "GUZZLE_CONNECT_TIMEOUT=10" >> "$PANEL_DIR/.env"
  echo ".env updated"
else
  echo "WARNING: $PANEL_DIR/.env not found"
fi

echo ""
echo "=== 3. Install cronjob (schedule:run) ==="
if crontab -l 2>/dev/null | grep -q "kaneil/artisan schedule:run"; then
  echo "Cronjob already present (root)."
else
  (crontab -l 2>/dev/null; echo "* * * * * php $PANEL_DIR/artisan schedule:run >> /dev/null 2>&1") | crontab -
  echo "Cronjob installed (root)."
fi

echo ""
echo "=== 4. Clear + rebuild panel config cache ==="
cd "$PANEL_DIR"
sudo -u "$WEB_USER" php artisan optimize:clear 2>&1 | tail -3 || php artisan optimize:clear 2>&1 | tail -3
sudo -u "$WEB_USER" php artisan config:cache 2>&1 | tail -3 || php artisan config:cache 2>&1 | tail -3
sudo -u "$WEB_USER" php artisan route:cache 2>&1 | tail -3 || true
sudo -u "$WEB_USER" php artisan view:cache 2>&1 | tail -3 || true

echo ""
echo "=== 5. Restart PHP-FPM ==="
for v in php8.5-fpm php8.4-fpm php8.3-fpm php8.2-fpm php-fpm; do
  if systemctl is-active --quiet "$v" 2>/dev/null; then
    systemctl restart "$v"
    echo "Restarted $v"
    break
  fi
done

echo ""
echo "=== 6. Reload nginx ==="
systemctl reload nginx 2>/dev/null || true

echo ""
echo "=== 7. Verify ==="
TIMEOUT_LOADED=$(cd "$PANEL_DIR" && sudo -u "$WEB_USER" php artisan tinker --execute='echo config("panel.guzzle.timeout");' 2>/dev/null | tail -1)
echo "Effective GUZZLE_TIMEOUT: ${TIMEOUT_LOADED:-unknown}"
echo ".env GUZZLE_TIMEOUT line: $(grep ^GUZZLE_TIMEOUT= "$PANEL_DIR/.env" || echo MISSING)"

echo "kaneil:    $(systemctl is-active kaneil 2>/dev/null)"
echo "ship:      $(systemctl is-active ship 2>/dev/null)"
echo "nginx:     $(systemctl is-active nginx 2>/dev/null)"
echo "redis:     $(systemctl is-active redis-server 2>/dev/null || systemctl is-active redis 2>/dev/null)"
echo "Cron:      $(crontab -l 2>/dev/null | grep -c 'schedule:run') entry/entries"

echo ""
echo "DONE. Retry vessel create now."
echo "If still timeout: journalctl -u kaneil -u ship -f"
