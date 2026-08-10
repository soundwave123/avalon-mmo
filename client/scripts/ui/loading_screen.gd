# T-691: the login loading screen — a code-built full-screen view (no .tscn; same idiom as
# gateway_login.gd) shown from auth until the world is playable. Owns a LoadProgressModel fed by
# the LoadPhases bus, so the bar is driven by calibrated elapsed-vs-expected per phase, never a
# fake linear crawl. The fill carries an animated shimmer sweep (Harrison CHI 2010: motion texture
# is worth ~11% of perceived duration for free) plus a phase status line and an honest ETA.
# Dismisses ONLY when every phase has ended — which includes the initial-populate queue drain and
# the first own-position snapshot — so the player never sees the half-dressed world behind it.

extends Control

const UiTheme = preload("res://scripts/ui/ui_theme.gd")
const LoadProgressModel = preload("res://scripts/ui/load_progress_model.gd")
# T-705 idiom: preloaded, not referenced by class_name (the s26 import-cache trap — a source-run
# client's global class cache can lag a new script).
const LoadPhases = preload("res://scripts/ui/load_phases.gd")

const FADE_SECS := 0.45
const SHIMMER_PERIOD := 1.3  # one sweep across the trough per period
const SHIMMER_WIDTH := 90.0
const BAR_SIZE := Vector2(520.0, 26.0)
# The status line names the current phase — the line that turns "did it freeze?" into "working".
const LABELS := {
	"world": "Shaping the land…",
	"terrain": "Raising the hills of the Wold…",
	"props": "Carving the villages…",
	"populate": "Dressing the realm…",
	"hud": "Lighting the hearths…",
	"connect": "Reaching the realm…",
	"snapshot": "Entering the world…",
}

var _model: LoadProgressModel = LoadProgressModel.new()
var _bar: ProgressBar = null
var _status: Label = null
var _eta: Label = null
var _shimmer: ColorRect = null
var _shim_t := 0.0
var _dismissed := false


func _ready() -> void:
	_model.load_calibration()
	_build_view()
	LoadPhases.add_listener(_on_phase_event)


func _exit_tree() -> void:
	LoadPhases.remove_listener(_on_phase_event)


func _on_phase_event(kind: String, phase: String, data: Dictionary) -> void:
	var now := Time.get_ticks_msec()
	match kind:
		"begin":
			_model.begin_phase(phase, now)
			if _status != null and LABELS.has(phase):
				_status.text = str(LABELS[phase])
		"end":
			_model.end_phase(phase, now)
		"progress":
			_model.set_items(phase, int(data.get("done", 0)), int(data.get("total", 0)))
		"reset":
			# A new login sequence superseded this screen (T-511 reconnect) — get out of the way,
			# and do NOT fold this aborted run's timings into the calibration.
			_dismiss(false)


func _process(delta: float) -> void:
	if _dismissed:
		return
	var now := Time.get_ticks_msec()
	_bar.value = _model.fraction(now) * 100.0
	var secs := _model.eta_secs(now)
	_eta.text = "about %ds remaining" % secs if secs > 0 else "almost there…"
	# The shimmer sweeps the FILLED width only — motion that tracks real progress, never a fake.
	_shim_t = fmod(_shim_t + delta, SHIMMER_PERIOD)
	var filled := _bar.size.x * float(_bar.value) / 100.0
	_shimmer.visible = filled > 1.0
	_shimmer.position.x = (_shim_t / SHIMMER_PERIOD) * filled - SHIMMER_WIDTH
	_shimmer.size = Vector2(minf(SHIMMER_WIDTH, filled), _bar.size.y)
	if _model.done():
		_dismiss()


func _dismiss(save := true) -> void:
	if _dismissed:
		return
	_dismissed = true
	if save:
		_model.save()  # fold this login's observed timings into the persisted calibration
	# T-748: this flipped the ROOT only, but the opaque full-rect `Backdrop` ColorRect underneath it
	# is default-STOP and stays in the tree for the whole FADE_SECS fade — so for 0.45s after the
	# world became playable, every click on screen still died on a screen the player can already see
	# through. Cascade so the whole overlay goes click-through at once (ui_theme.gd recipe a).
	UiTheme.set_mouse_filter_deep(self)  # the world is playable — stop eating clicks now
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, FADE_SECS)
	tween.tween_callback(queue_free)


func _build_view() -> void:
	theme = UiTheme.build()
	mouse_filter = Control.MOUSE_FILTER_STOP  # nothing behind this is ready for input yet
	z_index = 150  # under GatewayLogin's 200 (already freed by now), over everything else
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var backdrop := ColorRect.new()
	backdrop.name = "Backdrop"
	backdrop.color = Color(0.02, 0.025, 0.04, 1.0)  # OPAQUE — it hides the half-built world
	add_child(backdrop)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)

	var column := VBoxContainer.new()
	column.name = "Column"
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", 14)
	add_child(column)
	column.set_anchors_preset(Control.PRESET_CENTER)
	column.anchor_left = 0.5
	column.anchor_right = 0.5
	column.offset_left = -BAR_SIZE.x * 0.5
	column.offset_right = BAR_SIZE.x * 0.5

	var title := Label.new()
	title.name = "Title"
	title.text = "AVALON"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 54)
	title.add_theme_color_override("font_color", UiTheme.GOLD_BRIGHT)
	column.add_child(title)

	_status = Label.new()
	_status.name = "Status"
	_status.text = "Entering the realm…"
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.add_theme_color_override("font_color", UiTheme.PARCHMENT)
	column.add_child(_status)

	_bar = ProgressBar.new()
	_bar.name = "Bar"
	_bar.custom_minimum_size = BAR_SIZE
	_bar.min_value = 0.0
	_bar.max_value = 100.0
	_bar.show_percentage = false
	_bar.clip_contents = true
	var trough := StyleBoxFlat.new()
	trough.bg_color = UiTheme.IRON_MID
	trough.border_color = UiTheme.BRONZE
	trough.set_border_width_all(2)
	var fill := StyleBoxFlat.new()
	fill.bg_color = UiTheme.GOLD
	_bar.add_theme_stylebox_override("background", trough)
	_bar.add_theme_stylebox_override("fill", fill)
	column.add_child(_bar)

	_shimmer = ColorRect.new()
	_shimmer.name = "Shimmer"
	_shimmer.color = Color(1.0, 0.95, 0.8, 0.22)
	_shimmer.visible = false
	_shimmer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar.add_child(_shimmer)

	_eta = Label.new()
	_eta.name = "Eta"
	_eta.text = ""
	_eta.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_eta.add_theme_color_override("font_color", UiTheme.PARCHMENT_DIM)
	column.add_child(_eta)


# T-494 idiom (gateway_login.gd): while the loading gate is up, swallow any key the HUD's world
# hotkeys would otherwise catch — panels must not open under the overlay mid-load.
func _unhandled_key_input(event: InputEvent) -> void:
	if visible and not _dismissed and event is InputEventKey:
		get_viewport().set_input_as_handled()
