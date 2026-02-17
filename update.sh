#!/bin/bash
# n8n Update Script
# Usage: ./update.sh
set -uo pipefail

COMPOSE_DIR="/opt/n8n-autoscaling"
cd "$COMPOSE_DIR"

echo "========================================"
echo "  n8n Update Script"
echo "  $(date)"
echo "========================================"
echo

# Parse base images from Dockerfiles (single source of truth)
N8N_IMAGE=$(grep "^FROM n8nio" Dockerfile | tail -1 | awk '{print $2}')
RUNNER_IMAGE=$(grep "^FROM n8nio" Dockerfile.runner | tail -1 | awk '{print $2}')

# Step 1: Get current versions
echo "[1/7] Checking current versions..."
CURRENT_N8N=$(docker compose exec -T n8n n8n --version 2>/dev/null || echo "unknown")
CURRENT_N8N_DIGEST=$(docker inspect --format="{{.Image}}" n8n-autoscaling-n8n-1 2>/dev/null | cut -c8-19)
CURRENT_RUNNER_DIGEST=$(docker inspect --format="{{.Image}}" n8n-autoscaling-n8n-task-runner-1 2>/dev/null | cut -c8-19)
echo "  n8n:    $CURRENT_N8N"
echo "  Runner: $RUNNER_IMAGE (${CURRENT_RUNNER_DIGEST:-unknown})"

# Step 2: Pull latest base images
echo
echo "[2/7] Pulling latest base images..."
docker pull "$N8N_IMAGE"
docker pull "$RUNNER_IMAGE"
echo

# Step 3: Run backup before updating
echo
echo "[3/7] Running backup before update..."
if [ -f /opt/n8n-autoscaling/backup.sh ]; then
    /opt/n8n-autoscaling/backup.sh
    echo "  Backup complete."
else
    echo "  WARNING: backup.sh not found, skipping backup."
fi

# Step 4: Rebuild all n8n services
echo
echo "[4/7] Rebuilding containers (n8n + webhook + worker + runners)..."
docker compose build --no-cache n8n n8n-webhook n8n-worker n8n-task-runner n8n-worker-runner
echo "  Build complete."

# Step 5: Recreate containers
echo
echo "[5/7] Restarting containers..."
docker compose up -d --force-recreate n8n n8n-webhook n8n-worker n8n-task-runner n8n-worker-runner
echo "  Containers restarted."

# Step 6: Health check
echo
echo "[6/7] Health check (waiting 30s for startup)..."
sleep 30

HEALTHY=0
UNHEALTHY=0
for svc in n8n n8n-webhook n8n-worker n8n-task-runner n8n-worker-runner; do
    CONTAINER="n8n-autoscaling-${svc}-1"
    STATUS=$(docker inspect --format='{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo "missing")
    HEALTH=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$CONTAINER" 2>/dev/null || echo "unknown")
    if [ "$STATUS" = "running" ]; then
        echo "  ✓ $svc: $STATUS ($HEALTH)"
        HEALTHY=$((HEALTHY + 1))
    else
        echo "  ✗ $svc: $STATUS ($HEALTH)"
        UNHEALTHY=$((UNHEALTHY + 1))
    fi
done

# Get new versions
NEW_N8N=$(docker compose exec -T n8n n8n --version 2>/dev/null || echo "unknown")
NEW_N8N_DIGEST=$(docker inspect --format="{{.Image}}" n8n-autoscaling-n8n-1 2>/dev/null | cut -c8-19)
NEW_RUNNER_DIGEST=$(docker inspect --format="{{.Image}}" n8n-autoscaling-n8n-task-runner-1 2>/dev/null | cut -c8-19)

# Determine what changed
N8N_CHANGED="no change"
[ "$CURRENT_N8N" != "$NEW_N8N" ] && N8N_CHANGED="UPDATED"
[ "$CURRENT_N8N_DIGEST" != "$NEW_N8N_DIGEST" ] && N8N_CHANGED="rebuilt"

RUNNER_CHANGED="no change"
[ "$CURRENT_RUNNER_DIGEST" != "$NEW_RUNNER_DIGEST" ] && RUNNER_CHANGED="UPDATED"

echo
echo "========================================"
echo "  Update Complete!"
echo "  n8n:    $CURRENT_N8N → $NEW_N8N ($N8N_CHANGED)"
echo "  Runner: ${CURRENT_RUNNER_DIGEST:-?} → ${NEW_RUNNER_DIGEST:-?} ($RUNNER_CHANGED)"
echo "  Healthy: $HEALTHY  Unhealthy: $UNHEALTHY"
echo "========================================"

if [ "$UNHEALTHY" -gt 0 ]; then
    echo
    echo "WARNING: Some containers are unhealthy. Check with:"
    echo "  docker compose ps"
    echo "  docker compose logs <service>"
    exit 1
fi

# Step 7: API Key Health Check (shared script)
echo
echo "[7/7] Checking API key health..."
if [ -f /opt/n8n-autoscaling/check-api-keys.sh ]; then
    /opt/n8n-autoscaling/check-api-keys.sh
else
    echo "  WARNING: check-api-keys.sh not found, skipping API key check."
fi

# Post-update: trigger TypeVersion Health Check
if [ -f /opt/n8n-autoscaling/post-update-hook.sh ]; then
    /opt/n8n-autoscaling/post-update-hook.sh
fi
