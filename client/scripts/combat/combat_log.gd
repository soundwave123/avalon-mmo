class_name CombatLog
# T-027: Append-style combat log with 200-line cap.
#
# Each entry is a string message with an associated color category.
# Oldest entries are dropped when the cap is reached.
#
# Testable headlessly (no UI dependency for log data):
#   get_lines() → Array[String]
#   get_count() → int
#   add_entry(msg, color) → emits added signal
#   signals: entry_added, entry_removed (for UI binding)

extends Control

signal entry_added(msg: String, color: Color)
signal entry_removed(msg: String)
# T-556: consecutive identical lines coalesce into one entry with a running "(xN)" count instead of
# spamming N copies (six "Out of range" lines flooded the log). The UI updates its last rendered
# line from this signal rather than appending a fresh one.
signal entry_updated(msg: String, color: Color)

const MAX_LINES: int = 200


class LogEntry:
	var msg: String = ""  # the rendered text (carries the "(xN)" suffix once coalesced)
	var base: String = ""  # the un-suffixed message, matched against the next line to coalesce
	var color: Color = Color.WHITE
	var count: int = 1


var _entries: Array[LogEntry] = []


func _ready() -> void:
	pass


func add_entry(msg: String, color: Color = Color.WHITE) -> void:
	# T-556: fold a repeat of the immediately-preceding line (same text AND colour) into a count on
	# that line — a single spammed error can't push real events off the log or read as a stutter.
	if not _entries.is_empty():
		var last: LogEntry = _entries[-1]
		if last.base == msg and last.color == color:
			last.count += 1
			last.msg = "%s (x%d)" % [last.base, last.count]
			entry_updated.emit(last.msg, last.color)
			return

	var entry := LogEntry.new()
	entry.msg = msg
	entry.base = msg
	entry.color = color
	_entries.append(entry)
	entry_added.emit(msg, color)

	# Enforce cap — remove oldest entries
	while _entries.size() > MAX_LINES:
		var removed: LogEntry = _entries.pop_front()
		entry_removed.emit(removed.msg)


func get_lines() -> Array[String]:
	var result: Array[String] = []
	for entry in _entries:
		result.append(entry.msg)
	return result


func get_count() -> int:
	return _entries.size()


func clear() -> void:
	_entries.clear()
