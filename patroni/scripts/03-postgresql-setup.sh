#!/bin/bash
# =============================================================================
# Script: 03-postgresql-setup.sh
# Description: Step 3 - Install PostgreSQL on all three nodes
# Run this script on: NODE1, NODE2, NODE3
# NOTE: Patroni will manage cluster initialization - DO NOT run initdb manually.
# =============================================================================

set -euo pipefail

# ---- CONFIGURATION ----
PG_VERSION="15"
PGDATA="/var/lib/pgsql/${PG_VERSION}/data"
PG_LOG_DIR="/var/log/postgresql"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "=== Step 3: PostgreSQL ${PG_VERSION} Installation ==="

# ---- 3.1 INSTALL PostgreSQL REPOSITORY ----
log "--- 3.1 Installing PostgreSQL ${PG_VERSION} repository ---"
# RHEL 8
dnf install -y "https://download.postgresql.org/pub/repos/yum/reporpms/EL-8-x86_64/pgdg-redhat-repo-latest.noarch.rpm" 2>/dev/null || \
# RHEL 9 fallback
dnf install -y "https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm" || true

# Disable built-in postgresql module if RHEL 8
dnf -qy module disable postgresql 2>/dev/null || true
log "PostgreSQL repo installed."

# ---- 3.2 INSTALL PostgreSQL PACKAGES ----
log "--- 3.2 Installing PostgreSQL ${PG_VERSION} packages ---"
dnf install -y \
    "postgresql${PG_VERSION}-server" \
    "postgresql${PG_VERSION}" \
    "postgresql${PG_VERSION}-contrib" \
    "postgresql${PG_VERSION}-devel" \
    "postgresql${PG_VERSION}-libs"
log "PostgreSQL ${PG_VERSION} installed."

# ---- 3.3 ADD PostgreSQL BINARIES TO PATH ----
log "--- 3.3 Configuring PATH for PostgreSQL binaries ---"
PG_BIN_DIR="/usr/pgsql-${PG_VERSION}/bin"

# Add to system profile
cat > /etc/profile.d/postgresql.sh <<EOF
# PostgreSQL ${PG_VERSION} binary path
export PATH=\$PATH:${PG_BIN_DIR}
export PGDATA="${PGDATA}"
EOF
source /etc/profile.d/postgresql.sh

# Add to postgres user profile
cat >> /var/lib/pgsql/.bash_profile <<EOF

# PostgreSQL environment
export PATH=\$PATH:${PG_BIN_DIR}
export PGDATA="${PGDATA}"
export PGPORT=5432
EOF

log "PATH configured: ${PG_BIN_DIR}"

# ---- 3.4 CREATE REQUIRED DIRECTORIES ----
log "--- 3.4 Creating PostgreSQL directories ---"
mkdir -p "${PGDATA}"
mkdir -p "${PG_LOG_DIR}"
chown -R postgres:postgres "${PGDATA}" "${PG_LOG_DIR}"
chmod 750 "${PGDATA}"
log "Directories created."

# ---- 3.5 INSTALL PYTHON PACKAGES NEEDED BY PATRONI ----
log "--- 3.5 Installing Python packages for Patroni ---"
pip3 install --upgrade pip
pip3 install \
    psycopg2-binary \
    python-etcd
log "Python packages installed."

# ---- 3.6 VERIFY INSTALLATION ----
log "--- 3.6 Verifying PostgreSQL installation ---"
PG_INSTALLED_VERSION=$(${PG_BIN_DIR}/postgres --version)
log "PostgreSQL version: ${PG_INSTALLED_VERSION}"

# ---- 3.7 DO NOT START postgresql-15.service ----
# IMPORTANT: Patroni will manage PostgreSQL.
# The postgresql-15.service should NOT be started independently.
log "--- 3.7 Ensuring PostgreSQL service is disabled (Patroni manages it) ---"
systemctl disable "postgresql-${PG_VERSION}" 2>/dev/null || true
systemctl stop "postgresql-${PG_VERSION}" 2>/dev/null || true
log "postgresql-${PG_VERSION}.service disabled (will be managed by Patroni)."

# ---- 3.8 GRANT postgres USER SYSTEMCTL PRIVILEGES (for Patroni callbacks) ----
log "--- 3.8 Configuring sudoers for postgres user ---"
cat > /etc/sudoers.d/postgres-patroni <<EOF
# Allow postgres user to manage services for Patroni callbacks
postgres ALL=(ALL) NOPASSWD: /bin/systemctl start patroni
postgres ALL=(ALL) NOPASSWD: /bin/systemctl stop patroni
postgres ALL=(ALL) NOPASSWD: /bin/systemctl restart patroni
postgres ALL=(ALL) NOPASSWD: /bin/systemctl reload patroni
EOF
chmod 440 /etc/sudoers.d/postgres-patroni
log "Sudoers configured for postgres user."

log ""
log "=== Step 3 Complete: PostgreSQL ${PG_VERSION} installed on $(hostname) ==="
log ""
log "IMPORTANT: Do NOT run 'postgresql-${PG_VERSION} initdb' or start the service."
log "Patroni will initialize the cluster automatically."
log ""
log "NEXT STEPS:"
log "  1. Run this script on all other nodes"
log "  2. Proceed to: 04-patroni-setup.sh"
