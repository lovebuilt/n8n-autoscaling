#!/bin/bash
# API Key Health Check — shared by update.sh, quick-update.sh, restart-all.sh
# Tests all n8n API keys (JWTs) against the running instance.
# Version updates can change JWT signing/validation, silently invalidating old keys.
#
# SYNC NOTE: This script is called by update.sh, quick-update.sh, and restart-all.sh.
# Changes here apply to all update paths automatically.

COMPOSE_DIR="/opt/n8n-autoscaling"
cd "$COMPOSE_DIR"

echo "Checking API key health..."

PGPASSWORD=$(grep '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)

# Write keys to temp file to avoid shell parsing issues with long JWTs
docker compose exec -T -e PGPASSWORD="$PGPASSWORD" postgres \
  psql -U postgres -d n8n -t -A -F'|' \
  -c "SELECT label, \"apiKey\" FROM user_api_keys;" 2>/dev/null > /tmp/n8n_api_keys.tmp

BROKEN_KEYS=""
BROKEN_COUNT=0
TOTAL_COUNT=0

while IFS='|' read -r label key; do
  [ -z "$label" ] && continue
  TOTAL_COUNT=$((TOTAL_COUNT + 1))

  # stdin redirected from /dev/null to prevent docker exec from consuming the file
  if docker compose exec -T n8n \
    wget -qO/dev/null --header="X-N8N-API-KEY: $key" \
    "http://localhost:5678/api/v1/workflows?limit=1" < /dev/null 2>/dev/null; then
    echo "  ✓ $label: OK"
  else
    echo "  ✗ $label: INVALID"
    BROKEN_KEYS="$BROKEN_KEYS\n    - $label"
    BROKEN_COUNT=$((BROKEN_COUNT + 1))
  fi
done < /tmp/n8n_api_keys.tmp
rm -f /tmp/n8n_api_keys.tmp

if [ "$BROKEN_COUNT" -gt 0 ]; then
  echo
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║  ⚠️  API KEY(S) INVALIDATED BY UPDATE                   ║"
  echo "╠══════════════════════════════════════════════════════════╣"
  echo "║                                                          ║"
  echo "║  $BROKEN_COUNT of $TOTAL_COUNT API keys no longer validate.              ║"
  echo "║  This is caused by JWT signing changes in the new        ║"
  echo "║  n8n version. Keys must be regenerated.                  ║"
  echo "║                                                          ║"
  echo "║  BROKEN KEYS:"
  echo -e "$BROKEN_KEYS"
  echo "║                                                          ║"
  echo "║  TO FIX:                                                 ║"
  echo "║  1. Go to: n8n Settings → API                           ║"
  echo "║  2. Delete each broken key listed above                  ║"
  echo "║  3. Create new replacement key(s)                        ║"
  echo "║  4. Update anything that stores the old key:             ║"
  echo "║     • 'n8n account' credential (used by workflows)      ║"
  echo "║     • .mcp.json on Mac (if MCP key broke)               ║"
  echo "║                                                          ║"
  echo "║  Affected workflows: Sync Registry, Version Checker,     ║"
  echo "║  and any workflow using the n8n API node.                ║"
  echo "╚══════════════════════════════════════════════════════════╝"
else
  echo "  All $TOTAL_COUNT API key(s) valid."
fi
