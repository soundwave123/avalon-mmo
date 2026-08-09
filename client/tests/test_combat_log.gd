extends "res://addons/gut/test.gd"
# T-027: Tests for CombatLog (headless, no UI dependency).


func _make_log() -> CombatLog:
	# Create headlessly — no add_child, just use as data container
	var log := CombatLog.new()
	return log


func test_starts_empty() -> void:
	var log := _make_log()
	assert_eq(log.get_count(), 0)
	assert_eq(log.get_lines().size(), 0)


func test_add_entry_increases_count() -> void:
	var log := _make_log()
	log.add_entry("Player hits Goblin for 10.", Color.RED)
	assert_eq(log.get_count(), 1)


func test_add_entry_adds_line() -> void:
	var log := _make_log()
	log.add_entry("test message", Color.WHITE)
	var lines := log.get_lines()
	assert_eq(lines.size(), 1)
	assert_eq(lines[0], "test message")


func test_add_multiple_entries() -> void:
	var log := _make_log()
	log.add_entry("msg 1", Color.RED)
	log.add_entry("msg 2", Color.GREEN)
	log.add_entry("msg 3", Color.GRAY)
	assert_eq(log.get_count(), 3)
	var lines := log.get_lines()
	assert_eq(lines[0], "msg 1")
	assert_eq(lines[1], "msg 2")
	assert_eq(lines[2], "msg 3")


func test_clear_resets_log() -> void:
	var log := _make_log()
	log.add_entry("msg 1", Color.RED)
	log.add_entry("msg 2", Color.GREEN)
	log.clear()
	assert_eq(log.get_count(), 0)
	assert_eq(log.get_lines().size(), 0)


func test_cap_at_max_lines() -> void:
	var log := _make_log()
	# Add more than MAX_LINES (200)
	for i in range(250):
		log.add_entry("entry %d" % i, Color.WHITE)
	assert_eq(log.get_count(), 200)


func test_oldest_entries_removed_first() -> void:
	var log := _make_log()
	for i in range(250):
		log.add_entry("entry %d" % i, Color.WHITE)

	var lines := log.get_lines()
	# First entry should be "entry 50" (entries 0-49 removed)
	assert_eq(lines[0], "entry 50")
	# Last entry should be "entry 249"
	assert_eq(lines[249 - 50], "entry 249")


func test_entry_added_signal() -> void:
	var log := _make_log()
	watch_signals(log)
	log.add_entry("signal test", Color.RED)
	assert_signal_emitted(log, "entry_added")
	assert_signal_emitted_with_parameters(log, "entry_added", ["signal test", Color.RED])


func test_entry_removed_signal_on_cap() -> void:
	var log := _make_log()
	watch_signals(log)
	# Add enough to trigger removal
	for i in range(201):
		log.add_entry("entry %d" % i, Color.WHITE)
	# At least one removal should have happened
	assert_signal_emitted(log, "entry_removed")


# T-556: consecutive identical lines coalesce into one entry with a running "(xN)" count instead of
# flooding the log (six identical "Out of range" lines pushed real events off-screen).
func test_consecutive_identical_lines_coalesce_with_a_count() -> void:
	var log := _make_log()
	var msg := "Out of range — target 38.3m away, ability reaches 2.5m."
	for _i in range(6):
		log.add_entry(msg, Color.RED)
	assert_eq(log.get_count(), 1, "six identical lines collapse to one entry")
	assert_eq(log.get_lines()[0], "%s (x6)" % msg, "the single line carries the repeat count")


# T-556: only IMMEDIATE repeats coalesce — a different line between repeats breaks the run so real
# interleaved events are never swallowed.
func test_non_consecutive_repeats_do_not_coalesce() -> void:
	var log := _make_log()
	log.add_entry("Out of range.", Color.RED)
	log.add_entry("You hit the wolf for 7.", Color.WHITE)
	log.add_entry("Out of range.", Color.RED)
	assert_eq(log.get_count(), 3, "a line between two identical lines keeps all three")


# T-556: a repeat with a DIFFERENT colour is a distinct event (e.g. a friendly vs hostile line),
# so it appends rather than folding into the previous count.
func test_same_text_different_color_does_not_coalesce() -> void:
	var log := _make_log()
	log.add_entry("Blocked.", Color.RED)
	log.add_entry("Blocked.", Color.GREEN)
	assert_eq(log.get_count(), 2, "same text but different colour stays two entries")


# T-556: the coalesced count updates the newest line rather than adding one — surfaced via a signal
# so the panel rewrites the last rendered line in place.
func test_coalesce_emits_entry_updated_signal() -> void:
	var log := _make_log()
	watch_signals(log)
	log.add_entry("Out of range.", Color.RED)
	log.add_entry("Out of range.", Color.RED)
	assert_signal_emitted(log, "entry_updated")


func test_different_colors_preserved() -> void:
	var log := _make_log()
	var red_color := Color(1.0, 0.2, 0.2)
	var green_color := Color(0.2, 1.0, 0.2)
	var grey_color := Color(0.5, 0.5, 0.5)

	log.add_entry("damage", red_color)
	log.add_entry("heal", green_color)
	log.add_entry("miss", grey_color)

	assert_eq(log.get_count(), 3)
	var lines := log.get_lines()
	assert_eq(lines[0], "damage")
	assert_eq(lines[1], "heal")
	assert_eq(lines[2], "miss")
