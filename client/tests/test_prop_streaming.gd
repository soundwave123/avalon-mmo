extends "res://addons/gut/test.gd"

# T-594: the WorldPropsLayer streaming lifecycle — the leak/orphan + determinism guard the ticket
# asks for ("walk a border 10x, no leaks/orphans; identical resident set"). Drives a small injected
# manifest of real GLBs through repeated border crossings and asserts the resident set + child count
# return to an identical value every cycle (a leaked node would grow it), that a building stays
# stays resident while flora streams, and that another region's prop never instantiates.

const WorldPropsLayer = preload("res://scripts/world/world_props_layer.gd")
const PropStreamer = preload("res://scripts/world/prop_streamer.gd")

const HAYBALE := "res://assets/models/prop_haybale_v2.glb"  # flora tier (streams by distance)
const COTTAGE := "res://assets/models/prop_cottage_v2.glb"  # building tier (resident in-region)
const LAMPPOST := "res://assets/models/prop_lamppost_v2.glb"  # night-light special base


func _manifest() -> Array:
	# idx0 far Wold flora, idx1 near Wold flora, idx2 Wold building, idx3 Ashmoor flora (region 1).
	return [
		{"scene": HAYBALE, "x": 0.0, "y": 300.0, "solid": false},
		{"scene": HAYBALE, "x": 0.0, "y": 20.0, "solid": false},
		{"scene": COTTAGE, "x": 0.0, "y": 5.0, "rot_deg": 0},
		{"scene": HAYBALE, "x": -440.0, "y": 0.0, "solid": false},
	]


func _sorted(a: Array) -> Array:
	var out := a.duplicate()
	out.sort()
	return out


func _make_layer() -> WorldPropsLayer:
	var layer := WorldPropsLayer.new()
	# T-693: pin the INDIVIDUAL streaming path — this suite is the T-594 lifecycle guard for
	# individually placed props (critters/night-lights/special bases still stream this way);
	# the chunked-batching equivalents of these invariants live in test_prop_chunks.gd.
	layer._batching = false
	layer.load_manifest(_manifest())  # inject before entering the tree -> _ready skips props.json
	layer.set_stream_cfg({"flora_ring": 100.0, "building_ring": 900.0})
	add_child_autofree(layer)
	layer._streaming = false  # drive stream_to() by hand; no auto _process re-stream mid-assert
	return layer


func test_border_walk_is_leak_free_and_deterministic() -> void:
	var layer := _make_layer()
	var here := Vector2(0.0, 0.0)  # near flora (idx1) + building (idx2) resident; far flora out
	var there := Vector2(0.0, 250.0)  # far flora (idx0) + building (idx2) resident; near flora out

	layer.stream_to(here)
	await wait_process_frames(2)
	var baseline_here := _sorted(layer.placed_indices())
	var baseline_children := layer.get_child_count()
	assert_eq(baseline_here, [1, 2], "at the origin: near flora + building resident, far flora out")
	assert_false((layer.placed_indices() as Array).has(3), "the Ashmoor prop never instantiates")

	for _n in range(10):
		layer.stream_to(there)
		await wait_process_frames(2)
		assert_eq(_sorted(layer.placed_indices()), [0, 2], "far standpoint: far flora + building")
		layer.stream_to(here)
		await wait_process_frames(2)
		# The invariant: same resident set AND same child count every return — a leak would grow it.
		assert_eq(
			_sorted(layer.placed_indices()), baseline_here, "resident set identical on return"
		)
		assert_eq(layer.get_child_count(), baseline_children, "no orphan/leak: child count stable")


func test_building_stays_resident_while_flora_streams() -> void:
	var layer := _make_layer()
	layer.stream_to(Vector2(0.0, 0.0))
	await wait_process_frames(2)
	assert_true((layer.placed_indices() as Array).has(2), "building resident near it")
	# Walk the flora out of its ring; the building must remain (silhouette = navigation).
	layer.stream_to(Vector2(0.0, 250.0))
	await wait_process_frames(2)
	assert_true((layer.placed_indices() as Array).has(2), "building still resident across the walk")
	assert_false((layer.placed_indices() as Array).has(1), "the near flora streamed out")


# ---- T-692 Part B: preset density + live re-apply on the individual path ----------------------


func test_flora_density_thins_the_individual_carpet_deterministically() -> void:
	var manifest: Array = []
	for k in 12:
		manifest.append({"scene": HAYBALE, "x": float(k * 2), "y": 0.0, "solid": false})
	var layer := WorldPropsLayer.new()
	layer._batching = false  # pin the individual path (the batched twin lives in test_prop_chunks)
	layer.load_manifest(manifest)
	layer.set_stream_cfg({"flora_ring": 100.0, "building_ring": 900.0})
	add_child_autofree(layer)
	layer._streaming = false
	layer.apply_quality_cfg({"flora_ring": 100.0, "building_ring": 900.0, "flora_density": 0.5})
	await wait_process_frames(8)  # the budgeted repopulate drains LOAD_BUDGET_PER_FRAME per frame
	var want: Array = []
	for k in 12:
		if PropStreamer.density_kept(k, 0.5):
			want.append(k)
	var got: Array = layer.placed_indices()
	got.sort()
	assert_eq(got, want, "exactly the deterministic keep-subset places on the individual path")
	# Raising back to full density restores every placement — the re-apply is live and leak-free.
	layer.apply_quality_cfg({"flora_ring": 100.0, "building_ring": 900.0})
	await wait_process_frames(8)
	assert_eq((layer.placed_indices() as Array).size(), 12, "full density restores the carpet")


func test_density_never_drops_special_bases() -> void:
	var manifest: Array = [
		{"scene": HAYBALE, "x": 0.0, "y": 0.0, "solid": false},
		{"scene": HAYBALE, "x": 2.0, "y": 0.0, "solid": false},
		{"scene": LAMPPOST, "x": 4.0, "y": 0.0, "solid": false},
	]
	var layer := WorldPropsLayer.new()
	layer._batching = false
	layer.load_manifest(manifest)
	layer.set_stream_cfg({"flora_ring": 100.0, "building_ring": 900.0})
	add_child_autofree(layer)
	layer._streaming = false
	# Density 0 is the extreme lower bound (presets floor at 0.5): every plain flora placement
	# drops, but the night-light base — gameplay lighting, not carpet — must survive.
	layer.apply_quality_cfg({"flora_ring": 100.0, "building_ring": 900.0, "flora_density": 0.0})
	await wait_process_frames(4)
	assert_eq(layer.placed_indices(), [2], "only the special base survives density 0")


func test_region_change_tears_down_and_rebuilds() -> void:
	var layer := _make_layer()
	layer.stream_to(Vector2(0.0, 0.0))
	await wait_process_frames(2)
	assert_true(layer.get_child_count() > 0, "the Wold dressing is resident")
	# Cross into Ashmoor (region 1): the Wold set tears down whole, the Ashmoor prop (idx3) loads.
	layer.stream_to(Vector2(-440.0, 0.0))
	await wait_process_frames(2)
	var placed: Array = layer.placed_indices()
	assert_true(placed.has(3), "the Ashmoor prop is now resident")
	assert_false(placed.has(1), "no Wold prop survives the region swap")
	assert_false(placed.has(2), "the Wold building was torn down on the region change")
