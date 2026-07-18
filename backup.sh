#!/bin/bash
# n8n Automated Backup Script
# Backs up: PostgreSQL core dump ONLY (workflows, credentials, settings).
# The core dump is uploaded offsite to Google Drive by n8n workflow EIl6GTfolBXwJZAd.
# Retention: 1 daily, 1 weekly. Google Drive is the ONLY backup destination; the local
# file exists solely because the n8n workflow uploads by reading it off disk (/backups is
# mounted read-only into n8n, so n8n cannot clean up after itself). Each run replaces it.
#
# Deliberately does NOT back up the n8n volumes, the config dir, or a full DB dump:
# whole-VPS snapshots already cover on-server recovery, and tarring anything n8n writes
# into (.n8n/storage) is what caused the 2026-07-18 recursive-growth disk-full incident.

set -uo pipefail

BACKUP_DIR="/backups"
COMPOSE_DIR="/opt/n8n-autoscaling"
DATE=$(date +%Y-%m-%d)
DAY_OF_WEEK=$(date +%u)  # 1=Monday, 7=Sunday
LOG_FILE="$BACKUP_DIR/backup.log"
ERRORS=0

# Load Postgres password from .env
POSTGRES_PASSWORD=$(grep '^POSTGRES_PASSWORD=' "$COMPOSE_DIR/.env" | cut -d= -f2)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "=== Starting backup $DATE ==="

# Determine backup target (weekly on Sundays)
if [ "$DAY_OF_WEEK" -eq 7 ]; then
    TARGET_DIR="$BACKUP_DIR/weekly"
    BACKUP_TYPE="weekly"
else
    TARGET_DIR="$BACKUP_DIR/daily"
    BACKUP_TYPE="daily"
fi

BACKUP_PATH="$TARGET_DIR/$DATE"
mkdir -p "$BACKUP_PATH"

# 1a. Core PostgreSQL dump (workflows, credentials, settings — small, uploaded to Google Drive)
#
# --exclude-table-data (NOT --exclude-table): keeps every table's DDL, indexes and constraints
# and drops only the ROWS. --exclude-table omits the table entirely, and because the migrations
# table restores fully populated, n8n would boot believing the schema is current and never
# recreate them — the restored instance could not execute a single workflow. (Found by the
# 2026-07-18 adversarial review; verified on the artifact: 218 tables, no execution_entity.)
#
# Written to a .tmp and only promoted after it validates, so a failed run can never truncate
# or replace the previous good dump — the shell's > redirect creates the target file before
# pg_dump runs, so writing in place would leave a 0-byte artifact the workflow would upload.
DUMP_FINAL="$BACKUP_PATH/n8n-postgres-core.dump"
DUMP_TMP="$BACKUP_PATH/.n8n-postgres-core.dump.tmp"

log "Dumping PostgreSQL (core)..."
if docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" n8n-autoscaling-postgres-1 \
    pg_dump -U postgres -d n8n --format=custom --compress=6 \
    --exclude-table-data=binary_data \
    --exclude-table-data=execution_data \
    --exclude-table-data=execution_entity \
    --exclude-table-data=execution_metadata \
    --exclude-table-data=execution_annotations \
    > "$DUMP_TMP" 2>>"$LOG_FILE"; then

    # Validate before promoting: the archive must parse, and must actually contain the things
    # a restore depends on. A dump that parses but is missing credentials is worse than no dump,
    # because it looks like a backup.
    docker cp "$DUMP_TMP" n8n-autoscaling-postgres-1:/tmp/verify.dump >/dev/null 2>>"$LOG_FILE"
    TOC=$(docker exec n8n-autoscaling-postgres-1 pg_restore --list /tmp/verify.dump 2>>"$LOG_FILE")
    TOC_RC=$?
    docker exec n8n-autoscaling-postgres-1 rm -f /tmp/verify.dump 2>/dev/null

    DUMP_BYTES=$(stat -c %s "$DUMP_TMP" 2>/dev/null || echo 0)
    HAS_CREDS=$(printf '%s' "$TOC" | grep -c 'TABLE public credentials_entity')
    HAS_WF=$(printf '%s' "$TOC" | grep -c 'TABLE public workflow_entity')
    HAS_EXEC=$(printf '%s' "$TOC" | grep -c 'TABLE public execution_entity')

    if [ "$TOC_RC" -ne 0 ]; then
        log "ERROR: core dump does not parse (pg_restore --list failed) — keeping previous dump"
        rm -f "$DUMP_TMP"
        ERRORS=$((ERRORS + 1))
    elif [ "$DUMP_BYTES" -lt 102400 ]; then
        log "ERROR: core dump implausibly small (${DUMP_BYTES} bytes) — keeping previous dump"
        rm -f "$DUMP_TMP"
        ERRORS=$((ERRORS + 1))
    elif [ "$HAS_CREDS" -eq 0 ] || [ "$HAS_WF" -eq 0 ] || [ "$HAS_EXEC" -eq 0 ]; then
        log "ERROR: core dump missing required schema (creds=$HAS_CREDS wf=$HAS_WF exec=$HAS_EXEC) — keeping previous dump"
        rm -f "$DUMP_TMP"
        ERRORS=$((ERRORS + 1))
    else
        mv -f "$DUMP_TMP" "$DUMP_FINAL"
        CORE_SIZE=$(du -sh "$DUMP_FINAL" | cut -f1)
        log "Core dump complete ($CORE_SIZE) — validated: workflows, credentials, full schema"

        # 1b. Restore manifest (~1KB). Ships to Drive beside the dump so the artifact is
        # self-describing under recovery pressure: version compatibility, integrity hash,
        # the exact restore commands, and where the decryption key lives.
        N8N_VER=$(docker exec n8n-autoscaling-n8n-1 n8n --version 2>/dev/null | tr -d '\r')
        PG_VER=$(docker exec n8n-autoscaling-postgres-1 postgres --version 2>/dev/null | awk '{print $3}')
        DUMP_SHA=$(sha256sum "$DUMP_FINAL" | cut -d' ' -f1)
        WF_COUNT=$(printf '%s' "$TOC" | grep -c 'TABLE public')

        cat > "$BACKUP_PATH/RESTORE.md" <<MANIFEST
# n8n restore manifest — $DATE

Produced by /opt/n8n-autoscaling/backup.sh on the dev VPS.

| | |
|---|---|
| Artifact | n8n-postgres-core.dump ($CORE_SIZE) |
| SHA-256 | $DUMP_SHA |
| n8n version | ${N8N_VER:-unknown} |
| Postgres | ${PG_VER:-unknown} |
| Tables in dump | $WF_COUNT |

## What is in it

Full schema (DDL, indexes, constraints) for every table, plus ROW DATA for everything
except binary_data, execution_data, execution_entity, execution_metadata and
execution_annotations — i.e. all workflows, credentials, settings, users, variables and
tags, with execution history deliberately dropped. Restores into an EMPTY database.

## Restore

    # 1. verify integrity first
    sha256sum -c <<<"$DUMP_SHA  n8n-postgres-core.dump"

    # 2. fresh postgres, empty db, then:
    pg_restore -U postgres -d n8n --no-owner --clean --if-exists n8n-postgres-core.dump

    # 3. set N8N_ENCRYPTION_KEY in the new instance's env BEFORE first boot (see below)
    # 4. start n8n on version ${N8N_VER:-unknown} or newer; it will run any pending migrations

## Credential decryption — REQUIRED

Credentials in this dump are AES-encrypted with N8N_ENCRYPTION_KEY. Without that exact
key they restore as named-but-unusable entries and every API-touching workflow stays
broken. The key is NOT in this backup, deliberately — it is kept apart so that access to
this Drive folder alone does not expose the credentials.

Key location: 1Password (VPS secret-loading system), mirrored to Mac ~/.env as
N8N_ENCRYPTION_KEY, and live at /opt/n8n-autoscaling/.env on the dev VPS.
Retrieve with: eval \$(get-secret N8N_ENCRYPTION_KEY)

## Not included

Docker/compose config (tracked in the /opt/n8n-autoscaling git repo), the n8n volumes
(community nodes; rebuildable), and execution history. Whole-VPS snapshots cover
on-server recovery; this artifact is the offsite second copy.
MANIFEST
        log "Restore manifest written (sha256 ${DUMP_SHA:0:12}…, n8n ${N8N_VER:-unknown})"
    fi
else
    log "ERROR: Core PostgreSQL dump failed!"
    rm -f "$DUMP_TMP"
    ERRORS=$((ERRORS + 1))
fi

# 2. Total backup size
TOTAL_SIZE=$(du -sh "$BACKUP_PATH" | cut -f1)
log "Backup complete: $BACKUP_PATH ($TOTAL_SIZE, $BACKUP_TYPE)"

# 3. Cleanup old backups
# Only ever runs on a fully-clean run. A failed run can produce a truncated or missing dump,
# and purging by age would then delete the last KNOWN-GOOD copy before Drive has a
# replacement (happened 2026-07-18: a 4-error run removed the good 2026-07-10 set).

# Sorts by the YYYY-MM-DD directory NAME, not by mtime. mtime is not a reliable proxy for
# backup age — overwriting a dump in place leaves the parent dir's mtime untouched, so an
# mtime sort once selected TODAY'S fresh dump for deletion (observed 2026-07-18).
# $DATE is additionally protected as a belt-and-suspenders guard.
cleanup_old() {
    local dir="$1"
    local keep="$2"
    local count
    count=$(find "$dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    if [ "$count" -gt "$keep" ]; then
        find "$dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
            | sort | head -n -"$keep" | while read -r old; do
            if [ "$old" = "$DATE" ]; then
                log "Refusing to remove today's backup: $dir/$old"
                continue
            fi
            log "Removing old backup: $dir/$old"
            rm -rf "${dir:?}/${old:?}"
        done
    fi
}

if [ "$ERRORS" -eq 0 ]; then
    log "Cleaning up old backups..."
    cleanup_old "$BACKUP_DIR/daily" 1
    cleanup_old "$BACKUP_DIR/weekly" 1
else
    log "SKIPPING cleanup: run had $ERRORS error(s) — refusing to purge known-good backups"
fi

# Disk usage summary
BACKUP_TOTAL=$(du -sh "$BACKUP_DIR" | cut -f1)
DISK_FREE=$(df -h / | tail -1 | awk '{print $4}')
log "Total backup storage: $BACKUP_TOTAL | Disk free: $DISK_FREE"

if [ "$ERRORS" -gt 0 ]; then
    log "=== Backup $DATE finished with $ERRORS error(s) ==="
    exit 1
else
    log "=== Backup $DATE finished successfully ==="
fi
