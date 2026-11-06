#!/bin/sh
# name: Web Server
# summary: nginx, serving the pages in /srv/site
# category: server
# systems: ubuntu debian fedora arch

set -eu

echo "==> Installing nginx"
if command -v pacman > /dev/null; then
    # The keys that sign today's packages first, which may be newer than the system's.
    pacman -Sy --noconfirm --needed $(pacman -Qqs '^arch.*-keyring$')
    pacman -Su --noconfirm --needed nginx
elif command -v dnf > /dev/null; then
    dnf -y install nginx
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
    # Arch Linux and Fedora keep the whole configuration in one file, and don't start nginx by
    # themselves. On Fedora, SELinux lets nginx read only what is marked as web content.
    if command -v restorecon > /dev/null && [ "$(getenforce 2> /dev/null)" = Enforcing ]; then
        chcon -R -t httpd_sys_content_t /srv/site
    fi
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
