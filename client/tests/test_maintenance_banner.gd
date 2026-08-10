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


# T-751: the chat panel hosts its maintenance banner on the PARENT CanvasLayer when it has one, so
# _exit_tree() must free it — and used to walk away leaving the field addressing the corpse-to-be.
# queue_free() is DEFERRED: for the rest of that frame `_maintenance_banner != null` is still true
# and is_instance_valid() is still true, so setup()'s "already built?" test skipped the rebuild and
# a re-mounted panel spent its life poking a detached node. The fix is to release the handle at the
# free site, which is the only thing that works — neither null nor validity can see a doomed node.
func test_a_remounted_chat_panel_rebuilds_its_banner_instead_of_reusing_a_doomed_one() -> void:
	var host := CanvasLayer.new()
	add_child_autofree(host)
	var panel := ChatPanel.new()
	host.add_child(panel)
	panel.setup(func(_intent): pass)
	var first = panel._maintenance_banner
	assert_not_null(first, "precondition: the banner mounted onto the host CanvasLayer")
	assert_ne(
		first.get_parent(), panel, "precondition: hosted by the parent, so _exit_tree frees it"
	)
	host.remove_child(panel)  # fires _exit_tree in the same frame — nothing has actually died yet
	assert_null(panel._maintenance_banner, "the handle was released at the free site")
	host.add_child(panel)
	panel.setup(func(_intent): pass)
	assert_not_null(panel._maintenance_banner, "the re-mounted panel built a FRESH banner")
	assert_ne(panel._maintenance_banner, first, "not the doomed one")
	panel.queue_free()
