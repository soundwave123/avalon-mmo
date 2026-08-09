extends "res://addons/gut/test.gd"

# T-507: character-select screen — request shapes, row labels, the slot-cap gate on create,
# the two-step delete confirmation, and roster updates from gateway responses. The socket is
# a fresh (unconnected) WebSocketPeer: _send no-ops, so all flows are driven via
# _handle_message with gateway-shaped JSON — the same seam the live socket feeds.

const CharacterSelect = preload("res://scripts/ui/character_select.gd")
const GatewayLogin = preload("res://scripts/net/gateway_login.gd")

const TWO_CHARS := [
	{"id": 1, "name": "shrekwar", "slot": 0, "class": "warrior", "class_locked": true, "level": 9},
	{"id": 2, "name": "shrekmage", "slot": 1, "class": "mage", "class_locked": false, "level": 1},
]


func _mount(characters: Array) -> CharacterSelect:
	var screen: CharacterSelect = CharacterSelect.new()
	var host: Node = add_child_autofree(Node.new())
	screen.setup(WebSocketPeer.new(), characters, host)
	return screen


# ---- request/label builders ----


func test_request_shapes() -> void:
	assert_eq(CharacterSelect.select_request(7), {"type": "char_select", "character_id": 7})
	assert_eq(CharacterSelect.create_request("newalt"), {"type": "char_create", "name": "newalt"})
	assert_eq(CharacterSelect.delete_request(7), {"type": "char_delete", "character_id": 7})


func test_login_request_carries_manage_flag_only_when_set() -> void:
	assert_true(bool(GatewayLogin.login_request("shrek", "pw", "", true).get("manage", false)))
	assert_false(GatewayLogin.login_request("shrek", "pw").has("manage"), "default stays lean")


func test_row_label_shows_class_only_once_locked() -> void:
	assert_eq(CharacterSelect.row_label(TWO_CHARS[0]), "shrekwar — Warrior, level 9")
	assert_eq(CharacterSelect.row_label(TWO_CHARS[1]), "shrekmage — level 1 (class unchosen)")
	# Postgres TSV booleans arrive as "t"/"f" strings; "t" must read as locked.
	var tsv := {"id": 3, "name": "dbchar", "class": "rogue", "class_locked": "t", "level": 4}
	assert_eq(CharacterSelect.row_label(tsv), "dbchar — Rogue, level 4")


# ---- UI state ----


func test_lists_one_row_per_character() -> void:
	var screen := _mount(TWO_CHARS)
	assert_eq(screen.get_node("Frame/VBox/Rows").get_child_count(), 2, "one row per character")
	assert_false(
		(screen.get_node("Frame/VBox/CreateBox/Create") as Button).disabled,
		"create stays enabled below the slot cap"
	)


func test_create_disabled_at_slot_cap() -> void:
	var full := TWO_CHARS.duplicate()
	full.append({"id": 3, "name": "third", "slot": 2, "class": "rogue", "level": 2})
	var screen := _mount(full)
	assert_true(
		(screen.get_node("Frame/VBox/CreateBox/Create") as Button).disabled,
		"create must be disabled at 3/3 slots (server remains the enforcer)"
	)


func test_delete_requires_two_step_confirmation() -> void:
	var screen := _mount(TWO_CHARS)
	screen._on_delete_pressed(2)
	assert_eq(screen._pending_delete_id, 2, "first press only ARMS the delete")
	var delete_button := screen.get_node("Frame/VBox/Rows/Row2/Delete") as Button
	assert_eq(delete_button.text, "Confirm?", "the armed row relabels to confirm")
	assert_eq(
		(screen.get_node("Frame/VBox/Rows/Row1/Delete") as Button).text,
		"Delete",
		"other rows stay disarmed"
	)
	screen._on_select_pressed(1)
	assert_eq(screen._pending_delete_id, 0, "any other action disarms the pending delete")


func test_create_ok_appends_row_and_delete_ok_rebuilds() -> void:
	var screen := _mount(TWO_CHARS)
	(
		screen
		. _handle_message(
			(
				JSON
				. stringify(
					{
						"type": "char_create_ok",
						"character":
						{"id": 3, "name": "third", "slot": 2, "class": "warrior", "level": 1},
					}
				)
			)
		)
	)
	assert_eq(screen.get_node("Frame/VBox/Rows").get_child_count(), 3, "created row appears")
	screen._handle_message(JSON.stringify({"type": "char_delete_ok", "characters": [TWO_CHARS[0]]}))
	assert_eq(
		screen.get_node("Frame/VBox/Rows").get_child_count(), 1, "delete_ok rebuilds the roster"
	)


func test_select_ok_emits_chosen_with_token() -> void:
	var screen := _mount(TWO_CHARS)
	var seen: Array = []
	screen.chosen.connect(func(token: String) -> void: seen.append(token))
	screen._handle_message(JSON.stringify({"type": "char_select_ok", "access_token": "tok_abc123"}))
	assert_eq(seen, ["tok_abc123"], "the character-bound token reaches the login flow")


func test_select_err_reports_reason_without_emitting() -> void:
	var screen := _mount(TWO_CHARS)
	var seen: Array = []
	screen.chosen.connect(func(token: String) -> void: seen.append(token))
	screen._handle_message(JSON.stringify({"type": "char_select_err", "reason": "not_owned"}))
	assert_eq(seen.size(), 0, "a refused selection never authenticates")
	assert_string_contains(str((screen.get_node("Frame/VBox/Status") as Label).text), "not owned")
