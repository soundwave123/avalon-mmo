extends RefCounted
# T-429: pure, deterministic personal performance aggregation over authoritative combat events.
# No clock, network, DB, or global state: callers inject events, the character peer id, and ticks.


static func blank(start_tick: int) -> Dictionary:
	return {
		"start_tick": start_tick,
		"last_tick": start_tick,
		"event_count": 0,
		"damage_done": 0,
		"damage_taken": 0,
		"healing_done": 0,
		"healing_taken": 0,
		"mitigation": 0,
		"interrupts": 0,
		"deaths": 0,
		"abilities": {},
		"participant_ids": [],
	}


static func apply_event(
	current: Dictionary, event: Dictionary, character_peer_id: int
) -> Dictionary:
	var result: Dictionary = current.duplicate(true)
	var event_type := str(event.get("type", ""))
	var caster_id := int(event.get("caster_id", -1))
	var target_id := int(event.get("target_id", event.get("player_id", -1)))
	var involved := character_peer_id == caster_id or character_peer_id == target_id
	if not involved:
		return result
	var tick := int(event.get("tick", result.get("last_tick", result.get("start_tick", 0))))
	result["last_tick"] = maxi(int(result.get("last_tick", tick)), tick)
	result["event_count"] = int(result.get("event_count", 0)) + 1
	var other_id := target_id if character_peer_id == caster_id else caster_id
	if other_id > 0 and not other_id in result["participant_ids"]:
		result["participant_ids"].append(other_id)

	if event_type == "player_death":
		if character_peer_id == target_id:
			result["deaths"] = int(result["deaths"]) + 1
		return result
	var has_amount := event.has("damage") or event.has("amount") or event.has("heal")
	if event_type != "ability_result" and not has_amount:
		return result

	var amount := maxi(0, int(event.get("damage", event.get("amount", event.get("heal", 0)))))
	var is_heal := str(event.get("outcome", "")) == "heal"
	if character_peer_id == caster_id:
		if is_heal:
			result["healing_done"] = int(result["healing_done"]) + amount
		else:
			result["damage_done"] = int(result["damage_done"]) + amount
		if bool(event.get("interrupt_landed", false)):
			result["interrupts"] = int(result["interrupts"]) + 1
		if event_type == "ability_result":
			result["abilities"] = _credit_ability(result["abilities"], event, amount, is_heal)
	if character_peer_id == target_id:
		if is_heal:
			result["healing_taken"] = int(result["healing_taken"]) + amount
		else:
			result["damage_taken"] = int(result["damage_taken"]) + amount
			result["mitigation"] = (
				int(result["mitigation"]) + maxi(0, int(event.get("mitigated", 0)))
			)
	return result


static func _credit_ability(
	abilities: Dictionary, event: Dictionary, amount: int, is_heal: bool
) -> Dictionary:
	var result: Dictionary = abilities.duplicate(true)
	var ability_id := int(event.get("ability_id", 0))
	var key := str(ability_id)
	var row: Dictionary = (
		result
		. get(
			key,
			{
				"id": ability_id,
				"name": str(event.get("ability_name", "Ability %d" % ability_id)),
				"uses": 0,
				"damage": 0,
				"healing": 0,
				"interrupts": 0,
			}
		)
	)
	row["uses"] = int(row["uses"]) + 1
	if is_heal:
		row["healing"] = int(row["healing"]) + amount
	else:
		row["damage"] = int(row["damage"]) + amount
	if bool(event.get("interrupt_landed", false)):
		row["interrupts"] = int(row["interrupts"]) + 1
	result[key] = row
	return result


static func finalize(
	current: Dictionary,
	encounter_key: String,
	encounter_label: String,
	end_tick: int,
	tick_rate: int,
	prior_runs: Array
) -> Dictionary:
	var rate := maxi(1, tick_rate)
	var elapsed_ticks := maxi(1, end_tick - int(current.get("start_tick", end_tick)))
	var duration_s := float(elapsed_ticks) / float(rate)
	var abilities: Array = (current.get("abilities", {}) as Dictionary).values()
	abilities.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			var a_total := int(a.get("damage", 0)) + int(a.get("healing", 0))
			var b_total := int(b.get("damage", 0)) + int(b.get("healing", 0))
			return a_total > b_total
	)
	var result := {
		"encounter_key": encounter_key,
		"encounter_label": encounter_label,
		"damage_done": int(current.get("damage_done", 0)),
		"damage_taken": int(current.get("damage_taken", 0)),
		"healing_done": int(current.get("healing_done", 0)),
		"healing_taken": int(current.get("healing_taken", 0)),
		"mitigation": int(current.get("mitigation", 0)),
		"interrupts": int(current.get("interrupts", 0)),
		"deaths": int(current.get("deaths", 0)),
		"duration_s": snappedf(duration_s, 0.01),
		"dps": snappedf(float(current.get("damage_done", 0)) / duration_s, 0.1),
		"hps": snappedf(float(current.get("healing_done", 0)) / duration_s, 0.1),
		"abilities": abilities,
		"participant_ids": (current.get("participant_ids", []) as Array).duplicate(),
		"comparison": _comparison(current, prior_runs),
	}
	return result


static func _comparison(current: Dictionary, prior_runs: Array) -> Dictionary:
	var result := {"runs": prior_runs.size()}
	if prior_runs.is_empty():
		return result
	var damage_total := 0.0
	var healing_total := 0.0
	for prior: Dictionary in prior_runs:
		damage_total += float(prior.get("damage_done", 0))
		healing_total += float(prior.get("healing_done", 0))
	var damage_avg := damage_total / float(prior_runs.size())
	var healing_avg := healing_total / float(prior_runs.size())
	if damage_avg > 0.0:
		result["damage_pct"] = snappedf(
			(float(current.get("damage_done", 0)) - damage_avg) * 100.0 / damage_avg, 0.1
		)
	if healing_avg > 0.0:
		result["healing_pct"] = snappedf(
			(float(current.get("healing_done", 0)) - healing_avg) * 100.0 / healing_avg, 0.1
		)
	return result


static func append_history(history: Array, recap: Dictionary, limit: int) -> Array:
	var result: Array = history.duplicate(true)
	result.append(recap.duplicate(true))
	while result.size() > maxi(1, limit):
		result.pop_front()
	return result
