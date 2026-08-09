#!/usr/bin/env bash
# T-142: screenshot-wall.sh — the regression wall.
#
# Drives an ALREADY-RUNNING pilot client (via scripts/pilot.py) to a set of named benchmark
# vistas and captures one screenshot each, so a before/after visual diff is a single command.
# This unblocks the T-172/173/175 QA captures at distant locations (Crystal Lake, the campfire,
# the Highkeep road + core) that the follow-cam can't reach without walking there.
#
# Usage:  scripts/screenshot-wall.sh [OUTDIR]        (default OUTDIR=/tmp/avalon-wall)
#
#   Requires a pilot client already running (AVALON_PILOT=1) — the orchestrator launches it;
#   this script NEVER launches a client. Every pilot call is capped at 30s and fails SOFT: a
#   vista that times out or errors is skipped and the wall keeps going.
#
# CAMERA / YAW CONVENTION  (verified against client/scripts/dev/pilot.gd freecam op +
# client/scripts/world/local_player.gd):
#   Coordinates are world (x, height, z). The freecam sets rotation = (pitch, yaw, 0) in Godot's
#   default YXZ euler order, i.e. basis = Ry(yaw) * Rx(pitch) — identical to the player camera
#   (rotation.y = yaw, camera_arm.rotation.x = pitch). Therefore:
#       * forward is -Z at yaw 0;  +yaw rotates about world +Y  (90 -> -X, 180 -> +Z, 270 -> +X)
#       * pitch < 0 looks DOWN  (the player rig's default is -25 deg)
#
#   The yaws below were DERIVED so each camera actually faces its subject (subject positions read
#   from client/assets/props.json + client/scripts/world/world_view.gd + ambient_fx_layer.gd):
#       village houses ~origin (z -4..+4), Crystal Lake (18,22), campfire (20,12),
#       meadow oak prop_oak2 (13,13), Highkeep gatehouse (0,-101) & keep core (0,-150).
#   NOTE: crystal_lake / campfire / highkeep_road / highkeep_core / meadow_oak were re-aimed from
#   the draft yaws (which pointed 180 deg away from their subjects under the verified convention).
set -uo pipefail

OUTDIR="${1:-/tmp/avalon-wall}"
PILOT="$(cd "$(dirname "$0")" && pwd)/pilot.py"
PY="${PYTHON:-python3}"
FRAMES=30       # let the scene settle (animations, water, wind, weather) before the shot
TIMEOUT=30      # hard cap per pilot call — fail soft past this

# name  x  y  z  yaw  pitch   (see CONVENTION header for how the yaws were derived)
VISTAS=(
	# T-135 layout v2 re-aim: the old pose (2,7,-8 yaw 170) is now INSIDE the relocated tavern's
	# doorway. Shot from west of the road looking +X across the square (well/market/NPCs center,
	# church spire left, lake + watermill right) — the town's beauty angle.
	# T-191 re-aim: real-scale petiolate oaks swallowed the old west pose (-14,11,0) — shot now
	# from the SW meadow, clear of all six crowns, looking NE across smithy/street/tavern/lake.
	"spawn_village  -24   10   -12   235  -13"
	"village_road    0    10   14   0    -25"
	"meadow_oak     -10   6    6    253  -15"
	# First-run findings: the old lake pose (18,8,34) spawned inside the watermill (22,30) —
	# now shot from the west bank looking east (yaw 270 = +X). The campfire was IN the lake and
	# moved to (4,14); its vista follows it.
	"crystal_lake    2    8    22   270  -20"
	"campfire        4    4    20   0    -20"
	"highkeep_road   0    9   -58   0    -15"
	"highkeep_core   0    14  -120  0    -20"
)

mkdir -p "$OUTDIR"

pilot() {  # run a pilot.py command under a hard 30s cap; propagates its exit code
	timeout "$TIMEOUT" "$PY" "$PILOT" "$@"
}

INDEX="$OUTDIR/index.md"
{
	echo "# Screenshot wall — $(date '+%Y-%m-%d %H:%M:%S')"
	echo
	echo "Deterministic benchmark vistas (T-142). Re-shoot after any visual change to diff."
	echo
	echo "| vista | x | y | z | yaw | pitch | shot |"
	echo "|---|---|---|---|---|---|---|"
} >"$INDEX"

shots=0
for row in "${VISTAS[@]}"; do
	read -r name x y z yaw pitch <<<"$row"
	echo "[wall] $name -> ($x,$y,$z) yaw=$yaw pitch=$pitch"
	if ! pilot freecam "$x" "$y" "$z" "$yaw" "$pitch" >/dev/null; then
		echo "[wall] SKIP $name (freecam failed/timeout)"
		echo "| $name | $x | $y | $z | $yaw | $pitch | SKIPPED |" >>"$INDEX"
		continue
	fi
	pilot wait "$FRAMES" >/dev/null || true
	shot="$OUTDIR/$name.png"
	if pilot screenshot "$shot" >/dev/null; then
		echo "| $name | $x | $y | $z | $yaw | $pitch | ![]($name.png) |" >>"$INDEX"
		shots=$((shots + 1))
	else
		echo "[wall] SKIP $name (screenshot failed/timeout)"
		echo "| $name | $x | $y | $z | $yaw | $pitch | FAILED |" >>"$INDEX"
	fi
done

pilot freecam off >/dev/null || true
echo "[wall] done — $shots/${#VISTAS[@]} shots in $OUTDIR (index: $INDEX)"
