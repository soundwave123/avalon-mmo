extends "res://addons/gut/test.gd"

# T-561: pure runtime-anomaly-sentinel tests. No network, no engine loop — every
# tick clock is injected. Proves the three detectors fire on their synthetic
# symptom sequences AND that a normal combat death stays silent.

const QaSentinel = preload("res://scripts/qa_sentinel.gd")

# Tight windows so the loop detector needs 3 deaths, not 60 real seconds.
const CONFIG := {
	"death_window_ticks": 1000,
	"death_count": 3,
	"death_radius": 5.0,
}


func _sentinel():
	return QaSentinel.new(CONFIG)


func _obs(
	pid: int, hp: int, pos: Vector3, in_combat: bool, attacked: bool, src_recorded: bool
) -> Dictionary:
	return {
		"pid": pid,
		"hp": hp,
		"max_hp": 100,
		"pos": pos,
		"in_combat": in_combat,
		"attacked_by_mob": attacked,
		"damage_source_recorded": src_recorded,
	}


func _reasons(anomalies: Array) -> Array:
	var out: Array = []
	for a in anomalies:
		out.append(a["reason"])
	return out


# --- (a) idle HP-drain: the effigy / drowning symptom ---


func test_idle_hp_drain_fires_and_dedupes() -> void:
	var s = _sentinel()
	var origin := Vector3.ZERO
	# Baseline tick establishes history; returns nothing.
	assert_eq(s.observe(100, [_obs(1, 100, origin, false, false, true)]).size(), 0)

	# HP falls while alive, out of combat, un-targeted, stationary -> fires once.
	var first = s.observe(110, [_obs(1, 95, origin, false, false, false)])
	assert_eq(_reasons(first), ["idle_hp_drain"], "idle HP-drain must fire")
	assert_eq(first[0]["pid"], 1)

	# Still draining, same conditions -> DEDUPED (latched), no second line.
	var second = s.observe(120, [_obs(1, 90, origin, false, false, false)])
	assert_eq(second.size(), 0, "persistent drain must dedupe to one line")

	# HP stops falling -> latch re-arms; a fresh drain fires again.
	assert_eq(s.observe(130, [_obs(1, 90, origin, false, false, false)]).size(), 0)
	var rearmed = s.observe(140, [_obs(1, 85, origin, false, false, false)])
	assert_eq(_reasons(rearmed), ["idle_hp_drain"], "latch must re-arm after drain clears")


func test_hp_drain_while_moving_does_not_fire() -> void:
	var s = _sentinel()
	assert_eq(s.observe(100, [_obs(1, 100, Vector3.ZERO, false, false, true)]).size(), 0)
	# Same HP loss but the player walked several metres -> environmental / normal, silent.
	var moved = s.observe(110, [_obs(1, 95, Vector3(3, 0, 0), false, false, false)])
	assert_eq(moved.size(), 0, "a moving player losing HP is not an idle drain")


func test_hp_drain_while_targeted_does_not_fire() -> void:
	var s = _sentinel()
	assert_eq(s.observe(100, [_obs(1, 100, Vector3.ZERO, false, false, true)]).size(), 0)
	# A mob is on us -> the HP loss is explained, not anomalous.
	var targeted = s.observe(110, [_obs(1, 95, Vector3.ZERO, false, true, true)])
	assert_eq(targeted.size(), 0, "a targeted player losing HP is not an idle drain")


# --- (b) death-loop / spawn-trap ---


func test_death_loop_fires_on_third_death() -> void:
	var s = _sentinel()
	var trap := Vector3(10, 0, 10)
	# Three alive->dead transitions near one spot inside the window (deaths are
	# combat-attributed so ONLY the loop detector can fire).
	assert_eq(s.observe(0, [_obs(1, 100, trap, true, true, true)]).size(), 0)
	assert_eq(_reasons(s.observe(10, [_obs(1, 0, trap, true, true, true)])), [])  # death 1
	assert_eq(s.observe(20, [_obs(1, 100, trap, true, true, true)]).size(), 0)  # respawn
	assert_eq(_reasons(s.observe(30, [_obs(1, 0, trap, true, true, true)])), [])  # death 2
	assert_eq(s.observe(40, [_obs(1, 100, trap, true, true, true)]).size(), 0)  # respawn
	var third = s.observe(50, [_obs(1, 0, trap, true, true, true)])  # death 3
	assert_eq(_reasons(third), ["death_loop"], "3 deaths near one spot must fire death_loop")
	assert_eq(third[0]["detail"]["deaths"], 3)


func test_scattered_deaths_do_not_fire() -> void:
	var s = _sentinel()
	# Three deaths, but each far apart -> not a spawn trap.
	assert_eq(s.observe(0, [_obs(1, 100, Vector3(0, 0, 0), true, true, true)]).size(), 0)
	s.observe(10, [_obs(1, 0, Vector3(0, 0, 0), true, true, true)])
	s.observe(20, [_obs(1, 100, Vector3(50, 0, 0), true, true, true)])
	s.observe(30, [_obs(1, 0, Vector3(50, 0, 0), true, true, true)])
	s.observe(40, [_obs(1, 100, Vector3(100, 0, 0), true, true, true)])
	var third = s.observe(50, [_obs(1, 0, Vector3(100, 0, 0), true, true, true)])
	assert_eq(third.size(), 0, "deaths spread across the map are not a death loop")


# --- (c) unattributed death vs a normal combat death ---


func test_unattributed_death_fires() -> void:
	var s = _sentinel()
	assert_eq(s.observe(100, [_obs(1, 100, Vector3.ZERO, false, false, true)]).size(), 0)
	# HP hits 0 with no source, no attacker, not in combat -> unattributed.
	var death = s.observe(110, [_obs(1, 0, Vector3.ZERO, false, false, false)])
	assert_eq(_reasons(death), ["unattributed_death"], "sourceless death must fire")


func test_normal_combat_death_is_silent() -> void:
	var s = _sentinel()
	assert_eq(s.observe(100, [_obs(1, 100, Vector3.ZERO, true, true, true)]).size(), 0)
	# HP hits 0 in combat, targeted, with a recorded source -> expected, NO anomaly.
	var death = s.observe(110, [_obs(1, 0, Vector3.ZERO, true, true, true)])
	assert_eq(death.size(), 0, "a normal combat death must not fire any detector")


# --- render format ---


func test_format_line_carries_reason_player_and_pos() -> void:
	var s = _sentinel()
	var line: String = s.format_line(
		{"reason": "idle_hp_drain", "pid": 7, "pos": Vector3(1, 2, 3), "detail": {"hp": 42}}
	)
	assert_string_contains(line, "[qa-anomaly]")
	assert_string_contains(line, "reason=idle_hp_drain")
	assert_string_contains(line, "player=7")
	assert_string_contains(line, "pos=(1.00,2.00,3.00)")
