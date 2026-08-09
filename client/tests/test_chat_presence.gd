extends "res://addons/gut/test.gd"
# T-396: ChatPresence — the pure fade/focus state machine behind the glanceable chat window.
# Deterministic, headless (no display, no OS time): the caller injects dt and events.

var _p: ChatPresence = null


func before_each() -> void:
	_p = ChatPresence.new()


func test_starts_idle_and_silent() -> void:
	# Nothing to show yet: the area targets invisible, the backdrop sits at the subtle gradient.
	assert_false(_p.is_awake(), "no line, no focus, no hover → asleep")
	assert_false(_p.is_interactive(), "idle never eats clicks")
	assert_eq(_p.area_target(), ChatPresence.AREA_IDLE_ALPHA)
	assert_eq(_p.bg_target(), ChatPresence.BG_IDLE_ALPHA)


func test_new_line_wakes_and_resets_the_timer() -> void:
	_p.notify_line()
	assert_true(_p.is_awake(), "a fresh line wakes the area")
	assert_eq(_p.area_alpha, ChatPresence.AREA_AWAKE_ALPHA, "the line snaps the panel visible")
	assert_eq(_p.area_target(), ChatPresence.AREA_AWAKE_ALPHA)
	# Still click-through — a recent line shows the panel but does not make it interactive.
	assert_false(_p.is_interactive())


func test_fades_out_after_the_idle_delay() -> void:
	_p.notify_line()
	assert_true(_p.is_awake())
	# Tick past the inactivity window with no new line.
	for i in range(int(ChatPresence.IDLE_FADE_DELAY) + 2):
		_p.tick(1.0)
	assert_false(_p.is_awake(), "silence past IDLE_FADE_DELAY lets the area fade")
	assert_eq(_p.area_target(), ChatPresence.AREA_IDLE_ALPHA)
	assert_lt(_p.area_alpha, 0.05, "area_alpha has lerped toward invisible")


func test_a_new_line_mid_fade_brings_it_back() -> void:
	_p.notify_line()
	for i in range(int(ChatPresence.IDLE_FADE_DELAY) + 2):
		_p.tick(1.0)
	assert_false(_p.is_awake())
	_p.notify_line()  # a new message
	assert_true(_p.is_awake(), "a new line revives the faded panel")
	assert_eq(_p.area_alpha, ChatPresence.AREA_AWAKE_ALPHA)


func test_focus_keeps_awake_and_ramps_the_backdrop() -> void:
	_p.set_focus(true)
	# Even after a long silence, focus holds the area open and interactive.
	for i in range(int(ChatPresence.IDLE_FADE_DELAY) + 5):
		_p.tick(1.0)
	assert_true(_p.is_awake(), "focus overrides the inactivity fade")
	assert_true(_p.is_interactive(), "an open input row eats clicks / allows scrolling")
	assert_eq(_p.bg_target(), ChatPresence.BG_FOCUS_ALPHA, "focus ramps the backdrop opacity up")
	assert_gt(_p.bg_alpha, ChatPresence.BG_IDLE_ALPHA, "bg_alpha has lerped toward the focus value")


func test_unfocus_drops_the_backdrop_back() -> void:
	_p.set_focus(true)
	_p.tick(1.0)
	_p.set_focus(false)
	assert_eq(_p.bg_target(), ChatPresence.BG_IDLE_ALPHA, "leaving focus drops the ramp")
	assert_false(_p.is_interactive())


func test_hover_ramps_and_makes_interactive() -> void:
	_p.set_hover(true)
	assert_true(_p.is_awake())
	assert_true(_p.is_interactive(), "hover restores normal filtering")
	assert_eq(_p.bg_target(), ChatPresence.BG_FOCUS_ALPHA)
	_p.set_hover(false)
	assert_false(_p.is_interactive())


func test_tick_lerps_toward_targets_never_overshoots() -> void:
	_p.set_focus(true)  # bg target = BG_FOCUS_ALPHA
	for i in range(200):
		_p.tick(0.1)
	assert_almost_eq(_p.bg_alpha, ChatPresence.BG_FOCUS_ALPHA, 0.001)
	assert_almost_eq(_p.area_alpha, ChatPresence.AREA_AWAKE_ALPHA, 0.001)
