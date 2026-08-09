extends "res://addons/gut/test.gd"
# T-515: fresh players must never spawn inside the aggro range of a dangerous mob (playtest bug:
# "I spawn next to level 12-14 mobs and they kill me instantly"). This data-integrity test loads the
# SHIPPED spawn hubs + mob spawns and asserts every hub keeps a safe clearance from every mob above
# SAFE_MOB_LEVEL, so re-authoring a hub (or moving a mob) next to a high-level pack fails CI.

const SAFE_MOB_LEVEL := 3  # L1-3 starter mobs are fair game near spawn; L4+ must be kept clear
# AGGRO_MAX (T-402) is 20 m and the spawn jitter disc is 6 m, so 26 m is the true danger radius.
# 30 m gives a margin and is the documented invariant in spawn_points.json.
const SAFE_CLEARANCE_M := 30.0

# T-706 (fresh-spawn pin): hub[0] must stay inside the tutorial giver's marker horizon.
const MARKER_HORIZON_M := 55.0  # client nameplate_lod.gd MARKER_FADE_END (kept in lock-step)
const SPAWN_JITTER_M := 6.0
const TUTORIAL_GIVER := "npc_drillmaster"

# T-708 (starter wolf density): band, spacing floor, hub clearance and the ~15 s respawn.
const STARTER_BAND_M := 120.0  # the hamlet band; heartwold wolf packs live far outside it
const WOLF_PAIR_MIN_M := 15.0
const WOLF_HUB_CLEARANCE_M := 30.0
const STARTER_RESPAWN_TICKS_MAX := 300  # ~15 s at 20 tps


func _read_json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	assert_not_null(f, "missing data file %s" % path)
	if f == null:
		return null
	return JSON.parse_string(f.get_as_text())


func _mob_level(mob_file: String) -> int:
	var data: Variant = _read_json("res://data/mobs/%s" % mob_file)
	if data is Dictionary:
		return int((data as Dictionary).get("level", 0))
	return 0


func test_every_shipped_spawn_hub_is_clear_of_dangerous_mobs() -> void:
	var spawn_doc: Variant = _read_json("res://data/regions/spawn_points.json")
	assert_true(spawn_doc is Dictionary, "spawn_points.json parses")
	var hubs: Array = (spawn_doc as Dictionary).get("hubs", [])
	assert_gt(hubs.size(), 0, "there is at least one spawn hub")

	var spawns_doc: Variant = _read_json("res://data/mobs/spawns.json")
	var spawns: Array = (spawns_doc as Dictionary).get("spawns", [])

	# Collect every dangerous mob position once.
	var danger: Array = []  # [Vector2 pos, int level, String id]
	for entry: Dictionary in spawns:
		var mob_file := str(entry.get("mob_file", ""))
		var level := _mob_level(mob_file)
		if level <= SAFE_MOB_LEVEL:
			continue
		for pos in entry.get("positions", []):
			danger.append([Vector2(float(pos[0]), float(pos[1])), level, mob_file])

	for hub in hubs:
		var h := Vector2(float(hub[0]), float(hub[1]))
		for d in danger:
			var dist := h.distance_to(d[0])
			assert_true(
				dist >= SAFE_CLEARANCE_M,
				(
					"spawn hub %s is %.1f m from L%d %s (need >= %.0f m; a fresh L1 would be killed at spawn)"
					% [h, dist, d[1], d[2], SAFE_CLEARANCE_M]
				)
			)


# --- T-706: hub[0] is the fresh-character spawn — it must stay inside the marker horizon ------
# spawn_dispersion.pick_first_hub pins every not-yet-graduated login to the FIRST authored hub.
# That only guides anyone if the hub actually sits within nameplate_lod's 55 m marker fade of the
# tutorial giver (Drillmaster Hale) — minus the 6 m jitter disc, worst case. Re-anchoring hub[0]
# (or moving Hale) past that horizon recreates the launch-scale "spawned with zero guidance" bug.
func test_first_hub_is_inside_the_tutorial_givers_marker_horizon() -> void:
	var spawn_doc: Variant = _read_json("res://data/regions/spawn_points.json")
	var hubs: Array = (spawn_doc as Dictionary).get("hubs", [])
	assert_gt(hubs.size(), 0, "there is at least one spawn hub")
	var first := Vector2(float(hubs[0][0]), float(hubs[0][1]))
	assert_eq(first, Vector2(40.0, -14.0), "hub[0] is the T-515 Drillmaster-adjacent anchor")
	var npc_doc: Variant = _read_json("res://data/npcs/npcs.json")
	var giver := Vector2.INF
	for npc: Dictionary in (npc_doc as Dictionary).get("npcs", []):
		if str(npc.get("id", "")) == TUTORIAL_GIVER:
			giver = Vector2(float(npc.get("x", 0.0)), float(npc.get("y", 0.0)))
	assert_ne(giver, Vector2.INF, "the tutorial giver exists")
	var worst := first.distance_to(giver) + SPAWN_JITTER_M
	assert_true(
		worst <= MARKER_HORIZON_M,
		(
			(
				"hub[0] %s is %.1f m (worst case, +jitter) from %s — past the %.0f m marker horizon; "
				% [first, worst, TUTORIAL_GIVER, MARKER_HORIZON_M]
			)
			+ "a fresh character would spawn with zero on-screen guidance (T-706)"
		)
	)


# --- T-708: starter wolf density + spacing --------------------------------------------------
# The starter band must feed ~15 required wolf kills (q001+q010+q004) for 2+ simultaneous
# newcomers: >=6 spawns, every pair >=15 m apart (the fun-audit #52 chain-pull floor; authored at
# >=30 m, T-402's solo grammar), EVERY spawn >=30 m from every spawn hub, and a ~15 s respawn.
func _starter_wolf_entries() -> Array:  # spawns.json entries whose positions sit in the band
	var spawns_doc: Variant = _read_json("res://data/mobs/spawns.json")
	var out: Array = []
	for entry: Dictionary in (spawns_doc as Dictionary).get("spawns", []):
		if str(entry.get("mob_file", "")) != "wolf.json":
			continue
		for pos in entry.get("positions", []):
			if absf(float(pos[0])) <= STARTER_BAND_M and absf(float(pos[1])) <= STARTER_BAND_M:
				out.append(entry)
				break
	return out


func test_starter_wolf_density_spacing_and_respawn() -> void:
	var entries := _starter_wolf_entries()
	assert_gt(entries.size(), 0, "the starter band has a wolf spawn entry")
	var pts: Array = []
	for entry: Dictionary in entries:
		assert_true(
			int(entry.get("respawn_ticks", 600)) <= STARTER_RESPAWN_TICKS_MAX,
			"starter wolves respawn in ~15 s (respawn_ticks <= %d)" % STARTER_RESPAWN_TICKS_MAX
		)
		for pos in entry.get("positions", []):
			pts.append(Vector2(float(pos[0]), float(pos[1])))
	assert_gte(pts.size(), 6, "at least 6 starter wolf spawns feed the ~15 required kills")
	for i in range(pts.size()):
		for j in range(i + 1, pts.size()):
			var d: float = pts[i].distance_to(pts[j])
			assert_true(
				d >= WOLF_PAIR_MIN_M,
				(
					"wolf pair %s/%s is %.1f m apart (< %.0f m) — the #52 chain-pull"
					% [str(pts[i]), str(pts[j]), d, WOLF_PAIR_MIN_M]
				)
			)
	var spawn_doc: Variant = _read_json("res://data/regions/spawn_points.json")
	for hub in (spawn_doc as Dictionary).get("hubs", []):
		var h := Vector2(float(hub[0]), float(hub[1]))
		for p: Vector2 in pts:
			assert_true(
				p.distance_to(h) >= WOLF_HUB_CLEARANCE_M,
				(
					(
						"wolf %s is %.1f m from hub %s (need >= %.0f m — fast-respawn wolves must "
						% [str(p), p.distance_to(h), str(h), WOLF_HUB_CLEARANCE_M]
					)
					+ "never camp a spawn hub)"
				)
			)
