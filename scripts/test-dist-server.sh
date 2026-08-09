#!/usr/bin/env bash
# T-690 DoD test: the dist-server serves manifest.json + patches/*.zst UNDER the token gate,
# still serves *.zip, and rejects: bad token, traversal, and unknown paths.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRV="$SCRIPT_DIR/../infra/playtest/dist_server.py"
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

TMP="$(mktemp -d /tmp/t690-dist.XXXXXX)"
DIST="$TMP/dist"; mkdir -p "$DIST/patches"
printf '{"latest":"2026-07-23T040000Z","pck":{"sha256":"deadbeef"}}\n' > "$DIST/manifest.json"
printf 'ZSTPATCHBYTES' > "$DIST/patches/pck_a_to_b.zst"
printf 'PK-fake-zip' > "$DIST/avalon-playtest-2026-07-23-linux.zip"
printf 'SECRET' > "$DIST/../secret.txt"   # traversal target one level up

TOKEN="test-tok-123"
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
AVALON_DIST_TOKEN="$TOKEN" python3 "$SRV" --port "$PORT" --dir "$DIST" >"$TMP/srv.log" 2>&1 &
SRV_PID=$!
trap 'kill "$SRV_PID" 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in $(seq 1 50); do curl -fsS "http://127.0.0.1:$PORT/manifest.json?token=$TOKEN" -o /dev/null 2>/dev/null && break; sleep 0.1; done

base="http://127.0.0.1:$PORT"
code() { curl -s -o /dev/null -w '%{http_code}' "$1"; }
body() { curl -s "$1"; }

[[ "$(code "$base/manifest.json?token=$TOKEN")" == "200" ]] && ok "manifest.json 200 with token" || bad "manifest.json not 200"
[[ "$(body "$base/manifest.json?token=$TOKEN")" == *'"latest":"2026-07-23T040000Z"'* ]] && ok "manifest body served" || bad "manifest body wrong"
[[ "$(code "$base/manifest.json")" == "403" ]] && ok "manifest.json 403 without token" || bad "manifest not gated"
[[ "$(code "$base/patches/pck_a_to_b.zst?token=$TOKEN")" == "200" ]] && ok "patch .zst 200 with token" || bad "patch not 200"
[[ "$(body "$base/patches/pck_a_to_b.zst?token=$TOKEN")" == "ZSTPATCHBYTES" ]] && ok "patch bytes served" || bad "patch bytes wrong"
[[ "$(code "$base/patches/pck_a_to_b.zst")" == "403" ]] && ok "patch 403 without token" || bad "patch not gated"
[[ "$(code "$base/avalon-playtest-2026-07-23-linux.zip?token=$TOKEN")" == "200" ]] && ok "zip still served (fallback path)" || bad "zip not served"
# traversal attempts (basename-flattened) must not escape dist/
[[ "$(code "$base/patches/..%2f..%2fsecret.txt?token=$TOKEN")" == "404" ]] && ok "patch traversal rejected" || bad "patch traversal leaked"
[[ "$(code "$base/patches/evil.txt?token=$TOKEN")" == "404" ]] && ok "non-.zst under patches rejected" || bad "non-zst served"

echo
echo "T-690 dist-server: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
