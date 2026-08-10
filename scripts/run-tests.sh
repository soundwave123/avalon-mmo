#!/usr/bin/env bash
# Avalon test runner.
#
# PASS CONDITIONS — a project passes only if ALL SEVEN are true:
#   1. godot exited 0
#   2. parsed "Tests" count is > 0           (catches runner-ran-but-found-nothing)
#   3. parsed "Passing Tests" == "Tests"     (catches partial pass / failures)
#   4. output contains "All tests passed!"   (gut's own self-reported sentinel)
#   5. no "Ignoring script"/"Ignoring Inner Class" warning       (T-756, see below)
#   6. gut's summary has no non-zero "Errors" total              (T-756)
#   7. the test count is at or above this project's floor        (T-756)
#
# Any single project failing any condition causes the runner to exit 1.
#
# WHY 5-7 EXIST (T-756). Conditions 1-4 are all downstream of GUT agreeing that a file is
# a test file. When a test script fails to LOAD — a parse error, a bad preload, a renamed
# class_name — GUT does not fail. It logs
#     WARNING: Ignoring script res://tests/test_foo.gd because it does not extend GutTest
# at warning level, drops the script from the collection, runs the remaining ones, and
# prints "All tests passed!" with exit 0. Every one of conditions 1-4 is satisfied by that
# run. The only evidence left is a test count that quietly dropped by however many tests
# were in the dead file — which nobody diffs. A lane hit the sharper version of this live
# while working T-753: `-gtest=res://tests/X.gd` matched nothing, ran ZERO tests, and
# printed "All tests passed!"; only the missing count block betrayed it.
#
# So: condition 5 turns that warning into a hard failure naming the file, condition 6
# catches GUT's own error tally, and condition 7 is the backstop for any silent-drop
# mechanism nobody has thought of yet — if the suite shrinks, the runner goes red and a
# human has to say out loud that the shrink was intended.
#
# USAGE
#   ./scripts/run-tests.sh                       # full suite, all conditions
#   ./scripts/run-tests.sh -gtest=res://tests/test_foo.gd   # one file; floors exempt
#   AVALON_TEST_LOG_DIR=/tmp/mylane ./scripts/run-tests.sh  # parallel-lane isolation
#
# Any extra arguments are appended to the gut command line. If any of them is a selection
# flag (-gtest=, -gselect=, -gunit_test_name=, -ginner_class=, -gdir=, -gprefix=,
# -gsuffix=, -gconfig=) the run is by definition a subset, so the count FLOORS are
# exempted — but conditions 1-6 still apply, including the zero-test trap that started all
# of this.

set -euo pipefail

# tools/server-manager is the T-742 self-host wizard (GUT rides in via its addons/gut
# symlink into client/addons/gut).
PROJECTS=(client server/gateway server/master server/world tools/server-manager)

# T-756 — per-project test-count FLOORS.
#
# Measured live on 2026-08-10 (full green run, this worktree):
#     client 1941 | server/gateway 87 | server/master 797 | server/world 1413
#     tools/server-manager 58
# (The 2026-08-09 audit recorded 1871/87/797/1402/58 — client and world have grown since.)
#
# Each floor is the live count minus ~2% slack, floored to a round number, minimum slack 2.
# The slack exists so that legitimately merging or deleting a handful of redundant tests
# doesn't require a floor bump in the same commit; it is deliberately far smaller than a
# whole test FILE, which is the loss this is here to catch (the smallest test file in the
# repo carries more tests than any of these slacks).
#
# WHEN THIS GATE GOES RED: do not lower the floor to make it pass. Find out which tests
# stopped running first. If the shrink is genuinely intended (tests deleted on purpose),
# raise-or-lower the floor in the SAME commit that deletes them, and say so in the message.
# Floors ratchet UP freely — bumping them after a run that adds tests is always correct.
declare -A TEST_FLOORS=(
    [client]=1900
    [server/gateway]=85
    [server/master]=780
    [server/world]=1385
    [tools/server-manager]=56
)

# Args are either a PROJECT SELECTOR (a bare project name / basename — filters PROJECTS to that
# one, floors exempt because a single project's count differs from the full-suite floor set) or
# gut pass-through flags. A non-flag arg that names no known project is a hard error rather than
# a silently-fatal gut arg (T-762: T-756 forwarded `world` straight to gut → "Unknown arguments"
# → zero tests). Detect gut selection flags too, so their floor-exempt semantics are preserved.
EXTRA_GUT_ARGS=()
SELECTION_MODE=0
SELECTED_PROJECTS=()
for _arg in "$@"; do
    case "$_arg" in
        -gtest|-gtest=*|-gselect|-gselect=*|-gunit_test_name|-gunit_test_name=*|\
        -ginner_class|-ginner_class=*|-gdir|-gdir=*|-gprefix|-gprefix=*|\
        -gsuffix|-gsuffix=*|-gconfig|-gconfig=*)
            SELECTION_MODE=1
            EXTRA_GUT_ARGS+=("$_arg")
            ;;
        -*)
            EXTRA_GUT_ARGS+=("$_arg")
            ;;
        *)
            # Bare word: resolve to a project by full path or basename.
            _matched=""
            for _p in "${PROJECTS[@]}"; do
                if [[ "$_p" == "$_arg" || "${_p##*/}" == "$_arg" ]]; then _matched="$_p"; break; fi
            done
            if [[ -z "$_matched" ]]; then
                echo "[run-tests] FATAL — '$_arg' names no known project. Valid: ${PROJECTS[*]}" >&2
                exit 2
            fi
            SELECTED_PROJECTS+=("$_matched")
            SELECTION_MODE=1
            ;;
    esac
done
if [[ ${#SELECTED_PROJECTS[@]} -gt 0 ]]; then
    PROJECTS=("${SELECTED_PROJECTS[@]}")
fi
if [[ $SELECTION_MODE -eq 1 ]]; then
    echo "[run-tests] SUBSET RUN — selection flag detected; test-count floors are EXEMPT."
    echo "[run-tests] This is NOT a green suite. Conditions 1-6 still apply."
fi

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
        -gexit \
        ${EXTRA_GUT_ARGS[@]+"${EXTRA_GUT_ARGS[@]}"} > "$log" 2>&1
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

    # --- Condition 5 (T-756): GUT silently dropped a script it could not load. ---
    # This is the failure that makes "All tests passed!" a lie. Name the file(s) loudly:
    # the fix is almost always a parse error or a broken preload inside the named script.
    dropped_scripts=""
    if grep -qE 'Ignoring (script|Inner Class)' "$log"; then
        dropped_scripts="$(grep -E 'Ignoring (script|Inner Class)' "$log" | sed 's/\x1b\[[0-9;]*m//g')"
    fi

    # --- Condition 6 (T-756): gut's own Errors total. ---
    # summary.gd only prints this line when the count is non-zero, so its mere presence
    # with a leading non-zero digit is the failure.
    gut_errors=0
    if grep -qE '^Errors[[:space:]]+[1-9]' "$log"; then
        gut_errors="$(grep -E '^Errors[[:space:]]+[1-9]' "$log" | head -1 | awk '{print $NF}')"
    fi

    # --- Condition 7 (T-756): count floor. Exempt on subset runs. ---
    floor="${TEST_FLOORS[$proj]:-0}"
    floor_breached=0
    if [[ $SELECTION_MODE -eq 0 && $floor -gt 0 && $tests_run -lt $floor ]]; then
        floor_breached=1
    fi

    # Seven-condition pass check
    verdict="FAIL"
    fail_reasons=()
    [[ $exit_code -eq 0 ]] || fail_reasons+=("godot exited $exit_code")
    [[ $tests_run -gt 0 ]] || fail_reasons+=("zero tests ran")
    [[ $tests_passed -eq $tests_run ]] || fail_reasons+=("$((tests_run - tests_passed)) failing test(s)")
    [[ $has_all_passed_line -eq 1 ]] || fail_reasons+=("missing 'All tests passed!' sentinel")
    [[ -z "$dropped_scripts" ]] || fail_reasons+=("GUT DROPPED A TEST SCRIPT (see below)")
    [[ "$gut_errors" == "0" ]] || fail_reasons+=("gut reported Errors=$gut_errors")
    [[ $floor_breached -eq 0 ]] || fail_reasons+=("test count $tests_run is BELOW floor $floor")

    if [[ ${#fail_reasons[@]} -eq 0 ]]; then
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
        for r in "${fail_reasons[@]}"; do
            echo "[run-tests]   REASON: $r"
        done
        if [[ -n "$dropped_scripts" ]]; then
            echo "[run-tests]   --- GUT refused to load these, then reported success anyway ---"
            echo "$dropped_scripts" | sed 's/^/[run-tests]   /'
            echo "[run-tests]   Fix the named script (parse error / bad preload / not extending"
            echo "[run-tests]   GutTest). A harness that is not a test must not be named test_*.gd."
        fi
        if [[ $floor_breached -eq 1 ]]; then
            echo "[run-tests]   The suite SHRANK. Find the tests that stopped running before"
            echo "[run-tests]   touching TEST_FLOORS — lowering the floor to go green defeats it."
        fi
        echo "[run-tests]   --- last 30 lines of $log ---"
        tail -30 "$log" | sed 's/^/[run-tests]   /'
    fi
done

# Final summary table
echo
echo "================================================================"
printf "%-22s %8s %8s %8s %8s %10s %8s\n" "PROJECT" "TESTS" "FLOOR" "PASSED" "FAILED" "DURATION" "VERDICT"
echo "----------------------------------------------------------------------------"
for i in "${!SUMMARY_PROJ[@]}"; do
    _floor="${TEST_FLOORS[${SUMMARY_PROJ[$i]}]:-0}"
    [[ $SELECTION_MODE -eq 1 ]] && _floor="exempt"
    printf "%-22s %8s %8s %8s %8s %10s %8s\n" \
        "${SUMMARY_PROJ[$i]}" \
        "${SUMMARY_TESTS[$i]}" \
        "$_floor" \
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
