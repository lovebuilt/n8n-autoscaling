#!/bin/bash
# Quick n8n Update — pull, rebuild, restart (no backup)
# Usage: ./quick-update.sh
set -euo pipefail

COMPOSE_DIR="/opt/n8n-autoscaling"
cd "$COMPOSE_DIR"

echo "========================================"
echo "  Quick Update"
echo "  $(date)"
echo "========================================"
echo

# Parse base images from Dockerfiles (single source of truth)
N8N_IMAGE=$(grep "^FROM n8nio" Dockerfile | tail -1 | awk '{print $2}')
RUNNER_IMAGE=$(grep "^FROM n8nio" Dockerfile.runner | tail -1 | awk '{print $2}')

# Get current versions
CURRENT_N8N=$(docker compose exec -T n8n n8n --version 2>/dev/null || echo "unknown")
CURRENT_N8N_DIGEST=$(docker inspect --format="{{.Image}}" n8n-autoscaling-n8n-1 2>/dev/null | cut -c8-19)
CURRENT_RUNNER_DIGEST=$(docker inspect --format="{{.Image}}" n8n-autoscaling-n8n-task-runner-1 2>/dev/null | cut -c8-19)
echo "  n8n:    $CURRENT_N8N"
echo "  Runner: ${CURRENT_RUNNER_DIGEST:-unknown}"

echo
echo "Pulling latest images..."
docker pull "$N8N_IMAGE" && docker pull "$RUNNER_IMAGE"

echo
echo "Rebuilding..."
docker compose build --no-cache n8n n8n-webhook n8n-worker n8n-task-runner n8n-worker-runner

echo
echo "Restarting..."
docker compose up -d --force-recreate n8n n8n-webhook n8n-worker n8n-task-runner n8n-worker-runner

echo
echo "Waiting 10s..."
sleep 10

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
echo "  Quick Update Complete!"
echo "  n8n:    $CURRENT_N8N → $NEW_N8N ($N8N_CHANGED)"
echo "  Runner: ${CURRENT_RUNNER_DIGEST:-?} → ${NEW_RUNNER_DIGEST:-?} ($RUNNER_CHANGED)"
echo "========================================"

# Post-update: trigger TypeVersion Health Check
if [ -f /opt/n8n-autoscaling/post-update-hook.sh ]; then
    /opt/n8n-autoscaling/post-update-hook.sh
fi
