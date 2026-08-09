class_name NpcMarker
extends Node2D

# T-048: a quest-giver indicator that sits above an NPC at its world position. WoW convention —
# gold "!" = quest available, gold "?" = turn-in ready. (Silver level-gated/in-progress + blue
# repeatable are future states, easy to add to marker_style.) The server's npc_indicators emits
# "!" / "?" / "". World-space (Node2D + a Label child); renders once the client has a world camera.

const GOLD := Color(1.0, 0.82, 0.0)
const GREY := Color(0.62, 0.62, 0.62)  # "grey": you have the quest, objectives not done yet
# T-621: silver "!future" — a quest that unlocks in a few levels (WoW's visible-promise wayfinding).
# A cool desaturated steel so it reads as "not yet" against the hot gold of a takeable quest.
const SILVER := Color(0.75, 0.80, 0.88)
# T-668: the T-664 BRIGHT_GOLD was only a ~12% channel shift off standard GOLD — read as identical
# at a glance. Pushed to max saturation/brightness within the gold family (near-white-hot) so the
# tutorial giver is unmistakable, not just faintly warmer.
const BRIGHT_GOLD := Color(1.0, 1.0, 0.25)

# T-668: primary/tutorial marker renders visibly larger than a standard quest-giver marker — a new
# player should instantly see which "!" to approach, not have to compare hues.
const PRIMARY_MARKER_SCALE := 1.45
const STANDARD_MARKER_SCALE := 1.0
# T-668: gentle "alive" breathing pulse on the primary marker only (amplitude keeps it readable,
# not distracting). Pure sinusoid so it's unit-testable without a running SceneTree/timer.
const PULSE_AMPLITUDE := 0.12
const PULSE_RATE := 2.4  # rad/s ≈ 2.6s per full breath

var npc_id: String = ""
var _is_primary_giver: bool = false
var _label: Label = null


func _init() -> void:
	_label = Label.new()
	_label.position = Vector2(-4.0, -28.0)  # offset above the NPC
	add_child(_label)


func setup(p_npc_id: String, world_pos: Vector2) -> void:
	npc_id = p_npc_id
	_is_primary_giver = _is_tutorial_giver(npc_id)
	position = world_pos


func apply(indicator: String) -> void:
	var style := marker_style(indicator, npc_id)
	_label.text = style["symbol"]
	_label.modulate = style["color"]
	_label.scale = Vector2.ONE * float(style["scale"])  # T-668: primary marker renders larger
	visible = style["visible"]


func get_symbol() -> String:
	return _label.text


# Pure mapping (server indicator string → on-screen style). Unit-tested without a tree.
# T-664: npc_id lets the tutorial giver render PRIMARY over side quest-givers. T-668: "scale" makes
# that primary status a SIZE delta too, not just a color hint.
static func marker_style(indicator: String, npc_id: String = "") -> Dictionary:
	var is_primary: bool = _is_tutorial_giver(npc_id)
	var scale: float = PRIMARY_MARKER_SCALE if is_primary else STANDARD_MARKER_SCALE
	match indicator:
		"!":
			return {
				"symbol": "!",
				"color": BRIGHT_GOLD if is_primary else GOLD,
				"visible": true,
				"scale": scale
			}
		"?":
			return {
				"symbol": "?",
				"color": BRIGHT_GOLD if is_primary else GOLD,
				"visible": true,
				"scale": scale
			}
		"?grey":
			return {"symbol": "?", "color": GREY, "visible": true, "scale": STANDARD_MARKER_SCALE}
		"!future":  # T-621: silver ! — available in a few levels (never the primary/tutorial giver)
			return {"symbol": "!", "color": SILVER, "visible": true, "scale": STANDARD_MARKER_SCALE}
		_:
			return {"symbol": "", "color": GOLD, "visible": false, "scale": STANDARD_MARKER_SCALE}


# T-664: NPC IDs that own the guided tutorial chain render with PRIMARY marker style.
static func _is_tutorial_giver(npc_id: String) -> bool:
	return npc_id == "npc_drillmaster"


# T-668: pure breathing-pulse multiplier for the primary marker's scale, sampled with the running
# clock (seconds). 1.0 at t=0, oscillates within +/-PULSE_AMPLITUDE — deterministic and
# unit-testable without a live timer/tree.
static func pulse_scale(t_sec: float) -> float:
	return 1.0 + PULSE_AMPLITUDE * sin(t_sec * PULSE_RATE)
