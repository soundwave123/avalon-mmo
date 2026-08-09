extends GutTest

# T-055: the snapshot-interpolation math — pure, so it's unit-tested without nodes/network.

const SnapshotBuffer = preload("res://scripts/world/snapshot_buffer.gd")


func test_lerps_between_bracketing_snapshots() -> void:
	var b = SnapshotBuffer.new()
	b.push(Vector3(0, 0, 0), 1000)
	b.push(Vector3(10, 0, 0), 1100)
	# Halfway in time → halfway in space.
	assert_eq(b.sample(1050), Vector3(5, 0, 0), "interpolates between the two snapshots")


func test_clamps_before_first_and_after_last() -> void:
	var b = SnapshotBuffer.new()
	b.push(Vector3(0, 0, 0), 1000)
	b.push(Vector3(10, 0, 0), 1100)
	assert_eq(b.sample(900), Vector3(0, 0, 0), "before first → hold first")
	assert_eq(
		b.sample(2000), Vector3(10, 0, 0), "after last (stalled stream) → hold last, not origin"
	)


func test_single_snapshot_returns_it() -> void:
	var b = SnapshotBuffer.new()
	b.push(Vector3(3, 0, 4), 500)
	assert_eq(b.sample(9999), Vector3(3, 0, 4))


func test_empty_is_origin() -> void:
	assert_eq(SnapshotBuffer.new().sample(1000), Vector3.ZERO)


func test_buffer_is_bounded() -> void:
	var b = SnapshotBuffer.new()
	for i in range(40):
		b.push(Vector3(i, 0, 0), 1000 + i)
	assert_true(b.size() <= SnapshotBuffer.MAX_SNAPSHOTS, "old snapshots are pruned")
	assert_eq(b.sample(99999), Vector3(39, 0, 0), "latest still present")
