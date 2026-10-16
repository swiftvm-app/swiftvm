#!/bin/sh
# name: Web Server
# summary: nginx, serving the pages in /srv/site
# category: server
# systems: ubuntu debian arch

set -eu

echo "==> Installing nginx"
if command -v pacman > /dev/null; then
    # The keys that sign today's packages first, which may be newer than the system's.
    pacman -Sy --noconfirm --needed $(pacman -Qqs '^arch.*-keyring$')
    pacman -Su --noconfirm --needed nginx
else
    apt-get update
    apt-get install -y nginx
fi

echo "==> Setting up the site"
mkdir -p /srv/site
echo "<h1>Hello from $(hostname)</h1>" > /srv/site/index.html
chown -R "$SWIFTVM_USER" /srv/site
if [ -d /etc/nginx/sites-available ]; then
    cat > /etc/nginx/sites-available/default << 'END'
server {
    listen 80 default_server;
    root /srv/site;
}
END
    systemctl reload nginx
else
    # Arch Linux keeps the whole configuration in one file, and doesn't start nginx by itself.
    cat > /etc/nginx/nginx.conf << 'END'
worker_processes auto;

events {
    worker_connections 1024;
}

http {
    include mime.types;
    default_type application/octet-stream;

    server {
        listen 80 default_server;
        root /srv/site;
    }
}
END
    systemctl enable nginx
    systemctl restart nginx
fi
