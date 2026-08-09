#!/usr/bin/env bash
# T-690: delta-patch + manifest generation for the tester client auto-updater.
#
# Given a freshly-built .pck (the ~936 MB game data that changes every build) plus the per-platform
# engine binaries, this:
#   1. caches the new .pck under a stamp slug so future builds can diff against it,
#   2. emits a zstd binary-delta patch (pck_<oldstamp>_to_<newstamp>.zst) FROM each of the last N
#      cached prior packs TO the new pack (large-window --long=30 required for a ~936 MB pack),
#   3. writes dist/manifest.json (latest stamp; .pck sha256+size; per-platform engine sha256+size;
#      the list of available patch edges old->latest with patch filename+size+sha256),
#   4. prunes cached packs + patch edges beyond the last N builds so dist/ stays bounded.
#
# The launcher downloads exactly one edge (local->latest), applies it with the SAME --long=30, and
# verifies the applied pack's sha256 against the manifest (fail-closed).
#
# It is intentionally decoupled from build-playtest.sh (it operates on plain files) so the whole
# pipeline is testable with two tiny fake "packs" — see scripts/test-patch-roundtrip.sh.
set -euo pipefail

PATCH_LEVEL=19       # zstd compression level for the delta
LONG=30              # large-window log2 — MUST match on apply; a ~936 MB pack needs a >window
KEEP_DEFAULT=5       # how many prior builds' packs/edges to retain

log() { printf '[build-patches] %s\n' "$*"; }
die() { printf '[build-patches] FATAL: %s\n' "$*" >&2; exit 1; }

command -v zstd >/dev/null 2>&1 || die "zstd not found"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum not found"
command -v python3 >/dev/null 2>&1 || die "python3 not found"

# stamp -> filesystem/URL-safe slug (drop the colons an ISO-8601 instant carries).
slug() { printf '%s' "${1//:/}"; }
sha_of() { sha256sum "$1" | awk '{print $1}'; }
size_of() { stat -c %s "$1"; }

# ── selftest: prove the round trip + corruption guard with tiny fake packs, no Godot, no 936 MB ──
if [[ "${1:-}" == "--selftest" ]]; then
	tmp="$(mktemp -d /tmp/build-patches-selftest.XXXXXX)"
	trap 'rm -rf "$tmp"' EXIT
	# Two "packs" that mostly overlap (like two real builds): shared prefix + a small changed tail.
	head -c 400000 /dev/urandom > "$tmp/shared"
	cp "$tmp/shared" "$tmp/old.pck"; head -c 2000 /dev/urandom >> "$tmp/old.pck"
	cp "$tmp/shared" "$tmp/new.pck"; head -c 2000 /dev/urandom >> "$tmp/new.pck"
	zstd -q --patch-from="$tmp/old.pck" -$PATCH_LEVEL --long=$LONG "$tmp/new.pck" -o "$tmp/p.zst"
	zstd -q -d --long=$LONG --patch-from="$tmp/old.pck" "$tmp/p.zst" -o "$tmp/applied.pck"
	[[ "$(sha_of "$tmp/applied.pck")" == "$(sha_of "$tmp/new.pck")" ]] || die "selftest: applied != new"
	patch_size=$(size_of "$tmp/p.zst"); full_size=$(size_of "$tmp/new.pck")
	[[ "$patch_size" -lt "$full_size" ]] || die "selftest: patch not smaller than full"
	# corruption guard: flip a byte in the patch -> apply MUST fail (launcher then falls back to full).
	printf 'X' | dd of="$tmp/p.zst" bs=1 seek=10 count=1 conv=notrunc status=none
	if zstd -q -d --long=$LONG --patch-from="$tmp/old.pck" "$tmp/p.zst" -o "$tmp/bad.pck" 2>/dev/null; then
		# zstd may still emit; the launcher's real guard is the sha check — assert THAT catches it.
		[[ "$(sha_of "$tmp/bad.pck")" != "$(sha_of "$tmp/new.pck")" ]] || die "selftest: tamper not detected"
	fi
	log "SELFTEST PASS (patch $patch_size B vs full $full_size B; round-trip sha match; tamper caught)"
	exit 0
fi

NEW_PCK="" STAMP="" ENGINE_LINUX="" ENGINE_WINDOWS="" DIST_DIR="" CACHE_DIR="" KEEP="$KEEP_DEFAULT"
FULL_ZIP_LINUX="" FULL_ZIP_WINDOWS=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		--new-pck) NEW_PCK="$2"; shift 2 ;;
		--stamp) STAMP="$2"; shift 2 ;;
		--engine-linux) ENGINE_LINUX="$2"; shift 2 ;;
		--engine-windows) ENGINE_WINDOWS="$2"; shift 2 ;;
		--full-zip-linux) FULL_ZIP_LINUX="$2"; shift 2 ;;
		--full-zip-windows) FULL_ZIP_WINDOWS="$2"; shift 2 ;;
		--dist) DIST_DIR="$2"; shift 2 ;;
		--cache) CACHE_DIR="$2"; shift 2 ;;
		--keep) KEEP="$2"; shift 2 ;;
		*) die "unknown arg: $1" ;;
	esac
done

[[ -f "$NEW_PCK" ]] || die "--new-pck missing/not a file: $NEW_PCK"
[[ -n "$STAMP" ]] || die "--stamp required"
[[ -n "$DIST_DIR" ]] || die "--dist required"
[[ -n "$CACHE_DIR" ]] || die "--cache required"
[[ "$KEEP" =~ ^[0-9]+$ ]] && [[ "$KEEP" -ge 1 ]] || die "--keep must be a positive integer"

NEW_SLUG="$(slug "$STAMP")"
PATCH_DIR="$DIST_DIR/patches"
ENGINE_DIR="$DIST_DIR/engine"
mkdir -p "$PATCH_DIR" "$ENGINE_DIR" "$CACHE_DIR"

new_sha="$(sha_of "$NEW_PCK")"
new_size="$(size_of "$NEW_PCK")"
log "new pack $STAMP sha=$new_sha size=$new_size"

# Generate a patch FROM every still-cached prior pack TO the new pack.
# Edges accumulate as JSON-lines in a temp file consumed by the manifest writer.
edges="$(mktemp)"
trap 'rm -f "$edges"' EXIT
shopt -s nullglob
for old_pck in "$CACHE_DIR"/*.pck; do
	old_slug="$(basename "$old_pck" .pck)"
	[[ "$old_slug" == "$NEW_SLUG" ]] && continue   # don't diff a pack against itself
	old_meta="$CACHE_DIR/$old_slug.stamp"
	[[ -f "$old_meta" ]] || { log "skip $old_slug (no .stamp sidecar)"; continue; }
	from_stamp="$(<"$old_meta")"
	patch_name="pck_${old_slug}_to_${NEW_SLUG}.zst"
	patch_path="$PATCH_DIR/$patch_name"
	log "delta $from_stamp -> $STAMP ..."
	zstd -q -f --patch-from="$old_pck" -$PATCH_LEVEL --long=$LONG "$NEW_PCK" -o "$patch_path"
	p_size="$(size_of "$patch_path")"; p_sha="$(sha_of "$patch_path")"
	printf '%s\t%s\t%s\t%s\t%s\n' "$from_stamp" "$STAMP" "$patch_name" "$p_size" "$p_sha" >> "$edges"
	log "  -> $patch_name ($p_size B, $(awk "BEGIN{printf \"%.1f\", $p_size/$new_size*100}")% of full)"
done
shopt -u nullglob

# Cache the new pack (+ its full stamp sidecar) so the NEXT build can diff against it.
cp -f "$NEW_PCK" "$CACHE_DIR/$NEW_SLUG.pck"
printf '%s' "$STAMP" > "$CACHE_DIR/$NEW_SLUG.stamp"

# ── Prune: keep only the last KEEP cached prior packs (the new one always stays). Drop pruned
#    packs, their sidecars, and any patch edge whose source is no longer cached. ──
mapfile -t all_slugs < <(for f in "$CACHE_DIR"/*.pck; do basename "$f" .pck; done | LC_ALL=C sort)
# newest last (slugs are lexically monotonic ISO instants); prior = everything except NEW_SLUG.
priors=()
for s in "${all_slugs[@]}"; do [[ "$s" != "$NEW_SLUG" ]] && priors+=("$s"); done
prune_count=$(( ${#priors[@]} - KEEP ))
if [[ $prune_count -gt 0 ]]; then
	for ((i = 0; i < prune_count; i++)); do
		drop="${priors[$i]}"
		log "prune cached pack $drop (beyond keep=$KEEP)"
		rm -f "$CACHE_DIR/$drop.pck" "$CACHE_DIR/$drop.stamp"
		rm -f "$PATCH_DIR/pck_${drop}_to_"*.zst
	done
	# Drop pruned edges from the manifest set too.
	kept_edges="$(mktemp)"
	while IFS=$'\t' read -r from to name size sha; do
		fslug="$(slug "$from")"
		[[ -f "$CACHE_DIR/$fslug.pck" ]] && printf '%s\t%s\t%s\t%s\t%s\n' "$from" "$to" "$name" "$size" "$sha" >> "$kept_edges"
	done < "$edges"
	mv "$kept_edges" "$edges"
fi

# ── Write dist/manifest.json ──
# Publish the raw engine binaries under dist/engine/ so a rare engine bump re-downloads just the
# ~73 MB binary (served at /engine/<name>) rather than the whole zip; the launcher fetches it only
# when its hash differs from the local copy.
eng_linux_json="null"; eng_windows_json="null"
if [[ -n "$ENGINE_LINUX" ]]; then
	[[ -f "$ENGINE_LINUX" ]] || die "--engine-linux not a file: $ENGINE_LINUX"
	cp -f "$ENGINE_LINUX" "$ENGINE_DIR/$(basename "$ENGINE_LINUX")"
	eng_linux_json="$(printf '{"name":"%s","sha256":"%s","size":%s}' \
		"$(basename "$ENGINE_LINUX")" "$(sha_of "$ENGINE_LINUX")" "$(size_of "$ENGINE_LINUX")")"
fi
if [[ -n "$ENGINE_WINDOWS" ]]; then
	[[ -f "$ENGINE_WINDOWS" ]] || die "--engine-windows not a file: $ENGINE_WINDOWS"
	cp -f "$ENGINE_WINDOWS" "$ENGINE_DIR/$(basename "$ENGINE_WINDOWS")"
	eng_windows_json="$(printf '{"name":"%s","sha256":"%s","size":%s}' \
		"$(basename "$ENGINE_WINDOWS")" "$(sha_of "$ENGINE_WINDOWS")" "$(size_of "$ENGINE_WINDOWS")")"
fi

MANIFEST="$DIST_DIR/manifest.json" \
LATEST_STAMP="$STAMP" PCK_SHA="$new_sha" PCK_SIZE="$new_size" \
ENG_LINUX="$eng_linux_json" ENG_WINDOWS="$eng_windows_json" \
ZIP_LINUX="$FULL_ZIP_LINUX" ZIP_WINDOWS="$FULL_ZIP_WINDOWS" \
EDGES_FILE="$edges" \
python3 - <<'PY'
import json, os
edges = []
with open(os.environ["EDGES_FILE"]) as f:
    for line in f:
        line = line.rstrip("\n")
        if not line:
            continue
        frm, to, name, size, sha = line.split("\t")
        edges.append({"from": frm, "to": to, "file": name, "size": int(size), "sha256": sha})
manifest = {
    "schema": 1,
    "latest": os.environ["LATEST_STAMP"],
    "pck": {"name": "Avalon.pck", "sha256": os.environ["PCK_SHA"], "size": int(os.environ["PCK_SIZE"])},
    "engine": {
        "linux": json.loads(os.environ["ENG_LINUX"]),
        "windows": json.loads(os.environ["ENG_WINDOWS"]),
    },
    "full_zip": {
        "linux": os.environ.get("ZIP_LINUX") or None,
        "windows": os.environ.get("ZIP_WINDOWS") or None,
    },
    "patches": edges,
}
with open(os.environ["MANIFEST"], "w") as f:
    json.dump(manifest, f, indent=2, sort_keys=True)
    f.write("\n")
print("[build-patches] wrote %s (%d patch edge(s))" % (os.environ["MANIFEST"], len(edges)))
PY

log "PASS: manifest + $(find "$PATCH_DIR" -name '*.zst' | wc -l | tr -d ' ') patch file(s) in $DIST_DIR"
