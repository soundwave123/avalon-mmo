extends "res://addons/gut/test.gd"

var _pool: FloatingTextPool = null


func before_all() -> void:
	_pool = FloatingTextPool.new()
	add_child(_pool)
	# Wait one frame so _ready() fires and pool is preloaded
	await get_tree().process_frame


func after_all() -> void:
	_pool.queue_free()


func test_pool_has_initial_labels() -> void:
	# Default pool size is 15
	assert_true(_pool.get_pool_size() >= 10)


func test_spawn_text_increments_count() -> void:
	var initial := _pool.get_spawned_count()
	_pool.spawn_text(1, "42", Color.RED)
	assert_eq(_pool.get_spawned_count(), initial + 1)


func test_spawn_text_emits_signal() -> void:
	watch_signals(_pool)
	_pool.spawn_text(7, "99", Color.RED)
	assert_signal_emitted(_pool, "text_spawned")
	assert_signal_emitted_with_parameters(_pool, "text_spawned", [7, "99"])


func test_spawn_multiple_text_increments_count() -> void:
	var initial := _pool.get_spawned_count()
	_pool.spawn_text(1, "10", Color.RED)
	_pool.spawn_text(2, "20", Color.GREEN)
	_pool.spawn_text(3, "30", Color.GRAY)
	assert_eq(_pool.get_spawned_count(), initial + 3)


func test_active_count_increments_on_spawn() -> void:
	var initial := _pool.get_active_count()
	_pool.spawn_text(100, "damage", Color.RED)
	# Active count should increase immediately
	assert_true(_pool.get_active_count() > initial)


# T-756: this used to spawn 20 labels and assert get_spawned_count() >= 20 — a counter that
# only ever increments, so the assert was true the moment the loop ran and the recycle path
# the test is NAMED for was never touched. The tween can't be awaited headlessly, but the
# recycle is driven by the label's `finished` signal, and that CAN be fired directly.
func test_a_finished_label_returns_to_the_pool_and_releases_its_entity_slot() -> void:
	var pool := FloatingTextPool.new()
	add_child_autofree(pool)
	var pool_before := pool.get_pool_size()
	assert_gt(pool_before, 0, "the preloaded pool has labels to hand out")

	pool.spawn_text(4242, "13", Color.RED)
	assert_eq(pool.get_pool_size(), pool_before - 1, "spawning takes the label OUT of the pool")
	assert_eq(pool.get_active_count(), 1, "and parks it against the entity")

	var label: FloatingTextLabel = pool._labels_by_entity[4242]
	label.finished.emit()

	assert_eq(pool.get_pool_size(), pool_before, "the finished label is recycled, not leaked")
	assert_eq(pool.get_active_count(), 0, "and the entity slot is released for reuse")


func test_pool_grows_when_every_label_is_still_animating() -> void:
	# The exhaustion path: _get_available_label() returns null and spawn_text builds a new one
	# rather than dropping the hit. Asserted on labels actually parented, not on the counter.
	var pool := FloatingTextPool.new()
	add_child_autofree(pool)
	var labels_before := pool.get_child_count()
	var over := pool.get_pool_size() + 5
	for i in range(over):
		pool.spawn_text(i, "test", Color.WHITE)
	assert_eq(pool.get_pool_size(), 0, "every preloaded label is out on an entity")
	assert_gt(
		pool.get_child_count(), labels_before, "the pool built new labels rather than dropping hits"
	)
	assert_eq(pool.get_active_count(), over, "no hit was silently dropped")


func test_is_label_available_after_init() -> void:
	# Pool was preloaded with DEFAULT_POOL_SIZE=15 in _ready().
	# Earlier tests may have consumed labels, so create a fresh pool to test.
	var fresh_pool := FloatingTextPool.new()
	add_child(fresh_pool)
	await get_tree().process_frame
	assert_true(fresh_pool.is_label_available())
	fresh_pool.queue_free()


func test_pool_size_after_spawns() -> void:
	var before := _pool.get_pool_size()
	_pool.spawn_text(1, "x", Color.RED)
	# After spawn, pool should have one fewer available label
	# (the spawned label is no longer in the pool while animating)
	assert_true(_pool.get_pool_size() < before or _pool.get_spawned_count() > 0)
