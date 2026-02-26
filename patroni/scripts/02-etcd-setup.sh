#!/bin/bash
# =============================================================================
# Script: 02-etcd-setup.sh
# Description: Step 2 - Install and configure etcd cluster (DCS for Patroni)
# Run this script on: NODE1, NODE2, NODE3
# etcd version: 3.5.x
# =============================================================================

set -euo pipefail

# ---- CONFIGURATION ----
NODE1_IP="192.168.1.101"
NODE2_IP="192.168.1.102"
NODE3_IP="192.168.1.103"
NODE1_HOSTNAME="pg-node1"
NODE2_HOSTNAME="pg-node2"
NODE3_HOSTNAME="pg-node3"
ETCD_VERSION="3.5.9"
ETCD_CLUSTER_TOKEN="patroni-etcd-cluster-token-$(openssl rand -hex 8)"
ETCD_DATA_DIR="/var/lib/etcd"

# ---- DETECT CURRENT NODE ----
CURRENT_IP=$(hostname -I | awk '{print $1}')

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Determine current node identity
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

log "=== Step 2: etcd Cluster Setup ==="
log "Current node: ${CURRENT_NAME} (${CURRENT_IP})"

# ---- 2.1 DOWNLOAD AND INSTALL etcd ----
log "--- 2.1 Downloading etcd v${ETCD_VERSION} ---"
ETCD_ARCHIVE="etcd-v${ETCD_VERSION}-linux-amd64"
cd /tmp
if [ ! -f "${ETCD_ARCHIVE}.tar.gz" ]; then
    curl -L "https://github.com/etcd-io/etcd/releases/download/v${ETCD_VERSION}/${ETCD_ARCHIVE}.tar.gz" \
         -o "${ETCD_ARCHIVE}.tar.gz"
fi
tar xzf "${ETCD_ARCHIVE}.tar.gz"
cp "${ETCD_ARCHIVE}/etcd" /usr/local/bin/
cp "${ETCD_ARCHIVE}/etcdctl" /usr/local/bin/
chmod +x /usr/local/bin/etcd /usr/local/bin/etcdctl
log "etcd installed: $(etcd --version | head -1)"

# ---- 2.2 CREATE etcd USER AND DIRECTORIES ----
log "--- 2.2 Creating etcd user and directories ---"
id etcd &>/dev/null || useradd -r -s /sbin/nologin -d "${ETCD_DATA_DIR}" etcd
mkdir -p "${ETCD_DATA_DIR}"
chown -R etcd:etcd "${ETCD_DATA_DIR}"
log "etcd user and data directory ready."

# ---- 2.3 GENERATE etcd CONFIGURATION ----
log "--- 2.3 Generating etcd configuration ---"
mkdir -p /etc/etcd

cat > /etc/etcd/etcd.conf <<EOF
# etcd configuration for Patroni HA cluster
# Node: ${CURRENT_NAME}

# Member settings
ETCD_NAME="${CURRENT_NAME}"
ETCD_DATA_DIR="${ETCD_DATA_DIR}"
ETCD_WAL_DIR=""
ETCD_SNAPSHOT_COUNT="10000"
ETCD_HEARTBEAT_INTERVAL="100"
ETCD_ELECTION_TIMEOUT="1000"
ETCD_QUOTA_BACKEND_BYTES="8589934592"

# Cluster settings
ETCD_LISTEN_PEER_URLS="http://${CURRENT_IP}:2380"
ETCD_LISTEN_CLIENT_URLS="http://${CURRENT_IP}:2379,http://127.0.0.1:2379"
ETCD_MAX_SNAPSHOTS="5"
ETCD_MAX_WALS="5"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://${CURRENT_IP}:2380"
ETCD_ADVERTISE_CLIENT_URLS="http://${CURRENT_IP}:2379"
ETCD_DISCOVERY=""
ETCD_INITIAL_CLUSTER_TOKEN="${ETCD_CLUSTER_TOKEN}"
ETCD_INITIAL_CLUSTER="${NODE1_HOSTNAME}=http://${NODE1_IP}:2380,${NODE2_HOSTNAME}=http://${NODE2_IP}:2380,${NODE3_HOSTNAME}=http://${NODE3_IP}:2380"
ETCD_INITIAL_CLUSTER_STATE="new"

# Security (TLS - optional, configure for production)
ETCD_CERT_FILE=""
ETCD_KEY_FILE=""
ETCD_CLIENT_CERT_AUTH="false"
ETCD_TRUSTED_CA_FILE=""
ETCD_AUTO_TLS="false"
ETCD_PEER_CERT_FILE=""
ETCD_PEER_KEY_FILE=""
ETCD_PEER_CLIENT_CERT_AUTH="false"
ETCD_PEER_TRUSTED_CA_FILE=""
ETCD_PEER_AUTO_TLS="false"

# Logging
ETCD_LOG_LEVEL="info"
ETCD_LOG_OUTPUTS="default"
EOF

chown etcd:etcd /etc/etcd/etcd.conf
log "etcd configuration created at /etc/etcd/etcd.conf"

# ---- 2.4 CREATE SYSTEMD SERVICE ----
log "--- 2.4 Creating etcd systemd service ---"
cat > /etc/systemd/system/etcd.service <<EOF
[Unit]
Description=etcd key-value store (Patroni DCS)
Documentation=https://github.com/etcd-io/etcd
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=notify
User=etcd
Group=etcd
EnvironmentFile=/etc/etcd/etcd.conf
ExecStart=/usr/local/bin/etcd
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
LimitNPROC=65536

# Hardening
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
NoNewPrivileges=true
ReadWritePaths=${ETCD_DATA_DIR}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
log "etcd systemd service created."

# ---- 2.5 START etcd ----
log "--- 2.5 Starting etcd service ---"
log "NOTE: Start etcd on ALL THREE nodes within 2 minutes of each other for cluster formation."
log "Starting etcd now..."
systemctl enable --now etcd
sleep 5

# ---- 2.6 VERIFY etcd HEALTH ----
log "--- 2.6 Verifying etcd health ---"
log "Waiting 10 seconds for cluster to form..."
sleep 10

# Check local member
if etcdctl --endpoints="http://127.0.0.1:2379" endpoint health; then
    log "Local etcd is healthy."
else
    log "WARNING: Local etcd health check failed. Ensure all nodes are running etcd."
fi

# Print cluster status if all members reachable
log "Checking cluster member list..."
etcdctl --endpoints="http://${NODE1_IP}:2379,http://${NODE2_IP}:2379,http://${NODE3_IP}:2379" \
    member list --write-out=table 2>/dev/null || \
    log "WARNING: Cannot reach all members yet. Run validation after all nodes are started."

log ""
log "=== Step 2 Complete: etcd configured on ${CURRENT_NAME} ==="
log ""
log "NEXT STEPS:"
log "  1. Run this script on all other nodes"
log "  2. Validate cluster: etcdctl --endpoints=http://${NODE1_IP}:2379,http://${NODE2_IP}:2379,http://${NODE3_IP}:2379 endpoint health --write-out=table"
log "  3. Proceed to: 03-postgresql-setup.sh"
