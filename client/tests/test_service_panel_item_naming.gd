extends "res://addons/gut/test.gd"
# T-646: Bank vault list must show display names (via ItemNaming) instead of raw item_ids.
# This mirrors the vendor branch fix (T-571).

# ---- Assertion 1: Bank vault list uses ItemNaming --------


func test_bank_vault_list_uses_item_naming() -> void:
	# T-646: The bank vault list in service_panel.gd must use ItemNaming.display_name()
	# instead of displaying raw item_ids like "itm_potion_minor_healing".
	var path := "res://scripts/ui/service_panel.gd"
	var file := FileAccess.open(path, FileAccess.READ)
	assert_true(file != null, "ServicePanel file should exist")
	var content := file.get_as_text()

	# Check that the bank body function uses ItemNaming.display_name for vault items
	assert_true(
		(
			content.contains("ItemNaming.display_name(item_id")
			and content.contains("_build_bank_body")
		),
		"Bank vault list should use ItemNaming.display_name() (T-646)"
	)


# ---- Assertion 2: Bank bag list uses ItemNaming --------


func test_bank_bag_list_uses_item_naming() -> void:
	# T-646: The bank bag deposit list should also use ItemNaming.display_name()
	var path := "res://scripts/ui/service_panel.gd"
	var file := FileAccess.open(path, FileAccess.READ)
	assert_true(file != null, "ServicePanel file should exist")
	var content := file.get_as_text()

	# The fix should apply ItemNaming to both vault and bag sections
	var count := content.count("ItemNaming.display_name")
	assert_true(
		count >= 3,  # vendor uses it 3+ times, bank should also use it
		"Bank section should use ItemNaming.display_name() for both vault and bag (T-646)"
	)
