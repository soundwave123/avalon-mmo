# T-361 item 3: the pure emote catalog — loads the data-driven emote list and resolves an id to the
# lines a player sees. No I/O beyond the one-shot JSON load, no state: the validation (is_emote) and
# the text resolution (resolve) are pure functions of (id, catalog), so the whole emote surface is
# unit-testable headlessly. ChatService loads the catalog once at setup (like the profanity list),
# then calls is_emote/resolve per intent.
#
# Catalog shape: id -> {self: String, other: String (%s = actor name), clip: String}. `clip` names a
# T-118 anim to play where one is baked; today every row is "" (the hero rigs carry only the 8
# combat/locomotion clips — emote clips are an assetgen re-bake, deferred to the visual lane), so
# every emote is text-only. The wire payload still carries `clip` so anim wiring is a later
# client-only add with no protocol change.

extends RefCounted

const _PATH := "res://data/social/emotes.json"


# Load id -> {self, other, clip} from the JSON file. Keys starting with "_" (e.g. "_comment") are
# skipped. Returns {} (no emotes → everything rejects) when the file is missing/malformed.
static func load_catalog(path: String = _PATH) -> Dictionary:
	var out: Dictionary = {}
	if not FileAccess.file_exists(path):
		return out
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		return out
	for id in parsed.keys():
		if str(id).begins_with("_"):
			continue
		var e = parsed[id]
		if not (e is Dictionary):
			continue
		out[str(id).to_lower()] = {
			"self": str(e.get("self", "")),
			"other": str(e.get("other", "%s")),
			"clip": str(e.get("clip", "")),
		}
	return out


# The server's validation gate: is this client-supplied id a known emote? Fail-closed — an unknown
# id (a forged/spoofed emote) is never an emote.
static func is_emote(id: String, catalog: Dictionary) -> bool:
	return catalog.has(id.to_lower())


# Resolve an emote to the actual lines: the actor's own ("self") and the third-person line others
# see ("other", with the server-resolved actor name injected). Returns {} for an unknown id. `actor`
# is the SESSION username (never the wire's) — the caller passes the trusted identity.
static func resolve(id: String, actor: String, catalog: Dictionary) -> Dictionary:
	var e: Dictionary = catalog.get(id.to_lower(), {})
	if e.is_empty():
		return {}
	return {
		"self": str(e.get("self", "")),
		"other": str(e.get("other", "%s")) % actor,
		"clip": str(e.get("clip", "")),
	}
