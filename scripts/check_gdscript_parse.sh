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

if [[ -z "$GODOT" ]]; then
    echo "[gdscript-parse-all] WARN: godot not in PATH, skipping"
    exit 0
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0
CHECKED=0

# Projects to check (relative to repo root).
PROJECTS=("server/gateway" "server/master" "server/world" "client")

for proj in "${PROJECTS[@]}"; do
    proj_path="$REPO_ROOT/$proj"
    if [[ ! -f "$proj_path/project.godot" ]]; then
        continue
    fi

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
