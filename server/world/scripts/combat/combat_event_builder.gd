extends RefCounted
# T-429 carve: canonical server ability-result payload, kept pure so main.gd stays at its hard cap.


static func ability_result(
	ability_id: int,
	ability_name: String,
	caster_id: int,
	target_id: int,
	amount: int,
	outcome: String,
	tick: int,
	caster_name: String,
	target_name: String,
	target_hp: int,
	target_max_hp: int,
	mitigated: int,
	interrupt_landed: bool
) -> Dictionary:
	return {
		"type": "ability_result",
		"ability_id": ability_id,
		"ability_name": ability_name,
		"caster_id": caster_id,
		"target_id": target_id,
		"damage": amount,
		"outcome": outcome,
		"tick": tick,
		"caster_name": caster_name,
		"target_name": target_name,
		"target_hp": target_hp,
		"target_max_hp": target_max_hp,
		"mitigated": maxi(0, mitigated),
		"interrupt_landed": interrupt_landed,
	}
