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

# ---------- Uninstallation functions ---------- #

rm_panel_files() {
  output "Removing panel files..."
  rm -rf /var/www/kaneil /usr/local/bin/composer
  case "$OS" in
  debian | ubuntu)
    unlink /etc/nginx/sites-enabled/kaneil.conf
    rm -f /etc/nginx/sites-available/kaneil.conf
    ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
    ;;
  rocky | alma)
    rm -f /etc/nginx/conf.d/kaneil.conf
    ;;
  esac
  systemctl restart nginx
  success "Removed panel files."
}

rm_docker_containers() {
  output "Removing docker containers and images..."

  docker system prune -a -f

  success "Removed docker containers and images."
}

rm_ship_files() {
  output "Removing ship files..."

  # stop and remove ship service
  systemctl disable --now ship
  rm -rf /etc/systemd/system/ship.service

  rm -rf /etc/kaneil /usr/local/bin/ship /var/lib/kaneil
  success "Removed ship files."
}

rm_services() {
  output "Removing services..."
  systemctl disable --now kaneil
  rm -rf /etc/systemd/system/kaneil.service
  case "$OS" in
  debian | ubuntu)
    systemctl disable --now redis-server
    ;;
  rocky | alma)
    systemctl disable --now redis
    systemctl disable --now php-fpm
    rm -rf /etc/php-fpm.d/www-kaneil.conf
    ;;
  esac
  success "Removed services."
}

rm_cron() {
  output "Removing cron jobs..."
  crontab -l | grep -vF "* * * * * php /var/www/kaneil/artisan schedule:run >> /dev/null 2>&1" | crontab -
  success "Removed cron jobs."
}

rm_database() {
  output "Removing database..."
  valid_db=$(mariadb -u root -e "SELECT schema_name FROM information_schema.schemata;" | grep -v -E -- 'schema_name|information_schema|performance_schema|mysql')
  warning "Be careful! This database will be deleted!"
  if [[ "$valid_db" == *"panel"* ]]; then
    echo -n "* Database called panel has been detected. Is it the kaneil database? (y/N): "
    read -r is_panel
    if [[ "$is_panel" =~ [Yy] ]]; then
      DATABASE=panel
    else
      print_list "$valid_db"
    fi
  else
    print_list "$valid_db"
  fi
  while [ -z "$DATABASE" ] || [[ $valid_db != *"$database_input"* ]]; do
    echo -n "* Choose the panel database (to skip don't input anything): "
    read -r database_input
    if [[ -n "$database_input" ]]; then
      DATABASE="$database_input"
    else
      break
    fi
  done
  [[ -n "$DATABASE" ]] && mariadb -u root -e "DROP DATABASE $DATABASE;"
  # Exclude usernames User and root (Hope no one uses username User)
  output "Removing database user..."
  valid_users=$(mariadb -u root -e "SELECT user FROM mysql.user;" | grep -v -E -- 'user|root')
  warning "Be careful! This user will be deleted!"
  if [[ "$valid_users" == *"kaneil"* ]]; then
    echo -n "* User called kaneil has been detected. Is it the kaneil user? (y/N): "
    read -r is_user
    if [[ "$is_user" =~ [Yy] ]]; then
      DB_USER=kaneil
    else
      print_list "$valid_users"
    fi
  else
    print_list "$valid_users"
  fi
  while [ -z "$DB_USER" ] || [[ $valid_users != *"$user_input"* ]]; do
    echo -n "* Choose the panel user (to skip don't input anything): "
    read -r user_input
    if [[ -n "$user_input" ]]; then
      DB_USER=$user_input
    else
      break
    fi
  done
  [[ -n "$DB_USER" ]] && mariadb -u root -e "DROP USER $DB_USER@'127.0.0.1';"
  mariadb -u root -e "FLUSH PRIVILEGES;"
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
