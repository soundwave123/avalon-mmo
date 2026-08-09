extends "res://addons/gut/test.gd"

# T-723 layout audit: every class's INTERRUPT must sit in a slot the keyboard can actually reach.
#
# The kit the client renders is derived here, not authored by hand: ability_registry sorts a class's
# abilities by id (a stable default action-bar order) and kit_helper drops the trainer-gated ones
# until they're bought, so an ability's SLOT INDEX moves as the player trains. That is how the
# T-719 bug happened — Pummel (106) and Counterspell (206) are the highest ids in their kits, so a
# fully-trained warrior/mage carries the interrupt at index 5, which the old KEY_1..KEY_4 input map
# could not cast at all. The tutorial's interrupt lesson asked for a press that was impossible.
#
# The client half of the fix widened the keyed range to the whole nine-slot bar; this test is the
# standing guard on the DATA side: if a future ability id, a new class or a re-ordering pushes an
# interrupt (or any kit ability) past the keyed range, the suite fails here rather than in a
# playtest. Worst case is the fully-trained kit — every unlock inserts a LOWER id ahead of the
# interrupt — so both the untrained and fully-trained kits are audited.

const _AR = preload("res://scripts/combat/ability_registry.gd")
const _KIT = preload("res://scripts/kit_helper.gd")
const _BLO = preload("res://scripts/bar_layout_ops.gd")

const CLASSES := ["warrior", "mage", "priest"]

# How many action-bar slots the keyboard can cast. Mirrors AbilityKeybinds.SLOT_COUNT in
# client/scripts/ui/ability_keybinds.gd — and test_keyed_range_matches_the_client below reads that
# file to prove the mirror is honest, so the two projects cannot drift apart in silence.
const KEYED_SLOTS := 9
const CLIENT_KEYBINDS_REL := "../../client/scripts/ui/ability_keybinds.gd"


func _reg():
	var r = _AR.new()
	r.load_from_dir("res://data/abilities")
	return r


# Every trainer-gated id for a class — "fully trained" is the worst case for an interrupt's index.
func _trained_ids(reg, char_class: String) -> Array:
	var out: Array = []
	for ab in reg.get_abilities_for_class(char_class):
		if ab.trained:
			out.append(ab.id)
	return out


# The ids of a class's full-interrupt abilities (the role-free break: Pummel, Counterspell).
func _interrupt_ids(reg, char_class: String) -> Array:
	var out: Array = []
	for ab in reg.get_abilities_for_class(char_class):
		if ab.can_full_interrupt:
			out.append(ab.id)
	return out


func _kit_ids(reg, char_class: String, unlocked: Array) -> Array:
	var out: Array = []
	for row in _KIT.build_kit(reg, char_class, unlocked):
		out.append(int(row["id"]))
	return out


func test_every_class_kit_fits_the_keyed_range() -> void:
	# A kit longer than the keyed bar means abilities the player owns but cannot press — the same
	# class of bug as T-723, one ability further out. Growing a kit past this is a design decision
	# (a second bar / modifier row), never an accident.
	var reg = _reg()
	for cls in CLASSES:
		var ids := _kit_ids(reg, cls, _trained_ids(reg, cls))
		assert_lte(
			ids.size(),
			KEYED_SLOTS,
			(
				"%s's fully-trained kit (%d abilities) must fit the %d keyed slots"
				% [cls, ids.size(), KEYED_SLOTS]
			)
		)


func test_interrupts_sit_in_a_keyed_slot_by_default() -> void:
	var reg = _reg()
	for cls in CLASSES:
		var trained := _trained_ids(reg, cls)
		for interrupt_id in _interrupt_ids(reg, cls):
			# Untrained (fresh character) and fully-trained (largest index) default layouts.
			for unlocked in [[], trained]:
				var slot: int = _kit_ids(reg, cls, unlocked).find(interrupt_id)
				assert_gte(slot, 0, "%s's interrupt %d is in its kit" % [cls, interrupt_id])
				assert_lt(
					slot,
					KEYED_SLOTS,
					(
						"%s's interrupt %d sits at slot %d — past the keyed range"
						% [cls, interrupt_id, slot + 1]
					)
				)


func test_the_interrupt_roster_is_the_audited_one() -> void:
	# Keeps the audit above from passing VACUOUSLY: if an interrupt is renamed, re-flagged or given
	# to a new class, this assert fails and the roster gets a deliberate update. Priest carries no
	# full interrupt by design (T-434 gave it a hard-CC stun instead) — its empty list is the truth.
	var reg = _reg()
	var roster := {}
	for cls in CLASSES:
		roster[cls] = _interrupt_ids(reg, cls)
	assert_eq(
		roster,
		{"warrior": [106], "mage": [206], "priest": []},
		"the role-free interrupt roster (Pummel / Counterspell)"
	)


func test_any_saved_layout_keeps_the_interrupt_keyed() -> void:
	# Players re-order the bar by drag (T-422c) and the server persists it. Because a kit fits the
	# keyed range, EVERY permutation the server will accept is keyed too — proved on the harshest
	# one, a full reversal that drives the interrupt as far right as it can go.
	var reg = _reg()
	for cls in CLASSES:
		var kit: Array = _KIT.build_kit(reg, cls, _trained_ids(reg, cls))
		var reversed_ids: Array = _BLO.ids(kit)
		reversed_ids.reverse()
		var sanitized: Array = _BLO.sanitize(reversed_ids, _BLO.ids(kit))
		assert_eq(sanitized, reversed_ids, "a full reversal is a layout the server accepts")
		var ordered: Array = _BLO.ids(_BLO.order_kit(kit, sanitized))
		for interrupt_id in _interrupt_ids(reg, cls):
			assert_lt(
				ordered.find(interrupt_id),
				KEYED_SLOTS,
				"%s's interrupt %d stays keyed under a reversed layout" % [cls, interrupt_id]
			)


func test_keyed_range_matches_the_client() -> void:
	# The audit is only meaningful if KEYED_SLOTS is what the CLIENT actually binds, so read the
	# client's map instead of trusting a copied number. (Skipped, not failed, when the world project
	# is checked out without the client beside it — the suite runs from the repo root.)
	var path := ProjectSettings.globalize_path("res://").path_join(CLIENT_KEYBINDS_REL)
	if not FileAccess.file_exists(path):
		pass_test("client keybind map not present next to the world project — drift check skipped")
		return
	var src := FileAccess.get_file_as_string(path)
	var found := RegEx.create_from_string("const SLOT_COUNT := ([0-9]+)").search(src)
	assert_not_null(found, "the client still declares AbilityKeybinds.SLOT_COUNT")
	if found != null:
		assert_eq(
			int(found.get_string(1)),
			KEYED_SLOTS,
			"the client's keyed slot count must match the one this audit asserts against"
		)
