#!/bin/bash
set -euo pipefail

log() { echo "[postgres-pgbackrest] $*"; }

STANZA="${PGBACKREST_STANZA:-main}"
PGBACKREST_HOST="${PGBACKREST_HOST:-pgbackrest}"

# ── SSH private key (injected by OwnBase secrets as env var) ─────────────────
if [ -z "${PGBACKREST_SSH_KEY:-}" ]; then
    log "WARNING: PGBACKREST_SSH_KEY is not set — WAL archiving to pgbackrest will fail."
    log "         Set it with: ownbasectl secrets set postgres PGBACKREST_SSH_KEY=..."
else
    SSH_DIR=/var/lib/postgresql/.ssh
    mkdir -p "$SSH_DIR"
    printf '%s\n' "$PGBACKREST_SSH_KEY" > "$SSH_DIR/id_ed25519"
    chmod 600 "$SSH_DIR/id_ed25519"
    # Disable strict host checking for the pgbackrest container; communication
    # is internal to the Podman network and the channel is authenticated by key.
    cat > "$SSH_DIR/config" << EOF
Host ${PGBACKREST_HOST}
    StrictHostKeyChecking no
    Port 2222
    IdentityFile ~/.ssh/id_ed25519
    User pgbackrest
EOF
    chmod 600 "$SSH_DIR/config"
    # CAP_CHOWN is dropped by OwnBase; pre-create $SSH_DIR as postgres in the
    # Dockerfile so this chown is a no-op in practice.
    chown -R postgres:postgres "$SSH_DIR" 2>/dev/null || true
    log "SSH key for pgbackrest configured."
fi

# ── Rewrite pgbackrest.conf from env (stanza and host are configurable) ──────
cat > /etc/pgbackrest/pgbackrest.conf << EOF
[global]
repo1-host=${PGBACKREST_HOST}
repo1-host-user=pgbackrest
log-level-console=info
log-path=/var/log/pgbackrest

[${STANZA}]
pg1-path=/var/lib/postgresql/data
pg1-port=5432
EOF

# ── Archive init script (runs on first initdb, sets archive settings) ────────
# docker-entrypoint-initdb.d scripts run after initdb completes but before
# postgres accepts external connections, so postgresql.auto.conf is writable.
mkdir -p /docker-entrypoint-initdb.d
cat > /docker-entrypoint-initdb.d/10-pgbackrest-archive.sh << INITSCRIPT
#!/bin/bash
# Applied once on first initdb. Subsequent starts read from postgresql.auto.conf.
cat >> "\$PGDATA/postgresql.auto.conf" << 'PGCONF'
archive_mode = on
archive_command = 'pgbackrest --stanza=${STANZA} archive-push %p'
archive_timeout = 60
PGCONF
echo "[pgbackrest] Archive settings written to postgresql.auto.conf"
INITSCRIPT
chmod +x /docker-entrypoint-initdb.d/10-pgbackrest-archive.sh

log "Handing off to postgres entrypoint..."
exec docker-entrypoint.sh "$@"
