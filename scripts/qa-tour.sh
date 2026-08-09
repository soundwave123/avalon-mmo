#!/usr/bin/env bash
# qa-tour.sh — one-boot standard QA screenshot pass (orchestrator efficiency batch, 2026-07-09).
#
# Boots the pilot with the day frozen at QA afternoon (no more sunset-cut screenshot sessions),
# locks a class, walks the standard stations, and emits BOTH the full-res shots and a single
# contact-sheet montage for cheap orchestrator review.
#
# Usage:
#   scripts/qa-tour.sh [outdir] [user]          # default outdir /tmp/avalon-review/qa-tour
#   AVALON_FREEZE_DAY=0.25 scripts/qa-tour.sh   # override frozen time-of-day (default 0.34)
#   scripts/qa-tour.sh --stations-only outdir   # skip montage (montage needs imagemagick)
#
# Stations (world-conventions: -Z=north): village square/well, church+churchyard, farmstead,
# watch-tower, lakeside, King's Road waystone, Highkeep gate, Highkeep market square.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

# GPU graphics guard (595.84 Blackwell Xid-79 wait-mode) — refuse to render locally while locked.
bash "$PROJECT_DIR/scripts/ops/gpu-graphics-guard.sh" || exit 1

MONTAGE=1
if [[ "${1:-}" == "--stations-only" ]]; then MONTAGE=0; shift; fi
OUT="${1:-/tmp/avalon-review/qa-tour}"
USER_NAME="${2:-qatour}"
export AVALON_FREEZE_DAY="${AVALON_FREEZE_DAY:-0.34}"
# T-346: pin ONE capture resolution regardless of this host's persisted user://settings.cfg
# (window_mode/fullscreen from an old manual play session silently resizes the window to the
# host's native display — T-347's cross-host golden trap). pilot-up.sh both boots the window at
# this size AND has main.gd re-enforce it after settings load; qa-tour/visual-regress must never
# drift from each other or from the goldens, so this is exported explicitly here too.
export AVALON_PILOT_RESOLUTION="${AVALON_PILOT_RESOLUTION:-1280x720}"

mkdir -p "$OUT"
PILOT="python3 $SCRIPT_DIR/pilot.py"
log() { echo "[qa-tour] $*"; }

log "Booting pilot (day frozen at $AVALON_FREEZE_DAY) ..."
bash "$SCRIPT_DIR/pilot-up.sh" "$USER_NAME" || { log "FATAL: pilot-up failed"; exit 1; }
sleep 6

# Lock a class if the picker is up, then WAIT UNTIL the panel is actually gone before any
# screenshot (owner rule 2026-07-10: no class-selection window in proof shots). The ack can lag
# 10-20s until T-322 lands, so poll the pilot state rather than sleeping blind; re-press once
# midway in case the first key landed before the panel was ready.
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
	log "FATAL: class panel still visible after 60s — refusing to shoot proof screenshots"
	$PILOT quit >/dev/null 2>&1
	exit 1
fi

# station <name> <x> <y> <z> <yaw> <pitch>
station() {
	local name="$1" x="$2" y="$3" z="$4" yaw="$5" pitch="$6"
	$PILOT freecam "$x" "$y" "$z" "$yaw" "$pitch" >/dev/null 2>&1
	sleep 2.5
	$PILOT screenshot "$OUT/$name.png" >/dev/null 2>&1
	log "shot: $name"
}

station 01_village_square 5.6 2.5 8 0 -8
station 02_church_churchyard 8.8 2.5 -7 0 -6
station 03_farmstead 60 14 16 90 -16
station 04_watchtower 20 2.5 -21 0 -8
station 05_lakeside 12 2.5 22 90 -8
station 06_kings_road 4 2.5 -60 0 -6
station 07_highkeep_gate 0 3 -130 0 -6
station 08_hk_market 0 3 -198 0 -8

$PILOT quit >/dev/null 2>&1

if [[ "$MONTAGE" == "1" ]] && command -v montage >/dev/null; then
	montage "$OUT"/0*.png -tile 4x2 -geometry 640x360+4+4 -label '%t' "$OUT/contact_sheet.png" \
		&& log "contact sheet: $OUT/contact_sheet.png"
else
	log "montage skipped (imagemagick missing or --stations-only)"
fi
log "done — $OUT"
