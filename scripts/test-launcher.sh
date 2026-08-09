#!/usr/bin/env bash
# T-690: run the launcher's headless update-logic unit tests (update_logic.gd) via the pipeline
# Godot resolver. No GUT dependency — the runner is a plain SceneTree script that exits non-zero
# on any failing assertion.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GODOT="$SCRIPT_DIR/godot-bin.sh"
LAUNCHER_DIR="$SCRIPT_DIR/../tools/launcher"
export AVALON_LAUNCHER_TMP="${AVALON_LAUNCHER_TMP:-$(mktemp -d /tmp/t690-launcher.XXXXXX)}"

# Register class_names / import resources first (mirrors run-tests.sh).
"$GODOT" --headless --path "$LAUNCHER_DIR" --import >/dev/null 2>&1 || true
"$GODOT" --headless --path "$LAUNCHER_DIR" -s res://tests/run_logic_tests.gd
