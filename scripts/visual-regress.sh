#!/usr/bin/env bash
# visual-regress.sh — T-338: golden-image visual regression harness over the 8 qa-tour stations.
#
# Evaluated GDSnap (addons/gdsnap) vs an ImageMagick `compare` wrapper (see T-338 work item 1);
# picked the wrapper — no addon vendoring, no .import risk (standing orders §8), and
# ImageMagick is already a qa-tour.sh/benchmark-city.sh pipeline dependency.
#
# Modes:
#   --baseline "<reason>"   shoot the 8 qa-tour stations, store as goldens, REQUIRE a reason
#                            (orchestrator-noted, per T-338 work item 2)
#   (default)                re-shoot the 8 stations, RMSE-diff each against its golden; on
#                            drift past threshold, write a side-by-side diff PNG + exit nonzero
#
# Threshold tuning (documented honestly — see T-338 report for the live numbers):
#   qa-tour stations are NOT static: NPC wander (npc_wander.gd/critter_wander.gd) and cloud
#   drift (ambient_fx_layer.gd) move independently of the camera. A pixel-exact compare would
#   false-fail every run. AVALON_FREEZE_DAY pins the sun angle but not cloud position or NPC
#   position. Mitigation used here: (a) RMSE metric (not AE/PAE) — a global "how different are
#   we on average" score tolerates a moving sprite-sized patch far better than a per-pixel exact
#   count; (b) a PER-STATION threshold, because NPC-path proximity is wildly uneven across the 8
#   stations. Empirical baseline (two clean same-scene re-shoots, no repo changes):
#     01_village_square   RMSE ~0.091  (courier/villager NPCs walk right up to this camera —
#                                        busiest station by far)
#     02..08 (all others)  RMSE ~0.007-0.015 (empty terrain/building shots, no NPC path nearby)
#   Global default is 0.06 (5x the quiet-station noise floor); 01_village_square gets its own
#   0.15 override (still ~1.6x its observed noise, well under the forced-fail magnitude — a
#   camera offset produced RMSE far higher, see T-338 report). Do NOT raise the global default to
#   paper over a real regression — raise a single station's override only, and only if that
#   station is independently confirmed to sit on a busy NPC path.
#
# Usage:
#   scripts/visual-regress.sh --baseline "reason for (re)baselining"
#   scripts/visual-regress.sh                     # default: diff mode
#   AVALON_VISUAL_RMSE_THRESHOLD=0.08 scripts/visual-regress.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

GOLDEN_DIR="docs/verification/golden/qa-tour"
DIFF_OUT="/tmp/avalon-review/visual-regress"
THRESHOLD="${AVALON_VISUAL_RMSE_THRESHOLD:-0.06}"
USER_NAME="${AVALON_VISUAL_USER:-visualregress}"
PILOT="python3 $SCRIPT_DIR/pilot.py"
# T-346: pin ONE capture resolution — this is a golden-image RMSE compare, so a resolution drift
# reads as a uniform false regression across every station (T-347 hit this: goldens baked at
# 1920x1080, a later host rendered 2560x1440 because its persisted user://settings.cfg carried
# fullscreen from an old manual play session). qa-tour.sh exports the same variable; pilot-up.sh
# is the single place that both boots the window at this size and has main.gd re-enforce it.
export AVALON_PILOT_RESOLUTION="${AVALON_PILOT_RESOLUTION:-1280x720}"

# Per-station threshold overrides (see tuning note above). Station name -> RMSE threshold.
declare -A STATION_THRESHOLD=(
	[01_village_square]="${AVALON_VISUAL_RMSE_01:-0.15}"
)
threshold_for() {
	local s="$1"
	echo "${STATION_THRESHOLD[$s]:-$THRESHOLD}"
}

log() { echo "[visual-regress] $*"; }

STATIONS=(
	01_village_square
	02_church_churchyard
	03_farmstead
	04_watchtower
	05_lakeside
	06_kings_road
	07_highkeep_gate
	08_hk_market
)

MODE="diff"
REASON=""
if [[ "${1:-}" == "--baseline" ]]; then
	MODE="baseline"
	REASON="${2:-}"
	if [[ -z "$REASON" ]]; then
		log "FATAL: --baseline requires a reason, e.g.:"
		log "  scripts/visual-regress.sh --baseline \"T-338 initial golden bake\""
		exit 1
	fi
fi

command -v magick >/dev/null || { log "FATAL: imagemagick (magick) not found"; exit 1; }

# --- shoot the 8 stations into a fresh temp dir via qa-tour.sh's own self-contained boot ------
SHOOT_DIR="$(mktemp -d /tmp/avalon-visual-regress.XXXXXX)"
log "shooting stations into $SHOOT_DIR (mode=$MODE) ..."
if ! bash "$SCRIPT_DIR/qa-tour.sh" --stations-only "$SHOOT_DIR" "$USER_NAME"; then
	log "FATAL: qa-tour.sh shoot failed"
	rm -rf "$SHOOT_DIR"
	exit 1
fi

if [[ "$MODE" == "baseline" ]]; then
	mkdir -p "$GOLDEN_DIR"
	for s in "${STATIONS[@]}"; do
		src="$SHOOT_DIR/$s.png"
		[[ -f "$src" ]] || { log "FATAL: missing shot $src"; rm -rf "$SHOOT_DIR"; exit 1; }
		magick "$src" -quality 90 "$GOLDEN_DIR/$s.jpg"
		log "golden: $GOLDEN_DIR/$s.jpg"
	done
	{
		echo "# Golden re-bake log"
		echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)  reason: $REASON"
	} >>"$GOLDEN_DIR/REASON.txt"
	log "baseline complete — reason logged in $GOLDEN_DIR/REASON.txt"
	rm -rf "$SHOOT_DIR"
	exit 0
fi

# --- diff mode: RMSE-compare each station against its golden -----------------------------------
mkdir -p "$DIFF_OUT"
rm -f "$DIFF_OUT"/*.png 2>/dev/null
FAIL=0
for s in "${STATIONS[@]}"; do
	golden="$GOLDEN_DIR/$s.jpg"
	shot="$SHOOT_DIR/$s.png"
	if [[ ! -f "$golden" ]]; then
		log "SKIP $s — no golden (run --baseline first)"
		continue
	fi
	if [[ ! -f "$shot" ]]; then
		log "FAIL $s — no re-shoot captured"
		FAIL=1
		continue
	fi
	# `compare -metric RMSE` prints "<abs> (<normalized 0..1>)" to stderr; capture the normalized
	# figure. Resize the shot to the golden's geometry first in case station framing changed size.
	rmse_raw=$(magick compare -metric RMSE "$shot" "$golden" null: 2>&1 || true)
	rmse=$(echo "$rmse_raw" | grep -oP '\(\K[0-9.]+(?=\))' | head -1)
	if [[ -z "$rmse" ]]; then
		log "FAIL $s — could not parse RMSE from: $rmse_raw"
		FAIL=1
		continue
	fi
	t="$(threshold_for "$s")"
	over=$(python3 -c "print(1 if $rmse > $t else 0)")
	if [[ "$over" == "1" ]]; then
		log "FAIL $s — RMSE=$rmse > threshold=$t"
		diff_png="$DIFF_OUT/${s}_diff.png"
		sbs_png="$DIFF_OUT/${s}_sidebyside.png"
		magick compare "$shot" "$golden" "$diff_png" 2>/dev/null || true
		magick montage "$golden" "$shot" "$diff_png" -tile 3x1 -geometry 480x270+4+4 \
			-label '%f' "$sbs_png" 2>/dev/null || true
		FAIL=1
	else
		log "PASS $s — RMSE=$rmse <= threshold=$t"
	fi
done

rm -rf "$SHOOT_DIR"

if [[ "$FAIL" == "1" ]]; then
	log "VISUAL REGRESSION: FAIL — diffs in $DIFF_OUT"
	exit 1
fi
log "VISUAL REGRESSION: PASS — all stations within threshold ($THRESHOLD)"
exit 0
