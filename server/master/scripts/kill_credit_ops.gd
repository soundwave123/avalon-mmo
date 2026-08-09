class_name KillCreditOps
extends RefCounted

# Carved out of main.gd at its 1000-line gdlint cap (T-613 needed a few more dispatch lines and
# tipped it over). Pure functions only — no `self` state, just CharacterManager/AchievementStore/
# MobXp/MentorCreditStore/TelemetryStore (all global) — so the move is behavior-identical; the
# call sites (main.gd's "credit_kill" dispatch arm, _credit_reach, _turn_in) were repointed here.

# CharacterManager/MobXp/TelemetryStore have no class_name (deliberately — every caller aliases
# them); AchievementStore/MentorCreditStore DO, so they resolve as bare globals below.
const CharacterManager = preload("res://scripts/character_manager.gd")
const MobXp = preload("res://scripts/mob_xp.gd")
const TelemetryStore = preload("res://scripts/telemetry_store.gd")
const GuildStore = preload("res://scripts/guild_store.gd")  # T-679: guild scope resolution
const GuildAchievementStore = preload("res://scripts/guild_achievement_store.gd")  # T-679


# T-367: fold any newly-earned achievements into a credit result so the world can toast the earner.
static func merge_achievements(result: Dictionary, observed: Dictionary) -> void:
	var earned: Array = observed.get("newly_earned", [])
	if not earned.is_empty():
		result["achievements"] = (result.get("achievements", []) as Array) + earned


# T-679: credit a server-validated collective event to the actor's CURRENT guild (a no-op for the
# guildless) and fold any newly-earned GUILD achievement into the result under a distinct key so the
# world can broadcast a "our guild earned X" toast to the whole roster (vs. the personal one above).
static func credit_guild(
	result: Dictionary, cid: int, event: String, key: String, value := 0
) -> void:
	var gid := GuildStore.guild_id_for(cid)
	if gid <= 0:
		return
	var earned: Array = GuildAchievementStore.observe(gid, event, key, value).get(
		"newly_earned", []
	)
	if not earned.is_empty():
		result["guild_achievements"] = (result.get("guild_achievements", []) as Array) + earned


static func party_level_sum(usernames: Array) -> int:
	if usernames.size() <= 1:
		return -1
	var total := 0
	for u in usernames:
		total += maxi(1, int(CharacterManager.get_character(str(u)).get("level", 1)))
	return total


# T-042: credit a kill to the username's active matching quests. Returns {"credited": [quest_id]}.
# T-358: also grants server-observed mob-kill XP (world reports the kill + snapshot; there is NO
# client verb). The amount comes from the pure mob_xp.gd (gray cutoff + party split); the player's
# level is read from the persisted character, never the packet; rested applies to kill XP (WoW).
static func credit_kill(
	username: String,
	mob_id: String,
	quest_defs: Dictionary,
	mob_xp: int = 0,
	mob_level: int = 1,
	party_size: int = 1,
	mentor_level: int = -1,
	mentor_opted_in: bool = false,
	mentor_active: bool = false,
	party_usernames: Array = []
) -> Dictionary:
	var character: Dictionary = CharacterManager.get_character(username)
	if character.is_empty():
		return {"credited": []}
	var cid := int(character.get("id", -1))
	var result: Dictionary = CharacterManager.credit_kill(cid, mob_id, quest_defs)
	# T-367: server-observed achievement progress rides the kill credit the server already validated.
	merge_achievements(result, AchievementStore.observe(cid, "kill", mob_id))
	credit_guild(result, cid, "guild_kill", mob_id)  # T-679: roster-total kills, credited to the guild
	var char_lvl := int(character.get("level", 1))
	# T-620: party_usernames level-weights the split (a low-level rider no longer earns an equal cut).
	var granted := MobXp.share(
		mob_xp, mob_level, char_lvl, party_size, mentor_level, party_level_sum(party_usernames)
	)
	if granted > 0:
		result["mob_xp"] = granted
		result["leveling"] = CharacterManager.award_xp_to_character(cid, granted, true)
	var mentor := (
		MentorCreditStore
		. observe_completion(
			username,
			{
				"opted_in": mentor_opted_in,
				"effective_level": mentor_level,
				"active_participation": mentor_active,
			},
			mob_id
		)
	)
	if int(mentor.get("credit_delta", 0)) > 0:
		result["mentor_credit"] = {"credit": mentor["credit"], "unlocks": mentor["unlocks"]}
		merge_achievements(result, {"newly_earned": mentor["achievements"]})
	TelemetryStore.record_kill_funnel(username, mob_id, result.get("leveling", {}))  # T-528 funnel
	return result
