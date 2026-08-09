extends GutTest
# T-528: the first-session hook funnel aggregation. Pure math against synthetic T-186 traces —
# per-stage completeness + monotonic timings, and cohort %-reached / median against a known fixture.
# Also proves the new kill / level_up emission and that rollup() reads only via the injected query.

const Funnel = preload("res://scripts/first_session_funnel.gd")
const TelemetryStore = preload("res://scripts/telemetry_store.gd")


func _ev(t: String, ts: float, acct := "hero") -> Dictionary:
	return {"account": acct, "event_type": t, "ts": ts}


# --- per-account first_session -------------------------------------------------


func test_first_session_stages_are_timestamped_from_entry_and_monotonic() -> void:
	var events := [
		_ev("session_start", 100.0),
		_ev("kill", 130.0),
		_ev("level_up", 160.0),
		_ev("session_end", 300.0),
	]
	var rec := Funnel.first_session(events)
	assert_true(bool(rec["reached_entry"]), "entry reached")
	assert_eq(float(rec["times"]["world_entry"]), 0.0, "entry is the anchor")
	assert_eq(float(rec["times"]["first_kill"]), 30.0, "time-to-first-kill from entry")
	assert_eq(float(rec["times"]["first_level_up"]), 60.0, "time-to-first-levelup from entry")
	assert_true(
		(
			float(rec["times"]["world_entry"]) <= float(rec["times"]["first_kill"])
			and float(rec["times"]["first_kill"]) <= float(rec["times"]["first_level_up"])
		),
		"stage times are monotonic",
	)
	assert_eq(str(rec["drop_stage"]), "first_level_up", "furthest stage reached")
	assert_true(bool(rec["ended"]), "session_end seen")


func test_unreached_stages_are_marked() -> void:
	var rec := Funnel.first_session(
		[_ev("session_start", 200.0), _ev("kill", 225.0), _ev("session_end", 260.0)]
	)
	assert_false(bool(rec["reached"]["first_level_up"]), "no level-up this session")
	assert_eq(float(rec["times"]["first_level_up"]), -1.0, "unreached stage has no time")
	assert_eq(str(rec["drop_stage"]), "first_kill", "dropped at first_kill")


func test_only_the_first_session_counts() -> void:
	# A second session's kill must NOT back-fill the (kill-less) first session.
	var rec := (
		Funnel
		. first_session(
			[
				_ev("session_start", 10.0),
				_ev("session_end", 20.0),
				_ev("session_start", 1000.0),
				_ev("kill", 1010.0),
			]
		)
	)
	assert_false(bool(rec["reached"]["first_kill"]), "kill belongs to the 2nd session")
	assert_eq(str(rec["drop_stage"]), "world_entry", "first session dropped at entry")


func test_no_entry_is_not_a_cohort_member() -> void:
	var rec := Funnel.first_session([_ev("kill", 5.0)])
	assert_false(bool(rec["reached_entry"]), "no session_start -> not counted")


# --- cohort rollup -------------------------------------------------------------


# T-705: the fixture carries the reward beats the funnel gained (quest/loot/equip/turn-in) so the
# drop-off assertions below still describe what they were written to describe — the earliest
# ONE-player drop. Without them every new stage would read as a 2-3 player cliff.
func _cohort_events() -> Array:
	return [
		# A: full funnel
		_ev("session_start", 100.0, "A"),
		_ev("quest_accept", 110.0, "A"),
		_ev("kill", 130.0, "A"),
		_ev("loot", 131.0, "A"),
		_ev("level_up", 160.0, "A"),
		_ev("equip", 170.0, "A"),
		_ev("quest_turn_in", 180.0, "A"),
		_ev("session_end", 300.0, "A"),
		# B: kill, no level-up
		_ev("session_start", 200.0, "B"),
		_ev("quest_accept", 210.0, "B"),
		_ev("kill", 225.0, "B"),
		_ev("loot", 226.0, "B"),
		_ev("session_end", 260.0, "B"),
		# C: entry + quest only
		_ev("session_start", 50.0, "C"),
		_ev("quest_accept", 55.0, "C"),
		_ev("session_end", 70.0, "C"),
	]


func test_cohort_rollup_math_against_known_fixture() -> void:
	var out := Funnel.cohort_rollup(_cohort_events())
	assert_eq(int(out["cohort_size"]), 3, "three new accounts")
	var by_stage := {}
	for s: Dictionary in out["stages"]:
		by_stage[str(s["stage"])] = s
	assert_eq(int(by_stage["world_entry"]["reached"]), 3)
	assert_eq(float(by_stage["world_entry"]["pct_reached"]), 100.0)
	assert_eq(int(by_stage["first_kill"]["reached"]), 2, "A and B killed")
	assert_almost_eq(float(by_stage["first_kill"]["pct_reached"]), 66.7, 0.1)
	assert_eq(float(by_stage["first_kill"]["median_seconds"]), 27.5, "median of [25,30]")
	assert_eq(int(by_stage["first_level_up"]["reached"]), 1, "only A leveled")
	assert_eq(float(by_stage["first_level_up"]["median_seconds"]), 60.0)


func test_cohort_flags_the_largest_drop_off() -> void:
	var out := Funnel.cohort_rollup(_cohort_events())
	assert_eq(str(out["biggest_drop_stage"]), "first_kill", "earliest 1-player drop wins the flag")
	assert_eq(int(out["biggest_drop_count"]), 1)
	assert_eq(int(out["last_event_counts"]["session_end"]), 3, "all three sessions ended cleanly")


func test_empty_cohort_is_safe() -> void:
	var out := Funnel.cohort_rollup([])
	assert_eq(int(out["cohort_size"]), 0)
	assert_eq(str(out["biggest_drop_stage"]), "")
	assert_eq(float(out["stages"][0]["pct_reached"]), 0.0, "no divide-by-zero")


# --- impure seam: rollup() reads only via the injected query --------------------


func test_rollup_maps_query_rows_and_never_writes() -> void:
	var captured := {}
	var stub := func(sql: String, params: Array) -> Array:
		captured["sql"] = sql
		captured["params"] = params
		return [
			{"account": "A", "event_type": "session_start", "ts": "100"},
			{"account": "A", "event_type": "kill", "ts": "130"},
		]
	var reply := Funnel.rollup({"days": 7}, stub)
	assert_true(bool(reply["ok"]))
	assert_eq(int(reply["result"]["cohort_size"]), 1, "one account from the stubbed rows")
	assert_eq(int(reply["result"]["window_days"]), 7, "window echoed")
	assert_eq(int(captured["params"][1]), 7, "days passed to the query")
	assert_true(str(captured["sql"]).begins_with("SELECT"), "read-only: SELECT, never INSERT")


# --- new server-authoritative emission -----------------------------------------


func test_record_kill_funnel_emits_kill_and_level_up() -> void:
	TelemetryStore.reset_for_test()
	TelemetryStore.record_kill_funnel("hero", "wolf", {"leveled_up": true, "level": 4})
	var events := TelemetryStore.test_events()
	assert_eq(events.size(), 2, "kill + level_up on a ding")
	assert_eq(str(events[0]["event_type"]), "kill")
	assert_eq(str(events[1]["event_type"]), "level_up")
	assert_eq(int(events[1]["payload"]["level"]), 4)


func test_record_kill_funnel_kill_only_without_ding() -> void:
	TelemetryStore.reset_for_test()
	TelemetryStore.record_kill_funnel("hero", "rat", {"leveled_up": false})
	var events := TelemetryStore.test_events()
	assert_eq(events.size(), 1, "no ding -> only the kill event")
	assert_eq(str(events[0]["event_type"]), "kill")


# --- T-426 slice 4: the skill-acquisition measure -------------------------------


func test_skill_acquisition_stages_are_measured_from_entry() -> void:
	var rec := (
		Funnel
		. first_session(
			[
				_ev("session_start", 100.0),
				_ev("kill", 130.0),
				_ev("tutorial_basics", 140.0),
				_ev("tutorial_kit", 200.0),
				_ev("tutorial_tactics", 260.0),
				_ev("session_end", 400.0),
			]
		)
	)
	assert_true(bool(rec["reached"]["tutorial_basics"]), "q_tut_01 completion is measured")
	assert_true(bool(rec["reached"]["tutorial_kit"]), "q_tut_02 completion is measured")
	assert_true(
		bool(rec["reached"]["tutorial_tactics"]), "the interrupt encounter clear is measured"
	)
	assert_eq(float(rec["times"]["tutorial_tactics"]), 160.0, "time-to-tactics from entry")
	assert_eq(str(rec["drop_stage"]), "tutorial_tactics", "furthest stage is the tactical clear")


func test_never_acquiring_the_tactical_skill_is_visible() -> void:
	var rec := (
		Funnel
		. first_session(
			[
				_ev("session_start", 0.0),
				_ev("tutorial_basics", 30.0),
				_ev("tutorial_kit", 90.0),
				_ev("session_end", 200.0),
			]
		)
	)
	assert_true(bool(rec["reached"]["tutorial_kit"]), "kit acquired")
	assert_false(bool(rec["reached"]["tutorial_tactics"]), "tactical skill NOT acquired")
	assert_eq(float(rec["times"]["tutorial_tactics"]), -1.0, "unreached -> no time")


func test_cohort_rollup_surfaces_skill_stages() -> void:
	var out := (
		Funnel
		. cohort_rollup(
			[
				_ev("session_start", 0.0, "A"),
				_ev("tutorial_basics", 10.0, "A"),
				_ev("tutorial_tactics", 40.0, "A"),
				_ev("session_start", 0.0, "B"),
				_ev("tutorial_basics", 12.0, "B"),
			]
		)
	)
	var by_stage := {}
	for s: Dictionary in out["stages"]:
		by_stage[str(s["stage"])] = s
	assert_eq(int(by_stage["tutorial_basics"]["reached"]), 2, "both acquired the basics")
	assert_eq(
		int(by_stage["tutorial_tactics"]["reached"]), 1, "only A cleared the tactical encounter"
	)


func test_record_tutorial_step_emits_the_named_event() -> void:
	TelemetryStore.reset_for_test()
	TelemetryStore.record_tutorial_step("hero", "tutorial_tactics")
	var events := TelemetryStore.test_events()
	assert_eq(events.size(), 1)
	assert_eq(str(events[0]["event_type"]), "tutorial_tactics")
	assert_eq(str(events[0]["account"]), "hero")


func test_record_tutorial_step_ignores_empty_inputs() -> void:
	TelemetryStore.reset_for_test()
	assert_eq(int(TelemetryStore.record_tutorial_step("", "tutorial_kit")["written"]), 0)
	assert_eq(int(TelemetryStore.record_tutorial_step("hero", "")["written"]), 0)
	assert_eq(TelemetryStore.test_events().size(), 0, "neither empty call wrote")


# --- T-705: measured from PROCESS LAUNCH, not spawn ----------------------------


func _boot_ev(ts: float, to_login: int, to_interactive: int, acct := "hero") -> Dictionary:
	var e := _ev("client_boot_timing", ts, acct)
	e["payload"] = {"launch_to_login_ms": to_login, "login_to_interactive_ms": to_interactive}
	return e


func _reject_ev(ts: float, reason: String, intent: String, acct := "hero") -> Dictionary:
	var e := _ev("intent_rejected", ts, acct)
	e["character"] = acct
	e["payload"] = {"reason": reason, "intent": intent}
	return e


func test_boot_phases_are_measured_and_summed_into_the_dead_air_window() -> void:
	var rec := Funnel.first_session([_ev("session_start", 100.0), _boot_ev(101.0, 12000, 29000)])
	var boot: Dictionary = rec["boot"]
	assert_eq(float(boot["launch_to_login"]), 12.0, "launch -> login submit, in seconds")
	assert_eq(float(boot["login_to_interactive"]), 29.0, "login submit -> world interactive")
	assert_eq(float(boot["launch_to_interactive"]), 41.0, "the whole pre-control dead air")


func test_every_stage_also_carries_a_time_from_process_launch() -> void:
	var rec := (
		Funnel
		. first_session(
			[
				_ev("session_start", 100.0),
				_boot_ev(101.0, 12000, 29000),
				_ev("quest_accept", 129.0),
				_ev("kill", 160.0),
			]
		)
	)
	assert_eq(float(rec["times"]["first_kill"]), 60.0, "from-spawn time is unchanged")
	assert_eq(
		float(rec["times_from_launch"]["first_kill"]),
		101.0,
		"41s of boot + 60s in world = the honest time-to-first-kill from double-click",
	)
	assert_eq(float(rec["times_from_launch"]["world_entry"]), 41.0, "spawn itself costs 41s")
	assert_eq(
		float(rec["times_from_launch"]["first_level_up"]), -1.0, "unreached stages stay unmeasured"
	)


func test_an_account_without_boot_timing_reports_no_launch_anchored_time() -> void:
	# Older clients send no boot event; the funnel must not invent a zero-length boot for them.
	var rec := Funnel.first_session([_ev("session_start", 100.0), _ev("kill", 130.0)])
	assert_true((rec["boot"] as Dictionary).is_empty(), "no boot data recorded")
	assert_eq(float(rec["times_from_launch"]["first_kill"]), -1.0, "and no launch-anchored time")


func test_boot_rollup_medians_only_the_accounts_that_reported() -> void:
	var out := (
		Funnel
		. cohort_rollup(
			[
				_ev("session_start", 0.0, "A"),
				_boot_ev(1.0, 10000, 20000, "A"),
				_ev("session_start", 0.0, "B"),
				_boot_ev(1.0, 20000, 40000, "B"),
				_ev("session_start", 0.0, "C"),  # no boot report at all
			]
		)
	)
	var boot: Dictionary = out["boot"]
	assert_eq(int(boot["samples"]), 2, "only the two reporting accounts count")
	var by_phase := {}
	for p: Dictionary in boot["phases"]:
		by_phase[str(p["phase"])] = float(p["median_seconds"])
	assert_eq(by_phase["launch_to_login"], 15.0, "median of [10s, 20s]")
	assert_eq(by_phase["launch_to_interactive"], 45.0, "median of [30s, 60s]")


func test_stage_rows_carry_a_launch_anchored_median() -> void:
	var out := (
		Funnel
		. cohort_rollup(
			[
				_ev("session_start", 100.0, "A"),
				_boot_ev(101.0, 10000, 20000, "A"),
				_ev("kill", 140.0, "A"),
				_ev("session_start", 500.0, "B"),  # no boot report
				_ev("kill", 520.0, "B"),
			]
		)
	)
	var by_stage := {}
	for s: Dictionary in out["stages"]:
		by_stage[str(s["stage"])] = s
	assert_eq(float(by_stage["first_kill"]["median_seconds"]), 30.0, "median of [40s, 20s]")
	assert_eq(
		float(by_stage["first_kill"]["median_seconds_from_launch"]),
		70.0,
		"only A reported a boot, so the launch median is A's 30s boot + 40s alone",
	)


# --- T-705: the reward beats between the old stages -----------------------------


func test_quest_loot_equip_and_turn_in_are_measured_stages() -> void:
	var rec := (
		Funnel
		. first_session(
			[
				_ev("session_start", 0.0),
				_ev("quest_accept", 29.0),
				_ev("kill", 60.0),
				_ev("loot", 61.0),
				_ev("equip", 90.0),
				_ev("quest_turn_in", 120.0),
			]
		)
	)
	assert_eq(float(rec["times"]["first_quest"]), 29.0, "time-to-on-quest")
	assert_eq(float(rec["times"]["first_loot"]), 61.0, "time-to-first-drop")
	assert_eq(float(rec["times"]["first_equip"]), 90.0, "time-to-first-upgrade-worn")
	assert_eq(float(rec["times"]["first_turn_in"]), 120.0, "time-to-first-reward-collected")
	assert_eq(str(rec["drop_stage"]), "first_turn_in", "furthest beat reached")


func test_every_stage_has_a_median_seconds_column() -> void:
	# Acceptance: every stage 0->15min reports a median-seconds column, reached or not.
	var out := Funnel.cohort_rollup(_cohort_events())
	assert_eq(int(out["stages"].size()), Funnel.STAGES.size(), "one row per stage, no gaps")
	for s: Dictionary in out["stages"]:
		assert_true(s.has("median_seconds"), "%s reports a from-spawn median" % str(s["stage"]))
		assert_true(
			s.has("median_seconds_from_launch"), "%s reports a from-launch median" % str(s["stage"])
		)
		assert_ne(str(s["label"]), "", "%s is labelled for the GM console" % str(s["stage"]))


# --- T-705: session length + D1 return ------------------------------------------


func test_session_length_medians_only_finished_sessions() -> void:
	var out := (
		Funnel
		. cohort_rollup(
			[
				_ev("session_start", 0.0, "A"),
				_ev("session_end", 600.0, "A"),
				_ev("session_start", 0.0, "B"),
				_ev("session_end", 1200.0, "B"),
				_ev("session_start", 0.0, "C"),  # never ended — still playing, or the world died
			]
		)
	)
	var length: Dictionary = out["session_length"]
	assert_eq(int(length["samples"]), 2, "only the two closed sessions are measurable")
	assert_eq(float(length["median_seconds"]), 900.0, "median of [10m, 20m]")
	assert_eq(int(length["unfinished"]), 1, "the open session is reported, never counted as 0s")


func test_d1_return_counts_only_accounts_whose_day_two_is_over() -> void:
	var day := 86400.0
	var events := [
		# A came back 30 h after first entry -> a D1 return.
		_ev("session_start", 0.0, "A"),
		_ev("session_start", 30.0 * 3600.0, "A"),
		# B never came back, and its day 2 is long gone -> eligible, not returned.
		_ev("session_start", 0.0, "B"),
		# C started only 3 h before the newest event -> day 2 has not happened yet.
		_ev("session_start", 4.0 * day - 3.0 * 3600.0, "C"),
		_ev("session_end", 4.0 * day, "C"),
	]
	var d1 := Funnel.d1_return(events)
	assert_eq(int(d1["eligible"]), 2, "C is not judged before its day 2 has elapsed")
	assert_eq(int(d1["returned"]), 1, "only A logged back in on day 2")
	assert_eq(float(d1["pct"]), 50.0)
	# A same-day relog is NOT a D1 return (that is still session 1's day).
	var same_day := Funnel.d1_return(
		[_ev("session_start", 0.0, "A"), _ev("session_start", 3600.0, "A")], 5.0 * day
	)
	assert_eq(int(same_day["returned"]), 0, "an hour later is the same day, not a return")


func test_d1_return_is_empty_and_safe_with_no_eligible_accounts() -> void:
	var d1 := Funnel.d1_return([_ev("session_start", 0.0, "A")])
	assert_eq(int(d1["eligible"]), 0)
	assert_eq(float(d1["pct"]), 0.0, "no divide-by-zero")


# --- T-705: failure-reason events -----------------------------------------------


func test_rejections_are_captured_per_session_with_reason_and_intent() -> void:
	var rec := (
		Funnel
		. first_session(
			[
				_ev("session_start", 0.0),
				_reject_ev(20.0, "too_far", "turn_in"),
				_reject_ev(45.0, "insufficient_resource", "use_ability"),
				_ev("session_end", 60.0),
			]
		)
	)
	var rejections: Array = rec["rejections"]
	assert_eq(rejections.size(), 2, "both refusals recorded")
	assert_eq(str(rejections[0]["reason"]), "too_far")
	assert_eq(str(rejections[0]["intent"]), "turn_in", "what they were trying to do")
	assert_eq(float(rejections[0]["t"]), 20.0, "timed from entry like every other signal")


func test_rejection_rollup_ranks_reasons_and_names_the_characters() -> void:
	var out := (
		Funnel
		. cohort_rollup(
			[
				_ev("session_start", 0.0, "A"),
				_reject_ev(10.0, "too_far", "turn_in", "A"),
				_reject_ev(15.0, "bag_full", "loot", "A"),
				_ev("session_start", 0.0, "B"),
				_reject_ev(12.0, "too_far", "service_intent", "B"),
			]
		)
	)
	var rejections: Array = out["rejections"]
	assert_eq(str(rejections[0]["reason"]), "too_far", "the most-hit refusal ranks first")
	assert_eq(int(rejections[0]["count"]), 2)
	assert_eq(rejections[0]["characters"], ["A", "B"], "queryable per character")
	assert_eq(
		rejections[0]["intents"], ["service_intent", "turn_in"], "both refused intents are kept"
	)
	assert_eq(str(rejections[1]["reason"]), "bag_full")


func test_a_rejection_outside_the_first_session_is_not_counted() -> void:
	var rec := (
		Funnel
		. first_session(
			[
				_ev("session_start", 0.0),
				_ev("session_end", 60.0),
				_ev("session_start", 5000.0),
				_reject_ev(5010.0, "too_far", "turn_in"),
			]
		)
	)
	assert_eq((rec["rejections"] as Array).size(), 0, "session 2's refusal is not session 1's")


# --- T-705: payloads survive the jsonb round-trip -------------------------------


func test_a_payload_that_arrives_as_a_json_string_is_still_read() -> void:
	# Postgres hands jsonb back as text; a test stub hands back a Dictionary. Both must work.
	var e := _ev("client_boot_timing", 1.0)
	e["payload"] = '{"launch_to_login_ms": 5000, "login_to_interactive_ms": 5000}'
	var rec := Funnel.first_session([_ev("session_start", 0.0), e])
	assert_eq(float(rec["boot"]["launch_to_interactive"]), 10.0, "jsonb text parsed")


func test_a_malformed_payload_never_raises() -> void:
	var e := _ev("client_boot_timing", 1.0)
	e["payload"] = "not json at all"
	var rec := Funnel.first_session([_ev("session_start", 0.0), e])
	assert_true((rec["boot"] as Dictionary).is_empty(), "unreadable payload -> no boot data")


# --- T-705: the reader and the writer share one event vocabulary ----------------


func test_the_funnel_reads_exactly_what_the_store_is_allowed_to_write() -> void:
	for stage: String in Funnel.STAGES:
		assert_true(
			TelemetryStore.FUNNEL_EVENT_TYPES.has(str(Funnel.STAGE_EVENT[stage])),
			"stage %s reads an event type the store can actually write" % stage,
		)
	for extra in [Funnel.BOOT_EVENT, Funnel.REJECT_EVENT, "session_end"]:
		assert_true(TelemetryStore.FUNNEL_EVENT_TYPES.has(extra), "%s is in the catalog" % extra)


func test_record_funnel_event_refuses_an_event_type_outside_the_catalog() -> void:
	TelemetryStore.reset_for_test()
	var written := TelemetryStore.record_funnel_event("hero", "quest_accept", {"q": "q001"})
	assert_eq(int(written["written"]), 1)
	assert_eq(int(TelemetryStore.record_funnel_event("hero", "typo_event")["written"]), 0)
	assert_eq(int(TelemetryStore.record_funnel_event("", "quest_accept")["written"]), 0)
	var events := TelemetryStore.test_events()
	assert_eq(events.size(), 1, "only the catalogued event was written")
	assert_eq(str(events[0]["event_type"]), "quest_accept")
	assert_eq(str(events[0]["character"]), "hero", "beats stay queryable per character")


func test_rollup_query_reads_the_character_and_payload_columns() -> void:
	var captured := {}
	var stub := func(sql: String, params: Array) -> Array:
		captured["sql"] = sql
		captured["params"] = params
		return []
	Funnel.rollup({"days": 7}, stub)
	var sql := str(captured["sql"])
	assert_true(sql.begins_with("SELECT"), "still read-only")
	assert_true(sql.contains('"character"'), "character is quoted (Postgres type keyword)")
	assert_true(sql.contains("payload"), "the payload carries boot phases + rejection reasons")
