# T-071: once-per-server-tick resource dynamics.
#
# is_new_tick() is the tick-edge guard: main.gd's _process runs every FRAME and headless
# Godot has no fps cap, so tick-gated dynamics applied per frame fired N× per interval
# (N = fps / TICK_RATE_HZ) — regen/decay rates scaled with server hardware.
#
# tick_player() is the pure per-player pass (clock-injected, no OS time, no side effects):
#   - rage decays out of combat / mana follows the T-062 five-second rule;
#   - HP + the swing pool regenerate only OUT of combat (T-071);
#   - the DEAD regenerate nothing (respawn restores them).

extends RefCounted

const _RM = preload("res://scripts/combat/resource_model.gd")
const _CS = preload("res://scripts/combat/combat_state.gd")
const _CSTATS = preload("res://scripts/combat/character_stats.gd")

# Out-of-combat window for vitals regen — same 5 s window rage decay uses.
const OUT_OF_COMBAT_TICKS: int = _RM.RAGE_OUT_OF_COMBAT_TICKS

var _last_tick: int = -1


# True exactly once per server tick, no matter how many frames land inside it.
func is_new_tick(now_tick: int) -> bool:
	if now_tick == _last_tick:
		return false
	_last_tick = now_tick
	return true


# T-586 cap-carve of main._tick_player_resources (behaviour-preserving; main.gd rides the
# gdlint 1000-line cap): one tick of resource dynamics for EVERY player, committed in place.
static func tick_all(
	resources: Dictionary, stats: Dictionary, states: Dictionary, now_tick: int
) -> void:
	for pid in resources:
		var cr = resources[pid]
		var spirit: int = stats.get(pid, _CSTATS.new()).spirit_val
		var out = tick_player(cr, spirit, states.get(pid), now_tick)
		if out != cr:
			resources[pid] = out


# Pure — one server tick of resource dynamics for one player. Returns the (possibly
# unchanged) CombatResources; the caller commits it to the live store.
static func tick_player(cr, spirit: int, combat_state, now_tick: int):
	if combat_state != null and combat_state.state == _CS.CombatStateEnum.DEAD:
		return cr

	var out = cr
	# T-062: class-resource dynamics (rage decay gates itself on the combat window;
	# mana regen gates itself on the five-second rule).
	if out.resource_kind == "rage":
		var nr: int = _RM.decay_rage(out.rage, out.last_combat_tick, now_tick, OUT_OF_COMBAT_TICKS)
		if nr != out.rage:
			out = out.with_class_resource(nr)
	elif out.resource_kind == "mana":
		var nm: int = _RM.regen_mana(out.mana, out.max_mana, out.last_spend_tick, now_tick, spirit)
		if nm != out.mana:
			out = out.with_class_resource(nm)

	# T-071: vitals (HP + swing pool) regenerate only out of combat.
	if now_tick - out.last_combat_tick >= OUT_OF_COMBAT_TICKS:
		out = out.regen_vitals_tick(now_tick)

	return out
