#!/bin/bash
set -euo pipefail

log() { echo "[pgbackrest] $*"; }

# ── SSH host keys ────────────────────────────────────────────────────────────
ssh-keygen -A -q

# Use port 2222: port 22 requires CAP_NET_BIND_SERVICE which OwnBase drops.
cat > /etc/ssh/sshd_config.d/pgbackrest.conf << 'EOF'
Port 2222
PermitRootLogin no
AllowUsers pgbackrest
PasswordAuthentication no
PubkeyAuthentication yes
EOF

# ── Authorized key (injected by OwnBase secrets as env var) ─────────────────
if [ -z "${PGBACKREST_CLIENT_PUBKEY:-}" ]; then
    log "WARNING: PGBACKREST_CLIENT_PUBKEY is not set — the postgres container cannot connect via SSH."
    log "         Set it with: ownbasectl secrets set pgbackrest PGBACKREST_CLIENT_PUBKEY=..."
else
    # .ssh/ and authorized_keys are root-owned (Dockerfile), so root in the
    # container can write here even with CAP_DAC_OVERRIDE dropped.
    printf '%s\n' "$PGBACKREST_CLIENT_PUBKEY" > /home/pgbackrest/.ssh/authorized_keys
    log "SSH authorized key installed."
fi

# ── pgbackrest.conf (generated from env) ────────────────────────────────────
STANZA="${PGBACKREST_STANZA:-main}"
PG_HOST="${PGBACKREST_PG_HOST:-postgres}"
PG_PORT="${PGBACKREST_PG_PORT:-5432}"
PG_PATH="${PGBACKREST_PG_PATH:-/var/lib/postgresql/data}"
PG_USER="${PGBACKREST_PG_USER:-postgres}"
RETENTION_FULL="${PGBACKREST_RETENTION_FULL:-2}"
RETENTION_DIFF="${PGBACKREST_RETENTION_DIFF:-14}"

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
pg1-host=${PG_HOST}
pg1-host-user=${PG_USER}
pg1-path=${PG_PATH}
pg1-port=${PG_PORT}
EOF
else
    log "Configuring local repository: /var/lib/pgbackrest"
    cat > /etc/pgbackrest/pgbackrest.conf << EOF
[global]
repo1-path=/var/lib/pgbackrest
repo1-retention-full=${RETENTION_FULL}
repo1-retention-diff=${RETENTION_DIFF}
log-level-console=info
log-path=/var/log/pgbackrest

[${STANZA}]
pg1-host=${PG_HOST}
pg1-host-user=${PG_USER}
pg1-path=${PG_PATH}
pg1-port=${PG_PORT}
EOF
fi

# CAP_CHOWN dropped; config is root-owned but pgbackrest reads it fine.

# ── Start sshd on port 2222 ──────────────────────────────────────────────────
log "Starting sshd on port 2222..."
/usr/sbin/sshd -D &
SSHD_PID=$!

# ── Wait for postgres ────────────────────────────────────────────────────────
log "Waiting for postgres at ${PG_HOST}:${PG_PORT}..."
ATTEMPTS=0
until pg_isready -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -q; do
    ATTEMPTS=$((ATTEMPTS + 1))
    if [ "$ATTEMPTS" -ge 60 ]; then
        log "ERROR: postgres did not become ready after 5 minutes."
        exit 1
    fi
    sleep 5
done
log "Postgres is ready."

# ── Stanza create (idempotent) ───────────────────────────────────────────────
# Run pgbackrest as root — OwnBase drops all capabilities (DropCapability=ALL)
# so su/runuser cannot switch users. pgbackrest works fine as root; the repo
# directory is pre-owned accordingly.
log "Creating stanza '${STANZA}'..."
pgbackrest --stanza="${STANZA}" stanza-create 2>&1 | \
    sed 's/^/[pgbackrest] /' || log "Stanza-create returned non-zero (may already exist; continuing)."

# ── Initial full backup if none exists ──────────────────────────────────────
SNAPSHOT_COUNT=$(pgbackrest --stanza="${STANZA}" info --output=text 2>/dev/null | \
    grep -c "full backup" || true)
if [ "$SNAPSHOT_COUNT" -eq 0 ]; then
    log "No backups found — running initial full backup..."
    pgbackrest --stanza="${STANZA}" backup --type=full 2>&1 | \
        sed 's/^/[pgbackrest] /'
    log "Initial backup complete."
fi

# ── Scheduled backups (weekly full, daily incremental) ──────────────────────
FULL_INTERVAL="${PGBACKREST_FULL_INTERVAL_SECONDS:-$((7 * 24 * 3600))}"
INCR_INTERVAL="${PGBACKREST_INCR_INTERVAL_SECONDS:-$((24 * 3600))}"

backup_loop() {
    local type="$1"
    local interval="$2"
    sleep "$interval"
    while true; do
        log "Running scheduled ${type} backup..."
        pgbackrest --stanza="${STANZA}" backup --type="${type}" 2>&1 | \
            sed 's/^/[pgbackrest] /' || log "${type} backup failed (will retry next cycle)."
        sleep "$interval"
    done
}

backup_loop full  "$FULL_INTERVAL"  &
backup_loop incr  "$INCR_INTERVAL"  &

log "pgBackRest repository host ready. Stanza: ${STANZA}, repo: $(grep 'repo1-path\|repo1-type' /etc/pgbackrest/pgbackrest.conf | head -1)"
wait "$SSHD_PID"
