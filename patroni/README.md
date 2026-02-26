# Patroni Three-Node HA Cluster on Red Hat Enterprise Linux

## Overview

This guide provides a complete, step-by-step implementation of a **PostgreSQL High Availability cluster** using **Patroni** on **Red Hat Enterprise Linux 8/9** across three nodes.

---

## Architecture

```
                        ┌─────────────────────────────────┐
                        │    Virtual IP (VIP): 192.168.1.100  │
                        │    Managed by Keepalived            │
                        └──────────────┬──────────────────┘
                                       │
              ┌────────────────────────┼────────────────────────┐
              │                        │                        │
   ┌──────────▼──────────┐  ┌─────────▼───────────┐  ┌────────▼────────────┐
   │      pg-node1        │  │      pg-node2        │  │      pg-node3       │
   │   192.168.1.101      │  │   192.168.1.102      │  │   192.168.1.103     │
   │ ─────────────────── │  │ ─────────────────── │  │ ─────────────────── │
   │  HAProxy (5000/5001) │  │  HAProxy (5000/5001) │  │  HAProxy (5000/5001)│
   │  Keepalived          │  │  Keepalived          │  │  Keepalived         │
   │  Patroni             │  │  Patroni             │  │  Patroni            │
   │  PostgreSQL 15       │  │  PostgreSQL 15       │  │  PostgreSQL 15      │
   │  etcd (DCS)          │  │  etcd (DCS)          │  │  etcd (DCS)         │
   │ ─────────────────── │  │ ─────────────────── │  │ ─────────────────── │
   │  [PRIMARY]           │  │  [REPLICA]           │  │  [REPLICA]          │
   └─────────────────────┘  └─────────────────────┘  └─────────────────────┘

   Port Layout:
   ┌──────────────────────────────────────────────────────────────┐
   │  5000  - HAProxy → Primary only (Read/Write connections)     │
   │  5001  - HAProxy → Replicas only (Read-Only connections)     │
   │  5432  - PostgreSQL direct (per-node)                        │
   │  8008  - Patroni REST API (per-node)                         │
   │  2379  - etcd client                                         │
   │  2380  - etcd peer communication                             │
   │  7000  - HAProxy stats web UI                                │
   └──────────────────────────────────────────────────────────────┘
```

---

## Component Versions

| Component   | Version | Role                                         |
|-------------|---------|----------------------------------------------|
| RHEL        | 8 or 9  | Operating System                             |
| PostgreSQL  | 15      | Database engine                              |
| Patroni     | 3.x     | HA cluster manager                           |
| etcd        | 3.5.9   | Distributed Configuration Store (DCS)        |
| HAProxy     | 2.4+    | Load balancer / connection routing           |
| Keepalived  | 2.2+    | Virtual IP (VIP) failover                    |

---

## Node IP Addresses

| Node        | Hostname   | IP Address      | Role     |
|-------------|-----------|-----------------|----------|
| Node 1      | pg-node1  | 192.168.1.101   | Primary  |
| Node 2      | pg-node2  | 192.168.1.102   | Replica  |
| Node 3      | pg-node3  | 192.168.1.103   | Replica  |
| Virtual IP  | pg-vip    | 192.168.1.100   | VIP      |

> **Edit these IPs** in each script's CONFIGURATION section before running.

---

## Quick Start

Run these scripts **in order** on **all three nodes** (unless noted otherwise):

```bash
# On ALL nodes - one at a time, complete each step before next
bash patroni/scripts/01-prereqs.sh
bash patroni/scripts/02-etcd-setup.sh
bash patroni/scripts/03-postgresql-setup.sh
bash patroni/scripts/04-patroni-setup.sh       # Start NODE1 first, then NODE2/3
bash patroni/scripts/05-haproxy-keepalived-setup.sh

# Run on any node to test
bash patroni/scripts/06-test-failover.sh
```

---

## Step-by-Step Guide

### Step 1: Prerequisites (`01-prereqs.sh`)

**Run on:** NODE1, NODE2, NODE3

Configures the OS foundation for all cluster nodes:

- Sets unique hostnames (`pg-node1`, `pg-node2`, `pg-node3`)
- Updates `/etc/hosts` with all node IPs and the VIP
- Sets SELinux to permissive mode
- Configures firewall rules for all required ports
- Disables swap (required for PostgreSQL performance)
- Sets kernel parameters (`vm.swappiness`, `net.ipv4.ip_nonlocal_bind`)
- Installs and configures Chrony (NTP) for time sync
- Installs required packages (Python 3, gcc, etc.)
- Creates the `postgres` system user

```bash
# Edit the IP addresses at the top of the script first
vim patroni/scripts/01-prereqs.sh

# Run on NODE1
ssh root@192.168.1.101 "bash /path/to/01-prereqs.sh"

# Run on NODE2
ssh root@192.168.1.102 "bash /path/to/01-prereqs.sh"

# Run on NODE3
ssh root@192.168.1.103 "bash /path/to/01-prereqs.sh"
```

**After this step:** Exchange SSH keys between nodes manually:
```bash
# From NODE1, copy public key to other nodes
ssh-copy-id root@192.168.1.102
ssh-copy-id root@192.168.1.103
```

---

### Step 2: etcd Cluster (`02-etcd-setup.sh`)

**Run on:** NODE1, NODE2, NODE3 (start all within 2 minutes of each other)

Sets up a 3-node etcd cluster, which Patroni uses as its Distributed Configuration Store (DCS) for leader election and cluster state.

- Downloads and installs etcd 3.5.9
- Creates `etcd` system user and data directory
- Generates per-node etcd configuration (`/etc/etcd/etcd.conf`)
- Creates `etcd.service` systemd unit
- Starts and validates etcd cluster formation

```bash
# Start on all three nodes nearly simultaneously
# NODE1
ssh root@192.168.1.101 "bash /path/to/02-etcd-setup.sh" &
# NODE2
ssh root@192.168.1.102 "bash /path/to/02-etcd-setup.sh" &
# NODE3
ssh root@192.168.1.103 "bash /path/to/02-etcd-setup.sh" &
wait
```

**Validate etcd cluster:**
```bash
etcdctl --endpoints=http://192.168.1.101:2379,http://192.168.1.102:2379,http://192.168.1.103:2379 \
    endpoint health --write-out=table

# Expected output:
# +---------------------------+--------+-------------+-------+
# | ENDPOINT                  | HEALTH | TOOK        | ERROR |
# +---------------------------+--------+-------------+-------+
# | http://192.168.1.101:2379 | true   | 2.345678ms  |       |
# | http://192.168.1.102:2379 | true   | 3.123456ms  |       |
# | http://192.168.1.103:2379 | true   | 2.987654ms  |       |
# +---------------------------+--------+-------------+-------+
```

---

### Step 3: PostgreSQL Installation (`03-postgresql-setup.sh`)

**Run on:** NODE1, NODE2, NODE3

Installs PostgreSQL 15 from the official PGDG repository.

> **CRITICAL:** Do NOT run `initdb` or start the `postgresql-15.service`. Patroni manages database initialization.

- Installs PGDG YUM repository
- Installs `postgresql15-server`, `contrib`, `devel` packages
- Configures PATH for PostgreSQL binaries
- Creates PGDATA directory (owned by postgres user)
- Installs Python packages (`psycopg2-binary`, `python-etcd`)
- Disables the `postgresql-15` systemd service (Patroni controls it)
- Configures sudoers for the postgres user

---

### Step 4: Patroni Setup (`04-patroni-setup.sh`)

**Run on:** NODE1 first, then NODE2 and NODE3

Installs Patroni and generates its configuration. NODE1 initializes the cluster; NODE2 and NODE3 join as replicas via `pg_basebackup`.

**Key configuration sections in `/etc/patroni/patroni.yml`:**

| Section | Purpose |
|---------|---------|
| `scope` | Cluster name (must match on all nodes) |
| `etcd3` | DCS connection details |
| `restapi` | Per-node REST API bind address |
| `bootstrap.dcs` | Cluster-wide PostgreSQL parameters |
| `bootstrap.pg_hba` | `pg_hba.conf` entries |
| `postgresql` | Per-node listen address, data_dir, auth |
| `tags` | Election behavior (nofailover, noloadbalance) |

```bash
# Start NODE1 first (becomes primary)
ssh root@192.168.1.101 "bash /path/to/04-patroni-setup.sh"

# Wait 30 seconds, then start NODE2 and NODE3
sleep 30
ssh root@192.168.1.102 "bash /path/to/04-patroni-setup.sh" &
ssh root@192.168.1.103 "bash /path/to/04-patroni-setup.sh" &
wait
```

**Verify cluster after all nodes start:**
```bash
patronictl -c /etc/patroni/patroni.yml list

# Expected output:
# + Cluster: postgres-ha (7234567890123456789) ------+----+-----------+
# | Member   | Host            | Role    | State   | TL | Lag in MB |
# +----------+-----------------+---------+---------+----+-----------+
# | pg-node1 | 192.168.1.101:5432 | Leader | running |  1 |           |
# | pg-node2 | 192.168.1.102:5432 | Replica | running |  1 |         0 |
# | pg-node3 | 192.168.1.103:5432 | Replica | running |  1 |         0 |
# +----------+-----------------+---------+---------+----+-----------+
```

---

### Step 5: HAProxy + Keepalived (`05-haproxy-keepalived-setup.sh`)

**Run on:** NODE1, NODE2, NODE3

Sets up connection routing and Virtual IP management.

**HAProxy** uses Patroni's REST API health endpoints:
- `/primary` → HTTP 200 only on the current Patroni leader
- `/replica` → HTTP 200 only on replicas

**Keepalived** uses VRRP to manage the VIP:
- NODE1 starts with the highest priority (110) and holds the VIP initially
- If NODE1's Patroni primary check fails, VIP floats to NODE2 (priority 100) or NODE3 (priority 90)

```bash
# Run on all nodes
for IP in 192.168.1.101 192.168.1.102 192.168.1.103; do
    ssh root@${IP} "bash /path/to/05-haproxy-keepalived-setup.sh"
done
```

**Verify:**
```bash
# Check VIP is assigned
ip addr show eth0 | grep 192.168.1.100

# Test R/W connection via VIP
psql -h 192.168.1.100 -p 5000 -U postgres -c "SELECT pg_is_in_recovery();"
# Should return: f (false = primary)

# Test read-only connection via VIP
psql -h 192.168.1.100 -p 5001 -U postgres -c "SELECT pg_is_in_recovery();"
# Should return: t (true = replica)

# HAProxy Stats UI
# http://192.168.1.100:7000/stats
```

---

### Step 6: Testing and Validation (`06-test-failover.sh`)

**Run on:** Any node

Validates the entire cluster setup and tests failover scenarios.

```bash
# Full validation suite
bash patroni/scripts/06-test-failover.sh all

# Individual tests
bash patroni/scripts/06-test-failover.sh health     # Cluster health check
bash patroni/scripts/06-test-failover.sh lag        # Replication lag
bash patroni/scripts/06-test-failover.sh write      # Write via VIP
bash patroni/scripts/06-test-failover.sh read       # Read from replica

# Failover tests (use with caution)
bash patroni/scripts/06-test-failover.sh switchover  # Planned switchover
bash patroni/scripts/06-test-failover.sh failover    # Simulate crash

# Monitoring reference
bash patroni/scripts/06-test-failover.sh monitor
```

---

## Connection Strings

After the full setup, applications connect through the VIP:

```
# Read-Write (primary only) - use for INSERT/UPDATE/DELETE
postgresql://postgres:StrongPostgresPassword123!@192.168.1.100:5000/mydb

# Read-Only (replica load-balanced) - use for SELECT
postgresql://postgres:StrongPostgresPassword123!@192.168.1.100:5001/mydb
```

---

## Day-2 Operations

### Planned Switchover (no data loss)
```bash
patronictl -c /etc/patroni/patroni.yml switchover postgres-ha
```

### Emergency Failover
```bash
patronictl -c /etc/patroni/patroni.yml failover postgres-ha
```

### Pause Auto-Failover (for maintenance)
```bash
patronictl -c /etc/patroni/patroni.yml pause postgres-ha
# ... perform maintenance ...
patronictl -c /etc/patroni/patroni.yml resume postgres-ha
```

### Rolling Restart (safe, no downtime)
```bash
patronictl -c /etc/patroni/patroni.yml restart postgres-ha
```

### Reinitialize a Failed Replica
```bash
patronictl -c /etc/patroni/patroni.yml reinit postgres-ha pg-node2
```

### Edit Cluster-Wide Configuration
```bash
patronictl -c /etc/patroni/patroni.yml edit-config postgres-ha
```

---

## Troubleshooting

### Patroni won't start
```bash
journalctl -fu patroni
cat /var/log/patroni/patroni.log
# Common causes: etcd unreachable, wrong IP in config, PGDATA permissions
```

### Split-brain prevention
Patroni uses etcd's distributed lock. If etcd quorum is lost (less than 2 nodes), Patroni demotes the primary to prevent split-brain. The cluster goes into read-only mode.

### etcd cluster unhealthy
```bash
# Check etcd on each node
systemctl status etcd
journalctl -fu etcd
# Restart etcd (data is persistent)
systemctl restart etcd
```

### Replica not replicating
```bash
# Check replication slot status on primary
psql -U postgres -c "SELECT * FROM pg_replication_slots;"
# Reinitialize if needed
patronictl -c /etc/patroni/patroni.yml reinit postgres-ha pg-node2 --force
```

### HAProxy shows all backends DOWN
```bash
# Check Patroni REST API manually
curl -v http://192.168.1.101:8008/primary
curl -v http://192.168.1.101:8008/replica
# Verify HAProxy config
haproxy -c -f /etc/haproxy/haproxy.cfg
```

---

## Security Hardening (Production Checklist)

- [ ] Enable TLS for etcd peer and client communication
- [ ] Enable TLS for Patroni REST API
- [ ] Enable `scram-sha-256` for all PostgreSQL connections
- [ ] Set SELinux to `enforcing` with proper policies
- [ ] Restrict firewall rules to specific source IPs
- [ ] Use strong, unique passwords (change defaults in scripts)
- [ ] Enable PostgreSQL SSL (`ssl = on`)
- [ ] Configure pg_hba.conf with specific application user CIDRs
- [ ] Set up log rotation and centralized log shipping
- [ ] Enable `synchronous_mode: true` for zero data loss (RPO=0)
- [ ] Configure proper WAL archiving (S3/NFS/etc.) for PITR

---

## File Reference

```
patroni/
├── README.md                          # This guide
├── scripts/
│   ├── 01-prereqs.sh                  # OS prerequisites (all nodes)
│   ├── 02-etcd-setup.sh               # etcd cluster setup (all nodes)
│   ├── 03-postgresql-setup.sh         # PostgreSQL installation (all nodes)
│   ├── 04-patroni-setup.sh            # Patroni install + config (all nodes)
│   ├── 05-haproxy-keepalived-setup.sh # HAProxy + VIP setup (all nodes)
│   └── 06-test-failover.sh            # Testing and monitoring
└── config/
    └── (configuration files generated by scripts at runtime)
```
