#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  NexaPanel Smart Repair Script — Auto-diagnose & fix all issues
#  Usage: curl -sSL https://raw.githubusercontent.com/payoro11/nexa-panel/main/repair.sh | sudo bash
#  Or:    sudo bash repair.sh [--check-only]
# ═══════════════════════════════════════════════════════════════
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; BOLD='\033[1m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()    { echo -e "${GREEN}  ✓${NC} $1"; }
warn()  { echo -e "${YELLOW}  ⚠${NC} $1"; WARNINGS=$((WARNINGS+1)); }
fail()  { echo -e "${RED}  ✗${NC} $1"; FAILURES=$((FAILURES+1)); }
info()  { echo -e "${BLUE}  ➜${NC} $1"; }
step()  { echo -e "\n${CYAN}${BOLD}══ $1${NC}"; }
fixed() { echo -e "${GREEN}  ✔ FIXED:${NC} $1"; FIXED_COUNT=$((FIXED_COUNT+1)); }

[ "$EUID" -ne 0 ] && { echo "Run as root: sudo bash repair.sh"; exit 1; }

CHECK_ONLY=0
[[ "$*" == *--check-only* ]] && CHECK_ONLY=1

PANEL_DIR="/opt/nexapanel"
PANEL_PORT=8080
PANEL_SERVICE="nexapanel"
PG_USER="nexapanel"
PG_DB="nexapanel"
LOG="/var/log/nexapanel-repair.log"
WARNINGS=0; FAILURES=0; FIXED_COUNT=0

exec > >(tee -a "$LOG") 2>&1
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║     NexaPanel Smart Repair — $(date +%Y-%m-%d)      ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════╝${NC}"

# ─── helpers ───────────────────────────────────────────────────
svc_running() { systemctl is-active --quiet "$1" 2>/dev/null; }
svc_restart() {
  local s="$1"
  info "Restarting $s..."
  systemctl restart "$s" >> "$LOG" 2>&1 && ok "$s restarted" || warn "$s restart failed"
}
wait_apt() {
  local i=0
  while fuser /var/lib/dpkg/lock-frontend > /dev/null 2>&1; do
    i=$((i+1)); [ $i -gt 20 ] && break; sleep 2
  done
}
pkg_install() { wait_apt; DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >> "$LOG" 2>&1; }

# Read installed config
PANEL_DB_PASS=""
if [ -f "$PANEL_DIR/.env" ]; then
  PANEL_DB_PASS=$(grep "^DATABASE_URL=" "$PANEL_DIR/.env" 2>/dev/null | sed 's/.*:\(.*\)@.*/\1/')
fi
MYSQL_PASS=""
[ -f /root/.my.cnf ] && MYSQL_PASS=$(grep "^password=" /root/.my.cnf | cut -d= -f2)

# ════════════════════════════════════════════════════════════════
step "1. PostgreSQL"
# ════════════════════════════════════════════════════════════════
if ! svc_running postgresql; then
  fail "PostgreSQL not running"
  if [ "$CHECK_ONLY" = "0" ]; then
    pkg_install postgresql >> "$LOG" 2>&1 || true
    systemctl enable --now postgresql >> "$LOG" 2>&1 || true
    sleep 3
    svc_running postgresql && fixed "PostgreSQL started" || fail "Could not start PostgreSQL"
  fi
else
  ok "PostgreSQL running"
fi

# Check nexapanel DB user + DB exist
if svc_running postgresql; then
  if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='nexapanel'" 2>/dev/null | grep -q 1; then
    ok "nexapanel DB user exists"
  else
    fail "nexapanel DB user missing"
    if [ "$CHECK_ONLY" = "0" ] && [ -n "$PANEL_DB_PASS" ]; then
      sudo -u postgres psql -c "CREATE USER nexapanel WITH ENCRYPTED PASSWORD '${PANEL_DB_PASS}';" >> "$LOG" 2>&1
      fixed "nexapanel DB user created"
    fi
  fi
  if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='nexapanel'" 2>/dev/null | grep -q 1; then
    ok "nexapanel database exists"
  else
    fail "nexapanel database missing"
    if [ "$CHECK_ONLY" = "0" ]; then
      sudo -u postgres psql -c "CREATE DATABASE nexapanel OWNER nexapanel;" >> "$LOG" 2>&1
      fixed "nexapanel database created"
    fi
  fi
  # Connection test
  if [ -n "$PANEL_DB_PASS" ]; then
    PGPASSWORD="$PANEL_DB_PASS" psql -h 127.0.0.1 -U nexapanel -d nexapanel -c "SELECT 1;" >> "$LOG" 2>&1 \
      && ok "PostgreSQL connection OK" \
      || { fail "PostgreSQL connection failed"; 
           [ "$CHECK_ONLY" = "0" ] && {
             sudo -u postgres psql -c "ALTER USER nexapanel WITH PASSWORD '${PANEL_DB_PASS}';" >> "$LOG" 2>&1
             # Fix scram vs md5
             PG_CONF=$(find /etc/postgresql -name "pg_hba.conf" 2>/dev/null | head -1)
             if [ -n "$PG_CONF" ]; then
               sed -i 's/scram-sha-256/md5/g' "$PG_CONF"
               systemctl reload postgresql >> "$LOG" 2>&1 || true
             fi
             PGPASSWORD="$PANEL_DB_PASS" psql -h 127.0.0.1 -U nexapanel -d nexapanel -c "SELECT 1;" >> "$LOG" 2>&1 \
               && fixed "PostgreSQL connection fixed" || fail "Still failing — check pg_hba.conf"
           }; }
  fi
fi

# ════════════════════════════════════════════════════════════════
step "2. MariaDB"
# ════════════════════════════════════════════════════════════════
if ! svc_running mariadb && ! svc_running mysql; then
  fail "MariaDB not running"
  if [ "$CHECK_ONLY" = "0" ]; then
    pkg_install mariadb-server >> "$LOG" 2>&1 || {
      warn "Standard install failed — trying official repo..."
      curl -fsSL https://downloads.mariadb.com/MariaDB/mariadb_repo_setup \
        | bash -s -- --mariadb-server-version="mariadb-10.11" >> "$LOG" 2>&1
      apt-get update -qq >> "$LOG" 2>&1
      pkg_install mariadb-server >> "$LOG" 2>&1
    }
    systemctl enable --now mariadb >> "$LOG" 2>&1; sleep 3
    svc_running mariadb && fixed "MariaDB installed and started" || fail "MariaDB install failed"
  fi
else
  ok "MariaDB running"
fi

if svc_running mariadb || svc_running mysql; then
  # Test root login
  MYSQL_OK=0
  mariadb -u root -e "SELECT 1;" >> "$LOG" 2>/dev/null && MYSQL_OK=1 || true
  [ "$MYSQL_OK" = "0" ] && [ -n "$MYSQL_PASS" ] && \
    mariadb -u root -p"${MYSQL_PASS}" -e "SELECT 1;" >> "$LOG" 2>/dev/null && MYSQL_OK=1 || true
  
  if [ "$MYSQL_OK" = "1" ]; then
    ok "MariaDB root login OK"
  else
    fail "MariaDB root login failed"
    if [ "$CHECK_ONLY" = "0" ] && [ -n "$MYSQL_PASS" ]; then
      # Reset root via socket in single-user mode not needed — try mysqld_safe method
      warn "Attempting password reset via skip-grant-tables..."
      systemctl stop mariadb >> "$LOG" 2>&1
      mysqld_safe --skip-grant-tables --skip-networking & sleep 5
      mysql -u root << SQLFIX >> "$LOG" 2>&1
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_PASS}';
FLUSH PRIVILEGES;
SQLFIX
      kill %1 >> "$LOG" 2>&1; sleep 2
      systemctl start mariadb >> "$LOG" 2>&1; sleep 3
      mariadb -u root -p"${MYSQL_PASS}" -e "SELECT 1;" >> "$LOG" 2>/dev/null \
        && fixed "MariaDB root password reset" || fail "MariaDB reset failed — run: mysql_secure_installation"
    fi
  fi

  # Check nexapanel_apps DB
  MYSQL_CMD=""
  mariadb -u root -e "USE nexapanel_apps;" >> "$LOG" 2>/dev/null && MYSQL_CMD="mariadb -u root" || true
  [ -z "$MYSQL_CMD" ] && [ -n "$MYSQL_PASS" ] && \
    mariadb -u root -p"${MYSQL_PASS}" -e "USE nexapanel_apps;" >> "$LOG" 2>/dev/null && MYSQL_CMD="mariadb -u root -p${MYSQL_PASS}" || true
  if [ -n "$MYSQL_CMD" ]; then
    ok "nexapanel_apps database exists"
  else
    fail "nexapanel_apps database missing or no access"
    if [ "$CHECK_ONLY" = "0" ]; then
      for CMD in "mariadb -u root" "mariadb -u root -p${MYSQL_PASS}"; do
        $CMD -e "CREATE DATABASE IF NOT EXISTS nexapanel_apps CHARACTER SET utf8mb4;" >> "$LOG" 2>/dev/null \
          && { fixed "nexapanel_apps database created"; break; } || true
      done
    fi
  fi
fi

# ════════════════════════════════════════════════════════════════
step "3. Redis"
# ════════════════════════════════════════════════════════════════
REDIS_SVC=""
systemctl is-active --quiet redis-server 2>/dev/null && REDIS_SVC="redis-server"
systemctl is-active --quiet redis        2>/dev/null && REDIS_SVC="redis"

if [ -n "$REDIS_SVC" ]; then
  ok "Redis running ($REDIS_SVC)"
else
  warn "Redis not running (optional — panel works without it)"
  if [ "$CHECK_ONLY" = "0" ]; then
    pkg_install redis-server >> "$LOG" 2>&1 || pkg_install redis >> "$LOG" 2>&1 || true
    for SVC in redis-server redis; do
      systemctl enable --now "$SVC" >> "$LOG" 2>&1 && REDIS_SVC="$SVC" && break || true
    done
    [ -n "$REDIS_SVC" ] && fixed "Redis installed and started" || warn "Redis not available (not critical)"
  fi
fi

# ════════════════════════════════════════════════════════════════
step "4. PHP & PHP-FPM"
# ════════════════════════════════════════════════════════════════
PHP_VER=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;" 2>/dev/null || echo "")
if [ -z "$PHP_VER" ]; then
  fail "PHP not installed"
  if [ "$CHECK_ONLY" = "0" ]; then
    add-apt-repository -y ppa:ondrej/php >> "$LOG" 2>&1 || true
    apt-get update -qq >> "$LOG" 2>&1
    pkg_install php8.3 php8.3-fpm php8.3-mysql php8.3-mbstring php8.3-xml php8.3-curl php8.3-zip php8.3-gd >> "$LOG" 2>&1
    PHP_VER=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;" 2>/dev/null || echo "unknown")
    [ "$PHP_VER" != "unknown" ] && fixed "PHP $PHP_VER installed" || fail "PHP install failed"
  fi
else
  ok "PHP $PHP_VER installed"
fi

PHP_FPM_SVC="php${PHP_VER}-fpm"
if svc_running "$PHP_FPM_SVC"; then
  ok "PHP-FPM running"
else
  fail "PHP-FPM not running"
  [ "$CHECK_ONLY" = "0" ] && {
    systemctl enable --now "$PHP_FPM_SVC" >> "$LOG" 2>&1 \
      && fixed "PHP-FPM started" || { pkg_install "${PHP_FPM_SVC}" >> "$LOG" 2>&1; systemctl enable --now "$PHP_FPM_SVC" >> "$LOG" 2>&1; }
  }
fi

# ════════════════════════════════════════════════════════════════
step "5. Nginx"
# ════════════════════════════════════════════════════════════════
if ! svc_running nginx; then
  fail "Nginx not running"
  if [ "$CHECK_ONLY" = "0" ]; then
    pkg_install nginx >> "$LOG" 2>&1 || { apt-get -f install -y >> "$LOG" 2>&1; pkg_install nginx >> "$LOG" 2>&1; } || true
    systemctl enable nginx >> "$LOG" 2>&1; systemctl start nginx >> "$LOG" 2>&1
    svc_running nginx && fixed "Nginx started" || fail "Nginx start failed"
  fi
else
  ok "Nginx running"
fi

# Check nginx config valid
if nginx -t >> "$LOG" 2>&1; then
  ok "Nginx config valid"
else
  fail "Nginx config invalid"
  if [ "$CHECK_ONLY" = "0" ]; then
    # Find and remove bad configs
    for conf in /etc/nginx/sites-enabled/*; do
      nginx -t >> "$LOG" 2>&1 && break
      warn "Disabling bad config: $conf"
      mv "$conf" "${conf}.broken" 2>/dev/null || true
    done
    nginx -t >> "$LOG" 2>&1 && { fixed "Bad nginx configs removed"; systemctl reload nginx >> "$LOG" 2>&1; } || fail "Nginx still broken"
  fi
fi

# Check panel vhost exists
if [ ! -f "/etc/nginx/sites-available/nexapanel.conf" ]; then
  fail "Panel nginx vhost missing"
  if [ "$CHECK_ONLY" = "0" ]; then
    SERVER_IP=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    PHP_SOCK="/run/php/php${PHP_VER}-fpm.sock"
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    cat > /etc/nginx/sites-available/nexapanel.conf << NGINX
server {
    listen 80 default_server;
    server_name ${SERVER_IP} _;
    client_max_body_size 500M;
    location ^~ /panel/assets/ {
        alias ${PANEL_DIR}/artifacts/nexapanel/dist/public/assets/;
        expires 1y; add_header Cache-Control "public, immutable"; access_log off;
    }
    location ^~ /panel/ {
        alias ${PANEL_DIR}/artifacts/nexapanel/dist/public/;
        try_files \$uri \$uri/ /panel/index.html;
    }
    location = /panel { return 301 /panel/; }
    location /api {
        proxy_pass http://127.0.0.1:${PANEL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 600s;
        client_max_body_size 500M;
    }
    location = /nexa-signon.php {
        root /var/www/html;
        fastcgi_pass unix:${PHP_SOCK};
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME /var/www/html/nexa-signon.php;
    }
    location /phpmyadmin {
        alias /var/www/phpmyadmin;
        index index.php;
        location ~ \.php$ {
            fastcgi_pass unix:${PHP_SOCK};
            include fastcgi_params;
            fastcgi_param SCRIPT_FILENAME \$request_filename;
        }
    }
    location = / { return 301 /panel; }
}
NGINX
    rm -f /etc/nginx/sites-enabled/default
    ln -sf /etc/nginx/sites-available/nexapanel.conf /etc/nginx/sites-enabled/nexapanel
    nginx -t >> "$LOG" 2>&1 && systemctl reload nginx >> "$LOG" 2>&1 && fixed "Panel nginx vhost created" || fail "New nginx config invalid"
  fi
elif ! [ -L "/etc/nginx/sites-enabled/nexapanel" ] && ! [ -f "/etc/nginx/sites-enabled/nexapanel" ]; then
  fail "Panel vhost not enabled"
  [ "$CHECK_ONLY" = "0" ] && {
    ln -sf /etc/nginx/sites-available/nexapanel.conf /etc/nginx/sites-enabled/nexapanel
    nginx -t >> "$LOG" 2>&1 && systemctl reload nginx >> "$LOG" 2>&1 && fixed "Panel vhost enabled"
  }
else
  ok "Panel nginx vhost configured"
fi

# ════════════════════════════════════════════════════════════════
step "6. NexaPanel Service"
# ════════════════════════════════════════════════════════════════
if [ ! -d "$PANEL_DIR" ]; then
  fail "Panel not installed at $PANEL_DIR"
else
  ok "Panel directory exists: $PANEL_DIR"
  # Check .env
  if [ ! -f "$PANEL_DIR/.env" ]; then
    fail ".env file missing"
  else
    ok ".env file present"
    # Check critical vars
    for VAR in DATABASE_URL PORT BASE_PATH SESSION_SECRET; do
      grep -q "^${VAR}=" "$PANEL_DIR/.env" && ok "  $VAR set" || fail "  $VAR missing in .env"
    done
  fi

  # Check systemd service
  if [ ! -f "/etc/systemd/system/${PANEL_SERVICE}.service" ]; then
    fail "Systemd service missing"
    if [ "$CHECK_ONLY" = "0" ] && [ -f "$PANEL_DIR/dist/index.cjs" ]; then
      cat > /etc/systemd/system/${PANEL_SERVICE}.service << SVCEOF
[Unit]
Description=NexaPanel API Server
After=network.target postgresql.service mariadb.service

[Service]
Type=simple
User=root
WorkingDirectory=${PANEL_DIR}
EnvironmentFile=${PANEL_DIR}/.env
ExecStart=/usr/bin/node ${PANEL_DIR}/dist/index.cjs
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF
      systemctl daemon-reload
      systemctl enable --now "$PANEL_SERVICE" >> "$LOG" 2>&1
      svc_running "$PANEL_SERVICE" && fixed "Panel service created and started" || fail "Service created but failed to start"
    fi
  elif svc_running "$PANEL_SERVICE"; then
    ok "Panel service running ✓"
  else
    fail "Panel service not running"
    [ "$CHECK_ONLY" = "0" ] && {
      systemctl daemon-reload >> "$LOG" 2>&1
      systemctl start "$PANEL_SERVICE" >> "$LOG" 2>&1
      sleep 3
      svc_running "$PANEL_SERVICE" && fixed "Panel service started" || {
        fail "Panel service still failing — last 10 lines:"
        journalctl -u "$PANEL_SERVICE" -n 10 --no-pager
      }
    }
  fi

  # Check frontend dist exists
  DIST_DIR="$PANEL_DIR/artifacts/nexapanel/dist/public"
  if [ -d "$DIST_DIR" ] && [ -f "$DIST_DIR/index.html" ]; then
    ok "Frontend dist present ($(find $DIST_DIR -type f | wc -l) files)"
    chmod -R o+rX "$PANEL_DIR/artifacts/nexapanel/dist" 2>/dev/null || true
  else
    fail "Frontend dist missing at $DIST_DIR"
    if [ "$CHECK_ONLY" = "0" ]; then
      info "Downloading frontend..."
      TARBALL_URL="https://github.com/payoro11/nexa-panel/raw/main/frontend-dist.tar.gz"
      mkdir -p "$PANEL_DIR/artifacts/nexapanel/dist"
      curl -sSfL --retry 3 "$TARBALL_URL" | tar -xz -C "$PANEL_DIR/artifacts/nexapanel/dist" \
        && fixed "Frontend downloaded" || fail "Frontend download failed"
    fi
  fi
fi

# ════════════════════════════════════════════════════════════════
step "7. Panel HTTP Endpoint"
# ════════════════════════════════════════════════════════════════
sleep 2
API_OK=0
curl -sf --connect-timeout 5 "http://127.0.0.1/api/healthz" -o /dev/null 2>/dev/null && API_OK=1 || true
if [ "$API_OK" = "1" ]; then
  ok "API responding at /api/healthz ✓"
else
  fail "API not responding on port 80"
  # Try direct backend port
  curl -sf --connect-timeout 5 "http://127.0.0.1:${PANEL_PORT}/api/healthz" -o /dev/null 2>/dev/null \
    && warn "API responds on :$PANEL_PORT but NOT via nginx (nginx proxy issue)" \
    || fail "API not responding on :$PANEL_PORT either — check panel service"
fi

FRONT_OK=0
curl -sf --connect-timeout 5 "http://127.0.0.1/panel/" -o /dev/null 2>/dev/null && FRONT_OK=1 || true
[ "$FRONT_OK" = "1" ] && ok "Frontend accessible at /panel/ ✓" || fail "Frontend not accessible at /panel/"

# ════════════════════════════════════════════════════════════════
step "8. Firewall"
# ════════════════════════════════════════════════════════════════
if command -v ufw > /dev/null; then
  UFW_STATUS=$(ufw status 2>/dev/null)
  if echo "$UFW_STATUS" | grep -q "Status: active"; then
    ok "UFW active"
    echo "$UFW_STATUS" | grep -q "80.*ALLOW\|Nginx.*ALLOW" && ok "Port 80 allowed" || {
      fail "Port 80 not in UFW rules"
      [ "$CHECK_ONLY" = "0" ] && { ufw allow 80/tcp >> "$LOG" 2>&1; ufw allow 443/tcp >> "$LOG" 2>&1; fixed "Port 80/443 opened"; }
    }
  else
    ok "UFW inactive (all ports open)"
  fi
fi

# ════════════════════════════════════════════════════════════════
step "9. SSL / Certbot"
# ════════════════════════════════════════════════════════════════
if command -v certbot > /dev/null; then
  ok "Certbot installed ($(certbot --version 2>&1 | head -1))"
else
  warn "Certbot not installed (needed for HTTPS)"
  [ "$CHECK_ONLY" = "0" ] && {
    pkg_install certbot python3-certbot-nginx >> "$LOG" 2>&1 \
      && fixed "Certbot installed" || warn "Certbot install failed (not critical)"
  }
fi

# ════════════════════════════════════════════════════════════════
step "10. Disk & Memory"
# ════════════════════════════════════════════════════════════════
DISK_USE=$(df / | awk 'NR==2{print $5}' | tr -d '%')
[ "$DISK_USE" -lt 80 ] && ok "Disk usage: ${DISK_USE}%" || warn "Disk usage high: ${DISK_USE}%"
MEM_FREE=$(free -m | awk '/^Mem/{print $4}')
[ "$MEM_FREE" -gt 200 ] && ok "Free memory: ${MEM_FREE}MB" || warn "Low free memory: ${MEM_FREE}MB — consider adding swap"

# Add swap if low memory and no swap exists
SWAP_TOTAL=$(free -m | awk '/^Swap/{print $2}')
if [ "$SWAP_TOTAL" -lt 512 ] && [ "$MEM_FREE" -lt 512 ]; then
  warn "Low RAM + no swap — this can cause OOM crashes"
  if [ "$CHECK_ONLY" = "0" ]; then
    info "Adding 1GB swap..."
    fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 >> "$LOG" 2>&1
    chmod 600 /swapfile; mkswap /swapfile >> "$LOG" 2>&1; swapon /swapfile >> "$LOG" 2>&1
    grep -q swapfile /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
    fixed "1GB swap added"
  fi
fi

# ════════════════════════════════════════════════════════════════
# SUMMARY
# ════════════════════════════════════════════════════════════════
SERVER_IP=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
echo ""
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Repair Summary${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
[ "$FIXED_COUNT"  -gt 0 ] && echo -e "${GREEN}  ✔ Fixed:    $FIXED_COUNT issues${NC}"
[ "$WARNINGS"     -gt 0 ] && echo -e "${YELLOW}  ⚠ Warnings: $WARNINGS${NC}"
[ "$FAILURES"     -gt 0 ] && echo -e "${RED}  ✗ Failures: $FAILURES${NC}"
[ "$FAILURES"     -eq 0 ] && [ "$FIXED_COUNT" -eq 0 ] && echo -e "${GREEN}  Everything looks healthy!${NC}"
echo ""
if [ "$FRONT_OK" = "1" ] && [ "$API_OK" = "1" ]; then
  echo -e "${GREEN}${BOLD}  Panel: http://${SERVER_IP}/panel${NC}"
  echo -e "  Log:   $LOG"
else
  echo -e "${YELLOW}  Access: http://${SERVER_IP}/panel (some issues remain)"
  echo -e "  Log:    $LOG"
  echo -e "  Re-run: sudo bash repair.sh"
fi
echo ""
