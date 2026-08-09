#!/usr/bin/env bash
# Self-test for scripts/run-tests.sh.
#
# Injects a deliberately-failing test into the client project,
# runs scripts/run-tests.sh, and asserts that the runner
# correctly reported the failure. Cleans up the injected file.
#
# Run this any time scripts/run-tests.sh is modified.
#
# Refuses to run if the working tree has uncommitted changes
# anywhere under the test target path, to avoid clobbering
# work-in-progress.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

INDUCED_FILE="client/tests/test_selftest_induced_failure.gd"

# Refuse if working tree dirty under client/tests/
if [[ -n "$(git status --porcelain client/tests/ 2>/dev/null)" ]]; then
    echo "[selftest] REFUSE — client/tests/ has uncommitted changes."
    echo "Commit or stash before running the selftest."
    exit 2
fi

cleanup() {
    if [[ -f "$INDUCED_FILE" ]]; then
        rm -f "$INDUCED_FILE"
        echo "[selftest] cleaned up $INDUCED_FILE"
    fi
}
trap cleanup EXIT

cat > "$INDUCED_FILE" <<'INDUCED_EOF'
extends "res://addons/gut/test.gd"

# DELIBERATE FAILURE for run-tests.sh self-test.
# This file should be removed automatically after the selftest runs.

func test_deliberate_failure() -> void:
    assert_eq(1, 2, "deliberate failure for selftest")
INDUCED_EOF

echo "[selftest] injected $INDUCED_FILE"
echo "[selftest] invoking scripts/run-tests.sh ..."
echo

set +e
output=$(./scripts/run-tests.sh 2>&1)
exit_code=$?
set -e

echo "$output"
echo
echo "[selftest] runner exited with: $exit_code"
echo

# Three required assertions:
#   1. exit code non-zero
#   2. output contains "deliberate failure"
#   3. summary table shows client with FAILED >= 1 and verdict FAIL

fail=0

if [[ $exit_code -eq 0 ]]; then
    echo "[selftest] FAIL: runner exited 0 despite induced failure"
    fail=1
fi

if ! echo "$output" | grep -qF "deliberate failure"; then
    echo "[selftest] FAIL: runner output did not contain 'deliberate failure'"
    fail=1
fi

# Look for client row in the summary table with FAIL verdict and failed count >= 1
client_row=$(echo "$output" | grep -E '^client +[0-9]+ +[0-9]+ +[0-9]+' || echo "")
if [[ -z "$client_row" ]]; then
    echo "[selftest] FAIL: could not find client row in summary table"
    fail=1
else
    failed_count=$(echo "$client_row" | awk '{print $4}')
    verdict=$(echo "$client_row" | awk '{print $NF}')
    if [[ "$failed_count" -lt 1 ]]; then
        echo "[selftest] FAIL: client row shows failed=$failed_count, expected >= 1"
        fail=1
    fi
    if [[ "$verdict" != "FAIL" ]]; then
        echo "[selftest] FAIL: client row verdict was '$verdict', expected 'FAIL'"
        fail=1
    fi
fi

if [[ $fail -ne 0 ]]; then
    echo
    echo "[selftest] FAIL — run-tests.sh did NOT correctly catch the induced failure"
    exit 1
fi

echo "[selftest] PASS — runner correctly caught induced failure"
exit 0
