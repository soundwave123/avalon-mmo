#!/usr/bin/env bash
# T-346: THE single Godot entry point for the whole Avalon pipeline — run-tests, the world/walk-in
# audits + their probes, and the dev stack (dev-up/pilot-up/review-asset) all route through here so
# the Godot 4.6 -> 4.7 migration cutover is ONE line: the GODOT_PIN default below.
#
# Contract — invoke it EXACTLY like the flatpak call you already had, but WITHOUT the leading
# `flatpak run` and WITHOUT the `org.godotengine.Godot` app-id token:
#     scripts/godot-bin.sh [--env=K=V ...] [--filesystem=PATH ...] <godot args...>
#
#   * flatpak-4.6 (live default): re-inserts `flatpak run` + the app-id around your sandbox flags,
#     i.e. reproduces the historical invocation byte-for-byte.
#   * native-4.7: converts each --env=K=V into a real child environment variable (native Godot
#     inherits the process env — no sandbox), drops --filesystem= (native sees the real FS), and
#     execs the binary directly.
#
# exec preserves the PID, so callers that background it and capture $! (dev-up) still get the right
# process. Override the engine for a one-off run without editing this file:
#     AVALON_GODOT_PIN=native-4.7 scripts/godot-bin.sh ...
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────────────────────
# THE PIN. The migration cutover flips exactly this default from flatpak-4.6 to native-4.7.
# T-346 CUTOVER: flipped 2026-07-11 after the on-4.7 pilot smoke + visual-regress re-baseline
# (pinned capture resolution, see pilot-up.sh) + the socket_gaslamp AreaLight3D acceptance shot.
GODOT_PIN="${AVALON_GODOT_PIN:-native-4.7}"
# ─────────────────────────────────────────────────────────────────────────────────────────────

FLATPAK_APP="org.godotengine.Godot"
NATIVE_BIN="${AVALON_GODOT_NATIVE:-$HOME/godot47/godot}"

# Split the leading flatpak sandbox flags (--env= / --filesystem=) from the actual Godot args.
sandbox=()
while [[ $# -gt 0 ]]; do
	case "$1" in
		--env=* | --filesystem=*)
			sandbox+=("$1")
			shift
			;;
		*) break ;;
	esac
done
# "$@" now holds the Godot arguments (--headless, --path, -s, --script, ...).

case "$GODOT_PIN" in
	flatpak-4.6)
		exec flatpak run ${sandbox[@]+"${sandbox[@]}"} "$FLATPAK_APP" "$@"
		;;
	native-4.7)
		for s in ${sandbox[@]+"${sandbox[@]}"}; do
			case "$s" in
				--env=*) export "${s#--env=}" ;;
				# --filesystem=* : native Godot has no sandbox — nothing to grant.
			esac
		done
		if [[ ! -x "$NATIVE_BIN" ]]; then
			echo "godot-bin: native Godot not found/executable at '$NATIVE_BIN'" >&2
			exit 2
		fi
		exec "$NATIVE_BIN" "$@"
		;;
	*)
		echo "godot-bin: unknown AVALON_GODOT_PIN='$GODOT_PIN' (want flatpak-4.6|native-4.7)" >&2
		exit 2
		;;
esac
