#!/usr/bin/env bash
# NexaPanel Nginx Fix — installs/configures nginx for already-installed panel
# Run: curl -sSL https://raw.githubusercontent.com/payoro11/nexa-panel/main/nginx-fix.sh | sudo bash
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $1"; }
info() { echo -e "${BLUE}➜${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
fail() { echo -e "✗ ERROR: $1"; exit 1; }

[ "$EUID" -ne 0 ] && fail "Run as root"

PANEL_DIR="/opt/nexapanel"
PANEL_PORT=8080
PMA_DIR="/var/www/phpmyadmin"
PHP_FPM_SOCK="/run/php/php8.3-fpm.sock"

[ -d "$PANEL_DIR" ] || fail "NexaPanel not installed at $PANEL_DIR"

# 1. Install nginx
info "Installing nginx..."
apt-get update -qq >> /tmp/nginx-fix.log 2>&1 || true
apt-get install -y nginx >> /tmp/nginx-fix.log 2>&1 || {
  apt-get -f install -y >> /tmp/nginx-fix.log 2>&1 || true
  apt-get install -y --fix-missing nginx >> /tmp/nginx-fix.log 2>&1
}
ok "Nginx installed"

# 2. Create dirs
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled /var/www/html

# 3. Write nginx config
SERVER_IP=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
info "Writing nginx config (server IP: ${SERVER_IP})..."

cat > /etc/nginx/sites-available/nexapanel.conf << NGINX
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${SERVER_IP} _;
    client_max_body_size 500M;

    location ^~ /panel/assets/ {
        alias ${PANEL_DIR}/artifacts/nexapanel/dist/public/assets/;
        expires 1y;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    location ^~ /panel/ {
        alias ${PANEL_DIR}/artifacts/nexapanel/dist/public/;
        try_files \$uri \$uri/ /panel/index.html;
        expires -1;
        add_header Cache-Control "no-store, no-cache, must-revalidate";
    }
    location = /panel { return 301 /panel/; }

    location /api {
        proxy_pass http://127.0.0.1:${PANEL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 600s;
        client_max_body_size 500M;
    }

    location = /nexa-signon.php {
        root /var/www/html;
        fastcgi_pass unix:${PHP_FPM_SOCK};
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME /var/www/html/nexa-signon.php;
    }

    location /phpmyadmin {
        alias ${PMA_DIR};
        index index.php;
        location ~ \.php$ {
            fastcgi_pass unix:${PHP_FPM_SOCK};
            fastcgi_index index.php;
            include fastcgi_params;
            fastcgi_param SCRIPT_FILENAME \$request_filename;
        }
    }

    location = / { return 301 /panel; }
}
NGINX

ok "Nginx config written"

# 4. Enable site, remove default
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/nexapanel.conf /etc/nginx/sites-enabled/nexapanel

# 5. Set correct permissions on panel frontend
chmod o+x /opt /opt/nexapanel 2>/dev/null || true
find "${PANEL_DIR}/artifacts/nexapanel/dist" -type d -exec chmod o+rx {} \; 2>/dev/null || true
find "${PANEL_DIR}/artifacts/nexapanel/dist" -type f -exec chmod o+r {} \; 2>/dev/null || true

# 6. Start nginx
systemctl enable nginx >> /tmp/nginx-fix.log 2>&1 || true
nginx -t && systemctl restart nginx && ok "Nginx started ✓" || fail "nginx -t failed — check: nginx -t"

sleep 2
# 7. Check panel accessible
if curl -sf --connect-timeout 5 "http://127.0.0.1/panel/" -o /dev/null; then
  ok "Panel accessible at http://127.0.0.1/panel/ ✓"
else
  warn "Panel not responding on port 80 yet — check: systemctl status nginx"
fi

echo ""
echo -e "${GREEN}${BOLD}Done! Open: http://${SERVER_IP}/panel${NC}"
echo -e "  Login: admin@example.com / admin123"
