class_name EntitySnapshot

# Value object passed into the ability validation pipeline.
# Built by main.gd from server-authoritative state; never mutated by the pipeline.

extends RefCounted

# Preloads ensure class_name types resolve in --check-only parse mode.
const _CS = preload("res://scripts/combat/combat_state.gd")
const _CR = preload("res://scripts/combat/combat_resources.gd")
const _CSTATS = preload("res://scripts/combat/character_stats.gd")

var peer_id: int = -1
var position: Vector3 = Vector3.ZERO
var combat_state: CombatState = null
var resources: CombatResources = null
var stats: CharacterStats = null
var char_class: String = ""  # T-063: caster class ("" = mob/any) for ability class-gating
var is_mob: bool = false  # T-063: true for mobs (enemies) — friendly-only abilities reject these
# T-064: resolved talent ability modifiers ({} = none — mobs, talentless characters).
var ability_mods: Dictionary = {}
# T-365: server-authoritative caster level (drives rank scaling) + the trainer-unlocked ability ids
# (an unpurchased trained ability is not castable). Both read from the session, never the wire.
var level: int = 1
var unlocked: Array = []
# T-434: encounter-authored immunity flags. Populated only from MobData by combat_snapshot;
# player packets have no fields that can influence these server-truth booleans.
var control_immune: bool = false
var interrupt_immune: bool = false
