# ownbase-ai/pgbackrest

Two-container pgBackRest setup for [OwnBase](https://github.com/ownbase-ai/ownbase):

- **Root image** (`context: "."`) — pgBackRest repository host. Runs `sshd` and owns the backup repository. Schedules weekly full and daily incremental base backups.
- **Postgres image** (`context: "postgres"`) — `postgres:17` with the pgBackRest client installed. Archives WAL to the repository host over SSH so every transaction is recoverable.

Both images are built from this single mirror in OwnBase, using the `context:` field to select which Dockerfile to build.

## Why two containers instead of one

pgBackRest's repo-host model separates the backup repository from the database server. The repository host:

- holds all backup data independently of Postgres
- can restore to a new Postgres container without the old one being present
- lets the backup schedule run without touching the Postgres process

## Prerequisites

Both containers communicate over SSH. You need to generate a key pair once and store each half as an OwnBase secret.

```bash
ssh-keygen -t ed25519 -f pgbackrest-key -N ""

# Private key → injected into the postgres container
ownbasectl secrets set postgres \
    PGBACKREST_SSH_KEY="$(cat pgbackrest-key)" \
    POSTGRES_PASSWORD=your-db-password

# Public key → injected into the pgbackrest container (authorized_keys)
ownbasectl secrets set pgbackrest \
    PGBACKREST_CLIENT_PUBKEY="$(cat pgbackrest-key.pub)"

rm pgbackrest-key pgbackrest-key.pub
```

## ownbase.yaml

```yaml
services:
  pgbackrest:
    mirror: https://github.com/ownbase-ai/pgbackrest
    context: "."
    volumes:
      - name: repo
        mount: /var/lib/pgbackrest
        backup: ["."]        # restic snapshots the pgbackrest repo itself

  postgres:
    mirror: https://github.com/ownbase-ai/pgbackrest
    context: "postgres"
    port: 5432
    volumes:
      - name: data
        mount: /var/lib/postgresql/data
        # no backup: here — pgbackrest handles postgres backup
    requires:
      - pgbackrest
```

`postgres` declares `requires: [pgbackrest]` so the daemon starts the repository host first. The postgres container waits for pgbackrest to be reachable via SSH before accepting archive commands.

The pgbackrest `repo` volume is included in OwnBase's restic snapshots as a second line of defense. For production, consider using S3 directly (see below) so the backup repository lives off-machine without relying on restic.

## Connecting your app

Other services connect to Postgres by declaring `requires: [postgres]`. OwnBase puts them on the same Podman network, so the hostname `postgres` resolves automatically.

```yaml
services:
  myapp:
    source: services/myapp
    port: 8080
    domain: myapp.example.com
    requires:
      - postgres
```

Store the connection string as a secret:

```bash
ownbasectl secrets set myapp \
    DB_URL=postgres://postgres:your-db-password@postgres:5432/myapp
```

## Environment variables

### pgbackrest container

| Variable | Default | Description |
|---|---|---|
| `PGBACKREST_CLIENT_PUBKEY` | required | SSH public key for the postgres container |
| `PGBACKREST_STANZA` | `main` | pgBackRest stanza name |
| `PGBACKREST_PG_HOST` | `postgres` | Postgres container hostname |
| `PGBACKREST_PG_PORT` | `5432` | Postgres port |
| `PGBACKREST_PG_PATH` | `/var/lib/postgresql/data` | Postgres data directory |
| `PGBACKREST_PG_USER` | `postgres` | OS user that owns the Postgres data directory |
| `PGBACKREST_RETENTION_FULL` | `2` | Number of full backups to retain |
| `PGBACKREST_RETENTION_DIFF` | `14` | Number of differential backups to retain |
| `PGBACKREST_FULL_INTERVAL_SECONDS` | `604800` (7 days) | Full backup cadence |
| `PGBACKREST_INCR_INTERVAL_SECONDS` | `86400` (1 day) | Incremental backup cadence |

#### S3 repository (optional)

Set these to store backups in S3 instead of (or in addition to) the local volume:

| Variable | Description |
|---|---|
| `PGBACKREST_S3_BUCKET` | S3 bucket name; triggers S3 mode when set |
| `PGBACKREST_S3_REGION` | AWS region (default `us-east-1`) |
| `PGBACKREST_S3_KEY` | AWS access key ID |
| `PGBACKREST_S3_SECRET` | AWS secret access key |
| `PGBACKREST_S3_PATH` | Path prefix inside the bucket (default `/pgbackrest`) |

```bash
ownbasectl secrets set pgbackrest \
    PGBACKREST_CLIENT_PUBKEY="$(cat pgbackrest-key.pub)" \
    PGBACKREST_S3_BUCKET=my-bucket \
    PGBACKREST_S3_REGION=us-east-1 \
    PGBACKREST_S3_KEY=AKIA... \
    PGBACKREST_S3_SECRET=...
```

With S3 mode active, you can omit `backup: ["."]` from the pgbackrest volume — the repo lives off-machine and restic doesn't need to touch it.

### postgres container

| Variable | Default | Description |
|---|---|---|
| `PGBACKREST_SSH_KEY` | required | SSH private key for connecting to the pgbackrest container |
| `PGBACKREST_STANZA` | `main` | Must match the pgbackrest container's stanza |
| `PGBACKREST_HOST` | `pgbackrest` | Hostname of the pgbackrest container |
| `POSTGRES_PASSWORD` | required | Postgres superuser password (standard postgres image var) |

## Backup operations

### Check status

```bash
# SSH into the pgbackrest container and run:
podman exec ownbase-pgbackrest pgbackrest --stanza=main info
```

### Manual backup

```bash
# Full backup
podman exec ownbase-pgbackrest \
    su -s /bin/bash pgbackrest -c "pgbackrest --stanza=main backup --type=full"

# Incremental backup
podman exec ownbase-pgbackrest \
    su -s /bin/bash pgbackrest -c "pgbackrest --stanza=main backup --type=incr"
```

### Point-in-time recovery

Stop the postgres container first, then restore to a target time:

```bash
podman stop ownbase-postgres

podman exec ownbase-pgbackrest pgbackrest \
    --stanza=main \
    --type=time \
    --target="2026-06-26 03:00:00" \
    --target-action=promote \
    restore

podman start ownbase-postgres
```

### Full rebuild on a fresh machine

On a new machine after an OwnBase reinstall, restore the pgbackrest volume from the restic backup (via `ownbased --rebuild`), then start the services normally. The pgbackrest repository host will have its repository intact, and Postgres will recover from the latest base backup + WAL on first start.

If using S3, no restic restore is needed for the repository — start the services and the pgbackrest container reconnects to S3 directly.

## How archiving works

```
postgres container                     pgbackrest container
──────────────────                     ────────────────────
archive_command runs on each WAL  →→→  SSH → archive-push → repo
                                       ↑
                                  scheduled backup
                                  (full weekly, incr daily)
                                  connects to postgres via SSH
                                  and pg_basebackup protocol
```

The postgres container never touches the backup repository directly. All backup data flows through the pgbackrest container, which is the single point of truth for recovery.
