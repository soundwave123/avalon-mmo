#!/usr/bin/env bash
# T-500: reproducible, allowlist-audited Windows + Linux friends-and-family client zips.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLIENT_DIR="$PROJECT_DIR/client"
DIST_DIR="$PROJECT_DIR/dist"
GODOT="$SCRIPT_DIR/godot-bin.sh"

EXPECTED_ENGINE="4.7.1.stable.official.a13da4feb"
TEMPLATE_VERSION="4.7.1.stable"
TEMPLATE_ARCHIVE="Godot_v4.7.1-stable_export_templates.tpz"
TEMPLATE_URL="https://downloads.godotengine.org/?flavor=stable&platform=templates&slug=export_templates.tpz&version=4.7.1"
TEMPLATE_SHA256="86409db6200b6f8fd3230989c2d2002851f3dd18acf11d7bdbafddf5a0dd0f72"

# Owner convenience: infra/playtest/server-host.txt (gitignored) holds the DynDNS hostname so
# zips bake it in with no env needed; env vars still win for one-off builds.
HOST_FILE="$PROJECT_DIR/infra/playtest/server-host.txt"
FILE_HOST=""
[[ -f "$HOST_FILE" ]] && FILE_HOST="$(head -n1 "$HOST_FILE" | tr -d '[:space:]')"
PLAYTEST_HOST="${AVALON_PLAYTEST_HOST:-${AVALON_HOST:-$FILE_HOST}}"
BUILD_DATE="${AVALON_BUILD_DATE:-$(date +%Y-%m-%d)}"
# T-514: build stamp baked into server.cfg + sent to the server at login. ISO-8601 UTC so it is
# monotonic, lexically sortable, and distinguishes same-day rebuilds. Bumping this and restarting
# the stack with AVALON_MIN_BUILD set to it forces older clients to re-download.
BUILD_STAMP="${AVALON_BUILD_STAMP:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
CURRENT_BUILD_FILE="$PROJECT_DIR/infra/playtest/current-build.txt"
DATA_HOME="${XDG_DATA_HOME:-${HOME:?HOME is required to locate Godot export templates}/.local/share}"
CACHE_HOME="${XDG_CACHE_HOME:-${HOME:?HOME is required to cache Godot export templates}/.cache}"
TEMPLATE_DIR="$DATA_HOME/godot/export_templates/$TEMPLATE_VERSION"
CACHE_DIR="$CACHE_HOME/avalon/godot-templates"
ARCHIVE_PATH="$CACHE_DIR/$TEMPLATE_ARCHIVE"
WORK_DIR="$(mktemp -d /tmp/avalon-playtest-build.XXXXXX)"
EXPORT_CLIENT_DIR="$WORK_DIR/client"

log() { printf '[build-playtest] %s\n' "$*"; }
die() { printf '[build-playtest] FATAL: %s\n' "$*" >&2; exit 1; }
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

for tool in curl sha256sum unzip zip zipinfo; do
	command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done
[[ -x "$GODOT" ]] || die "Godot resolver is missing or not executable: $GODOT"
[[ -f "$CLIENT_DIR/export_presets.cfg" ]] || die "missing client/export_presets.cfg"
[[ -f "$PROJECT_DIR/docs/playtest/TESTER-GUIDE.md" ]] || die "missing tester guide"
[[ -n "$PLAYTEST_HOST" ]] || die "set AVALON_PLAYTEST_HOST (or AVALON_HOST) to the public/LAN server hostname"
[[ "$PLAYTEST_HOST" =~ ^[A-Za-z0-9._:-]+$ ]] || die "host must be a bare hostname or IP address (no scheme, port, path, or whitespace)"
[[ "$BUILD_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "AVALON_BUILD_DATE must be YYYY-MM-DD"
[[ "$BUILD_STAMP" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
	|| die "AVALON_BUILD_STAMP must be an ISO-8601 UTC instant (YYYY-MM-DDThh:mm:ssZ)"

install_templates() {
	local required=(
		linux_debug.x86_64
		linux_release.x86_64
		windows_debug_x86_64.exe
		windows_release_x86_64.exe
		version.txt
	)
	local missing=0
	local name
	for name in "${required[@]}"; do
		[[ -f "$TEMPLATE_DIR/$name" ]] || missing=1
	done
	if [[ $missing -eq 0 ]] && [[ "$(<"$TEMPLATE_DIR/version.txt")" == "$TEMPLATE_VERSION" ]]; then
		log "Official export templates already installed: $TEMPLATE_DIR"
		return
	fi

	mkdir -p "$CACHE_DIR" "$TEMPLATE_DIR"
	if [[ ! -f "$ARCHIVE_PATH" ]] || [[ "$(sha256sum "$ARCHIVE_PATH" | awk '{print $1}')" != "$TEMPLATE_SHA256" ]]; then
		log "Downloading official Godot $TEMPLATE_VERSION export templates (1.28 GB)..."
		rm -f "$ARCHIVE_PATH.part"
		curl --fail --location --retry 3 --output "$ARCHIVE_PATH.part" "$TEMPLATE_URL"
		mv "$ARCHIVE_PATH.part" "$ARCHIVE_PATH"
	fi
	local actual_sha
	actual_sha="$(sha256sum "$ARCHIVE_PATH" | awk '{print $1}')"
	[[ "$actual_sha" == "$TEMPLATE_SHA256" ]] || die "export template checksum mismatch: $actual_sha"
	unzip -tq "$ARCHIVE_PATH" >/dev/null || die "export template archive failed integrity check"
	unzip -jo "$ARCHIVE_PATH" \
		templates/linux_debug.x86_64 \
		templates/linux_release.x86_64 \
		templates/windows_debug_x86_64.exe \
		templates/windows_release_x86_64.exe \
		templates/version.txt \
		-d "$TEMPLATE_DIR" >/dev/null
	[[ "$(<"$TEMPLATE_DIR/version.txt")" == "$TEMPLATE_VERSION" ]] || die "installed template version mismatch"
	log "Installed official Godot $TEMPLATE_VERSION Windows + Linux templates"
}

write_server_config() {
	local destination="$1"
	printf '[server]\nhost="%s"\nbuild="%s"\n' "$PLAYTEST_HOST" "$BUILD_STAMP" > "$destination"
}

audit_stage() {
	local stage="$1"
	local binary="$2"
	local actual expected
	actual="$(find "$stage" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort)"
	expected="$(printf '%s\n' "$binary" Avalon.pck server.cfg TESTER-GUIDE.md | LC_ALL=C sort)"
	[[ "$actual" == "$expected" ]] || die "stage allowlist mismatch in $stage; found: ${actual//$'\n'/, }"
	if find "$stage" -mindepth 1 -type f \
		\( -name '.env*' -o -name '*.gd' -o -name '*.tscn' -o -name '*.tres' -o \
		-name '*.import' -o -name '*.sh' -o -name '*.py' -o -name '*.key' -o -name '*.pem' \) \
		-print -quit | grep -q .; then
		die "stage contains source, secret, or developer-tool files: $stage"
	fi
	if grep -Eqi 'JWT_SECRET|PG_PASSWORD|BEGIN (RSA |EC )?PRIVATE KEY|password[[:space:]]*=' \
		"$stage/server.cfg" "$stage/TESTER-GUIDE.md"; then
		die "stage text files contain a secret marker"
	fi
	grep -Fqx "host=\"$PLAYTEST_HOST\"" "$stage/server.cfg" || die "staged server.cfg host mismatch"
	log "AUDIT PASS: $(basename "$stage") contains only $binary, Avalon.pck, server.cfg, TESTER-GUIDE.md"
}

package_stage() {
	local platform="$1"
	local stage="$2"
	local binary="$3"
	local zip_path="$DIST_DIR/avalon-playtest-$BUILD_DATE-$platform.zip"
	rm -f "$zip_path"
	(cd "$stage" && zip -q -9 "$zip_path" "$binary" Avalon.pck server.cfg TESTER-GUIDE.md)
	local zip_files expected
	zip_files="$(zipinfo -1 "$zip_path" | LC_ALL=C sort)"
	expected="$(printf '%s\n' "$binary" Avalon.pck server.cfg TESTER-GUIDE.md | LC_ALL=C sort)"
	[[ "$zip_files" == "$expected" ]] || die "zip allowlist mismatch: $zip_path"
	log "Wrote $zip_path ($(du -h "$zip_path" | awk '{print $1}'))"
}

engine_version="$($GODOT --version)"
[[ "$engine_version" == "$EXPECTED_ENGINE" ]] || die "engine mismatch: expected $EXPECTED_ENGINE, got $engine_version"

# T-746: Detect-3D only fires in a live editor render, so a headless-only pipeline silently
# imports every 3D texture as Lossless — a ~1 GB pck and ~1.4 GB of texture VRAM. This is a
# read-only guard: it fails the build rather than shipping that, and prints the fix. Cheap
# (parses .import sidecars, no engine call), so it runs before the expensive template step.
log "Verifying 3D texture import policy (T-746)..."
python3 "$PROJECT_DIR/tools/texture_import_policy.py" --project "$CLIENT_DIR" --check --quiet \
	|| die "3D textures are not VRAM-compressed; run tools/texture_import_policy.py --project client && $GODOT --headless --path client --import"

install_templates

log "Preparing isolated client snapshot (the source tree will not be imported or modified)..."
cp -a --reflink=auto "$CLIENT_DIR" "$EXPORT_CLIENT_DIR"
rm -rf "$EXPORT_CLIENT_DIR/tests" "$EXPORT_CLIENT_DIR/addons/gut"
mkdir -p "$WORK_DIR/windows" "$WORK_DIR/linux" "$DIST_DIR"
log "Exporting Windows Desktop release with Godot $engine_version..."
"$GODOT" --headless --path "$EXPORT_CLIENT_DIR" --export-release "Windows Desktop" "$WORK_DIR/windows/Avalon.exe"
log "Exporting Linux release with Godot $engine_version..."
"$GODOT" --headless --path "$EXPORT_CLIENT_DIR" --export-release "Linux" "$WORK_DIR/linux/Avalon.x86_64"

for stage in "$WORK_DIR/windows" "$WORK_DIR/linux"; do
	write_server_config "$stage/server.cfg"
	cp "$PROJECT_DIR/docs/playtest/TESTER-GUIDE.md" "$stage/TESTER-GUIDE.md"
done
chmod +x "$WORK_DIR/linux/Avalon.x86_64"

audit_stage "$WORK_DIR/windows" Avalon.exe
audit_stage "$WORK_DIR/linux" Avalon.x86_64
package_stage windows "$WORK_DIR/windows" Avalon.exe
package_stage linux "$WORK_DIR/linux" Avalon.x86_64

# T-690: delta-patch + manifest generation for the tester auto-updater. The Windows and Linux
# exports embed the SAME resource pack (identical export filters + texture format), so the launcher
# treats Avalon.pck as one cross-platform artifact — assert that invariant before publishing a single
# pck hash in the manifest, and fail loudly if a future preset change breaks it.
win_pck_sha="$(sha256sum "$WORK_DIR/windows/Avalon.pck" | awk '{print $1}')"
lin_pck_sha="$(sha256sum "$WORK_DIR/linux/Avalon.pck" | awk '{print $1}')"
[[ "$win_pck_sha" == "$lin_pck_sha" ]] \
	|| die "Windows/Linux Avalon.pck diverged ($win_pck_sha vs $lin_pck_sha); the single-pck delta model needs revisiting"
if [[ "${AVALON_SKIP_PATCHES:-0}" != "1" ]]; then
	PACK_CACHE_DIR="$CACHE_HOME/avalon/playtest-packs"
	log "Generating delta patches + manifest (cache: $PACK_CACHE_DIR)..."
	"$SCRIPT_DIR/build-patches.sh" \
		--new-pck "$WORK_DIR/linux/Avalon.pck" \
		--stamp "$BUILD_STAMP" \
		--engine-linux "$WORK_DIR/linux/Avalon.x86_64" \
		--engine-windows "$WORK_DIR/windows/Avalon.exe" \
		--full-zip-linux "avalon-playtest-$BUILD_DATE-linux.zip" \
		--full-zip-windows "avalon-playtest-$BUILD_DATE-windows.zip" \
		--dist "$DIST_DIR" \
		--cache "$PACK_CACHE_DIR" \
		--keep "${AVALON_PATCH_KEEP:-5}"
	log "manifest.json + patches written to $DIST_DIR (served by dist_server.py under the token gate)"
else
	log "AVALON_SKIP_PATCHES=1 — skipped delta/manifest generation"
fi

# T-514: record the stamp this build carries so the stack can require it (AVALON_MIN_BUILD).
printf '%s\n' "$BUILD_STAMP" > "$CURRENT_BUILD_FILE"
log "build stamp $BUILD_STAMP recorded to $CURRENT_BUILD_FILE"
log "PASS: both playtest archives exported and allowlist-audited for host $PLAYTEST_HOST"
