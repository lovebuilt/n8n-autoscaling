#!/bin/bash
# Post-Update Hook — triggers TypeVersion Health Check workflow after n8n updates
# Called by: update.sh, quick-update.sh, restart-all.sh

echo
echo "[Post-Update] Triggering TypeVersion Health Check..."

# Wait for webhook container to be ready after restart
sleep 5

RESULT=$(docker exec n8n-autoscaling-n8n-webhook-1 wget -qO-   --post-data='{"trigger":"post-update"}'   --header='Content-Type: application/json'   'http://localhost:5678/webhook/run-typeversion-check' 2>&1) || true

if echo "$RESULT" | grep -q 'Workflow was started'; then
  echo "  TypeVersion Health Check triggered successfully."
  echo "  Results will be sent via email + Slack."
else
  echo "  Could not trigger TypeVersion Health Check (webhook container may still be starting)."
  echo "  It will run automatically on Sunday 8AM CT."
  echo "  Manual trigger: Check n8n UI for workflow link"
fi
