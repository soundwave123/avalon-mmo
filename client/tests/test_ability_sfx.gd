extends GutTest

# T-343 phase 3: the per-ability SOUND map for the restyled kit (era-direction §11.5 "sound
# weight"). These prove every shipped ability id resolves to a REGISTERED, school-matched cue at
# a volume balanced against the frost reference kit, that the phase-2 frost beats are preserved
# byte-for-byte, and that every mapped WAV imports as a one-shot with its loop OFF (the T-415
# loop-import discipline, inverted: a looped one-shot would ring forever off a single cast).

const AbilitySfxLib = preload("res://scripts/audio/ability_sfx.gd")
const AudioManagerLib = preload("res://scripts/audio/audio_manager.gd")

# Every shipped ability id (mirrors server/world/data/abilities/*.json).
const ALL_IDS: Array = [
	1,
	2,
	101,
	102,
	103,
	104,
	105,
	106,
	107,
	201,
	202,
	203,
	204,
	205,
	206,
	301,
	302,
	303,
	304,
	305,
	306,
	307
]
# Ids whose ability_result carries damage > 0 (they land the impact beat).
const DAMAGE_IDS: Array = [1, 2, 101, 104, 105, 106, 201, 202, 204, 205, 206, 303, 304]
const HEAL_IDS: Array = [301, 302, 305, 306]
const FIRE_IDS: Array = [2, 201, 202, 205]
const WARRIOR_IDS: Array = [1, 101, 102, 103, 104, 105, 106, 107]


func test_every_shipped_ability_resolves_a_registered_cast_cue() -> void:
	for id: int in ALL_IDS:
		var cue: Array = AbilitySfxLib.cast_for(id)
		assert_true(
			AudioManagerLib.SFX.has(str(cue[0])),
			"ability %d cast cue '%s' is registered in AudioManager.SFX" % [id, str(cue[0])]
		)
		assert_between(
			float(cue[1]), -13.0, -4.0, "ability %d cast volume in the balance band" % id
		)
		assert_between(float(cue[2]), 0.6, 1.4, "ability %d cast pitch is a sane variant" % id)


func test_every_damage_ability_resolves_a_registered_impact_cue() -> void:
	for id: int in DAMAGE_IDS:
		var cue: Array = AbilitySfxLib.impact_for(id)
		assert_true(
			AudioManagerLib.SFX.has(str(cue[0])),
			"ability %d impact cue '%s' is registered in AudioManager.SFX" % [id, str(cue[0])]
		)
		assert_between(float(cue[1]), -13.0, -4.0, "ability %d impact volume in band" % id)


func test_frost_reference_beats_are_unchanged() -> void:
	# The phase-2 frost pass is the reference pattern — this map must reproduce it exactly.
	assert_eq(AbilitySfxLib.cast_for(204), ["frost_cast", -6.0, 1.0], "frostbolt cast beat")
	assert_eq(AbilitySfxLib.impact_for(204), ["frost_impact", -5.0, 1.0], "frostbolt money hit")


func test_schools_are_voiced_not_generic() -> void:
	for id: int in FIRE_IDS:
		assert_eq(str(AbilitySfxLib.cast_for(id)[0]), "fire_cast", "fire school cast %d" % id)
		assert_eq(str(AbilitySfxLib.impact_for(id)[0]), "fire_impact", "fire school hit %d" % id)
	for id: int in WARRIOR_IDS:
		assert_eq(str(AbilitySfxLib.cast_for(id)[0]), "melee_swing", "warrior swing whoosh %d" % id)
	for id: int in [303, 304]:
		assert_eq(str(AbilitySfxLib.cast_for(id)[0]), "holy_cast", "holy cast %d" % id)
		assert_eq(str(AbilitySfxLib.impact_for(id)[0]), "holy_impact", "holy hit %d" % id)
	for id: int in HEAL_IDS:
		assert_eq(str(AbilitySfxLib.heal_for(id)[0]), "heal_chime", "heal landing chime %d" % id)
	assert_eq(str(AbilitySfxLib.cast_for(307)[0]), "shadow_cast", "psychic horror's shadow sting")
	assert_eq(
		str(AbilitySfxLib.cast_for(203)[0]), "frost_cast", "frost nova reuses the frost charge"
	)
	assert_eq(str(AbilitySfxLib.cast_for(206)[0]), "spell_cast", "counterspell reuses the shimmer")
	assert_gt(float(AbilitySfxLib.cast_for(206)[2]), 1.0, "counterspell is pitched into a zap")


func test_non_frost_abilities_never_borrow_the_frost_money_cues() -> void:
	# The phase-2 gap being closed: everything non-frost leaned on generic spell_cast/hit. The
	# inverse regression: nothing outside the frost school may borrow the frost flight/impact.
	for id: int in ALL_IDS:
		if id == 203 or id == 204:
			continue  # the frost school itself
		for cue_name: String in [
			str(AbilitySfxLib.cast_for(id)[0]), str(AbilitySfxLib.impact_for(id)[0])
		]:
			assert_false(
				cue_name in ["frost_cast", "frost_flight", "frost_impact"],
				"non-frost ability %d must not borrow frost cue '%s'" % [id, cue_name]
			)


func test_unknown_ability_falls_back_to_the_generic_beats() -> void:
	assert_eq(AbilitySfxLib.cast_for(-1), AbilitySfxLib.CAST_DEFAULT, "unknown cast -> generic")
	assert_eq(AbilitySfxLib.impact_for(-1), AbilitySfxLib.IMPACT_DEFAULT, "unknown hit -> generic")
	assert_eq(AbilitySfxLib.heal_for(-1), AbilitySfxLib.HEAL_DEFAULT, "unknown heal -> chime")


func test_every_mapped_cue_imports_as_a_one_shot_with_loop_off() -> void:
	# T-415 discipline INVERTED: beds must loop, one-shots must NOT (a looped cast cue would ring
	# forever off one press). Asserted on the stream as actually imported, per the row-E lesson.
	var names := {}
	for m: Dictionary in [AbilitySfxLib.CAST, AbilitySfxLib.IMPACT, AbilitySfxLib.HEAL]:
		for cue: Array in m.values():
			names[str(cue[0])] = true
	for d: Array in [
		AbilitySfxLib.CAST_DEFAULT, AbilitySfxLib.IMPACT_DEFAULT, AbilitySfxLib.HEAL_DEFAULT
	]:
		names[str(d[0])] = true
	assert_gt(names.size(), 6, "the map spans a real cue palette, not one generic file")
	for cue_name: String in names.keys():
		var s := load(str(AudioManagerLib.SFX[cue_name])) as AudioStreamWAV
		assert_not_null(s, cue_name + " loads as an AudioStreamWAV one-shot")
		if s == null:
			continue
		assert_eq(s.loop_mode, AudioStreamWAV.LOOP_DISABLED, cue_name + " one-shot loop is OFF")
		assert_gt(s.get_length(), 0.05, cue_name + " is a real cue, not a truncated blip")


func test_play_helpers_null_guard_the_audio_manager() -> void:
	AbilitySfxLib.play_cast(null, 201)  # must be a no-op, not a crash (headless/harness callers)
	AbilitySfxLib.play_impact(null, 201)
	AbilitySfxLib.play_heal(null, 305)
	assert_true(true, "beat helpers are null-safe")
