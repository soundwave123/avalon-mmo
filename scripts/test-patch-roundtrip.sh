#!/usr/bin/env bash
# T-690 DoD test: exercise the REAL build-patches.sh pipeline end-to-end with tiny fake "packs"
# (proves the pipeline, not the 936 MB). Asserts:
#   1. zstd --patch-from round-trip: applied pack sha256 == fresh pack sha256
#   2. the emitted patch is dramatically smaller than the full pack (the bandwidth win)
#   3. manifest.json is well-formed and carries the right latest stamp, pck sha, engine hashes, edge
#   4. a THIRD build reuses the cached packs and produces two edges (multi-edge, to-latest only)
#   5. --keep prunes cached packs + edges beyond N
#   6. corruption guard: a tampered patch's applied output sha256 != manifest -> caught (fallback)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BP="$SCRIPT_DIR/build-patches.sh"
LONG=30
pass=0; fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
sha()  { sha256sum "$1" | awk '{print $1}'; }
jq_get() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))$2)" "$1"; }

TMP="$(mktemp -d /tmp/t690-roundtrip.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
DIST="$TMP/dist"; CACHE="$TMP/cache"; mkdir -p "$DIST" "$CACHE"

# fake engine binaries (unchanged across builds A/B, changed at C to prove skip vs refetch)
head -c 5000 /dev/urandom > "$TMP/eng_linux"
head -c 5000 /dev/urandom > "$TMP/eng_win"

make_pack() { # $1=out  build a ~500KB pack sharing a common base + a small unique tail
	cat "$TMP/base" > "$1"; head -c 3000 /dev/urandom >> "$1"
}
head -c 500000 /dev/urandom > "$TMP/base"

echo "[1] build A (no priors -> 0 edges)"
make_pack "$TMP/A.pck"
"$BP" --new-pck "$TMP/A.pck" --stamp "2026-07-20T010000Z" \
	--engine-linux "$TMP/eng_linux" --engine-windows "$TMP/eng_win" \
	--dist "$DIST" --cache "$CACHE" --keep 5 >/dev/null
n_edges="$(jq_get "$DIST/manifest.json" "['patches'].__len__()")"
[[ "$n_edges" == "0" ]] && ok "build A: 0 patch edges" || bad "build A edges=$n_edges (want 0)"

echo "[2] build B (patch from A)"
make_pack "$TMP/B.pck"
"$BP" --new-pck "$TMP/B.pck" --stamp "2026-07-21T020000Z" \
	--engine-linux "$TMP/eng_linux" --engine-windows "$TMP/eng_win" \
	--full-zip-linux "avalon-playtest-2026-07-21-linux.zip" \
	--dist "$DIST" --cache "$CACHE" --keep 5 >/dev/null
edge_file="$(jq_get "$DIST/manifest.json" "['patches'][0]['file']")"
[[ "$edge_file" == "pck_2026-07-20T010000Z_to_2026-07-21T020000Z.zst" ]] \
	&& ok "build B: edge A->B named correctly" || bad "build B edge name=$edge_file"

# round-trip: apply the patch to A, assert == B and == manifest sha
zstd -q -d --long=$LONG --patch-from="$CACHE/2026-07-20T010000Z.pck" \
	"$DIST/patches/$edge_file" -o "$TMP/applied_B.pck"
man_pck_sha="$(jq_get "$DIST/manifest.json" "['pck']['sha256']")"
[[ "$(sha "$TMP/applied_B.pck")" == "$(sha "$TMP/B.pck")" ]] \
	&& ok "round-trip: applied(A+patch) == fresh B" || bad "round-trip sha mismatch"
[[ "$(sha "$TMP/applied_B.pck")" == "$man_pck_sha" ]] \
	&& ok "round-trip: applied sha == manifest pck sha (launcher's fail-closed check)" \
	|| bad "applied sha != manifest sha"

full_size="$(stat -c %s "$TMP/B.pck")"
patch_size="$(jq_get "$DIST/manifest.json" "['patches'][0]['size']")"
[[ "$patch_size" -lt "$full_size" ]] \
	&& ok "bandwidth: patch $patch_size B < full $full_size B" || bad "patch not smaller"

man_latest="$(jq_get "$DIST/manifest.json" "['latest']")"
[[ "$man_latest" == "2026-07-21T020000Z" ]] && ok "manifest latest == B stamp" || bad "latest=$man_latest"
man_eng="$(jq_get "$DIST/manifest.json" "['engine']['linux']['sha256']")"
[[ "$man_eng" == "$(sha "$TMP/eng_linux")" ]] && ok "manifest engine.linux sha matches" || bad "engine sha off"

echo "[3] build C (two priors A,B -> two edges, both TO C)"
make_pack "$TMP/C.pck"
"$BP" --new-pck "$TMP/C.pck" --stamp "2026-07-22T030000Z" \
	--engine-linux "$TMP/eng_linux" --engine-windows "$TMP/eng_win" \
	--dist "$DIST" --cache "$CACHE" --keep 5 >/dev/null
n_edges="$(jq_get "$DIST/manifest.json" "['patches'].__len__()")"
[[ "$n_edges" == "2" ]] && ok "build C: 2 edges (A->C, B->C)" || bad "build C edges=$n_edges (want 2)"
all_to_latest="$(python3 -c "import json;m=json.load(open('$DIST/manifest.json'));print(all(e['to']==m['latest'] for e in m['patches']))")"
[[ "$all_to_latest" == "True" ]] && ok "every edge targets latest" || bad "an edge did not target latest"

echo "[4] prune: --keep 1 drops the oldest cached pack + its edge"
make_pack "$TMP/D.pck"
"$BP" --new-pck "$TMP/D.pck" --stamp "2026-07-23T040000Z" \
	--engine-linux "$TMP/eng_linux" --engine-windows "$TMP/eng_win" \
	--dist "$DIST" --cache "$CACHE" --keep 1 >/dev/null
# keep=1 prior: only the newest prior (C) may remain; A and B pruned.
remaining="$(ls "$CACHE"/*.pck | wc -l | tr -d ' ')"
[[ "$remaining" == "2" ]] && ok "prune: cache holds new + 1 prior ($remaining packs)" || bad "cache has $remaining packs (want 2)"
n_edges="$(jq_get "$DIST/manifest.json" "['patches'].__len__()")"
[[ "$n_edges" == "1" ]] && ok "prune: manifest has 1 edge (C->D)" || bad "post-prune edges=$n_edges (want 1)"

echo "[5] corruption guard: tampered patch -> applied sha != manifest -> rejected"
cp "$DIST/patches/$(jq_get "$DIST/manifest.json" "['patches'][0]['file']")" "$TMP/tamper.zst"
printf 'X' | dd of="$TMP/tamper.zst" bs=1 seek=20 count=1 conv=notrunc status=none
detected=0
if zstd -q -d --long=$LONG --patch-from="$CACHE/2026-07-22T030000Z.pck" "$TMP/tamper.zst" -o "$TMP/bad.pck" 2>/dev/null; then
	man_d_sha="$(jq_get "$DIST/manifest.json" "['pck']['sha256']")"
	[[ "$(sha "$TMP/bad.pck")" != "$man_d_sha" ]] && detected=1
else
	detected=1  # zstd itself rejected the corrupt frame
fi
[[ "$detected" == "1" ]] && ok "tampered patch caught (would fall back to full download)" || bad "tamper NOT caught"

echo
echo "----- build-patches.sh --selftest -----"
"$BP" --selftest && ok "build-patches.sh --selftest" || bad "selftest failed"

echo
echo "===================================================="
echo "T-690 patch round-trip: $pass passed, $fail failed"
echo "===================================================="
[[ $fail -eq 0 ]]
