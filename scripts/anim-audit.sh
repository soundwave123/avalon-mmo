#!/usr/bin/env bash
# T-397: animation-coverage audit — every registered rig x required state must resolve through
# EntityVisuals.STATE_CLIPS AND move the skeleton. Gate7 §1 runs this; exits nonzero on FAIL.
# The probe needs client/.godot import caches — run after a test suite / import, not cold.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=$("scripts/godot-bin.sh" --headless --path client --script "$(pwd)/tools/anim_probe.gd" 2>&1)
echo "$OUT" | grep -vE 'Godot Engine|Vulkan|^$'
echo "$OUT" | grep -q 'ANIM AUDIT: PASS'
