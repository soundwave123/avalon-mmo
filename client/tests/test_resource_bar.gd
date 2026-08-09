extends GutTest

# T-062: local-player class-resource HUD bar. Instantiated into the tree so _ready builds the bar.

const ResourceBar = preload("res://scripts/combat/resource_bar.gd")


func _make() -> ResourceBar:
	var bar := ResourceBar.new()
	add_child_autofree(bar)  # runs _ready → builds the ProgressBar + Label
	return bar


func test_hidden_for_none_resource() -> void:
	var bar := _make()
	bar.update_resource("none", 0, 0)
	assert_false(bar.visible, "no class resource -> bar hidden")


func test_rage_shows_value_and_max() -> void:
	var bar := _make()
	bar.update_resource("rage", 45, 100)
	assert_true(bar.visible, "rage -> bar shown")
	assert_eq(bar.get_value(), 45)
	assert_eq(bar.get_max(), 100)


func test_mana_shows_value_and_max() -> void:
	var bar := _make()
	bar.update_resource("mana", 30, 50)
	assert_true(bar.visible)
	assert_eq(bar.get_value(), 30)
	assert_eq(bar.get_max(), 50)


func test_value_clamped_to_max() -> void:
	var bar := _make()
	bar.update_resource("rage", 150, 100)
	assert_eq(bar.get_value(), 100, "current clamped to max")
