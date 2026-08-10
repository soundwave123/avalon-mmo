class_name UiViewport
# T-747: the single authority on the two coordinate spaces UI stretch introduced.
#
# project.godot now declares `window/stretch/mode="canvas_items"` with a 1280x720 content base and
# a 1920x1080 window override. That splits what used to be one space into two, and mixing them is
# silent — nothing errors, clicks just land at 2/3 of where they were aimed. Measured on Godot
# 4.7.1 (headless probe, window 1920x1080 / base 1280x720, stretch factor 1.5):
#
#   CONTENT space (1280x720)                    WINDOW space (1920x1080)
#   ------------------------                    ------------------------
#   Control.get_global_rect()                   Window.size / Viewport.size
#   Viewport.get_visible_rect()                 DisplayServer.window_get_size()
#   Camera3D.unproject_position()               Input.parse_input_event() event positions
#   Camera3D.project_ray_origin/normal()        Viewport.get_texture().get_image() (screenshots)
#   InputEvent positions DELIVERED to Controls  Input.warp_mouse()
#
# The asymmetry that bites: an event position you SEND through Input.parse_input_event is window
# space (Godot applies the inverse stretch on the way in), but the same event as DELIVERED to a
# Control is content space. Proof — pushing (640,360), the content centre, through
# Input.parse_input_event arrives at a Control as (426.7,240); pushing the window centre (960,540)
# arrives as (640,360). So any position derived from unproject_position or get_global_rect() MUST
# go through content_to_window() before it is injected, and any position read off a SCREENSHOT
# must go through window_to_content() before it is fed to a camera ray.
#
# Viewport.get_final_transform() is exactly the content->window map (it is the stretch transform
# composed with the global canvas transform), so both helpers are one multiply and stay correct
# for every window size, aspect and content_scale_factor without re-deriving a ratio by hand.

extends RefCounted


# The authored content base straight from project settings — never a literal. Everything that used
# to hardcode 1280x720 (or, wrongly, 1920x1080) should read this, so a future base change is one
# project.godot edit and not a repo-wide grep.
static func base_size() -> Vector2:
	return Vector2(
		float(ProjectSettings.get_setting("display/window/size/viewport_width", 1280)),
		float(ProjectSettings.get_setting("display/window/size/viewport_height", 720)),
	)


# The OS window size the shipped client opens at: the override when set, else the base (Godot's
# own rule — an override of 0 means "use the viewport size").
static func window_size() -> Vector2i:
	var w := int(ProjectSettings.get_setting("display/window/size/window_width_override", 0))
	var h := int(ProjectSettings.get_setting("display/window/size/window_height_override", 0))
	var base := base_size()
	if w <= 0:
		w = int(base.x)
	if h <= 0:
		h = int(base.y)
	return Vector2i(w, h)


# CONTENT -> WINDOW. Use before Input.parse_input_event / Input.warp_mouse / comparing against
# screenshot pixels.
static func content_to_window(vp: Viewport, pos: Vector2) -> Vector2:
	if vp == null:
		return pos
	return vp.get_final_transform() * pos


# WINDOW -> CONTENT. Use on any coordinate read off a screenshot before handing it to a camera
# ray, a Control rect comparison, or anything else in content space.
static func window_to_content(vp: Viewport, pos: Vector2) -> Vector2:
	if vp == null:
		return pos
	return vp.get_final_transform().affine_inverse() * pos


# The live content->window scale (uniform under canvas_items). 1.0 means the two spaces coincide,
# which is the case whenever the window is pinned to the base — e.g. the pilot's default
# AVALON_PILOT_RESOLUTION=1280x720. Reported in pilot acks so a caller can convert offline.
static func content_scale(vp: Viewport) -> float:
	if vp == null:
		return 1.0
	return vp.get_final_transform().get_scale().x


# A HEADLESS window boots degenerate — measured 64x64, because the project's window size is never
# applied without a display. Under stretch that is worse than it looks: `expand` resolves the
# content against the window's ASPECT, so a 64x64 window yields a 1280x1280 content rect, not the
# authored 1280x720, and every anchored panel lays out against a square screen.
#
# Normalising the root window to the shipped override (1920x1080) restores the content rect to
# exactly the authored base — verified: root.size=(64,64) -> visible=(1280,1280), then
# root.size=(1920,1080) -> visible=(1280,720) with final_transform scale 1.5. This is what lets
# headless tests and the headless pilot exercise the REAL base instead of a fake one.
#
# Returns true if it changed anything. Safe to call repeatedly and on a real display (no-op).
static func normalize_headless(vp_owner: Node) -> bool:
	if vp_owner == null or not vp_owner.is_inside_tree():
		return false
	var win := vp_owner.get_tree().root
	if win == null or win.size.x >= 320:
		return false
	win.size = window_size()
	return true
