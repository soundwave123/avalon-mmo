#!/usr/bin/env bash
# Gate — Full GDScript parse check for pre-push
#
# Runs godot --check-only on every first-party .gd file across all
# Godot projects. Catches broken preload/res:// references that only
# surface at runtime without this gate.

set -euo pipefail

GODOT=""
if command -v godot >/dev/null 2>&1; then
    GODOT="godot"
elif command -v godot4 >/dev/null 2>&1; then
    GODOT="godot4"
fi

# FAIL CLOSED (T-756). This used to `exit 0` with a WARN, which meant the pre-push parse
# gate silently passed on any machine where godot wasn't on PATH — a gate that cannot fail
# is not a gate. If you genuinely need to push from a godot-less box, that is a deliberate
# `git push --no-verify`, not an invisible default.
if [[ -z "$GODOT" ]]; then
    echo "[gdscript-parse-all] FAIL: godot not found in PATH (tried 'godot', 'godot4')."
    echo "[gdscript-parse-all] This gate fails closed — it cannot verify parses without the engine."
    echo "[gdscript-parse-all] Install/link godot, or bypass deliberately with: git push --no-verify"
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0
CHECKED=0

# Projects to check (relative to repo root).
# T-756: tools/launcher and tools/server-manager are shipped Godot projects too (the T-742
# self-host wizard and the player launcher) — they were silently outside this gate, so a
# broken preload in either only surfaced when a player ran it.
PROJECTS=("server/gateway" "server/master" "server/world" "client" "tools/launcher" "tools/server-manager")

for proj in "${PROJECTS[@]}"; do
    proj_path="$REPO_ROOT/$proj"
    if [[ ! -f "$proj_path/project.godot" ]]; then
        continue
    fi

    # T-756: import the project first so its class_name registry is populated. Without this,
    # --check-only reports "Identifier 'X' not declared in the current scope" for every
    # first-party class_name — a false parse failure, not a real one. run-tests.sh has always
    # done this; this gate never did, and only got away with it because the four game projects
    # happen to carry a warm .godot cache from daily use. tools/launcher ships without one, so
    # adding it to PROJECTS surfaced the gap immediately (launcher.gd could not see UpdateLogic).
    # A fresh clone would have hit the same thing on all six.
    "$GODOT" --headless --path "$proj_path" --import >/dev/null 2>&1 || true

    mapfile -t gd_files < <(
        find "$proj_path" -name '*.gd' -not -path '*/addons/*' -not -path '*/.godot/*' | sort
    )

    if [[ ${#gd_files[@]} -eq 0 ]]; then
        continue
    fi

    for f in "${gd_files[@]}"; do
        rel="${f#$proj_path/}"
        res_path="res://$rel"

        out=$("$GODOT" --headless --path "$proj_path" --check-only --script "$res_path" 2>&1) || true
        if echo "$out" | grep -qE 'Parse Error|Failed to load script'; then
            echo "[gdscript-parse-all] FAIL: $rel (project: $proj)"
            echo "$out" | grep -E 'Parse Error|Failed to load script' | head -10
            ERRORS=$((ERRORS + 1))
        fi
        CHECKED=$((CHECKED + 1))
    done
done

if [[ $ERRORS -gt 0 ]]; then
    echo "[gdscript-parse-all] $ERRORS files failed parse ($CHECKED checked)"
    exit 1
fi

echo "[gdscript-parse-all] pass ($CHECKED files)"
exit 0
