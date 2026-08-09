class_name AbilitySfx
extends RefCounted

# T-343 phase 3: the per-ability SOUND map for the restyled kit (era-direction §11.5 "sound
# weight" bar). The frost bolt's phase-2 pass (frost_cast / frost_flight / frost_impact wired at
# the exact VFX beats through AudioManager.play_sfx) is the reference pattern; this table extends
# the same layering to every other shipped ability, keyed by ability id (mirroring
# server/world/data/abilities/*.json), voiced per SCHOOL:
#   fire     (2 Emberstrike, 201 Fireball, 202 Fire Blast, 205 Scorch) -> fire_cast / fire_impact
#   frost    (203 Frost Nova reuses the phase-2 frost_cast; 204 Frostbolt unchanged)
#   arcane   (206 Counterspell) -> the existing spell_cast shimmer pitched UP into a sharp zap
#   physical (1 Strike, 101-107 warrior kit) -> melee_swing whoosh + the hit thud, pitch-varied
#   holy     (301-306 priest kit) -> holy_cast / holy_impact, heals land the heal_chime
#   shadow   (307 Psychic Horror) -> shadow_cast descending sting
# Entries are [sfx_name, volume_db, pitch]; pitch/volume variants of one file are deliberate
# (reuse-over-new). Volumes are balanced against the frost kit: casts sit near frost_cast's -6,
# impacts under frost_impact's -5 money hit, swings under their own landing thud.
#
# KNOWN ASSET GAPS (flagged per §11.5 rather than shipping a mismatched sound — see the ticket):
# 102 Taunt wants a war-SHOUT voice cue (no voice asset exists; it carries a neutral low swing
# whoosh meanwhile), and control lands (203 root / 107 stun / 307 horror) have no target-side
# landing cue (damage-less results never reach the impact beat).

const CAST_DEFAULT: Array = ["spell_cast", -7.0, 1.0]
const IMPACT_DEFAULT: Array = ["hit", -11.0, 1.0]
const HEAL_DEFAULT: Array = ["heal_chime", -9.0, 1.0]

const CAST := {
	1: ["melee_swing", -11.0, 1.0],
	101: ["melee_swing", -10.0, 0.95],
	102: ["melee_swing", -11.0, 0.85],  # asset gap: wants a war-shout (see header)
	103: ["melee_swing", -10.0, 0.9],
	104: ["melee_swing", -10.0, 1.05],
	105: ["melee_swing", -9.0, 0.85],  # cleave: the widest arc = the lowest, loudest swing
	106: ["melee_swing", -10.0, 1.2],  # pummel: a quick jab
	107: ["melee_swing", -9.0, 0.8],  # concussive blow: the heaviest wind-up
	2: ["fire_cast", -7.0, 0.95],
	201: ["fire_cast", -7.0, 1.0],
	202: ["fire_cast", -8.0, 1.15],  # fire blast: instant, smaller and snappier
	205: ["fire_cast", -8.0, 1.08],
	203: ["frost_cast", -7.0, 1.15],  # frost nova reuses the phase-2 crystalline charge
	204: ["frost_cast", -6.0, 1.0],  # the phase-2 frost reference, byte-for-byte
	206: ["spell_cast", -7.0, 1.25],  # counterspell: the arcane shimmer sharpened into a zap
	301: ["holy_cast", -8.0, 1.1],
	302: ["holy_cast", -8.0, 1.05],
	303: ["holy_cast", -7.0, 1.0],
	304: ["holy_cast", -7.0, 0.95],
	305: ["holy_cast", -7.0, 1.0],
	306: ["holy_cast", -7.0, 0.9],  # resurrect: the gravest swell
	307: ["shadow_cast", -8.0, 1.0],
}

const IMPACT := {
	1: ["hit", -11.0, 1.0],
	101: ["hit", -10.0, 0.95],
	104: ["hit", -10.0, 1.05],
	105: ["hit", -10.0, 0.9],
	106: ["hit", -11.0, 1.2],
	2: ["fire_impact", -6.0, 0.95],
	201: ["fire_impact", -6.0, 1.0],
	202: ["fire_impact", -7.0, 1.1],
	205: ["fire_impact", -7.0, 1.05],
	204: ["frost_impact", -5.0, 1.0],  # the phase-2 frost reference, byte-for-byte
	206: ["hit", -12.0, 1.3],  # counterspell lands 1 damage — a tiny sharpened tick
	303: ["holy_impact", -6.0, 1.0],
	304: ["holy_impact", -6.0, 0.95],
}

const HEAL := {
	301: ["heal_chime", -9.0, 1.1],  # flash heal: quick and bright
	302: ["heal_chime", -10.0, 1.05],  # renew: the gentlest tick
	305: ["heal_chime", -8.0, 1.0],  # greater heal: the big landing
	306: ["heal_chime", -8.0, 0.9],  # resurrect: gravest
}


static func cast_for(ability_id: int) -> Array:
	return CAST.get(ability_id, CAST_DEFAULT)


static func impact_for(ability_id: int) -> Array:
	return IMPACT.get(ability_id, IMPACT_DEFAULT)


static func heal_for(ability_id: int) -> Array:
	return HEAL.get(ability_id, HEAL_DEFAULT)


# The three beat helpers keep the main.gd call sites one line each (main.gd rides the 1000-line
# cap). All null-guard the AudioManager so headless/harness callers stay safe.
static func play_cast(audio: AudioManager, ability_id: int) -> void:
	_play(audio, cast_for(ability_id))


static func play_impact(audio: AudioManager, ability_id: int) -> void:
	_play(audio, impact_for(ability_id))


static func play_heal(audio: AudioManager, ability_id: int) -> void:
	_play(audio, heal_for(ability_id))


static func _play(audio: AudioManager, cue: Array) -> void:
	if audio != null:
		audio.play_sfx(str(cue[0]), float(cue[1]), float(cue[2]))
