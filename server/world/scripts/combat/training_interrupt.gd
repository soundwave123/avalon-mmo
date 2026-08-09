# T-426 slice 4: PURE detection of a broken training-effigy telegraph, for crediting the tutorial
# "interrupt" objective (q_tut_03). Mirrors the pure-module discipline of boss_mechanics.gd /
# objective_tracker.gd: no OS time, no globals, inputs never mutated. The caller (world main's
# _commit_ability_result) invokes this the instant a player's ability result is about to be
# committed against a mob, passing the mob BEFORE the commit overwrites its combat_state/resources.
#
# The training effigy runs the M6 "dirge" channel under the distinct boss_mechanic "training_dirge"
# (so a real crypt dirge boss never credits a tutorial objective). A trainee breaks the wind-up TWO
# server-authoritative ways, both detected here from the same executor result:
#   1. Dedicated interrupt (warrior Pummel / mage Counterspell): ability_executor already stamped
#      interrupt_landed on the result (apply_interrupt moved the channel out of CHANNELING). Priests
#      have no dedicated interrupt, hence path 2.
#   2. Damage break (class-agnostic): this single hit dropped the effigy's HP by at least
#      dirge_interrupt_damage since the channel began (boss_mechanics uses the same threshold to
#      cancel the dirge on the next tick — we credit the breaking hit's caster, not a later tick).
extends RefCounted

const _CS = preload("res://scripts/combat/combat_state.gd")

const MECHANIC := "training_dirge"


# True when `exec_result` is the ability hit that broke `mob`'s training telegraph. `mob` MUST be
# the target as it stood BEFORE this result is committed (its combat_state is still the pre-hit
# channel state, dirge_hp_at_start still the channel's starting HP). Returns false for any
# non-training mob, a mob not mid-channel, or a hit that neither interrupted nor crossed threshold.
static func telegraph_broken(mob, exec_result) -> bool:
	if mob == null or exec_result == null or not exec_result.accepted:
		return false
	if str(mob.boss_mechanic) != MECHANIC:
		return false
	if mob.combat_state == null:
		return false
	var channeling: bool = (
		mob.combat_state.state == _CS.CombatStateEnum.CASTING
		or mob.combat_state.state == _CS.CombatStateEnum.CHANNELING
	)
	if not channeling:
		return false
	# Path 1: a dedicated interrupt moved the effigy out of the channel this hit.
	if bool(exec_result.interrupt_landed):
		return true
	# Path 2: this hit's damage crossed the channel's interrupt threshold (any class).
	if int(mob.dirge_interrupt_damage) <= 0 or exec_result.new_target_resources == null:
		return false
	if int(mob.dirge_hp_at_start) < 0:
		return false
	var lost: int = int(mob.dirge_hp_at_start) - int(exec_result.new_target_resources.hp)
	return lost >= int(mob.dirge_interrupt_damage)
