extends GutTest

# T-761: the guard on the central key registry.
#
# The audit's complaint was not that any single binding was wrong — it was that NOTHING could
# answer "which keys are taken?" without grepping 20 files, so two documentation lists had already
# drifted from what shipped and a new panel could silently steal a key. Three things keep the table
# honest, and they are the three sections below:
#
#   1. UNIQUENESS  — no two world-scope bindings claim the same physical key.
#   2. COVERAGE    — every KEY_* constant a shipped client script dispatches on has a row here.
#                    This is the meta-test the audit asked for: it reads the SOURCE TREE, in the
#                    same spirit as the server-side T-723 keyed-slot audit, so adding a binding
#                    without registering it fails the suite instead of a playtest.
#   3. RESOLUTION  — event_code (dispatch direction) and label_for (display direction) behave, on
#                    both the layout-aware and the headless path.

const REGISTRY_REL := "scripts/ui/key_registry.gd"

# Where the shipped client input code lives. scripts/dev is deliberately excluded: pilot.gd
# synthesizes arbitrary keys for automation and prop_showroom.gd is a free-fly asset viewer with
# its own QE/WASD camera — neither is a PLAYER binding, and registering their keys would make the
# table lie about what the game binds.
const SCAN_DIRS: Array = ["scripts", "scripts/ui", "scripts/world", "scripts/combat"]

const KEY_TOKEN := "KEY_[A-Z0-9_]+"

# ---------------------------------------------------------------- 1. uniqueness


func test_no_duplicate_world_bindings() -> void:
	# The check the audit demanded. World-scope keys are live simultaneously during normal play, so
	# two rows on one key means one of them is dead — press it and you get whichever listener the
	# tree happens to reach first, which is not a thing anyone decided.
	var seen := {}
	for b: Dictionary in KeyRegistry.bindings():
		if str(b["scope"]) != KeyRegistry.SCOPE_WORLD:
			continue
		var key := int(b["key"])
		var id := str(b["id"])
		assert_false(
			seen.has(key),
			(
				"%s and %s both bind %s — one of them can never fire"
				% [seen.get(key, ""), id, KeyRegistry.label_for(key)]
			)
		)
		seen[key] = id
	assert_gt(seen.size(), 30, "the world keymap is the whole game's bindings, not a subset")


func test_modal_bindings_may_alias_world_keys_but_ids_stay_unique() -> void:
	# Modal rows exist precisely so 1/2/3 can mean "class pick" under a modal and "ability slot"
	# during play — that aliasing is intended and UiInputGate is the switch. What must NOT collide
	# is the ids, or key_for() would silently answer with whichever row it hit first.
	var ids := {}
	for b: Dictionary in KeyRegistry.bindings():
		var id := str(b["id"])
		assert_false(ids.has(id), "duplicate binding id: %s" % id)
		ids[id] = true
	assert_eq(
		KeyRegistry.key_for("modal_pick_1"),
		KeyRegistry.key_for("ability_1"),
		"the documented alias: modal pick 1 sits on the ability-1 key"
	)


func test_every_owner_script_exists() -> void:
	# `owner` is how a human finds the listener for a binding. A stale path is a broken map.
	for b: Dictionary in KeyRegistry.bindings():
		var path := "res://" + str(b["owner"])
		assert_true(
			FileAccess.file_exists(path), "%s names a missing owner: %s" % [b["id"], b["owner"]]
		)


func test_the_two_rendered_key_lists_derive_from_the_registry() -> void:
	# The drift the audit found: settings_panel.KEYBINDS and controls_reference._ROWS were both
	# hand-typed. Now both name registry ids, so an unknown id must be impossible — an unresolved
	# id renders as an empty label, which is how this used to rot in silence.
	for row: Dictionary in ControlsReference.rows():
		assert_ne(str(row["keys_label"]), "", "%s renders no key label" % row["action"])
	var panel = preload("res://scripts/ui/settings_panel.gd").new()
	for row: Array in panel._keybind_rows():
		assert_ne(str(row[1]), "", "Options row '%s' renders no key label" % row[0])
	panel.free()


# ---------------------------------------------------------------- 2. coverage (the meta-test)


func test_registry_covers_every_key_the_source_tree_dispatches_on() -> void:
	# Reads the shipped client scripts and asserts every KEY_* constant they mention is registered.
	#
	# Both sides are compared as TOKEN TEXT, not as values: Godot exposes no runtime name->keycode
	# lookup for the global Key enum (Expression and ClassDB both decline @GlobalScope constants),
	# and a hand-written name->code table in this test would be exactly the kind of second list the
	# ticket exists to delete. Text on both sides needs no table and cannot drift.
	var registered := _tokens_in_file(REGISTRY_REL)
	assert_gt(registered.size(), 20, "the registry itself must name its keys as KEY_* literals")
	var unregistered: Array = []
	for rel in _client_scripts():
		if rel == REGISTRY_REL:
			continue
		for token in _tokens_in_file(rel).keys():
			if not registered.has(token):
				unregistered.append("%s (%s)" % [token, rel])
	assert_eq(
		unregistered,
		[],
		(
			"these keys are dispatched but not in KeyRegistry.BINDINGS — add a row (or move the "
			+ "script under scripts/dev if it is not a player binding): %s" % str(unregistered)
		)
	)


func test_the_coverage_scan_actually_reads_files() -> void:
	# A meta-test that silently scans nothing passes forever. Prove the scan sees the real tree and
	# the real bindings before trusting the assertion above.
	var scripts := _client_scripts()
	assert_gt(scripts.size(), 20, "the scan must reach the client's input scripts")
	assert_true("scripts/main.gd" in scripts, "main.gd is the biggest dispatch site")
	assert_true("scripts/world/local_player.gd" in scripts, "local_player polls movement keys")
	var main_tokens := _tokens_in_file("scripts/main.gd")
	assert_true(main_tokens.has("KEY_TAB"), "the scan reads main.gd's real hotkey literals")
	assert_false(main_tokens.has("KEY_NOT_A_KEY"), "the scan does not invent tokens")


func test_the_coverage_scan_ignores_comments() -> void:
	# ability_keybinds.gd's header discusses KEY_0 as the hypothetical tenth slot. A scan that read
	# comments would demand a row for a key nothing binds, and the honest fix would be to register
	# a lie. Comments are prose; only code binds keys.
	var tokens := _tokens_in_file("scripts/ui/ability_keybinds.gd")
	assert_true(tokens.has("KEY_1"), "FIRST_KEYCODE is code and must be seen")
	assert_false(tokens.has("KEY_0"), "KEY_0 appears only in prose about a future tenth slot")


# ---------------------------------------------------------------- 3. resolution


func test_event_code_prefers_the_physical_code() -> void:
	# The whole ticket in one assertion: an AZERTY player pressing the physical-W position sends
	# physical=KEY_W, keycode=KEY_Z. Dispatch must follow the POSITION or they cannot walk forward.
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_W
	ev.keycode = KEY_Z
	assert_eq(KeyRegistry.event_code(ev), KEY_W, "position wins over the printed letter")


func test_event_code_falls_back_when_no_physical_code_is_carried() -> void:
	# On-screen keyboards, IME and some synthesized events set only the logical code. Dispatching
	# nothing at all there would be a worse regression than dispatching by layout.
	var ev := InputEventKey.new()
	ev.keycode = KEY_L
	assert_eq(ev.physical_keycode, 0, "precondition: no physical code on the event")
	assert_eq(KeyRegistry.event_code(ev), KEY_L, "logical code is used when that is all there is")
	assert_eq(KeyRegistry.event_code(null), 0, "a null event dispatches nothing")


func test_qwerty_dispatch_is_byte_identical_to_the_old_logical_read() -> void:
	# The US regression guard. On a QWERTY board the driver sets physical == logical for every key
	# this game binds, so switching to physical_keycode changed NOTHING for the owner's playtesters
	# — this asserts that for the entire keymap rather than hoping it.
	for b: Dictionary in KeyRegistry.bindings():
		var key := int(b["key"])
		var ev := InputEventKey.new()
		ev.keycode = key  # QWERTY: the two fields agree
		ev.physical_keycode = key
		assert_eq(KeyRegistry.event_code(ev), key, "%s dispatches unchanged on QWERTY" % b["id"])


func test_labels_use_the_engine_name_on_the_headless_path() -> void:
	# Headless has no keyboard to describe, so label_for reports the POSITION's own name. This is
	# also the path every other test in the suite renders through, which is why the existing
	# OS.get_keycode_string assertions elsewhere still hold.
	assert_false(KeyRegistry.labels_are_layout_aware(), "the test suite runs headless")
	assert_eq(KeyRegistry.label_for(KEY_W), "W")
	assert_eq(KeyRegistry.label_for(KEY_T), OS.get_keycode_string(KEY_T))
	assert_eq(KeyRegistry.label_for_id("world_map"), "T")
	assert_eq(KeyRegistry.label_for_id("nonexistent_binding"), "")


func test_labels_follow_the_keyboard_on_the_layout_aware_path() -> void:
	# The other half of label_for: whatever the display server resolves a position to is what the
	# player is told. Exercised through the split-out seam because headless cannot resolve — feed
	# it what a French keyboard reports for the physical W and A positions.
	assert_eq(KeyRegistry.label_from_resolved(KEY_Z), "Z", "AZERTY reads Z where W sits")
	assert_eq(KeyRegistry.label_from_resolved(KEY_Q), "Q", "AZERTY reads Q where A sits")
	assert_eq(KeyRegistry.label_from_resolved(KEY_W), "W", "QWERTY is unchanged")


func test_friendly_labels_apply_after_resolution_not_before() -> void:
	# "`" and "/" are friendlier than "QuoteLeft" and "Slash", but the override must key off the
	# RESOLVED code. Applying it to the physical code would print "/" to a player whose keyboard
	# has ":" at that position — a US-centric label wearing a helpful disguise.
	assert_eq(KeyRegistry.label_from_resolved(KEY_QUOTELEFT), "`")
	assert_eq(KeyRegistry.label_from_resolved(KEY_SLASH), "/")
	assert_eq(KeyRegistry.label_from_resolved(KEY_COLON), OS.get_keycode_string(KEY_COLON))


# ---------------------------------------------------------------- helpers


# Relative paths of every shipped client script the coverage scan covers.
func _client_scripts() -> Array:
	var out: Array = []
	for dir in SCAN_DIRS:
		var da := DirAccess.open("res://" + dir)
		if da == null:
			continue
		for f in da.get_files():
			if str(f).ends_with(".gd"):
				out.append(dir + "/" + str(f))
	return out


# Every KEY_* token appearing in the CODE of a file (comments stripped), as a set.
func _tokens_in_file(rel: String) -> Dictionary:
	var out: Dictionary = {}
	var src := FileAccess.get_file_as_string("res://" + rel)
	var re := RegEx.create_from_string(KEY_TOKEN)
	for raw in src.split("\n"):
		var line := str(raw)
		var hash_at := line.find("#")
		if hash_at != -1:
			line = line.substr(0, hash_at)
		for m in re.search_all(line):
			out[m.get_string()] = true
	return out
