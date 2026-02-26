#!/bin/bash
# =============================================================================
# Script: 01-prereqs.sh
# Description: Step 1 - Prerequisites and system preparation for all three nodes
# Run this script on: NODE1, NODE2, NODE3
# OS: Red Hat Enterprise Linux 8/9
# =============================================================================

set -euo pipefail

# ---- CONFIGURATION (Edit these values to match your environment) ----
NODE1_IP="192.168.1.101"
NODE2_IP="192.168.1.102"
NODE3_IP="192.168.1.103"
NODE1_HOSTNAME="pg-node1"
NODE2_HOSTNAME="pg-node2"
NODE3_HOSTNAME="pg-node3"
VIP="192.168.1.100"            # Virtual IP managed by Keepalived
PG_VERSION="15"
POSTGRES_PASSWORD="StrongPostgresPassword123!"
REPLICATION_PASSWORD="StrongReplicationPassword123!"
PATRONI_SCOPE="postgres-ha"   # Cluster name in Patroni

# ---- DETECT CURRENT NODE ----
CURRENT_IP=$(hostname -I | awk '{print $1}')

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "=== Step 1: System Prerequisites Setup ==="
log "Current node IP: ${CURRENT_IP}"

# ---- 1.1 SET HOSTNAME ----
log "--- 1.1 Setting hostname ---"
if [ "${CURRENT_IP}" = "${NODE1_IP}" ]; then
    hostnamectl set-hostname "${NODE1_HOSTNAME}"
elif [ "${CURRENT_IP}" = "${NODE2_IP}" ]; then
    hostnamectl set-hostname "${NODE2_HOSTNAME}"
elif [ "${CURRENT_IP}" = "${NODE3_IP}" ]; then
    hostnamectl set-hostname "${NODE3_HOSTNAME}"
fi
log "Hostname set to: $(hostname)"

# ---- 1.2 UPDATE /etc/hosts ----
log "--- 1.2 Configuring /etc/hosts ---"
cat >> /etc/hosts <<EOF

# Patroni HA Cluster nodes
${NODE1_IP}    ${NODE1_HOSTNAME}
${NODE2_IP}    ${NODE2_HOSTNAME}
${NODE3_IP}    ${NODE3_HOSTNAME}
${VIP}         pg-vip
EOF
log "/etc/hosts updated."

# ---- 1.3 DISABLE SELINUX (or set to permissive for production tuning) ----
log "--- 1.3 Configuring SELinux ---"
# For production, configure SELinux policies instead of disabling.
# Here we set permissive for initial setup.
setenforce 0
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
log "SELinux set to permissive."

# ---- 1.4 DISABLE FIREWALLD or configure rules ----
log "--- 1.4 Configuring firewall rules ---"
systemctl enable --now firewalld || true

# PostgreSQL
firewall-cmd --permanent --add-port=5432/tcp
# Patroni REST API
firewall-cmd --permanent --add-port=8008/tcp
# etcd client
firewall-cmd --permanent --add-port=2379/tcp
# etcd peer
firewall-cmd --permanent --add-port=2380/tcp
# HAProxy stats
firewall-cmd --permanent --add-port=7000/tcp
# HAProxy primary (read-write)
firewall-cmd --permanent --add-port=5000/tcp
# HAProxy replicas (read-only)
firewall-cmd --permanent --add-port=5001/tcp

firewall-cmd --reload
log "Firewall rules applied."

# ---- 1.5 DISABLE SWAP ----
log "--- 1.5 Disabling swap ---"
swapoff -a
sed -i '/swap/d' /etc/fstab
log "Swap disabled."

# ---- 1.6 SET KERNEL PARAMETERS ----
log "--- 1.6 Configuring kernel parameters ---"
cat > /etc/sysctl.d/99-patroni.conf <<EOF
# Network performance tuning for PostgreSQL
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_nonlocal_bind = 1
vm.overcommit_memory = 2
vm.swappiness = 1
EOF
sysctl --system
log "Kernel parameters applied."

# ---- 1.7 CONFIGURE NTP/CHRONY ----
log "--- 1.7 Configuring time synchronization ---"
dnf install -y chrony
systemctl enable --now chronyd
chronyc makestep || true
log "Chrony configured and running."

# ---- 1.8 INSTALL REQUIRED SYSTEM PACKAGES ----
log "--- 1.8 Installing system packages ---"
dnf install -y \
    epel-release \
    python3 \
    python3-pip \
    python3-devel \
    gcc \
    libpq-devel \
    wget \
    curl \
    net-tools \
    bind-utils \
    telnet \
    vim \
    git \
    jq
log "System packages installed."

# ---- 1.9 CONFIGURE SSH KEY-BASED AUTH BETWEEN NODES ----
log "--- 1.9 Generating SSH key (copy manually to other nodes) ---"
if [ ! -f /root/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -b 4096 -N "" -f /root/.ssh/id_rsa
    log "SSH key generated at /root/.ssh/id_rsa"
    log "ACTION REQUIRED: Copy /root/.ssh/id_rsa.pub to authorized_keys on all other nodes."
    cat /root/.ssh/id_rsa.pub
fi

# ---- 1.10 CREATE POSTGRES SYSTEM USER ----
log "--- 1.10 Creating postgres system user ---"
id postgres &>/dev/null || useradd -m -s /bin/bash -d /var/lib/pgsql postgres
log "postgres user ready."

log ""
log "=== Step 1 Complete: Prerequisites installed on $(hostname) ==="
log ""
log "NEXT STEPS:"
log "  1. Run this script on all other nodes (NODE2, NODE3)"
log "  2. Exchange SSH keys between nodes"
log "  3. Proceed to: 02-etcd-setup.sh"
