extends GutTest

# T-308: the always-on vitals frame — HEALTH bar (every class) + class resource beneath it.

const VitalsFrame = preload("res://scripts/ui/vitals_frame.gd")


func _make() -> VitalsFrame:
	var v := VitalsFrame.new()
	add_child_autofree(v)  # runs _ready -> builds the bars
	return v


func test_health_always_shown_full() -> void:
	var v := _make()
	v.update_health(100, 100)
	assert_almost_eq(v.get_health_ratio(), 1.0, 0.001, "full HP -> full bar")
	assert_true(v.get_health_text().contains("100 / 100"))


func test_health_reflects_damage() -> void:
	var v := _make()
	v.update_health(30, 120)
	assert_almost_eq(v.get_health_ratio(), 0.25, 0.001, "30/120 -> quarter bar")
	assert_true(v.get_health_text().contains("30 / 120"))


func test_health_ratio_clamped() -> void:
	var v := _make()
	v.update_health(-5, 100)
	assert_almost_eq(v.get_health_ratio(), 0.0, 0.001, "negative HP clamps to empty")


func test_resource_hidden_for_none() -> void:
	var v := _make()
	v.update_resource("none", 0, 0)
	assert_false(v.is_resource_visible(), "classes with no resource hide the resource row")


func test_resource_shown_for_mana() -> void:
	var v := _make()
	v.update_resource("mana", 80, 150)
	assert_true(v.is_resource_visible())
	assert_true(v.get_resource_text().contains("80 / 150"))
	assert_true(v.get_resource_text().begins_with("Mana"))


# ---- T-460: idle HUD chrome — the vitals frame is not a box ---------------------------------


# The frame's legibility must live in the text/bars (outline + hairline troughs) over a subtle
# gradient — never in an opaque StyleBoxFlat fill or a thick border (T-396 rule 2/5).
func test_vitals_surface_has_no_opaque_box_or_thick_border() -> void:
	var v := _make()
	var panel := v.get_node("VitalsPanel") as PanelContainer
	var sb := panel.get_theme_stylebox("panel")
	assert_true(sb is StyleBoxEmpty, "the vitals panel surface carries no fill at all")
	for flat: StyleBoxFlat in _flat_styleboxes(v):
		var widest := maxi(
			maxi(flat.border_width_left, flat.border_width_right),
			maxi(flat.border_width_top, flat.border_width_bottom)
		)
		assert_lte(widest, 1, "no idle vitals surface carries a border thicker than 1px")
	# Troughs are translucent (a bar read, not a panel fill).
	var trough := v.get_node("VitalsPanel").find_child("HealthTrough", true, false) as Panel
	var trough_sb := trough.get_theme_stylebox("panel") as StyleBoxFlat
	assert_lt(trough_sb.bg_color.a, 0.6, "the trough is translucent, not an opaque block")


func test_vitals_backdrop_is_a_subtle_gradient() -> void:
	var v := _make()
	var backdrop := v.get_node("VitalsGradient") as TextureRect
	assert_not_null(backdrop, "the chat-idiom gradient sits behind the bars")
	assert_true(backdrop.texture is GradientTexture2D, "gradient, not a filled box")
	assert_lte(backdrop.modulate.a, 0.3, "reference model: at most a subtle ~25-30% veil")


# Every StyleBoxFlat override anywhere under the frame (troughs + fills).
func _flat_styleboxes(root: Node) -> Array:
	var out: Array = []
	if root is Control:
		var c := root as Control
		if c.has_theme_stylebox_override("panel"):
			var sb := c.get_theme_stylebox("panel")
			if sb is StyleBoxFlat:
				out.append(sb)
	for child in root.get_children():
		out.append_array(_flat_styleboxes(child))
	return out


# ---- T-697 fix 5: cached styleboxes + unchanged early-out ----------------------------------


func test_unchanged_health_update_reuses_the_same_cached_stylebox_instance() -> void:
	var v := _make()
	v.update_health(80, 100)
	var applied := v._hp_fill.get_theme_stylebox("panel")
	v.update_health(80, 100)  # identical 10 Hz broadcast — must not alloc/re-override
	assert_true(
		is_same(v._hp_fill.get_theme_stylebox("panel"), applied),
		"an unchanged broadcast keeps the exact cached StyleBoxFlat instance (no fresh alloc)"
	)
	v.update_health(75, 100)  # value moved but still healthy — same (not-low) cached style
	assert_true(
		is_same(v._hp_fill.get_theme_stylebox("panel"), applied),
		"a healthy-range hp change reuses the cached healthy stylebox"
	)


func test_low_health_flip_still_switches_to_the_low_stylebox() -> void:
	var v := _make()
	v.update_health(80, 100)
	var healthy := v._hp_fill.get_theme_stylebox("panel") as StyleBoxFlat
	v.update_health(20, 100)  # <= 30% — the low-hp warning color must still engage
	var low := v._hp_fill.get_theme_stylebox("panel") as StyleBoxFlat
	assert_false(is_same(low, healthy), "crossing the low threshold swaps the fill stylebox")
	assert_eq(low.bg_color, UiTheme.HEALTH_LOW, "low fill carries the warning color")
	v.update_health(90, 100)
	assert_true(
		is_same(v._hp_fill.get_theme_stylebox("panel"), healthy),
		"recovering re-applies the SAME cached healthy instance"
	)


func test_resource_kind_first_seen_hidden_still_gets_its_stylebox_when_shown() -> void:
	var v := _make()
	v.update_resource("mana", 5, 0)  # max 0 — row hidden, stylebox not yet applied
	assert_false(v.is_resource_visible())
	v.update_resource("mana", 5, 100)  # same kind, now visible — the mana fill must apply
	assert_true(v.is_resource_visible())
	var sb := v._res_fill.get_theme_stylebox("panel") as StyleBoxFlat
	assert_eq(sb.bg_color, UiTheme.MANA, "the visible row wears the mana fill color")
