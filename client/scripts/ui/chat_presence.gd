class_name ChatPresence
# T-396: the pure fade/focus state machine behind the glanceable chat window. No OS time, no nodes —
# the caller (ChatPanel) injects dt and feeds events (a new line arrived, focus gained/lost, mouse
# entered/left), then reads back two alphas the panel applies to its nodes each frame:
#   area_alpha — the whole chat area's modulate.a. Rides high while awake (a recent line, focus, or
#                hover) and fades toward invisible after IDLE_FADE_DELAY of silence. This is the
#                "glanceable, never blocking" behaviour.
#   bg_alpha   — the dark backdrop's own alpha. Sits at a subtle gradient strength when idle and
#                ramps toward a comfortable read/type strength while focused or hovered.
# Modelled on the pure-tick module idiom (npc_wander/critter_wander): deterministic, dt-scaled,
# unit-testable headlessly with no display.

extends RefCounted

# --- timing / target constants (seconds; alphas 0..1) ---------------------
const IDLE_FADE_DELAY := 10.0  # silence before the area starts fading out
const AREA_FADE_SPEED := 4.0  # per-second lerp rate of area_alpha toward its target
const BG_FADE_SPEED := 6.0  # per-second lerp rate of bg_alpha toward its target
const AREA_IDLE_ALPHA := 0.0  # fully faded once idle AND silent
const AREA_AWAKE_ALPHA := 1.0  # readable while awake
const BG_IDLE_ALPHA := 0.28  # subtle bottom-weighted gradient — no box (reference model ~25-30%)
const BG_FOCUS_ALPHA := 0.65  # comfortable read/type backdrop while focused or hovered

var area_alpha := AREA_IDLE_ALPHA
var bg_alpha := BG_IDLE_ALPHA
var _since_line := IDLE_FADE_DELAY + 1.0  # start silent (nothing to show yet)
var _focused := false
var _hovered := false


# A new chat line landed: reset the silence timer and snap the area visible so the line never
# arrives mid-fade below legibility.
func notify_line() -> void:
	_since_line = 0.0
	area_alpha = AREA_AWAKE_ALPHA


func set_focus(v: bool) -> void:
	_focused = v
	if v:
		area_alpha = AREA_AWAKE_ALPHA  # summoning the input snaps the panel in immediately


func set_hover(v: bool) -> void:
	_hovered = v


func is_focused() -> bool:
	return _focused


func is_hovered() -> bool:
	return _hovered


# Interactive = the panel must eat clicks / allow scrolling. A recent line keeps the area VISIBLE
# but still click-through; only focus or hover makes it interactive.
func is_interactive() -> bool:
	return _focused or _hovered


# Awake = the area should be shown at all (recent line, focus, or hover).
func is_awake() -> bool:
	return _focused or _hovered or _since_line < IDLE_FADE_DELAY


func area_target() -> float:
	return AREA_AWAKE_ALPHA if is_awake() else AREA_IDLE_ALPHA


func bg_target() -> float:
	return BG_FOCUS_ALPHA if is_interactive() else BG_IDLE_ALPHA


# Advance the fade one frame. Caller injects dt (seconds).
func tick(dt: float) -> void:
	_since_line += dt
	area_alpha = _approach(area_alpha, area_target(), AREA_FADE_SPEED * dt)
	bg_alpha = _approach(bg_alpha, bg_target(), BG_FADE_SPEED * dt)


static func _approach(cur: float, target: float, step: float) -> float:
	if cur < target:
		return minf(cur + step, target)
	return maxf(cur - step, target)
