#!/bin/bash
# Full Stack Restart — like update.sh but restarts ALL services (including Postgres, Redis, etc.)
# Usage: ./restart-all.sh
set -uo pipefail

COMPOSE_DIR="/opt/n8n-autoscaling"
cd "$COMPOSE_DIR"

echo "========================================"
echo "  Full Stack Restart"
echo "  $(date)"
echo "========================================"
echo

# Parse base images from Dockerfiles (single source of truth)
N8N_IMAGE=$(grep "^FROM n8nio" Dockerfile | tail -1 | awk '{print $2}')
RUNNER_IMAGE=$(grep "^FROM n8nio" Dockerfile.runner | tail -1 | awk '{print $2}')

# Step 1: Get current versions
echo "[1/6] Checking current versions..."
CURRENT_N8N=$(docker compose exec -T n8n n8n --version 2>/dev/null || echo "unknown")
CURRENT_N8N_DIGEST=$(docker inspect --format="{{.Image}}" n8n-autoscaling-n8n-1 2>/dev/null | cut -c8-19)
CURRENT_RUNNER_DIGEST=$(docker inspect --format="{{.Image}}" n8n-autoscaling-n8n-task-runner-1 2>/dev/null | cut -c8-19)
echo "  n8n:    $CURRENT_N8N"
echo "  Runner: $RUNNER_IMAGE (${CURRENT_RUNNER_DIGEST:-unknown})"

# Step 2: Pull latest base images
echo
echo "[2/6] Pulling latest base images..."
docker pull "$N8N_IMAGE"
docker pull "$RUNNER_IMAGE"
echo

# Step 3: Run backup before restart
echo
echo "[3/6] Running backup..."
if [ -f /opt/n8n-autoscaling/backup.sh ]; then
    /opt/n8n-autoscaling/backup.sh
    echo "  Backup complete."
else
    echo "  WARNING: backup.sh not found, skipping backup."
fi

# Step 4: Rebuild all n8n services
echo
echo "[4/6] Rebuilding containers (n8n + webhook + worker + runners)..."
docker compose build --no-cache n8n n8n-webhook n8n-worker n8n-task-runner n8n-worker-runner
echo "  Build complete."

# Step 5: Full stack down/up (ALL services including Postgres, Redis, Cloudflare tunnel)
echo
echo "[5/6] Full stack restart (all services)..."
docker compose down
docker compose up -d
echo "  All services started."

# Step 6: Health check
echo
echo "[6/6] Health check (waiting 30s for startup)..."
sleep 30

HEALTHY=0
UNHEALTHY=0
for svc in n8n n8n-webhook n8n-worker n8n-task-runner n8n-worker-runner postgres redis n8n-monitor cloudflared; do
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
echo "  Restart Complete!"
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

# Post-update: trigger TypeVersion Health Check
if [ -f /opt/n8n-autoscaling/post-update-hook.sh ]; then
    /opt/n8n-autoscaling/post-update-hook.sh
fi
