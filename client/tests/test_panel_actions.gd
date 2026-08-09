extends GutTest

# T-056 pass 2: the panel-action → intent dispatch is pure, so it's unit-tested with a spy net.

const PanelActions = preload("res://scripts/ui/panel_actions.gd")


class SpyNet:
	extends RefCounted
	var calls: Array = []

	func turn_in(q):
		calls.append(["turn_in", q])

	func abandon(q):
		calls.append(["abandon", q])

	func equip(s):
		calls.append(["equip", s])

	func unequip(s):
		calls.append(["unequip", s])

	func drop(t, i, c):
		calls.append(["drop", t, i, c])

	func spend_talent(t):
		calls.append(["spend_talent", t])

	func set_class(c):
		calls.append(["set_class", c])

	func set_gender(g):
		calls.append(["set_gender", g])


func test_turn_in_and_abandon() -> void:
	var n = SpyNet.new()
	PanelActions.dispatch(n, "turn_in|q007")
	PanelActions.dispatch(n, "abandon|q003")
	assert_eq(n.calls[0], ["turn_in", "q007"])
	assert_eq(n.calls[1], ["abandon", "q003"])


func test_equip_and_unequip() -> void:
	var n = SpyNet.new()
	PanelActions.dispatch(n, "equip|5")  # bag slot int
	PanelActions.dispatch(n, "unequip|head")
	assert_eq(n.calls[0], ["equip", 5], "equip parses the bag slot to int")
	assert_eq(n.calls[1], ["unequip", "head"])


func test_drop_parses_ints() -> void:
	var n = SpyNet.new()
	PanelActions.dispatch(n, "drop|bag|3|2")
	assert_eq(n.calls[0], ["drop", "bag", 3, 2])


func test_unknown_or_malformed_is_ignored() -> void:
	var n = SpyNet.new()
	PanelActions.dispatch(n, "bogus|x")
	PanelActions.dispatch(n, "drop|bag")  # too few args
	PanelActions.dispatch(n, "")
	assert_eq(n.calls.size(), 0, "no intent fired for unknown/short metas")


func test_null_net_is_safe() -> void:
	PanelActions.dispatch(null, "turn_in|q1")  # must not crash
	assert_true(true)


# ---- T-065: talent + class-selection dispatch ----


func test_spend_talent_and_set_class() -> void:
	var n = SpyNet.new()
	PanelActions.dispatch(n, "spend_talent|tal_mag_imp_fireball")
	PanelActions.dispatch(n, "set_class|mage")
	assert_eq(n.calls[0], ["spend_talent", "tal_mag_imp_fireball"])
	assert_eq(n.calls[1], ["set_class", "mage"])


# T-520: gender-selection dispatch — the panel's action meta becomes a set_gender intent.
func test_set_gender_dispatch() -> void:
	var n = SpyNet.new()
	PanelActions.dispatch(n, "set_gender|female")
	PanelActions.dispatch(n, "set_gender|male")
	assert_eq(n.calls[0], ["set_gender", "female"])
	assert_eq(n.calls[1], ["set_gender", "male"])
