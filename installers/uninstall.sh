#!/bin/bash

set -e

######################################################################################
#                                                                                    #
# Project 'kaneil-installer'                                                        #
#                                                                                    #
# Copyright (C) 2018 - 2025, YanIanZ                    #
#                                                                                    #
#   This program is free software: you can redistribute it and/or modify             #
#   it under the terms of the GNU General Public License as published by             #
#   the Free Software Foundation, either version 3 of the License, or                #
#   (at your option) any later version.                                              #
#                                                                                    #
#   This program is distributed in the hope that it will be useful,                  #
#   but WITHOUT ANY WARRANTY; without even the implied warranty of                   #
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the                    #
#   GNU General Public License for more details.                                     #
#                                                                                    #
#   You should have received a copy of the GNU General Public License                #
#   along with this program.  If not, see <https://www.gnu.org/licenses/>.           #
#                                                                                    #
# https://github.com/YanIanZ/KaNeil-Installer/blob/main/LICENSE                  #
#                                                                                    #
# This script is not associated with the official KaNeil Project.                   #
# https://github.com/YanIanZ/KaNeil-Installer                                    #
#                                                                                    #
######################################################################################

# Check if script is loaded, load if not or fail otherwise.
fn_exists() { declare -F "$1" >/dev/null; }
if ! fn_exists lib_loaded; then
  # shellcheck source=lib/lib.sh
  source /tmp/lib.sh || source <(curl -sSL "$GITHUB_BASE_URL/$GITHUB_SOURCE"/lib/lib.sh)
  ! fn_exists lib_loaded && echo "* ERROR: Could not load lib script" && exit 1
fi

# ------------------ Variables ----------------- #

RM_PANEL="${RM_PANEL:-true}"
RM_SHIP="${RM_SHIP:-true}"

# Read from .env if panel exists
PANEL_ENV="/var/www/kaneil/.env"
if [ -f "$PANEL_ENV" ]; then
  DB_DATABASE_DETECTED=$(grep -E '^DB_DATABASE=' "$PANEL_ENV" | cut -d= -f2-)
  DB_USERNAME_DETECTED=$(grep -E '^DB_USERNAME=' "$PANEL_ENV" | cut -d= -f2-)
fi

# ---------- Uninstallation functions ---------- #

rm_panel_files() {
  output "Removing panel files..."
  rm -rf /var/www/kaneil /usr/local/bin/composer
  case "$OS" in
  debian | ubuntu)
    unlink /etc/nginx/sites-enabled/kaneil.conf 2>/dev/null || true
    rm -f /etc/nginx/sites-available/kaneil.conf
    ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default 2>/dev/null || true
    ;;
  rocky | almalinux)
    rm -f /etc/nginx/conf.d/kaneil.conf
    ;;
  esac
  systemctl restart nginx 2>/dev/null || true
  success "Removed panel files."
}

rm_docker_containers() {
  output "Removing docker containers and images..."
  docker system prune -a -f 2>/dev/null || true
  success "Removed docker containers and images."
}

rm_ship_files() {
  output "Removing ship files..."
  systemctl disable --now ship 2>/dev/null || true
  rm -rf /etc/systemd/system/ship.service
  rm -rf /etc/kaneil /usr/local/bin/ship /var/lib/kaneil
  success "Removed ship files."
}

rm_services() {
  output "Removing services..."
  systemctl disable --now kaneil 2>/dev/null || true
  rm -rf /etc/systemd/system/kaneil.service
  case "$OS" in
  debian | ubuntu)
    systemctl disable --now redis-server 2>/dev/null || true
    ;;
  rocky | almalinux)
    systemctl disable --now redis 2>/dev/null || true
    systemctl disable --now php-fpm 2>/dev/null || true
    rm -rf /etc/php-fpm.d/www-kaneil.conf
    ;;
  esac
  success "Removed services."
}

rm_cron() {
  output "Removing cron jobs..."
  crontab -l 2>/dev/null | grep -vF "* * * * * php /var/www/kaneil/artisan schedule:run >> /dev/null 2>&1" | crontab - 2>/dev/null || true
  success "Removed cron jobs."
}

rm_database() {
  output "Removing database..."

  # Detect database name from .env
  if [ -n "$DB_DATABASE_DETECTED" ]; then
    output "Detected DB_DATABASE from .env: $DB_DATABASE_DETECTED"
    echo -n "* Use this database name? [$DB_DATABASE_DETECTED] (y/N): "
    read -r USE_DETECTED_DB
    if [[ "$USE_DETECTED_DB" =~ [Yy] ]]; then
      DATABASE="$DB_DATABASE_DETECTED"
    fi
  fi

  # List available databases and let user pick
  if [ -z "$DATABASE" ]; then
    valid_db=$(mariadb -u root -e "SELECT schema_name FROM information_schema.schemata;" 2>/dev/null | grep -v -E -- 'schema_name|information_schema|performance_schema|mysql')
    if [ -n "$valid_db" ]; then
      warning "Available databases:"
      print_list "$valid_db"
      echo -n "* Type the database name to drop (or leave empty to skip): "
      read -r database_input
      if [ -n "$database_input" ]; then
        DATABASE="$database_input"
      fi
    else
      output "No databases found. Skipping database removal."
    fi
  fi

  # Drop database if specified and exists
  if [ -n "$DATABASE" ]; then
    EXISTS=$(mariadb -u root -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$DATABASE';" 2>/dev/null | grep -c "$DATABASE" || true)
    if [ "$EXISTS" -gt 0 ]; then
      warning "This will DROP database '$DATABASE' permanently!"
      echo -n "* Confirm by typing the database name '$DATABASE': "
      read -r CONFIRM_DB
      if [ "$CONFIRM_DB" == "$DATABASE" ]; then
        mariadb -u root -e "DROP DATABASE IF EXISTS \`$DATABASE\`;" 2>/dev/null || true
        success "Dropped database '$DATABASE'."
      else
        output "Database drop skipped (name mismatch)."
      fi
    else
      output "Database '$DATABASE' does not exist. Skipping."
    fi
  else
    output "No database specified. Skipping."
  fi

  # Remove database user
  output "Removing database user..."

  # Detect username from .env
  if [ -n "$DB_USERNAME_DETECTED" ]; then
    output "Detected DB_USERNAME from .env: $DB_USERNAME_DETECTED"
    echo -n "* Use this username? [$DB_USERNAME_DETECTED] (y/N): "
    read -r USE_DETECTED_USER
    if [[ "$USE_DETECTED_USER" =~ [Yy] ]]; then
      DB_USER="$DB_USERNAME_DETECTED"
    fi
  fi

  if [ -z "$DB_USER" ]; then
    valid_users=$(mariadb -u root -e "SELECT user FROM mysql.user;" 2>/dev/null | grep -v -E -- 'user|root')
    if [ -n "$valid_users" ]; then
      warning "Available users:"
      print_list "$valid_users"
      echo -n "* Type the username to drop (or leave empty to skip): "
      read -r user_input
      if [ -n "$user_input" ]; then
        DB_USER="$user_input"
      fi
    fi
  fi

  if [ -n "$DB_USER" ]; then
    EXISTS=$(mariadb -u root -e "SELECT User FROM mysql.user WHERE User='$DB_USER';" 2>/dev/null | grep -c "$DB_USER" || true)
    if [ "$EXISTS" -gt 0 ]; then
      warning "This will DROP user '$DB_USER' permanently!"
      echo -n "* Confirm by typing the username '$DB_USER': "
      read -r CONFIRM_USER
      if [ "$CONFIRM_USER" == "$DB_USER" ]; then
        mariadb -u root -e "DROP USER IF EXISTS '$DB_USER'@'127.0.0.1';" 2>/dev/null || true
        mariadb -u root -e "DROP USER IF EXISTS '$DB_USER'@'localhost';" 2>/dev/null || true
        mariadb -u root -e "FLUSH PRIVILEGES;" 2>/dev/null || true
        success "Dropped user '$DB_USER'."
      else
        output "User drop skipped (name mismatch)."
      fi
    else
      output "User '$DB_USER' does not exist. Skipping."
    fi
  else
    output "No username specified. Skipping."
  fi

  success "Removed database and database user."
}

# --------------- Main functions --------------- #

perform_uninstall() {
  [ "$RM_PANEL" == true ] && rm_panel_files
  [ "$RM_PANEL" == true ] && rm_cron
  [ "$RM_PANEL" == true ] && rm_database
  [ "$RM_PANEL" == true ] && rm_services
  [ "$RM_SHIP" == true ] && rm_docker_containers
  [ "$RM_SHIP" == true ] && rm_ship_files

  return 0
}

# ------------------ Uninstall ----------------- #

perform_uninstall
