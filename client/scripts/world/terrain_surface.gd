class_name TerrainSurface
extends RefCounted

# T-737: what am I standing ON? Returns the acoustic surface family at a world position so
# footfalls match the ground the player is looking at.
#
# The ticket asked for surface variation only "if the terrain splat data is cheap to query".
# It is — but NOT because the splat is readable. The ground is a single mesh whose grass/dirt/
# cobble blend is computed per-fragment on the GPU (client/shaders/terrain_splat.gdshader); there
# is no splatmap texture and no GPU readback. What makes this cheap is that every mask in that
# shader ALREADY has a committed pure-GDScript twin in WorldView — the "three-way splat sync"
# (shader / clutter scatter / world-audit) that T-202/T-313/T-314/T-347 maintain so the paint,
# the prop scatter and the audits all agree. This composes those same twins, so the sound you
# hear is derived from the identical masks that painted the pixel.
#
# Analytic, allocation-free, no texture reads and no raycasts — cheaper than a terrain height()
# call, so it is safe to evaluate on every footfall.
#
# KEEP IN SYNC with terrain_splat.gdshader (road_mask / hk_pave_mask / hk_plaza_mask /
# vp_path_mask / field_mask / paddock_mask / ashmoor_soot_mask) via WorldView's mirrors.

const GRASS := "grass"
const DIRT := "dirt"
const STONE := "stone"
const WOOD := "wood"

# The clip families FootstepCadence can name. Fail-closed: surface_at only ever returns one of
# these, so the audio side can never be handed a surface it has no samples for.
const SURFACES := [GRASS, DIRT, STONE, WOOD]

# road_mask(): half_w 2.6 plus a noise wobble of up to +-0.8 and a 2.2 m soft edge. We take the
# nominal half-width plus a little of that edge — the audio boundary wants to land where the
# ground LOOKS dirt, and the shader's wobble is not reproducible CPU-side (it samples a texture).
const ROAD_HALF_W := 3.4
# ...and the corridor's z extent: zfade ramps in over -141..-136 and out over 24..30, so the road
# only exists between them. Without this gate the flattened centreline (road_center_x returns 0
# outside its window) would paint the entire x~0 meridian as road.
const ROAD_Z_MIN := -138.5
const ROAD_Z_MAX := 27.0


# The acoustic surface at (x, z). `indoors` comes from InteriorGate.is_indoors() and wins
# outright: inside a building you are on boards, whatever is painted on the terrain beneath it.
static func surface_at(x: float, z: float, indoors: bool = false) -> String:
	if indoors:
		return WOOD
	# Hard paved ground first — a street painted over verge earth is still a street underfoot.
	if WorldView.hk_in_city(x, z) and WorldView.hk_street_dist(x, z) < 0.0:
		return STONE  # Highkeep cobbled avenues + the flagstone market plaza (hk_pave/hk_plaza)
	if WorldView.in_ashmoor_district(x, z):
		# The era-2 district is soot-packed ground with a cobble High Street through it. It is
		# industrial city floor, not rural earth: it reads HARD underfoot, so it takes stone.
		return STONE
	# Then the worn-earth family: the King's Road, the village spurs, and worked farmland.
	if z >= ROAD_Z_MIN and z <= ROAD_Z_MAX and absf(x - WorldView.road_center_x(z)) < ROAD_HALF_W:
		return DIRT
	if WorldView.vp_path_dist(x, z) < 0.0:
		return DIRT
	if WorldView.in_farmstead_rect(x, z):
		return DIRT
	return GRASS


# Convenience for the callers that already hold a position and an interior gate.
static func surface_at_pos(pos: Vector3, indoors: bool = false) -> String:
	return surface_at(pos.x, pos.z, indoors)
