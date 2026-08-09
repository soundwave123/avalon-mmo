extends GutTest

# T-308: the kit action bar — slot count follows kit_size, slots carry 1-9 hotkey pips, and pressing
# a slot starts a (GCD-estimate) cooldown.

const ActionBar = preload("res://scripts/ui/action_bar.gd")


func _make() -> ActionBar:
	var bar := ActionBar.new()
	add_child_autofree(bar)  # runs _ready -> builds the slot row
	return bar


func _kit(n: int) -> Array:
	var k := []
	for i in range(n):
		k.append({"id": 100 + i, "name": "Ability %d" % i})
	return k


func test_slot_count_follows_kit_size() -> void:
	var bar := _make()
	bar.set_kit(_kit(4))
	assert_eq(bar.slot_count(), 4, "one slot per kit ability")


func test_rebuild_replaces_slots() -> void:
	var bar := _make()
	bar.set_kit(_kit(4))
	bar.set_kit(_kit(2))
	assert_eq(bar.slot_count(), 2, "re-issuing a smaller kit rebuilds cleanly")


func test_slots_capped_at_nine() -> void:
	var bar := _make()
	bar.set_kit(_kit(12))
	assert_eq(bar.slot_count(), ActionBar.MAX_SLOTS, "hotkeys only go 1-9")


func test_hotkey_pips_are_one_indexed() -> void:
	var bar := _make()
	bar.set_kit(_kit(3))
	assert_eq(bar.hotkey_label(0), "1")
	assert_eq(bar.hotkey_label(2), "3")


func test_press_starts_cooldown() -> void:
	var bar := _make()
	bar.set_kit(_kit(3))
	assert_false(bar.is_slot_on_cooldown(1), "idle slot has no cooldown")
	bar.trigger_slot(1)
	assert_true(bar.is_slot_on_cooldown(1), "pressing a slot starts the GCD-estimate sweep")


func test_press_out_of_range_is_safe() -> void:
	var bar := _make()
	bar.set_kit(_kit(2))
	bar.trigger_slot(5)  # no crash, no effect
	assert_eq(bar.slot_count(), 2)


# T-422a: a slot whose ability carries a resolvable icon slug renders the icon texture (not text).
func test_slot_renders_ability_icon() -> void:
	var bar := _make()
	bar.set_kit([{"id": 204, "name": "Frostbolt", "icon": "frostbolt"}])
	assert_not_null(bar.slot_icon_texture(0), "a mapped ability shows its icon texture")
	assert_eq(bar.slot_glyph_text(0), "", "the text glyph is absent when the icon renders")


# T-422a: a missing/blank icon falls back to the first-letters text glyph so nothing breaks.
func test_missing_icon_falls_back_to_text() -> void:
	var bar := _make()
	(
		bar
		. set_kit(
			[
				{"id": 100, "name": "Mystery Move"},  # no icon field
				{"id": 101, "name": "Bad Ref", "icon": "no_such_icon_xyz"},  # unresolvable slug
			]
		)
	)
	assert_null(bar.slot_icon_texture(0), "no icon field -> no texture")
	assert_eq(bar.slot_glyph_text(0), "MM", "blank icon falls back to the abbreviation glyph")
	assert_null(bar.slot_icon_texture(1), "unresolvable slug -> no texture")
	assert_eq(bar.slot_glyph_text(1), "BR", "missing icon file falls back to the glyph")


# T-422a: the icon does not displace the 1-9 hotkey pip or the GCD cooldown sweep.
func test_icon_slot_keeps_pip_and_sweep() -> void:
	var bar := _make()
	bar.set_kit([{"id": 204, "name": "Frostbolt", "icon": "frostbolt"}])
	assert_eq(bar.hotkey_label(0), "1", "hotkey pip survives the icon")
	assert_false(bar.is_slot_on_cooldown(0), "idle icon slot has no cooldown")
	bar.trigger_slot(0)
	assert_true(bar.is_slot_on_cooldown(0), "the GCD sweep still starts on an icon slot")


# T-555: the warrior kit shipped Pummel with Heroic Strike's slug and Concussive Blow with Sunder
# Armor's slug, so five abilities drew only ~3 glyphs (slots 1≡4, 3≡5). The bar must resolve each
# filled slot to a DISTINCT icon texture — no two equipped slots share a glyph.
func test_filled_slots_have_distinct_icons() -> void:
	var bar := _make()
	(
		bar
		. set_kit(
			[
				{"id": 1, "name": "Heroic Strike", "icon": "heroic_strike"},
				{"id": 2, "name": "Taunt", "icon": "taunt"},
				{"id": 3, "name": "Sunder Armor", "icon": "sunder_armor"},
				{"id": 4, "name": "Pummel", "icon": "heroic_strike"},  # server dup of slot 1
				{"id": 5, "name": "Concussive Blow", "icon": "sunder_armor"},  # server dup of slot 3
			]
		)
	)
	var seen := {}
	for slot in range(bar.slot_count()):
		var tex := bar.slot_icon_texture(slot)
		assert_not_null(tex, "filled slot %d resolves to an icon texture" % slot)
		var path := tex.resource_path if tex != null else ""
		assert_false(
			seen.has(path), "slot %d icon '%s' is not a duplicate of an earlier slot" % [slot, path]
		)
		seen[path] = true
	assert_eq(seen.size(), 5, "all five equipped abilities show their own distinct glyph")


# ---- T-422c drag-to-rebind (model + hotkey-follows-slot) ----------------------


# Dragging slot i onto slot j SWAPS the abilities underneath; the hotkey pip (slot number) stays,
# so key j now casts what used to be on i.
func test_swap_slots_moves_the_ability_and_keeps_the_hotkey() -> void:
	var bar := _make()
	bar.set_kit(_kit(4))  # ids 100,101,102,103
	assert_eq(bar.ability_id_at(0), 100, "slot 1 starts as ability 100")
	assert_eq(bar.ability_id_at(2), 102, "slot 3 starts as ability 102")
	bar.swap_slots(0, 2)
	assert_eq(bar.ability_id_at(0), 102, "the ability from slot 3 is now on slot 1")
	assert_eq(bar.ability_id_at(2), 100, "and slot 1's ability moved to slot 3")
	assert_eq(bar.hotkey_label(0), "1", "the hotkey number stays with the SLOT, not the ability")
	assert_eq(bar.hotkey_label(2), "3", "slot 3 is still bound to key 3 (now casting ability 100)")


# A reorder emits the new ordered id list so main can relay set_bar_layout + re-map its casts.
func test_swap_emits_layout_changed_with_the_new_order() -> void:
	var bar := _make()
	bar.set_kit(_kit(4))
	var events: Array = []  # lambdas capture locals by copy — mutate a shared array to capture
	bar.layout_changed.connect(func(ids): events.append(ids))
	bar.swap_slots(0, 3)
	assert_eq(events.size(), 1, "one reorder emits one signal")
	assert_eq(events[0], [103, 101, 102, 100], "layout_changed carries the full reordered id list")


# Placing an ability by id (the spellbook-drop path) swaps it into the target slot.
func test_place_ability_at_swaps_it_into_the_slot() -> void:
	var bar := _make()
	bar.set_kit(_kit(4))
	bar.place_ability_at(103, 0)  # drag ability 103 (slot 4) onto slot 1
	assert_eq(bar.ability_id_at(0), 103, "the dragged ability lands on slot 1")
	assert_eq(bar.ability_id_at(3), 100, "and slot 1's old ability takes 103's former slot")


# A drop payload from a bar slot round-trips through the drag handlers (source of truth for _drop).
func test_bar_drop_payload_swaps() -> void:
	var bar := _make()
	bar.set_kit(_kit(3))
	bar._drop_slot(Vector2.ZERO, {"source": "bar", "slot": 0, "ability_id": 100}, 2)
	assert_eq(bar.ability_id_at(2), 100, "a bar->bar drop swaps the two slots")


func test_book_drop_payload_places() -> void:
	var bar := _make()
	bar.set_kit(_kit(3))  # 100,101,102
	bar._drop_slot(Vector2.ZERO, {"source": "book", "ability_id": 102}, 0)
	assert_eq(bar.ability_id_at(0), 102, "a spellbook drop places the ability onto the target slot")


# ---- T-731 resource affordance (ready / on-cooldown / insufficient) ----------


# A warrior-shaped kit: a free ability, a cheap one, an expensive one. Costs come from the ability
# rows the server already ships (kit_helper: resource_cost/mana_cost) — the bar reads no class name.
func _cost_kit() -> Array:
	return [
		{"id": 100, "name": "Heroic Strike", "resource_cost": 0},
		{"id": 101, "name": "Revenge", "resource_cost": 20},
		{"id": 102, "name": "Cleave", "resource_cost": 60},
	]


func _sat(bar: ActionBar, slot: int) -> float:
	return float(bar.slot_shading(slot)["desaturation"])


func _dim(bar: ActionBar, slot: int) -> float:
	return float(bar.slot_shading(slot)["dim"])


func _afford(bar: ActionBar, slot: int) -> bool:
	return not ("insufficient" in bar.slot_visual_state(slot))


func test_insufficient_resource_desaturates_and_dims_the_slot() -> void:
	var bar := _make()
	bar.set_kit(_cost_kit())
	bar.set_resource_state("rage", 25, 100)  # covers Revenge (20), not Cleave (60)
	assert_true(_afford(bar, 1), "25 rage pays for the 20-rage ability")
	assert_false(_afford(bar, 2), "25 rage does not pay for the 60-rage ability")
	assert_gt(_sat(bar, 2), 0.5, "the unaffordable slot's art is drained of colour")
	assert_lt(_dim(bar, 2), 0.6, "and dimmed")
	assert_eq(bar.slot_visual_state(2), "insufficient")


func test_ready_slot_keeps_full_colour_and_brightness() -> void:
	var bar := _make()
	bar.set_kit(_cost_kit())
	bar.set_resource_state("rage", 100, 100)
	assert_eq(_sat(bar, 2), 0.0, "an affordable slot is not desaturated")
	assert_eq(_dim(bar, 2), 1.0, "an affordable slot is not dimmed")
	assert_eq(bar.slot_visual_state(2), "ready")


# The three states must be TOLD APART on sight, not just in the model: resource shortfall changes
# the art's saturation/brightness, cooldown lays a sweep over it. Neither borrows the other's cue.
func test_three_states_are_visually_distinct() -> void:
	var bar := _make()
	bar.set_kit(_cost_kit())
	bar.set_resource_state("rage", 100, 100)
	var ready_sat := _sat(bar, 2)
	var ready_dim := _dim(bar, 2)
	var ready_sweep := bar.sweep_fraction(2)

	bar.trigger_slot(2)  # ON-COOLDOWN, resource still plentiful
	assert_gt(bar.sweep_fraction(2), ready_sweep, "cooldown is encoded by the sweep")
	assert_eq(_sat(bar, 2), ready_sat, "cooldown does NOT borrow the resource cue")
	assert_eq(_dim(bar, 2), ready_dim, "cooldown leaves the art's brightness alone")
	assert_eq(bar.slot_visual_state(2), "cooldown")

	bar.set_kit(_cost_kit())  # clear the cooldown by rebuilding
	bar.set_resource_state("rage", 5, 100)  # INSUFFICIENT, no cooldown
	assert_ne(_sat(bar, 2), ready_sat, "insufficient changes saturation")
	assert_ne(_dim(bar, 2), ready_dim, "insufficient changes brightness")
	assert_eq(bar.sweep_fraction(2), ready_sweep, "insufficient does NOT borrow the cooldown sweep")


# Both at once: the sweep still covers the slot (cooldown wins the read) while the resource dim
# stays underneath it, so the button doesn't lie about being unaffordable when the sweep clears.
func test_cooldown_and_insufficient_compose() -> void:
	var bar := _make()
	bar.set_kit(_cost_kit())
	bar.set_resource_state("rage", 100, 100)
	bar.trigger_slot(2)
	bar.set_resource_state("rage", 0, 100)  # spent it all on the cast
	assert_true(bar.is_slot_on_cooldown(2), "the cooldown sweep survives the resource change")
	assert_gt(bar.sweep_fraction(2), 0.0, "cooldown is still drawn over the art")
	assert_gt(_sat(bar, 2), 0.5, "and the resource dim applies underneath")
	assert_eq(bar.slot_visual_state(2), "cooldown+insufficient")


# The live feed: rage building and decaying flips the same slot back and forth with no rebuild.
func test_slot_tracks_resource_across_the_threshold() -> void:
	var bar := _make()
	bar.set_kit(_cost_kit())
	bar.set_resource_state("rage", 0, 100)
	assert_false(_afford(bar, 1), "empty rage bar: the 20-rage ability is unaffordable")
	bar.set_resource_state("rage", 19, 100)
	assert_false(_afford(bar, 1), "one short is still short")
	bar.set_resource_state("rage", 20, 100)
	assert_true(_afford(bar, 1), "exactly the cost is affordable")
	assert_eq(_sat(bar, 1), 0.0, "crossing the threshold restores the art live")
	bar.set_resource_state("rage", 4, 100)  # rage decays out of combat
	assert_false(_afford(bar, 1), "decay dims it again without a kit rebuild")
	assert_gt(_sat(bar, 1), 0.5)


func test_free_ability_never_dims() -> void:
	var bar := _make()
	bar.set_kit(_cost_kit())
	bar.set_resource_state("rage", 0, 100)
	assert_true(_afford(bar, 0), "a no-cost ability is always castable")
	assert_eq(bar.slot_visual_state(0), "ready")


# Data-driven, not class-driven: mana defs (mana_cost field) and any future resource kind flow
# through the same check with no branch on the class.
func test_cost_reads_the_ability_data_for_any_resource() -> void:
	var bar := _make()
	(
		bar
		. set_kit(
			[
				{"id": 201, "name": "Fireball", "mana_cost": 45},  # caster defs use mana_cost
				{"id": 900, "name": "Future Move", "resource_cost": 30},
			]
		)
	)
	bar.set_resource_state("mana", 40, 200)
	assert_false(_afford(bar, 0), "40 mana does not pay a 45-mana cost")
	bar.set_resource_state("energy", 40, 100)  # a resource kind this code has never heard of
	assert_true(_afford(bar, 1), "40 energy pays a 30 cost — no class switch involved")
	bar.set_resource_state("energy", 10, 100)
	assert_false(_afford(bar, 1), "and 10 does not")


# A class with no resource pool (or a kit shown before the first snapshot) must never render as
# unaffordable — the bar only claims a shortfall it can actually see.
func test_no_resource_kind_never_dims() -> void:
	var bar := _make()
	bar.set_kit(_cost_kit())
	bar.set_resource_state("none", 0, 0)
	assert_true(_afford(bar, 2), "kind 'none' leaves every slot ready")
	assert_eq(_sat(bar, 2), 0.0)


# A rebuild (login, drag reorder, trainer purchase) re-stamps the CURRENT resource level, so a slot
# never renders a stale ready/dim state for a frame.
func test_kit_rebuild_restamps_affordance() -> void:
	var bar := _make()
	bar.set_kit(_cost_kit())
	bar.set_resource_state("rage", 30, 100)
	bar.swap_slots(0, 2)  # rebuilds: the 60-cost ability moves to slot 1
	assert_false(_afford(bar, 0), "the expensive ability is dim in its new slot")
	assert_true(_afford(bar, 2), "and the free ability is ready in its new slot")


# The affordance dims the ability ART, never the keybind pip — the number must stay readable so the
# player can still see WHICH key is starved (T-464 high-contrast pip is preserved).
func test_dimming_leaves_the_keybind_pip_untouched() -> void:
	var bar := _make()
	bar.set_kit(_cost_kit())
	bar.set_resource_state("rage", 0, 100)
	assert_eq(bar.hotkey_label(2), "3", "the pip still names its key while dimmed")
	assert_gt(bar.pip_outline_size(2), 0, "and keeps its high-contrast outline")
