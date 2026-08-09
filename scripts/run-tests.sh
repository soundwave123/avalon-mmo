#!/usr/bin/env bash
# Avalon test runner.
#
# PASS CONDITIONS — a project passes only if ALL FOUR are true:
#   1. godot exited 0
#   2. parsed "Tests" count is > 0           (catches runner-ran-but-found-nothing)
#   3. parsed "Passing Tests" == "Tests"     (catches partial pass / failures)
#   4. output contains "All tests passed!"   (gut's own self-reported sentinel)
#
# Any single project failing any condition causes the runner to exit 1.

set -euo pipefail

PROJECTS=(client server/gateway server/master server/world)

# Parallel-lane isolation: two concurrent runners sharing one log dir rm -rf each other's logs
# mid-run and the four-condition parse reads a half-written/deleted log as tests=0 (the documented
# /tmp/avalon-tests contention flake). Default path unchanged for tooling that reads it; a lane
# (or a pre-commit gate) sets AVALON_TEST_LOG_DIR to a private dir to run alongside other lanes.
LOG_DIR="${AVALON_TEST_LOG_DIR:-/tmp/avalon-tests}"
rm -rf "$LOG_DIR"
mkdir -p "$LOG_DIR"

# Resolve godot via the single pipeline resolver (T-346) so the 4.6->4.7 cutover is one pin flip.
# Override for a one-off run: AVALON_GODOT_PIN=native-4.7 ./scripts/run-tests.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GODOT="$SCRIPT_DIR/godot-bin.sh"
if [[ ! -x "$GODOT" ]]; then
    echo "[run-tests] FATAL — resolver not found/executable at $GODOT"
    exit 2
fi

# Per-project results
declare -a SUMMARY_PROJ=()
declare -a SUMMARY_TESTS=()
declare -a SUMMARY_PASSED=()
declare -a SUMMARY_FAILED=()
declare -a SUMMARY_DURATION=()
declare -a SUMMARY_VERDICT=()

OVERALL_FAIL=0

for proj in "${PROJECTS[@]}"; do
    proj_slug="${proj//\//_}"
    log="$LOG_DIR/${proj_slug}.log"
    import_log="$LOG_DIR/${proj_slug}.import.log"

    echo "[run-tests] === $proj ==="

    # Import to register GUT class_names (required after .godot cache cleared)
    set +e
    "$GODOT" --headless --path "$proj" --import > "$import_log" 2>&1
    set -e

    start=$(date +%s.%N)
    set +e
    "$GODOT" --headless \
        --path "$proj" \
        -s addons/gut/gut_cmdln.gd \
        -gdir=res://tests \
        -ginclude_subdirs \
        -gexit > "$log" 2>&1
    exit_code=$?
    set -e
    end=$(date +%s.%N)
    duration=$(awk "BEGIN { printf \"%.2f\", $end - $start }")

    # Parse gut summary lines. Format from observed run:
    #   Tests                 2
    #   Passing Tests         2
    tests_run=$(grep -E '^Tests +[0-9]+' "$log" | head -1 | awk '{print $NF}' || echo "")
    tests_passed=$(grep -E '^Passing Tests +[0-9]+' "$log" | head -1 | awk '{print $NF}' || echo "")

    # Default to 0 if parse failed
    [[ -z "$tests_run" ]] && tests_run=0
    [[ -z "$tests_passed" ]] && tests_passed=0

    tests_failed=$((tests_run - tests_passed))

    # Sentinel
    has_all_passed_line=0
    if grep -qF -- "All tests passed!" "$log"; then
        has_all_passed_line=1
    fi

    # Four-condition pass check
    verdict="FAIL"
    if [[ $exit_code -eq 0 ]] \
       && [[ $tests_run -gt 0 ]] \
       && [[ $tests_passed -eq $tests_run ]] \
       && [[ $has_all_passed_line -eq 1 ]]; then
        verdict="PASS"
    else
        OVERALL_FAIL=1
    fi

    SUMMARY_PROJ+=("$proj")
    SUMMARY_TESTS+=("$tests_run")
    SUMMARY_PASSED+=("$tests_passed")
    SUMMARY_FAILED+=("$tests_failed")
    SUMMARY_DURATION+=("${duration}s")
    SUMMARY_VERDICT+=("$verdict")

    echo "[run-tests]   verdict=$verdict tests=$tests_run passed=$tests_passed failed=$tests_failed duration=${duration}s exit=$exit_code"

    if [[ "$verdict" == "FAIL" ]]; then
        echo "[run-tests]   --- last 30 lines of $log ---"
        tail -30 "$log" | sed 's/^/[run-tests]   /'
    fi
done

# Final summary table
echo
echo "================================================================"
printf "%-22s %8s %8s %8s %10s %8s\n" "PROJECT" "TESTS" "PASSED" "FAILED" "DURATION" "VERDICT"
echo "----------------------------------------------------------------"
for i in "${!SUMMARY_PROJ[@]}"; do
    printf "%-22s %8s %8s %8s %10s %8s\n" \
        "${SUMMARY_PROJ[$i]}" \
        "${SUMMARY_TESTS[$i]}" \
        "${SUMMARY_PASSED[$i]}" \
        "${SUMMARY_FAILED[$i]}" \
        "${SUMMARY_DURATION[$i]}" \
        "${SUMMARY_VERDICT[$i]}"
done
echo "================================================================"

if [[ $OVERALL_FAIL -ne 0 ]]; then
    echo "[run-tests] OVERALL: FAIL"
    exit 1
fi

echo "[run-tests] OVERALL: PASS"
exit 0
