#!/bin/bash

# Install jq
sudo apt install jq -y

# Function to extract the tag name and zip URL from the GitHub API response
extract_tag_and_zip_url() {
    local json_url="$1"
    local keyword="$2"

    # Download JSON response from GitHub API
    local json_response=$(curl -s "$json_url")

    # Extract tag name using jq
    local tag_name=$(echo "$json_response" | jq -r '.tag_name')

    # Extract zip URL using jq
    local zip_url=$(echo "$json_response" | jq -r --arg name "$keyword" '.assets[] | select(.name | contains($name)) | .browser_download_url')

    echo "$tag_name $zip_url"
}

# GitHub API URL for latest release
release_url="https://api.github.com/repos/tonics-apps/tonics/releases/latest"

# Keyword to search for in the zip file name
keyword=$1

# Extracting the tag name and zip URL
result=$(extract_tag_and_zip_url "$release_url" "$keyword")
TonicsVersion=$(echo "$result" | awk '{print $1}')
zipURL=$(echo "$result" | awk '{print $2}')

# Init incus
sudo incus admin init --auto

# Launch Instance
sudo incus launch images:debian/bookworm/amd64 tonics-cms

# Dependencies
sudo incus exec tonics-cms -- bash -c "apt update -y && apt upgrade -y"

sudo incus exec tonics-cms -- bash -c "DEBIAN_FRONTEND=noninteractive apt install -y unzip mariadb-server nginx wget php php8.2-fpm php8.2-dom php8.2-xml php8.2-xmlrpc php8.2-soap php8.2-mysql php8.2-mbstring php8.2-readline php8.2-gd  php8.2-gmp php8.2-bcmath php8.2-zip php8.2-curl php8.2-intl php8.2-apcu"

# Setup MariaDB
sudo incus exec tonics-cms -- bash -c "mysql --user=root -sf <<EOS
-- set root password
ALTER USER root@localhost IDENTIFIED BY 'tonics_cloud';
DELETE FROM mysql.user WHERE User='';
-- delete remote root capabilities
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
-- drop database 'test'
DROP DATABASE IF EXISTS test;
-- also make sure there are lingering permissions to it
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
-- make changes immediately
FLUSH PRIVILEGES;
EOS
"

# Start Nginx
sudo incus exec tonics-cms -- bash -c "sudo nginx"

# Clean Debian Cache
sudo incus exec tonics-cms -- bash -c "apt clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*"

# Create the target directory if it doesn't exist
sudo incus exec tonics-cms -- bash -c "mkdir -p /var/www/tonics/"

#
# Fetch Tonics, extract and install to the default web root.
#
sudo incus exec tonics-cms -- bash -c "wget '$zipURL' -O tonics.zip"
sudo incus exec tonics-cms -- bash -c "rm -Rf /var/www/html/index.html /var/www/html/index.nginx-debian.html"
sudo incus exec tonics-cms -- bash -c "unzip tonics.zip -d /var/www/tonics"

# Copy Tonics .env-sample to .env
sudo incus exec tonics-cms -- bash -c "cp -f '/var/www/tonics/web/.env-sample' '/var/www/tonics/web/.env'"

PHP_BINARY=$(sudo incus exec tonics-cms -- which php8.2)

# Setting Up SystemD Services
sudo incus exec tonics-cms -- bash -c "sed -e 's#/path/to/tonics/web#/var/www/tonics/web#g' -e 's#/usr/bin/php8.1#$PHP_BINARYb#g' </var/www/tonics/web/bin/systemd/service_name.service > /etc/systemd/system/tonics.service"
sudo incus exec tonics-cms -- bash -c "cat /etc/systemd/system/tonics.service"
sudo incus exec tonics-cms -- bash -c "sed -e 's#service_name.service#tonics.service#g' </var/www/tonics/web/bin/systemd/service_name-watcher.service > /etc/systemd/system/tonics-watcher.service"
sudo incus exec tonics-cms -- bash -c "sed -e 's#/path/to/tonics/web/bin#/var/www/tonics/web/bin#g' </var/www/tonics/web/bin/systemd/service_name-watcher.path > /etc/systemd/system/tonics-watcher.path"

# Enabling SystemD Services
sudo incus exec tonics-cms -- bash -c "systemctl daemon-reload"
sudo incus exec tonics-cms -- bash -c "systemctl --now enable tonics.service"
sudo incus exec tonics-cms -- bash -c "systemctl --now enable tonics-watcher.service"
sudo incus exec tonics-cms -- bash -c "systemctl --now enable tonics-watcher.path"

# Setting Up Tonics Permission
sudo incus exec tonics-cms -- bash -c "chown -R www-data:www-data /var/www/tonics"
# Change permission of all directory and file
sudo incus exec tonics-cms -- bash -c 'find /var/www/tonics -type d -exec chmod 755 {} \; && find /var/www/tonics -type f -exec chmod 664 {} \;'

# Change permission of env file
sudo incus exec tonics-cms -- bash -c 'chmod 660 /var/www/tonics/web/.env'

# Allow Tonics To Manage private uploads
sudo incus exec tonics-cms -- bash -c 'find /var/www/tonics/private -type d -exec chmod 755 {} \; && find /var/www/tonics/private -type f -exec chmod 664 {} \;'
# Allow Tonics To Manage public contents
sudo incus exec tonics-cms -- bash -c 'find /var/www/tonics/public -type d -exec chmod 755 {} \; && find /var/www/tonics/public -type f -exec chmod 664 {} \;'

# Publish Image
mkdir images && sudo incus stop tonics-cms && sudo incus publish tonics-cms --alias tonics-cms

Version="MariaDB__$(sudo incus exec tonics-cms -- mysql -V | awk '{print $5}' | sed 's/,//')__Nginx__$(sudo incus exec tonics-cms -- nginx -v |& sed 's/nginx version: nginx\///')__PHP__$(sudo incus exec tonics-cms -- php -v | head -n 1 | awk '{print $2}' | cut -d '-' -f 1)__$1__$TonicsVersion"

# Export Image
sudo incus start tonics-cms
sudo incus image export tonics-cms images/tonics-bookworm-$Version

# Image Info
sudo incus image info tonics-cms >> images/info.txt
