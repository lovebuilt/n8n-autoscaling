#!/bin/bash
# n8n Automated Backup Script
# Backs up: PostgreSQL (core + full), n8n volumes, config files
# Core dump (workflows/credentials only) → uploaded to Google Drive by n8n workflow
# Full dump (everything) → kept locally only for on-server recovery
# Retention: 7 daily, 4 weekly

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

# 1b. Full PostgreSQL dump (everything — kept locally only, NOT uploaded)
log "Dumping PostgreSQL (full)..."
if docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" n8n-autoscaling-postgres-1 \
    pg_dump -U postgres -d n8n --format=custom --compress=6 \
    > "$BACKUP_PATH/n8n-postgres-full.dump" 2>>"$LOG_FILE"; then
    FULL_SIZE=$(du -sh "$BACKUP_PATH/n8n-postgres-full.dump" | cut -f1)
    log "Full dump complete ($FULL_SIZE) — local retention only"
else
    log "ERROR: Full PostgreSQL dump failed!"
    ERRORS=$((ERRORS + 1))
fi

# 2. n8n volumes (community packages, configs)
log "Backing up n8n volumes..."
for vol in n8n-autoscaling_n8n_main n8n-autoscaling_n8n_webhook; do
    VOL_SHORT=$(echo "$vol" | sed 's/n8n-autoscaling_//')
    if docker run --rm -v "$vol":/source -v "$BACKUP_PATH":/backup alpine \
        tar czf "/backup/${VOL_SHORT}.tar.gz" -C /source . 2>>"$LOG_FILE"; then
        VOL_SIZE=$(du -sh "$BACKUP_PATH/${VOL_SHORT}.tar.gz" | cut -f1)
        log "Volume $VOL_SHORT backed up ($VOL_SIZE)"
    else
        log "ERROR: Volume $VOL_SHORT backup failed!"
        ERRORS=$((ERRORS + 1))
    fi
done

# 3. Config files (docker-compose, Dockerfiles, .env, etc.)
log "Backing up config files..."
if tar czf "$BACKUP_PATH/config.tar.gz" \
    --exclude='*.log' \
    --exclude='node_modules' \
    -C "$(dirname "$COMPOSE_DIR")" "$(basename "$COMPOSE_DIR")" 2>>"$LOG_FILE"; then
    CONFIG_SIZE=$(du -sh "$BACKUP_PATH/config.tar.gz" | cut -f1)
    log "Config backup complete ($CONFIG_SIZE)"
else
    log "ERROR: Config backup failed!"
    ERRORS=$((ERRORS + 1))
fi

# 4. Total backup size
TOTAL_SIZE=$(du -sh "$BACKUP_PATH" | cut -f1)
log "Backup complete: $BACKUP_PATH ($TOTAL_SIZE, $BACKUP_TYPE)"

# 5. Cleanup old backups
log "Cleaning up old backups..."

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

cleanup_old "$BACKUP_DIR/daily" 7
cleanup_old "$BACKUP_DIR/weekly" 4

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
