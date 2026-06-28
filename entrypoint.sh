#!/bin/bash
set -euo pipefail

log() { echo "[pgbackrest] $*"; }

# ── Capture and scrub env vars that conflict with pgbackrest's env convention ─
# pgbackrest interprets every PGBACKREST_* env var as a config option
# (e.g. PGBACKREST_PG_HOST → pg-host, which is invalid because it needs an
# index like pg1-host). Capture our custom values into local vars, then unset
# to prevent pgbackrest from seeing them as config options.
_CLIENT_PUBKEY="${PGBACKREST_CLIENT_PUBKEY:-}"
unset PGBACKREST_CLIENT_PUBKEY

# ── SSH host keys ────────────────────────────────────────────────────────────
ssh-keygen -A -q

# Use port 2222: port 22 requires CAP_NET_BIND_SERVICE which OwnBase drops.
cat > /etc/ssh/sshd_config.d/pgbackrest.conf << 'EOF'
Port 2222
PermitRootLogin no
AllowUsers pgbackrest
PasswordAuthentication no
PubkeyAuthentication yes
# Disable privilege separation: the container provides its own isolation
# and CAP_SYS_CHROOT is not available with DropCapability=ALL + SETUID/SETGID.
UsePrivilegeSeparation no
EOF

# ── Authorized key (injected by OwnBase secrets as env var) ─────────────────
if [ -z "${_CLIENT_PUBKEY:-}" ]; then
    log "WARNING: PGBACKREST_CLIENT_PUBKEY is not set — the postgres container cannot connect via SSH."
    log "         Set it with: ownbasectl secrets set pgbackrest PGBACKREST_CLIENT_PUBKEY=..."
else
    mkdir -p /home/pgbackrest/.ssh
    printf '%s\n' "$_CLIENT_PUBKEY" > /home/pgbackrest/.ssh/authorized_keys
    # The container runs with DropCapability=ALL (no CAP_CHOWN), so we cannot
    # chown the file to pgbackrest. OpenSSH accepts authorized_keys owned by
    # root as long as it is not group/world writable; chmod 600 satisfies that.
    chmod 600 /home/pgbackrest/.ssh/authorized_keys
    log "SSH authorized key installed."
fi

# ── pgbackrest.conf (repo-host only — no pg1-host here) ─────────────────────
# This container is the repository host only. It stores and serves backups.
# The PostgreSQL container is the backup CLIENT and initiates all operations
# (stanza-create, archive-push, backup) by SSHing INTO this container.
# No pg1-host is needed in this config.
STANZA="${PGBACKREST_STANZA:-main}"
RETENTION_FULL="${PGBACKREST_RETENTION_FULL:-2}"
RETENTION_DIFF="${PGBACKREST_RETENTION_DIFF:-14}"

# Fix log dir permissions: run as root, chown log dir to pgbackrest
chown pgbackrest:pgbackrest /var/log/pgbackrest 2>/dev/null || true
chmod 750 /var/log/pgbackrest 2>/dev/null || true

if [ -n "${PGBACKREST_S3_BUCKET:-}" ]; then
    log "Configuring S3 repository: s3://${PGBACKREST_S3_BUCKET}"
    cat > /etc/pgbackrest/pgbackrest.conf << EOF
[global]
repo1-type=s3
repo1-path=${PGBACKREST_S3_PATH:-/pgbackrest}
repo1-s3-bucket=${PGBACKREST_S3_BUCKET}
repo1-s3-region=${PGBACKREST_S3_REGION:-us-east-1}
repo1-s3-key=${PGBACKREST_S3_KEY:-}
repo1-s3-key-secret=${PGBACKREST_S3_SECRET:-}
repo1-retention-full=${RETENTION_FULL}
repo1-retention-diff=${RETENTION_DIFF}
log-level-console=info
log-path=/var/log/pgbackrest

[${STANZA}]
EOF
else
    log "Configuring local repository: /var/lib/pgbackrest"
    # Ensure repo dir is owned by pgbackrest so pgbackrest (running as
    # pgbackrest via SSH) can write to it.
    chown pgbackrest:pgbackrest /var/lib/pgbackrest 2>/dev/null || true
    cat > /etc/pgbackrest/pgbackrest.conf << EOF
[global]
repo1-path=/var/lib/pgbackrest
repo1-retention-full=${RETENTION_FULL}
repo1-retention-diff=${RETENTION_DIFF}
log-level-console=info
log-path=/var/log/pgbackrest

[${STANZA}]
EOF
fi

log "Repository host ready. Starting sshd on port 2222..."
exec /usr/sbin/sshd -D
