extends GutTest

# T-048: NPC quest-giver marker logic — the indicator→style mapping (WoW convention) + the marker
# lifecycle (create / update / prune) driven by the server's npc_indicators payload.

const NpcMarker = preload("res://scripts/ui/npc_marker.gd")
const NpcMarkersLayer = preload("res://scripts/ui/npc_markers_layer.gd")
const ClientNet = preload("res://scripts/net/client_net.gd")
const HudHandlers = preload("res://scripts/net/hud_handlers.gd")


func test_marker_style_wow_convention() -> void:
	assert_eq(NpcMarker.marker_style("!")["symbol"], "!")
	assert_true(NpcMarker.marker_style("!")["visible"], "available → shown")
	assert_eq(NpcMarker.marker_style("?")["symbol"], "?")
	assert_true(NpcMarker.marker_style("?")["visible"], "turn-in ready → shown")
	assert_eq(NpcMarker.marker_style("?")["color"], NpcMarker.GOLD, "ready → gold")
	assert_false(NpcMarker.marker_style("")["visible"], "no quest → no marker")
	# T-056: grey ? — have the quest, objectives not done yet.
	assert_eq(NpcMarker.marker_style("?grey")["symbol"], "?")
	assert_eq(NpcMarker.marker_style("?grey")["color"], NpcMarker.GREY, "in progress → grey")
	assert_true(NpcMarker.marker_style("?grey")["visible"])
	assert_eq(NpcMarker.marker_style("!")["color"], NpcMarker.GOLD, "gold per WoW")
	# T-621: silver "!future" — a quest that unlocks in a few levels (visible promise).
	assert_eq(NpcMarker.marker_style("!future")["symbol"], "!", "future quest shows a !")
	assert_eq(NpcMarker.marker_style("!future")["color"], NpcMarker.SILVER, "future → silver")
	assert_true(NpcMarker.marker_style("!future")["visible"], "future promise is shown")
	assert_ne(NpcMarker.SILVER, NpcMarker.GOLD, "silver must read distinctly from takeable gold")


func test_marker_apply_sets_symbol_and_visibility() -> void:
	var m = NpcMarker.new()
	add_child_autofree(m)
	m.apply("!")
	assert_eq(m.get_symbol(), "!")
	assert_true(m.visible)
	m.apply("")
	assert_false(m.visible, "empty indicator hides the marker")


# ---- T-668: primary/tutorial marker is measurably larger, not just a color hint ----


func test_marker_style_scale_defaults_to_standard() -> void:
	assert_almost_eq(
		float(NpcMarker.marker_style("!")["scale"]),
		NpcMarker.STANDARD_MARKER_SCALE,
		0.001,
		"no npc_id → standard (non-primary) scale"
	)
	assert_almost_eq(float(NpcMarker.marker_style("?grey")["scale"]), 1.0, 0.001)
	assert_almost_eq(float(NpcMarker.marker_style("")["scale"]), 1.0, 0.001)


func test_marker_style_scale_bumps_the_tutorial_giver() -> void:
	var hale := NpcMarker.marker_style("!", "npc_drillmaster")
	assert_almost_eq(
		float(hale["scale"]),
		NpcMarker.PRIMARY_MARKER_SCALE,
		0.001,
		"tutorial giver marker uses the primary scale constant"
	)
	assert_gte(NpcMarker.PRIMARY_MARKER_SCALE, 1.4, "primary scale must be an unmistakable bump")


func test_marker_apply_scales_the_label_for_the_primary_giver() -> void:
	var m = NpcMarker.new()
	add_child_autofree(m)
	m.setup("npc_drillmaster", Vector2.ZERO)
	m.apply("!")
	assert_almost_eq(
		(m._label as Label).scale.x,
		NpcMarker.PRIMARY_MARKER_SCALE,
		0.001,
		"the on-screen label itself is scaled up for the tutorial giver"
	)


func test_pulse_scale_is_a_bounded_breathing_oscillation() -> void:
	assert_almost_eq(NpcMarker.pulse_scale(0.0), 1.0, 0.001, "pulse starts at rest scale")
	for i in range(50):
		var t := float(i) * 0.1
		var v := NpcMarker.pulse_scale(t)
		assert_true(
			(
				v >= 1.0 - NpcMarker.PULSE_AMPLITUDE - 0.001
				and v <= 1.0 + NpcMarker.PULSE_AMPLITUDE + 0.001
			),
			"pulse stays within +/-PULSE_AMPLITUDE of rest scale (t=%.1f, v=%.3f)" % [t, v]
		)


func test_layer_creates_positions_and_prunes_markers() -> void:
	var layer = NpcMarkersLayer.new()
	add_child_autofree(layer)
	(
		layer
		. update(
			[
				{
					"npc_id": "npc_drillmaster",
					"name": "Hale",
					"x": 10.0,
					"y": 10.0,
					"indicator": "!"
				},
				{"npc_id": "npc_courier", "name": "Bram", "x": 6.0, "y": 4.0, "indicator": ""},
			]
		)
	)
	assert_eq(layer.marker_count(), 2)
	assert_eq(layer.get_marker("npc_drillmaster").get_symbol(), "!")
	assert_eq(layer.get_marker("npc_drillmaster").position, Vector2(10.0, 10.0), "world position")
	assert_false(layer.get_marker("npc_courier").visible, "empty indicator hidden")

	# Refresh: drillmaster flips !→? (turn-in ready); courier drops out of the payload → pruned.
	layer.update(
		[{"npc_id": "npc_drillmaster", "name": "Hale", "x": 10.0, "y": 10.0, "indicator": "?"}]
	)
	assert_eq(layer.marker_count(), 1, "stale NPC pruned")
	assert_eq(layer.get_marker("npc_drillmaster").get_symbol(), "?")


func test_hud_handlers_routes_npc_indicators_to_layer() -> void:
	# The full path the live client uses: ClientNet routes a server npc_indicators message through
	# HudHandlers into the marker layer. (Other handlers are null here — only npc_indicators fires.)
	var layer = NpcMarkersLayer.new()
	add_child_autofree(layer)
	var net = ClientNet.new()
	net.setup(func(_m): pass, HudHandlers.build(null, null, null, layer))
	(
		net
		. handle_server_message(
			{
				"type": "npc_indicators",
				"npcs": [{"npc_id": "npc_drillmaster", "x": 10.0, "y": 10.0, "indicator": "!"}],
			}
		)
	)
	assert_eq(layer.marker_count(), 1)
	assert_eq(layer.get_marker("npc_drillmaster").get_symbol(), "!")


# ---- T-058: partial (targeted) marker updates ----


func test_apply_partial_updates_without_pruning() -> void:
	var layer := NpcMarkersLayer.new()
	add_child_autofree(layer)
	(
		layer
		. update(
			[
				{"npc_id": "npc_a", "x": 1.0, "y": 2.0, "indicator": "!"},
				{"npc_id": "npc_b", "x": 3.0, "y": 4.0, "indicator": ""},
			]
		)
	)
	layer.apply_partial([{"npc_id": "npc_a", "x": 1.0, "y": 2.0, "indicator": "?"}])
	assert_eq(layer.marker_count(), 2, "unlisted markers survive a partial update")
