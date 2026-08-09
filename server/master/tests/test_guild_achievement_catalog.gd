extends GutTest

# T-679: the GUILD-collective achievement catalog + the T-482 charter it must obey. Guards the
# ticket's identity-only-by-construction rule: a guild achievement may only reference a GUILD-scoped
# event the engine advances AND the server actually emits; its ONLY reward is a cosmetic (or
# nothing); and that cosmetic is earn-only (outside the store namespace, at the marquee tier the
# store can never sell — the marquee-tier side is asserted in the world's test_wardrobe_catalog).
# There is NO title/coin/xp/power/level reward and NO guild-level gate — a shared trophy wall, never
# a shared stat buff.

const AchievementProgress = preload("res://scripts/achievement_progress.gd")
const GuildAchievementRegistry = preload("res://scripts/guild_achievement_registry.gd")

# Reward keys a guild achievement may carry — cosmetic identity only. `coin`/`title` are legal for
# PER-CHARACTER achievements but NOT for a guild (a guild-wide coin faucet or account title would be
# the exact guild-power/perk track the ticket forbids as guild-hopping bait).
const _ALLOWED_REWARD_KEYS := ["cosmetic"]
const _STORE_PREFIXES := ["cos_", "skin_"]
const _FORBIDDEN_FIELDS := [
	"stats",
	"attack",
	"armor",
	"damage",
	"power",
	"bonuses",
	"effects",
	"hp",
	"coin",
	"title",
	"xp",
	"level",
	"perk",
	"buff",
	"gate",
	"unlock_content"
]

# The guild-scoped event vocabulary (everything a guild def is allowed to reference). A per-char
# event (kill/quest/level/...) must NEVER appear on a guild row — that would double the character
# ladder, not build a collective one.
const _GUILD_EVENTS := (
	AchievementProgress.GUILD_COUNT_EVENTS
	+ AchievementProgress.GUILD_FLAG_EVENTS
	+ AchievementProgress.GUILD_MAX_EVENTS
)


func before_each() -> void:
	GuildAchievementRegistry._reload_for_test()  # undo any _override_for_test — read the SHIPPED file


func _defs() -> Array:
	var defs := GuildAchievementRegistry.defs()
	assert_gt(defs.size(), 4, "the guild catalog is a real collective ladder, not a stub")
	return defs


# ---- (a) every criteria.event is a GUILD-scoped event the engine advances --------------------


func test_every_guild_criteria_event_is_guild_scoped_and_supported() -> void:
	for def: Dictionary in _defs():
		var event := str((def.get("criteria", {}) as Dictionary).get("event", ""))
		assert_true(
			event in _GUILD_EVENTS,
			(
				"%s references non-guild event '%s' (guild rows must be collective)"
				% [str(def.get("id", "")), event]
			)
		)
		assert_true(
			event in AchievementProgress.SUPPORTED_EVENTS,
			"%s references unknown criteria event '%s'" % [str(def.get("id", "")), event]
		)


# ---- (b) every guild event has a live server emit site ---------------------------------------


func test_every_guild_event_is_emitted_by_the_server() -> void:
	var sources := _read_all_scripts()
	for event: String in _GUILD_EVENTS:
		var wired := false
		for text: String in sources:
			# credit_guild(result, cid, "<event>", ...) or GuildAchievements.observe(gid, "<event>")
			if text.contains(', "%s"' % event):
				wired = true
				break
		assert_true(wired, "guild event '%s' is referenced but never emitted by the server" % event)


func _read_all_scripts() -> Array:
	var out: Array = []
	var dir := DirAccess.open("res://scripts")
	assert_not_null(dir, "scripts dir opens")
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name.ends_with(".gd"):
			var f := FileAccess.open("res://scripts/" + name, FileAccess.READ)
			if f != null:
				out.append(f.get_as_text())
		name = dir.get_next()
	dir.list_dir_end()
	return out


# ---- (c) T-482 charter: rewards are cosmetic-only, earn-only, power-free ----------------------


func test_every_guild_reward_is_cosmetic_identity_only() -> void:
	for def: Dictionary in _defs():
		var aid := str(def.get("id", ""))
		var reward: Dictionary = def.get("reward", {})
		for key: Variant in reward:
			assert_true(
				str(key) in _ALLOWED_REWARD_KEYS,
				(
					"%s reward carries non-cosmetic key '%s' (guild rewards are identity-only)"
					% [aid, str(key)]
				)
			)
		for field: String in _FORBIDDEN_FIELDS:
			assert_false(
				reward.has(field), "%s reward carries a power/perk field '%s'" % [aid, field]
			)
		# no power/perk/level field may hide at the DEF level either (a guild-level gate is forbidden).
		for field2: String in _FORBIDDEN_FIELDS:
			assert_false(def.has(field2), "%s def carries a forbidden field '%s'" % [aid, field2])
		if reward.has("cosmetic"):
			var cid := str(reward["cosmetic"])
			assert_ne(cid, "", "%s cosmetic id is non-empty" % aid)
			for prefix: String in _STORE_PREFIXES:
				assert_false(
					cid.begins_with(prefix),
					"%s earns store-namespace cosmetic '%s' (must be earn-only)" % [aid, cid]
				)


# ---- (d) at least one guild-earned cosmetic exists (the identity payoff is real) -------------


func test_the_catalog_actually_grants_a_guild_cosmetic() -> void:
	assert_gt(
		GuildAchievementRegistry.cosmetic_rewards().size(),
		0,
		"the guild ladder unlocks at least one wearable identity (tabard/crest/regalia)",
	)
