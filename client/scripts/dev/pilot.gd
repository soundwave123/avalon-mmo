class_name Pilot
# T-075: in-client automation pilot — the "eyes and hands" for agent-driven visual testing.
#
# Enabled ONLY when AVALON_PILOT=1 (main.gd adds this node). Polls a command file and
# executes ops against the LIVE client: framebuffer screenshots (display-server agnostic —
# no Xvfb/xdotool/Wayland portals), injected input events (they run the full engine input
# pipeline, no window focus needed), UI-tree and game-state introspection.
#
# Protocol (all under AVALON_PILOT_DIR, default /tmp/avalon-pilot):
#   cmds.jsonl  — driver APPENDS one JSON object per line; the line index is the command id.
#   ack_<id>.json — pilot writes one ack per command: {"ok": bool, ...result}.
# Ops:
#   {"op":"screenshot","path":"..."}         save the viewport to PNG
#   {"op":"key","key":"N"}                   press + release a key
#   {"op":"key_hold","key":"W","secs":1.0}   hold a key for N seconds
#   {"op":"click","x":640,"y":360}           left-click at viewport coords
#   {"op":"click_node","name":"Btn_mage"}    click the center of a named visible Control
#   {"op":"drag","button":"left","dx":..,"dy":..,"secs":0.5}  T-339: hold button, move by
#       (dx,dy) px over ~secs (interpolated across several motion events), release. button is
#       "left"/"right"/"middle". Closes the T-321 manual-only left-drag-orbit deferral.
#   {"op":"ui"}                              dump visible Controls (name/class/rect/text)
#   {"op":"state"}                           dump player/game state from Main
#   {"op":"observe"}                         T-562: ONE semantic snapshot for an LLM play-agent
#       (player vitals+hp_delta / active quest / inventory / nearby units / recent log / open panel)
#   {"op":"gear"}                            T-225: local + remote equipment visuals truth
#   {"op":"pvp"}                             T-401: open the PvP panel + dump its rendered body
#   {"op":"nameplates","visible":false}      T-227: hide all NPC + entity nameplates (glamour shots)
#   {"op":"wait_frames","frames":10}         delay before acking (settle animations)
#   {"op":"freecam","x":..,"y":..,"z":..,"yaw_deg":..,"pitch_deg":..}  benchmark camera (T-142)
#   {"op":"freecam","off":true}              restore the pre-freecam camera
#   {"op":"goto","x":..,"z":..,"y"?:..}      T-180: rate-legal hops. T-623(#57) ARRIVAL-VERIFIED.
#   {"op":"look","dx":..,"dy":..}            T-077: right-drag look. T-623 verifies it turned.
#   {"op":"create_character","gender":"male"|"female","class":"warrior"|"mage"|"priest",
#       "name"?:"<char name>"}  T-623/T-716: the boot dance (Handbook -> gender -> class -> name) as
#       ONE op — named Buttons + polling; without "name" it stops at the name modal (name_pending).
#   {"op":"wait_until","path":"a.b","value":"..","timeout"?:10.0}  T-623: poll-don't-sleep — wait
#       for a state+player dot-path to match value (">N" "<N" "x,z[,tol]" bool/number/string).
#   {"op":"batch","ops":[{...}, ...]}        T-623: N ops, ONE combined ack {ok,results:[...]}.
#   {"op":"intent","payload":{"type":...}}   T-334: send any typed intent dict to the server
#   {"op":"crypt","action":"enter"|"leave"}  T-334: enter_instance / leave_instance shorthand
#   {"op":"positions"}                       T-334: last positions payload (instance E2E truth)
#   {"op":"quit"}                            close the client

extends Node

# T-180 goto tuning — hops stay inside the server movement budget so no server change is needed.
const _GOTO_HOP := 90.0  # per hop; < server 100 u/tick & 100 u/sec budget (T-011/T-074)
const _GOTO_WINDOW_S := 1.1  # T-074 rate window is ~1 s; wait it out so no hop is rejected
const _GOTO_ARRIVE := 0.5  # stop within this of target (well inside INTERACT_RADIUS = 3 u)
const _GOTO_MAX_HOPS := 32  # guard: 32 * 90 u = 2880 u >> the ±500 world bounds
const _GOTO_DEFAULT_Y := 1.0  # flat core is y=0; a hair above so feet don't clip underfoot

var _dir: String = "/tmp/avalon-pilot"
var _lines_done: int = 0
var _held_keys: Dictionary = {}  # keycode -> release_at_msec
var _pending_acks: Array = []  # [{id, at_msec, payload}] for wait_frames
var _freecam: Camera3D = null  # T-142: dev-only benchmark camera (screenshot wall)
var _prev_camera: Camera3D = null  # T-142: camera live before the freecam takeover (to restore)
var _last_observe: Dictionary = {}  # T-562: previous observe snapshot (for the hp_delta diff)


func _ready() -> void:
	var env_dir := OS.get_environment("AVALON_PILOT_DIR")
	if env_dir != "":
		_dir = env_dir
	DirAccess.make_dir_recursive_absolute(_dir)
	_pin_resolution()
	print("[pilot] active — command file: %s/cmds.jsonl" % _dir)


# T-346: this machine's persisted user://settings.cfg (window_mode/fullscreen, from an earlier
# manual play session) applies via SettingsPanel.setup() BEFORE the Pilot node is added and can
# silently override the boot --resolution CLI flag (e.g. fullscreen -> the host's native display
# size — T-347's cross-host qa-tour/visual-regress golden trap). A piloted session always forces
# itself back to windowed at ONE pinned size, regardless of what got persisted. Same value
# pilot-up.sh's --resolution flag used (single source of truth, see AVALON_PILOT_RESOLUTION).
func _pin_resolution() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var pin := OS.get_environment("AVALON_PILOT_RESOLUTION")
	if pin == "":
		pin = "1280x720"
	var dims := pin.split("x")
	if dims.size() != 2:
		return
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Vector2i(int(dims[0]), int(dims[1])))


func _process(_delta: float) -> void:
	_release_due_keys()
	_flush_due_acks()
	var file := FileAccess.open(_dir.path_join("cmds.jsonl"), FileAccess.READ)
	if file == null:
		return
	var lines: PackedStringArray = file.get_as_text().split("\n")
	file.close()
	while _lines_done < lines.size():
		var line := lines[_lines_done].strip_edges()
		if line == "":
			if _lines_done == lines.size() - 1:
				break  # trailing newline — not a command yet
			_lines_done += 1
			continue
		var id := _lines_done
		_lines_done += 1
		var cmd = JSON.parse_string(line)
		if cmd is Dictionary:
			_run(id, cmd)
		else:
			_ack(id, {"ok": false, "error": "unparseable: %s" % line})


func _run(id: int, cmd: Dictionary) -> void:
	match str(cmd.get("op", "")):
		"screenshot":
			_op_screenshot(id, str(cmd.get("path", _dir.path_join("shot_%d.png" % id))))
		"key":
			_op_key(id, str(cmd.get("key", "")))
		"key_hold":
			_op_key_hold(id, str(cmd.get("key", "")), float(cmd.get("secs", 0.5)))
		"click":
			_op_click(id, Vector2(float(cmd.get("x", 0)), float(cmd.get("y", 0))))
		"click_node":
			_op_click_node(id, str(cmd.get("name", "")))
		"look":  # T-077: hold RMB, drag by (dx,dy) pixels over a few steps, release
			_op_look(id, float(cmd.get("dx", 0)), float(cmd.get("dy", 0)))
		"drag":  # T-339: hold any button, drag by (dx,dy) over ~secs, release (generalizes look)
			_op_drag(
				id,
				str(cmd.get("button", "left")),
				float(cmd.get("dx", 0)),
				float(cmd.get("dy", 0)),
				float(cmd.get("secs", 0.3))
			)
		"wheel":  # T-126: scroll steps>0 zooms in (wheel up), steps<0 zooms out
			_op_wheel(id, int(cmd.get("steps", 1)))
		"ui":
			_ack(id, {"ok": true, "controls": _dump_controls(get_tree().root, [])})
		"state":
			_ack(id, {"ok": true, "state": _dump_state()})
		"observe":  # T-562: ONE semantic snapshot for an LLM play-agent (reuses HUD/nameplate/log)
			_ack(id, {"ok": true, "observe": _op_observe()})
		"gear":
			_ack(id, {"ok": true, "gear": _dump_gear()})
		"pvp":  # T-401: open + dump the PvP panel (rating/honor/tracks/titles body)
			_ack(id, {"ok": true, "pvp": _dump_pvp()})
		"casts":
			_ack(id, {"ok": true, "casts": _dump_casts()})
		"nameplates":
			_set_nameplates(bool(cmd.get("visible", true)))
			_ack(id, {"ok": true, "visible": bool(cmd.get("visible", true))})
		"party":
			_party_action(str(cmd.get("action", "")), str(cmd.get("target", "")))
			_ack(id, {"ok": true})
		"partystate":
			_ack(id, {"ok": true, "party": _dump_party()})
		"fps":  # T-210: frame probe for the city benchmark
			_ack(
				id,
				{
					"ok": true,
					"fps": Engine.get_frames_per_second(),
					"frame_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
					"draw_calls":
					Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
					"primitives":
					Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
				}
			)
		"scene":  # visual-QA aid: every VisualInstance3D's path + world position (+ AABB size)
			_ack(
				id,
				{
					"ok": true,
					"camera": _dump_camera(),
					"nodes": _dump_scene_meshes(get_tree().root, [])
				}
			)
		"pick":  # visual-QA aid: physics raycast through a screen pixel -> what's there
			_op_pick(id, Vector2(float(cmd.get("x", 0)), float(cmd.get("y", 0))))
		"setvis":  # visual-QA aid: toggle a node's visibility to bisect what's on screen
			_op_setvis(id, str(cmd.get("path", "")), bool(cmd.get("visible", true)))
		"wait_frames":
			(
				_pending_acks
				. append(
					{
						"id": id,
						"at": Time.get_ticks_msec() + int(cmd.get("frames", 10)) * 17,
						"payload": {"ok": true},
					}
				)
			)
		"record":  # capture a frame SEQUENCE (for a GIF/MP4 — see transient VFX / motion live)
			_op_record(
				id,
				int(cmd.get("frames", 120)),
				str(cmd.get("dir", _dir.path_join("rec"))),
				maxi(1, int(cmd.get("every", 2)))
			)
		"audio_record":  # tap the Master audio bus to a WAV (hear the live game mix)
			_op_audio_record(
				id, float(cmd.get("secs", 6.0)), str(cmd.get("path", _dir.path_join("audio.wav")))
			)
		"freecam":  # T-142: dev-only benchmark camera for the screenshot wall (named vistas)
			if bool(cmd.get("off", false)):
				_op_freecam_off(id)
			else:
				_op_freecam(
					id,
					float(cmd.get("x", 0.0)),
					float(cmd.get("y", 0.0)),
					float(cmd.get("z", 0.0)),
					float(cmd.get("yaw_deg", 0.0)),
					float(cmd.get("pitch_deg", 0.0))
				)
		"goto":  # T-180: teleport the player to (x,z) in rate-legal hops for distant-zone QA
			# T-326: no explicit y -> resolve the terrain surface (y=1.0 sank the player
			# under raised ground and broke the follow camera on hills).
			var goto_x := float(cmd.get("x", 0.0))
			var goto_z := float(cmd.get("z", 0.0))
			var goto_y := float(cmd.get("y", _terrain_y_or_default(goto_x, goto_z)))
			_op_goto(id, goto_x, goto_y, goto_z)
		"target":  # T-326: select a combat target (nearest mob, optional name filter)
			_op_target(id, str(cmd.get("name", "")))
		"intent":  # T-334: send an ARBITRARY typed intent dict to the server (future-proof E2E verb)
			_op_intent(id, cmd.get("payload", {}))
		"say":  # T-361: chat — {op:say, text, channel?} rides the same generic intent path
			_op_intent(
				id,
				{
					"type": "chat",
					"channel": str(cmd.get("channel", "say")),
					"text": str(cmd.get("text", "")),
				}
			)
		"emote":  # T-361 item 3: emote intent — {op:emote, id} sends only the id; server validates
			_op_intent(id, {"type": "emote", "id": str(cmd.get("id", ""))})
		"crypt":  # T-334: dungeon stair without walking — enter_instance / leave_instance
			var crypt_action := str(cmd.get("action", ""))
			if crypt_action == "enter" or crypt_action == "leave":
				_op_intent(id, {"type": crypt_action + "_instance"})
			else:
				_ack(id, {"ok": false, "error": "crypt action must be enter|leave"})
		"create_character":  # T-623/T-716: gender+class+name modal dance as ONE op
			_op_create_character(id, cmd)
		"wait_until":  # T-623: poll-don't-sleep — wait for a state-path to match a value
			_op_wait_until(
				id,
				str(cmd.get("path", "")),
				str(cmd.get("value", "")),
				float(cmd.get("timeout", 10.0))
			)
		"batch":  # T-623: run N ops, ONE combined ack (cuts per-op round-trip overhead)
			_op_batch(id, cmd.get("ops", []))
		"positions":  # T-334: last positions broadcast payload — instance-scoped E2E truth
			var pos_main := get_tree().root.get_node_or_null("Main")
			var payload = pos_main.get("last_positions") if pos_main != null else null
			_ack(id, {"ok": pos_main != null, "positions": payload if payload != null else {}})
		"vfx_lance":  # T-351: fire the frost bolt VFX locally (cast -> lance -> impact) at a point
			# ahead of the player, so a screenshot catches the in-world look with NO target/server
			# round-trip needed (the era re-skin resolves via Main.vfx.set_era from the district).
			_op_vfx_lance(id, float(cmd.get("range", 8.0)))
		"quit":
			_ack(id, {"ok": true})
			get_tree().quit(0)
		_:
			_ack(id, {"ok": false, "error": "unknown op: %s" % cmd.get("op", "")})


func _op_screenshot(id: int, path: String) -> void:
	# Wait one drawn frame so pending UI changes land in the capture.
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	_ack(id, {"ok": err == OK, "path": path, "width": img.get_width(), "height": img.get_height()})


# Capture `frames` drawn frames (every `every`-th) into dir/f_####.png — pilot.py stitches them into
# a GIF/MP4 so live motion (particles, VFX, day/night, weather) is viewable, not just single frames.
func _op_record(id: int, frames: int, dir: String, every: int) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	# clear any stale frames from a previous recording
	var d := DirAccess.open(dir)
	if d != null:
		for f in d.get_files():
			if f.begins_with("f_") and f.ends_with(".png"):
				d.remove(f)
	var saved := 0
	for i in range(frames):
		await RenderingServer.frame_post_draw
		if i % every == 0:
			var img: Image = get_viewport().get_texture().get_image()
			# downscale before save — a full-res PNG encodes at ~2s/frame here (the bottleneck);
			# a 720-wide frame saves ~10x faster and is plenty for a review clip.
			if img.get_width() > 720:
				img.resize(
					720, int(720.0 * img.get_height() / img.get_width()), Image.INTERPOLATE_BILINEAR
				)
			img.save_png(dir.path_join("f_%04d.png" % saved))
			saved += 1
	_ack(id, {"ok": true, "dir": dir, "count": saved})


# Record the Master audio bus to a WAV via AudioEffectRecord (the bus DSP tap works regardless of
# the output device) so the live synthesized ambience + SFX mix can be heard.
func _op_audio_record(id: int, secs: float, path: String) -> void:
	var bus := AudioServer.get_bus_index("Master")
	if bus < 0:
		_ack(id, {"ok": false, "error": "no Master bus"})
		return
	var rec := AudioEffectRecord.new()
	AudioServer.add_bus_effect(bus, rec)
	var eff_idx := AudioServer.get_bus_effect_count(bus) - 1
	rec.set_recording_active(true)
	await get_tree().create_timer(secs).timeout
	rec.set_recording_active(false)
	var stream: AudioStreamWAV = rec.get_recording()
	var ok := false
	var frames := 0
	if stream != null:
		frames = stream.data.size()
		ok = stream.save_to_wav(path) == OK
	AudioServer.remove_bus_effect(bus, eff_idx)
	_ack(id, {"ok": ok, "path": path, "bytes": frames, "graph": _audio_graph()})


# Audio-graph dump riding the audio_record ack (T-409 row-E hunt): every bus (volume/mute) and
# every live stream player (playing state, routed bus, distance to the listening camera) so a
# silent WAV can be blamed on gating vs routing vs spatialization without guessing.
func _audio_graph() -> Dictionary:
	var buses := []
	for i in AudioServer.bus_count:
		(
			buses
			. append(
				{
					"name": AudioServer.get_bus_name(i),
					"db": AudioServer.get_bus_volume_db(i),
					"mute": AudioServer.is_bus_mute(i),
				}
			)
		)
	var cam := get_viewport().get_camera_3d()
	var players := []
	for node in get_tree().root.find_children("*", "AudioStreamPlayer", true, false):
		players.append(
			{"path": str(node.get_path()), "playing": node.playing, "bus": node.bus, "kind": "2d"}
		)
	for node in get_tree().root.find_children("*", "AudioStreamPlayer3D", true, false):
		var dist := -1.0
		if cam != null:
			dist = cam.global_position.distance_to(node.global_position)
		(
			players
			. append(
				{
					"path": str(node.get_path()),
					"playing": node.playing,
					"bus": node.bus,
					"kind": "3d",
					"unit_db": node.volume_db,
					"max_distance": node.max_distance,
					"dist_to_cam": snappedf(dist, 0.1),
				}
			)
		)
	return {"buses": buses, "players": players, "camera": str(cam.get_path()) if cam else "NONE"}


# T-142: dev-only benchmark camera for the screenshot wall. Lazily creates ONE standalone Camera3D
# ("PilotFreecam") under the tree root and makes it current, so deterministic named vistas can be
# shot WITHOUT touching gameplay's camera rig (built inside local_player.gd). Yaw rotates about
# world +Y, pitch about local X; forward is -Z at yaw 0, pitch<0 looks DOWN — same convention as
# the player camera (rotation.y = yaw, camera_arm.rotation.x = pitch).
func _op_freecam(id: int, x: float, y: float, z: float, yaw_deg: float, pitch_deg: float) -> void:
	if _freecam == null:
		# Capture the live game camera BEFORE ours exists — the one "off" restores.
		_prev_camera = get_viewport().get_camera_3d()
		_freecam = Camera3D.new()
		_freecam.name = "PilotFreecam"
		get_tree().root.add_child(_freecam)
	elif not _freecam.current:
		# Re-taking over after a freecam off — re-cache the now-live game camera.
		var live := get_viewport().get_camera_3d()
		if live != _freecam:
			_prev_camera = live
	_freecam.global_position = Vector3(x, y, z)
	# Default YXZ euler => basis = Ry(yaw) * Rx(pitch): yaw about world up, pitch tilt, no roll.
	_freecam.rotation = Vector3(deg_to_rad(pitch_deg), deg_to_rad(yaw_deg), 0.0)
	_freecam.current = true
	_ack(id, {"ok": true, "pos": [x, y, z], "yaw_deg": yaw_deg, "pitch_deg": pitch_deg})


# T-142: turn the benchmark camera off — restore the camera that was live before the first freecam
# takeover. Null-safe: acks ok (restored=false) even if no freecam/previous camera exists.
func _op_freecam_off(id: int) -> void:
	if _freecam != null:
		_freecam.current = false
	var restored := false
	if _prev_camera != null and is_instance_valid(_prev_camera):
		_prev_camera.current = true
		restored = true
	_ack(id, {"ok": true, "restored": restored})


# T-180: teleport the player for distant-zone QA. Interactions are proximity-gated on the SERVER's
# position and the client snaps to the server when the gap > 3 u, so a client-only global_position
# set would rubber-band AND leave the server thinking we never moved. We instead drive the
# authoritative position via the normal request_move intent, split into rate-legal hops
# (T-011/T-074: <= 100 u/tick & u/sec) paced one per rate window. No server change needed.
func _op_goto(id: int, x: float, y: float, z: float) -> void:
	var player := _local_player()
	if player == null:
		_ack(id, {"ok": false, "error": "no LocalPlayer"})
		return
	var net = player.get("_net")  # ClientNet.request_move; null in a headless test (moves locally)
	var target := Vector2(x, z)
	var hops := 0
	while hops < _GOTO_MAX_HOPS:
		var cur := player.global_position
		var rem := target - Vector2(cur.x, cur.z)
		if rem.length() <= _GOTO_ARRIVE:
			break
		var step := rem.limit_length(_GOTO_HOP)
		if net != null:
			net.request_move(step.x, step.y)  # Godot ground (x,z) delta -> server (x,y)
		player.global_position = Vector3(cur.x + step.x, cur.y, cur.z + step.y)
		hops += 1
		if rem.length() <= _GOTO_HOP:
			break  # this hop reached the target — don't burn a rate window waiting
		await get_tree().create_timer(_GOTO_WINDOW_S).timeout
	player.global_position.y = y
	await get_tree().process_frame
	var p := player.global_position
	# T-623 (#57): verify arrival within tolerance instead of a blind ok:true — that lie is what let
	# a 50-hop retry loop walk a character into an elite's aggro and get it killed.
	var ack := PilotChecks.goto_arrival(p, x, z, _GOTO_ARRIVE)
	ack["pos"] = [p.x, p.y, p.z]
	ack["hops"] = hops
	_ack(id, ack)


# T-351: stage the frost bolt VFX in-world for a screenshot. Fires the same VfxManager path the
# combat handler uses (cast anticipation -> flying lance -> impact burst), aimed `range` metres
# ahead of the player's facing, as the frost ability (id 204) so the Ashmoor era re-skin (Gaslight
# Lance, preset 19) resolves when the player is standing in the district. No target node / server
# round-trip: impact fires the burst without a flash-freeze victim (that needs a real target).
func _op_vfx_lance(id: int, range_m: float) -> void:
	var main := get_tree().root.get_node_or_null("Main")
	var player := _local_player()
	if main == null or player == null:
		_ack(id, {"ok": false, "error": "no Main/LocalPlayer"})
		return
	var vfx = main.get("vfx")
	if vfx == null:
		_ack(id, {"ok": false, "error": "no VfxManager"})
		return
	var origin: Vector3 = player.global_position
	var fwd := Vector3(0, 0, -1).rotated(Vector3.UP, player.rotation.y)  # -Z facing (T-308)
	var strike := origin + fwd * range_m
	var abil := 204  # frostbolt (VfxManager.FROST_ABILITY_ID)
	vfx.spawn_cast(origin, abil)
	await get_tree().create_timer(0.55).timeout  # let the cast anticipation build (buildup window)
	vfx.spawn_projectile(origin, strike, abil)
	await get_tree().create_timer(0.14).timeout
	vfx.spawn_impact_on(strike, null, abil)
	var era = vfx.get("_era")
	_ack(id, {"ok": true, "strike": [strike.x, strike.y, strike.z], "era": era})


# Resolve the player node goto drives: Main.local_player (the wiring point), else the first node
# named "LocalPlayer" — so a headless harness tree without a scripted Main still finds it.
# T-326: terrain-surface y for goto — mirrors the WorldView heightmap; falls back flat.
func _terrain_y_or_default(x: float, z: float) -> float:
	var main := get_tree().root.get_node_or_null("Main")
	var wv = main.get("world_view") if main != null else null
	if wv != null and wv.has_method("_terrain_height"):
		return float(wv.call("_terrain_height", x, z)) + 0.3
	return _GOTO_DEFAULT_Y


# T-326: target the nearest non-player entity (optional case-insensitive name filter on the
# nameplate) so ability/attack sequences are stageable from QA scripts — Tab/click were
# never wired through the pilot and left target_id=-1 (found during the 2026-07-10 QA batch).
func _op_target(id: int, name_filter: String) -> void:
	var main := get_tree().root.get_node_or_null("Main")
	var player := _local_player()
	if main == null or player == null:
		_ack(id, {"ok": false, "error": "no Main/LocalPlayer"})
		return
	var rel = main.get("remote_entities")
	if rel == null:
		_ack(id, {"ok": false, "error": "no RemoteEntities"})
		return
	var ents: Dictionary = rel.get("_entities")
	var best_id := -1
	var best_d := 1e18
	for eid in ents:
		var e: Dictionary = ents[eid]
		if bool(e.get("is_player", false)):
			continue
		var node = e.get("node")
		if node == null:
			continue
		if name_filter != "":
			var label_text := ""
			for lbl in (node as Node).find_children("*", "Label3D", true, false):
				label_text += str(lbl.get("text")) + " "
			if not label_text.to_lower().contains(name_filter.to_lower()):
				continue
		var d: float = (node as Node3D).global_position.distance_squared_to(player.global_position)
		if d < best_d:
			best_d = d
			best_id = int(e.get("target_id", -1))
	if best_id == -1:
		_ack(id, {"ok": false, "error": "no matching entity"})
		return
	main.call("_on_entity_clicked", best_id)
	_ack(id, {"ok": true, "target_id": best_id})


# T-623: thin wrappers — logic lives in PilotCreation/PilotWait/PilotBatch (this file's line cap).
func _op_create_character(id: int, cmd: Dictionary) -> void:
	_ack(id, await PilotCreation.run(self, cmd))


func _op_wait_until(id: int, path: String, raw_value: String, timeout_s: float) -> void:
	_ack(id, await PilotWait.run(self, path, raw_value, timeout_s))


func _op_batch(id: int, ops: Variant) -> void:
	_ack(id, await PilotBatch.run(self, id, ops))


func _local_player() -> Node3D:
	var main := get_tree().root.get_node_or_null("Main")
	if main != null:
		var p = main.get("local_player")
		if p is Node3D:
			return p
	return get_tree().root.find_child("LocalPlayer", true, false) as Node3D


func _key_event(key_name: String, pressed: bool) -> InputEventKey:
	var ev := InputEventKey.new()
	var code := OS.find_keycode_from_string(key_name)
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = pressed
	return ev


func _op_key(id: int, key_name: String) -> void:
	if key_name == "":
		_ack(id, {"ok": false, "error": "no key"})
		return
	Input.parse_input_event(_key_event(key_name, true))
	Input.parse_input_event(_key_event(key_name, false))
	_ack(id, {"ok": true, "key": key_name})


func _op_key_hold(id: int, key_name: String, secs: float) -> void:
	if key_name == "":
		_ack(id, {"ok": false, "error": "no key"})
		return
	Input.parse_input_event(_key_event(key_name, true))
	_held_keys[key_name] = Time.get_ticks_msec() + int(secs * 1000.0)
	# Ack only after release so the driver can chain screenshot-after-move.
	(
		_pending_acks
		. append(
			{
				"id": id,
				"at": Time.get_ticks_msec() + int(secs * 1000.0) + 34,
				"payload": {"ok": true, "key": key_name, "secs": secs},
			}
		)
	)


func _release_due_keys() -> void:
	var now := Time.get_ticks_msec()
	for key_name in _held_keys.keys():
		if now >= int(_held_keys[key_name]):
			Input.parse_input_event(_key_event(str(key_name), false))
			_held_keys.erase(key_name)


func _flush_due_acks() -> void:
	var now := Time.get_ticks_msec()
	for i in range(_pending_acks.size() - 1, -1, -1):
		if now >= int(_pending_acks[i]["at"]):
			_ack(int(_pending_acks[i]["id"]), _pending_acks[i]["payload"])
			_pending_acks.remove_at(i)


func _op_wheel(id: int, steps: int) -> void:
	var btn := MOUSE_BUTTON_WHEEL_UP if steps > 0 else MOUSE_BUTTON_WHEEL_DOWN
	for _i in absi(steps):
		for pressed in [true, false]:
			var ev := InputEventMouseButton.new()
			ev.button_index = btn
			ev.pressed = pressed
			ev.position = get_viewport().get_visible_rect().size / 2.0
			Input.parse_input_event(ev)
	Input.flush_buffered_events()
	_ack(id, {"ok": true, "steps": steps})


# Split from _op_click so a synthesized left-click is reusable without a standalone ack
# (T-623: create_character's gender/class/handbook buttons).
func _click_at(pos: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	motion.global_position = pos
	Input.parse_input_event(motion)
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = pos
		ev.global_position = pos
		Input.parse_input_event(ev)


func _op_click(id: int, pos: Vector2) -> void:
	_click_at(pos)
	_ack(id, {"ok": true, "x": pos.x, "y": pos.y})


# T-077: synthesize a right-drag: RMB down -> N relative-motion events -> RMB up.
# T-623 (session-12 "inert"): frame-spaced, and VERIFIES the body actually turned instead of
# trusting the input injection blindly.
func _op_look(id: int, dx: float, dy: float) -> void:
	var player := _local_player()
	var before_yaw := player.rotation.y if player != null else 0.0
	var center := Vector2(get_viewport().get_visible_rect().size) / 2.0
	var rmb := InputEventMouseButton.new()
	rmb.button_index = MOUSE_BUTTON_RIGHT
	rmb.pressed = true
	rmb.position = center
	rmb.global_position = center
	Input.parse_input_event(rmb)
	await get_tree().process_frame  # let the press land before the drag motion
	var steps := 8
	for i in range(steps):
		var motion := InputEventMouseMotion.new()
		motion.position = center
		motion.global_position = center
		motion.relative = Vector2(dx / steps, dy / steps)
		Input.parse_input_event(motion)
	await get_tree().process_frame  # let the motion land before release
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_RIGHT
	up.pressed = false
	up.position = center
	up.global_position = center
	Input.parse_input_event(up)
	await get_tree().process_frame
	var ack := {"dx": dx, "dy": dy}
	if player == null:
		ack["ok"] = false
		ack["error"] = "no LocalPlayer to verify rotation"
	else:
		ack.merge(PilotChecks.look_verified(before_yaw, player.rotation.y, dx), true)
	_ack(id, ack)


# T-339: generic held-button drag — press <button>, interpolate N relative-motion events over
# ~secs (real frame-spaced, not instantaneous like _op_look's fixed 8-step burst), release.
# Closes the T-321 deferral: pilot.py had no way to hold LMB across motion, so the left-drag
# camera-only orbit (local_player.gd's _orbit_armed/_orbiting) was manual-QA-only.
func _op_drag(id: int, button_name: String, dx: float, dy: float, secs: float) -> void:
	var btn := _button_index(button_name)
	var center := Vector2(get_viewport().get_visible_rect().size) / 2.0
	var down := InputEventMouseButton.new()
	down.button_index = btn
	down.pressed = true
	down.position = center
	down.global_position = center
	Input.parse_input_event(down)
	var steps := maxi(4, int(secs * 30.0))  # ~30 motion events/sec, floor of 4 for a snappy drag
	var per_step_wait := secs / float(steps)
	for i in range(steps):
		if per_step_wait > 0.0:
			await get_tree().create_timer(per_step_wait).timeout
		var motion := InputEventMouseMotion.new()
		motion.position = center
		motion.global_position = center
		motion.relative = Vector2(dx / steps, dy / steps)
		Input.parse_input_event(motion)
	var up := InputEventMouseButton.new()
	up.button_index = btn
	up.pressed = false
	up.position = center
	up.global_position = center
	Input.parse_input_event(up)
	_ack(id, {"ok": true, "button": button_name, "dx": dx, "dy": dy, "secs": secs, "steps": steps})


func _button_index(button_name: String) -> int:
	match button_name.to_lower():
		"right":
			return MOUSE_BUTTON_RIGHT
		"middle":
			return MOUSE_BUTTON_MIDDLE
		_:
			return MOUSE_BUTTON_LEFT


func _op_click_node(id: int, node_name: String) -> void:
	var target := _find_visible_control(get_tree().root, node_name)
	if target == null:
		_ack(id, {"ok": false, "error": "no visible Control named '%s'" % node_name})
		return
	_op_click(id, target.get_global_rect().get_center())


func _find_visible_control(node: Node, node_name: String) -> Control:
	if node is Control and node.name == node_name and (node as Control).is_visible_in_tree():
		return node
	for child in node.get_children():
		var found := _find_visible_control(child, node_name)
		if found != null:
			return found
	return null


func _dump_controls(node: Node, out: Array) -> Array:
	if node is Control and (node as Control).is_visible_in_tree():
		var c := node as Control
		var rect := c.get_global_rect()
		var entry := {
			"name": str(c.name),
			"class": c.get_class(),
			"rect": [rect.position.x, rect.position.y, rect.size.x, rect.size.y],
		}
		if c is Button or c is Label:
			entry["text"] = c.text
		elif c is RichTextLabel:
			entry["text"] = (c as RichTextLabel).get_parsed_text().left(160)
		out.append(entry)
	for child in node.get_children():
		_dump_controls(child, out)
	return out


# Visual-QA aid ("setvis" op): show/hide any node by absolute path — bisect a mystery object
# out of the frame without restarting the stack.
func _op_setvis(id: int, path: String, vis: bool) -> void:
	var node := get_node_or_null(NodePath(path))
	if node == null or not (node is Node3D or node is CanvasItem):
		_ack(id, {"ok": false, "error": "no such visual node: %s" % path})
		return
	node.set("visible", vis)
	_ack(id, {"ok": true, "path": path, "visible": vis})


# Camera pose for the "scene" op so node AABBs can be projected to screen coordinates offline.
func _dump_camera() -> Dictionary:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return {}
	var t := cam.global_transform
	return {
		"pos": [t.origin.x, t.origin.y, t.origin.z],
		"basis_x": [t.basis.x.x, t.basis.x.y, t.basis.x.z],
		"basis_y": [t.basis.y.x, t.basis.y.y, t.basis.y.z],
		"basis_z": [t.basis.z.x, t.basis.z.y, t.basis.z.z],
		"fov": cam.fov,
		"viewport": [get_viewport().size.x, get_viewport().size.y],
	}


# Visual-QA aid ("pick" op): raycast from the camera through a screen pixel and report the
# collider hit — "what IS that thing on screen?" without walking the pilot around. Note:
# collision-less visuals (trees, some decor) are invisible to the ray and it hits what's behind.
func _op_pick(id: int, px: Vector2) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		_ack(id, {"ok": false, "error": "no 3D camera"})
		return
	var from := cam.project_ray_origin(px)
	var to := from + cam.project_ray_normal(px) * 300.0
	var hit := cam.get_world_3d().direct_space_state.intersect_ray(
		PhysicsRayQueryParameters3D.create(from, to)
	)
	if hit.is_empty():
		_ack(id, {"ok": true, "hit": false})
		return
	var collider: Object = hit.get("collider")
	var pos: Vector3 = hit.get("position")
	_ack(
		id,
		{
			"ok": true,
			"hit": true,
			"collider": str(collider.get_path()) if collider is Node else str(collider),
			"pos": [pos.x, pos.y, pos.z],
		}
	)


# Visual-QA aid ("scene" op): walk the 3D scene and report every visible VisualInstance3D's
# path, world position, and AABB size — so a rogue on-screen object can be pinpointed without
# walking the pilot around. Skips tiny pieces (blades of grass etc. live in MultiMesh anyway).
func _dump_scene_meshes(node: Node, out: Array) -> Array:
	if node is VisualInstance3D and (node as VisualInstance3D).is_visible_in_tree():
		var vi := node as VisualInstance3D
		var aabb := vi.global_transform * vi.get_aabb()  # WORLD-space bounds
		(
			out
			. append(
				{
					"path": str(vi.get_path()),
					"pos": [aabb.position.x, aabb.position.y, aabb.position.z],
					"size": [aabb.size.x, aabb.size.y, aabb.size.z],
				}
			)
		)
	for child in node.get_children():
		_dump_scene_meshes(child, out)
	return out


func _dump_state() -> Dictionary:
	var main := get_tree().root.get_node_or_null("Main")
	if main == null:
		return {"error": "no Main"}
	var out := {
		"target_id": main.get("_target_id"),
		"kit_size": (main.get("_kit") as Array).size() if main.get("_kit") != null else 0,
	}
	# T-520: gender_panel is a TRUE blocking modal (the "ui_blocking_modal" group, same as
	# class_panel) shown FIRST at character creation — T-566: an agent polling `state` before this
	# fix could miss it entirely and sit stuck on a boot screen it had no visibility flag for.
	for panel in [
		"class_panel", "gender_panel", "talent_panel", "quest_log_panel", "inventory_panel"
	]:
		var p = main.get(panel)
		out[panel + "_visible"] = p != null and p.visible
	# T-566: WardrobePanel/CosmeticShopPanel are mounted under $HUD via a static mount() (T-428/
	# T-476) rather than kept as a Main field like the panels above, so they're looked up by node
	# path instead of main.get(). Both are real overlay panels (V / H hotkeys) an agent can open and
	# then get stuck behind without a way to notice via `state`.
	for hud_name in ["NamePanel", "WardrobePanel", "CosmeticShopPanel"]:  # T-716 adds the name modal
		var hud_panel = main.get_node_or_null("HUD/%s" % hud_name)
		out["%s_visible" % str(hud_name).to_snake_case()] = hud_panel != null and hud_panel.visible
	# T-376: the controls handbook lives on the OnboardingController, not a Main field.
	var onboarding = main.get("_onboarding")
	var card = onboarding.card if onboarding != null else null
	out["controls_card_visible"] = card != null and card.visible
	var player = main.get("local_player")
	if player is Node3D:
		var pos: Vector3 = (player as Node3D).global_position
		out["player_pos"] = [pos.x, pos.y, pos.z]
		# T-339: T-321 proof surface — body heading vs. the left-drag camera-only orbit offset.
		if player.has_method("body_yaw"):
			out["body_yaw"] = player.call("body_yaw")
		if player.has_method("cam_orbit_yaw"):
			out["cam_orbit_yaw"] = player.call("cam_orbit_yaw")
	return out


# T-562: the semantic snapshot for an autonomous play-agent. Reads are delegated to PilotObserve
# (which reuses the live HUD/positions/nameplate/quest/inventory/log internals) so this handler
# stays a thin, cap-safe seam. Pure read — no side effects. hp_delta is computed against the
# PREVIOUS observe, so the agent sees "my HP is dropping" across two calls.
func _op_observe() -> Dictionary:
	var main := get_tree().root.get_node_or_null("Main")
	if main == null:
		return {"error": "no Main"}
	var snapshot := PilotObserve.gather(main, _last_observe)
	_last_observe = snapshot
	return snapshot


# T-401: PvP panel E2E surface — opens the panel (which fires the rating/leaderboard/tracks
# requests) and returns its visibility + rendered body so a harness can assert the numbers landed.
func _dump_pvp() -> Dictionary:
	var main := get_tree().root.get_node_or_null("Main")
	if main == null:
		return {"error": "no Main"}
	var panel = main.get("pvp_panel")
	if panel == null:
		return {"error": "no pvp_panel"}
	if not panel.visible:
		panel.toggle()  # open → requests fire; the reply body lands over the next frames
	return {"visible": bool(panel.visible), "body": panel.body_text()}


func _ack(id: int, payload: Dictionary) -> void:
	var file := FileAccess.open(_dir.path_join("ack_%d.json" % id), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload))
		file.close()


# T-225: assertable gear truth for the equip-visual E2E — what THIS client renders.
func _dump_gear() -> Dictionary:
	var out := {"local": [], "remote": {}}
	var main := get_tree().root.get_node_or_null("Main")
	if main == null:
		return out
	var lp = main.get("local_player")
	if lp != null:
		var visual: Node = lp.get_node_or_null("BodyVisual")
		if visual != null:
			for att in visual.find_children("GearSlot_*", "", true, false):
				out["local"].append(str(att.name))
	var rem = main.get("remote_entities")
	if rem != null:
		var ents: Dictionary = rem.get("_entities")
		for eid in ents:
			var e: Dictionary = ents[eid]
			var names := []
			for att in (e["node"] as Node).find_children("GearSlot_*", "", true, false):
				names.append(str(att.name))
			out["remote"][str(eid)] = {"gear": e.get("gear", {}), "nodes": names}
	return out


# T-264: assertable cast truth — own cast payload + every remote entity's cast dict.
func _dump_casts() -> Dictionary:
	var out := {"local": {}, "remote": {}}
	var main := get_tree().root.get_node_or_null("Main")
	if main == null:
		return out
	out["local"] = main.get("_own_cast")
	var rem = main.get("remote_entities")
	if rem != null:
		var ents: Dictionary = rem.get("_entities")
		for eid in ents:
			var c = ents[eid].get("cast", {})
			if c is Dictionary and not (c as Dictionary).is_empty():
				out["remote"][str(eid)] = c
	return out


# T-227: flip all NPC + entity nameplates/plates (glamour shots; a future settings toggle
# uses the same layer setters).
func _set_nameplates(visible: bool) -> void:
	var main := get_tree().root.get_node_or_null("Main")
	if main == null:
		return
	var npc = main.get("npc_world")
	if npc != null:
		npc.set_labels_visible(visible)
	var rem = main.get("remote_entities")
	if rem != null:
		rem.set_labels_visible(visible)


# T-280: drive party intents from the harness (invite/accept/decline/leave/disband).
func _party_action(action: String, target: String) -> void:
	var main := get_tree().root.get_node_or_null("Main")
	if main == null:
		return
	var net = main.get("_net")
	if net == null:
		return
	if action == "invite":
		net.party("invite", target)
	elif action in ["accept", "decline", "leave", "disband"]:
		net.party(action)


# T-334: the generic client->server intent verb — sends any typed dict via Main._send_to_server
# (the crypt_gate precedent; client_net.gd sits at the gdlint public-method cap, so new intents
# get no dedicated methods). This is what lets a harness drive enter_instance / lfg_flag / any
# future msg_type from two piloted clients without another pilot release.
func _op_intent(id: int, payload: Dictionary) -> void:
	var main := get_tree().root.get_node_or_null("Main")
	if main == null or not main.has_method("_send_to_server"):
		_ack(id, {"ok": false, "error": "no Main._send_to_server"})
		return
	if str(payload.get("type", "")) == "":
		_ack(id, {"ok": false, "error": "payload needs a type"})
		return
	main.call("_send_to_server", payload)
	_ack(id, {"ok": true, "sent": payload})


# T-280: this client's party truth for assertions — roster, leader, own party_id, pending.
# T-334: + the last lfg_board reply, so board assertions ride the same dump.
func _dump_party() -> Dictionary:
	var main := get_tree().root.get_node_or_null("Main")
	if main == null:
		return {}
	var prompt = main.get("_party_prompt")  # T-598: invite state now lives on PartyInvitePrompt
	return {
		"members": main.get("party_members"),
		"leader": main.get("party_leader"),
		"pending_from": prompt.pending_from if prompt != null else "",
		"lfg": main.get("lfg_board"),
	}
