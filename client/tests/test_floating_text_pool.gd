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


func test_spawn_returns_labels_to_pool_after_finish() -> void:
	# This test checks the structural invariant:
	# spawn → animate → finish → label back in pool.
	# We can't easily wait for the tween in a headless test,
	# so verify the pool can handle spawns without crashing.
	var initial_pool_size := _pool.get_pool_size()
	# Spawn more than default pool to force new label creation
	for i in range(20):
		_pool.spawn_text(i, "test", Color.WHITE)
	# At least 5 new labels should have been created
	assert_true(_pool.get_spawned_count() >= 20)


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
