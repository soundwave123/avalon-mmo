class_name VaultOps
extends RefCounted

# T-412: the master-owned bank/vault op — extracted from master/main.gd (file-size budget; the
# dispatch arm now routes to VaultOps.op) so the tier-ladder coin SINK lands without growing main.gd
# past the 1000-line cap. Mirrors DurabilityOps/TradeOps: pure of Node state, all persistence rides
# ServicesStore/CharacterManager, all tunables ride ServerConfig, so a test drives op() directly.
#
# Actions:
#   list     read-only panel feed (vault rows + bag rows + current capacity/tier + coins)
#   move     deposit/withdraw one stack between bag and vault (capacity = the character's tier cap)
#   upgrade  BUY the next vault tier — a non-punitive coin sink. SERVER-AUTHORITATIVE: the target
#            tier AND its cost are derived from the persisted tier + ServerConfig.VAULT_TIER_COSTS;
#            a client-supplied cost/tier in params is never read (adversarial-tested). Debits via
#            adjust_coins reason "vault_upgrade" (overdraft-guarded; ledgers only on success).

const CharacterManager := preload("res://scripts/character_manager.gd")
const ServerConfig := preload("res://scripts/server_config.gd")


static func op(params: Dictionary) -> Dictionary:
	var cid := _char_id(params)
	if cid < 0:
		return {"error": "unknown_character"}
	var tier := ServicesStore.get_vault_tier(cid)
	var cap := VaultLogic.capacity_for_tier(
		tier, ServerConfig.VAULT_TIER_BASE_SLOTS, ServerConfig.VAULT_TIER_SLOTS_PER
	)
	var action := str(params.get("action", "list"))
	if action == "move":
		var plan := VaultLogic.plan_move(
			CharacterManager.get_inventory(cid),
			str(params.get("from_type", "")),
			int(params.get("from_index", -1)),
			cap
		)
		if not bool(plan.get("ok", false)):
			return {"error": str(plan.get("reason", "bad_move"))}
		if not CharacterManager.apply_vault_move(cid, plan["plan"]):
			return {"error": "persist_failed"}
	elif action == "upgrade":
		var up := _upgrade(cid, tier)
		if up.has("error"):
			return up
		tier = int(up["tier"])
		cap = int(up["cap"])
	return _panel(cid, cap, tier)


# Buy the next tier: cost + target derived server-side; debit ledgers reason "vault_upgrade".
static func _upgrade(cid: int, tier: int) -> Dictionary:
	var plan := VaultLogic.plan_upgrade(
		tier, ServicesStore.get_coins(cid), ServerConfig.VAULT_TIER_COSTS
	)
	if not bool(plan.get("ok", false)):
		return {"error": str(plan.get("reason", "cannot_upgrade"))}
	if not ServicesStore.adjust_coins(cid, -int(plan["cost"]), "vault_upgrade"):
		return {"error": "insufficient_coins"}
	var new_tier := int(plan["new_tier"])
	ServicesStore.set_vault_tier(cid, new_tier)
	var cap := VaultLogic.capacity_for_tier(
		new_tier, ServerConfig.VAULT_TIER_BASE_SLOTS, ServerConfig.VAULT_TIER_SLOTS_PER
	)
	return {"tier": new_tier, "cap": cap}


static func _panel(cid: int, cap: int, tier: int) -> Dictionary:
	var inventory := CharacterManager.get_inventory(cid)
	var bag: Array = []
	for entry in inventory:
		if str(entry["slot_type"]) == "bag":
			(
				bag
				. append(
					{
						"slot_index": int(entry["slot_index"]),
						"item_id": str(entry["item_id"]),
						"item_count": int(entry["item_count"]),
					}
				)
			)
	# T-611: surface the next tier's cost + resulting capacity so the client can render the
	# upgrade button without mirroring the cost table; cost 0 = already at max tier (no button).
	var next_cost := 0
	var next_slots := cap
	if tier < ServerConfig.VAULT_TIER_COSTS.size():
		next_cost = int(ServerConfig.VAULT_TIER_COSTS[tier])
		next_slots = VaultLogic.capacity_for_tier(
			tier + 1, ServerConfig.VAULT_TIER_BASE_SLOTS, ServerConfig.VAULT_TIER_SLOTS_PER
		)
	return {
		"vault": VaultLogic.vault_view(inventory),
		"bag": bag,
		"vault_slots": cap,
		"vault_tier": tier,
		"vault_next_cost": next_cost,
		"vault_next_slots": next_slots,
		"coins": ServicesStore.get_coins(cid),
	}


static func _char_id(params: Dictionary) -> int:
	var username := str(params.get("username", ""))
	CharacterManager.ensure_character(username)
	var character := CharacterManager.get_character(username)
	return int(character["id"]) if not character.is_empty() else -1
