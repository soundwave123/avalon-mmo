# T-355 CONCURRENCY/CAPACITY SPIKE — headless load probe for the positions broadcast.
#
# Drives the REAL production hot path (broadcast_builder.positions_frames + Godot's own
# var_to_bytes payload serialization — the exact bytes rpc_id puts on the wire) over synthetic
# N-player stores, so the measured curve is the honest cost of the current all-peers broadcast
# with no GPU, no DB, and no flaky N-process ENet fan-out. It answers the two questions the ticket
# asks — server broadcast build+send time as N grows, and broadcast bytes/peer — and adds a
# measured AOI (distance-interest) variant so the lever's ceiling gain is a number, not a guess.
#
# Run: scripts/godot-bin.sh --headless --path server/world -s res://tools/load_probe.gd
# Optional: AVALON_LOAD_NS="10,25,50,100,200,400" AVALON_LOAD_ITERS=200 AVALON_AOI_RADIUS=80
#
# Model (per server tick of the broadcast, at BROADCAST_RATE_HZ = 10 -> 100 ms budget):
#   all-peers cost  = build_frames_once + N * serialize(payload)   (rpc_id re-encodes per peer)
#   AOI cost        = N * (build_scoped_peer + serialize(scoped_payload))
# The honest CCU ceiling = the largest N whose cost stays under the 100 ms broadcast interval.
extends SceneTree

const _BB = preload("res://scripts/broadcast_builder.gd")
const _CR = preload("res://scripts/combat/combat_resources.gd")
const _SC = preload("res://scripts/server_config.gd")

# T-371: the era-region anchors the broadcast now buckets on (mirror of broadcast_builder).
const REGIONS := [Vector2(0.0, 0.0), Vector2(420.0, 0.0), Vector2(-420.0, 0.0)]
const _DIST_NOTE := {
	"spread": "  (uniform over era-1 playable)",
	"clustered": "  (all N crowded on the village square)",
	"dispersed": "  (N round-robin'd across the T-373 spawn hubs — lever 4 vs clustered)",
	"regional": "  (N split across era-1 / crypt / Ashmoor — the T-371 lever)"
}

# T-373: the login spawn hubs (mirror of server/world/data/regions/spawn_points.json). The
# "dispersed" distribution scatters logins round-robin across these instead of all onto origin, so
# the probe measures the AOI relief lever 4 buys over the "clustered" (K==N) hotspot.
const SPAWN_HUBS := [
	Vector2(-6.0, 44.0),
	Vector2(-54.0, -6.0),
	Vector2(-36.0, 18.0),
	Vector2(40.0, -14.0),
	Vector2(-46.0, -36.0),
	Vector2(50.0, -46.0),
	Vector2(6.0, 72.0),
	Vector2(-10.0, -104.0)
]

const CLASSES := ["warrior", "mage", "priest", "ranger", "rogue"]
const GEAR := {
	"weapon": "wpn_iron_sword",
	"offhand": "shd_round",
	"head": "hlm_iron",
	"chest": "arm_iron_chest",
	"legs": "arm_iron_legs"
}

# era-1 playable footprint (spawn-prompt bounds): x in [-200,200], z in [-400,200].
const PLAY_X_MIN := -200.0
const PLAY_X_MAX := 200.0
const PLAY_Z_MIN := -400.0
const PLAY_Z_MAX := 200.0
# The spawn/village-square hotspot every new login lands on (main.gd start_pos = Vector3.ZERO).
const HOTSPOT := Vector3.ZERO
const HOTSPOT_RADIUS := 25.0  # a village-square-sized crowd radius


func _init() -> void:
	var ns := _parse_ns(OS.get_environment("AVALON_LOAD_NS"))
	var iters := (
		int(OS.get_environment("AVALON_LOAD_ITERS"))
		if OS.get_environment("AVALON_LOAD_ITERS") != ""
		else 200
	)
	var aoi_r := (
		float(OS.get_environment("AVALON_AOI_RADIUS"))
		if OS.get_environment("AVALON_AOI_RADIUS") != ""
		else 80.0
	)
	var mobs := _synth_mobs(19)  # matches spawns.json open-world total
	var npcs := _synth_npcs(12)  # ~12 ambient movers ride the world frame (of 61 NPCs)
	var budget_ms := 1000.0 / _SC.BROADCAST_RATE_HZ

	print("=== T-355 LOAD PROBE — positions broadcast scaling ===")
	print(
		(
			"tick=%d Hz  broadcast=%d Hz  budget=%.1f ms/broadcast  iters=%d  AOI r=%.0fm"
			% [_SC.TICK_RATE_HZ, _SC.BROADCAST_RATE_HZ, budget_ms, iters, aoi_r]
		)
	)
	print("mobs=%d  ambient_npcs=%d  (both ride every world frame)" % [mobs.size(), npcs.size()])
	print("")

	for dist in ["spread", "clustered", "dispersed", "regional"]:
		print("---- distribution: %s%s ----" % [dist, _DIST_NOTE.get(dist, "")])
		print(
			(
				"%5s | %11s | %13s | %13s | %11s | %11s | %8s | %11s | %11s | %11s"
				% [
					"N",
					"build_ms",
					"ser/peer_ms",
					"bytes/peer",
					"ALL cost_ms",
					"ALL Mbit/s",
					"AOI_k",
					"AOI bytes/pr",
					"AOI cost_ms",
					"AOIreg ms"
				]
			)
		)
		for n in ns:
			var stores := _synth_stores(n, dist)
			_measure(n, stores, mobs, npcs, iters, aoi_r, budget_ms)
		print("")

	_delta_section(ns, mobs, npcs, iters, aoi_r)

	print(
		(
			"budget line: a broadcast must finish under %.1f ms or the 10 Hz cadence slips (tick backs up)."
			% budget_ms
		)
	)
	quit()


func _measure(
	n: int,
	stores: Dictionary,
	mobs: Dictionary,
	npcs: Array,
	iters: int,
	aoi_r: float,
	budget_ms: float
) -> void:
	var positions: Dictionary = stores["positions"]
	var resources: Dictionary = stores["resources"]
	var classes: Dictionary = stores["classes"]
	var gear: Dictionary = stores["gear"]
	var party_of: Dictionary = {}

	# ---- ALL-PEERS path: build the world frame once, serialize once, cost = build + N*serialize ----
	var t0 := Time.get_ticks_usec()
	var frames: Array = []
	for i in iters:
		frames = _BB.positions_frames(positions, resources, classes, gear, {}, party_of, mobs, npcs)
	var build_ms := float(Time.get_ticks_usec() - t0) / 1000.0 / iters

	var payload: Dictionary = frames[0]["payload"]
	var t1 := Time.get_ticks_usec()
	var bytes := PackedByteArray()
	for i in iters:
		bytes = var_to_bytes(payload)
	var ser_ms := float(Time.get_ticks_usec() - t1) / 1000.0 / iters
	var bytes_per_peer := bytes.size()

	var all_cost_ms := build_ms + n * ser_ms
	var all_mbit := float(n) * bytes_per_peer * _SC.BROADCAST_RATE_HZ * 8.0 / 1_000_000.0

	# ---- AOI path: each peer gets only players within aoi_r; cost = N*(build_scoped + serialize) ----
	var aoi_cost_ms := 0.0
	var aoi_k_total := 0
	var aoi_bytes_total := 0
	var t2 := Time.get_ticks_usec()
	for pid in positions:
		var scoped := _within_radius(positions, positions[pid], aoi_r)
		aoi_k_total += scoped.size()
		var pa := _BB.players_array(scoped, resources, classes, gear, {}, party_of)
		var scoped_payload := {
			"type": "positions", "players": pa, "mobs": _BB.mobs_array(mobs), "npcs": npcs
		}
		aoi_bytes_total += var_to_bytes(scoped_payload).size()
	aoi_cost_ms = float(Time.get_ticks_usec() - t2) / 1000.0
	var aoi_bytes := int(aoi_bytes_total / max(1, n))  # measured AOI bytes/peer — the bandwidth win
	var aoi_k := float(aoi_k_total) / float(max(1, n))

	# ---- T-371 region-bucketed AOI: cross-region peers skip radius math (build+serialize per peer,
	# but each peer's interest scan is bounded by its OWN era's population, not global N) ----
	var t3 := Time.get_ticks_usec()
	var region_bytes_total := 0
	var buckets := {}
	for pid in positions:
		var rk := _BB.region_of(positions[pid]["x"], positions[pid]["z"])
		buckets.get_or_add(rk, {})[pid] = positions[pid]
	for rk in buckets:
		var region_pos: Dictionary = buckets[rk]
		var region_mobs: Array = _BB.mobs_array(_BB.mobs_in_region(mobs, rk))
		var region_npcs: Array = _BB.npcs_in_region(npcs, rk)
		for pid in region_pos:
			var neigh := _BB.peers_in_range(region_pos, pid, aoi_r, 0)
			var pa := _BB.players_array(neigh, resources, classes, gear, {}, party_of)
			var scoped_payload := {
				"type": "positions", "players": pa, "mobs": region_mobs, "npcs": region_npcs
			}
			region_bytes_total += var_to_bytes(scoped_payload).size()
	var aoireg_cost_ms := float(Time.get_ticks_usec() - t3) / 1000.0

	var flag := "  <-- OVER" if all_cost_ms > budget_ms else ""
	print(
		(
			"%5d | %11.4f | %13.5f | %13d | %11.3f | %11.2f | %8.1f | %11d | %11.3f | %11.3f%s"
			% [
				n,
				build_ms,
				ser_ms,
				bytes_per_peer,
				all_cost_ms,
				all_mbit,
				aoi_k,
				aoi_bytes,
				aoi_cost_ms,
				aoireg_cost_ms,
				flag
			]
		)
	)


# T-372 lever 3: the per-peer DELTA broadcast on top of the AOI frames. Measures the FULL keyframe
# frame (every field, every neighbour — the T-370/T-371 "after" is this ticket's "before") against a
# steady-state delta after every player takes a ~0.4 m walking step: the static half of the payload
# (username/class/gear/max_hp/resource_kind) stops re-transmitting, so bytes/peer collapse to the
# moving fields + the (unchanged, full) mob/npc floor. delta ms = the extra transform cost/frame.
func _delta_section(ns: Array, mobs: Dictionary, npcs: Array, iters: int, aoi_r: float) -> void:
	print("---- T-372 delta broadcast (spread; full keyframe vs steady-state delta) ----")
	print(
		"%5s | %13s | %13s | %8s | %11s" % ["N", "key B/peer", "delta B/peer", "saved%", "delta ms"]
	)
	var cap: int = _SC.DEFAULT_AOI_MAX_PEERS
	for n in ns:
		var stores := _synth_stores(n, "spread")
		var pos: Dictionary = stores["positions"]
		var res: Dictionary = stores["resources"]
		var cls: Dictionary = stores["classes"]
		var gear: Dictionary = stores["gear"]
		var kframes := _BB.positions_frames_aoi(pos, res, cls, gear, {}, {}, mobs, npcs, aoi_r, cap)
		var key_out := _BB.positions_delta_frames(kframes, {}, 999999)
		var key_bytes := _avg_frame_bytes(key_out["frames"])
		var moved := _nudge(pos)
		var mframes := _BB.positions_frames_aoi(
			moved, res, cls, gear, {}, {}, mobs, npcs, aoi_r, cap
		)
		var t := Time.get_ticks_usec()
		var dout := {}
		for i in iters:
			dout = _BB.positions_delta_frames(mframes, key_out["state"], 20)
		var delta_ms := float(Time.get_ticks_usec() - t) / 1000.0 / iters
		var delta_bytes := _avg_frame_bytes(dout["frames"])
		var saved := 100.0 * (1.0 - float(delta_bytes) / float(max(1, key_bytes)))
		print("%5d | %13d | %13d | %7.1f%% | %11.4f" % [n, key_bytes, delta_bytes, saved, delta_ms])
	print("")


func _avg_frame_bytes(frames: Array) -> int:
	if frames.is_empty():
		return 0
	var total := 0
	for f in frames:
		total += var_to_bytes(f["payload"]).size()
	return int(total / frames.size())


# Every player takes a small walking step (positions change frame-to-frame; static fields do not).
func _nudge(positions: Dictionary) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x5717
	var out := {}
	for pid in positions:
		var p: Dictionary = positions[pid].duplicate()
		p["x"] = float(p["x"]) + rng.randf_range(-0.4, 0.4)
		p["z"] = float(p["z"]) + rng.randf_range(-0.4, 0.4)
		out[pid] = p
	return out


# players within `radius` of `center` — the AOI interest filter (mirrors positions_in_instance).
func _within_radius(positions: Dictionary, center: Dictionary, radius: float) -> Dictionary:
	var cx: float = center["x"]
	var cz: float = center["z"]
	var r2 := radius * radius
	var out := {}
	for pid in positions:
		var p: Dictionary = positions[pid]
		var dx: float = p["x"] - cx
		var dz: float = p["z"] - cz
		if dx * dx + dz * dz <= r2:
			out[pid] = p
	return out


func _synth_stores(n: int, dist: String) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xA5A5 + n
	var positions := {}
	var resources := {}
	var classes := {}
	var gear := {}
	for i in n:
		var pid := 1000 + i
		var pos: Vector3
		if dist == "clustered":
			var a := rng.randf() * TAU
			var rr := sqrt(rng.randf()) * HOTSPOT_RADIUS
			pos = HOTSPOT + Vector3(cos(a) * rr, 0.0, sin(a) * rr)
		elif dist == "dispersed":
			# T-373: round-robin the login across the spawn hubs (+ a village-square-sized jitter per
			# hub), the exact shape spawn_dispersion.gd produces. The crowd that clustered on origin is
			# now split ~N/hubs ways, so each peer's AOI neighbour count K falls from N toward N/hubs.
			var hub: Vector2 = SPAWN_HUBS[i % SPAWN_HUBS.size()]
			var a := rng.randf() * TAU
			var rr := sqrt(rng.randf()) * 6.0
			pos = Vector3(hub.x + cos(a) * rr, 0.0, hub.y + sin(a) * rr)
		elif dist == "regional":
			# T-371: split the population across the three era domains, each a village-square-sized
			# huddle at its anchor — so region bucketing bounds each peer's scan to N/3, not N.
			var anchor: Vector2 = REGIONS[i % REGIONS.size()]
			var a := rng.randf() * TAU
			var rr := sqrt(rng.randf()) * HOTSPOT_RADIUS
			pos = Vector3(anchor.x + cos(a) * rr, 0.0, anchor.y + sin(a) * rr)
		else:
			pos = Vector3(
				rng.randf_range(PLAY_X_MIN, PLAY_X_MAX),
				0.0,
				rng.randf_range(PLAY_Z_MIN, PLAY_Z_MAX)
			)
		var cls: String = CLASSES[i % CLASSES.size()]
		positions[pid] = {
			"username": "loadbot_%04d" % i, "x": pos.x, "y": pos.y, "z": pos.z, "instance_id": 0
		}
		classes[pid] = cls
		gear[pid] = GEAR
		var cr = _CR.new()
		cr.hp = 850
		cr.max_hp = 1000
		cr.resource_kind = (
			"mana" if cls in ["mage", "priest"] else ("rage" if cls == "warrior" else "none")
		)
		cr.mana = 3000
		cr.max_mana = 5000
		cr.rage = 40
		cr.max_rage = 100
		resources[pid] = cr
	return {"positions": positions, "resources": resources, "classes": classes, "gear": gear}


func _synth_mobs(n: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xBEEF
	var mobs := {}
	for i in n:
		var m := _MobStub.new()
		m.mob_id = "mob_wolf_%d" % i
		m.render_kind = "mob_wolf"
		m.name = "Grey Wolf"
		m.position = Vector3(rng.randf_range(-45, 48), 0.0, rng.randf_range(-45, 42))
		m.resources = _CR.new()
		m.resources.hp = 60
		m.resources.max_hp = 80
		mobs[m.mob_id] = m
	return mobs


func _synth_npcs(n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append({"npc_id": "npc_villager_%d" % i, "x": float(i), "y": 0.0, "z": float(-i)})
	return out


func _parse_ns(s: String) -> Array:
	if s == "":
		return [10, 25, 50, 100, 200, 400, 800]
	var out: Array = []
	for tok in s.split(","):
		if tok.strip_edges() != "":
			out.append(int(tok))
	return out


# Minimal mob stand-in matching the fields broadcast_builder.mobs_array reads.
class _MobStub:
	extends RefCounted
	var mob_id: String
	var render_kind: String
	var name: String
	var elite: bool = false
	var render_scale: float = 1.0
	var position: Vector3
	var ai_state: String = "idle"
	var instance_id: int = 0
	var resources
