# T-451: pure social-discovery brain. The caller injects every authoritative map (level, class,
# guild, position); this module never reads a session, clock, node, or client packet on its own.
extends RefCounted

const _BB = preload("res://scripts/broadcast_builder.gd")

const CLASS_ROLES := {"warrior": "tank", "priest": "heal", "mage": "dps"}
const NOTE_MAX := 120
const WHO_MAX := 50
# T-477: a clear, server-derived rung separates newcomers from veterans. The flag never changes a
# level; it only advertises consent. Crossing the bar removes an incompatible stale signal.
const MENTOR_MIN_LEVEL := 20
const MENTEE_MAX_LEVEL := MENTOR_MIN_LEVEL - 1


static func new_store() -> Dictionary:
	return {"entries": {}}


static func new_mentorship_store() -> Dictionary:
	return {"entries": {}}


static func role_for_class(char_class: String) -> String:
	return str(CLASS_ROLES.get(char_class, "dps"))


static func clean_note(note: String) -> String:
	var cleaned := note.replace("\n", " ").replace("\r", " ").strip_edges()
	while cleaned.contains("  "):
		cleaned = cleaned.replace("  ", " ")
	return cleaned.left(NOTE_MAX)


static func flag(store: Dictionary, peer: int, level: int, role: String, note: String) -> void:
	store["entries"][peer] = {
		"level": maxi(level, 1),
		"role": role,
		"note": clean_note(note),
	}


static func unflag(store: Dictionary, peer: int) -> void:
	store["entries"].erase(peer)


static func prune_guilded(store: Dictionary, guilds: Dictionary) -> Array:
	var dropped: Array = []
	for peer in store["entries"]:
		if int(guilds.get(peer, 0)) > 0:
			dropped.append(int(peer))
	for peer in dropped:
		store["entries"].erase(peer)
	dropped.sort()
	return dropped


static func board(store: Dictionary) -> Array:
	var peers: Array = store["entries"].keys()
	peers.sort()
	var out: Array = []
	for peer in peers:
		var entry: Dictionary = store["entries"][peer]
		(
			out
			. append(
				{
					"peer": int(peer),
					"level": int(entry["level"]),
					"role": str(entry["role"]),
					"note": str(entry["note"]),
				}
			)
		)
	return out


# `kind` is the player's opt-in desire; eligibility and every displayed gameplay field are injected
# by the world from its authoritative maps. Invalid/out-of-band desires fail closed and store
# nothing.
static func flag_mentorship(
	store: Dictionary, peer: int, kind: String, level: int, role: String, zone: String, note: String
) -> Dictionary:
	if not mentorship_eligible(kind, level):
		return {"ok": false, "reason": "not_eligible"}
	store["entries"][peer] = {
		"kind": kind,
		"level": level,
		"role": role,
		"zone": zone,
		"note": clean_note(note),
	}
	return {"ok": true, "reason": ""}


static func mentorship_eligible(kind: String, level: int) -> bool:
	if kind == "mentor":
		return level >= MENTOR_MIN_LEVEL
	if kind == "mentee":
		return level >= 1 and level <= MENTEE_MAX_LEVEL
	return false


# Same lifecycle technique as T-334: party truth is held by reference and pruned at every board
# seam, avoiding hooks in capped main/world_rpc. Live level truth also drops signals that aged out.
static func prune_mentorship(store: Dictionary, levels: Dictionary, party_of: Dictionary) -> Array:
	var dropped: Array = []
	for peer in store["entries"]:
		var entry: Dictionary = store["entries"][peer]
		var level := int(levels.get(peer, 0))
		if party_of.has(peer) or not mentorship_eligible(str(entry.get("kind", "")), level):
			dropped.append(int(peer))
		else:
			entry["level"] = level
	for peer in dropped:
		store["entries"].erase(peer)
	dropped.sort()
	return dropped


static func mentorship_board(store: Dictionary, kind: String = "") -> Array:
	var peers: Array = store["entries"].keys()
	peers.sort()
	var out: Array = []
	for peer in peers:
		var entry: Dictionary = store["entries"][peer]
		if kind != "" and str(entry.get("kind", "")) != kind:
			continue
		(
			out
			. append(
				{
					"peer": int(peer),
					"kind": str(entry.get("kind", "")),
					"level": int(entry.get("level", 1)),
					"role": str(entry.get("role", "")),
					"zone": str(entry.get("zone", "")),
					"note": str(entry.get("note", "")),
				}
			)
		)
	return out


static func can_browse_seekers(rank: int) -> bool:
	return rank == 0 or rank == 1


static func zone_for(position: Dictionary) -> String:
	if int(position.get("instance_id", 0)) != 0:
		return "Hollowed Crypt"
	match _BB.region_of(float(position.get("x", 0.0)), float(position.get("z", 0.0))):
		1:
			return "Crypt Wilds"
		2:
			return "Ashmoor"
		_:
			return "Starter Vale"


# Server-truth online rows with optional read-only filters. A client's `level`/`role` claims are
# never parameters here; only the injected maps can populate those fields.
static func who(
	positions: Dictionary,
	levels: Dictionary,
	classes: Dictionary,
	guilds: Dictionary,
	guild_names: Dictionary,
	filters: Dictionary,
	mentorship_store: Dictionary = {}
) -> Array:
	var out: Array = []
	var peers: Array = positions.keys()
	peers.sort()
	for peer in peers:
		var position: Dictionary = positions[peer]
		var row := {
			"name": str(position.get("username", "")),
			"level": int(levels.get(peer, 1)),
			"role": role_for_class(str(classes.get(peer, ""))),
			"zone": zone_for(position),
			"guild": str(guild_names.get(peer, "")) if int(guilds.get(peer, 0)) > 0 else "",
			"mentor":
			(
				mentorship_store.get("entries", {}).has(peer)
				and str(mentorship_store["entries"][peer].get("kind", "")) == "mentor"
			),
		}
		if not _matches(row, filters):
			continue
		out.append(row)
		if out.size() >= WHO_MAX:
			break
	out.sort_custom(func(a, b): return str(a["name"]).to_lower() < str(b["name"]).to_lower())
	return out


static func _matches(row: Dictionary, filters: Dictionary) -> bool:
	for key in ["name", "zone", "guild"]:
		var needle := str(filters.get(key, "")).strip_edges().to_lower()
		if needle != "" and not str(row[key]).to_lower().contains(needle):
			return false
	var role := str(filters.get("role", "")).strip_edges().to_lower()
	if role != "" and str(row["role"]) != role:
		return false
	if filters.has("mentor") and bool(row.get("mentor", false)) != bool(filters["mentor"]):
		return false
	var min_level := clampi(int(filters.get("min_level", 1)), 1, 999)
	var max_level := clampi(int(filters.get("max_level", 999)), min_level, 999)
	return int(row["level"]) >= min_level and int(row["level"]) <= max_level
