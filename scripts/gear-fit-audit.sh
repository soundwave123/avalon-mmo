#!/usr/bin/env bash
# T-423: gear-FIT audit — every EntityVisuals.ARMOR_GLBS piece, attached to its GEAR_BONES bone
# with the exact ARMOR_FIT transform, must land in the correct BODY REGION (helm on the head,
# cuirass on the chest, greaves BELOW the pelvis — never riding up into the stomach). Gate7 runs
# this alongside anim-audit/walkin-audit so a mis-fit can never again pass on eyeballing alone.
# The probe needs client/.godot import caches — run after a test suite / import, not cold.
# AVALON_GEAR_FIT_DUMP=1 prints raw AABB/bone-Y diagnostics.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=$("scripts/godot-bin.sh" --headless --path client --script "$(pwd)/tools/gear_fit_probe.gd" 2>&1)
echo "$OUT" | grep -vE 'Godot Engine|Vulkan|^$'
echo "$OUT" | grep -q 'GEAR-FIT AUDIT: PASS'
