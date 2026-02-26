#!/bin/bash
# =============================================================================
# Script: 04-patroni-setup.sh
# Description: Step 4 - Install and configure Patroni on all three nodes
# Run this script on: NODE1, NODE2, NODE3
# Patroni version: 3.x
# =============================================================================

set -euo pipefail

# ---- CONFIGURATION ----
NODE1_IP="192.168.1.101"
NODE2_IP="192.168.1.102"
NODE3_IP="192.168.1.103"
NODE1_HOSTNAME="pg-node1"
NODE2_HOSTNAME="pg-node2"
NODE3_HOSTNAME="pg-node3"
PG_VERSION="15"
PG_BIN_DIR="/usr/pgsql-${PG_VERSION}/bin"
PGDATA="/var/lib/pgsql/${PG_VERSION}/data"
PATRONI_CONFIG_DIR="/etc/patroni"
PATRONI_LOG_DIR="/var/log/patroni"
PATRONI_SCOPE="postgres-ha"          # Cluster name (must be same on all nodes)
PATRONI_NAMESPACE="/patroni"          # etcd key namespace
POSTGRES_SUPERUSER_PASSWORD="StrongPostgresPassword123!"
REPLICATION_PASSWORD="StrongReplicationPassword123!"
REWIND_PASSWORD="StrongRewindPassword123!"

# ---- DETECT CURRENT NODE ----
CURRENT_IP=$(hostname -I | awk '{print $1}')

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

if [ "${CURRENT_IP}" = "${NODE1_IP}" ]; then
    CURRENT_NAME="${NODE1_HOSTNAME}"
elif [ "${CURRENT_IP}" = "${NODE2_IP}" ]; then
    CURRENT_NAME="${NODE2_HOSTNAME}"
elif [ "${CURRENT_IP}" = "${NODE3_IP}" ]; then
    CURRENT_NAME="${NODE3_HOSTNAME}"
else
    log "ERROR: Current IP ${CURRENT_IP} does not match any configured node."
    exit 1
fi

log "=== Step 4: Patroni Installation and Configuration ==="
log "Current node: ${CURRENT_NAME} (${CURRENT_IP})"

# ---- 4.1 INSTALL PATRONI VIA PIP ----
log "--- 4.1 Installing Patroni and dependencies ---"
pip3 install --upgrade \
    patroni[etcd] \
    psycopg2-binary \
    python-etcd \
    ydiff
log "Patroni installed: $(patroni --version)"

# ---- 4.2 CREATE PATRONI USER AND DIRECTORIES ----
log "--- 4.2 Creating Patroni directories ---"
mkdir -p "${PATRONI_CONFIG_DIR}"
mkdir -p "${PATRONI_LOG_DIR}"
chown -R postgres:postgres "${PATRONI_CONFIG_DIR}" "${PATRONI_LOG_DIR}"
chmod 750 "${PATRONI_CONFIG_DIR}"
log "Patroni directories created."

# ---- 4.3 GENERATE PATRONI CONFIGURATION FILE ----
log "--- 4.3 Generating Patroni configuration for ${CURRENT_NAME} ---"

cat > "${PATRONI_CONFIG_DIR}/patroni.yml" <<EOF
# =============================================================================
# Patroni configuration for node: ${CURRENT_NAME}
# Cluster: ${PATRONI_SCOPE}
# =============================================================================

scope: ${PATRONI_SCOPE}
namespace: ${PATRONI_NAMESPACE}
name: ${CURRENT_NAME}

# --------------------------------------------------------------------------
# Distributed Configuration Store (DCS) - etcd
# --------------------------------------------------------------------------
etcd3:
  hosts:
    - ${NODE1_IP}:2379
    - ${NODE2_IP}:2379
    - ${NODE3_IP}:2379
  # For TLS (optional):
  # protocol: https
  # cacert: /etc/etcd/ssl/ca.crt
  # cert: /etc/etcd/ssl/client.crt
  # key: /etc/etcd/ssl/client.key

# --------------------------------------------------------------------------
# Patroni REST API
# --------------------------------------------------------------------------
restapi:
  listen: ${CURRENT_IP}:8008
  connect_address: ${CURRENT_IP}:8008
  # Uncomment to enable basic auth on REST API:
  # authentication:
  #   username: patroni
  #   password: patroni_api_password

# --------------------------------------------------------------------------
# Bootstrap: runs only when initializing cluster for the first time
# --------------------------------------------------------------------------
bootstrap:
  # Time to wait for cluster to be initialized (seconds)
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576    # 1MB - max lag for replica to be failover candidate
    maximum_lag_on_syncnode: -1
    max_timelines_history: 0
    primary_start_timeout: 300
    synchronous_mode: false             # Set to true for zero data loss (requires at least 2 nodes)
    synchronous_mode_strict: false
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        # ---- Connections ----
        max_connections: 200
        superuser_reserved_connections: 5
        # ---- WAL ----
        wal_level: replica
        wal_log_hints: 'on'             # Required for pg_rewind
        wal_compression: 'on'
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: '512MB'
        max_wal_size: '4GB'
        min_wal_size: '256MB'
        # ---- Replication ----
        hot_standby: 'on'
        hot_standby_feedback: 'on'
        # ---- Performance ----
        shared_buffers: '256MB'
        effective_cache_size: '768MB'
        maintenance_work_mem: '64MB'
        checkpoint_completion_target: 0.9
        random_page_cost: 1.1
        effective_io_concurrency: 200
        default_statistics_target: 100
        # ---- Logging ----
        log_destination: 'stderr'
        logging_collector: 'on'
        log_directory: '${PATRONI_LOG_DIR}'
        log_filename: 'postgresql-%Y-%m-%d_%H%M%S.log'
        log_rotation_age: '1d'
        log_rotation_size: '100MB'
        log_min_duration_statement: 1000  # Log queries longer than 1s
        log_checkpoints: 'on'
        log_connections: 'on'
        log_disconnections: 'on'
        log_lock_waits: 'on'
        log_temp_files: 0
        log_autovacuum_min_duration: 0
        log_line_prefix: '%m [%p] %q%u@%d '
        # ---- Timezone ----
        timezone: 'UTC'
        log_timezone: 'UTC'

  # Initialize the database cluster
  initdb:
    - encoding: UTF8
    - data-checksums
    - locale: en_US.UTF-8

  # Create replication slot for each replica after bootstrap
  slots:
    ${NODE2_HOSTNAME}_slot:
      type: physical
    ${NODE3_HOSTNAME}_slot:
      type: physical

  # Execute these SQL commands after bootstrap
  post_bootstrap: /etc/patroni/post_bootstrap.sh

  pg_hba:
    # Local connections
    - local   all             all                                     trust
    - host    all             all             127.0.0.1/32            scram-sha-256
    - host    all             all             ::1/128                 scram-sha-256
    # Replication connections from all cluster nodes
    - host    replication     replicator      ${NODE1_IP}/32          scram-sha-256
    - host    replication     replicator      ${NODE2_IP}/32          scram-sha-256
    - host    replication     replicator      ${NODE3_IP}/32          scram-sha-256
    # pg_rewind connections
    - host    all             rewind_user     ${NODE1_IP}/32          scram-sha-256
    - host    all             rewind_user     ${NODE2_IP}/32          scram-sha-256
    - host    all             rewind_user     ${NODE3_IP}/32          scram-sha-256
    # Application connections (adjust CIDR to your network)
    - host    all             all             192.168.1.0/24          scram-sha-256

# --------------------------------------------------------------------------
# PostgreSQL settings
# --------------------------------------------------------------------------
postgresql:
  listen: "${CURRENT_IP}:5432"
  connect_address: "${CURRENT_IP}:5432"
  data_dir: "${PGDATA}"
  bin_dir: "${PG_BIN_DIR}"
  config_dir: "${PGDATA}"
  pgpass: /var/lib/pgsql/.pgpass

  authentication:
    replication:
      username: replicator
      password: "${REPLICATION_PASSWORD}"
    superuser:
      username: postgres
      password: "${POSTGRES_SUPERUSER_PASSWORD}"
    rewind:
      username: rewind_user
      password: "${REWIND_PASSWORD}"

  parameters:
    unix_socket_directories: '/var/run/postgresql,/tmp'
    archive_mode: 'on'
    archive_command: '/bin/true'    # Replace with actual archive command in production

  create_replica_methods:
    - basebackup

  basebackup:
    checkpoint: fast
    max-rate: '100M'
    verbose: true

  # Callbacks: scripts executed on state changes
  callbacks:
    on_start: /etc/patroni/callbacks/on_start.sh
    on_stop: /etc/patroni/callbacks/on_stop.sh
    on_role_change: /etc/patroni/callbacks/on_role_change.sh
    on_reload: /etc/patroni/callbacks/on_reload.sh

# --------------------------------------------------------------------------
# Tags: control node behavior in elections
# --------------------------------------------------------------------------
tags:
  nofailover: false      # Set to true to exclude this node from leader elections
  noloadbalance: false   # Set to true to exclude from load balancing
  clonefrom: false       # Set to true to prefer this node as clone source
  nosync: false          # Set to true to exclude from synchronous replication
EOF

chown postgres:postgres "${PATRONI_CONFIG_DIR}/patroni.yml"
chmod 640 "${PATRONI_CONFIG_DIR}/patroni.yml"
log "Patroni configuration created: ${PATRONI_CONFIG_DIR}/patroni.yml"

# ---- 4.4 CREATE POST-BOOTSTRAP SCRIPT ----
log "--- 4.4 Creating post-bootstrap SQL script ---"
cat > "${PATRONI_CONFIG_DIR}/post_bootstrap.sh" <<'BOOTSTRAP_EOF'
#!/bin/bash
# Post-bootstrap: creates required PostgreSQL users and roles
set -euo pipefail

POSTGRES_SUPERUSER_PASSWORD="StrongPostgresPassword123!"
REPLICATION_PASSWORD="StrongReplicationPassword123!"
REWIND_PASSWORD="StrongRewindPassword123!"

psql -U postgres <<SQL
-- Set postgres superuser password
ALTER USER postgres PASSWORD '${POSTGRES_SUPERUSER_PASSWORD}';

-- Create replication user
CREATE USER replicator WITH REPLICATION ENCRYPTED PASSWORD '${REPLICATION_PASSWORD}';

-- Create rewind user (needs REPLICATION or superuser for pg_rewind)
CREATE USER rewind_user WITH LOGIN ENCRYPTED PASSWORD '${REWIND_PASSWORD}';
GRANT EXECUTE ON FUNCTION pg_catalog.pg_ls_dir(text, boolean, boolean) TO rewind_user;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_stat_file(text, boolean) TO rewind_user;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text) TO rewind_user;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean) TO rewind_user;

-- Create monitoring user (optional)
CREATE USER monitor WITH LOGIN ENCRYPTED PASSWORD 'MonitorPassword123!';
GRANT pg_monitor TO monitor;

-- Log success
\echo 'Post-bootstrap SQL complete.'
SQL
BOOTSTRAP_EOF

chmod +x "${PATRONI_CONFIG_DIR}/post_bootstrap.sh"
chown postgres:postgres "${PATRONI_CONFIG_DIR}/post_bootstrap.sh"

# ---- 4.5 CREATE CALLBACK SCRIPTS ----
log "--- 4.5 Creating Patroni callback scripts ---"
mkdir -p "${PATRONI_CONFIG_DIR}/callbacks"

cat > "${PATRONI_CONFIG_DIR}/callbacks/on_role_change.sh" <<'CB_EOF'
#!/bin/bash
# Patroni callback: triggered on role change (primary <-> replica)
# Arguments: $1=action, $2=role, $3=cluster_name
ACTION=$1
ROLE=$2
CLUSTER=$3
LOG_FILE="/var/log/patroni/callbacks.log"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Role change: action=${ACTION}, role=${ROLE}, cluster=${CLUSTER}" >> "${LOG_FILE}"

case "${ROLE}" in
  master|primary)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] This node is now PRIMARY" >> "${LOG_FILE}"
    # Add any primary promotion hooks here (e.g., DNS update, notify monitoring)
    ;;
  replica)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] This node is now a REPLICA" >> "${LOG_FILE}"
    ;;
esac
CB_EOF

cat > "${PATRONI_CONFIG_DIR}/callbacks/on_start.sh" <<'CB_EOF'
#!/bin/bash
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Patroni PostgreSQL started" >> /var/log/patroni/callbacks.log
CB_EOF

cat > "${PATRONI_CONFIG_DIR}/callbacks/on_stop.sh" <<'CB_EOF'
#!/bin/bash
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Patroni PostgreSQL stopped" >> /var/log/patroni/callbacks.log
CB_EOF

cat > "${PATRONI_CONFIG_DIR}/callbacks/on_reload.sh" <<'CB_EOF'
#!/bin/bash
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Patroni PostgreSQL reloaded" >> /var/log/patroni/callbacks.log
CB_EOF

chmod +x "${PATRONI_CONFIG_DIR}/callbacks/"*.sh
chown -R postgres:postgres "${PATRONI_CONFIG_DIR}/callbacks/"
log "Callback scripts created."

# ---- 4.6 CREATE .pgpass FILE ----
log "--- 4.6 Creating .pgpass for postgres user ---"
cat > /var/lib/pgsql/.pgpass <<EOF
# hostname:port:database:username:password
*:5432:*:postgres:${POSTGRES_SUPERUSER_PASSWORD}
*:5432:*:replicator:${REPLICATION_PASSWORD}
*:5432:*:rewind_user:${REWIND_PASSWORD}
EOF
chmod 600 /var/lib/pgsql/.pgpass
chown postgres:postgres /var/lib/pgsql/.pgpass
log ".pgpass created."

# ---- 4.7 CREATE PATRONI SYSTEMD SERVICE ----
log "--- 4.7 Creating Patroni systemd service ---"
cat > /etc/systemd/system/patroni.service <<EOF
[Unit]
Description=Patroni PostgreSQL HA cluster manager
Documentation=https://patroni.readthedocs.io/
After=syslog.target network.target etcd.service
Wants=etcd.service

[Service]
Type=simple
User=postgres
Group=postgres
WorkingDirectory=/var/lib/pgsql
ExecStart=$(which patroni) ${PATRONI_CONFIG_DIR}/patroni.yml
ExecReload=/bin/kill -s HUP \$MAINPID
KillMode=process
TimeoutSec=30
Restart=on-failure
RestartSec=10s
LimitNOFILE=65536
LimitNPROC=65536

# Logging
StandardOutput=append:${PATRONI_LOG_DIR}/patroni.log
StandardError=append:${PATRONI_LOG_DIR}/patroni.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
log "Patroni systemd service created."

# ---- 4.8 START PATRONI (NODE1 FIRST, THEN OTHERS) ----
log "--- 4.8 Starting Patroni ---"
if [ "${CURRENT_IP}" = "${NODE1_IP}" ]; then
    log "This is NODE1 (will become primary). Starting Patroni..."
    systemctl enable --now patroni
    log "Patroni started on NODE1. Wait 30 seconds before starting on other nodes."
    log "Watch status with: journalctl -fu patroni"
else
    log "This is ${CURRENT_NAME}. Starting Patroni (NODE1 should already be running)..."
    systemctl enable --now patroni
    log "Patroni started. It will join as a replica."
fi

# ---- 4.9 VERIFY PATRONI STATUS ----
sleep 15
log "--- 4.9 Checking Patroni status ---"
if systemctl is-active patroni &>/dev/null; then
    log "Patroni service is RUNNING."
    # Show cluster status if patronictl available
    if command -v patronictl &>/dev/null; then
        patronictl -c "${PATRONI_CONFIG_DIR}/patroni.yml" list 2>/dev/null || true
    fi
else
    log "WARNING: Patroni service is not running. Check: journalctl -fu patroni"
fi

log ""
log "=== Step 4 Complete: Patroni configured on ${CURRENT_NAME} ==="
log ""
log "USEFUL COMMANDS:"
log "  Status:     patronictl -c ${PATRONI_CONFIG_DIR}/patroni.yml list"
log "  History:    patronictl -c ${PATRONI_CONFIG_DIR}/patroni.yml history"
log "  Failover:   patronictl -c ${PATRONI_CONFIG_DIR}/patroni.yml failover ${PATRONI_SCOPE}"
log "  Switchover: patronictl -c ${PATRONI_CONFIG_DIR}/patroni.yml switchover ${PATRONI_SCOPE}"
log "  Logs:       tail -f ${PATRONI_LOG_DIR}/patroni.log"
log ""
log "NEXT STEPS:"
log "  1. Run this script on all other nodes"
log "  2. Verify cluster: patronictl -c ${PATRONI_CONFIG_DIR}/patroni.yml list"
log "  3. Proceed to: 05-haproxy-keepalived-setup.sh"
