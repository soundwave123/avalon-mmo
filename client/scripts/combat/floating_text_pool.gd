class_name FloatingTextPool
# T-027: Object pool for FloatingTextLabel nodes.
#
# Recycles labels instead of instantiating/freeing per hit.
# Call `spawn_text(entity_id, value, color)` to show a label above an entity.
# Labels auto-return to pool when animation finishes.
#
# Testable headlessly: get_spawned_count(), get_pool_size(), is_label_available().

extends Node

signal text_spawned(entity_id: int, value: String)

const DEFAULT_POOL_SIZE: int = 15

var enabled: bool = true  # T-057: off in the 3D client (these 2D labels have no world position)

var _pool: Array[FloatingTextLabel] = []
var _template: FloatingTextLabel = null
var _labels_by_entity: Dictionary = {}  # entity_id -> FloatingTextLabel
var _spawned_count: int = 0


func _ready() -> void:
	_preload_pool(DEFAULT_POOL_SIZE)


func _preload_pool(count: int) -> void:
	for i in range(count):
		var label: FloatingTextLabel = _create_label()
		_pool.append(label)


func _create_label() -> FloatingTextLabel:
	var label := FloatingTextLabel.new()
	label.name = "FloatingText_%d" % (_spawned_count + _pool.size())
	add_child(label)
	label.finished.connect(_on_label_finished.bind(label))
	return label


func spawn_text(entity_id: int, value: String, color: Color) -> void:
	"""Spawn (or reuse) a floating label for an entity."""
	if not enabled:
		return
	var label: FloatingTextLabel = _get_available_label()
	if label == null:
		label = _create_label()

	label.show_text(value, color)
	_labels_by_entity[entity_id] = label
	_spawned_count += 1
	text_spawned.emit(entity_id, value)


func _get_available_label() -> FloatingTextLabel:
	for label in _pool:
		if not label.is_animating():
			_pool.erase(label)
			return label
	return null


func _on_label_finished(label: FloatingTextLabel) -> void:
	_pool.append(label)
	# Remove from entity map if this was the tracked label
	for entity_id in _labels_by_entity:
		if _labels_by_entity[entity_id] == label:
			_labels_by_entity.erase(entity_id)
			break


func get_spawned_count() -> int:
	return _spawned_count


func get_pool_size() -> int:
	return _pool.size()


func get_active_count() -> int:
	return _labels_by_entity.size()


func is_label_available() -> bool:
	return _pool.size() > 0
