extends "res://addons/gut/test.gd"
# T-640: PaperdollPreview — the character window's live 3D paperdoll. HEADLESS-SAFE: the GUT runner
# (and the T-075 pilot when it runs headless) has no display, so the whole SubViewport/3D subtree is
# skipped and this degrades to the T-422 framed placeholder rather than faking a render.

var _preview: PaperdollPreview = null


func before_each() -> void:
	_preview = PaperdollPreview.new()
	add_child(_preview)
	await get_tree().process_frame


func after_each() -> void:
	_preview.queue_free()


func test_headless_test_runner_uses_the_placeholder() -> void:
	assert_true(_preview.is_headless(), "the GUT runner has no display")
	assert_false(_preview.has_model(), "no SubViewport/3D model built without a display")
	assert_not_null(_preview.get_node_or_null("Hint"), "the T-422 framed placeholder text shows")
	assert_null(_preview.get_node_or_null("ViewportContainer"), "no SubViewport built headlessly")


func test_frame_carries_the_gold_bordered_stylebox() -> void:
	var sb := _preview.get_theme_stylebox("panel") as StyleBoxFlat
	assert_not_null(sb, "the framed-placeholder look (T-422) is preserved")
	assert_eq(sb.border_color, UiTheme.GOLD)


func test_update_preview_tracks_class_and_gear_even_headlessly() -> void:
	_preview.update_preview(
		{"char_class": "mage", "gear": {"head": "itm_mage_cowl"}, "username": "roy"}
	)
	assert_eq(_preview.get_model_class(), "mage")
	assert_eq(_preview.get_last_gear(), {"head": "itm_mage_cowl"})


func test_update_preview_keeps_the_last_value_when_a_key_is_missing() -> void:
	_preview.update_preview({"char_class": "priest", "gear": {}, "username": "roy"})
	_preview.update_preview({"gear": {"chest": "itm_vestment"}})
	assert_eq(_preview.get_model_class(), "priest", "class persists when a later push omits it")
	assert_eq(_preview.get_last_gear(), {"chest": "itm_vestment"})
