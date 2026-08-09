#!/usr/bin/env bash
# verify-state.sh — Prove where we are with evidence.
#
# Usage: ./scripts/verify-state.sh [--push]
#   --push  Also compare local vs remote (requires network)
#
# Exit: 0

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

SHOW_PUSH=false
[[ "${1:-}" == "--push" ]] && SHOW_PUSH=true

BRANCH=$(git rev-parse --abbrev-ref HEAD)
HEAD=$(git rev-parse --short HEAD)

echo "=== AVALON STATE: $(date '+%Y-%m-%d %H:%M') ==="
echo "Branch: $BRANCH  HEAD: $HEAD"
echo ""

# ── 1. Last 15 commits ─────────────────────────────────────────────
echo "--- LAST 15 COMMITS ---"
git log --oneline -15
echo ""

# ── 2. Uncommitted changes ─────────────────────────────────────────
echo "--- WORKING TREE ---"
STATUS=$(git status --short)
if [[ -z "$STATUS" ]]; then
    echo "CLEAN — nothing uncommitted"
else
    echo "$STATUS" | head -30
    COUNT=$(echo "$STATUS" | wc -l)
    TOTAL=$(git diff --stat | tail -1 || echo "many files changed")
    echo "($COUNT changed files)"
fi
echo ""

# ── 3. Push status ─────────────────────────────────────────────────
if [[ "$SHOW_PUSH" == "true" ]]; then
    git fetch origin --quiet 2>/dev/null || {
        echo "REMOTE FETCH FAILED (no network?)"
        echo ""
    } || true

    if git rev-parse "origin/$BRANCH" &>/dev/null; then
        AHEAD=$(git rev-list --count "origin/$BRANCH"..HEAD)
        BEHIND=$(git rev-list --count HEAD.."origin/$BRANCH")
        echo "--- PUSH STATUS vs origin/$BRANCH ---"
        echo "Local ahead: $AHEAD commit(s)"
        echo "Remote ahead: $BEHIND commit(s)"
        if [[ "$AHEAD" -gt 0 ]]; then
            echo "UNPUSHED:"
            git log "origin/$BRANCH"..HEAD --oneline
        else
            echo "All local commits are pushed."
        fi
    else
        echo "--- NO REMOTE tracking for $BRANCH ---"
    fi
    echo ""
fi

# ── 4. Milestone evidence ──────────────────────────────────────────
echo "--- MILESTONE EVIDENCE ---"

# M0: T-009 through T-014
M0_RANGE=$(git log --oneline --all --grep='T-009\|T-010\|T-011\|T-012\|T-013\|T-014\|feat(M0)' | wc -l)
echo "M0 (T-009..T-014) commits: $M0_RANGE"

# Key M0 proof commits
if git log --oneline --all --grep='demo-m0' | grep -q .; then
    echo "  demo-m0.sh committed: $(git log --oneline --all --grep='demo-m0' -1 | cut -d' ' -f1)"
fi
if git log --oneline --all --grep='T-013\|gameplay proof' | grep -q .; then
    echo "  gameplay proof: $(git log --oneline --all --grep='T-013\|gameplay proof' -1 | cut -d' ' -f1)"
fi

# M1: T-016 through T-027
M1_RANGE=$(git log --oneline --all --grep='T-016\|T-017\|T-018\|T-019\|T-02[0-9]\|feat(M1)' | wc -l)
echo "M1 (T-016..T-027) commits: $M1_RANGE"

# Latest M1 commit
LATEST_M1=$(git log --oneline --all --grep='feat(M1)' -1 2>/dev/null | cut -d' ' -f1 || echo "none")
echo "Latest M1 commit: $LATEST_M1"

# Test status
if [[ -f scripts/run-tests.sh ]]; then
    TEST_COUNT=$(grep -r 'fn test_' tests/ server/ client/ --include='*.gd' 2>/dev/null | wc -l || echo "?")
    echo "Test functions found: $TEST_COUNT"
fi

echo ""
echo "=== DONE ==="
