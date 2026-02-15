# n8n Server Cheat Sheet

> **Server IP**: Check your password manager or Hetzner console
> **Tailscale IP**: Check Tailscale admin panel

## Connect

```bash
ssh root@$SERVER_IP
cd /opt/n8n-autoscaling
```

## GitHub Sync

```bash
./sync.sh                     # Show help
./sync.sh status              # What changed? Am I behind GitHub?
./sync.sh diff                # Show the actual changes
./sync.sh push "message"      # Send changes to GitHub
./sync.sh pull                # Get changes from GitHub
```

## Update n8n

```bash
./update.sh                   # Full update: backup → pull images → rebuild → restart → health check
./quick-update.sh             # Quick: pull → rebuild → restart (no backup)
```

## Restart

```bash
./restart-all.sh              # Full stack restart (ALL services including Postgres, Redis, Cloudflare)
```

## Backup

```bash
./backup.sh                   # Manual backup (also runs daily at 9 AM via cron)
ls -la /backups/daily/        # See daily backups
ls -la /backups/weekly/       # See weekly backups (Sundays)
cat /backups/backup.log       # Check backup history
```

## Health Check

```bash
docker compose ps             # All container statuses
docker compose logs -f n8n    # Follow n8n logs (Ctrl+C to stop)
docker compose logs --tail=50 n8n-task-runner   # Last 50 runner log lines
```

## Rebuild After Dockerfile Changes

```bash
# Must rebuild ALL services sharing the same Dockerfile:
docker compose build --no-cache n8n n8n-webhook n8n-worker n8n-task-runner n8n-worker-runner
docker compose up -d --force-recreate n8n n8n-webhook n8n-worker n8n-task-runner n8n-worker-runner
```

## Quick Checks

```bash
docker compose exec n8n n8n --version           # Current n8n version
docker compose exec n8n-task-runner node -v      # Node.js version in runner
docker compose exec n8n tesseract --version      # OCR available?
docker compose exec n8n-task-runner python3 -c "import pandas; print(pandas.__version__)"  # Python packages?
```

## URLs

| Service | URL |
|---------|-----|
| n8n Editor | https://$YOUR_DOMAIN |
| Webhooks | https://webhook.$YOUR_DOMAIN |
| NocoDB | https://data.$YOUR_DOMAIN |
| Portainer | https://portainer.$YOUR_DOMAIN |

## Files That Matter

| File | What It Does |
|------|-------------|
| `.env` | All secrets (NEVER push to GitHub) |
| `docker-compose.yml` | Service definitions |
| `Dockerfile` | Main container (Execute Command tools) |
| `Dockerfile.runner` | Task runner (Code node tools: JS, Python, Chromium) |
| `n8n-task-runners.json` | Package allowlists for Code nodes |
| `.gitignore` | Keeps secrets out of GitHub |
