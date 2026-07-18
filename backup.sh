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
log "Dumping PostgreSQL (core)..."
if docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" n8n-autoscaling-postgres-1 \
    pg_dump -U postgres -d n8n --format=custom --compress=6 \
    --exclude-table=binary_data \
    --exclude-table=execution_data \
    --exclude-table=execution_entity \
    --exclude-table=execution_metadata \
    --exclude-table=execution_annotations \
    > "$BACKUP_PATH/n8n-postgres-core.dump" 2>>"$LOG_FILE"; then
    CORE_SIZE=$(du -sh "$BACKUP_PATH/n8n-postgres-core.dump" | cut -f1)
    log "Core dump complete ($CORE_SIZE) — workflows, credentials, settings"
else
    log "ERROR: Core PostgreSQL dump failed!"
    ERRORS=$((ERRORS + 1))
fi

# 2. Total backup size
TOTAL_SIZE=$(du -sh "$BACKUP_PATH" | cut -f1)
log "Backup complete: $BACKUP_PATH ($TOTAL_SIZE, $BACKUP_TYPE)"

# 3. Cleanup old backups
# Only ever runs on a fully-clean run. A failed run can produce a truncated or missing dump,
# and purging by age would then delete the last KNOWN-GOOD copy before Drive has a
# replacement (happened 2026-07-18: a 4-error run removed the good 2026-07-10 set).

cleanup_old() {
    local dir="$1"
    local keep="$2"
    local count
    count=$(find "$dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    if [ "$count" -gt "$keep" ]; then
        find "$dir" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null \
            | sort -n | head -n -"$keep" | cut -d' ' -f2- | while read -r old; do
            log "Removing old backup: $old"
            rm -rf "$old"
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
