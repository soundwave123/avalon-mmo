#!/usr/bin/env bash
# T-343: record the frost-bolt VFX candidate gallery. Boots the AVALON_VFX_GALLERY dev harness
# once per preset (a fixed side-on stage — mage casts at a Training Dummy), records under Godot
# MOVIE MODE (--write-movie + --fixed-fps 24: deterministic fixed-dt frames, true full-rate
# motion — round-1's wall-clock captures time-compressed the action), and assembles a clip +
# 3-frame strip + contact sheet. The stage renders at the SHIPPED glow/tonemap (honesty rule).
# No server / login / runtime lease needed (the harness returns before the game boot).
#
# Usage: scripts/vfx-gallery.sh [first_preset] [last_preset]   (defaults: 0 .. count-1)
#        AVALON_VFX_OUT=/tmp/avalon-review/t343r2 scripts/vfx-gallery.sh 13 18
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLIENT_DIR="$PROJECT_DIR/client"
OUT="${AVALON_VFX_OUT:-/tmp/avalon-review/t343}"
GODOT="org.godotengine.Godot"
FPS="${AVALON_VFX_FPS:-24}"
FIRST="${1:-0}"
# authoritative preset count = entries in the JSON preset table
COUNT="$(python3 -c "import json,sys; print(len(json.load(open('$CLIENT_DIR/scripts/world/vfx_presets.json'))['presets']))")"
LAST="${2:-$((COUNT - 1))}"
mkdir -p "$OUT"
log() { echo "[vfx-gallery] $*"; }

# One editor import pass so vendored particle textures are usable at runtime.
log "importing assets (once)..."
timeout 180 flatpak run "$GODOT" --path "$CLIENT_DIR" --headless --import >/dev/null 2>&1 || true

STRIPS=()
for N in $(seq "$FIRST" "$LAST"); do
	log "recording preset $N (movie mode, ${FPS}fps fixed)..."
	rm -f "$OUT"/strip_${N}_*.png "$OUT/raw_$N.avi"
	timeout 300 flatpak run \
		--env="AVALON_VFX_GALLERY=1" \
		--env="AVALON_VFX_PRESET=$N" \
		--env="AVALON_REVIEW_DIR=$OUT" \
		--env="AVALON_VFX_FRAMES=${AVALON_VFX_FRAMES:-96}" \
		--filesystem=/tmp \
		"$GODOT" --path "$CLIENT_DIR" --resolution 1280x720 \
		--write-movie "$OUT/raw_$N.avi" --fixed-fps "$FPS" >/dev/null 2>&1
	if [[ -s "$OUT/raw_$N.avi" ]]; then
		# T-343 p2: the gallery now runs an AudioManager and fires the ability SFX at the VFX beats;
		# Godot movie mode records the audio bus INTERLEAVED into raw_$N.avi (pcm stereo). Carry that
		# stream into the mp4 (re-encoded to AAC) so the ballot is no longer silent — no separate wav
		# is produced by this engine build. If the AVI has no audio stream, ffmpeg simply maps none.
		ffmpeg -y -i "$OUT/raw_$N.avi" \
			-vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" \
			-c:v libx264 -pix_fmt yuv420p -c:a aac \
			-movflags +faststart "$OUT/variant_$N.mp4" >/dev/null 2>&1
		rm -f "$OUT/raw_$N.avi"
		if compgen -G "$OUT/strip_${N}_*.png" >/dev/null; then
			montage "$OUT/strip_${N}_cast.png" "$OUT/strip_${N}_flight.png" "$OUT/strip_${N}_impact.png" \
				-tile 3x1 -geometry +4+4 -background black "$OUT/strip_$N.png" >/dev/null 2>&1
			STRIPS+=("$OUT/strip_$N.png")
		fi
		log "  -> variant_$N.mp4 + strip_$N.png"
	else
		log "  !! no movie captured for preset $N (check the harness boot)"
	fi
done

# One numbered contact sheet of every strip.
if [[ ${#STRIPS[@]} -gt 0 ]]; then
	montage "${STRIPS[@]}" -tile 2x -geometry +6+6 -background '#101014' \
		-title "T-343 Frost-Bolt VFX Gallery" "$OUT/contact_sheet.png" >/dev/null 2>&1
	log "contact sheet -> $OUT/contact_sheet.png"
fi
log "done: $OUT"
