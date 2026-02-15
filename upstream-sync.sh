#!/bin/bash
set -e

# upstream-sync.sh — Safely merge upstream changes into your fork
# Usage: ./upstream-sync.sh [check|merge|abort|done]
#
# LAYERED ARCHITECTURE:
#   Upstream's Dockerfiles stay clean in git (no conflicts on merge).
#   Your additions live in custom/config.json.
#   After merge, custom/build.py generates .build files with your packages injected.
#   docker-compose.override.yml points Docker to the .build files.

cd "$(dirname "$0")"
UPSTREAM="upstream/main"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

rebuild_customizations() {
    echo ""
    echo -e "${CYAN}Re-applying your customizations...${NC}"
    python3 custom/build.py
}

case "${1:-check}" in

check)
    echo -e "${CYAN}Fetching upstream...${NC}"
    git fetch upstream

    BEHIND=$(git rev-list --count main..$UPSTREAM 2>/dev/null || echo 0)
    AHEAD=$(git rev-list --count $UPSTREAM..main 2>/dev/null || echo 0)

    if [ "$BEHIND" -eq 0 ]; then
        echo -e "${GREEN}✓ You are up to date with upstream.${NC}"
        [ "$AHEAD" -gt 0 ] && echo -e "  (You have $AHEAD commit(s) ahead — your customizations)"
        exit 0
    fi

    echo -e "${YELLOW}⚠  $BEHIND new commit(s) from upstream:${NC}"
    echo ""
    git log --oneline main..$UPSTREAM
    echo ""

    echo -e "${CYAN}Files that would change:${NC}"
    git diff --stat main $UPSTREAM
    echo ""

    DELETED_BY_UPSTREAM=$(git diff --diff-filter=D --name-only main $UPSTREAM)
    if [ -n "$DELETED_BY_UPSTREAM" ]; then
        echo -e "${RED}⚠  Upstream DELETED these files (you may want to keep yours):${NC}"
        echo "$DELETED_BY_UPSTREAM" | while read f; do echo "  - $f"; done
        echo ""
    fi

    echo -e "${YELLOW}To merge: ./upstream-sync.sh merge${NC}"
    echo -e "  Your Dockerfile customizations are safe — they live in custom/config.json"
    echo -e "  and get re-applied automatically after merge."
    ;;

merge)
    echo -e "${CYAN}Fetching upstream...${NC}"
    git fetch upstream

    BEHIND=$(git rev-list --count main..$UPSTREAM 2>/dev/null || echo 0)
    if [ "$BEHIND" -eq 0 ]; then
        echo -e "${GREEN}✓ Already up to date.${NC}"
        exit 0
    fi

    # Safety: check for uncommitted changes
    if [ -n "$(git status --porcelain)" ]; then
        echo -e "${RED}✗ You have uncommitted changes. Commit or stash them first.${NC}"
        git status --short
        exit 1
    fi

    echo -e "${YELLOW}Merging $BEHIND upstream commit(s)...${NC}"
    echo ""

    if git merge $UPSTREAM --no-edit; then
        echo ""
        echo -e "${GREEN}✓ Merge successful! No conflicts.${NC}"

        # Auto-regenerate .build files with your customizations
        rebuild_customizations

        echo ""
        echo -e "${GREEN}✓ All done! Your customizations are preserved.${NC}"
        echo -e "  Push to your fork:  ./sync.sh push \"merge upstream updates\""
        echo -e "  Rebuild containers: ./quick-update.sh"
        echo -e "  If something is wrong: git reset --hard HEAD~1"
    else
        echo ""
        echo -e "${RED}⚠  MERGE CONFLICTS detected.${NC}"
        echo ""
        echo -e "Files with conflicts:"
        git diff --name-only --diff-filter=U
        echo ""
        echo -e "${YELLOW}What to do:${NC}"
        echo "  For Dockerfiles/n8n-task-runners.json conflicts, just accept UPSTREAM's version:"
        echo "    git checkout upstream/main -- Dockerfile Dockerfile.runner n8n-task-runners.json"
        echo "    git add Dockerfile Dockerfile.runner n8n-task-runners.json"
        echo "  (Your packages are in custom/config.json and get injected by build.py)"
        echo ""
        echo "  For OTHER files with conflicts, resolve manually."
        echo ""
        echo "  Then finish: ./upstream-sync.sh done"
        echo "  Or cancel:   ./upstream-sync.sh abort"
    fi
    ;;

done)
    if [ -f .git/MERGE_HEAD ]; then
        git commit --no-edit
        echo -e "${GREEN}✓ Merge committed!${NC}"

        # Regenerate .build files
        rebuild_customizations

        echo ""
        echo -e "${GREEN}✓ All done! Your customizations are preserved.${NC}"
        echo -e "  Push to your fork:  ./sync.sh push \"merge upstream updates\""
        echo -e "  Rebuild containers: ./quick-update.sh"
    else
        echo -e "${YELLOW}No merge in progress.${NC}"
    fi
    ;;

abort)
    if [ -f .git/MERGE_HEAD ]; then
        git merge --abort
        echo -e "${GREEN}✓ Merge aborted. Back to where you started.${NC}"
    else
        echo -e "${YELLOW}No merge in progress.${NC}"
    fi
    ;;

*)
    echo "Usage: ./upstream-sync.sh [check|merge|abort|done]"
    echo ""
    echo "  check  — See what's new upstream (default, safe)"
    echo "  merge  — Start merging upstream changes"
    echo "  done   — Finish merge after resolving conflicts"
    echo "  abort  — Cancel a merge in progress"
    echo ""
    echo "  Your Dockerfile packages are in custom/config.json."
    echo "  They get auto-injected into upstream's Dockerfiles after every merge."
    ;;
esac
