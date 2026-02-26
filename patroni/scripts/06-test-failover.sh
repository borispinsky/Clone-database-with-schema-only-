#!/bin/bash
# =============================================================================
# Script: 06-test-failover.sh
# Description: Step 6 - Failover testing, monitoring, and day-2 operations
# Run from: Any cluster node (preferably NODE1)
# =============================================================================

set -euo pipefail

# ---- CONFIGURATION ----
NODE1_IP="192.168.1.101"
NODE2_IP="192.168.1.102"
NODE3_IP="192.168.1.103"
NODE1_HOSTNAME="pg-node1"
NODE2_HOSTNAME="pg-node2"
NODE3_HOSTNAME="pg-node3"
VIP="192.168.1.100"
HAPROXY_PRIMARY_PORT=5000
HAPROXY_REPLICA_PORT=5001
PATRONI_CONFIG="/etc/patroni/patroni.yml"
PATRONI_SCOPE="postgres-ha"
POSTGRES_PASSWORD="StrongPostgresPassword123!"

log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
success() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [OK]  $*"; }
failure() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [FAIL] $*"; }
header()  { echo ""; echo "============================================================================="; echo "  $*"; echo "============================================================================="; }

# ============================================================================
# TEST 1: Cluster Health Check
# ============================================================================
test_cluster_health() {
    header "TEST 1: Cluster Health Check"

    log "1.1 Checking Patroni cluster status..."
    if patronictl -c "${PATRONI_CONFIG}" list; then
        success "Patroni cluster list successful."
    else
        failure "Patroni cluster list failed."
    fi

    log "1.2 Checking etcd health..."
    etcdctl --endpoints="http://${NODE1_IP}:2379,http://${NODE2_IP}:2379,http://${NODE3_IP}:2379" \
        endpoint health --write-out=table && success "etcd cluster healthy." || failure "etcd health check failed."

    log "1.3 Checking Patroni REST API on each node..."
    for IP in ${NODE1_IP} ${NODE2_IP} ${NODE3_IP}; do
        STATUS=$(curl -s "http://${IP}:8008/health" | python3 -m json.tool 2>/dev/null || echo "UNREACHABLE")
        log "  Node ${IP}: ${STATUS}"
    done

    log "1.4 Checking HAProxy stats..."
    PRIMARY_BACKENDS=$(curl -s "http://${NODE1_IP}:7000/stats" | grep -c "pg_primary" 2>/dev/null || echo "0")
    log "  HAProxy primary backends visible: ${PRIMARY_BACKENDS}"
}

# ============================================================================
# TEST 2: Replication Lag Check
# ============================================================================
test_replication_lag() {
    header "TEST 2: Replication Lag Check"

    log "Checking replication lag on all nodes..."
    PGPASSWORD="${POSTGRES_PASSWORD}" psql \
        -h "${VIP}" -p "${HAPROXY_PRIMARY_PORT}" \
        -U postgres -c "
        SELECT
            client_addr,
            state,
            sync_state,
            pg_size_pretty(write_lag::text::interval * 1e6 * 8 / 1024 / 1024 * 1024 * 1024) AS write_lag,
            pg_size_pretty(flush_lag::text::interval * 1e6 * 8 / 1024 / 1024 * 1024 * 1024) AS flush_lag,
            pg_size_pretty(replay_lag::text::interval * 1e6 * 8 / 1024 / 1024 * 1024 * 1024) AS replay_lag,
            pg_size_pretty(sent_lsn - replay_lsn) AS replication_lag_bytes
        FROM pg_stat_replication;" 2>/dev/null || log "Note: Could not query primary (check VIP connectivity)"

    # Alternative: check from patronictl
    log "Patroni lag from patronictl:"
    patronictl -c "${PATRONI_CONFIG}" list 2>/dev/null || true
}

# ============================================================================
# TEST 3: Write Test on Primary
# ============================================================================
test_write_primary() {
    header "TEST 3: Write Test via VIP (Primary)"

    log "3.1 Testing write connection via VIP:${HAPROXY_PRIMARY_PORT}..."
    PGPASSWORD="${POSTGRES_PASSWORD}" psql \
        -h "${VIP}" -p "${HAPROXY_PRIMARY_PORT}" \
        -U postgres <<SQL
-- Check if we are on primary
SELECT pg_is_in_recovery() AS is_replica;

-- Create test table
CREATE TABLE IF NOT EXISTS patroni_test (
    id SERIAL PRIMARY KEY,
    node_name TEXT,
    inserted_at TIMESTAMP DEFAULT now(),
    test_data TEXT
);

-- Insert test record
INSERT INTO patroni_test (node_name, test_data)
VALUES (current_setting('cluster_name'), 'test-write-$(date +%s)');

-- Verify insert
SELECT * FROM patroni_test ORDER BY inserted_at DESC LIMIT 5;
SQL
    success "Write test completed."
}

# ============================================================================
# TEST 4: Read Test on Replicas
# ============================================================================
test_read_replicas() {
    header "TEST 4: Read Test via Replica Port"

    log "4.1 Testing read-only connection via VIP:${HAPROXY_REPLICA_PORT}..."
    PGPASSWORD="${POSTGRES_PASSWORD}" psql \
        -h "${VIP}" -p "${HAPROXY_REPLICA_PORT}" \
        -U postgres <<SQL
-- Should be on a replica
SELECT pg_is_in_recovery() AS is_replica;
SELECT inet_server_addr() AS connected_to;
SELECT COUNT(*) FROM patroni_test;
SQL
    success "Read replica test completed."
}

# ============================================================================
# TEST 5: Planned Switchover (Zero Downtime)
# ============================================================================
test_planned_switchover() {
    header "TEST 5: Planned Switchover"

    log "Current cluster state before switchover:"
    patronictl -c "${PATRONI_CONFIG}" list

    CURRENT_PRIMARY=$(patronictl -c "${PATRONI_CONFIG}" list -f json 2>/dev/null | \
        python3 -c "import sys,json; [print(m['Name']) for m in json.load(sys.stdin) if m.get('Role')=='Leader']" 2>/dev/null || echo "unknown")
    log "Current primary: ${CURRENT_PRIMARY}"

    log "Initiating planned switchover (with automatic candidate selection)..."
    patronictl -c "${PATRONI_CONFIG}" switchover "${PATRONI_SCOPE}" \
        --master "${CURRENT_PRIMARY}" --scheduled now --force

    log "Waiting 15 seconds for switchover to complete..."
    sleep 15

    log "Cluster state after switchover:"
    patronictl -c "${PATRONI_CONFIG}" list
    success "Switchover test completed."
}

# ============================================================================
# TEST 6: Unplanned Failover Simulation (Kill Primary Process)
# ============================================================================
test_unplanned_failover() {
    header "TEST 6: Unplanned Failover Simulation"
    log "WARNING: This test kills the PostgreSQL process on the primary node!"
    log "         Patroni will automatically detect the failure and promote a replica."

    CURRENT_PRIMARY=$(patronictl -c "${PATRONI_CONFIG}" list -f json 2>/dev/null | \
        python3 -c "import sys,json; [print(m['Name']) for m in json.load(sys.stdin) if m.get('Role')=='Leader']" 2>/dev/null || echo "unknown")
    log "Simulating crash on: ${CURRENT_PRIMARY}"

    # Record pre-failover time
    START_TIME=$(date +%s)

    # Kill postgres on primary (simulate crash) - run on primary node
    # This must be executed on the node that is currently primary
    # For demonstration, we show the command to run:
    log "To simulate crash, run on ${CURRENT_PRIMARY}:"
    log "  sudo -u postgres kill -9 \$(sudo -u postgres psql -t -c 'SELECT pg_backend_pid();')"

    log "Monitoring failover (watching for 60 seconds)..."
    for i in $(seq 1 12); do
        sleep 5
        NEW_PRIMARY=$(patronictl -c "${PATRONI_CONFIG}" list -f json 2>/dev/null | \
            python3 -c "import sys,json; [print(m['Name']) for m in json.load(sys.stdin) if m.get('Role')=='Leader']" 2>/dev/null || echo "unknown")
        ELAPSED=$(( $(date +%s) - START_TIME ))
        log "  [${ELAPSED}s] Current leader: ${NEW_PRIMARY}"
        if [ "${NEW_PRIMARY}" != "${CURRENT_PRIMARY}" ] && [ "${NEW_PRIMARY}" != "unknown" ]; then
            success "Failover complete! New primary: ${NEW_PRIMARY} (${ELAPSED}s elapsed)"
            break
        fi
    done

    patronictl -c "${PATRONI_CONFIG}" list
}

# ============================================================================
# TEST 7: Reinstate Failed Node
# ============================================================================
test_reinstate_node() {
    header "TEST 7: Reinstate Failed/Old Primary"

    log "7.1 Check if old primary came back as replica..."
    patronictl -c "${PATRONI_CONFIG}" list

    log "7.2 If node shows as 'stopped', reinstate it:"
    log "  patronictl -c ${PATRONI_CONFIG} reinit ${PATRONI_SCOPE} <node-name>"

    log "7.3 Restart patroni on the failed node (if needed):"
    log "  systemctl restart patroni"
}

# ============================================================================
# TEST 8: Monitoring Commands Reference
# ============================================================================
show_monitoring_commands() {
    header "TEST 8: Monitoring Reference"

    cat <<'MONITORING'
# ---- PATRONI MONITORING ----
# Cluster overview
patronictl -c /etc/patroni/patroni.yml list

# Cluster history (timeline events)
patronictl -c /etc/patroni/patroni.yml history

# Check specific node REST API
curl -s http://192.168.1.101:8008/patroni | python3 -m json.tool
curl -s http://192.168.1.101:8008/health
curl -s http://192.168.1.101:8008/primary    # 200 if primary
curl -s http://192.168.1.101:8008/replica    # 200 if replica
curl -s http://192.168.1.101:8008/cluster    # Full cluster info

# ---- etcd MONITORING ----
# etcd cluster health
etcdctl --endpoints=http://192.168.1.101:2379,http://192.168.1.102:2379,http://192.168.1.103:2379 \
    endpoint health --write-out=table

# etcd member list
etcdctl --endpoints=http://192.168.1.101:2379 member list --write-out=table

# View Patroni keys in etcd
etcdctl --endpoints=http://192.168.1.101:2379 get /patroni/ --prefix

# ---- POSTGRESQL MONITORING ----
# Replication status on primary
psql -U postgres -c "SELECT * FROM pg_stat_replication;"

# Replication lag on replica
psql -U postgres -c "SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag;"

# Check recovery status
psql -U postgres -c "SELECT pg_is_in_recovery(), pg_last_xlog_replay_location();"

# Active connections
psql -U postgres -c "SELECT count(*), state FROM pg_stat_activity GROUP BY state;"

# ---- HAPROXY MONITORING ----
# Stats page (web browser)
# http://192.168.1.100:7000/stats

# Backend status via socat
echo "show info" | socat stdio /var/lib/haproxy/stats
echo "show stat" | socat stdio /var/lib/haproxy/stats

# ---- LOG MONITORING ----
# Patroni logs
tail -f /var/log/patroni/patroni.log

# PostgreSQL logs
tail -f /var/log/patroni/postgresql-*.log

# Keepalived logs
tail -f /var/log/keepalived.log
journalctl -fu keepalived

# ---- DAY-2 OPERATIONS ----
# Manual failover (promotes a specific node)
patronictl -c /etc/patroni/patroni.yml failover postgres-ha --master pg-node1 --candidate pg-node2

# Switchover (graceful, planned)
patronictl -c /etc/patroni/patroni.yml switchover postgres-ha

# Pause auto-failover (for maintenance)
patronictl -c /etc/patroni/patroni.yml pause postgres-ha

# Resume auto-failover
patronictl -c /etc/patroni/patroni.yml resume postgres-ha

# Reload Patroni configuration (without restart)
patronictl -c /etc/patroni/patroni.yml reload postgres-ha

# Restart PostgreSQL via Patroni (safe rolling restart)
patronictl -c /etc/patroni/patroni.yml restart postgres-ha

# Reinitialize a replica from scratch
patronictl -c /etc/patroni/patroni.yml reinit postgres-ha pg-node2

# Edit DCS configuration
patronictl -c /etc/patroni/patroni.yml edit-config postgres-ha
MONITORING
}

# ============================================================================
# MAIN: Run all tests
# ============================================================================
main() {
    header "Patroni HA Cluster - Verification and Failover Tests"
    log "Starting test suite on $(hostname) at $(date)"

    test_cluster_health
    test_replication_lag
    test_write_primary
    test_read_replicas
    show_monitoring_commands

    log ""
    log "To run failover tests (destructive), run individually:"
    log "  bash $0 switchover   - Test planned switchover"
    log "  bash $0 failover     - Simulate unplanned failover"
    log "  bash $0 reinstate    - Reinstate failed node"
}

# Allow running specific test functions
case "${1:-all}" in
    health)     test_cluster_health ;;
    lag)        test_replication_lag ;;
    write)      test_write_primary ;;
    read)       test_read_replicas ;;
    switchover) test_planned_switchover ;;
    failover)   test_unplanned_failover ;;
    reinstate)  test_reinstate_node ;;
    monitor)    show_monitoring_commands ;;
    all)        main ;;
    *)          echo "Usage: $0 [health|lag|write|read|switchover|failover|reinstate|monitor|all]" ;;
esac
