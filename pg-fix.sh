#!/usr/bin/env bash
# NexaPanel PostgreSQL Fix
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}checkmark${NC} $1"; }
warn() { echo -e "${YELLOW}warning${NC} $1"; }
[ "$EUID" -ne 0 ] && { echo "Run as root"; exit 1; }
PANEL_DIR="/opt/nexapanel"
DB_PASS=$(grep "^DATABASE_URL=" "$PANEL_DIR/.env" 2>/dev/null | sed 's/.*:\(.*\)@.*/\1/')
[ -z "$DB_PASS" ] && { echo "Cannot find DB password in $PANEL_DIR/.env"; exit 1; }
PG_HBA=$(find /etc/postgresql -name "pg_hba.conf" 2>/dev/null | head -1)
[ -n "$PG_HBA" ] && sed -i 's/scram-sha-256/md5/g' "$PG_HBA" && ok "pg_hba.conf fixed (scram->md5)"
systemctl restart postgresql 2>/dev/null || true; sleep 2
sudo -u postgres psql -c "ALTER USER nexapanel WITH ENCRYPTED PASSWORD '${DB_PASS}';" 2>/dev/null && ok "Password updated"
PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U nexapanel -d nexapanel -c "SELECT 1;" > /dev/null 2>&1 \
  && ok "PostgreSQL connection OK" \
  || warn "Still failing - check: journalctl -u postgresql"
