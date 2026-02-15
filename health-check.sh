#!/bin/bash
# n8n Infrastructure Health Check — color-coded table with summary
# Usage: ./health-check.sh (on server) or: ssh root@37.27.189.40 /opt/n8n-autoscaling/health-check.sh

H=0; U=0; N=0
ROWS=""

while IFS="|" read -r name status; do
  svc=$(echo "$name" | sed 's/n8n-autoscaling-//;s/-1$//')
  up=$(echo "$status" | grep -oE '[0-9]+ (seconds?|minutes?|hours?|days?|weeks?)')
  if echo "$status" | grep -q "(healthy)"; then
    ROWS+=$(printf "  ║ \033[32m%-28s\033[0m ║ \033[32m%-9s\033[0m ║ %-8s ║\n" "$svc" "healthy" "$up")
    ROWS+=$'\n'
    H=$((H+1))
  elif echo "$status" | grep -q "(unhealthy)"; then
    ROWS+=$(printf "  ║ \033[31m%-28s\033[0m ║ \033[31m%-9s\033[0m ║ %-8s ║\n" "$svc" "UNHEALTHY" "$up")
    ROWS+=$'\n'
    U=$((U+1))
  else
    ROWS+=$(printf "  ║ \033[33m%-28s\033[0m ║ \033[33m%-9s\033[0m ║ %-8s ║\n" "$svc" "no check" "$up")
    ROWS+=$'\n'
    N=$((N+1))
  fi
done < <(docker ps --format '{{.Names}}|{{.Status}}' | grep n8n-autoscaling | sort)

# Build summary with exact padding to 53 inner chars
SUM=$(printf "\033[32m✓ Healthy: %d\033[0m   \033[31m✗ Unhealthy: %d\033[0m   \033[33m○ No check: %d\033[0m" "$H" "$U" "$N")
# Visible char count: "✓ Healthy: X   ✗ Unhealthy: X   ○ No check: X" (varies with digits)
# We pad manually to keep the box aligned
VIS_LEN=$(printf "✓ Healthy: %d   ✗ Unhealthy: %d   ○ No check: %d" "$H" "$U" "$N" | wc -m | tr -d ' ')
PAD=$((51 - VIS_LEN))
PADDING=$(printf "%${PAD}s" "")

echo ""
printf "  ╔══════════════════════════════╦═══════════╦══════════╗\n"
printf "  ║   n8n Infrastructure Health  ║  Status   ║  Uptime  ║\n"
printf "  ╠══════════════════════════════╬═══════════╬══════════╣\n"
printf "%s" "$ROWS"
printf "  ╠══════════════════════════════╩═══════════╩══════════╣\n"
printf "  ║ %s%s ║\n" "$SUM" "$PADDING"
printf "  ╚═════════════════════════════════════════════════════╝\n"
echo ""
