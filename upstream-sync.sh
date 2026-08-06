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
    # DRY-RUN FIRST. This subcommand deliberately NEVER commits.
    #
    # Why (2026-07-10 incident + 2026-08-06 confirmation): an upstream-update email said
    # "SAFE TO MERGE"; `check` then warned the merge would delete 1,535 lines including the
    # whole customization layer. BOTH were wrong, in opposite directions. The email's AI only
    # sees the new upstream commits, and `check`'s deletion list is `git diff main upstream`
    # -- a TREE comparison, not a merge preview, so files the fork ADDED show up as
    # "deleted by upstream" even though a real 3-way merge never touches them.
    #
    # The only truth is a staged dry-run merge. This leaves it staged for inspection and
    # hands you `done` / `abort`. It will not commit on your behalf.
    echo -e "${CYAN}Fetching upstream...${NC}"
    git fetch upstream

    BEHIND=$(git rev-list --count main..$UPSTREAM 2>/dev/null || echo 0)
    if [ "$BEHIND" -eq 0 ]; then
        echo -e "${GREEN}✓ Already up to date.${NC}"
        exit 0
    fi

    # Safety: shared production repo -- refuse on a dirty tree.
    if [ -n "$(git status --porcelain | grep -v '^?? ')" ]; then
        echo -e "${RED}✗ You have uncommitted tracked changes. Commit or stash them first.${NC}"
        git status --short
        exit 1
    fi

    ROLLBACK_TAG="pre-merge-$(date -u +%Y%m%dT%H%M%SZ)"
    git tag -f "$ROLLBACK_TAG" >/dev/null 2>&1
    echo -e "${CYAN}Rollback tag: ${NC}$ROLLBACK_TAG"
    echo -e "${YELLOW}Dry-run merging $BEHIND upstream commit(s) (--no-commit --no-ff)...${NC}"
    echo ""

    set +e
    git merge $UPSTREAM --no-commit --no-ff >/tmp/upstream-merge.out 2>&1
    set -e
    cat /tmp/upstream-merge.out

    # ---- GATE 1: real deletions (the load-bearing check) ----
    DELETIONS=$(git diff --cached --diff-filter=D --name-only)
    PROTECTED=$(echo "$DELETIONS" | grep -E '^(custom/|docker-compose\.override\.yml|.*\.sh$)' || true)

    echo ""
    if [ -n "$PROTECTED" ]; then
        echo -e "${RED}⛔ ABORTING: the merge would delete CUSTOMIZATION files:${NC}"
        echo "$PROTECTED" | sed 's/^/    /'
        git merge --abort
        echo -e "${GREEN}✓ Merge aborted. Working tree restored. Nothing was committed.${NC}"
        exit 1
    fi

    if [ -n "$DELETIONS" ]; then
        echo -e "${YELLOW}⚠  Merge deletes these files (none are customization files -- review anyway):${NC}"
        echo "$DELETIONS" | sed 's/^/    /'
    else
        echo -e "${GREEN}✓ Deletion gate: no files deleted.${NC}"
    fi

    # ---- GATE 2: conflicts ----
    CONFLICTS=$(git diff --name-only --diff-filter=U)
    echo ""
    if [ -n "$CONFLICTS" ]; then
        echo -e "${YELLOW}⚠  Conflicts to resolve by hand:${NC}"
        echo "$CONFLICTS" | sed 's/^/    /'
        echo ""
        echo -e "  Dockerfiles / n8n-task-runners.json -> take UPSTREAM's version:"
        echo "    git checkout upstream/main -- <file> && git add <file>"
        echo "    (your packages live in custom/config.json and are re-injected by build.py)"
        echo ""
        echo -e "  docker-compose.yml -> resolve by hand. Customizations belong in"
        echo "    docker-compose.override.yml where possible (see FORK.md)."
    else
        echo -e "${GREEN}✓ No conflicts -- merge is staged clean.${NC}"
    fi

    echo ""
    echo -e "${CYAN}Staged changes:${NC}"
    git diff --cached --stat | tail -30

    echo ""
    echo -e "${YELLOW}NOTHING HAS BEEN COMMITTED.${NC} Inspect, then:"
    echo -e "  Inspect a file:  git diff --cached <file>"
    echo -e "  Finish:          ./upstream-sync.sh done"
    echo -e "  Cancel:          ./upstream-sync.sh abort   (or: git reset --hard $ROLLBACK_TAG)"
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
