class_name CombatResources

# T-016: Server-authoritative resource pools (HP, mana, stamina).
#
# Pure data class — no side effects, no OS time, no global RNG.
# All mutation functions return a NEW CombatResources instance;
# the original is never modified. Coefficients read from ServerConfig.

extends RefCounted

const _SC = preload("res://scripts/server_config.gd")
# T-061: stat->pool derivation lives in the one tunable module (HP/mana/swing-pool constants moved
# there from the local HP_FROM_STR_* consts). This class stays a dumb pool holder.
const _STC = preload("res://scripts/combat/stat_converter.gd")
const _RM = preload("res://scripts/combat/resource_model.gd")

var hp: int = 0
var max_hp: int = 0
var mana: int = 0
var max_mana: int = 0
var stamina: int = 0
var max_stamina: int = 0

# T-062: the class resource — kind-keyed (rage | mana | none) so a future class's energy/combo is
# one branch + data, not new fields everywhere. Casters reuse the mana field (kind="mana"); warriors
# use rage. Read/write via class_resource*() / with_class_resource() — never the raw field.
var resource_kind: String = "none"
var rage: int = 0
var max_rage: int = 0
var last_spend_tick: int = 0  # for mana's 5-second rule (set on every class-resource spend)
var last_combat_tick: int = 0  # for rage's out-of-combat decay (set when the entity deals/takes)


func derive_from_stats(stats: CharacterStats) -> void:
	"""
	T-061: Pure derivation from the attribute vector. max HP from the Stamina stat, max mana from
	Intellect, the swing pool (max_stamina) from Dex — all via stat_converter (the one tunable home).
	Called on entity creation and on stat change. Fills max_ fields and sets current = max.
	NOTE: `max_stamina` is the UO swing-economy POOL (Dex-derived), distinct from the Stamina STAT
	that drives HP — see the naming note in stat_converter.gd.
	"""
	max_hp = _STC.max_hp(stats.stamina_val)
	max_mana = _STC.max_mana(stats.int_val)
	max_stamina = _STC.swing_pool(stats.dex_val)
	hp = max_hp
	mana = max_mana
	stamina = max_stamina


func _duplicate_with(dup: CombatResources) -> CombatResources:
	"""Copy current values into a new instance."""
	dup.hp = hp
	dup.max_hp = max_hp
	dup.mana = mana
	dup.max_mana = max_mana
	dup.stamina = stamina
	dup.max_stamina = max_stamina
	dup.resource_kind = resource_kind
	dup.rage = rage
	dup.max_rage = max_rage
	dup.last_spend_tick = last_spend_tick
	dup.last_combat_tick = last_combat_tick
	return dup


func apply_damage(amount: int) -> CombatResources:
	"""Pure — returns new CombatResources with HP reduced. Clamps to [0, max]."""
	if amount <= 0:
		return _duplicate_with(CombatResources.new())
	var result := CombatResources.new()
	result = _duplicate_with(result)
	result.hp = max(0, hp - amount)
	return result


func apply_heal(amount: int) -> CombatResources:
	"""Pure — returns new CombatResources with HP increased. Clamps to [0, max]."""
	if amount <= 0:
		return _duplicate_with(CombatResources.new())
	var result := CombatResources.new()
	result = _duplicate_with(result)
	result.hp = min(max_hp, hp + amount)
	return result


func apply_mana_cost(cost: int) -> CombatResources:
	"""Pure — returns new CombatResources with mana deducted. Clamps to 0."""
	if cost <= 0:
		return _duplicate_with(CombatResources.new())
	var result := CombatResources.new()
	result = _duplicate_with(result)
	result.mana = max(0, mana - cost)
	return result


func apply_stamina_drain(drain: int) -> CombatResources:
	"""Pure — returns new CombatResources with stamina reduced. Clamps to [0, max]."""
	if drain <= 0:
		return _duplicate_with(CombatResources.new())
	var result := CombatResources.new()
	result = _duplicate_with(result)
	result.stamina = max(0, stamina - drain)
	return result


static func is_dead(res: CombatResources) -> bool:
	"""T-026: Return true when HP is at or below 0."""
	return res.hp <= 0


func revive(hp_pct: float, mana_pct: float) -> CombatResources:
	"""T-364: pure resurrection restore — HP/mana to a fraction of max (HP floored at 1 so the
	revived ally is actually alive). Rage resets to empty; a mana class refills to mana_pct."""
	var result := _duplicate_with(CombatResources.new())
	result.hp = maxi(1, int(round(float(max_hp) * hp_pct)))
	if resource_kind == "mana":
		result.mana = clampi(int(round(float(max_mana) * mana_pct)), 0, max_mana)
	result.rage = 0
	return result


# ---- T-062: class resource (kind-keyed: rage | mana). Callers use these, never the raw field. ----


func class_resource() -> int:
	"""Current class-resource value, kind-agnostic (HUD bar, broadcast, use_ability gate use this)."""
	if resource_kind == "mana":
		return mana
	if resource_kind == "rage":
		return rage
	return 0


func class_resource_max() -> int:
	if resource_kind == "mana":
		return max_mana
	if resource_kind == "rage":
		return max_rage
	return 0


func set_class_resource(char_class: String, int_val: int) -> void:
	"""Stamp the class resource from class + Intellect (ResourceModel is the source of truth): warrior
	rage starts empty, caster mana starts full, unknown class = inert. Called at spawn after derive."""
	var r: Dictionary = _RM.initial_for_class(char_class, int_val)
	resource_kind = str(r["kind"])
	if resource_kind == "rage":
		rage = int(r["current"])
		max_rage = int(r["max"])
	elif resource_kind == "mana":
		mana = int(r["current"])
		max_mana = int(r["max"])


func with_class_resource(value: int) -> CombatResources:
	"""Pure — copy with the class resource set to `value` (clamped to [0, max]). Tick-loop regen/decay
	feeds ResourceModel's computed value here."""
	var result := _duplicate_with(CombatResources.new())
	if resource_kind == "mana":
		result.mana = clampi(value, 0, max_mana)
	elif resource_kind == "rage":
		result.rage = clampi(value, 0, max_rage)
	return result


func spend_class_resource(cost: int, now: int) -> CombatResources:
	"""Pure — spend `cost` of the class resource, recording the spend tick (mana's 5-second rule)."""
	var result := _duplicate_with(CombatResources.new())
	var spent: int = maxi(0, cost)
	if resource_kind == "mana":
		result.mana = maxi(0, mana - spent)
	elif resource_kind == "rage":
		result.rage = maxi(0, rage - spent)
	result.last_spend_tick = now
	return result


func mark_combat(now: int) -> CombatResources:
	"""Pure — copy stamped with the current combat tick (gates rage's out-of-combat decay)."""
	var result := _duplicate_with(CombatResources.new())
	result.last_combat_tick = now
	return result


func regen_vitals_tick(tick: int) -> CombatResources:
	"""
	Pure — returns new CombatResources after one server tick of VITALS regen: HP + the
	dex swing pool (stamina). Regen fires when tick % INTERVAL == 0; no HP regen when
	hp == 0 (Dead). Mana is NOT touched here — the class-resource model owns it (T-062
	five-second rule); regenerating it here double-dipped (T-071).
	Intervals and rates read from ServerConfig.
	"""
	var result := _duplicate_with(CombatResources.new())

	# HP regen — no regen when Dead (hp == 0)
	if hp > 0:
		var hp_interval := _SC.get_hp_regen_interval()
		var hp_rate := _SC.get_hp_regen_per_interval()
		if tick % hp_interval == 0:
			result.hp = min(max_hp, hp + hp_rate)

	# Swing-pool (stamina) regen
	var stamina_interval := _SC.get_stamina_regen_interval()
	var stamina_rate := _SC.get_stamina_regen_per_interval()
	if tick % stamina_interval == 0:
		result.stamina = min(max_stamina, stamina + stamina_rate)

	return result
