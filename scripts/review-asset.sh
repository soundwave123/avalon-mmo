#!/usr/bin/env bash
# T-121: capture one GLB from many angles for the structural quality harness.
#   scripts/review-asset.sh <res-path-or-model-name> [out_dir]
# e.g. scripts/review-asset.sh prop_oak2   ->  /tmp/avalon-review/{front,threeq,side,back,base_low,closeup}.png
# Runs the windowed client in review mode (no server needed) and quits when done.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARG="${1:?usage: review-asset.sh <model-name-or-res-path> [out_dir]}"
OUT="${2:-/tmp/avalon-review}"
case "$ARG" in
	res://*) GLB="$ARG" ;;
	*.glb) GLB="res://assets/models/$(basename "$ARG")" ;;
	*) GLB="res://assets/models/${ARG}.glb" ;;
esac
mkdir -p "$OUT"
rm -f "$OUT"/*.png
# A GLB that Godot has never imported wedges the windowed client indefinitely (cost us 30min
# on prop_tavern_v2). If the sidecar .import is missing or older than the GLB, import first.
GLB_FILE="$PROJECT_DIR/client/${GLB#res://}"
if [[ -f "$GLB_FILE" && ( ! -f "$GLB_FILE.import" || "$GLB_FILE" -nt "$GLB_FILE.import" ) ]]; then
	echo "[review] importing new/updated asset first (headless)..."
	timeout 300 "$SCRIPT_DIR/godot-bin.sh" --headless \
		--path "$PROJECT_DIR/client" --import > /dev/null 2>&1
fi
echo "[review] $GLB -> $OUT"
# T-346: route Godot through the single resolver so the 4.6->4.7 cutover is one pin flip.
"$SCRIPT_DIR/godot-bin.sh" \
	--env="AVALON_REVIEW_GLB=$GLB" \
	--env="AVALON_REVIEW_DIR=$OUT" \
	--filesystem=/tmp \
	--path "$PROJECT_DIR/client" --resolution 800x800 2>&1 \
	| grep -aE 'asset-review|Error|SCRIPT ERR' | head
ls "$OUT"/*.png 2>/dev/null | wc -l | xargs echo "[review] captured views:"
# Contact sheet: one montage per asset so a reviewer reads ONE image, not eight (2026-07-09).
if command -v montage >/dev/null; then
	SHEET="$OUT/_sheet.png"
	montage $(ls "$OUT"/*.png | grep -v _sheet) -tile 4x2 -geometry 400x400+2+2 "$SHEET" \
		2>/dev/null && echo "[review] contact sheet: $SHEET"
fi
