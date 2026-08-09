extends GutTest

const WardrobeService = preload("res://scripts/wardrobe_service.gd")


class FakeMaster:
	var calls: Array = []
	var response: Dictionary = {"ok": true, "slots": [], "unlocks": [], "looks": {}}

	func call_master(method: String, params: Dictionary) -> Dictionary:
		calls.append({"method": method, "params": params.duplicate(true)})
		return response.duplicate(true)


var _master: FakeMaster
var _replies: Array
var _gear: Array
var _svc


func before_each() -> void:
	_master = FakeMaster.new()
	_replies = []
	_gear = []
	_svc = WardrobeService.new()
	var items := {
		"itm_iron_sword":
		{"name": "Iron Sword", "slot": "weapon", "armor_type": "none", "rarity": "uncommon"},
		# Backing items for the T-476 store rows in wardrobe.json.
		"itm_smith_broadsword": {"name": "Broadsword", "slot": "weapon", "armor_type": "none"},
		"itm_arcanist_cowl": {"name": "Cowl", "slot": "head", "armor_type": "robe"},
		"itm_ironward_cuirass": {"name": "Cuirass", "slot": "chest", "armor_type": "plate"},
		# T-679: shoulders backing for the guild-earned crest mantle.
		"itm_ironward_pauldrons": {"name": "Pauldrons", "slot": "shoulders", "armor_type": "plate"},
	}
	assert_eq(
		_svc.setup(
			_master,
			func(pid, msg): _replies.append([pid, msg]),
			items,
			"res://data/wardrobe.json",
			func(pid, gear): _gear.append([pid, gear])
		),
		""
	)


func test_apply_uses_session_identity_and_ignores_forged_definition_and_stats() -> void:
	await (
		_svc
		. handle(
			7,
			{"username": "alice"},
			{
				"type": "wardrobe_apply",
				"slot": "weapon",
				"appearance_id": "cos_gilded_blade",
				"dye_id": "dye_crimson",
				"display_item": "itm_cheat_blade",
				"stats": {"attack": 999999},
				"username": "mallory",
			}
		)
	)
	assert_eq(_master.calls[0]["method"], "wardrobe_op")
	var sent: Dictionary = _master.calls[0]["params"]
	assert_eq(sent["username"], "alice", "identity comes from the validated session")
	assert_eq(sent["appearance"]["display_item"], "itm_iron_sword", "server catalog wins")
	assert_false(sent.has("stats"), "forged power never crosses world->master")
	assert_false(sent["appearance"].has("stats"), "catalog appearance is presentation-only")


func test_unknown_appearance_and_dye_fail_before_master() -> void:
	await _svc.handle(
		7, {"username": "alice"}, {"type": "wardrobe_apply", "slot": "weapon", "appearance_id": "x"}
	)
	assert_eq(_master.calls.size(), 0)
	assert_eq(_replies[-1][1]["reason"], "unknown_appearance")
	await (
		_svc
		. handle(
			7,
			{"username": "alice"},
			{
				"type": "wardrobe_apply",
				"slot": "weapon",
				"appearance_id": "cos_gilded_blade",
				"dye_id": "dye_fake",
			}
		)
	)
	assert_eq(_master.calls.size(), 0)
	assert_eq(_replies[-1][1]["reason"], "unknown_dye")


func test_list_filters_catalog_by_authoritative_unlocks_and_returns_dyes() -> void:
	_master.response = {
		"ok": true,
		"slots": [],
		"unlocks": ["cos_gilded_blade", "not_in_catalog"],
		"looks": {},
	}
	await _svc.handle(7, {"username": "alice"}, {"type": "wardrobe_list"})
	var msg: Dictionary = _replies[-1][1]
	assert_eq(msg["type"], "wardrobe_state")
	assert_eq((msg["appearances"] as Array).size(), 1, "only owned, catalogued looks are exposed")
	assert_gt((msg["dyes"] as Array).size(), 0, "authored dyes are data-fed")


func test_successful_apply_refreshes_public_gear_cache() -> void:
	_master.response = {
		"ok": true,
		"slots":
		[
			{
				"slot_type": "weapon",
				"item_id": "itm_iron_sword",
				"appearance_override": "itm_iron_sword",
				"appearance_armor_type": "none",
				"tint": "#9f3142",
				"dye_mask": "all",
			}
		],
		"unlocks": ["cos_gilded_blade"],
		"looks": {},
	}
	await (
		_svc
		. handle(
			7,
			{"username": "alice"},
			{
				"type": "wardrobe_apply",
				"slot": "weapon",
				"appearance_id": "cos_gilded_blade",
				"dye_id": "dye_crimson",
			}
		)
	)
	assert_eq(_gear.size(), 1, "confirmed master state updates the broadcast cache")
	assert_eq(
		_gear[0][1]["weapon"],
		"itm_iron_sword|none|#9f3142|all",
		"world->broadcast round-trip emits the client renderer's exact wardrobe token"
	)
	assert_eq(_replies[-1][1]["type"], "wardrobe_state")


func test_buy_resolves_server_priced_store_row_before_master() -> void:
	# T-476: the client names only an appearance_id; the world attaches the server-authored priced
	# catalog row (never a client price) and asks the master to spend against it.
	_master.response = {"ok": true, "slots": [], "unlocks": ["cos_gilded_blade"], "looks": {}}
	await _svc.handle(
		7, {"username": "alice"}, {"type": "wardrobe_buy", "appearance_id": "cos_gilded_blade"}
	)
	assert_eq(_master.calls[0]["method"], "wardrobe_op")
	var sent: Dictionary = _master.calls[0]["params"]
	assert_eq(sent["action"], "purchase")
	assert_eq(int(sent["appearance"]["price"]), 120, "server price, never the client's")
	assert_false(sent["appearance"].has("stats"), "the purchased row is presentation-only")
	assert_eq(_replies[-1][1]["type"], "wardrobe_state")


func test_buy_refuses_an_earned_or_unknown_look_before_master() -> void:
	await _svc.handle(
		7, {"username": "alice"}, {"type": "wardrobe_buy", "appearance_id": "mentor_sigil_blade"}
	)
	assert_eq(_master.calls.size(), 0, "an earned look never reaches the spend path")
	assert_eq(_replies[-1][1]["reason"], "not_for_sale")
