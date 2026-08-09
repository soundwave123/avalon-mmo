class_name GatherNodesLayer
extends Node3D

# T-414 (slice 3): renders the world's gather nodes from the read-only `gather_nodes` feed
# (craft_service._send_nodes) as clickable world markers — a small resource mote + a "Gather"
# billboard above it. Click a node → sends {type:gather, node_id}; the SERVER re-checks proximity,
# availability and the yield (item + count come from its registry, never the wire). Depleted nodes
# read dim + unclickable until the server's respawn flips them back on the next feed poll.
#
# Mirrors NpcWorldLayer (T-056): server (x, y) ground → Godot (x, terrain height, y) — T-445:
# render height derives from the shared TerrainField (the feed is planar); spawn on first sight,
# despawn when a node leaves the feed; click picking needs the viewport's physics_object_picking
# (main.gd enables it). T-440 maps the server-authored cosmetic kind to an existing textured prop;
# this layer still owns only FEED→marker + click→intent wiring.

const _POLL_SECONDS := 4.0  # re-poll cadence so depletion/respawn state stays fresh in the world
const _READY_HIGHLIGHT := Color(0.72, 0.86, 0.48, 0.08)
const _SPENT_HIGHLIGHT := Color(0.3, 0.3, 0.3, 0.03)
const _PROP_SPECS := {
	"herb":
	{
		"path": "res://assets/models/prop_bush_real_d.glb",
		"scale": 0.45,
		# Reused poppies supply Bloodthorn's sparse crimson blossom read without a new asset.
		"accent_path": "res://assets/models/prop_flora_poppy.glb",
		"accent_scale": 0.7,
		"accent_pos": Vector3(0.0, 0.08, 0.0),
	},
	"ore": {"path": "res://assets/models/prop_rock_moss_cluster_a.glb", "scale": 0.55},
	"timber": {"path": "res://assets/models/prop_deadfall_log.glb", "scale": 0.75},
	"fibre": {"path": "res://assets/models/prop_flora_nettle.glb", "scale": 0.9},
	"fishing": {"path": "res://assets/models/prop_reeds.glb", "scale": 0.8},
}

var _send_fn: Callable = Callable()
var _nodes: Dictionary = {}  # node_id -> body/label/visual/meshes/kind/available
var _poll_accum: float = 0.0
var _shimmer_phase: float = 0.0
# T-697 fix 8: ONE shimmer overlay material shared by every gather node — the per-frame pulse is
# a single alpha write instead of a per-node material sweep (depleted nodes are hidden whole, so
# a shared ready-tint can never show on a spent node).
var _shimmer_mat: StandardMaterial3D = null
# T-445: shared ground truth for the rolled meadow (untyped: TerrainField annotation breaks the
# cold headless parse, T-309).
var _terrain = preload("res://scripts/world/terrain_field.gd").new()


# main.gd wires this once: the transport (sends ride main._send_to_server) + the routed hub the
# layer self-registers the `gather_nodes` feed on (no per-type main.gd handler line).
func setup(send_fn: Callable, reply_router) -> void:
	_send_fn = send_fn
	if reply_router != null:
		reply_router.register("gather_nodes", func(d): update(d.get("nodes", [])))


# Poll the feed on a gentle cadence so newly-available (respawned) or freshly-depleted nodes update
# without any main.gd timer wiring. The send guards `_connected`, so this is a no-op while offline.
func _process(delta: float) -> void:
	_poll_accum += delta
	_shimmer_phase = fmod(_shimmer_phase + delta, TAU)
	# T-697 fix 8: one write pulses every node's shared overlay (was a per-node values() sweep).
	if _shimmer_mat != null and not _nodes.is_empty():
		_shimmer_mat.albedo_color.a = 0.055 + 0.025 * (0.5 + 0.5 * sin(_shimmer_phase * 1.7))
	if _poll_accum >= _POLL_SECONDS:
		_poll_accum = 0.0
		if _send_fn.is_valid():
			_send_fn.call({"type": "gather_nodes"})


# Upsert one marker per node from the feed; prune nodes that dropped out. Feed row shape:
#   {id, x, y, item_id, kind, display_name, available}
# A HARVESTED node (available=false) is hidden ENTIRELY — asset + name vanish until the server's
# respawn timer flips it back available on a later feed poll, so players roam for more instead of
# camping a spent node (report #16).
func update(nodes: Array) -> void:
	var seen: Dictionary = {}
	for node: Dictionary in nodes:
		var node_id := str(node.get("id", ""))
		if node_id == "":
			continue
		seen[node_id] = true
		var kind := _kind_for(node)
		var e := _ensure(node_id, _label_for(node), kind)
		var gx := float(node.get("x", 0.0))
		var gz := float(node.get("y", 0.0))
		(e["body"] as Node3D).position = Vector3(gx, _terrain.height(gx, gz), gz)
		var available := bool(node.get("available", true))
		e["available"] = available
		# Keep the label text fresh from the server-authored name (verb-free — just "Bloodthorn").
		(e["label"] as Label3D).text = _label_for(node)
		# Hide the whole marker (asset + billboard) while depleted; show it on respawn.
		(e["body"] as Node3D).visible = available
		for mesh: MeshInstance3D in e["meshes"]:
			mesh.transparency = 0.0
		var highlight := e["highlight"] as StandardMaterial3D
		highlight.albedo_color = _READY_HIGHLIGHT
		(e["label"] as Label3D).modulate = Color(0.85, 1.0, 0.8)
	for node_id: String in _nodes.keys():
		if not seen.has(node_id):
			_nodes[node_id]["body"].queue_free()
			_nodes.erase(node_id)


# The world label: server-authored display_name, falling back to a cleaned item name. NEVER carries
# the "Gather" interaction verb — that leaked into the billboard before (report #16).
func _label_for(node: Dictionary) -> String:
	var dn := str(node.get("display_name", "")).strip_edges()
	if dn != "":
		return dn
	var item_id := str(node.get("item_id", ""))
	return item_id.trim_prefix("itm_").replace("_", " ").strip_edges()


func _ensure(node_id: String, display_name: String, kind: String) -> Dictionary:
	if not _nodes.has(node_id):
		var body := StaticBody3D.new()
		body.name = "Node_%s" % node_id
		var prop := _make_prop(kind)
		body.add_child(prop["visual"])
		body.add_child(_make_collision())
		var label := _make_label(display_name)
		body.add_child(label)
		body.input_event.connect(func(_c, event, _p, _n, _s): _on_body_input(node_id, event))
		add_child(body)
		_nodes[node_id] = {
			"body": body,
			"label": label,
			"visual": prop["visual"],
			"meshes": prop["meshes"],
			"highlight": prop["highlight"],
			"prop_path": prop["prop_path"],
			"kind": kind,
			"available": true,
		}
	return _nodes[node_id]


func _kind_for(node: Dictionary) -> String:
	var explicit := str(node.get("kind", "")).to_lower()
	if _PROP_SPECS.has(explicit):
		return explicit
	var item_id := str(node.get("item_id", ""))
	if item_id.begins_with("itm_ore_"):
		return "ore"
	if item_id.begins_with("itm_timber_"):
		return "timber"
	if item_id.begins_with("itm_fibre_") or item_id.begins_with("itm_fiber_"):
		return "fibre"
	return "herb"


func _make_prop(kind: String) -> Dictionary:
	var spec: Dictionary = _PROP_SPECS.get(kind, _PROP_SPECS["herb"])
	var visual := Node3D.new()
	visual.name = "ResourceProp_%s" % kind.capitalize()
	var path := str(spec["path"])
	_instantiate_prop(path, float(spec.get("scale", 1.0)), Vector3.ZERO, visual)
	if spec.has("accent_path"):
		_instantiate_prop(
			str(spec["accent_path"]),
			float(spec.get("accent_scale", 1.0)),
			spec.get("accent_pos", Vector3.ZERO),
			visual
		)
	var meshes: Array[MeshInstance3D] = []
	for found in visual.find_children("*", "MeshInstance3D", true, false):
		meshes.append(found as MeshInstance3D)
	# T-697 fix 8: every node's meshes wear the SAME overlay material (built once, lazily).
	if _shimmer_mat == null:
		_shimmer_mat = StandardMaterial3D.new()
		_shimmer_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_shimmer_mat.albedo_color = _READY_HIGHLIGHT
		_shimmer_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for mesh: MeshInstance3D in meshes:
		mesh.material_overlay = _shimmer_mat
	return {"visual": visual, "meshes": meshes, "highlight": _shimmer_mat, "prop_path": path}


func _instantiate_prop(path: String, scale_factor: float, offset: Vector3, parent: Node3D) -> void:
	var scene := load(path) as PackedScene
	if scene == null:
		push_error("[gather] missing resource prop: %s" % path)
		return
	var model := scene.instantiate() as Node3D
	if model == null:
		push_error("[gather] resource prop root is not Node3D: %s" % path)
		return
	model.position = offset
	model.scale = Vector3.ONE * scale_factor
	parent.add_child(model)


func _make_collision() -> CollisionShape3D:
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.6, 0.9, 0.6)
	col.shape = shape
	col.position = Vector3(0.0, 0.45, 0.0)
	return col


func _make_label(display_name: String) -> Label3D:
	var label := Label3D.new()
	# The billboard shows ONLY the resource name (e.g. "Bloodthorn"); the "Gather" verb is the
	# click-to-interact prompt, not part of the name (report #16).
	label.text = display_name if display_name != "" else "Resource"
	label.position = Vector3(0.0, 1.1, 0.0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.pixel_size = 0.006
	label.font_size = 40
	label.outline_size = 8
	label.modulate = Color(0.85, 1.0, 0.8)
	return label


# Left-click an AVAILABLE node → gather intent (server re-checks proximity + availability + yield).
func _on_body_input(node_id: String, event: InputEvent) -> void:
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	if (event as InputEventMouseButton).button_index != MOUSE_BUTTON_LEFT:
		return
	if not bool(_nodes.get(node_id, {}).get("available", false)):
		return
	if _send_fn.is_valid():
		_send_fn.call({"type": "gather", "node_id": node_id})


func node_count() -> int:
	return _nodes.size()


func is_available(node_id: String) -> bool:
	return bool(_nodes.get(node_id, {}).get("available", false))


func node_position(node_id: String) -> Vector3:
	if not _nodes.has(node_id):
		return Vector3.ZERO
	return (_nodes[node_id]["body"] as Node3D).global_position
