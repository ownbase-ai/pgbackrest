#!/bin/bash
set -euo pipefail

log() { echo "[postgres-pgbackrest] $*"; }

# ── Capture and scrub env vars that conflict with pgbackrest's env convention ─
# pgbackrest interprets every PGBACKREST_* env var as a config option. Capture
# our custom values into local vars, then unset before any pgbackrest call.
STANZA="${PGBACKREST_STANZA:-main}"
_REPO_HOST="${PGBACKREST_HOST:-pgbackrest}"
_SSH_KEY_B64="${PGBACKREST_SSH_KEY_B64:-}"
_SSH_KEY="${PGBACKREST_SSH_KEY:-}"
unset PGBACKREST_HOST PGBACKREST_SSH_KEY_B64 PGBACKREST_SSH_KEY

# ── SSH private key (injected by OwnBase secrets as env var) ─────────────────
# Accept the key either as plain text (_SSH_KEY) or base64-encoded (_SSH_KEY_B64).
# Base64 is preferred because YAML env values cannot contain literal newlines.
if [ -n "${_SSH_KEY_B64:-}" ]; then
    _RAW_KEY=$(printf '%s' "$_SSH_KEY_B64" | base64 -d)
elif [ -n "${_SSH_KEY:-}" ]; then
    _RAW_KEY="$_SSH_KEY"
else
    _RAW_KEY=""
fi

if [ -z "${_RAW_KEY:-}" ]; then
    log "WARNING: PGBACKREST_SSH_KEY_B64 (or PGBACKREST_SSH_KEY) is not set — WAL archiving to pgbackrest will fail."
    log "         Set it with: ownbasectl secrets set postgres PGBACKREST_SSH_KEY_B64=\$(base64 -w0 < ~/.ssh/pgbackrest_key)"
else
    SSH_DIR=/var/lib/postgresql/.ssh
    mkdir -p "$SSH_DIR"
    printf '%s\n' "$_RAW_KEY" > "$SSH_DIR/id_ed25519"
    chmod 600 "$SSH_DIR/id_ed25519"
    # Disable strict host checking for the pgbackrest container; communication
    # is internal to the Podman network and the channel is authenticated by key.
    cat > "$SSH_DIR/config" << EOF
Host ${_REPO_HOST}
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
repo1-host=${_REPO_HOST}
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
