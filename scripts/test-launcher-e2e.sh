#!/usr/bin/env bash
# T-690 END-TO-END: drive the REAL exported Linux launcher binary through a full delta update.
#
# Scenario: a tester's install is at build A. Build B ships (changed pck + a bumped engine binary).
# We stand up the token-gated dist server with B's manifest + the A->B patch + the new engine, then
# run the actual AvalonUpdater.x86_64 (headless) pointed at a fake install. It must:
#   * download ONLY the small A->B patch (not the full pck), apply it, verify sha -> swap Avalon.pck
#   * re-fetch the engine binary (hash changed) and skip nothing it shouldn't
#   * rewrite server.cfg's build stamp to B
#   * launch the game binary (we stub it with a marker-writing script)
# Asserts bandwidth (patch bytes << full pck) and that the launched binary is the NEW engine.
#
# Requires: a built launcher zip (scripts/build-launcher.sh --platform linux) and zstd.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BP="$SCRIPT_DIR/build-patches.sh"
SRV="$PROJECT_DIR/infra/playtest/dist_server.py"
LAUNCHER_ZIP="$PROJECT_DIR/dist/avalon-launcher-linux.zip"
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
sha() { sha256sum "$1" | awk '{print $1}'; }

[[ -f "$LAUNCHER_ZIP" ]] || { echo "missing $LAUNCHER_ZIP — run scripts/build-launcher.sh --platform linux first"; exit 2; }

TMP="$(mktemp -d /tmp/t690-e2e.XXXXXX)"
DIST="$TMP/dist"; CACHE="$TMP/cache"; INSTALL="$TMP/install"; RUN="$TMP/launcher"; LTMP="$TMP/ltmp"
mkdir -p "$DIST" "$CACHE" "$INSTALL" "$RUN" "$LTMP"

STAMP_A="2026-07-22T010000Z"
STAMP_B="2026-07-23T020000Z"
MARKER="$TMP/LAUNCHED"

# Fake packs: shared 800KB base + small unique tails (like two real builds).
head -c 800000 /dev/urandom > "$TMP/base"
cat "$TMP/base" > "$TMP/A.pck"; head -c 4000 /dev/urandom >> "$TMP/A.pck"
cat "$TMP/base" > "$TMP/B.pck"; head -c 4000 /dev/urandom >> "$TMP/B.pck"

# Fake engine binaries are launchable scripts writing a marker, so we can prove the engine that
# actually gets executed is the NEW one the launcher fetched. They MUST be named Avalon.x86_64 —
# that is the exact name build-patches publishes and the dist-server's engine route allows.
mkdir -p "$TMP/old" "$TMP/new"
printf '#!/bin/sh\necho old > "%s"\n' "$MARKER" > "$TMP/old/Avalon.x86_64"
printf '#!/bin/sh\necho new > "%s"\n' "$MARKER" > "$TMP/new/Avalon.x86_64"
chmod +x "$TMP/old/Avalon.x86_64" "$TMP/new/Avalon.x86_64"

echo "[setup] publish build A then build B (A->B patch + new engine) into dist/"
"$BP" --new-pck "$TMP/A.pck" --stamp "$STAMP_A" --engine-linux "$TMP/old/Avalon.x86_64" \
	--dist "$DIST" --cache "$CACHE" --keep 5 >/dev/null
"$BP" --new-pck "$TMP/B.pck" --stamp "$STAMP_B" --engine-linux "$TMP/new/Avalon.x86_64" \
	--full-zip-linux "avalon-playtest-2026-07-23-linux.zip" \
	--dist "$DIST" --cache "$CACHE" --keep 5 >/dev/null

# The install currently at build A: pck A, OLD engine, server.cfg stamped A, a bundled zstd beside it.
cp "$TMP/A.pck" "$INSTALL/Avalon.pck"
cp "$TMP/old/Avalon.x86_64" "$INSTALL/Avalon.x86_64"; chmod +x "$INSTALL/Avalon.x86_64"
printf '[server]\nhost="127.0.0.1"\nbuild="%s"\n' "$STAMP_A" > "$INSTALL/server.cfg"
cp "$PROJECT_DIR/tools/launcher/vendor/zstd-linux" "$INSTALL/zstd"; chmod +x "$INSTALL/zstd"

# Unzip the REAL launcher and run it (install dir overridden to the fake install).
unzip -q -o "$LAUNCHER_ZIP" -d "$RUN"
chmod +x "$RUN/AvalonUpdater.x86_64"

TOKEN="e2e-tok-$$"
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
AVALON_DIST_TOKEN="$TOKEN" python3 "$SRV" --port "$PORT" --dir "$DIST" >"$TMP/srv.log" 2>&1 &
SRV_PID=$!
trap 'kill "$SRV_PID" 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in $(seq 1 50); do curl -fsS "http://127.0.0.1:$PORT/manifest.json?token=$TOKEN" -o /dev/null 2>/dev/null && break; sleep 0.1; done

patch_size=$(python3 -c "import json;print(json.load(open('$DIST/manifest.json'))['patches'][0]['size'])")
full_size=$(stat -c %s "$TMP/B.pck")

echo "[run] launching the real AvalonUpdater.x86_64 (headless)…"
set +e
AVALON_INSTALL_DIR="$INSTALL" \
AVALON_DIST_BASE_URL="http://127.0.0.1:$PORT" \
AVALON_DIST_TOKEN="$TOKEN" \
AVALON_LAUNCHER_TMP="$LTMP" \
timeout 90 "$RUN/AvalonUpdater.x86_64" --headless >"$TMP/launcher.log" 2>&1
lrc=$?
set -e
# Give the stub game process a moment to write its marker.
for _ in $(seq 1 30); do [[ -f "$MARKER" ]] && break; sleep 0.1; done

echo "[assert]"
[[ $lrc -eq 0 ]] && ok "launcher exited 0 (completed + quit)" || bad "launcher exit=$lrc (see log below)"
[[ "$(sha "$INSTALL/Avalon.pck")" == "$(sha "$TMP/B.pck")" ]] \
	&& ok "Avalon.pck updated A->B via patch, sha verified" || bad "pck not updated to B"
[[ -f "$MARKER" && "$(cat "$MARKER")" == "new" ]] \
	&& ok "launched the NEW engine (engine re-fetched on hash change, then launched)" \
	|| bad "marker='$(cat "$MARKER" 2>/dev/null)' (expected new)"
new_stamp=$(python3 -c "import configparser;c=configparser.ConfigParser();c.read('$INSTALL/server.cfg');print(c['server']['build'].strip('\"'))" 2>/dev/null || echo "?")
[[ "$new_stamp" == "$STAMP_B" ]] && ok "server.cfg build stamp advanced to B" || bad "stamp='$new_stamp' (want $STAMP_B)"
[[ "$patch_size" -lt "$full_size" ]] \
	&& ok "bandwidth: downloaded patch $patch_size B vs full pck $full_size B ($(awk "BEGIN{printf \"%.2f\", $patch_size/$full_size*100}")%)" \
	|| bad "patch not smaller than full"

if [[ $fail -ne 0 ]]; then
	echo "----- launcher.log -----"; tail -30 "$TMP/launcher.log" | sed 's/^/  /'
	echo "----- srv.log -----"; tail -15 "$TMP/srv.log" | sed 's/^/  /'
fi

# ── Scenario B: corruption guard — tamper the published patch; the launcher must reject it and
#    fall back to the full zip download, still ending at a verified build B (never a bad client). ──
echo
echo "[scenario B] tampered patch -> full-download fallback"
INSTALL2="$TMP/install2"; mkdir -p "$INSTALL2"
cp "$TMP/A.pck" "$INSTALL2/Avalon.pck"
cp "$TMP/old/Avalon.x86_64" "$INSTALL2/Avalon.x86_64"; chmod +x "$INSTALL2/Avalon.x86_64"
printf '[server]\nhost="127.0.0.1"\nbuild="%s"\n' "$STAMP_A" > "$INSTALL2/server.cfg"
cp "$PROJECT_DIR/tools/launcher/vendor/zstd-linux" "$INSTALL2/zstd"; chmod +x "$INSTALL2/zstd"
# Publish the real full zip the manifest points at (launcher extracts Avalon.pck from it).
( cd "$TMP" && cp B.pck Avalon.pck && zip -q "$DIST/avalon-playtest-2026-07-23-linux.zip" Avalon.pck && rm Avalon.pck )
# Corrupt the on-server patch so zstd-apply's output fails the sha check.
patch_file="$DIST/patches/$(python3 -c "import json;print(json.load(open('$DIST/manifest.json'))['patches'][0]['file'])")"
printf 'XXXX' | dd of="$patch_file" bs=1 seek=40 count=4 conv=notrunc status=none
MARKER=""; rm -f "$TMP/LAUNCHED"; MARKER="$TMP/LAUNCHED"

set +e
AVALON_INSTALL_DIR="$INSTALL2" \
AVALON_DIST_BASE_URL="http://127.0.0.1:$PORT" \
AVALON_DIST_TOKEN="$TOKEN" \
AVALON_LAUNCHER_TMP="$TMP/ltmp2" \
timeout 90 "$RUN/AvalonUpdater.x86_64" --headless >"$TMP/launcher2.log" 2>&1
lrc2=$?
set -e
for _ in $(seq 1 30); do [[ -f "$MARKER" ]] && break; sleep 0.1; done
[[ $lrc2 -eq 0 ]] && ok "fallback: launcher exited 0" || bad "fallback launcher exit=$lrc2"
[[ "$(sha "$INSTALL2/Avalon.pck")" == "$(sha "$TMP/B.pck")" ]] \
	&& ok "fallback: tampered patch rejected, full download restored a VERIFIED build B" \
	|| bad "fallback: pck not at B (bad-client guard failed)"
[[ -f "$MARKER" ]] && ok "fallback: game still launched after full download" || bad "fallback: no launch"
if [[ $fail -ne 0 ]]; then
	echo "----- launcher2.log -----"; tail -30 "$TMP/launcher2.log" | sed 's/^/  /'
fi

echo
echo "T-690 launcher E2E: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
