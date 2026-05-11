#!/bin/bash

set -e

source /tmp/lib.sh

output ""
output "Starting KaNeil Ship Update..."

# Check if ship is installed
if [ ! -f "/usr/local/bin/ship" ]; then
  error "KaNeil Ship is not installed at /usr/local/bin/ship"
  exit 1
fi

# Get current version
output "Current ship: $(/usr/local/bin/ship --version 2>/dev/null || echo "unknown")"

# Detect architecture
ARCH="amd64"
case "$(uname -m)" in
  aarch64 | arm64) ARCH="arm64" ;;
esac

output "Downloading latest ship binary..."
curl -Lo /tmp/ship_latest "$SHIP_DL_BASE_URL$ARCH"
chmod +x /tmp/ship_latest

# Stop ship service
if systemctl is-active --quiet ship 2>/dev/null; then
  output "Stopping Ship service..."
  systemctl stop ship
fi

# Backup old binary
cp /usr/local/bin/ship /usr/local/bin/ship.backup 2>/dev/null || true

# Replace binary
mv /tmp/ship_latest /usr/local/bin/ship
chmod +x /usr/local/bin/ship

# Remove old wings binary if it exists
if [ -f "/usr/local/bin/wings" ]; then
  rm -f /usr/local/bin/wings
  output "Removed old wings binary"
fi

# Start ship service
if systemctl is-enabled --quiet ship 2>/dev/null; then
  output "Starting Ship service..."
  systemctl start ship
  sleep 2
  if systemctl is-active --quiet ship 2>/dev/null; then
    success "Ship daemon started successfully!"
  else
    error "Ship daemon failed to start. Check logs with: journalctl -u ship -n 50"
    error "Old binary backed up to /usr/local/bin/ship.backup"
  fi
else
  output "Ship service not enabled. Start manually: systemctl start ship"
fi

success "KaNeil Ship updated successfully!"
output ""
