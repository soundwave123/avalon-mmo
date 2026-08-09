# T-361 item 3: the pure emote catalog — load (skips "_"-prefixed doc keys), the is_emote validation
# gate (fail-closed on unknown ids), and resolve's self/other line + actor-name injection.

extends GutTest

const _EMOTES = preload("res://scripts/emote_catalog.gd")


func test_real_catalog_loads_known_emotes() -> void:
	var cat := _EMOTES.load_catalog()
	assert_true(cat.has("wave"), "the shipped catalog defines /wave")
	assert_true(cat.has("bow"), "the shipped catalog defines /bow")
	assert_false(cat.has("_comment"), "doc keys (underscore-prefixed) are not emotes")


func test_is_emote_is_fail_closed_and_case_insensitive() -> void:
	var cat := _EMOTES.load_catalog()
	assert_true(_EMOTES.is_emote("wave", cat), "a listed id is an emote")
	assert_true(_EMOTES.is_emote("WAVE", cat), "id matching is case-insensitive")
	assert_false(_EMOTES.is_emote("__hack__", cat), "an unknown id is never an emote")
	assert_false(_EMOTES.is_emote("wave", {}), "an empty catalog rejects everything")


func test_resolve_injects_actor_into_other_line() -> void:
	var cat := {"wave": {"self": "You wave.", "other": "%s waves.", "clip": ""}}
	var got := _EMOTES.resolve("wave", "Alice", cat)
	assert_eq(str(got["self"]), "You wave.", "the actor sees the first-person line")
	assert_eq(str(got["other"]), "Alice waves.", "others see the third-person line with the name")
	assert_eq(str(got["clip"]), "", "text-only emotes carry an empty clip")


func test_resolve_unknown_id_returns_empty() -> void:
	assert_true(_EMOTES.resolve("nope", "Alice", {}).is_empty(), "unknown id resolves to nothing")


# T-397 deliverable 3: dance/kneel/point were retargeted from the UAL/Quaternius CC0 library onto
# the hero rigs, so their catalog rows carry a non-empty `clip` (an EntityVisuals emote-state key);
# the other nine have no CC0 source clip and stay text-only ("").
func test_baked_emotes_carry_a_clip_state_the_rest_are_text_only() -> void:
	var cat := _EMOTES.load_catalog()
	for id in ["dance", "kneel", "point"]:
		assert_eq(str(cat[id]["clip"]), id, "%s carries its baked emote-state clip" % id)
	for id in ["wave", "bow", "cheer", "clap", "laugh", "salute", "cry", "thank", "flex"]:
		assert_eq(str(cat[id]["clip"]), "", "%s has no CC0 clip yet — text-only" % id)


func test_resolve_forwards_the_baked_clip() -> void:
	var cat := _EMOTES.load_catalog()
	var got := _EMOTES.resolve("dance", "Alice", cat)
	assert_eq(
		str(got["clip"]), "dance", "resolve forwards the baked emote's clip state to the wire"
	)
