#!/bin/sh
# name: Web Server
# summary: nginx, serving the pages in /srv/site
# category: server
# systems: ubuntu debian

set -eu

echo "==> Installing nginx"
apt-get update
apt-get install -y nginx

echo "==> Setting up the site"
mkdir -p /srv/site
echo "<h1>Hello from $(hostname)</h1>" > /srv/site/index.html
chown -R "$SWIFTVM_USER" /srv/site
cat > /etc/nginx/sites-available/default << 'END'
server {
    listen 80 default_server;
    root /srv/site;
}
END
systemctl reload nginx
