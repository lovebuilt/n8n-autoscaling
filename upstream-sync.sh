#!/bin/bash
set -e

# upstream-sync.sh — Safely merge upstream changes into your fork
# Usage: ./upstream-sync.sh [check|merge|abort|done]

cd "$(dirname "$0")"
UPSTREAM="upstream/main"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

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

    # Check for likely conflicts
    CONFLICT_FILES=$(git diff --name-only main $UPSTREAM | while read f; do
        git diff --name-only HEAD -- "$f" 2>/dev/null | head -1
    done | sort -u)

    DELETED_BY_UPSTREAM=$(git diff --diff-filter=D --name-only main $UPSTREAM)

    if [ -n "$DELETED_BY_UPSTREAM" ]; then
        echo -e "${RED}⚠  Upstream DELETED these files (you may want to keep yours):${NC}"
        echo "$DELETED_BY_UPSTREAM" | while read f; do echo "  - $f"; done
        echo ""
    fi

    echo -e "${YELLOW}To merge: ./upstream-sync.sh merge${NC}"
    echo -e "  This will attempt a git merge. If there are conflicts,"
    echo -e "  you'll resolve them manually, then run: ./upstream-sync.sh done"
    echo -e "  To cancel a merge: ./upstream-sync.sh abort"
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
        echo -e "  Review changes, then push to your fork: ./sync.sh push \"merge upstream updates\""
        echo -e "  If something looks wrong: git reset --hard HEAD~1"
    else
        echo ""
        echo -e "${RED}⚠  MERGE CONFLICTS detected.${NC}"
        echo ""
        echo -e "Files with conflicts:"
        git diff --name-only --diff-filter=U
        echo ""
        echo -e "${YELLOW}What to do:${NC}"
        echo "  1. Edit each conflicted file (look for <<<<<<< markers)"
        echo "  2. For files upstream deleted but you want to KEEP:"
        echo "     git checkout HEAD -- filename"
        echo "  3. For files you want to take FROM UPSTREAM:"
        echo "     git checkout $UPSTREAM -- filename"
        echo "  4. Stage resolved files: git add <file>"
        echo "  5. Finish: ./upstream-sync.sh done"
        echo ""
        echo -e "  To cancel everything: ./upstream-sync.sh abort"
    fi
    ;;

done)
    if [ -f .git/MERGE_HEAD ]; then
        git commit --no-edit
        echo -e "${GREEN}✓ Merge complete!${NC}"
        echo -e "  Push to your fork: ./sync.sh push \"merge upstream updates\""
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
    ;;
esac
