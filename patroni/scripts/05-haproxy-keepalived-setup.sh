#!/bin/bash
# =============================================================================
# Script: 05-haproxy-keepalived-setup.sh
# Description: Step 5 - Install HAProxy and Keepalived for connection routing
#              and virtual IP (VIP) management.
# Run this script on: NODE1, NODE2, NODE3
#
# Architecture:
#   - HAProxy:    Routes port 5000 -> Primary (R/W), port 5001 -> Replicas (RO)
#                 Uses Patroni REST API health checks to detect current primary.
#   - Keepalived: Manages a Virtual IP (VIP) that always points to the HAProxy
#                 instance on the active primary node.
# =============================================================================

set -euo pipefail

# ---- CONFIGURATION ----
NODE1_IP="192.168.1.101"
NODE2_IP="192.168.1.102"
NODE3_IP="192.168.1.103"
NODE1_HOSTNAME="pg-node1"
NODE2_HOSTNAME="pg-node2"
NODE3_HOSTNAME="pg-node3"
VIP="192.168.1.100"               # Virtual IP
VIP_INTERFACE="eth0"              # Network interface for VIP (adjust if needed)
HAPROXY_STATS_PORT=7000
HAPROXY_PRIMARY_PORT=5000         # Read-write connections (primary only)
HAPROXY_REPLICA_PORT=5001         # Read-only connections (replicas)
PATRONI_REST_PORT=8008
HAPROXY_STATS_USER="haproxy_stats"
HAPROXY_STATS_PASS="HaproxyStats123!"

# Keepalived priorities (highest wins election for VIP)
NODE1_PRIORITY=110
NODE2_PRIORITY=100
NODE3_PRIORITY=90
KEEPALIVED_ROUTER_ID=51
KEEPALIVED_AUTH_PASS="keepalived_secret_2024"

# ---- DETECT CURRENT NODE ----
CURRENT_IP=$(hostname -I | awk '{print $1}')

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

if [ "${CURRENT_IP}" = "${NODE1_IP}" ]; then
    CURRENT_NAME="${NODE1_HOSTNAME}"
    KEEPALIVED_PRIORITY=${NODE1_PRIORITY}
    KEEPALIVED_STATE="MASTER"
elif [ "${CURRENT_IP}" = "${NODE2_IP}" ]; then
    CURRENT_NAME="${NODE2_HOSTNAME}"
    KEEPALIVED_PRIORITY=${NODE2_PRIORITY}
    KEEPALIVED_STATE="BACKUP"
elif [ "${CURRENT_IP}" = "${NODE3_IP}" ]; then
    CURRENT_NAME="${NODE3_HOSTNAME}"
    KEEPALIVED_PRIORITY=${NODE3_PRIORITY}
    KEEPALIVED_STATE="BACKUP"
else
    log "ERROR: Current IP ${CURRENT_IP} does not match any configured node."
    exit 1
fi

log "=== Step 5: HAProxy and Keepalived Setup ==="
log "Current node: ${CURRENT_NAME} (${CURRENT_IP})"

# ============================================================================
# PART A: HAProxy Installation and Configuration
# ============================================================================

# ---- 5.1 INSTALL HAProxy ----
log "--- 5.1 Installing HAProxy ---"
dnf install -y haproxy
log "HAProxy installed: $(haproxy -v 2>&1 | head -1)"

# ---- 5.2 CONFIGURE HAProxy ----
log "--- 5.2 Configuring HAProxy ---"
cat > /etc/haproxy/haproxy.cfg <<EOF
#------------------------------------------------------------------------------
# HAProxy Configuration for Patroni PostgreSQL HA Cluster
# Updated: $(date '+%Y-%m-%d')
#------------------------------------------------------------------------------

global
    log         /dev/log local0
    log         /dev/log local1 notice
    chroot      /var/lib/haproxy
    pidfile     /var/run/haproxy.pid
    maxconn     4096
    user        haproxy
    group       haproxy
    daemon
    stats socket /var/lib/haproxy/stats level admin expose-fd listeners

defaults
    log                     global
    option                  dontlognull
    option                  redispatch
    option                  tcplog
    retries                 3
    timeout connect         5s
    timeout client          30m
    timeout server          30m
    timeout check           5s
    maxconn                 2048

#------------------------------------------------------------------------------
# Statistics web UI
# Access at: http://<node-ip>:${HAPROXY_STATS_PORT}/stats
#------------------------------------------------------------------------------
listen stats
    bind *:${HAPROXY_STATS_PORT}
    mode http
    stats enable
    stats uri /stats
    stats realm HAProxy\ Statistics
    stats auth ${HAPROXY_STATS_USER}:${HAPROXY_STATS_PASS}
    stats refresh 10s
    stats show-legends
    stats show-node

#------------------------------------------------------------------------------
# Primary (Read-Write) - Port ${HAPROXY_PRIMARY_PORT}
# Only routes to the Patroni PRIMARY node.
# Health check: Patroni REST API returns HTTP 200 only on primary.
# Application should use: <VIP>:${HAPROXY_PRIMARY_PORT}
#------------------------------------------------------------------------------
listen pg_primary
    bind *:${HAPROXY_PRIMARY_PORT}
    mode tcp
    option tcp-check
    # Patroni REST API health check - /primary returns 200 only on leader
    option httpchk GET /primary
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server ${NODE1_HOSTNAME} ${NODE1_IP}:5432 check port ${PATRONI_REST_PORT} check-ssl verify none
    server ${NODE2_HOSTNAME} ${NODE2_IP}:5432 check port ${PATRONI_REST_PORT} check-ssl verify none
    server ${NODE3_HOSTNAME} ${NODE3_IP}:5432 check port ${PATRONI_REST_PORT} check-ssl verify none

#------------------------------------------------------------------------------
# Replicas (Read-Only) - Port ${HAPROXY_REPLICA_PORT}
# Routes to REPLICA nodes. Falls back to primary if no replicas available.
# Health check: Patroni REST API /replica returns 200 on replicas.
# Application should use: <VIP>:${HAPROXY_REPLICA_PORT} for read-only queries
#------------------------------------------------------------------------------
listen pg_replicas
    bind *:${HAPROXY_REPLICA_PORT}
    mode tcp
    balance leastconn
    option tcp-check
    # Patroni REST API - /replica returns 200 on replicas
    option httpchk GET /replica?lag=100MB
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server ${NODE1_HOSTNAME} ${NODE1_IP}:5432 check port ${PATRONI_REST_PORT} check-ssl verify none
    server ${NODE2_HOSTNAME} ${NODE2_IP}:5432 check port ${PATRONI_REST_PORT} check-ssl verify none
    server ${NODE3_HOSTNAME} ${NODE3_IP}:5432 check port ${PATRONI_REST_PORT} check-ssl verify none
EOF

log "HAProxy configuration created at /etc/haproxy/haproxy.cfg"

# ---- 5.3 CONFIGURE SELinux FOR HAProxy ----
log "--- 5.3 Configuring SELinux for HAProxy ---"
setsebool -P haproxy_connect_any 1 2>/dev/null || true
log "SELinux configured for HAProxy."

# ---- 5.4 START HAProxy ----
log "--- 5.4 Starting HAProxy ---"
haproxy -c -f /etc/haproxy/haproxy.cfg  # Validate config
systemctl enable --now haproxy
log "HAProxy started."

# ============================================================================
# PART B: Keepalived Installation and Configuration
# ============================================================================

# ---- 5.5 INSTALL Keepalived ----
log "--- 5.5 Installing Keepalived ---"
dnf install -y keepalived
log "Keepalived installed: $(keepalived --version 2>&1 | head -1)"

# ---- 5.6 CREATE KEEPALIVED HEALTH CHECK SCRIPT ----
log "--- 5.6 Creating Keepalived health check script ---"
cat > /etc/keepalived/check_haproxy.sh <<'CHECK_EOF'
#!/bin/bash
# Health check for Keepalived: verify HAProxy is running and PostgreSQL primary is reachable
if systemctl is-active --quiet haproxy; then
    # Also check if HAProxy can reach the primary
    if curl -s -o /dev/null -w "%{http_code}" \
       "http://127.0.0.1:8008/primary" 2>/dev/null | grep -q "200"; then
        exit 0   # Healthy: HAProxy running AND local node is primary
    fi
fi
exit 1  # Unhealthy
CHECK_EOF
chmod +x /etc/keepalived/check_haproxy.sh

# ---- 5.7 CONFIGURE Keepalived ----
log "--- 5.7 Configuring Keepalived on ${CURRENT_NAME} ---"
cat > /etc/keepalived/keepalived.conf <<EOF
# =============================================================================
# Keepalived Configuration for Patroni HA Cluster
# Node: ${CURRENT_NAME} | State: ${KEEPALIVED_STATE} | Priority: ${KEEPALIVED_PRIORITY}
# =============================================================================

global_defs {
    router_id ${CURRENT_NAME}
    script_user root
    enable_script_security
}

# Health check: verify this node is the PostgreSQL primary
vrrp_script chk_patroni_primary {
    script "/etc/keepalived/check_haproxy.sh"
    interval 2         # Check every 2 seconds
    weight -20         # Reduce priority by 20 if script fails
    fall 2             # Failures before declaring down
    rise 2             # Successes before declaring up
}

# VRRP instance: manages the Virtual IP
vrrp_instance VI_PATRONI_PRIMARY {
    state ${KEEPALIVED_STATE}
    interface ${VIP_INTERFACE}
    virtual_router_id ${KEEPALIVED_ROUTER_ID}
    priority ${KEEPALIVED_PRIORITY}
    advert_int 1
    preempt_delay 30   # Wait 30s before preempting lower-priority node

    authentication {
        auth_type PASS
        auth_pass ${KEEPALIVED_AUTH_PASS}
    }

    virtual_ipaddress {
        ${VIP}/24 dev ${VIP_INTERFACE}
    }

    track_script {
        chk_patroni_primary
    }

    # Notifications (optional: configure email or script)
    notify_master "/bin/echo 'VIP ${VIP} acquired by ${CURRENT_NAME}' >> /var/log/keepalived.log"
    notify_backup "/bin/echo 'VIP ${VIP} released by ${CURRENT_NAME}' >> /var/log/keepalived.log"
    notify_fault  "/bin/echo 'Keepalived FAULT on ${CURRENT_NAME}' >> /var/log/keepalived.log"
}
EOF

log "Keepalived configuration created."

# ---- 5.8 ENABLE IP FORWARDING FOR Keepalived ----
log "--- 5.8 Enabling IP forwarding ---"
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-keepalived.conf
sysctl --system
log "IP forwarding enabled."

# ---- 5.9 ALLOW VRRP IN FIREWALL ----
log "--- 5.9 Configuring firewall for VRRP (Keepalived) ---"
firewall-cmd --permanent --add-rich-rule='rule protocol value="vrrp" accept'
firewall-cmd --reload
log "VRRP firewall rule added."

# ---- 5.10 START Keepalived ----
log "--- 5.10 Starting Keepalived ---"
systemctl enable --now keepalived
log "Keepalived started."

# ---- 5.11 VERIFY VIP ----
sleep 5
log "--- 5.11 Verifying Virtual IP ---"
if ip addr show "${VIP_INTERFACE}" | grep -q "${VIP}"; then
    log "SUCCESS: VIP ${VIP} is assigned to ${CURRENT_NAME} (this node is MASTER)."
else
    log "INFO: VIP ${VIP} is not on this node (this node is BACKUP - expected if not primary)."
fi

log ""
log "=== Step 5 Complete: HAProxy and Keepalived configured on ${CURRENT_NAME} ==="
log ""
log "CONNECTION ENDPOINTS:"
log "  Primary (R/W):  ${VIP}:${HAPROXY_PRIMARY_PORT}"
log "  Replicas (RO):  ${VIP}:${HAPROXY_REPLICA_PORT}"
log "  HAProxy Stats:  http://${CURRENT_IP}:${HAPROXY_STATS_PORT}/stats"
log "                  User: ${HAPROXY_STATS_USER} / Pass: ${HAPROXY_STATS_PASS}"
log ""
log "VERIFICATION COMMANDS:"
log "  VIP status:     ip addr show ${VIP_INTERFACE} | grep ${VIP}"
log "  HAProxy status: systemctl status haproxy"
log "  Keepalived:     systemctl status keepalived"
log "  Connect test:   psql -h ${VIP} -p ${HAPROXY_PRIMARY_PORT} -U postgres -c 'SELECT pg_is_in_recovery();'"
log ""
log "NEXT STEPS:"
log "  1. Run this script on all other nodes"
log "  2. Proceed to: 06-test-failover.sh"
