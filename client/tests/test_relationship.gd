extends GutTest
# T-281: the relationship truth table (docs/design/m8-grouping-and-unit-frames.md). Every
# branch of Relationship.of() is a row here — this pure function drives all the M8 unit-frame
# and nameplate rendering, so its classification must be exhaustively pinned.

const Rel = preload("res://scripts/world/relationship.gd")


func test_mob_is_always_hostile() -> void:
	var viewer := {"peer_id": 1}
	assert_eq(Rel.of(viewer, {"mob_id": 7}), Rel.Rel.HOSTILE, "mob_id -> HOSTILE")
	assert_eq(Rel.of(viewer, {"is_mob": true}), Rel.Rel.HOSTILE, "is_mob -> HOSTILE")


func test_passive_mob_is_neutral() -> void:
	var viewer := {"peer_id": 1}
	assert_eq(
		Rel.of(viewer, {"mob_id": 7, "hostile": false}),
		Rel.Rel.NEUTRAL,
		"an authoritative passive-mob flag -> NEUTRAL"
	)


func test_self_by_peer_id() -> void:
	assert_eq(Rel.of({"peer_id": 42}, {"peer_id": 42}), Rel.Rel.SELF)


func test_same_party_is_party() -> void:
	var viewer := {"peer_id": 1, "party_id": 5}
	assert_eq(Rel.of(viewer, {"peer_id": 2, "party_id": 5}), Rel.Rel.PARTY)


func test_different_party_is_friendly() -> void:
	var viewer := {"peer_id": 1, "party_id": 5}
	assert_eq(Rel.of(viewer, {"peer_id": 2, "party_id": 9}), Rel.Rel.FRIENDLY)


func test_solo_players_are_friendly() -> void:
	# neither carries a party_id (server omits it for solo) -> not PARTY
	assert_eq(Rel.of({"peer_id": 1}, {"peer_id": 2}), Rel.Rel.FRIENDLY)


func test_party_id_zero_is_not_a_party() -> void:
	# defensive: an explicit 0 (no real party — ids start at 1) must never read as PARTY
	assert_eq(
		Rel.of({"peer_id": 1, "party_id": 0}, {"peer_id": 2, "party_id": 0}), Rel.Rel.FRIENDLY
	)


func test_both_pvp_flagged_is_hostile() -> void:
	var viewer := {"peer_id": 1, "pvp_flag": true}
	assert_eq(Rel.of(viewer, {"peer_id": 2, "pvp_flag": true}), Rel.Rel.HOSTILE)


func test_one_sided_pvp_is_friendly() -> void:
	# only HOSTILE when BOTH are flagged (T-282 semantics)
	var viewer := {"peer_id": 1, "pvp_flag": true}
	assert_eq(Rel.of(viewer, {"peer_id": 2}), Rel.Rel.FRIENDLY, "unit not flagged -> FRIENDLY")
	assert_eq(
		Rel.of({"peer_id": 1}, {"peer_id": 2, "pvp_flag": true}),
		Rel.Rel.FRIENDLY,
		"viewer not flagged -> FRIENDLY"
	)


func test_party_beats_pvp() -> void:
	# a party member who is also pvp-flagged is still PARTY (party check precedes pvp)
	var viewer := {"peer_id": 1, "party_id": 3, "pvp_flag": true}
	assert_eq(Rel.of(viewer, {"peer_id": 2, "party_id": 3, "pvp_flag": true}), Rel.Rel.PARTY)


func test_self_beats_party() -> void:
	var viewer := {"peer_id": 1, "party_id": 3}
	assert_eq(Rel.of(viewer, {"peer_id": 1, "party_id": 3}), Rel.Rel.SELF)


func test_plate_color_is_red_for_hostile_green_otherwise() -> void:
	# T-286/T-665: WoW color language — hostile red, neutral yellow, friendly green.
	assert_eq(Rel.plate_color(Rel.Rel.HOSTILE), Rel.HOSTILE_PLATE, "hostile -> red")
	assert_eq(Rel.plate_color(Rel.Rel.NEUTRAL), Rel.NEUTRAL_PLATE, "neutral -> yellow")
	assert_eq(Rel.plate_color(Rel.Rel.FRIENDLY), Rel.FRIENDLY_PLATE, "friendly -> green")
	assert_eq(Rel.plate_color(Rel.Rel.PARTY), Rel.FRIENDLY_PLATE, "party -> green")
	assert_eq(Rel.plate_color(Rel.Rel.SELF), Rel.FRIENDLY_PLATE, "self -> green")
	assert_true(Rel.HOSTILE_PLATE.r > Rel.HOSTILE_PLATE.g, "red channel dominates hostile")
	assert_true(
		Rel.NEUTRAL_PLATE.r > Rel.NEUTRAL_PLATE.b and Rel.NEUTRAL_PLATE.g > Rel.NEUTRAL_PLATE.b,
		"red + green dominate neutral yellow"
	)
	assert_true(Rel.FRIENDLY_PLATE.g > Rel.FRIENDLY_PLATE.r, "green channel dominates friendly")


func test_name_of_covers_every_value() -> void:
	assert_eq(Rel.name_of(Rel.Rel.SELF), "SELF")
	assert_eq(Rel.name_of(Rel.Rel.PARTY), "PARTY")
	assert_eq(Rel.name_of(Rel.Rel.FRIENDLY), "FRIENDLY")
	assert_eq(Rel.name_of(Rel.Rel.NEUTRAL), "NEUTRAL")
	assert_eq(Rel.name_of(Rel.Rel.HOSTILE), "HOSTILE")
