extends RefCounted


static func load_schedule(path: String = "res://data/loot/dungeon_schedule.json") -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		printerr("[dungeon_loot] cannot open %s" % path)
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if not (parsed is Dictionary) or not (parsed.get("bosses", null) is Dictionary):
		printerr('[dungeon_loot] malformed schedule (need {"bosses": {...}})')
		return {}
	return parsed["bosses"]


# Pure: injected RNG; greens always return and at most one named blue rolls.
static func roll_boss(boss_schedule: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	var guaranteed: Array = []
	for item_id in boss_schedule.get("guaranteed_green", []):
		if str(item_id) != "":
			guaranteed.append({"item": str(item_id), "count": 1})
	var blue_item := ""
	var pool: Array = boss_schedule.get("named_blue_pool", [])
	var chance := clampf(float(boss_schedule.get("blue_chance", 0.0)), 0.0, 1.0)
	if not pool.is_empty() and rng.randf() < chance:
		blue_item = str(pool[rng.randi_range(0, pool.size() - 1)])
	return {
		"guaranteed_items": guaranteed, "blue_item": blue_item, "cadence": _cadence(boss_schedule)
	}


# T-473: distribute a boss's schedule across the eligible recipients under the group's loot rule.
# Returns [{peer, rolled}] rows (rolled = the roll_boss shape, cadence included).
#
#  - Plain party / solo (`party` empty or no loot_rule): the T-333 behaviour byte-for-byte — every
#    recipient gets an INDEPENDENT honest roll (greens + their own gated-drop chance).
#  - Raid `loot_rule == "round_robin"` (the T-472 seam): greens still land on everyone, but the
#    gated drop rolls ONCE for the whole kill; on a hit it is awarded to the next member in the
#    raid's rotation (`loot_cursor` on the live party record — the record is by-ref, so the cursor
#    survives across kills) among recipients, in the server-authoritative `members` order. The
#    cursor advances only when an item actually drops. Master's per-character lockout still gates
#    the winner's grant, exactly as it gates independent rolls.
static func distribute(
	boss_schedule: Dictionary, recipients: Array, party: Dictionary, rng: RandomNumberGenerator
) -> Array:
	var shares: Array = []
	if str(party.get("loot_rule", "")) != "round_robin":
		for peer in recipients:
			shares.append({"peer": int(peer), "rolled": roll_boss(boss_schedule, rng)})
		return shares
	var group_roll := roll_boss(boss_schedule, rng)
	var awarded: String = str(group_roll.get("blue_item", ""))
	var winner := -1
	if awarded != "":
		var rotation: Array = []
		for m in party.get("members", []):
			if recipients.has(int(m)):
				rotation.append(int(m))
		if rotation.is_empty():
			awarded = ""
		else:
			var cursor := int(party.get("loot_cursor", 0))
			winner = int(rotation[cursor % rotation.size()])
			party["loot_cursor"] = cursor + 1
	for peer in recipients:
		var rolled := {
			"guaranteed_items": group_roll.get("guaranteed_items", []),
			"blue_item": awarded if int(peer) == winner else "",
			"cadence": _cadence(boss_schedule),
		}
		shares.append({"peer": int(peer), "rolled": rolled})
	return shares


static func _cadence(boss_schedule: Dictionary) -> String:
	return "weekly" if str(boss_schedule.get("cadence", "daily")) == "weekly" else "daily"


static func grant(
	master, username: String, boss_id: String, rolled: Dictionary, content: Dictionary
):
	return await (
		master
		. call_master(
			"grant_dungeon_loot",
			{
				"username": username,
				"boss_id": boss_id,
				"cadence": str(rolled.get("cadence", "daily")),  # T-473: weekly re-lock window
				"date_key": Time.get_date_string_from_system(true),
				"guaranteed_items": rolled.get("guaranteed_items", []),
				"blue_item": rolled.get("blue_item", ""),
				"item_registry": content.get("items", {}),
				"quest_defs": content.get("quests", {}),
			}
		)
	)
