#!/usr/bin/env bash
# T-690: cross-export the Avalon tester auto-updater launcher for Windows + Linux (same toolchain
# and Godot templates as build-playtest.sh), and stage each into a small zip the tester unzips INTO
# their game folder. Each zip carries: the launcher binary, its .pck, and a bundled zstd (Windows
# testers have no zstd). The tester runs the launcher instead of the game; it delta-updates the
# install and launches Avalon.
#
# Usage: scripts/build-launcher.sh [--platform linux|windows|both]  (default: both)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LAUNCHER_DIR="$PROJECT_DIR/tools/launcher"
VENDOR_DIR="$LAUNCHER_DIR/vendor"
DIST_DIR="$PROJECT_DIR/dist"
GODOT="$SCRIPT_DIR/godot-bin.sh"
WORK_DIR="$(mktemp -d /tmp/avalon-launcher-build.XXXXXX)"

WANT="both"
[[ "${1:-}" == "--platform" ]] && WANT="${2:?--platform needs a value}"

log() { printf '[build-launcher] %s\n' "$*"; }
die() { printf '[build-launcher] FATAL: %s\n' "$*" >&2; exit 1; }
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

for tool in zip; do command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool"; done
[[ -x "$GODOT" ]] || die "godot resolver missing: $GODOT"
[[ -f "$LAUNCHER_DIR/project.godot" ]] || die "no launcher project at $LAUNCHER_DIR"
mkdir -p "$DIST_DIR" "$WORK_DIR/linux" "$WORK_DIR/windows"

# Import first so class_name UpdateLogic / the scene resolve during export.
"$GODOT" --headless --path "$LAUNCHER_DIR" --import >/dev/null 2>&1 || true

build_linux() {
	log "Exporting Linux launcher..."
	"$GODOT" --headless --path "$LAUNCHER_DIR" --export-release "Linux" "$WORK_DIR/linux/AvalonUpdater.x86_64"
	[[ -f "$WORK_DIR/linux/AvalonUpdater.x86_64" ]] || die "Linux launcher export produced no binary"
	[[ -f "$WORK_DIR/linux/AvalonUpdater.pck" ]] || die "Linux launcher export produced no .pck"
	[[ -f "$VENDOR_DIR/zstd-linux" ]] || die "missing bundled Linux zstd: $VENDOR_DIR/zstd-linux"
	cp "$VENDOR_DIR/zstd-linux" "$WORK_DIR/linux/zstd"
	chmod +x "$WORK_DIR/linux/AvalonUpdater.x86_64" "$WORK_DIR/linux/zstd"
	local zip_path="$DIST_DIR/avalon-launcher-linux.zip"
	rm -f "$zip_path"
	(cd "$WORK_DIR/linux" && zip -q -9 "$zip_path" AvalonUpdater.x86_64 AvalonUpdater.pck zstd)
	log "Wrote $zip_path ($(du -h "$zip_path" | awk '{print $1}'))"
}

build_windows() {
	log "Exporting Windows launcher..."
	"$GODOT" --headless --path "$LAUNCHER_DIR" --export-release "Windows Desktop" "$WORK_DIR/windows/AvalonUpdater.exe"
	[[ -f "$WORK_DIR/windows/AvalonUpdater.exe" ]] || die "Windows launcher export produced no .exe"
	[[ -f "$WORK_DIR/windows/AvalonUpdater.pck" ]] || die "Windows launcher export produced no .pck"
	[[ -f "$VENDOR_DIR/zstd-win64.exe" ]] || die "missing bundled Windows zstd: $VENDOR_DIR/zstd-win64.exe"
	cp "$VENDOR_DIR/zstd-win64.exe" "$WORK_DIR/windows/zstd.exe"
	local zip_path="$DIST_DIR/avalon-launcher-windows.zip"
	rm -f "$zip_path"
	(cd "$WORK_DIR/windows" && zip -q -9 "$zip_path" AvalonUpdater.exe AvalonUpdater.pck zstd.exe)
	log "Wrote $zip_path ($(du -h "$zip_path" | awk '{print $1}'))"
}

case "$WANT" in
	linux) build_linux ;;
	windows) build_windows ;;
	both) build_linux; build_windows ;;
	*) die "unknown --platform '$WANT' (want linux|windows|both)" ;;
esac
log "PASS: launcher export(s) staged into $DIST_DIR"
