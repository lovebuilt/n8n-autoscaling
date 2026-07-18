#!/bin/bash
# n8n restore drill (F9) — runs ON THE dev VPS host as root, weekly.
#
# A backup nobody has restored is a hypothesis, not a backup. This restores the LATEST
# n8n core dump (the one backup.sh promotes and the workflow ships to Google Drive) into a
# THROWAWAY database, asserts the restore is plausibly complete (tables, workflows,
# credentials, migrations), then drops the throwaway. It NEVER touches the live `n8n`
# database — only a uniquely-named restore_drill_* DB it creates and drops.
#
# Why a host script and not an n8n workflow: n8n's Execute Command runs INSIDE the n8n
# container, which has neither the docker socket nor pg_restore, so it cannot restore
# anything. The restore has to run where the dump, docker, and pg_restore coexist — the host.
#
# FAILS (non-zero) if: no dump found, pg_restore errors, or any count is implausibly low
# (an empty/partial restore looks like a backup but is not). On failure it POSTs to the
# n8n Alert Relay webhook (→ Gmail) AND writes a /backups/.restore-drill-failed sentinel as
# a fallback for when n8n itself is down.

set -uo pipefail

COMPOSE_DIR="/opt/n8n-autoscaling"
BACKUP_DIR="/backups"
PG_CONTAINER="n8n-autoscaling-postgres-1"
DRILL_DB="restore_drill_$(date -u +%Y%m%d_%H%M%S)"
LOG_FILE="$BACKUP_DIR/restore-drill.log"
SENTINEL="$BACKUP_DIR/.restore-drill-failed"
ALERT_URL="http://100.91.209.32:5678/webhook/restore-drill-alert"

# Minimum plausible counts. Live at build time (2026-07-18): 111 tables, 187 workflows,
# 41 credentials, 216 migrations. Thresholds sit well below those so normal growth/shrink
# never false-alarms, but an empty or half-restored dump (≈0) trips every one.
MIN_TABLES=100
MIN_WORKFLOWS=100
MIN_CREDENTIALS=20
MIN_MIGRATIONS=200

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

fail() {
    local msg="$1"
    log "DRILL FAILED: $msg"
    echo "$(date -u +%F) FAILED: $msg (see $LOG_FILE)" > "$SENTINEL"
    # Best-effort immediate alert; the sentinel is the fallback if n8n is unreachable.
    curl -sS -m 15 -X POST -H 'Content-Type: application/json' \
        --data "$(printf '{"subject":"n8n restore drill FAILED","message":"%s\\n\\nHost: dev VPS\\nLog: %s"}' "$msg" "$LOG_FILE")" \
        "$ALERT_URL" >/dev/null 2>&1 && log "alert POSTed to relay" || log "alert POST failed (sentinel written)"
    exit 1
}

POSTGRES_PASSWORD=$(grep '^POSTGRES_PASSWORD=' "$COMPOSE_DIR/.env" | cut -d= -f2)
pex() { docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$PG_CONTAINER" "$@"; }
psql_scalar() { pex psql -U postgres -d "$1" -tAc "$2" 2>>"$LOG_FILE"; }

cleanup() {
    pex psql -U postgres -d postgres -c "DROP DATABASE IF EXISTS \"$DRILL_DB\";" >/dev/null 2>>"$LOG_FILE" \
        && log "throwaway db dropped: $DRILL_DB" || log "WARN: could not drop $DRILL_DB — check manually"
    pex rm -f /tmp/drill.dump >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "=== Starting restore drill ($DRILL_DB) ==="

# 1. Latest dump = newest core.dump under daily/ or weekly/ (by mtime).
DUMP=$(ls -t "$BACKUP_DIR"/daily/*/n8n-postgres-core.dump "$BACKUP_DIR"/weekly/*/n8n-postgres-core.dump 2>/dev/null | head -1)
[ -n "$DUMP" ] || fail "no core dump found under $BACKUP_DIR/{daily,weekly}"
log "restoring: $DUMP ($(du -h "$DUMP" | cut -f1))"

# 2. Copy the dump into the container and restore into a fresh throwaway DB.
docker cp "$DUMP" "$PG_CONTAINER":/tmp/drill.dump >/dev/null 2>>"$LOG_FILE" || fail "docker cp of dump into container failed"
pex createdb -U postgres "$DRILL_DB" 2>>"$LOG_FILE" || fail "createdb $DRILL_DB failed"

# pg_restore emits benign notices (roles already exist, etc.); real corruption shows as a
# non-zero exit under --exit-on-error. We deliberately do NOT use --clean (empty DB) and DO
# use --no-owner (roles differ under recovery). A handful of ignorable errors would still be
# caught by the count assertions below.
if ! pex pg_restore -U postgres -d "$DRILL_DB" --no-owner --exit-on-error /tmp/drill.dump 2>>"$LOG_FILE"; then
    fail "pg_restore reported errors restoring $DUMP"
fi

# 3. Assertions — plausible, not exact (the live instance grows/shrinks between drills).
T=$(psql_scalar "$DRILL_DB" "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")
W=$(psql_scalar "$DRILL_DB" "SELECT count(*) FROM workflow_entity")
C=$(psql_scalar "$DRILL_DB" "SELECT count(*) FROM credentials_entity")
M=$(psql_scalar "$DRILL_DB" "SELECT count(*) FROM migrations")
log "restored counts: tables=$T workflows=$W credentials=$C migrations=$M"

[ "${T:-0}" -ge "$MIN_TABLES" ]       || fail "tables=$T below minimum $MIN_TABLES"
[ "${W:-0}" -ge "$MIN_WORKFLOWS" ]    || fail "workflow_entity=$W below minimum $MIN_WORKFLOWS"
[ "${C:-0}" -ge "$MIN_CREDENTIALS" ]  || fail "credentials_entity=$C below minimum $MIN_CREDENTIALS"
[ "${M:-0}" -ge "$MIN_MIGRATIONS" ]   || fail "migrations=$M below minimum $MIN_MIGRATIONS"

# Success — clear any prior failure sentinel. Do NOT unset POSTGRES_PASSWORD here: the EXIT
# trap's cleanup() still needs it to DROP the throwaway DB, and the var dies with the process.
rm -f "$SENTINEL"
log "=== Restore drill PASSED (tables=$T workflows=$W credentials=$C migrations=$M) ==="
