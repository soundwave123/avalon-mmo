extends GutTest

# T-735: the flat ground-projected selection ring that replaced T-057's fixed vertical torus.
# Three things are worth pinning headless: (1) the radius really DERIVES from each unit's collision
# footprint (the whole point — a fixed size is what swallowed small mobs), (2) the color speaks the
# T-286 relationship palette, and (3) the ring node parents onto the target and is cleaned up on
# target change and on death/despawn (it must never be freed along with the body it rides).
# The ring node is read off `_target_ring` directly rather than through an accessor: the layer is
# already at gdlint's 20-public-method cap, and a test-only getter is not worth a lint suppression.

const RemoteEntitiesLayer = preload("res://scripts/world/remote_entities_layer.gd")
const TargetRing = preload("res://scripts/world/target_ring.gd")


func _layer():
	var l = RemoteEntitiesLayer.new()
	add_child_autofree(l)
	return l


# Two mobs of different physical size (T-332 render_scale drives both mesh and hitbox), plus a
# player, in one broadcast. hostile defaults true; mob 3 is explicitly neutral.
func _ingest_mixed(l, hostile_big: bool = true) -> void:
	(
		l
		. ingest(
			{
				"players": [{"peer_id": 1, "x": 0, "y": 0, "z": 0, "hp": 100, "max_hp": 100}],
				"mobs":
				[
					{"mob_id": 10, "x": 1, "y": 1, "z": 0, "render_scale": 0.8},
					{
						"mob_id": 20,
						"x": 2,
						"y": 2,
						"z": 0,
						"render_scale": 2.0,
						"hostile": hostile_big
					},
					{"mob_id": 30, "x": 3, "y": 3, "z": 0, "hostile": false},
				],
			},
			99,
			1000
		)
	)


# ---- radius derives from the collision footprint (never a fixed size) ----


func test_radius_derives_from_shape_kind_and_size() -> void:
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	assert_almost_eq(TargetRing.radius_for_shape(cap), 0.5, 0.001, "capsule: r * 1.25 margin")
	var box := BoxShape3D.new()
	box.size = Vector3(1.0, 1.6, 1.0)
	assert_almost_eq(
		TargetRing.radius_for_shape(box), 0.625, 0.001, "box: widest ground half-extent"
	)
	# A box's Y is HEIGHT, not footprint — a tall thin mob must not get a tall-wide ring.
	var tall := BoxShape3D.new()
	tall.size = Vector3(1.0, 6.0, 1.0)
	assert_almost_eq(
		TargetRing.radius_for_shape(tall), 0.625, 0.001, "height never widens the ring"
	)
	var sph := SphereShape3D.new()
	sph.radius = 2.0
	assert_almost_eq(TargetRing.radius_for_shape(sph), 2.5, 0.001, "sphere radius carries through")


func test_radius_is_clamped_at_both_ends() -> void:
	var tiny := SphereShape3D.new()
	tiny.radius = 0.01
	assert_almost_eq(
		TargetRing.radius_for_shape(tiny), TargetRing.MIN_RADIUS, 0.001, "critter floor"
	)
	var huge := SphereShape3D.new()
	huge.radius = 40.0
	assert_almost_eq(
		TargetRing.radius_for_shape(huge), TargetRing.MAX_RADIUS, 0.001, "boss ceiling"
	)


func test_small_and_large_entities_get_different_ring_radii() -> void:
	var l = _layer()
	_ingest_mixed(l)
	l.set_target(10)  # render_scale 0.8 mob -> 0.8 m box -> 0.4 half-extent -> 0.5 ring
	var small: float = l._target_ring.radius()
	l.set_target(20)  # render_scale 2.0 mob -> 2.0 m box -> 1.0 half-extent -> 1.25 ring
	var large: float = l._target_ring.radius()
	assert_almost_eq(small, 0.5, 0.001, "the small mob's ring hugs its own footprint")
	assert_almost_eq(large, 1.25, 0.001, "the large mob's ring scales with its footprint")
	assert_gt(large, small, "ring size tracks entity size (the T-735 fix)")
	l.set_target(1)  # remote player -> 0.4 capsule -> 0.5 ring
	assert_almost_eq(l._target_ring.radius(), 0.5, 0.001, "a player ring comes off its capsule")


func test_ring_geometry_is_flat_so_it_cannot_cross_the_silhouette() -> void:
	# The T-057 bug was a torus rotated upright into a vertical hoop through the model. Every
	# vertex of the replacement sits on the ground plane, so occlusion is geometrically impossible.
	var mesh := TargetRing.build_mesh(1.0)
	var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	assert_gt(verts.size(), 0, "the annulus has geometry")
	var max_abs_y := 0.0
	var max_r := 0.0
	for v: Vector3 in verts:
		max_abs_y = maxf(max_abs_y, absf(v.y))
		max_r = maxf(max_r, Vector2(v.x, v.z).length())
	assert_almost_eq(max_abs_y, 0.0, 0.0001, "every vertex lies flat on y = 0")
	assert_almost_eq(max_r, 1.0, 0.001, "the ring reaches exactly its requested radius")


func test_ring_sits_a_hair_above_the_ground_to_avoid_z_fighting() -> void:
	var l = _layer()
	_ingest_mixed(l)
	l.set_target(10)
	assert_almost_eq(
		l._target_ring.position.y, TargetRing.GROUND_EPSILON, 0.0001, "epsilon lift, not a float"
	)
	assert_gt(TargetRing.GROUND_EPSILON, 0.0, "the lift is real")
	assert_lt(TargetRing.GROUND_EPSILON, 0.1, "but small enough to still read as painted on")


# ---- color follows the T-286 relationship palette ----


func test_ring_color_follows_relationship() -> void:
	var l = _layer()
	_ingest_mixed(l)
	l.set_target(20)  # hostile mob
	assert_eq(_ring_color(l), Relationship.HOSTILE_PLATE, "hostile target rings red")
	l.set_target(30)  # T-665 non-hostile mob
	assert_eq(_ring_color(l), Relationship.NEUTRAL_PLATE, "neutral target rings yellow")
	l.set_target(1)  # another player, no pvp flags
	assert_eq(_ring_color(l), Relationship.FRIENDLY_PLATE, "friendly target rings green")


func test_ring_recolors_when_the_target_flips_hostility() -> void:
	var l = _layer()
	_ingest_mixed(l, true)
	l.set_target(20)
	assert_eq(_ring_color(l), Relationship.HOSTILE_PLATE, "starts hostile")
	_ingest_mixed(l, false)  # same mob, server flips its disposition
	assert_eq(_ring_color(l), Relationship.NEUTRAL_PLATE, "the live selection recolors on ingest")


func test_ring_glows_over_a_translucent_fill() -> void:
	var l = _layer()
	_ingest_mixed(l)
	l.set_target(20)
	var mat: StandardMaterial3D = l._target_ring.material_override
	assert_true(mat.emission_enabled, "subtle emissive glow (legible at night)")
	assert_eq(mat.emission, Relationship.HOSTILE_PLATE, "the glow is the relationship color")
	assert_lt(mat.albedo_color.a, 1.0, "fill is translucent — the ground reads through it")
	assert_eq(mat.transparency, BaseMaterial3D.TRANSPARENCY_ALPHA)


# ---- parenting + cleanup on target change and death ----


func test_ring_parents_onto_the_target_and_follows_target_changes() -> void:
	var l = _layer()
	_ingest_mixed(l)
	l.set_target(10)
	assert_eq(l._target_ring.get_parent(), l.target_node(10), "the ring rides the selected body")
	assert_true(l._target_ring.visible, "and is shown")
	l.set_target(20)
	assert_eq(l._target_ring.get_parent(), l.target_node(20), "it moves to the new target")
	assert_eq(
		l.target_node(10).get_children().filter(func(c): return c is TargetRing).size(),
		0,
		"and leaves nothing behind on the old one"
	)


func test_deselecting_parks_and_hides_the_ring() -> void:
	var l = _layer()
	_ingest_mixed(l)
	l.set_target(10)
	l.set_target(-1)
	assert_eq(l._target_ring.get_parent(), l, "the ring parks back on the layer")
	assert_false(l._target_ring.visible, "and is hidden with no selection")


func test_target_death_detaches_the_ring_instead_of_freeing_it() -> void:
	var l = _layer()
	_ingest_mixed(l)
	l.set_target(20)
	var ring = l._target_ring
	# the big mob dies: the next broadcast simply omits it, and its body is queue_free'd
	(
		l
		. ingest(
			{
				"players": [{"peer_id": 1, "x": 0, "y": 0, "z": 0, "hp": 100, "max_hp": 100}],
				"mobs": [{"mob_id": 10, "x": 1, "y": 1, "z": 0, "render_scale": 0.8}],
			},
			99,
			1100
		)
	)
	assert_true(is_instance_valid(ring), "the ring is NOT freed along with the dead body")
	assert_eq(ring.get_parent(), l, "it is re-parented back onto the layer")
	assert_false(ring.visible, "and hidden — no ring floating where the corpse was")
	assert_false(l.has_target(20), "the dead target is gone")


# T-751: the failure the ==null guard could not survive. The ring rides the target body, so ANY
# path that frees that body without detaching first takes the ring down with it — and the freed
# reference left in `_target_ring` is NOT null, so the old `if _target_ring == null: return` guard
# read false, fell through, and dereferenced a corpse at the 10 Hz broadcast rate for the rest of
# the session (one missed detach = a permanently dead ring). is_instance_valid() sees the corpse,
# and because the ring is cheap stateless geometry, seeing it means rebuilding it.
func test_a_missed_detach_self_heals_instead_of_killing_the_ring_for_the_session() -> void:
	var l = _layer()
	_ingest_mixed(l)
	l.set_target(20)
	var body = l.target_node(20)
	assert_eq(l._target_ring.get_parent(), body, "precondition: the ring is riding the body")
	# Simulate the missed detach: the entity is dropped and its body freed with the ring aboard.
	l._entities.erase("mob_20")
	body.free()
	assert_false(is_instance_valid(l._target_ring), "precondition: the ring really was freed")
	# The next selection must recover rather than error. Pre-fix this deref killed the ring path.
	l.set_target(10)
	assert_true(is_instance_valid(l._target_ring), "the layer rebuilt the ring instead of dying")
	assert_eq(l._target_ring.get_parent(), l.target_node(10), "and it rides the new target")
	assert_true(l._target_ring.visible, "a self-healed ring is a VISIBLE ring")
	assert_almost_eq(l._target_ring.radius(), 0.5, 0.001, "fully re-fitted, not a bare stub")


# T-751: the same recovery through the OTHER guard — deselecting after a missed detach parks a
# rebuilt ring on the layer instead of walking a freed reference.
func test_deselect_after_a_missed_detach_parks_a_rebuilt_ring() -> void:
	var l = _layer()
	_ingest_mixed(l)
	l.set_target(20)
	var stale = l._target_ring.get_parent()
	l._entities.erase("mob_20")
	stale.free()
	assert_false(is_instance_valid(l._target_ring), "precondition: freed with its parent")
	l.set_target(-1)
	assert_true(is_instance_valid(l._target_ring), "a fresh ring exists")
	assert_eq(l._target_ring.get_parent(), l, "parked back on the layer")
	assert_false(l._target_ring.visible, "and hidden — nothing is selected")


func _ring_color(l) -> Color:
	return (l._target_ring.material_override as StandardMaterial3D).emission
