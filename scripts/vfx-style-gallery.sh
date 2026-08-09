#!/usr/bin/env bash
# T-343 (owner ruling 2026-07-16): record the ability-VFX STYLE candidate gallery. For each core
# hit type (impact, cast, heal, projectile) it boots the AVALON_VFX_STYLE_GALLERY dev harness once
# per candidate style, on the same fixed side-on stage at the SHIPPED grade, captures a 3-phase
# strip (+ an optional movie-mode clip), then assembles ONE LABELLED contact sheet per hit type so
# the owner can pick a direction async. No server / login / runtime lease (the harness returns
# before the game boot).
#
# Usage: scripts/vfx-style-gallery.sh [hit_type ...]   (default: all four)
#        AVALON_VFX_OUT=/tmp/avalon-review/t343-gallery scripts/vfx-style-gallery.sh impact
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLIENT_DIR="$PROJECT_DIR/client"
JSON="$CLIENT_DIR/scripts/world/vfx_styles.json"
OUT="${AVALON_VFX_OUT:-/tmp/avalon-review/t343-gallery}"
GODOT="org.godotengine.Godot"
FPS="${AVALON_VFX_FPS:-24}"
MOVIE="${AVALON_VFX_MOVIE:-1}"  # 1 = also record an mp4 clip per style; 0 = strips only (faster)
TYPES=("${@:-impact cast heal projectile}")
# shellcheck disable=SC2206
TYPES=(${TYPES[@]})
mkdir -p "$OUT"
log() { echo "[vfx-style-gallery] $*"; }

count_for() { python3 -c "import json;print(len(json.load(open('$JSON'))['$1']))"; }
name_for()  { python3 -c "import json;print(json.load(open('$JSON'))['$1'][$2]['name'])"; }

log "importing assets (once)..."
timeout 180 flatpak run "$GODOT" --path "$CLIENT_DIR" --headless --import >/dev/null 2>&1 || true

for T in "${TYPES[@]}"; do
	N="$(count_for "$T")"
	log "hit type '$T' — $N candidate styles"
	LABELS=()
	STRIPS=()
	for I in $(seq 0 $((N - 1))); do
		NAME="$(name_for "$T" "$I")"
		log "  recording $T #$I ($NAME)..."
		rm -f "$OUT"/style_${T}_${I}_*.png "$OUT/raw_${T}_$I.avi"
		MOVIE_ARGS=()
		[[ "$MOVIE" == "1" ]] && MOVIE_ARGS=(--write-movie "$OUT/raw_${T}_$I.avi" --fixed-fps "$FPS")
		timeout 240 flatpak run \
			--env="AVALON_VFX_GALLERY=1" \
			--env="AVALON_VFX_STYLE_GALLERY=1" \
			--env="AVALON_VFX_STYLE_TYPE=$T" \
			--env="AVALON_VFX_STYLE_INDEX=$I" \
			--env="AVALON_REVIEW_DIR=$OUT" \
			--env="AVALON_VFX_FRAMES=${AVALON_VFX_FRAMES:-120}" \
			--filesystem=/tmp \
			"$GODOT" --path "$CLIENT_DIR" --resolution 1280x720 \
			"${MOVIE_ARGS[@]}" >/dev/null 2>&1
		if [[ "$MOVIE" == "1" && -s "$OUT/raw_${T}_$I.avi" ]]; then
			ffmpeg -y -i "$OUT/raw_${T}_$I.avi" -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" \
				-c:v libx264 -pix_fmt yuv420p -an -movflags +faststart \
				"$OUT/clip_${T}_$I.mp4" >/dev/null 2>&1
			rm -f "$OUT/raw_${T}_$I.avi"
		fi
		if compgen -G "$OUT/style_${T}_${I}_*.png" >/dev/null; then
			# one row per style: ignition | peak | settle
			montage "$OUT/style_${T}_${I}_a.png" "$OUT/style_${T}_${I}_b.png" "$OUT/style_${T}_${I}_c.png" \
				-tile 3x1 -geometry +3+3 -background black "$OUT/strip_${T}_$I.png" >/dev/null 2>&1
			STRIPS+=("$OUT/strip_${T}_$I.png")
			LABELS+=("$I  $NAME")
		else
			log "    !! no frames captured for $T #$I"
		fi
	done
	# one labelled contact sheet per hit type: a stack of style rows
	if [[ ${#STRIPS[@]} -gt 0 ]]; then
		ARGS=()
		for k in "${!STRIPS[@]}"; do ARGS+=(-label "${LABELS[$k]}" "${STRIPS[$k]}"); done
		montage "${ARGS[@]}" -tile 1x -geometry +8+8 -background '#101014' -fill '#e8e8ee' \
			-pointsize 20 -title "T-343 VFX STYLE candidates — ${T^^}" \
			"$OUT/contact_${T}.png" >/dev/null 2>&1
		log "  contact sheet -> $OUT/contact_${T}.png"
	fi
done
log "done: $OUT"
