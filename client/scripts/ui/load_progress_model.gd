class_name LoadProgressModel
# T-691: the PURE login-progress estimator behind the loading screen. Weighted phases (each phase
# owns a slice of the bar proportional to its EXPECTED duration), expectations learned per machine
# by an EWMA over past logins and persisted to user:// — so the second login on any box is already
# calibrated (SSD vs HDD, fast vs slow GPU all converge in 2-3 runs). Within a phase the fill runs
# on elapsed/expected, clamped to an asymptotic ceiling so an overrun CREEPS instead of stalling
# (Harrison CHI 2007/2010: a visibly stopped bar is the worst outcome available; never move
# backwards, never sit at a number). No scene/engine deps beyond ConfigFile — every timestamp is
# injected (now_ms), so the whole model is provable headless with synthetic timings.

extends RefCounted

const DEFAULT_PATH := "user://load_calibration.cfg"
# EWMA fold rate: expected <- ALPHA*observed + (1-ALPHA)*expected. ~3 logins to converge.
const ALPHA := 0.3
# Within-phase progress may never exceed this share of the phase's slice before the phase's end
# event lands — the end snaps it to 1.0, which doubles as the "accelerate into done" beat.
const PHASE_CEILING := 0.95
# Progress is linear in elapsed/expected up to the knee, then eases asymptotically to the ceiling.
const LINEAR_KNEE := 0.7
# Observed durations are clamped to sane bounds BEFORE the EWMA fold — one AFK login (or a laptop
# suspended mid-boot) must not poison the calibration (same guard shape as boot_clock.gd).
const MIN_OBSERVED_MS := 1.0
const MAX_OBSERVED_MS := 120000.0
# The canonical login phases, in boot order (the bus in load_phases.gd stamps these names). The
# seed durations are first-run defaults from a measured 2026-08-08 boot on the owner's machine
# (headless [loadphase] stamps: world 944 ms / props 3.8 s / populate 3.6 s / hud 73 ms), rounded
# up for live GPU upload + shader-compile cost — run #1 is sane, run #2 is calibrated.
const PHASES: Array = ["world", "props", "populate", "hud", "connect", "snapshot"]
const SEED_MS := {
	"world": 1500.0,
	"props": 4500.0,
	"populate": 4500.0,
	"hud": 400.0,
	"connect": 700.0,
	"snapshot": 700.0,
}

var _expected: Dictionary = {}  # phase -> learned expected duration (ms)
var _begun: Dictionary = {}  # phase -> begin timestamp (ms); first begin wins
var _ended: Dictionary = {}  # phase -> observed duration (ms); first end wins
var _items: Dictionary = {}  # phase -> real item fraction 0..1 (e.g. props placed / queued)
var _peak := 0.0  # monotonic latch — fraction() never reports below its own high-water mark


func _init() -> void:
	_expected = SEED_MS.duplicate()


func begin_phase(phase: String, now_ms: int) -> void:
	if not _expected.has(phase) or _begun.has(phase):
		return
	_begun[phase] = now_ms


func end_phase(phase: String, now_ms: int) -> void:
	if not _begun.has(phase) or _ended.has(phase):
		return
	var observed := clampf(float(now_ms - int(_begun[phase])), MIN_OBSERVED_MS, MAX_OBSERVED_MS)
	_ended[phase] = observed
	_expected[phase] = ALPHA * observed + (1.0 - ALPHA) * float(_expected[phase])


# Real intra-phase progress when the phase can count its work (T-688 queue: placed/queued props).
# Still ceiling-clamped — only the phase's end event may take its slice to 100%.
func set_items(phase: String, done: int, total: int) -> void:
	if not _expected.has(phase) or total <= 0:
		return
	_items[phase] = clampf(float(done) / float(total), 0.0, 1.0)


# Overall bar position in [0, 1]. Monotonic (never backwards); < 1.0 until every phase has ended.
func fraction(now_ms: int) -> float:
	var total := _expected_total()
	var sum := 0.0
	for phase: String in PHASES:
		sum += (float(_expected[phase]) / total) * _phase_progress(phase, now_ms)
	_peak = maxf(_peak, sum)
	return _peak


# Honest "about Ns remaining" from the remaining phases' expected durations. An overrunning phase
# contributes 0 (unknowable) rather than a number that counts up.
func eta_secs(now_ms: int) -> int:
	var remaining := 0.0
	for phase: String in PHASES:
		if _ended.has(phase):
			continue
		if _begun.has(phase):
			remaining += maxf(float(_expected[phase]) - float(now_ms - int(_begun[phase])), 0.0)
		else:
			remaining += float(_expected[phase])
	return int(ceil(remaining / 1000.0))


# True only when EVERY canonical phase has ended — the screen's dismiss gate. "populate" ends on
# the initial queue drain and "snapshot" on the first own-position row, so this is exactly the
# DoD's "no early dismiss into a half-built world".
func done() -> bool:
	for phase: String in PHASES:
		if not _ended.has(phase):
			return false
	return true


func expected_total_ms() -> float:
	return _expected_total()


# ---- calibration persistence (user://) -----------------------------------------------------


func save(path: String = DEFAULT_PATH) -> void:
	var cfg := ConfigFile.new()
	for phase: String in PHASES:
		cfg.set_value("expected_ms", phase, float(_expected[phase]))
	cfg.save(path)


func load_calibration(path: String = DEFAULT_PATH) -> void:
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return  # first run — the shipped seeds stand
	for phase: String in PHASES:
		var v := float(cfg.get_value("expected_ms", phase, 0.0))
		if v > 0.0:
			_expected[phase] = clampf(v, MIN_OBSERVED_MS, MAX_OBSERVED_MS)


# ---- internals -----------------------------------------------------------------------------


func _expected_total() -> float:
	var total := 0.0
	for phase: String in PHASES:
		total += float(_expected[phase])
	return maxf(total, 1.0)


func _phase_progress(phase: String, now_ms: int) -> float:
	if _ended.has(phase):
		return 1.0
	if not _begun.has(phase):
		return 0.0
	var ratio := float(now_ms - int(_begun[phase])) / maxf(float(_expected[phase]), 1.0)
	var eased := _ease(ratio)
	# Countable phases may run ahead of the clock (fast disk) — take the better signal, but the
	# ceiling still holds until the end event lands.
	return maxf(eased, minf(float(_items.get(phase, 0.0)), PHASE_CEILING))


# Linear to the knee, then an asymptotic ease toward PHASE_CEILING — continuous, strictly
# monotonic in elapsed time, and it NEVER reaches the ceiling, so an overrun keeps creeping.
static func _ease(ratio: float) -> float:
	var r := maxf(ratio, 0.0)
	if r <= LINEAR_KNEE:
		return r
	var span := PHASE_CEILING - LINEAR_KNEE
	return LINEAR_KNEE + span * (1.0 - exp(-(r - LINEAR_KNEE) / span))
