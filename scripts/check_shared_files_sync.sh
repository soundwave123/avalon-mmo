#!/usr/bin/env bash
# Generalized shared-files sync gate for pre-push.
#
# Checks that shared GDScript files (canonically stored in server/shared/)
# are byte-identical across all project copies. Prevents silent drift between
# gateway, master, and world copies of shared code.
#
# Usage: add new shared files to SHARED_FILES array below.
# Each entry: "source|copy1|copy2|..." (relative to repo root)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Shared files: first path is canonical source, rest are copies.
# New shared files should be added here.
SHARED_FILES=(
    # NOTE: world has no jwt.gd — the world server validates tokens via the master
    # RPC (master_client.gd), it never signs or rotates JWTs itself. Any jwt.gd under
    # server/world/ would be dead code and is intentionally NOT synced here.
    "server/shared/jwt.gd|server/gateway/scripts/jwt.gd|server/master/scripts/jwt.gd"
    # T-514/T-514b: the client build gate, enforced at BOTH the gateway login and the world session
    # handshake (defense in depth) — all three copies kept byte-identical.
    "server/shared/build_gate.gd|server/gateway/scripts/build_gate.gd|server/world/scripts/build_gate.gd"
    "server/shared/session_manager.gd|server/gateway/scripts/session_manager.gd|server/master/scripts/session_manager.gd"
    # T-716: the character-name rule set (charset/length/normalisation + the plain-English copy).
    # The gateway validates alt creation, the master owns the in-world name step, and the client
    # gives instant feedback while typing — all three MUST agree or a name accepted in one place is
    # rejected in another.
    "server/shared/character_name.gd|server/gateway/scripts/character_name.gd|server/master/scripts/character_name.gd|client/scripts/ui/character_name.gd"
    "addons/database/database.gd|server/gateway/addons/database/database.gd|server/master/addons/database/database.gd"
    # T-701: sidecar driver rides next to database.gd in every project that has the seam.
    "addons/database/pg_pipe.gd|server/gateway/addons/database/pg_pipe.gd|server/master/addons/database/pg_pipe.gd"
    "scripts/infra/pg_query.sh|server/gateway/scripts/infra/pg_query.sh|server/master/scripts/infra/pg_query.sh"
    # T-327: the deterministic terrain-height field. Canonical is the CLIENT copy (T-309 extracted
    # it there; the visual lane owns the formula) — the world server samples byte-identical ground
    # for movement (height is derived from (x, z) on each side, never wired).
    "client/scripts/world/terrain_field.gd|server/world/scripts/terrain_field.gd"
)

FAIL=0
FAIL_MSGS=()

for entry in "${SHARED_FILES[@]}"; do
    IFS='|' read -ra paths <<< "$entry"
    source="${paths[0]}"
    src_path="$REPO_ROOT/$source"

    if [[ ! -f "$src_path" ]]; then
        FAIL_MSGS+=("missing source: $source")
        FAIL=1
        continue
    fi

    for ((i=1; i<${#paths[@]}; i++)); do
        copy="${paths[$i]}"
        copy_path="$REPO_ROOT/$copy"

        if [[ ! -f "$copy_path" ]]; then
            FAIL_MSGS+=("missing copy: $copy (source: $source)")
            FAIL=1
            continue
        fi

        if ! diff -q "$src_path" "$copy_path" > /dev/null 2>&1; then
            FAIL_MSGS+=("DRIFT: $copy differs from $source")
            FAIL=1
        fi
    done
done

if [[ $FAIL -eq 1 ]]; then
    echo "[shared-files-sync] FAIL:"
    for msg in "${FAIL_MSGS[@]}"; do
        echo "  - $msg"
    done
    echo ""
    echo "Fix by copying canonical source to project copies:"
    for entry in "${SHARED_FILES[@]}"; do
        IFS='|' read -ra paths <<< "$entry"
        source="${paths[0]}"
        for ((i=1; i<${#paths[@]}; i++)); do
            copy="${paths[$i]}"
            echo "  cp $source $copy"
        done
    done
    exit 1
fi

echo "[shared-files-sync] OK: all shared files byte-identical (${#SHARED_FILES[@]} groups checked)"
exit 0
