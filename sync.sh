#\!/bin/bash
# GitHub Sync Helper — no git commands to remember
set -uo pipefail
cd /opt/n8n-autoscaling

case "${1:-}" in

  status)
    echo "=== Local Changes ==="
    git status --short
    CHANGES=$(git status --short | wc -l)
    if [ "$CHANGES" -eq 0 ]; then
      echo "  (clean — nothing changed)"
    fi
    echo
    echo "=== Behind/Ahead of GitHub ==="
    git fetch origin --quiet
    LOCAL=$(git rev-parse HEAD)
    REMOTE=$(git rev-parse origin/main)
    BASE=$(git merge-base HEAD origin/main)
    if [ "$LOCAL" = "$REMOTE" ]; then
      echo "  In sync with GitHub"
    elif [ "$LOCAL" = "$BASE" ]; then
      BEHIND=$(git rev-list --count HEAD..origin/main)
      echo "  $BEHIND commit(s) behind GitHub — run: ./sync.sh pull"
    elif [ "$REMOTE" = "$BASE" ]; then
      AHEAD=$(git rev-list --count origin/main..HEAD)
      echo "  $AHEAD commit(s) ahead of GitHub — run: ./sync.sh push \"message\""
    else
      echo "  DIVERGED — local and GitHub have different changes"
      echo "  Ask Claude to help resolve this"
    fi
    ;;

  diff)
    echo "=== Unstaged Changes ==="
    git diff
    echo
    echo "=== Untracked Files ==="
    git ls-files --others --exclude-standard
    ;;

  push)
    MESSAGE="${2:-}"
    if [ -z "$MESSAGE" ]; then
      echo "Usage: ./sync.sh push \"description of changes\""
      echo
      echo "Example: ./sync.sh push \"updated Dockerfile with new package\""
      exit 1
    fi
    echo "=== Staging all changes ==="
    git add -A
    echo "=== Committing ==="
    git commit -m "$MESSAGE"
    echo "=== Pushing to GitHub ==="
    git push origin main
    echo
    echo "Done\! Changes are now on GitHub."
    ;;

  pull)
    echo "=== Pulling from GitHub ==="
    git fetch origin
    LOCAL=$(git rev-parse HEAD)
    REMOTE=$(git rev-parse origin/main)
    if [ "$LOCAL" = "$REMOTE" ]; then
      echo "  Already up to date."
    else
      git pull origin main
      echo
      echo "Done\! Server matches GitHub."
      echo
      echo "If Dockerfiles changed, rebuild with:"
      echo "  docker compose build --no-cache n8n n8n-webhook n8n-worker n8n-task-runner n8n-worker-runner"
      echo "  docker compose up -d --force-recreate n8n n8n-webhook n8n-worker n8n-task-runner n8n-worker-runner"
    fi
    ;;

  *)
    echo "========================================"
    echo "  n8n Stack — GitHub Sync"
    echo "========================================"
    echo
    echo "  ./sync.sh status          What changed? Am I behind GitHub?"
    echo "  ./sync.sh diff            Show me the actual changes"
    echo "  ./sync.sh push \"message\"   Send my changes to GitHub"
    echo "  ./sync.sh pull            Get changes from GitHub"
    echo
    echo "========================================"
    ;;

esac
