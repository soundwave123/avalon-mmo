#!/usr/bin/env bash
# T-141: performance-budget gate. Captures live RAM/VRAM usage (and folds in a viewpoints fps
# file from scripts/benchmark-city.sh if given), then enforces the tier budget via
# tools/perf/perf_budget.py — exit 1 on any under-budget viewpoint OR headroom alert (>=90%
# used = under the owner's 10% headroom rule). Usage:
#   scripts/perf-audit.sh [--preset ultra|high|medium|low] [viewpoints.json]
# viewpoints.json (optional): {"viewpoints":[{"name","fps","draw_calls"}, ...]}
set -uo pipefail
cd "$(dirname "$0")/.."

PRESET="ultra"
VIEWPOINTS_FILE=""
while [ $# -gt 0 ]; do
	case "$1" in
		--preset) PRESET="$2"; shift 2 ;;
		*) VIEWPOINTS_FILE="$1"; shift ;;
	esac
done

# RAM used % from /proc/meminfo (MemTotal vs MemAvailable — matches the batch runner's probe).
ram_used_pct() {
	awk '/MemTotal:/{t=$2} /MemAvailable:/{a=$2} END{ if(t>0) printf "%.1f", 100*(t-a)/t; else print "" }' /proc/meminfo
}
# VRAM used % from nvidia-smi (blank if no GPU present — the gate then skips the VRAM alert).
vram_used_pct() {
	command -v nvidia-smi >/dev/null 2>&1 || { echo ""; return; }
	nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null \
		| awk -F', ' 'NR==1 && $2>0 { printf "%.1f", 100*$1/$2 }'
}

RAM=$(ram_used_pct)
VRAM=$(vram_used_pct)
echo "[perf-audit] preset=$PRESET ram_used=${RAM:-?}% vram_used=${VRAM:-n/a}%"

# Build the metrics JSON: viewpoints from the file (if any) + the live resource usage.
METRICS=$(python3 - "$VIEWPOINTS_FILE" "$RAM" "$VRAM" <<'PY'
import json, sys
vp_file, ram, vram = sys.argv[1], sys.argv[2], sys.argv[3]
m = {"viewpoints": []}
if vp_file:
    with open(vp_file) as f:
        m["viewpoints"] = json.load(f).get("viewpoints", [])
if ram:
    m["ram_used_pct"] = float(ram)
if vram:
    m["vram_used_pct"] = float(vram)
print(json.dumps(m))
PY
)

echo "$METRICS" > /tmp/avalon-perf-metrics.json
python3 tools/perf/perf_budget.py /tmp/avalon-perf-metrics.json --preset "$PRESET"
