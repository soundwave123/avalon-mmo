# T-120: distance-LOD + impostor policy — the single source of truth for how far each prop class
# draws and where its real mesh gives way to a billboard impostor. Pure module (RefCounted, static
# funcs, no OS time, no globals, inputs never mutated) mirroring npc_wander.gd / critter_wander.gd
# so the thresholds + hysteresis are unit-tested in isolation. world_props_layer.gd is the only
# caller; it applies cull_distance() to the engine `visibility_range_end` and drives the mesh<->
# impostor swap from impostor_active().
#
# Godot 4 auto-generates opaque mesh LODs at import (meshes/generate_lods=true, verified headless);
# that shrinks TRIS but does nothing for alpha-card foliage overdraw or draw-call count. This module
# is the committable layer on top: cull the small stuff early, swap big trees to a flat billboard
# past ~90 m so a dense forest stops paying full canopy overdraw at range.

extends RefCounted

# Cull distance (m) by prop-class prefix -> engine visibility_range_end. 0.0 = never cull.
# Buildings/walls are absent on purpose: their silhouette is navigation, so they always draw.
# Ordered longest-lived first; matched by String.begins_with (first hit wins in cull_distance).
const _CULL := [
	["prop_sapling", 240.0],  # young trees read as shape well past the fern range
	["prop_rock", 220.0],
	["prop_boulder", 220.0],
	["prop_stump", 220.0],
	["furn_", 160.0],  # interior furniture — no point drawing a stool across the valley
	["prop_bush", 160.0],
]

# Impostor swap distance (m) + hysteresis band (m) by prop-class prefix. Beyond `dist` the real
# mesh is hidden and a flat billboard drawn; the mesh only returns once inside `dist - hyst` (and
# the impostor only appears past `dist + hyst`), so a camera hovering on the boundary can't flicker.
# Trees only for now — they own the canopy overdraw. 0 elsewhere (no impostor).
const _IMPOSTOR_DIST := 90.0
const _IMPOSTOR_HYST := 12.0
const _IMPOSTOR_PREFIXES := [
	"prop_oak",
	"prop_tree",
	"prop_fir",
	"prop_pine",
]
# Full-tree cull is generous so the impostor (cheap) carries the mid-far band before it winks out.
const _TREE_CULL := 320.0

# T-758: cull distance (m) for the boot-time WorldView ground clutter (grass tufts, scatter rocks,
# meadow flowers). These 8 MultiMeshes (~13.7k instances) shipped with NO visibility_range at all,
# so the whole meadow drew even when the camera was in another zone. Each value sits comfortably
# beyond its scatter radius so the near field never clips, but the field culls once you are well
# outside it. Small ground detail, so shorter than the prop-mesh table above.
const _CLUTTER_CULL := {
	"grass": 150.0,  # tufts read only close; the tallest grass disc has radius ~120
	"rock": 200.0,  # scatter pebbles, disc radius ~130
	"flower": 160.0,  # sparse colour pops, disc radius ~110
}


# Engine visibility_range_end for this prop's file basename (e.g. "prop_oak_real.glb"). 0.0 means
# "never cull" — the caller leaves visibility_range_end at its default (0 = unlimited).
# T-692 Part B: `mult` scales every distance for the quality presets (Low 0.55 … Ultra 1.25);
# 1.0 = the authored baseline. A never-cull class stays 0.0 at every tier.
static func cull_distance(base: String, mult: float = 1.0) -> float:
	if _is_impostor_class(base):
		return _TREE_CULL * mult
	for entry in _CULL:
		if base.begins_with(entry[0]):
			return float(entry[1]) * mult
	return 0.0


# T-758: engine visibility_range_end for a boot-time ground-clutter class ("grass"/"rock"/"flower").
# 0.0 for an unknown class -> the caller leaves the MultiMesh uncapped (the pre-T-758 behaviour).
static func clutter_cull_distance(clutter_class: String, mult: float = 1.0) -> float:
	return float(_CLUTTER_CULL.get(clutter_class, 0.0)) * mult


# Distance (m) at which this prop swaps to a billboard impostor. 0.0 = this class never impostors.
# `mult` = the same preset multiplier as cull_distance, so the swap tracks the cull per tier.
static func impostor_distance(base: String, mult: float = 1.0) -> float:
	return _IMPOSTOR_DIST * mult if _is_impostor_class(base) else 0.0


# Hysteresis half-band (m) around the impostor distance.
static func impostor_hysteresis() -> float:
	return _IMPOSTOR_HYST


# Does this prop class ever draw as an impostor? (Trees only, currently.)
static func _is_impostor_class(base: String) -> bool:
	for pfx in _IMPOSTOR_PREFIXES:
		if base.begins_with(pfx):
			return true
	return false


# Pure hysteresis swap decision: should the impostor (not the real mesh) be shown, given the
# camera distance, the class swap distance, the hysteresis half-band, and whether the impostor is
# ALREADY showing? Inside `imp_dist - hyst` -> always mesh (false). Beyond `imp_dist + hyst` ->
# always impostor (true). Between the two the previous state holds (no flicker). imp_dist <= 0
# means the class has no impostor -> always false.
static func impostor_active(dist: float, imp_dist: float, hyst: float, was_active: bool) -> bool:
	if imp_dist <= 0.0:
		return false
	if dist >= imp_dist + hyst:
		return true
	if dist <= imp_dist - hyst:
		return false
	return was_active


# Impostor billboard TEXTURE path for a real prop scene path, or "" if that class has no impostor.
# Convention: .../prop_oak_real.glb -> .../prop_oak_real_impostor.png (baked by
# tools/assetgen/bake_impostor.py). A texture — not a GLB — because the runtime draws it
# on a code-built Y-billboard quad (StandardMaterial3D billboard mode), the right primitive for a
# distant cardboard tree. The caller checks existence and no-ops (range-cull only) when absent.
static func impostor_texture_path(scene_path: String) -> String:
	var base := scene_path.get_file()
	if not _is_impostor_class(base) or not base.ends_with(".glb"):
		return ""
	var stem := scene_path.substr(0, scene_path.length() - 4)  # drop ".glb"
	return stem + "_impostor.png"
