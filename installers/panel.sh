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

# Domain name / IP
FQDN="${FQDN:-localhost}"

# Default MySQL credentials
MYSQL_DB="${MYSQL_DB:-panel}"
MYSQL_USER="${MYSQL_USER:-kaneil}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-$(gen_passwd 64)}"

# Environment
timezone="${timezone:-America/New_York}"

# Assume SSL, will fetch different config if true
ASSUME_SSL="${ASSUME_SSL:-false}"
CONFIGURE_LETSENCRYPT="${CONFIGURE_LETSENCRYPT:-false}"

# Firewall
CONFIGURE_FIREWALL="${CONFIGURE_FIREWALL:-false}"

# Must be assigned to work, no default values
email="${email:-}"
user_email="${user_email:-}"
user_username="${user_username:-}"
user_password="${user_password:-}"

if [[ -z "${email}" ]]; then
  error "Email is required"
  exit 1
fi

if [[ -z "${user_email}" ]]; then
  error "User email is required"
  exit 1
fi

if [[ -z "${user_username}" ]]; then
  error "User username is required"
  exit 1
fi

if [[ -z "${user_password}" ]]; then
  error "User password is required"
  exit 1
fi

# --------- Main installation functions -------- #

install_composer() {
  output "Installing composer.."
  curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
  success "Composer installed!"
}

if [ -z "$PANEL_DL_URL" ]; then
  PANEL_DL_URL="https://github.com/YanIanZ/KaNeil-Panel/releases/download/experimental-latest/panel.tar.gz"
fi

ptdl_dl() {
  output "Downloading kaneil panel files .. "
  mkdir -p /var/www/kaneil
  cd /var/www/kaneil || exit

  curl -Lo panel.tar.gz "$PANEL_DL_URL"
  tar -xzvf panel.tar.gz

  # Ensure all required framework directories exist before composer scripts run.
  # post-autoload-dump triggers filament:upgrade which needs view.compiled path.
  mkdir -p storage/framework/views \
           storage/framework/cache/data \
           storage/framework/sessions \
           storage/framework/testing \
           storage/logs \
           storage/app/public \
           bootstrap/cache

  chmod -R 755 storage bootstrap/cache

  cp .env.example .env

  success "Downloaded kaneil panel files!"
}

install_composer_deps() {
  output "Installing composer dependencies.."
  [ "$OS" == "rocky" ] || [ "$OS" == "alma" ] && export PATH=/usr/local/bin:$PATH

  # Two-phase install: skip post-scripts on first pass (before APP_KEY exists),
  # generate APP_KEY + setup env, then run scripts manually.
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-scripts --no-interaction

  # Generate APP_KEY now so filament:upgrade etc. have a valid env to work with.
  # (Will be re-checked by configure() but safe to call twice.)
  if ! grep -q '^APP_KEY=base64:' .env 2>/dev/null; then
    php artisan key:generate --force 2>/dev/null || true
  fi

  # Now run the post-autoload scripts that we skipped.
  COMPOSER_ALLOW_SUPERUSER=1 composer run-script post-autoload-dump --no-interaction || \
    output "Warning: post-autoload-dump scripts had non-fatal errors (continuing)"

  success "Installed composer dependencies!"
}

# Configure environment
configure() {
  output "Configuring environment.."

  local app_url="http://$FQDN"
  [ "$ASSUME_SSL" == true ] && app_url="https://$FQDN"
  [ "$CONFIGURE_LETSENCRYPT" == true ] && app_url="https://$FQDN"

  # Generate .env file and APP_KEY automatically
  php artisan p:environment:setup

  # Update environment variables to bypass Web Installer
  sed -i "s@APP_URL=.*@APP_URL=$app_url@g" .env
  sed -i "s/APP_INSTALLED=false/APP_INSTALLED=true/g" .env
  sed -i "s/APP_ENV=local/APP_ENV=production/g" .env
  
  # Configure Database and Redis (Append to .env)
  cat <<EOF >> .env

# Database Configuration
DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=$MYSQL_DB
DB_USERNAME=$MYSQL_USER
DB_PASSWORD=$MYSQL_PASSWORD

# Redis Configuration
CACHE_STORE=redis
CACHE_PREFIX=
SESSION_DRIVER=redis
SESSION_LIFETIME=120
QUEUE_CONNECTION=redis
REDIS_HOST=127.0.0.1
REDIS_PASSWORD=null
REDIS_PORT=6379
EOF

  # Run database migrations
  php artisan migrate --seed --force

  # Create admin user account (skip if already exists)
  EXISTING_USER=$(php artisan tinker --execute="echo App\Models\User::where('username', '$user_username')->orWhere('email', '$user_email')->count();" 2>/dev/null || echo "0")
  if [ "${EXISTING_USER:-0}" -eq 0 ]; then
    php artisan p:user:make \
      --email="$user_email" \
      --username="$user_username" \
      --password="$user_password" \
      --admin=1
  else
    output "Admin user '$user_username' already exists. Skipping creation."
  fi

  success "Configured environment!"
}

# set the correct folder permissions depending on OS and webserver
set_folder_permissions() {
  # if os is ubuntu or debian, we do this
  case "$OS" in
  debian | ubuntu)
    chown -R www-data:www-data /var/www/kaneil
    ;;
  rocky | almalinux | alma)
    chown -R nginx:nginx /var/www/kaneil
    ;;
  esac
}

insert_cronjob() {
  output "Installing cronjob.. "

  if crontab -l 2>/dev/null | grep -qF "kaneil/artisan schedule:run"; then
    output "Cronjob already present, skipping."
  else
    (crontab -l 2>/dev/null; echo "* * * * * php /var/www/kaneil/artisan schedule:run >> /dev/null 2>&1") | crontab -
  fi

  if ! crontab -l 2>/dev/null | grep -qF "kaneil/artisan schedule:run"; then
    error "Cronjob install failed - schedule:run not in crontab"
    return 1
  fi

  success "Cronjob installed!"
}

install_kaneilq() {
  output "Installing kaneilq service.."

  curl -fSL -o /etc/systemd/system/kaneil.service "$GITHUB_URL"/configs/kaneil.service

  if [ ! -s /etc/systemd/system/kaneil.service ]; then
    error "Failed to fetch kaneil.service unit"
    return 1
  fi

  case "$OS" in
  debian | ubuntu)
    sed -i -e "s@<user>@www-data@g" /etc/systemd/system/kaneil.service
    ;;
  rocky | almalinux | alma)
    sed -i -e "s@<user>@nginx@g" /etc/systemd/system/kaneil.service
    ;;
  esac

  systemctl daemon-reload
  systemctl enable kaneil.service
  systemctl restart kaneil

  sleep 2
  if ! systemctl is-active --quiet kaneil; then
    error "kaneil queue worker failed to start - check: journalctl -u kaneil -n 50"
    return 1
  fi

  success "Installed kaneilq!"
}

# -------- OS specific install functions ------- #

enable_services() {
  case "$OS" in
  ubuntu | debian)
    systemctl enable redis-server
    systemctl start redis-server
    ;;
  rocky | almalinux | alma)
    systemctl enable redis
    systemctl start redis
    ;;
  esac
  systemctl enable nginx
  systemctl enable mariadb
  systemctl start mariadb
}

selinux_allow() {
  setsebool -P httpd_can_network_connect 1 || true # these commands can fail OK
  setsebool -P httpd_execmem 1 || true
  setsebool -P httpd_unified 1 || true
}

php_fpm_conf() {
  curl -o /etc/php-fpm.d/www-kaneil.conf "$GITHUB_URL"/configs/www-kaneil.conf

  systemctl enable php-fpm
  systemctl start php-fpm
}

ubuntu_dep() {
  # Install deps for adding repos
  install_packages "software-properties-common apt-transport-https ca-certificates gnupg"

  # Add Ubuntu universe repo
  add-apt-repository universe -y

  # Add PPA for PHP (we need 8.5)
  LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
}

debian_dep() {
  # Install deps for adding repos
  install_packages "dirmngr ca-certificates apt-transport-https lsb-release"

  # Install PHP 8.5 using sury's repo
  curl -o /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg
  echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" | tee /etc/apt/sources.list.d/php.list
}

alma_rocky_dep() {
  # SELinux tools
  install_packages "policycoreutils selinux-policy selinux-policy-targeted \
    setroubleshoot-server setools setools-console mcstrans"

  # add remi repo (php8.5)
  install_packages "epel-release http://rpms.remirepo.net/enterprise/remi-release-$OS_VER_MAJOR.rpm"
  dnf module enable -y php:remi-8.5
}

dep_install() {
  output "Installing dependencies for $OS $OS_VER..."

  # Update repos before installing
  update_repos

  [ "$CONFIGURE_FIREWALL" == true ] && install_firewall && firewall_ports

  case "$OS" in
  ubuntu | debian)
    [ "$OS" == "ubuntu" ] && ubuntu_dep
    [ "$OS" == "debian" ] && debian_dep

    update_repos

    # Install dependencies
    install_packages "php8.5 php8.5-{cli,common,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip,redis,intl,sqlite3} \
      mariadb-common mariadb-server mariadb-client \
      nginx \
      redis-server \
      zip unzip tar \
      git cron"

    [ "$CONFIGURE_LETSENCRYPT" == true ] && install_packages "certbot python3-certbot-nginx"

    ;;
  rocky | almalinux | alma)
    alma_rocky_dep

    # Install dependencies
    install_packages "php php-{common,fpm,cli,json,mysqlnd,mcrypt,gd,mbstring,pdo,zip,bcmath,dom,opcache,posix,redis,intl,sqlite3} \
      mariadb mariadb-server \
      nginx \
      redis \
      zip unzip tar \
      git cronie"

    [ "$CONFIGURE_LETSENCRYPT" == true ] && install_packages "certbot python3-certbot-nginx"

    # Allow nginx
    selinux_allow

    # Create config for php fpm
    php_fpm_conf
    ;;
  esac

  enable_services

  success "Dependencies installed!"
}

# --------------- Other functions -------------- #

firewall_ports() {
  output "Opening ports: 22 (SSH), 80 (HTTP) and 443 (HTTPS)"

  firewall_allow_ports "22 80 443"

  success "Firewall ports opened!"
}

letsencrypt() {
  FAILED=false

  output "Configuring Let's Encrypt..."

  # Obtain certificate
  certbot --nginx --redirect --no-eff-email --email "$email" -d "$FQDN" || FAILED=true

  # Check if it succeded
  if [ ! -d "/etc/letsencrypt/live/$FQDN/" ] || [ "$FAILED" == true ]; then
    warning "The process of obtaining a Let's Encrypt certificate failed!"
    echo -n "* Still assume SSL? (y/N): "
    read -r CONFIGURE_SSL

    if [[ "$CONFIGURE_SSL" =~ [Yy] ]]; then
      ASSUME_SSL=true
      CONFIGURE_LETSENCRYPT=false
      configure_nginx
    else
      ASSUME_SSL=false
      CONFIGURE_LETSENCRYPT=false
    fi
  else
    success "The process of obtaining a Let's Encrypt certificate succeeded!"
  fi
}

# ------ Webserver configuration functions ----- #

configure_nginx() {
  output "Configuring nginx .."

  if [ "$ASSUME_SSL" == true ] && [ "$CONFIGURE_LETSENCRYPT" == false ]; then
    DL_FILE="nginx_ssl.conf"
  else
    DL_FILE="nginx.conf"
  fi

  case "$OS" in
  ubuntu | debian)
    PHP_SOCKET="/run/php/php8.5-fpm.sock"
    CONFIG_PATH_AVAIL="/etc/nginx/sites-available"
    CONFIG_PATH_ENABL="/etc/nginx/sites-enabled"
    ;;
  rocky | almalinux | alma)
    PHP_SOCKET="/var/run/php-fpm/kaneil.sock"
    CONFIG_PATH_AVAIL="/etc/nginx/conf.d"
    CONFIG_PATH_ENABL="$CONFIG_PATH_AVAIL"
    ;;
  esac

  rm -rf "$CONFIG_PATH_ENABL"/default

  curl -o "$CONFIG_PATH_AVAIL"/kaneil.conf "$GITHUB_URL"/configs/$DL_FILE

  sed -i -e "s@<domain>@${FQDN}@g" "$CONFIG_PATH_AVAIL"/kaneil.conf

  sed -i -e "s@<php_socket>@${PHP_SOCKET}@g" "$CONFIG_PATH_AVAIL"/kaneil.conf

  case "$OS" in
  ubuntu | debian)
    ln -sf "$CONFIG_PATH_AVAIL"/kaneil.conf "$CONFIG_PATH_ENABL"/kaneil.conf
    ;;
  esac

  if [ "$ASSUME_SSL" == false ] && [ "$CONFIGURE_LETSENCRYPT" == false ]; then
    systemctl restart nginx
  fi

  success "Nginx configured!"
}

# --------------- Main functions --------------- #

perform_install() {
  output "Starting installation.. this might take a while!"
  dep_install
  install_composer
  ptdl_dl
  install_composer_deps
  create_db_user "$MYSQL_USER" "$MYSQL_PASSWORD"
  create_db "$MYSQL_DB" "$MYSQL_USER"
  configure
  set_folder_permissions
  insert_cronjob
  install_kaneilq
  configure_nginx
  [ "$CONFIGURE_LETSENCRYPT" == true ] && letsencrypt

  return 0
}

# ------------------- Install ------------------ #

perform_install
