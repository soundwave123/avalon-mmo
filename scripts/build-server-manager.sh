#!/usr/bin/env bash
# T-742: cross-export the Avalon Server Manager (the self-host setup wizard) for
# Windows + Linux with the same toolchain as build-launcher.sh, and stage each into a
# zip the server owner unzips INTO the repo/server folder (the exe walks up from its
# own directory to find scripts/windows/run-server.ps1, so the repo root is the
# intended home). v1 deliberately ships as a zip, not an MSI/NSIS installer — building
# a real installer needs Windows tooling this repo's Linux pipeline doesn't have.
#
# Usage: scripts/build-server-manager.sh [--platform linux|windows|both]  (default: both)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANAGER_DIR="$PROJECT_DIR/tools/server-manager"
DIST_DIR="$PROJECT_DIR/dist"
GODOT="$SCRIPT_DIR/godot-bin.sh"
WORK_DIR="$(mktemp -d /tmp/avalon-server-manager-build.XXXXXX)"

WANT="both"
[[ "${1:-}" == "--platform" ]] && WANT="${2:?--platform needs a value}"

log() { printf '[build-server-manager] %s\n' "$*"; }
die() { printf '[build-server-manager] FATAL: %s\n' "$*" >&2; exit 1; }
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

command -v zip >/dev/null 2>&1 || die "missing tool: zip"
[[ -x "$GODOT" ]] || die "godot resolver missing: $GODOT"
[[ -f "$MANAGER_DIR/project.godot" ]] || die "no manager project at $MANAGER_DIR"
mkdir -p "$DIST_DIR" "$WORK_DIR/linux" "$WORK_DIR/windows"

# Import first so class_names and the scene resolve during export.
"$GODOT" --headless --path "$MANAGER_DIR" --import >/dev/null 2>&1 || true

readme() {
	cat > "$1" <<'EOF'
Avalon Server Manager
=====================
Unzip BOTH files into your Avalon server folder (the one that contains
scripts\windows\run-server.bat), then double-click AvalonServerManager.
It walks you through ports, your address, and player accounts — and you can
re-run it any time to change settings.
EOF
}

build_windows() {
	log "Exporting Windows manager..."
	"$GODOT" --headless --path "$MANAGER_DIR" --export-release "Windows Desktop" \
		"$WORK_DIR/windows/AvalonServerManager.exe"
	[[ -f "$WORK_DIR/windows/AvalonServerManager.exe" ]] || die "Windows export produced no .exe"
	[[ -f "$WORK_DIR/windows/AvalonServerManager.pck" ]] || die "Windows export produced no .pck"
	readme "$WORK_DIR/windows/README-SERVER-MANAGER.txt"
	local zip_path="$DIST_DIR/avalon-server-manager-windows.zip"
	rm -f "$zip_path"
	(cd "$WORK_DIR/windows" && zip -q -9 "$zip_path" \
		AvalonServerManager.exe AvalonServerManager.pck README-SERVER-MANAGER.txt)
	log "Wrote $zip_path ($(du -h "$zip_path" | awk '{print $1}'))"
}

build_linux() {
	log "Exporting Linux manager..."
	"$GODOT" --headless --path "$MANAGER_DIR" --export-release "Linux" \
		"$WORK_DIR/linux/AvalonServerManager.x86_64"
	[[ -f "$WORK_DIR/linux/AvalonServerManager.x86_64" ]] || die "Linux export produced no binary"
	[[ -f "$WORK_DIR/linux/AvalonServerManager.pck" ]] || die "Linux export produced no .pck"
	chmod +x "$WORK_DIR/linux/AvalonServerManager.x86_64"
	readme "$WORK_DIR/linux/README-SERVER-MANAGER.txt"
	local zip_path="$DIST_DIR/avalon-server-manager-linux.zip"
	rm -f "$zip_path"
	(cd "$WORK_DIR/linux" && zip -q -9 "$zip_path" \
		AvalonServerManager.x86_64 AvalonServerManager.pck README-SERVER-MANAGER.txt)
	log "Wrote $zip_path ($(du -h "$zip_path" | awk '{print $1}'))"
}

case "$WANT" in
	windows) build_windows ;;
	linux) build_linux ;;
	both) build_windows; build_linux ;;
	*) die "unknown platform: $WANT" ;;
esac
log "Done."
