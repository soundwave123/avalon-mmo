extends GutTest
# T-225: equipment visuals ride the positions broadcast — gear derivation from master
# inventory slots is pure, and players_array carries it per peer (omitted when empty).

const _BB = preload("res://scripts/broadcast_builder.gd")
const _CS = preload("res://scripts/combat/combat_state.gd")
const _CQ = preload("res://scripts/content/content_query.gd")
const _CONTENT = preload("res://scripts/content/content_registry.gd")


# T-420: an enriched armor slot carries armor_type, so the visual token becomes "<id>|<armor_type>"
# — the client routes armor to its GLB family by the SERVER-authored armor_type, never an id
# substring. Weapons / armor_type "none" keep a bare id, so nothing regresses.
func test_equipped_from_slots_folds_armor_type_into_the_visual_token() -> void:
	var slots := [
		{"slot_type": "chest", "item_id": "itm_ironward_cuirass", "armor_type": "plate"},
		{"slot_type": "legs", "item_id": "itm_bonepriest_wraps", "armor_type": "cloth"},
		{"slot_type": "weapon", "item_id": "itm_iron_sword", "armor_type": "none"},
		{"slot_type": "head", "item_id": "itm_leather_cap"},  # no armor_type field
	]
	var gear := _BB.equipped_from_slots(slots)
	assert_eq(gear.get("chest"), "itm_ironward_cuirass|plate", "plate armor carries its family")
	assert_eq(gear.get("legs"), "itm_bonepriest_wraps|cloth", "cloth armor carries its family")
	assert_eq(gear.get("weapon"), "itm_iron_sword", 'armor_type "none" stays a bare id')
	assert_eq(gear.get("head"), "itm_leather_cap", "a slot with no armor_type stays a bare id")


# T-420: the shoulders slot joins the worn set so the T-224 pauldrons ride the gear broadcast.
func test_equipped_from_slots_includes_shoulders() -> void:
	assert_true("shoulders" in _BB.GEAR_SLOTS, "shoulders is a worn visual slot")
	var slots := [
		{"slot_type": "shoulders", "item_id": "itm_ironward_pauldrons", "armor_type": "plate"},
	]
	assert_eq(_BB.equipped_from_slots(slots).get("shoulders"), "itm_ironward_pauldrons|plate")


# T-420: enrich_inventory stamps armor_type from the item registry so the equipped-visual derivation
# above has a SERVER-authored family to fold in (the client never asserts armor_type).
func test_enrich_inventory_stamps_armor_type_from_the_registry() -> void:
	var loaded := _CONTENT.load_all("res://data")
	assert_eq(loaded["errors"], [], "seed content loads clean")
	var raw := [{"slot_type": "chest", "item_id": "itm_ironward_cuirass", "item_count": 1}]
	var enriched := _CQ.enrich_inventory(raw, loaded["items"])
	assert_eq(str(enriched[0].get("armor_type")), "plate", "plate cuirass enriches with its family")


func test_equipped_from_slots_picks_visual_slots_only() -> void:
	var slots := [
		{"slot_type": "bag", "slot_index": 0, "item_id": "itm_wolf_pelt"},
		{"slot_type": "weapon", "slot_index": 0, "item_id": "itm_iron_sword"},
		{"slot_type": "head", "slot_index": 0, "item_id": "itm_leather_cap"},
		{"slot_type": "vault", "slot_index": 0, "item_id": "itm_copper_ore"},
	]
	var gear := _BB.equipped_from_slots(slots)
	assert_eq(gear.get("weapon"), "itm_iron_sword")
	assert_eq(gear.get("head"), "itm_leather_cap")
	assert_false(gear.has("bag"), "bag contents are not worn")
	assert_false(gear.has("vault"), "vaulted items are not worn")


func test_appearance_override_renders_over_the_real_item() -> void:
	# T-375: the cosmetic APPEARANCE channel wins over the STATS channel — a transmogged slot shows
	# its override id; an un-transmogged slot still shows the real item; stats read item_id elsewhere.
	var slots := [
		{
			"slot_type": "weapon",
			"slot_index": 0,
			"item_id": "itm_iron_sword",
			"appearance_override": "cos_gilded_blade"
		},
		{"slot_type": "chest", "slot_index": 0, "item_id": "itm_leather_vest"},
	]
	var gear := _BB.equipped_from_slots(slots)
	assert_eq(gear.get("weapon"), "cos_gilded_blade", "the transmog renders, not the real sword")
	assert_eq(gear.get("chest"), "itm_leather_vest", "an un-overridden slot renders its real item")


func test_empty_appearance_override_falls_back_to_the_real_item() -> void:
	# A blank override string is not a transmog — the body renders exactly as today (zero regression).
	var slots := [
		{
			"slot_type": "head",
			"slot_index": 0,
			"item_id": "itm_leather_cap",
			"appearance_override": ""
		},
	]
	assert_eq(_BB.equipped_from_slots(slots).get("head"), "itm_leather_cap")


# T-428: dye + override family ride the same public paper-doll token other clients consume, while
# hidden helm produces an explicit empty head visual so a prior attachment is removed.
func test_wardrobe_override_broadcasts_display_family_dye_and_mask() -> void:
	var slots := [
		{
			"slot_type": "chest",
			"item_id": "itm_leather_vest",
			"armor_type": "leather",
			"appearance_override": "itm_ironward_cuirass",
			"appearance_armor_type": "plate",
			"tint": "#9f3142",
			"dye_mask": "all",
		}
	]
	assert_eq(
		_BB.equipped_from_slots(slots)["chest"],
		"itm_ironward_cuirass|plate|#9f3142|all",
		"display item, its family, authored dye, and mask cross the broadcast"
	)


func test_hidden_helm_broadcasts_empty_visual() -> void:
	var slots := [{"slot_type": "head", "item_id": "itm_leather_cap", "appearance_hidden": true}]
	assert_true(_BB.equipped_from_slots(slots).has("head"), "empty is explicit, not omitted")
	assert_eq(_BB.equipped_from_slots(slots)["head"], "", "other clients remove the helm")


func test_players_array_carries_gear_per_peer() -> void:
	var positions := {7: {"username": "a", "x": 1.0, "y": 2.0, "z": 0.0}, 9: {"username": "b"}}
	var gear := {7: {"weapon": "itm_iron_sword"}}
	var out := _BB.players_array(positions, {}, {}, gear)
	for entry: Dictionary in out:
		if int(entry["peer_id"]) == 7:
			assert_eq(entry.get("gear", {}).get("weapon"), "itm_iron_sword")
		else:
			assert_false(entry.has("gear"), "no gear key when a player has none equipped")


func test_players_array_backward_compatible_without_gear_arg() -> void:
	var out := _BB.players_array({3: {"username": "c"}}, {}, {})
	assert_eq(out.size(), 1)
	assert_false((out[0] as Dictionary).has("gear"))


# T-401: the worn title rides the player entry as a plain string field (omitted when none) — so the
# T-372 delta detects a title change for free and the client renders it under the nameplate.
func test_players_array_carries_title_per_peer() -> void:
	var positions := {7: {"username": "a", "x": 1.0}, 9: {"username": "b"}}
	var titles := {7: "title:Wolf of the Vale"}
	var out := _BB.players_array(positions, {}, {}, {}, {}, {}, titles)
	for entry: Dictionary in out:
		if int(entry["peer_id"]) == 7:
			assert_eq(str(entry.get("title", "")), "title:Wolf of the Vale", "worn title rides")
		else:
			assert_false(entry.has("title"), "no title key when a player wears none")


func test_players_array_backward_compatible_without_title_arg() -> void:
	# The titles param defaults to {}, so every existing caller (and the whole positions pipeline)
	# is unaffected — no title key appears unless a title is supplied.
	var out := _BB.players_array({3: {"username": "c"}}, {}, {})
	assert_false((out[0] as Dictionary).has("title"))


func test_cast_payload_shapes() -> void:
	# T-264: seconds-based cast dict; {} when idle, expired, or degenerate.
	var cs := _CS.new()
	assert_true(_BB.cast_payload(cs, 100, 20).is_empty(), "idle -> empty")
	cs.state = _CS.CombatStateEnum.CASTING
	cs.cast_start = 100
	cs.cast_end = 140
	cs.cast_ability_id = 201
	var cp := _BB.cast_payload(cs, 120, 20)
	assert_eq(int(cp["ability_id"]), 201)
	assert_almost_eq(float(cp["remaining_s"]), 1.0, 0.001)
	assert_almost_eq(float(cp["total_s"]), 2.0, 0.001)
	assert_true(_BB.cast_payload(cs, 140, 20).is_empty(), "completed -> empty")


func test_players_array_carries_cast() -> void:
	var cs := _CS.new()
	cs.state = _CS.CombatStateEnum.CASTING
	cs.cast_start = 0
	cs.cast_end = 40
	cs.cast_ability_id = 204
	var casts := _BB.casts_map({5: cs, 6: _CS.new()}, 20, 20)
	assert_true(casts.has(5) and not casts.has(6), "only active casters in the map")
	var out := _BB.players_array({5: {"username": "a"}, 6: {"username": "b"}}, {}, {}, {}, casts)
	for entry: Dictionary in out:
		if int(entry["peer_id"]) == 5:
			assert_eq(int(entry["cast"]["ability_id"]), 204)
		else:
			assert_false(entry.has("cast"))


func test_players_array_carries_party_id() -> void:
	var out := _BB.players_array(
		{1: {"username": "a"}, 2: {"username": "b"}}, {}, {}, {}, {}, {1: 7, 2: 7}
	)
	for entry: Dictionary in out:
		assert_eq(int(entry["party_id"]), 7, "each partied player carries the party_id")
	# solo player: no party_id key
	var solo := _BB.players_array({3: {"username": "c"}}, {}, {}, {}, {}, {})
	assert_false((solo[0] as Dictionary).has("party_id"))
