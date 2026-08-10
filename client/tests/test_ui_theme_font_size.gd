extends "res://addons/gut/test.gd"
# T-747: the theme font-size hook. Two things are worth asserting and they pull in opposite
# directions — that turning the hook on changed nothing visible today, and that it is nevertheless
# a real hook rather than decoration.


func _themed(node: Control, theme: Theme) -> Control:
	var host := Control.new()
	host.theme = theme
	host.add_child(node)
	add_child_autofree(host)
	return node


func test_the_hook_is_a_no_op_at_the_shipped_size() -> void:
	# BODY_FONT_SIZE is Godot's own default, so every styled type must resolve to exactly what it
	# resolved to before the theme carried any font size at all. If this fails, shipping T-747
	# silently resized text across all 91 UI files.
	var theme := UiTheme.build()
	var bare_label := Label.new()
	add_child_autofree(bare_label)
	var themed_label := _themed(Label.new(), theme) as Label
	var themed_rich := _themed(RichTextLabel.new(), theme) as RichTextLabel
	var themed_bar := _themed(ProgressBar.new(), theme) as ProgressBar
	var themed_button := _themed(Button.new(), theme) as Button
	await get_tree().process_frame

	var engine_default := bare_label.get_theme_font_size("font_size")
	assert_eq(UiTheme.BODY_FONT_SIZE, engine_default, "the hook's value IS the engine default")
	assert_eq(themed_label.get_theme_font_size("font_size"), engine_default)
	assert_eq(themed_bar.get_theme_font_size("font_size"), engine_default)
	assert_eq(themed_rich.get_theme_font_size("normal_font_size"), engine_default)
	# Button is not styled by build(), so it proves default_font_size covers the unnamed types too.
	assert_eq(themed_button.get_theme_font_size("font_size"), engine_default)


func test_one_call_scales_every_styled_type_including_rich_text_runs() -> void:
	# The hook has to actually reach things. RichTextLabel is the trap: five separate font-size
	# items, so a partial implementation leaves bold/italic/mono chat runs at the old size.
	# T-759: mutate a throwaway theme, NOT UiTheme.build() (now a process-wide singleton) — leaving
	# it scaled to 24 would silently resize every other test file's panels that share the instance.
	var theme := Theme.new()
	UiTheme.apply_font_sizes(theme, 24)
	var label := _themed(Label.new(), theme) as Label
	var rich := _themed(RichTextLabel.new(), theme) as RichTextLabel
	var bar := _themed(ProgressBar.new(), theme) as ProgressBar
	var button := _themed(Button.new(), theme) as Button
	await get_tree().process_frame

	assert_eq(label.get_theme_font_size("font_size"), 24)
	assert_eq(bar.get_theme_font_size("font_size"), 24)
	assert_eq(button.get_theme_font_size("font_size"), 24, "unnamed types follow default_font_size")
	for item in UiTheme.RICH_TEXT_FONT_SIZE_ITEMS:
		assert_eq(rich.get_theme_font_size(item), 24, "rich-text run '%s' scaled too" % item)


func test_per_node_overrides_still_win_so_nothing_regressed() -> void:
	# The 28 surviving add_theme_font_size_override() literals are deliberately NOT swept by this
	# ticket. This pins the reason it is safe to leave them: a per-node override beats the theme
	# unconditionally, so the hook cannot have moved any of them.
	var theme := Theme.new()  # T-759: throwaway, not the shared singleton (see the note above)
	UiTheme.apply_font_sizes(theme, 24)
	var label := _themed(Label.new(), theme) as Label
	label.add_theme_font_size_override("font_size", 40)
	await get_tree().process_frame
	assert_eq(label.get_theme_font_size("font_size"), 40, "the per-node literal still wins")


# T-759: build() is now a cache — every call returns the SAME resource, so the ~25 HUD surfaces that
# assign it share one Theme instead of minting 25 identical copies (+ their StyleBoxes).
func test_build_returns_the_same_cached_singleton() -> void:
	assert_same(UiTheme.build(), UiTheme.build(), "build() hands back one shared Theme, not a copy")
	# And that shared instance is at the shipped body size — proof no earlier test poisoned it.
	var label := _themed(Label.new(), UiTheme.build()) as Label
	await get_tree().process_frame
	assert_eq(label.get_theme_font_size("font_size"), UiTheme.BODY_FONT_SIZE, "singleton unmutated")
