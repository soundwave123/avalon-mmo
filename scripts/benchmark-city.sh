#!/usr/bin/env bash
# T-210 + T-336: city frame budget — 4 fixed viewpoints, fps/draw-call capture via the pilot's fps
# op. Budget (owner rig class, Ultra): >= 60 fps at every viewpoint.
#
# T-336 (2026-07-11): self-contained like qa-tour.sh. Probes for a live pilot
# (`python3 scripts/pilot.py state`); if none responds, boots its own (day frozen at QA
# afternoon, class panel cleared via the qa-tour.sh poll loop), runs the 4 viewpoints, then
# quits it — but ONLY the pilot this script booted; a caller-supplied live pilot is left running.
# A dead probe (fps=0) is NOT an under-budget world: it fails loudly with a distinct message and
# exit code 2 so gate7 can't mistake "no data" for "slow".
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

BUDGET=${BUDGET:-60}
USER_NAME="${AVALON_BENCH_USER:-benchcity}"
PILOT="python3 $SCRIPT_DIR/pilot.py"
log() { echo "[benchmark-city] $*"; }

declare -a VIEWS=(
    "gate_vista    0   3  -112   0   6"
    "market_square 0   3  -215  45   2"
    "ward_street  -60  3  -190 270   2"
    "wallwalk_pan  0  10  -141 180  -4"
)

booted_own=0

probe_pilot() {
    timeout 8 $PILOT state >/dev/null 2>&1
}

if probe_pilot; then
    log "live pilot responded — reusing it"
else
    log "no live pilot — booting our own (day frozen, class panel poll)"
    AVALON_FREEZE_DAY=0.34 bash "$SCRIPT_DIR/pilot-up.sh" "$USER_NAME" \
        || { log "FATAL: pilot-up failed"; exit 1; }
    booted_own=1
    sleep 6

    # Class picker may stick open (T-320); poll class_panel_visible rather than sleeping blind,
    # re-pressing once midway — same pattern as qa-tour.sh.
    $PILOT key 1 >/dev/null 2>&1
    panel_gone=0
    for i in $(seq 1 30); do
        sleep 2
        vis=$($PILOT state 2>/dev/null | python3 -c \
            "import json,sys;print(json.load(sys.stdin)['state'].get('class_panel_visible'))" \
            2>/dev/null)
        if [[ "$vis" == "False" ]]; then panel_gone=1; break; fi
        [[ "$i" == "8" ]] && $PILOT key 1 >/dev/null 2>&1
    done
    if [[ "$panel_gone" == "1" ]]; then
        log "class panel cleared (${i}x2s)"
    else
        log "FATAL: class panel still visible after 60s — refusing to benchmark"
        $PILOT quit >/dev/null 2>&1
        exit 1
    fi
fi

cleanup() {
    if [[ "$booted_own" == "1" ]]; then
        log "quitting self-booted pilot"
        $PILOT quit >/dev/null 2>&1
    fi
}
trap cleanup EXIT

fail=0
dead=0
for v in "${VIEWS[@]}"; do
    read -r name x y z yaw pitch <<<"$v"
    $PILOT freecam "$x" "$y" "$z" "$yaw" "$pitch" >/dev/null 2>&1
    sleep 2.5   # settle: streaming, shader compiles, particle warmup
    out=$($PILOT fps 2>/dev/null)
    fps=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read() or '{}'); print(int(d.get('fps',0)))" <<<"$out")
    dc=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read() or '{}'); print(int(d.get('draw_calls',0)))" <<<"$out")
    if [ "$fps" -eq 0 ]; then
        printf "  %-14s fps=%-5s draw_calls=%-6s DEAD-PROBE\n" "$name" "$fps" "$dc"
        dead=1
        continue
    fi
    verdict=OK
    if [ "$fps" -lt "$BUDGET" ]; then verdict="UNDER-BUDGET"; fail=1; fi
    printf "  %-14s fps=%-5s draw_calls=%-6s %s\n" "$name" "$fps" "$dc" "$verdict"
done

if [ "$dead" = 1 ]; then
    echo "CITY BENCHMARK: BENCHMARK PROBE DEAD (fps=0 — pilot unresponsive, not an under-budget world)"
    exit 2
fi
if [ "$fail" = 1 ]; then echo "CITY BENCHMARK: FAIL (budget ${BUDGET}fps)"; exit 1; fi
echo "CITY BENCHMARK: PASS (budget ${BUDGET}fps)"
