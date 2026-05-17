#!/usr/bin/env bash
# ============================================================
#   NexaPanel — Full Auto Installer
#   Supports: Ubuntu 20.04/22.04/24.04, Debian 11/12,
#             AlmaLinux 8/9, Rocky Linux 8/9,
#             CentOS Stream 8/9, RHEL 8/9
#
#   Install order:
#   1. Base tools + Node.js + PostgreSQL  → Panel starts
#   2. Panel registers MariaDB password   → zero-config DB
#   3. Nginx, PHP 8.3, MariaDB, Redis     → full PHP stack
#   4. phpMyAdmin, Certbot, UFW/firewalld → security + tools
# ============================================================
set -uo pipefail

HOSTING_URL="https://nexapanel.hostganga.com"
GITHUB_RAW="https://raw.githubusercontent.com/payoro11/nexapanel-install/main"
PANEL_URL="http://151.158.180.29"
PANEL_DIR="/opt/nexapanel"
PANEL_PORT=8080
PANEL_USER="nexapanel"
LOG="/var/log/nexapanel-install.log"
DB_PASS=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 20)
PANEL_DB_PASS=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 20)
PMA_DIR="/var/www/phpmyadmin"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $1" | tee -a "$LOG"; }
info() { echo -e "${BLUE}➜${NC} $1" | tee -a "$LOG"; }
warn() { echo -e "${YELLOW}⚠${NC} $1" | tee -a "$LOG"; }
fail() { echo -e "${RED}✗ ERROR:${NC} $1" | tee -a "$LOG"; exit 1; }
step() { echo -e "\n${BOLD}${BLUE}══ $1 ${NC}" | tee -a "$LOG"; }

# ── Root check ─────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then fail "Run as root: sudo bash install.sh"; fi

mkdir -p /var/log && touch "$LOG"

clear
printf '\033[38;5;208m'
cat << 'NEXABANNER'

  ███╗   ██╗███████╗██╗  ██╗ █████╗ ██████╗  █████╗ ███╗   ██╗███████╗██╗     
  ████╗  ██║██╔════╝╚██╗██╔╝██╔══██╗██╔══██╗██╔══██╗████╗  ██║██╔════╝██║     
  ██╔██╗ ██║█████╗   ╚███╔╝ ███████║██████╔╝███████║██╔██╗ ██║█████╗  ██║     
  ██║╚██╗██║██╔══╝   ██╔██╗ ██╔══██║██╔═══╝ ██╔══██║██║╚██╗██║██╔══╝  ██║     
  ██║ ╚████║███████╗██╔╝ ██╗██║  ██║██║     ██║  ██║██║ ╚████║███████╗███████╗
  ╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝     ╚═╝  ╚═╝╚═╝  ╚═══╝╚══════╝╚══════╝

NEXABANNER
printf '\033[0m'
printf '\033[38;5;208m  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
printf '\033[1;37m  NexaPanel Installing...\033[0m  \033[0;36mAuto-Installer v2.7\033[0m\n'
printf '\033[38;5;208m  A Brand of \033[1;37mNexaroot Technology India Pvt Ltd\033[0m  \033[38;5;208m•  Powered By \033[1;37mHOSTGANGA.COM\033[0m\n'
printf '\033[38;5;208m  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
printf '\n'

# ── OS Detection ───────────────────────────────────────────
step "Detecting OS"
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS="$ID"; VER="$VERSION_ID"; MAJOR_VER="${VERSION_ID%%.*}"
  ok "Detected: $PRETTY_NAME"
else
  fail "Cannot detect OS. Supported: Ubuntu/Debian/AlmaLinux/Rocky/CentOS/RHEL"
fi

# Determine OS family and package manager
case "$OS" in
  ubuntu|debian)
    OS_FAMILY="debian"
    PKG_MGR="apt-get"
    PKG_INSTALL="DEBIAN_FRONTEND=noninteractive apt-get install -y -qq"
    PKG_UPDATE="apt-get update -qq"
    NGINX_CONF_DIR="/etc/nginx/sites-available"
    NGINX_ENABLED_DIR="/etc/nginx/sites-enabled"
    NGINX_USE_SYMLINKS=1
    APACHE_SVC="apache2"
    PHP_FPM_SOCK="/run/php/php8.3-fpm.sock"
    PHP_FPM_SVC="php8.3-fpm"
    REDIS_SVC="redis-server"
    FIREWALL_TYPE="ufw"
    NEEDS_EPEL=0
    export DEBIAN_FRONTEND=noninteractive
    ;;
  almalinux|rocky|centos|rhel|ol|oraclelinux|fedora)
    OS_FAMILY="rhel"
    if [ "$MAJOR_VER" -le 7 ]; then
      PKG_MGR="yum"; PKG_INSTALL="yum install -y"; PKG_UPDATE="yum makecache"
    else
      PKG_MGR="dnf"; PKG_INSTALL="dnf install -y"; PKG_UPDATE="dnf makecache"
    fi
    NGINX_CONF_DIR="/etc/nginx/conf.d"
    NGINX_ENABLED_DIR="/etc/nginx/conf.d"
    NGINX_USE_SYMLINKS=0
    APACHE_SVC="httpd"
    PHP_FPM_SOCK="/run/php-fpm/www.sock"
    PHP_FPM_SVC="php-fpm"
    REDIS_SVC="redis"
    FIREWALL_TYPE="firewalld"
    NEEDS_EPEL=1
    ;;
  *)
    fail "Unsupported OS: $OS. Supported: Ubuntu, Debian, AlmaLinux, Rocky Linux, CentOS, RHEL"
    ;;
esac

ok "OS family: $OS_FAMILY | Package manager: $PKG_MGR | Firewall: $FIREWALL_TYPE"

# ════════════════════════════════════════════════════════════
# PHASE 1 — PANEL CORE (Node.js + PostgreSQL + Panel itself)
#           Panel starts FIRST so it can manage everything
# ════════════════════════════════════════════════════════════
step "Updating system packages"
$PKG_UPDATE >> "$LOG" 2>&1 && ok "Package list updated"

if [ "$OS_FAMILY" = "debian" ]; then
  $PKG_INSTALL curl wget gnupg2 ca-certificates lsb-release software-properties-common apt-transport-https unzip zip git openssl >> "$LOG" 2>&1 && ok "Base tools installed"
else
  # RHEL family — install EPEL first for extra packages
  if [ "$NEEDS_EPEL" = "1" ]; then
    $PKG_INSTALL epel-release >> "$LOG" 2>&1 && ok "EPEL repository enabled" || warn "EPEL install failed — some packages may be unavailable"
    # Enable PowerTools/CRB for RHEL 8/9
    if command -v dnf > /dev/null 2>&1; then
      dnf config-manager --set-enabled powertools >> "$LOG" 2>&1 || dnf config-manager --set-enabled crb >> "$LOG" 2>&1 || true
    fi
  fi
  $PKG_INSTALL curl wget ca-certificates unzip zip git openssl policycoreutils-python-utils >> "$LOG" 2>&1 && ok "Base tools installed"
fi

# ── Node.js 24 ─────────────────────────────────────────────
step "Installing Node.js 24"
NODE_OK=0
if command -v node > /dev/null 2>&1; then
  NODE_VER="$(node -e 'process.stdout.write(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)"
  [ "$NODE_VER" -ge 20 ] && NODE_OK=1
fi
if [ "$NODE_OK" = "0" ]; then
  if [ "$OS_FAMILY" = "debian" ]; then
    # Primary: NodeSource 24.x
    if curl -fsSL https://deb.nodesource.com/setup_24.x 2>/dev/null | bash - >> "$LOG" 2>&1 &&        $PKG_INSTALL nodejs >> "$LOG" 2>&1 && command -v node > /dev/null 2>&1; then
      ok "Node.js installed via NodeSource"
    else
      # Fallback: nvm (works on all distros including Ubuntu 24.04)
      warn "NodeSource failed — trying nvm fallback..."
      export NVM_DIR="/root/.nvm"
      curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh 2>/dev/null | bash - >> "$LOG" 2>&1 || true
      [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
      nvm install 20 >> "$LOG" 2>&1 && nvm use 20 >> "$LOG" 2>&1 && nvm alias default 20 >> "$LOG" 2>&1 || true
      # Symlink so node is available system-wide
      NODE_BIN_PATH="$(command -v node 2>/dev/null || echo '')"
      if [ -n "$NODE_BIN_PATH" ]; then
        ln -sf "$NODE_BIN_PATH" /usr/local/bin/node 2>/dev/null || true
        ln -sf "$(dirname "$NODE_BIN_PATH")/npm" /usr/local/bin/npm 2>/dev/null || true
        ok "Node.js installed via nvm"
      else
        fail "Node.js install failed — check $LOG for details"
      fi
    fi
  else
    if curl -fsSL https://rpm.nodesource.com/setup_24.x 2>/dev/null | bash - >> "$LOG" 2>&1 &&        $PKG_INSTALL nodejs >> "$LOG" 2>&1 && command -v node > /dev/null 2>&1; then
      ok "Node.js installed via NodeSource"
    else
      warn "NodeSource failed — trying nvm fallback..."
      export NVM_DIR="/root/.nvm"
      curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh 2>/dev/null | bash - >> "$LOG" 2>&1 || true
      [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
      nvm install 20 >> "$LOG" 2>&1 && nvm use 20 >> "$LOG" 2>&1 && nvm alias default 20 >> "$LOG" 2>&1 || true
      NODE_BIN_PATH="$(command -v node 2>/dev/null || echo '')"
      if [ -n "$NODE_BIN_PATH" ]; then
        ln -sf "$NODE_BIN_PATH" /usr/local/bin/node 2>/dev/null || true
        ok "Node.js installed via nvm"
      else
        fail "Node.js install failed — check $LOG for details"
      fi
    fi
  fi
fi
ok "Node.js $(node --version) installed"
npm install -g pnpm@9 >> "$LOG" 2>&1 && ok "pnpm installed"

# ── PostgreSQL (panel internal DB) ────────────────────────
step "Installing PostgreSQL (NexaPanel internal database)"
if [ "$OS_FAMILY" = "debian" ]; then
  PG_OK=0
  # Attempt 1: default apt repo
  if $PKG_INSTALL postgresql postgresql-contrib >> "$LOG" 2>&1 && command -v psql > /dev/null 2>&1; then
    PG_OK=1
    ok "PostgreSQL installed from default repo"
  fi
  # Attempt 2: official pgdg repo (new recommended method — no lsb_release needed)
  if [ "$PG_OK" = "0" ]; then
    warn "Default repo failed — trying official pgdg repo..."
    OS_CODENAME="$(. /etc/os-release && echo ${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null || echo noble)})"
    install -d /usr/share/postgresql-common/pgdg >> "$LOG" 2>&1 || true
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc       -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc >> "$LOG" 2>&1 || true
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${OS_CODENAME}-pgdg main"       > /etc/apt/sources.list.d/pgdg.list
    $PKG_UPDATE >> "$LOG" 2>&1 || true
    if $PKG_INSTALL postgresql-16 postgresql-client-16 >> "$LOG" 2>&1 && command -v psql > /dev/null 2>&1; then
      PG_OK=1
      ok "PostgreSQL 16 installed from pgdg repo"
    elif $PKG_INSTALL postgresql postgresql-contrib >> "$LOG" 2>&1 && command -v psql > /dev/null 2>&1; then
      PG_OK=1
      ok "PostgreSQL installed from pgdg repo"
    fi
  fi
  # Attempt 3: force apt with fix-broken
  if [ "$PG_OK" = "0" ]; then
    warn "pgdg also failed — trying apt fix-broken..."
    apt-get -f install -y >> "$LOG" 2>&1 || true
    apt-get install -y --fix-missing postgresql postgresql-contrib >> "$LOG" 2>&1       && command -v psql > /dev/null 2>&1 && PG_OK=1 || true
  fi
  [ "$PG_OK" = "0" ] && fail "PostgreSQL install failed. Check $LOG for details."
else
  # RHEL: PostgreSQL 15 from official repo
  $PKG_INSTALL https://download.postgresql.org/pub/repos/yum/reporpms/EL-${MAJOR_VER}-x86_64/pgdg-redhat-repo-latest.noarch.rpm >> "$LOG" 2>&1 || true
  $PKG_MGR module disable -y postgresql >> "$LOG" 2>&1 || true
  $PKG_INSTALL postgresql15-server postgresql15-contrib >> "$LOG" 2>&1 || $PKG_INSTALL postgresql-server postgresql-contrib >> "$LOG" 2>&1 || fail "PostgreSQL install failed"
  # Initialize the DB cluster if not already done
  if command -v postgresql-setup > /dev/null 2>&1; then
    postgresql-setup --initdb >> "$LOG" 2>&1 || true
  elif [ -f /usr/pgsql-15/bin/postgresql-15-setup ]; then
    /usr/pgsql-15/bin/postgresql-15-setup initdb >> "$LOG" 2>&1 || true
  fi
fi
systemctl enable --now postgresql >> "$LOG" 2>&1
sleep 3

ROLE_EXISTS=$(su - postgres -c "psql -At -c \"SELECT 1 FROM pg_roles WHERE rolname='nexapanel';\"" 2>/dev/null | tr -d '[:space:]')
[ "$ROLE_EXISTS" = "1" ] || su - postgres -c "createuser nexapanel 2>/dev/null; true" >> "$LOG" 2>&1

# Inline psql — no temp file, no permission issues
su - postgres -c "psql -c \"SET password_encryption = md5;\"" >> "$LOG" 2>&1 || true
su - postgres -c "psql -c \"ALTER USER nexapanel WITH PASSWORD \'${PANEL_DB_PASS}\';\"" >> "$LOG" 2>&1 \
  && ok "PostgreSQL user ready" \
  || warn "Could not set DB password"

su - postgres -c "createdb -O nexapanel nexapanel 2>/dev/null; true" >> "$LOG" 2>&1
# Use SQL file to avoid shell quoting issues with GRANT statements
su - postgres -c "psql -c 'GRANT ALL PRIVILEGES ON DATABASE nexapanel TO nexapanel;'" >> "$LOG" 2>&1 || true
su - postgres -c "psql -d nexapanel -c 'GRANT ALL ON SCHEMA public TO nexapanel;'" >> "$LOG" 2>&1 || true

PG_HBA=$(su - postgres -c "psql -At -c 'SHOW hba_file;'" 2>/dev/null | tr -d '[:space:]')
if [ -n "$PG_HBA" ] && [ -f "$PG_HBA" ]; then
  sed -i '/nexapanel/d' "$PG_HBA"
  # Always use md5 — scram-sha-256 causes node pg driver failures
  PG_AUTH_METHOD="md5"
  # Use a temp file to prepend lines (avoids sed delimiter conflicts with IP addresses)
  PG_HBA_TMP="${PG_HBA}.nexapanel_tmp"
  {
    printf "host    nexapanel   nexapanel   127.0.0.1/32    %s
" "$PG_AUTH_METHOD"
    printf "host    nexapanel   nexapanel   ::1/128         %s
" "$PG_AUTH_METHOD"
    printf "local   nexapanel   nexapanel                   %s
" "$PG_AUTH_METHOD"
    cat "$PG_HBA"
  } > "$PG_HBA_TMP" && mv "$PG_HBA_TMP" "$PG_HBA"
  PG_DATA_DIR=$(su - postgres -c "psql -At -c 'SHOW data_directory;'" 2>/dev/null | tr -d '[:space:]')
  [ -n "$PG_DATA_DIR" ] && su - postgres -c "pg_ctl reload -D "$PG_DATA_DIR"" >> "$LOG" 2>&1 || systemctl reload postgresql >> "$LOG" 2>&1 || true
  sleep 2
  ok "PostgreSQL pg_hba.conf updated"
fi

if PGPASSWORD="${PANEL_DB_PASS}" psql -h 127.0.0.1 -U nexapanel -d nexapanel -c 'q' >> "$LOG" 2>&1; then
  ok "PostgreSQL connection verified ✓"
else
  warn "Connection test failed — restarting PostgreSQL..."
  systemctl restart postgresql >> "$LOG" 2>&1; sleep 5
  su - postgres -c "psql -c \"SET password_encryption = md5;\"" >> "$LOG" 2>&1 || true
  su - postgres -c "psql -c \"ALTER USER nexapanel WITH PASSWORD \'${PANEL_DB_PASS}\';\"" >> "$LOG" 2>&1 || true
  sleep 2
  PGPASSWORD="${PANEL_DB_PASS}" psql -h 127.0.0.1 -U nexapanel -d nexapanel -c 'q' >> "$LOG" 2>&1 \
    && ok "PostgreSQL connection verified ✓" \
    || warn "PostgreSQL still failing — run: curl -sSL https://nexapanel.hostganga.com/pg-fix.sh | sudo bash"
fi

# ── NexaPanel Source ──────────────────────────────────────
step "Downloading NexaPanel"
useradd -r -m -d "$PANEL_DIR" -s /bin/bash "$PANEL_USER" 2>/dev/null || true
usermod -aG shadow "$PANEL_USER" 2>/dev/null || true
if [ "$OS_FAMILY" = "debian" ]; then
  $PKG_INSTALL python3-pam >> "$LOG" 2>&1 && ok "python3-pam installed" || warn "python3-pam not available"
else
  $PKG_INSTALL python3-pampy >> "$LOG" 2>&1 && ok "python3-pampy installed" || warn "PAM python bindings unavailable — shadow-group auth will be used"
fi
mkdir -p "$PANEL_DIR/artifacts/api-server/dist" "$PANEL_DIR/artifacts/nexapanel"

export PATH="/root/.nvm/versions/node/$(ls /root/.nvm/versions/node 2>/dev/null | sort -V | tail -1)/bin:/usr/local/bin:/usr/bin:$PATH"
NODE_BIN="$(command -v node || echo /usr/bin/node)"

# ── Environment config ────────────────────────────────────
step "Configuring NexaPanel environment"
SESSION_SECRET=$(openssl rand -hex 32)
ENV_FILE="$PANEL_DIR/artifacts/api-server/.env"

printf "DATABASE_URL=postgresql://nexapanel:%s@127.0.0.1:5432/nexapanel
" "${PANEL_DB_PASS}" > "$ENV_FILE"
printf "SESSION_SECRET=%s
" "${SESSION_SECRET}" >> "$ENV_FILE"
printf "MYSQL_ROOT_PASSWORD=%s
" "${DB_PASS}" >> "$ENV_FILE"
printf "PORT=%s
" "${PANEL_PORT}" >> "$ENV_FILE"
printf "NODE_ENV=production
" >> "$ENV_FILE"
chmod 600 "$ENV_FILE"
ok "Environment configured"

set -a; source "$ENV_FILE"; set +a
# ── Download pre-built backend bundle ─────────────────────
step "Downloading NexaPanel backend"
BUNDLE_TMP="/tmp/nexapanel-bundle-$$.tar.gz"
BUNDLE_OK=0
mkdir -p "$PANEL_DIR/artifacts/api-server/dist"
for _BSRC in \
  "${HOSTING_URL}/bundle.tar.gz" \
  "${GITHUB_RAW}/bundle.tar.gz" \
  "${PANEL_URL}/api/panel/bundle"; do
  info "Backend bundle: trying $_BSRC"
  _BHTTP=$(curl -fsSL --connect-timeout 30 --max-time 120 \
    -w "%{http_code}" -o "$BUNDLE_TMP" "$_BSRC" 2>> "$LOG")
  if [ "$_BHTTP" = "200" ] && [ -s "$BUNDLE_TMP" ]; then
    if echo "$_BSRC" | grep -q "\.tar\.gz"; then
      tar -xzf "$BUNDLE_TMP" -C "$PANEL_DIR/artifacts/api-server/dist" >> "$LOG" 2>&1 \
        && BUNDLE_OK=1 && ok "Backend bundle ready (from $_BSRC)" && break
      warn "Extract failed from $_BSRC"
    else
      mv "$BUNDLE_TMP" "$PANEL_DIR/artifacts/api-server/dist/index.mjs" \
        && BUNDLE_OK=1 && ok "Backend bundle ready (from $_BSRC)" && break
    fi
  fi
  warn "Failed (_BHTTP=$_BHTTP) from $_BSRC"
  rm -f "$BUNDLE_TMP"
done
rm -f "$BUNDLE_TMP"
[ "$BUNDLE_OK" = "0" ] && fail "Backend bundle download failed from all sources"


# ── Download pre-built frontend ────────────────────────────
step "Downloading NexaPanel frontend"
FE_TMP="/tmp/nexapanel-fe-$$.tar.gz"
FE_OK=0
mkdir -p "$PANEL_DIR/artifacts/nexapanel/dist"
for _FSRC in \
  "${HOSTING_URL}/frontend-dist.tar.gz" \
  "${GITHUB_RAW}/frontend-dist.tar.gz" \
  "${PANEL_URL}/api/panel/frontend-dist.tar.gz"; do
  info "Frontend: trying $_FSRC"
  _FHTTP=$(curl -fsSL --connect-timeout 30 --max-time 180 -L \
    -w "%{http_code}" -o "$FE_TMP" "$_FSRC" 2>> "$LOG")
  if [ "$_FHTTP" = "200" ] && [ -s "$FE_TMP" ]; then
    tar -xzf "$FE_TMP" -C "$PANEL_DIR/artifacts/nexapanel/dist" >> "$LOG" 2>&1 \
      && FE_OK=1 && ok "Frontend ready (from $_FSRC)" && break
    warn "Extract failed from $_FSRC"
  fi
  warn "Failed (_FHTTP=$_FHTTP) from $_FSRC"
  rm -f "$FE_TMP"
done
rm -f "$FE_TMP"
[ "$FE_OK" = "0" ] && fail "Frontend download failed from all sources — check internet connection"

# ── Install native runtime packages (cannot be bundled by esbuild) ──
step "Installing native runtime packages"
cd "$PANEL_DIR/artifacts/api-server"
npm install --prefix . ssh2 ws basic-ftp >> "$LOG" 2>&1   && ok "Native packages installed (ssh2, ws, basic-ftp)"   || warn "Native package install had issues — check pm2 logs if panel fails to start"
cd "$PANEL_DIR"

# ── DB Migrations (pure SQL, no drizzle-kit needed) ───────
step "Setting up database (tables + admin account)"

MIGRATION_SQL="/tmp/nexapanel_migrate_$$.sql"
cat > "$MIGRATION_SQL" << 'ENDSQL'
-- Users
CREATE TABLE IF NOT EXISTS users (
  id           SERIAL PRIMARY KEY,
  email        TEXT NOT NULL UNIQUE,
  name         TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  role         TEXT NOT NULL DEFAULT 'customer',
  customer_id  INTEGER,
  created_at   TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Customers
CREATE TABLE IF NOT EXISTS customers (
  id         SERIAL PRIMARY KEY,
  name       TEXT NOT NULL,
  email      TEXT NOT NULL UNIQUE,
  company    TEXT,
  phone      TEXT,
  status     TEXT NOT NULL DEFAULT 'active',
  country    TEXT,
  balance    NUMERIC(10,2) NOT NULL DEFAULT 0,
  created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Invoices
CREATE TABLE IF NOT EXISTS invoices (
  id             SERIAL PRIMARY KEY,
  customer_id    INTEGER NOT NULL,
  invoice_number TEXT NOT NULL UNIQUE,
  status         TEXT NOT NULL DEFAULT 'pending',
  amount         NUMERIC(10,2) NOT NULL,
  due_date       TEXT NOT NULL,
  paid_at        TIMESTAMP,
  items          JSONB NOT NULL DEFAULT '[]',
  created_at     TIMESTAMP NOT NULL DEFAULT NOW()
);

-- VPS servers
CREATE TABLE IF NOT EXISTS vps_servers (
  id            SERIAL PRIMARY KEY,
  vpsid         TEXT,
  customer_id   INTEGER NOT NULL,
  hostname      TEXT NOT NULL,
  ip_address    TEXT,
  plan          TEXT NOT NULL,
  cpu           INTEGER NOT NULL,
  ram_gb        INTEGER NOT NULL,
  disk_gb       INTEGER NOT NULL,
  os            TEXT NOT NULL,
  status        TEXT NOT NULL DEFAULT 'provisioning',
  monthly_price NUMERIC(10,2) NOT NULL,
  created_at    TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Settings
CREATE TABLE IF NOT EXISTS settings (
  id         SERIAL PRIMARY KEY,
  key        TEXT NOT NULL UNIQUE,
  value      TEXT NOT NULL,
  updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Outreach campaigns
CREATE TABLE IF NOT EXISTS campaigns (
  id          SERIAL PRIMARY KEY,
  name        TEXT NOT NULL,
  description TEXT,
  status      TEXT NOT NULL DEFAULT 'draft',
  tone        TEXT NOT NULL DEFAULT 'professional',
  created_at  TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Prospects
CREATE TABLE IF NOT EXISTS prospects (
  id           SERIAL PRIMARY KEY,
  first_name   TEXT NOT NULL,
  last_name    TEXT NOT NULL,
  email        TEXT NOT NULL,
  company      TEXT,
  title        TEXT,
  industry     TEXT,
  campaign_id  INTEGER,
  email_status TEXT DEFAULT 'pending',
  created_at   TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Outreach emails
CREATE TABLE IF NOT EXISTS outreach_emails (
  id          SERIAL PRIMARY KEY,
  prospect_id INTEGER NOT NULL,
  campaign_id INTEGER,
  subject     TEXT NOT NULL,
  body        TEXT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'sent',
  sent_at     TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Panel license
CREATE TABLE IF NOT EXISTS panel_license (
  id                 SERIAL PRIMARY KEY,
  license_key        TEXT,
  server_ip          TEXT,
  server_fingerprint TEXT,
  active             BOOLEAN NOT NULL DEFAULT false,
  plan               TEXT,
  expires_at         TIMESTAMP,
  activated_at       TIMESTAMP,
  updated_at         TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Panel websites
CREATE TABLE IF NOT EXISTS panel_websites (
  id            SERIAL PRIMARY KEY,
  domain        TEXT NOT NULL UNIQUE,
  status        TEXT NOT NULL DEFAULT 'active',
  php_version   TEXT NOT NULL DEFAULT '8.3',
  document_root TEXT NOT NULL,
  ssl_enabled   BOOLEAN NOT NULL DEFAULT false,
  ssl_expiry    TEXT,
  disk_usage_mb REAL NOT NULL DEFAULT 0,
  ip_address    TEXT,
  created_at    TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Panel databases
CREATE TABLE IF NOT EXISTS panel_databases (
  id            SERIAL PRIMARY KEY,
  name          TEXT NOT NULL UNIQUE,
  username      TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  size_mb       REAL NOT NULL DEFAULT 0,
  tables        INTEGER NOT NULL DEFAULT 0,
  charset       TEXT NOT NULL DEFAULT 'utf8mb4',
  collation     TEXT NOT NULL DEFAULT 'utf8mb4_unicode_ci',
  created_at    TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Panel email accounts
CREATE TABLE IF NOT EXISTS panel_email_accounts (
  id            SERIAL PRIMARY KEY,
  email         TEXT NOT NULL UNIQUE,
  domain        TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  quota_mb      INTEGER NOT NULL DEFAULT 1024,
  used_mb       INTEGER NOT NULL DEFAULT 0,
  created_at    TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Panel DNS records
CREATE TABLE IF NOT EXISTS panel_dns_records (
  id         SERIAL PRIMARY KEY,
  domain     TEXT NOT NULL,
  type       TEXT NOT NULL,
  name       TEXT NOT NULL,
  value      TEXT NOT NULL,
  ttl        INTEGER NOT NULL DEFAULT 3600,
  priority   INTEGER,
  created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Panel SSL certs
CREATE TABLE IF NOT EXISTS panel_ssl_certs (
  id         SERIAL PRIMARY KEY,
  domain     TEXT NOT NULL,
  type       TEXT NOT NULL DEFAULT 'letsencrypt',
  issuer     TEXT NOT NULL,
  issued_at  TIMESTAMP NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMP NOT NULL,
  auto_renew BOOLEAN NOT NULL DEFAULT true,
  status     TEXT NOT NULL DEFAULT 'active',
  cert_data  TEXT,
  key_data   TEXT
);

-- Panel firewall rules
CREATE TABLE IF NOT EXISTS panel_firewall_rules (
  id         SERIAL PRIMARY KEY,
  action     TEXT NOT NULL DEFAULT 'allow',
  direction  TEXT NOT NULL DEFAULT 'in',
  proto      TEXT NOT NULL DEFAULT 'tcp',
  port       TEXT NOT NULL,
  from_ip    TEXT,
  status     TEXT NOT NULL DEFAULT 'active',
  created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Panel plugins
CREATE TABLE IF NOT EXISTS panel_plugins (
  id            SERIAL PRIMARY KEY,
  plugin_id     TEXT NOT NULL UNIQUE,
  name          TEXT NOT NULL,
  description   TEXT NOT NULL,
  author        TEXT NOT NULL,
  version       TEXT NOT NULL,
  category      TEXT NOT NULL,
  price         REAL NOT NULL DEFAULT 0,
  currency      TEXT NOT NULL DEFAULT 'USD',
  rating        REAL,
  install_count INTEGER NOT NULL DEFAULT 0,
  installed     BOOLEAN NOT NULL DEFAULT false,
  enabled       BOOLEAN NOT NULL DEFAULT false,
  icon_url      TEXT,
  tags          JSONB DEFAULT '[]',
  published_at  TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Panel cron jobs
CREATE TABLE IF NOT EXISTS panel_cron_jobs (
  id         SERIAL PRIMARY KEY,
  name       TEXT NOT NULL,
  command    TEXT NOT NULL,
  schedule   TEXT NOT NULL,
  enabled    BOOLEAN NOT NULL DEFAULT true,
  last_run   TIMESTAMP,
  next_run   TIMESTAMP,
  created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Panel SSH config
CREATE TABLE IF NOT EXISTS panel_ssh_config (
  id                       SERIAL PRIMARY KEY,
  port                     INTEGER NOT NULL DEFAULT 22,
  permit_root_login        BOOLEAN NOT NULL DEFAULT false,
  password_authentication  BOOLEAN NOT NULL DEFAULT false,
  pubkey_authentication    BOOLEAN NOT NULL DEFAULT true,
  max_auth_tries           INTEGER NOT NULL DEFAULT 3,
  login_grace_time         INTEGER NOT NULL DEFAULT 60,
  authorized_keys          JSONB DEFAULT '[]',
  updated_at               TIMESTAMP NOT NULL DEFAULT NOW()
);
ENDSQL

# Self-heal PostgreSQL before migration — if connection fails, re-apply md5 and retry
if ! PGPASSWORD="${PANEL_DB_PASS}" psql -h 127.0.0.1 -U nexapanel -d nexapanel -c 'SELECT 1' >> "$LOG" 2>&1; then
  warn "DB connection failed before migration — re-applying md5 auth..."
  systemctl restart postgresql >> "$LOG" 2>&1; sleep 4
  su - postgres -c "psql -c \"SET password_encryption = md5;\"" >> "$LOG" 2>&1 || true
  su - postgres -c "psql -c \"ALTER USER nexapanel WITH PASSWORD '${PANEL_DB_PASS}';\"" >> "$LOG" 2>&1 || true
  # Re-apply pg_hba.conf md5 entries
  _PG_HBA=$(su - postgres -c "psql -At -c 'SHOW hba_file;'" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$_PG_HBA" ] && [ -f "$_PG_HBA" ]; then
    sed -i '/nexapanel/d' "$_PG_HBA"
    { echo "host nexapanel nexapanel 127.0.0.1/32 md5"; echo "host nexapanel nexapanel ::1/128 md5"; echo "local nexapanel nexapanel md5"; cat "$_PG_HBA"; } > "${_PG_HBA}.tmp" && mv "${_PG_HBA}.tmp" "$_PG_HBA"
    systemctl reload postgresql >> "$LOG" 2>&1 || true; sleep 3
  fi
  PGPASSWORD="${PANEL_DB_PASS}" psql -h 127.0.0.1 -U nexapanel -d nexapanel -c 'SELECT 1' >> "$LOG" 2>&1     && ok "PostgreSQL self-heal succeeded ✓"     || fail "PostgreSQL connection failed — check $LOG then run: curl -sSL https://nexapanel.hostganga.com/pg-fix.sh | sudo bash"
fi
PGPASSWORD="${PANEL_DB_PASS}" psql -h 127.0.0.1 -U nexapanel -d nexapanel -f "$MIGRATION_SQL" >> "$LOG" 2>&1   && ok "All database tables created"   || fail "Database migration failed — check $LOG"
rm -f "$MIGRATION_SQL"

# Grant schema privileges after table creation
PGPASSWORD="${PANEL_DB_PASS}" psql -h 127.0.0.1 -U nexapanel -d nexapanel   -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO nexapanel; GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO nexapanel;"   >> "$LOG" 2>&1 || true

# ── Seed all data directly into PostgreSQL (before panel starts) ───────────────
# MariaDB password, admin user, license — all seeded via psql (no API call needed)

# 1. MariaDB root password → settings table
MYSQL_SEED_SQL="/tmp/nexapanel_mysql_seed_$$.sql"
printf "INSERT INTO settings (key, value) VALUES ('mysql_root_password', '%s') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
" "${DB_PASS}" > "$MYSQL_SEED_SQL"
PGPASSWORD="${PANEL_DB_PASS}" psql -h 127.0.0.1 -U nexapanel -d nexapanel -f "$MYSQL_SEED_SQL" >> "$LOG" 2>&1   && ok "MariaDB root password seeded into panel DB (zero-config DB access)"   || warn "MariaDB password seed failed — will retry after panel starts"
rm -f "$MYSQL_SEED_SQL"

# 2. Admin user — sha256("admin123salt_saas_2025")
ADMIN_HASH=$("$NODE_BIN" -e "const c=require('crypto');console.log(c.createHash('sha256').update('admin123salt_saas_2025').digest('hex'))" 2>/dev/null || echo "d0d1135e24161486ca442f07e9cc1d840485ad67426a2d292badae9ea09524a2")
SEED_SQL="/tmp/nexapanel_seed_$$.sql"
printf "INSERT INTO users (email, name, password_hash, role) VALUES ('admin@example.com', 'Administrator', '%s', 'admin') ON CONFLICT (email) DO UPDATE SET password_hash = EXCLUDED.password_hash, role = 'admin';
" "${ADMIN_HASH}" > "$SEED_SQL"
PGPASSWORD="${PANEL_DB_PASS}" psql -h 127.0.0.1 -U nexapanel -d nexapanel -f "$SEED_SQL" >> "$LOG" 2>&1   && ok "Admin account ready (admin@example.com / admin123)"   || warn "Admin seed failed — check $LOG"
rm -f "$SEED_SQL"

# 3. Auto-request demo license from nexapanel.hostganga.com portal
SERVER_IP_NOW=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
ok "Server IP detected: ${SERVER_IP_NOW}"

# ════════════════════════════════════════════════════════════
# PHASE 2 — START PANEL SERVICE
#           Panel starts NOW (PostgreSQL + passwords ready)
# ════════════════════════════════════════════════════════════
step "Starting NexaPanel service"
cat > /etc/systemd/system/nexapanel.service << SERVICE
[Unit]
Description=NexaPanel Control Panel
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=root
WorkingDirectory=${PANEL_DIR}/artifacts/api-server
EnvironmentFile=${PANEL_DIR}/artifacts/api-server/.env
ExecStart=${NODE_BIN} dist/index.mjs
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=nexapanel

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload >> "$LOG" 2>&1
systemctl enable nexapanel >> "$LOG" 2>&1
systemctl start nexapanel >> "$LOG" 2>&1

# Wait for panel to be ready (up to 30s)
PANEL_READY=0
for i in $(seq 1 10); do
  sleep 3
  if curl -sf --connect-timeout 3 "http://127.0.0.1:${PANEL_PORT}/api/healthz" > /dev/null 2>&1; then
    ok "NexaPanel API is responding ✓ (took $((i*3))s)"
    PANEL_READY=1
    break
  fi
done
if [ "$PANEL_READY" = "0" ]; then
  warn "Panel not responding yet — checking service status..."
  systemctl is-active --quiet nexapanel && info "Service is running (may need more time)" || {
    journalctl -u nexapanel -n 20 --no-pager | tee -a "$LOG"
  }
fi

# Auto-request trial license from hostganga.com (via Node.js API on nexapanel.hostganga.com)
step "Requesting trial license from hostganga.com..."
DEMO_RESP=$(curl -s --connect-timeout 15 --max-time 30   -X POST https://nexapanel.hostganga.com/api/panel/license/public/generate   -H "Content-Type: application/json"   -d "{"server_ip":"${SERVER_IP_NOW}","edition":"demo_web","hostname":"$(hostname)","os":"${OS_FAMILY:-linux}"}"   2>/dev/null || echo '{}')
DEMO_KEY=$(echo "$DEMO_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('license_key',''))" 2>/dev/null || echo "")
if [ -n "$DEMO_KEY" ]; then
  # Retry activation up to 5 times (panel may still be warming up)
  ACT_OK=""
  for _try in 1 2 3 4 5; do
    sleep 4
    # Step 1: get admin token
    ADMIN_TOKEN=$(curl -s --connect-timeout 8 --max-time 12       -X POST "http://127.0.0.1:${PANEL_PORT}/api/panel/auth/login"       -H "Content-Type: application/json"       -d '{"email":"admin@example.com","password":"admin123"}'       2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || echo "")
    [ -z "$ADMIN_TOKEN" ] && continue
    # Step 2: activate with auth header + serverIp
    ACT_RESP=$(curl -s --connect-timeout 10 --max-time 20       -X POST "http://127.0.0.1:${PANEL_PORT}/api/panel/license"       -H "Content-Type: application/json"       -H "Authorization: Bearer ${ADMIN_TOKEN}"       -d "{"licenseKey":"${DEMO_KEY}","serverIp":"${SERVER_IP_NOW}"}" 2>/dev/null || echo '{}')
    ACT_OK=$(echo "$ACT_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print('ok' if d.get('active') else '')" 2>/dev/null || echo "")
    [ "$ACT_OK" = "ok" ] && break
  done
  if [ "$ACT_OK" = "ok" ]; then
    ok "Trial license activated: ${DEMO_KEY}"
    ok "15-day trial started — upgrade at nexapanel.hostganga.com"
  else
    warn "Auto-activation failed — key saved: ${DEMO_KEY}"
    warn "Enter key manually: Panel → License → Activate License Key"
  fi
else
  # Fallback: try local public/generate endpoint directly
  DEMO_RESP2=$(curl -s --connect-timeout 8 --max-time 15     -X POST "http://127.0.0.1:${PANEL_PORT}/api/panel/license/public/generate"     -H "Content-Type: application/json"     -d "{"server_ip":"${SERVER_IP_NOW}","edition":"demo_web"}"     2>/dev/null || echo '{}')
  DEMO_KEY2=$(echo "$DEMO_RESP2" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('license_key',''))" 2>/dev/null || echo "")
  if [ -n "$DEMO_KEY2" ]; then
    # Activate via public endpoint (no auth needed)
    curl -s --connect-timeout 10 --max-time 20       -X POST "http://127.0.0.1:${PANEL_PORT}/api/panel/license/public/activate"       -H "Content-Type: application/json"       -d "{"license_key":"${DEMO_KEY2}","server_ip":"${SERVER_IP_NOW}"}" > /dev/null 2>&1
    ok "Trial license activated (local): ${DEMO_KEY2}"
  else
    warn "Could not get trial license — activate manually at nexapanel.hostganga.com"
  fi
fi

# ════════════════════════════════════════════════════════════
# PHASE 3 — PHP STACK (MariaDB, PHP 8.3, Nginx, Redis)
#           Now that panel is up, install the web server stack
# ════════════════════════════════════════════════════════════
step "Installing Nginx"
NGINX_OK=0
$PKG_INSTALL nginx >> "$LOG" 2>&1 && NGINX_OK=1 || true
if [ "$NGINX_OK" = "0" ]; then
  warn "Nginx install failed — retrying with fix-broken..."
  apt-get -f install -y >> "$LOG" 2>&1 || true
  apt-get install -y --fix-missing nginx >> "$LOG" 2>&1 && NGINX_OK=1 || true
fi
if [ "$NGINX_OK" = "0" ]; then
  warn "Apt nginx failed — trying snap nginx..."
  snap install nginx >> "$LOG" 2>&1 && NGINX_OK=1 || true
fi
[ "$NGINX_OK" = "1" ] && ok "Nginx installed" || warn "Nginx install still failing — will configure manually"
systemctl enable nginx >> "$LOG" 2>&1 || true
systemctl start nginx >> "$LOG" 2>&1 || true

step "Installing PHP 8.3 + extensions"
if [ "$OS_FAMILY" = "debian" ]; then
  if ! apt-cache show php8.3 > /dev/null 2>&1; then
    info "Adding ondrej/php PPA for PHP 8.3..."
    add-apt-repository -y ppa:ondrej/php >> "$LOG" 2>&1 || {
      curl -sSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/php.gpg >> "$LOG" 2>&1
      echo "deb https://packages.sury.org/php/ $(lsb_release -cs) main" > /etc/apt/sources.list.d/php.list
    }
    $PKG_UPDATE >> "$LOG" 2>&1
  fi
  PHP_PKGS="php8.3 php8.3-fpm php8.3-mysql php8.3-pgsql php8.3-curl php8.3-gd php8.3-mbstring php8.3-xml php8.3-zip php8.3-bcmath php8.3-intl php8.3-soap php8.3-opcache php8.3-cli php8.3-common php8.3-sqlite3"
  $PKG_INSTALL $PHP_PKGS >> "$LOG" 2>&1 || warn "Some PHP extensions may not be available"
  systemctl enable --now php8.3-fpm >> "$LOG" 2>&1
else
  # RHEL family: use Remi repository for PHP 8.3
  if [ "$MAJOR_VER" -ge 8 ]; then
    $PKG_INSTALL https://rpms.remirepo.net/enterprise/remi-release-${MAJOR_VER}.rpm >> "$LOG" 2>&1 || true
  fi
  # Enable Remi PHP 8.3 module stream
  $PKG_MGR module enable -y php:remi-8.3 >> "$LOG" 2>&1 || true
  PHP_PKGS="php php-fpm php-mysqlnd php-pgsql php-curl php-gd php-mbstring php-xml php-zip php-bcmath php-intl php-soap php-opcache php-cli php-common"
  $PKG_INSTALL $PHP_PKGS >> "$LOG" 2>&1 || warn "Some PHP extensions may not be available"
  systemctl enable --now php-fpm >> "$LOG" 2>&1
  # On RHEL, www-data is www, set socket permissions
  sed -i 's/^user = apache/user = nginx/' /etc/php-fpm.d/www.conf 2>/dev/null || true
  sed -i 's/^group = apache/group = nginx/' /etc/php-fpm.d/www.conf 2>/dev/null || true
  sed -i 's|^listen.owner = nobody|listen.owner = nginx|' /etc/php-fpm.d/www.conf 2>/dev/null || true
  sed -i 's|^listen.group = nobody|listen.group = nginx|' /etc/php-fpm.d/www.conf 2>/dev/null || true
fi
ok "PHP 8.3 + extensions installed"

step "Installing MariaDB"
# Wait for any apt lock to clear (other processes may be updating)
_LOCK_WAIT=0
while fuser /var/lib/dpkg/lock-frontend > /dev/null 2>&1 || fuser /var/lib/apt/lists/lock > /dev/null 2>&1; do
  _LOCK_WAIT=$((_LOCK_WAIT+1))
  [ "$_LOCK_WAIT" -gt 30 ] && break
  info "Waiting for apt lock... (${_LOCK_WAIT}s)"
  sleep 2
done

MARIADB_OK=0
# Attempt 1: default repo
$PKG_INSTALL mariadb-server >> "$LOG" 2>&1 && MARIADB_OK=1 || true

# Attempt 2: add official MariaDB repo
if [ "$MARIADB_OK" = "0" ] && [ "$OS_FAMILY" = "debian" ]; then
  warn "Default MariaDB failed — adding official MariaDB 10.11 repo..."
  apt-get install -y apt-transport-https curl gnupg >> "$LOG" 2>&1 || true
  curl -fsSL https://downloads.mariadb.com/MariaDB/mariadb_repo_setup     | bash -s -- --mariadb-server-version="mariadb-10.11" >> "$LOG" 2>&1 || true
  apt-get update -qq >> "$LOG" 2>&1 || true
  apt-get install -y mariadb-server >> "$LOG" 2>&1 && MARIADB_OK=1 || true
fi

# Attempt 3: fix-broken
if [ "$MARIADB_OK" = "0" ]; then
  warn "Retrying with apt fix-broken..."
  apt-get -f install -y >> "$LOG" 2>&1 || true
  apt-get install -y --fix-missing mariadb-server >> "$LOG" 2>&1 && MARIADB_OK=1 || true
fi

[ "$MARIADB_OK" = "1" ] && ok "MariaDB installed" || warn "MariaDB package install had issues — trying to start anyway"
systemctl enable mariadb >> "$LOG" 2>&1 || true
systemctl start mariadb  >> "$LOG" 2>&1 || true
sleep 4

# Secure MariaDB — try unix_socket first (default on fresh install), then password
MYSQL_CMD=""
if mariadb -u root -e "SELECT 1;" >> "$LOG" 2>&1 2>/dev/null; then
  MYSQL_CMD="mariadb -u root"
elif mysql -u root -e "SELECT 1;" >> "$LOG" 2>&1 2>/dev/null; then
  MYSQL_CMD="mysql -u root"
fi

if [ -n "$MYSQL_CMD" ]; then
  $MYSQL_CMD >> "$LOG" 2>&1 << MYSQLEOF
UPDATE mysql.global_priv SET priv=json_set(priv,'$.plugin','mysql_native_password','$.authentication_string',PASSWORD('${DB_PASS}')) WHERE User='root' AND Host='localhost';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.global_priv WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
CREATE DATABASE IF NOT EXISTS nexapanel_apps CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
FLUSH PRIVILEGES;
MYSQLEOF
  ok "MariaDB secured ✓"
else
  warn "Could not connect to MariaDB via socket — trying password auth..."
  mysql -u root -p"${DB_PASS}" -e "SELECT 1;" >> "$LOG" 2>&1     && ok "MariaDB already secured ✓"     || warn "MariaDB secure step skipped — run: mysql_secure_installation"
fi

# Write .my.cnf for root convenience
printf "[client]
password=%s
" "${DB_PASS}" > /root/.my.cnf
chmod 600 /root/.my.cnf

systemctl restart mariadb >> "$LOG" 2>&1 || true; sleep 2
ok "MariaDB installed and secured"

# Verify connectivity
if mysql -u root -p"${DB_PASS}" -e "SELECT 1;" >> "$LOG" 2>&1 2>/dev/null    || mariadb -u root -p"${DB_PASS}" -e "SELECT 1;" >> "$LOG" 2>&1 2>/dev/null; then
  ok "MariaDB root login verified ✓"
  PGPASSWORD="${PANEL_DB_PASS}" psql -h 127.0.0.1 -U nexapanel -d nexapanel     -c "INSERT INTO settings (key, value) VALUES ('mysql_root_password', '${DB_PASS}') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();"     >> "$LOG" 2>&1 && ok "MariaDB password confirmed in panel DB ✓" || warn "Password re-seed failed"
else
  warn "MariaDB root login check failed — password is in /root/.my.cnf"
fi

step "Installing Redis"
REDIS_OK=0
if [ "$OS_FAMILY" = "debian" ]; then
  $PKG_INSTALL redis-server >> "$LOG" 2>&1 && REDIS_OK=1 || true
  if [ "$REDIS_OK" = "0" ]; then
    apt-get -f install -y >> "$LOG" 2>&1 || true
    apt-get install -y --fix-missing redis-server >> "$LOG" 2>&1 && REDIS_OK=1 || true
  fi
else
  $PKG_INSTALL redis >> "$LOG" 2>&1 && REDIS_OK=1 || true
  if [ "$REDIS_OK" = "0" ]; then
    $PKG_INSTALL redis6 redis7 >> "$LOG" 2>&1 && REDIS_OK=1 || true
  fi
fi
if [ "$REDIS_OK" = "1" ]; then
  systemctl enable --now "$REDIS_SVC" >> "$LOG" 2>&1 && ok "Redis installed and started ✓" || warn "Redis installed but start failed"
else
  warn "Redis install failed — panel works without Redis (optional cache)"
fi

# ════════════════════════════════════════════════════════════
# PHASE 4 — phpMyAdmin, Certbot, UFW, Fail2ban
# ════════════════════════════════════════════════════════════
step "Installing phpMyAdmin"
PMA_VERSION="5.2.1"
PMA_URL="https://files.phpmyadmin.net/phpMyAdmin/${PMA_VERSION}/phpMyAdmin-${PMA_VERSION}-all-languages.tar.gz"
mkdir -p "$PMA_DIR"
if curl -sSL "$PMA_URL" | tar -xz -C "$PMA_DIR" --strip-components=1 >> "$LOG" 2>&1; then
  cp "$PMA_DIR/config.sample.inc.php" "$PMA_DIR/config.inc.php"
  BLOWFISH=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9!@#$%^&*' | head -c 32)
  sed -i "s/\$cfg\['blowfish_secret'\] = ''/\$cfg['blowfish_secret'] = '${BLOWFISH}'/" "$PMA_DIR/config.inc.php"
  printf "\$cfg['Servers'][\$i]['auth_type'] = 'signon';
\$cfg['Servers'][\$i]['SignonSession'] = 'SignonSession';
\$cfg['Servers'][\$i]['SignonURL'] = '/nexa-signon.php';
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;
" >> "$PMA_DIR/config.inc.php"
  chown -R www-data:www-data "$PMA_DIR"; chmod -R 755 "$PMA_DIR"
  ok "phpMyAdmin installed with signon auth"
else
  warn "phpMyAdmin download failed — install manually: apt install phpmyadmin -y"
fi

step "Creating phpMyAdmin auto-login bridge script"
mkdir -p /var/www/html
cat > /var/www/html/nexa-signon.php << 'SIGNONPHP'
<?php
// NexaPanel phpMyAdmin Auto-Login Bridge v2
// Reads panel port dynamically from /opt/nexapanel/.env
$token = $_GET['token'] ?? '';
$db    = $_GET['db']    ?? '';

if (empty($token)) {
    http_response_code(400);
    echo '<p style="font-family:sans-serif;color:red">No token provided. Please try again from NexaPanel.</p>';
    exit;
}

// Read panel port from .env (fallback 8080)
$port = 8080;
$envFile = '/opt/nexapanel/.env';
if (file_exists($envFile)) {
    foreach (file($envFile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
        if (preg_match('/^PORT=(d+)/', $line, $m)) { $port = (int)$m[1]; break; }
    }
}

// Fetch credentials from panel API directly (localhost, no nginx, no auth)
$url = 'http://127.0.0.1:' . $port . '/api/panel/databases/signon/' . rawurlencode($token);
$ch  = curl_init($url);
curl_setopt_array($ch, [
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_TIMEOUT        => 8,
    CURLOPT_CONNECTTIMEOUT => 5,
    CURLOPT_FOLLOWLOCATION => false,
]);
$response = curl_exec($ch);
$httpCode  = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
$curlError = curl_error($ch);
curl_close($ch);

if ($curlError || $httpCode !== 200 || !$response) {
    http_response_code(502);
    echo '<div style="font-family:sans-serif;padding:20px">';
    echo '<h3 style="color:red">phpMyAdmin Auto-Login Failed</h3>';
    if ($curlError) echo '<p>Connection error: ' . htmlspecialchars($curlError) . '</p>';
    elseif ($httpCode === 404) echo '<p>Token expired or already used — please click the Auto-Login button again.</p>';
    else echo '<p>Panel API returned HTTP ' . $httpCode . ' on port ' . $port . '.</p>';
    echo '<p><a href="javascript:window.close()">Close this tab</a> and click the phpMyAdmin button again in NexaPanel.</p>';
    echo '</div>';
    exit;
}

$data = json_decode($response, true);
if (!$data || empty($data['username'])) {
    http_response_code(500);
    echo '<p style="font-family:sans-serif;color:red">Credential decode error. Contact your administrator.</p>';
    exit;
}

// Destroy any existing SignonSession first to avoid stale credential conflicts
session_name('SignonSession');
if (session_status() === PHP_SESSION_NONE) session_start();
session_destroy();

// Start fresh and write new credentials
session_name('SignonSession');
session_start();
$_SESSION['PMA_single_signon_user']     = $data['username'];
$_SESSION['PMA_single_signon_password'] = $data['password'];
$_SESSION['PMA_single_signon_host']     = '127.0.0.1';
$_SESSION['PMA_single_signon_port']     = '3306';
session_write_close();

$targetDb = !empty($db) ? $db : ($data['db'] ?? '');
$redirect = '/phpmyadmin/' . ($targetDb ? '?db=' . rawurlencode($targetDb) : '');
header('Location: ' . $redirect);
exit;
SIGNONPHP
chown www-data:www-data /var/www/html/nexa-signon.php
chmod 644 /var/www/html/nexa-signon.php
ok "nexa-signon.php created"

step "Installing Certbot"
if [ "$OS_FAMILY" = "debian" ]; then
  $PKG_INSTALL certbot python3-certbot-nginx >> "$LOG" 2>&1 && ok "Certbot installed" || warn "Certbot install failed"
else
  # RHEL: Certbot via snap or EPEL
  if command -v snap > /dev/null 2>&1; then
    snap install --classic certbot >> "$LOG" 2>&1 && ln -sf /snap/bin/certbot /usr/bin/certbot 2>/dev/null && ok "Certbot installed via snap"
  else
    $PKG_INSTALL certbot python3-certbot-nginx >> "$LOG" 2>&1 && ok "Certbot installed" || warn "Certbot install failed — install manually after setup"
  fi
fi

step "Configuring Firewall ($FIREWALL_TYPE)"
if [ "$FIREWALL_TYPE" = "ufw" ]; then
  $PKG_INSTALL ufw >> "$LOG" 2>&1
  ufw --force reset >> "$LOG" 2>&1
  ufw default deny incoming >> "$LOG" 2>&1
  ufw default allow outgoing >> "$LOG" 2>&1
  ufw allow 22/tcp comment 'SSH' >> "$LOG" 2>&1
  ufw allow 80/tcp comment 'HTTP' >> "$LOG" 2>&1
  ufw allow 443/tcp comment 'HTTPS' >> "$LOG" 2>&1
  ufw allow ${PANEL_PORT}/tcp comment 'NexaPanel' >> "$LOG" 2>&1
  echo "y" | ufw enable >> "$LOG" 2>&1
  ok "UFW configured (ports 22, 80, 443, ${PANEL_PORT} open)"
else
  # firewalld on RHEL
  $PKG_INSTALL firewalld >> "$LOG" 2>&1
  systemctl enable --now firewalld >> "$LOG" 2>&1
  firewall-cmd --permanent --add-service=ssh >> "$LOG" 2>&1
  firewall-cmd --permanent --add-service=http >> "$LOG" 2>&1
  firewall-cmd --permanent --add-service=https >> "$LOG" 2>&1
  firewall-cmd --permanent --add-port=${PANEL_PORT}/tcp >> "$LOG" 2>&1
  firewall-cmd --reload >> "$LOG" 2>&1
  ok "firewalld configured (SSH, HTTP, HTTPS, port ${PANEL_PORT} open)"
fi

step "Installing Fail2ban"
if [ "$NEEDS_EPEL" = "1" ]; then
  $PKG_MGR install -y epel-release >> "$LOG" 2>&1 || true
fi
$PKG_INSTALL fail2ban >> "$LOG" 2>&1
mkdir -p /etc/fail2ban
cat > /etc/fail2ban/jail.local << 'F2B'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
[sshd]
enabled = true
port    = ssh
logpath = %(sshd_log)s
backend = %(syslog_backend)s
[nginx-http-auth]
enabled = true
F2B
systemctl enable --now fail2ban >> "$LOG" 2>&1 && ok "Fail2ban configured"

# ════════════════════════════════════════════════════════════
# PHASE 5 — NGINX CONFIG + FILE PERMISSIONS
# ════════════════════════════════════════════════════════════
step "Configuring Nginx reverse proxy"
SERVER_IP=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

# Ensure nginx config dirs and webroot exist (nginx may have partially installed)
mkdir -p "$NGINX_CONF_DIR" "$NGINX_ENABLED_DIR" 2>/dev/null || true
NGINX_WEBROOT="/var/www/html"
mkdir -p "$NGINX_WEBROOT"
if [ "$OS_FAMILY" = "rhel" ]; then
  chown -R nginx:nginx "$NGINX_WEBROOT" 2>/dev/null || true
fi

NGINX_VHOST_FILE="${NGINX_CONF_DIR}/nexapanel.conf"

cat > "$NGINX_VHOST_FILE" << NGINX
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${SERVER_IP} _;
    client_max_body_size 500M;

    # Panel assets: content-hashed filenames → cache forever
    location ^~ /panel/assets/ {
        alias ${PANEL_DIR}/artifacts/nexapanel/dist/public/assets/;
        expires 1y;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    # Panel SPA: index.html must NEVER be cached (stale hashes cause white page)
    location ^~ /panel/ {
        alias ${PANEL_DIR}/artifacts/nexapanel/dist/public/;
        try_files \$uri \$uri/ /panel/index.html;
        expires -1;
        add_header Cache-Control "no-store, no-cache, must-revalidate, proxy-revalidate";
        add_header Pragma "no-cache";
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
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 600s;
        proxy_connect_timeout 30s;
        client_max_body_size 500M;
    }

    location = /nexa-signon.php {
        root ${NGINX_WEBROOT};
        fastcgi_pass unix:${PHP_FPM_SOCK};
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME ${NGINX_WEBROOT}/nexa-signon.php;
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

chmod o+x /opt /opt/nexapanel 2>/dev/null || true
find "${PANEL_DIR}/artifacts/nexapanel/dist" -type d -exec chmod o+rx {} ; 2>/dev/null || true
find "${PANEL_DIR}/artifacts/nexapanel/dist" -type f -exec chmod o+r {} ; 2>/dev/null || true

# Debian: enable via symlink; RHEL: already in conf.d, remove default if any
if [ "$NGINX_USE_SYMLINKS" = "1" ]; then
  rm -f /etc/nginx/sites-enabled/default
  ln -sf "$NGINX_VHOST_FILE" "${NGINX_ENABLED_DIR}/nexapanel"
else
  # On RHEL, disable the default server block from the main nginx.conf
  sed -i 's|^s*include /etc/nginx/default.d/*.conf;||g' /etc/nginx/nginx.conf 2>/dev/null || true
fi

# Apply SELinux context on RHEL so nginx can access panel files
if command -v restorecon > /dev/null 2>&1; then
  restorecon -R "${PANEL_DIR}" 2>/dev/null || true
  # Allow nginx to make network connections (for proxy_pass)
  setsebool -P httpd_can_network_connect 1 >> "$LOG" 2>&1 || true
fi

# Ensure nginx is running before test
systemctl start nginx >> "$LOG" 2>&1 || true
sleep 2
if nginx -t >> "$LOG" 2>&1; then
  systemctl reload nginx >> "$LOG" 2>&1 || systemctl restart nginx >> "$LOG" 2>&1 || true
  ok "Nginx configured ✓"
else
  warn "Nginx config test failed — check: nginx -t"
fi

step "Setting file permissions"
chown -R "$PANEL_USER:$PANEL_USER" "$PANEL_DIR" 2>/dev/null || true
# Web user differs by distro: www-data (Debian) or nginx (RHEL)
WEB_USER="$([ "$OS_FAMILY" = "rhel" ] && echo 'nginx' || echo 'www-data')"
mkdir -p /var/www/html && chown -R "$WEB_USER:$WEB_USER" /var/www
cat > /var/www/html/index.php << 'PHPINFO'
<?php echo "<h1>NexaPanel Ready</h1><p>Your server is configured!</p>"; phpinfo();
PHPINFO
chown "$WEB_USER:$WEB_USER" /var/www/html/index.php 2>/dev/null || true
ok "Permissions set, default web directory ready ($WEB_USER)"

# ════════════════════════════════════════════════════════════
# FINAL — Verify panel + print credentials
# ════════════════════════════════════════════════════════════
step "Final verification"

# Verify panel API health
if curl -sf --connect-timeout 5 "http://127.0.0.1:${PANEL_PORT}/api/healthz" > /dev/null 2>&1; then
  ok "Panel API healthy ✓"
else
  warn "Panel API not responding — check: journalctl -u nexapanel -n 30"
fi

# Verify MariaDB password is saved in panel DB
DB_CHECK=$(PGPASSWORD="${PANEL_DB_PASS}" psql -h 127.0.0.1 -U nexapanel -d nexapanel -At -c "SELECT value FROM settings WHERE key='mysql_root_password';" 2>/dev/null | tr -d '[:space:]')
if [ -n "$DB_CHECK" ]; then
  ok "MariaDB password confirmed in panel DB ✓ (panel can access MySQL without any config)"
else
  warn "MariaDB password not found in panel DB — seeding again..."
  FINAL_SEED="/tmp/nexapanel_final_seed_$$.sql"
  printf "INSERT INTO settings (key, value) VALUES ('mysql_root_password', '%s') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
" "${DB_PASS}" > "$FINAL_SEED"
  PGPASSWORD="${PANEL_DB_PASS}" psql -h 127.0.0.1 -U nexapanel -d nexapanel -f "$FINAL_SEED" >> "$LOG" 2>&1     && ok "MariaDB password seeded on final attempt ✓" || warn "Seed failed — update manually in Panel → Databases"
  rm -f "$FINAL_SEED"
fi

# ── Save credentials ──────────────────────────────────────
CRED_FILE="/root/nexapanel-credentials.txt"
cat > "$CRED_FILE" << CREDS
╔══════════════════════════════════════════════════════════════╗
║          NexaPanel Installation Complete!                    ║
╚══════════════════════════════════════════════════════════════╝

  Server IP:       ${SERVER_IP}

  NexaPanel URL:   http://${SERVER_IP}/panel
  Login:           admin@example.com
  Password:        admin123

  phpMyAdmin URL:  http://${SERVER_IP}/phpmyadmin
  MySQL root:      root / ${DB_PASS}

  PostgreSQL (internal):
    Host: 127.0.0.1  DB: nexapanel  User: nexapanel
    Pass: ${PANEL_DB_PASS}

  MariaDB root password: ${DB_PASS}
  (saved in /root/.my.cnf AND panel DB — zero config needed)

  Panel files: ${PANEL_DIR}
  Install log: ${LOG}
  Service:     systemctl status nexapanel

  ── Maintenance commands ────────────────────────────────────────
  Repair      :  nexapanel-repair
  Repair+Update:  nexapanel-repair --update
  Update only :  nexapanel-repair --update-only
  ──────────────────────────────────────────────────────────────

  IMPORTANT: Change panel password after first login!
CREDS
chmod 600 "$CRED_FILE"

# ── Install nexapanel-repair as a local command ──────────────────
step "Installing nexapanel-repair command"
REPAIR_LOCAL="/usr/local/bin/nexapanel-repair"
cat > "$REPAIR_LOCAL" << 'REPEOF'
#!/bin/bash
SELF_IP=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
exec curl -sL "http://${SELF_IP}/api/panel/repair.sh" | sudo bash -s -- "$@"
REPEOF
chmod +x "$REPAIR_LOCAL"
ok "nexapanel-repair installed — run: nexapanel-repair [--update]"

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║       NexaPanel Installation Complete!                       ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Panel:${NC}      http://${SERVER_IP}/panel"
echo -e "  Login:       admin@example.com / admin123"
echo ""
echo -e "  ${BOLD}phpMyAdmin:${NC} http://${SERVER_IP}/phpmyadmin"
echo -e "  MySQL root:  root / ${DB_PASS}"
echo ""
echo -e "  ${BOLD}Credentials:${NC} ${CRED_FILE}"
echo ""
echo -e "${YELLOW}  Change panel password after first login!${NC}"
echo ""
echo -e "  ${BOLD}Maintenance:${NC}"
echo -e "    nexapanel-repair                 # Check + repair all services"
echo -e "    nexapanel-repair --update        # Repair + update to latest"
echo -e "    nexapanel-repair --update-only   # Update bundle only"
echo -e "    systemctl status nexapanel       # Panel service status"
echo ""
echo -e "Service status:"
echo -e "  nexapanel:  $(systemctl is-active nexapanel)"
echo -e "  nginx:      $(systemctl is-active nginx)"
echo -e "  php8.3-fpm: $(systemctl is-active php8.3-fpm 2>/dev/null || echo 'not installed yet')"
echo -e "  mariadb:    $(systemctl is-active mariadb 2>/dev/null || echo 'not installed yet')"
echo -e "  postgresql: $(systemctl is-active postgresql)"
echo -e "  redis:      $(systemctl is-active redis-server 2>/dev/null || echo 'not installed yet')"
echo ""
