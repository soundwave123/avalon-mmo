extends GutTest
# T-759: the UI consistency pass. Proves the two grey windows now resolve the shared theme, the
# trade modal opts into the solid (not the 0.42-alpha glass) surface, the fixed-height panels clear
# the minimap/hotbar at the 1280x720 content base, the mail/bank bodies scroll instead of overflowing
# off-screen, and the achievement/level-up toasts have a real (non-degenerate) centered rect.

const ServicePanel = preload("res://scripts/ui/service_panel.gd")
const MailPanel = preload("res://scripts/ui/mail_panel.gd")
const TradePanel = preload("res://scripts/ui/trade_panel.gd")
const InventoryPanel = preload("res://scripts/ui/inventory_panel.gd")
const PvpPanel = preload("res://scripts/ui/pvp_panel.gd")
const RecipePanel = preload("res://scripts/ui/recipe_panel.gd")
const QuestLogPanel = preload("res://scripts/ui/quest_log_panel.gd")
const ObjectiveTracker = preload("res://scripts/ui/objective_tracker.gd")
const WardrobePanel = preload("res://scripts/ui/wardrobe_panel.gd")
const WeeklyPanel = preload("res://scripts/ui/weekly_panel.gd")
const CosmeticShopPanel = preload("res://scripts/ui/cosmetic_shop_panel.gd")
const AchievementUi = preload("res://scripts/ui/achievement_ui.gd")
const LevelUpUi = preload("res://scripts/ui/level_up_ui.gd")


# A harness root at the REAL 1280x720 content base (test_hud_safe_zone idiom) so a panel's
# anchors+offsets resolve to the same rect the shipped client lays out.
func _base_root() -> Control:
	UiViewport.normalize_headless(self)
	await get_tree().process_frame
	var root := Control.new()
	root.size = get_tree().root.get_visible_rect().size
	add_child_autofree(root)
	return root


func _mounted(root: Control, panel: Control) -> Control:
	root.add_child(panel)
	return panel


# ---- item 1/2: the shared theme + the two grey windows -----------------------


func test_build_is_the_shared_singleton() -> void:
	assert_same(UiTheme.build(), UiTheme.build(), "build() returns one cached Theme")


func test_service_panel_carries_the_shared_theme_so_solidwindow_resolves() -> void:
	var p := ServicePanel.new()
	add_child_autofree(p)
	assert_same(p.theme, UiTheme.build(), "service window carries the shared theme")
	assert_true(p.theme.has_stylebox("panel", "SolidWindow"), "the SolidWindow variation resolves")


func test_mail_panel_carries_the_shared_theme_so_solidwindow_resolves() -> void:
	var p := MailPanel.new()
	add_child_autofree(p)
	assert_same(p.theme, UiTheme.build(), "mail window carries the shared theme")
	assert_true(p.theme.has_stylebox("panel", "SolidWindow"), "the SolidWindow variation resolves")


func test_trade_modal_uses_the_solid_window_fill_not_the_glass() -> void:
	var p := TradePanel.new()
	add_child_autofree(p)
	var frame: PanelContainer = p.get_node("TradeFrame")
	assert_eq(
		frame.theme_type_variation, "SolidWindow", "irreversible trade opts into the solid frame"
	)
	var sb: StyleBoxFlat = frame.get_theme_stylebox("panel")
	# window_stylebox is 0.94 alpha; the idle-HUD glass it used to resolve was 0.42.
	assert_almost_eq(sb.bg_color.a, 0.94, 0.01, "the world no longer reads through the trade modal")


# ---- item 3: safe-zone routing off the minimap + hotbar ----------------------


func test_inventory_panel_clears_the_minimap_and_hotbar() -> void:
	var root := await _base_root()
	var p := _mounted(root, InventoryPanel.new())
	await get_tree().process_frame
	var r := p.get_global_rect()
	assert_false(
		HudSafeZone.intersects_minimap(r), "right-side inventory clears the always-on minimap"
	)
	assert_false(HudSafeZone.intersects_action_bar(r), "inventory clears the hotbar")


func test_pvp_panel_clears_the_minimap_and_hotbar() -> void:
	var root := await _base_root()
	var p := _mounted(root, PvpPanel.new())
	await get_tree().process_frame
	var r := p.get_global_rect()
	assert_false(HudSafeZone.intersects_minimap(r), "pvp panel clears the minimap")
	assert_false(HudSafeZone.intersects_action_bar(r), "pvp panel clears the hotbar")


func test_recipe_panel_clears_the_minimap_and_hotbar() -> void:
	var root := await _base_root()
	var p := _mounted(root, RecipePanel.new())
	await get_tree().process_frame
	var r := p.get_global_rect()
	assert_false(HudSafeZone.intersects_minimap(r), "recipe panel clears the minimap")
	assert_false(HudSafeZone.intersects_action_bar(r), "recipe panel clears the hotbar")


func test_quest_log_clears_the_hotbar() -> void:
	var root := await _base_root()
	var p := _mounted(root, QuestLogPanel.new())
	await get_tree().process_frame
	# Left-anchored: no minimap on that side, but its bottom was a raw -56 (into the hotbar) till now.
	assert_false(
		HudSafeZone.intersects_action_bar(p.get_global_rect()), "quest log clears the hotbar"
	)


func test_objective_tracker_top_clears_the_minimap() -> void:
	assert_eq(
		ObjectiveTracker._TOP, HudSafeZone.MINIMAP_SAFE_TOP, "tracker top reads the shared const"
	)
	# The tracker is a right-edge column; a representative rect at its top must clear the minimap.
	var column := Rect2(964.0, ObjectiveTracker._TOP, ObjectiveTracker._WIDTH, 200.0)
	assert_false(
		HudSafeZone.intersects_minimap(column), "the objective column no longer clips minimap"
	)


func test_centered_modals_clear_the_hotbar() -> void:
	var root := await _base_root()
	for scene in [WardrobePanel, WeeklyPanel, CosmeticShopPanel]:
		var p := _mounted(root, scene.new())
		await get_tree().process_frame
		assert_false(
			HudSafeZone.intersects_action_bar(p.get_global_rect()),
			"%s clears the hotbar" % p.get_class()
		)


func test_minimap_safe_top_actually_clears_the_reserved_minimap_rect() -> void:
	# intersects_minimap had zero callers while the collision shipped; pin the new constant against it.
	var right_panel := Rect2(900.0, HudSafeZone.MINIMAP_SAFE_TOP, 380.0, 400.0)
	assert_false(HudSafeZone.intersects_minimap(right_panel), "MINIMAP_SAFE_TOP clears the minimap")
	var too_high := Rect2(900.0, 56.0, 380.0, 400.0)  # the old raw offset_top
	assert_true(HudSafeZone.intersects_minimap(too_high), "and the old 56 top genuinely overlapped")


# ---- item 5: scroll containers cap the mail/bank bodies ----------------------


func test_service_body_scrolls_with_a_capped_height() -> void:
	var p := ServicePanel.new()
	add_child_autofree(p)
	var scroll := p._body.get_parent()
	assert_true(scroll is ScrollContainer, "the service body is wrapped in a scroll")
	assert_gt((scroll as ScrollContainer).custom_minimum_size.y, 0.0, "and its height is capped")


func test_mail_inbox_scrolls_with_a_capped_height() -> void:
	var p := MailPanel.new()
	add_child_autofree(p)
	var scroll := p._inbox_list.get_parent()
	assert_true(scroll is ScrollContainer, "the mail inbox is wrapped in a scroll")
	assert_gt((scroll as ScrollContainer).custom_minimum_size.y, 0.0, "and its height is capped")


# ---- item 6: non-degenerate centered toast rects -----------------------------


func _theme_src(root: Control) -> Control:
	var src := Control.new()
	src.theme = UiTheme.build()
	root.add_child(src)
	return src


func test_achievement_toast_has_a_real_centered_width() -> void:
	var hud := Control.new()
	add_child_autofree(hud)
	var _ui := AchievementUi.new(hud, _theme_src(hud), func(_m): pass)
	var toast: Label = hud.get_node("AchievementToast")
	assert_gt(toast.offset_right - toast.offset_left, 100.0, "not a degenerate 0-wide centered box")


func test_level_up_banner_and_subline_have_a_real_centered_width() -> void:
	var hud := Control.new()
	add_child_autofree(hud)
	var _ui := LevelUpUi.mount(hud, _theme_src(hud))
	var banner: Label = hud.get_node("LevelUpBanner")
	var subline: Label = hud.get_node("LevelUpSubline")
	assert_gt(banner.offset_right - banner.offset_left, 100.0, "banner has a real width")
	assert_gt(subline.offset_right - subline.offset_left, 100.0, "subline has a real width")
