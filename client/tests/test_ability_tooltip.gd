extends GutTest

# T-464: action-bar discoverability — the hover tooltip builder, the locked/future-slot affordance,
# the high-contrast keybind pip, and the on-icon cooldown sweep.

const ActionBar = preload("res://scripts/ui/action_bar.gd")
const AbilityTooltip = preload("res://scripts/ui/ability_tooltip.gd")


func _make() -> ActionBar:
	var bar := ActionBar.new()
	add_child_autofree(bar)  # runs _ready -> builds the slot row + tooltip
	return bar


func _frostbolt() -> Dictionary:
	return {
		"id": 204,
		"name": "Frostbolt",
		"icon": "frostbolt",
		"effect": "damage",
		"cast_ticks": 30,
		"resource_cost": 45,
		"cooldown_ticks": 120,  # 6.0 sec at 20 Hz
		"range_units": 30.0,
		"base_damage": 100,
		"variance_min": 0.9,
		"variance_max": 1.1,
		"attacker_stat_coeffs": {"int": 0.5},
	}


# ---- tooltip builder (pure) --------------------------------------------------


func test_tooltip_has_name_cost_and_cooldown() -> void:
	var text := AbilityTooltip.build_text(_frostbolt(), "mana", "1")
	assert_string_contains(text, "Frostbolt", "tooltip leads with the ability name")
	assert_string_contains(
		text, "45 Mana", "tooltip shows the resource cost, named by class resource"
	)
	assert_string_contains(text, "6.0 sec cooldown", "tooltip shows the cooldown")


func test_tooltip_has_description_and_keybind() -> void:
	var text := AbilityTooltip.build_text(_frostbolt(), "mana", "1")
	assert_string_contains(
		text, "Strikes an enemy", "tooltip carries a one-line effect description"
	)
	assert_string_contains(text, "Press [1]", "tooltip names the key that fires the ability")


func test_no_cooldown_omits_the_cooldown_line() -> void:
	var ability := _frostbolt()
	ability["cooldown_ticks"] = 0
	var text := AbilityTooltip.build_text(ability, "mana", "1")
	assert_false(text.contains("cooldown"), "an ability off cooldown shows no cooldown line")


func test_locked_text_signals_future_unlock() -> void:
	var text := AbilityTooltip.locked_text("5")
	assert_string_contains(
		text, "unlocks", "a locked slot tells the player an ability arrives later"
	)
	assert_string_contains(text, "5", "the locked slot names the key it will bind")


# ---- action bar wiring -------------------------------------------------------


func test_slot_tooltip_text_reaches_the_bar() -> void:
	var bar := _make()
	bar.set_resource_kind("mana")
	bar.set_kit([_frostbolt()])
	var text := bar.slot_tooltip_text(0)
	assert_string_contains(text, "Frostbolt", "hovering slot 1 builds Frostbolt's tooltip")
	assert_string_contains(text, "6.0 sec cooldown", "the slot tooltip carries the cooldown")


# T-464: a small kit pads out to MIN_VISIBLE_SLOTS with dim locked placeholders (future slots read).
func test_small_kit_shows_locked_placeholder_slots() -> void:
	var bar := _make()
	bar.set_kit([_frostbolt()])  # one ability
	assert_eq(bar.slot_count(), 1, "one real slot for the one ability")
	assert_eq(
		bar.locked_slot_count(),
		ActionBar.MIN_VISIBLE_SLOTS - 1,
		"the rest of the visible slots are locked/future placeholders",
	)


# As the kit grows past the minimum, the locked placeholders disappear (no over-claiming).
func test_full_kit_shows_no_locked_slots() -> void:
	var bar := _make()
	var kit: Array = []
	for i in range(ActionBar.MIN_VISIBLE_SLOTS + 1):
		kit.append({"id": 300 + i, "name": "Ability %d" % i})
	bar.set_kit(kit)
	assert_eq(bar.locked_slot_count(), 0, "a bar past the minimum shows no locked placeholders")


# T-464: the keybind pip carries a black outline so it reads over bright icon art (T-396 model).
func test_keybind_pip_is_high_contrast() -> void:
	var bar := _make()
	bar.set_kit([_frostbolt()])
	assert_gt(bar.pip_outline_size(0), 0, "the keybind pip has an outline for legibility")


# ---- cooldown sweep ----------------------------------------------------------


func test_cooldown_sweep_covers_the_icon_on_press() -> void:
	var bar := _make()
	bar.set_kit([_frostbolt()])
	assert_almost_eq(bar.sweep_fraction(0), 0.0, 0.001, "an idle slot has no sweep coverage")
	bar.trigger_slot(0)
	assert_true(bar.is_slot_on_cooldown(0), "pressing starts the cooldown sweep")
	assert_gt(bar.sweep_fraction(0), 0.5, "a just-fired slot is mostly covered by the sweep")
