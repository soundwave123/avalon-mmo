extends GutTest

const MaintenanceBanner = preload("res://scripts/ui/maintenance_banner.gd")

var _banner: Control


func before_each() -> void:
	_banner = MaintenanceBanner.new()
	add_child_autofree(_banner)
	await get_tree().process_frame


func test_deboxed_amber_banner_renders_countdown_reason() -> void:
	(
		_banner
		. display(
			{
				"type": "maintenance",
				"remaining_seconds": 300,
				"reason": "database patch",
				"text": "Server maintenance begins 5m — database patch",
			}
		)
	)
	assert_true(_banner.visible)
	assert_true(_banner.is_active())
	assert_string_contains(_banner.banner_text(), "5m")
	assert_string_contains(_banner.banner_text(), "database patch")
	assert_eq(_banner.get_child_count(), 1, "de-boxed: the banner is text only")
	assert_true(_banner.get_child(0) is Label, "no PanelContainer/hint-toast chrome")
	assert_eq(
		(_banner.get_child(0) as Label).get_theme_color("font_color"),
		MaintenanceBanner.AMBER,
	)


func test_clear_hides_and_resets_maintenance_state() -> void:
	_banner.display({"remaining_seconds": 30, "reason": "restart", "text": "30s"})
	_banner.clear_notice()
	assert_false(_banner.visible)
	assert_false(_banner.is_active())
