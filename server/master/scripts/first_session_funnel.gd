class_name FirstSessionFunnel
extends RefCounted

# T-528: the first-session hook funnel over the T-186 event log (telemetry.gameplay_events).
# Pure aggregation (no DB, no OS time) so the stage math unit-tests against synthetic traces; the
# only impure seam is rollup(), which reads the log via an injected query Callable — the OpsStore
# idiom. ETHICAL GUARDRAIL (ticket §Ethical): this is read-only product measurement of the
# pseudonymous account/event data T-186 already logs, to improve the onramp — no per-player lever,
# no churn/FOMO hook, no PII. It only ever SELECTs; it never writes and never targets one player.

# T-705: the funnel used to anchor on world entry, which made the 20-30s launch->login->interactive
# dead air invisible — the exact window a refund clock runs in. The client reports its own boot
# phases as ONE post-handshake event (durations only, never a wall clock), so every stage now also
# carries a seconds-from-LAUNCH median alongside the seconds-from-entry one. Same guardrail as
# above: durations and counts, cohort-wide, no per-player lever.

const CharacterManager = preload("res://scripts/character_manager.gd")
const TelemetryStore = preload("res://scripts/telemetry_store.gd")

# Ordered funnel stages and the T-186 event_type that marks each. world_entry = session_start
# (the moment the world validates + spawns the player = control gained / time-to-first-gameplay).
# first_kill / first_level_up are the T-528 additions the credit path emits, fire-and-forget.
# T-426: the tutorial stages are the SKILL-ACQUISITION measure the fun-science audit asked for
# — server-observed proof a new player actually acquired the taught skills, not just reward cadence.
# tutorial_basics = q_tut_01 turned in (move/attack/loot performed); tutorial_kit = q_tut_02
# (equip/ability); tutorial_tactics = the interrupt encounter cleared (q_tut_03). They ride the same
# funnel so the GM console shows exactly where new players stop acquiring skills.
# T-705 adds the reward beats between them — the first quest taken, the first item that dropped,
# the first piece worn, the first hand-in — so a stall reads as a missing BEAT, not just a gap.
const STAGES := [
	"world_entry",
	"first_quest",
	"first_kill",
	"first_loot",
	"first_level_up",
	"first_equip",
	"first_turn_in",
	"tutorial_basics",
	"tutorial_kit",
	"tutorial_tactics",
]
const STAGE_EVENT := {
	"world_entry": "session_start",
	"first_quest": "quest_accept",
	"first_kill": "kill",
	"first_loot": "loot",
	"first_level_up": "level_up",
	"first_equip": "equip",
	"first_turn_in": "quest_turn_in",
	"tutorial_basics": "tutorial_basics",
	"tutorial_kit": "tutorial_kit",
	"tutorial_tactics": "tutorial_tactics",
}
const STAGE_LABEL := {
	"world_entry": "World entry (spawn)",
	"first_quest": "First quest accepted",
	"first_kill": "First kill",
	"first_loot": "First loot received",
	"first_level_up": "First level-up",
	"first_equip": "First item equipped",
	"first_turn_in": "First quest turned in",
	"tutorial_basics": "Tutorial: basics (move/attack/loot)",
	"tutorial_kit": "Tutorial: kit (equip/ability)",
	"tutorial_tactics": "Tutorial: tactics (interrupt)",
}

# T-705: the pre-spawn phases, derived from the client's one boot-timing event. launch is 0 by
# construction (the client clock is time-since-process-start), so these are the two measurable
# segments plus their sum — the whole dead-air window before the player has control.
const BOOT_PHASES := [
	{"phase": "launch_to_login", "label": "Launch → login submit"},
	{"phase": "login_to_interactive", "label": "Login submit → world interactive"},
	{"phase": "launch_to_interactive", "label": "Launch → world interactive (total dead air)"},
]
const BOOT_EVENT := "client_boot_timing"
const REJECT_EVENT := "intent_rejected"
# D1 = "came back on day 2". An account only counts once its day 2 is fully over, so a player who
# started an hour ago is neither a win nor a loss — they are simply not eligible yet.
const D1_WINDOW_START_S := 86400.0
const D1_WINDOW_END_S := 172800.0

const _READ_TYPES := TelemetryStore.FUNNEL_EVENT_TYPES
const _WINDOW_MIN := 1
const _WINDOW_MAX := 90
const _WINDOW_DEFAULT := 14


# Impure seam: read the recent first-session traces and roll them up. `query` defaults to the live
# Postgres reader; tests inject a stub. Returns {ok, result:<cohort_rollup>, window_days}.
static func rollup(params: Dictionary, query: Callable = Callable()) -> Dictionary:
	var days := clampi(int(params.get("days", _WINDOW_DEFAULT)), _WINDOW_MIN, _WINDOW_MAX)
	var run := query if query.is_valid() else Callable(CharacterManager, "db_query")
	# T-705: `character` is quoted (it is a Postgres type keyword) and `payload` rides along — the
	# boot phases and the rejection reasons live in it. Still SELECT-only.
	var rows: Array = run.call(
		(
			'SELECT account, "character" AS char_name, event_type, payload, '
			+ "EXTRACT(EPOCH FROM ts) AS ts "
			+ "FROM telemetry.gameplay_events "
			+ "WHERE event_type = ANY($1) AND account IS NOT NULL AND account <> '' "
			+ "AND ts >= now() - make_interval(days => $2) ORDER BY account, ts"
		),
		[_READ_TYPES, days]
	)
	var events: Array = []
	for row: Dictionary in rows:
		(
			events
			. append(
				{
					"account": str(row.get("account", "")),
					"character": str(row.get("char_name", "")),
					"event_type": str(row.get("event_type", "")),
					"payload": row.get("payload", {}),
					"ts": float(row.get("ts", 0.0)),
				}
			)
		)
	var out := cohort_rollup(events)
	out["window_days"] = days
	return {"ok": true, "result": out}


# Pure: one account's FIRST session. events = that account's rows [{event_type, ts}] (any order).
# The window runs from the first session_start to the first session_end at/after it (open if none).
static func first_session(events: Array) -> Dictionary:
	var sorted := events.duplicate()
	sorted.sort_custom(func(a, b): return float(a.get("ts", 0.0)) < float(b.get("ts", 0.0)))
	var anchor := INF
	for e: Dictionary in sorted:
		if str(e.get("event_type", "")) == "session_start":
			anchor = float(e.get("ts", 0.0))
			break
	if anchor == INF:
		return {"reached_entry": false}
	var end_ts := INF
	for e: Dictionary in sorted:
		if str(e.get("event_type", "")) == "session_end" and float(e.get("ts", 0.0)) >= anchor:
			end_ts = float(e.get("ts", 0.0))
			break
	var first_ts := {}  # event_type -> earliest ts within the session window
	var boot_payload := {}
	var rejections: Array = []  # T-705: every refusal this session, in order, with its reason
	var last_type := "session_start"
	for e: Dictionary in sorted:
		var ts := float(e.get("ts", 0.0))
		if ts < anchor or ts > end_ts:
			continue
		var et := str(e.get("event_type", ""))
		if not first_ts.has(et):
			first_ts[et] = ts
		if et == BOOT_EVENT and boot_payload.is_empty():
			boot_payload = _payload_of(e)
		elif et == REJECT_EVENT:
			var rp := _payload_of(e)
			(
				rejections
				. append(
					{
						"reason": str(rp.get("reason", "unknown")),
						"intent": str(rp.get("intent", "")),
						"character": str(e.get("character", e.get("account", ""))),
						"t": ts - anchor,
					}
				)
			)
		last_type = et
	var boot := _boot_seconds(boot_payload)
	# -1.0 = this account reported no boot timing, so it contributes to no launch-anchored median.
	var launch_offset: float = float(boot.get("launch_to_interactive", -1.0))
	var reached := {}
	var times := {}
	var from_launch := {}
	var drop_stage := "world_entry"
	for stage: String in STAGES:
		var hit: bool = stage == "world_entry" or first_ts.has(STAGE_EVENT[stage])
		reached[stage] = hit
		times[stage] = -1.0
		from_launch[stage] = -1.0
		if hit:
			var ev_ts: float = anchor if stage == "world_entry" else first_ts[STAGE_EVENT[stage]]
			times[stage] = ev_ts - anchor
			if launch_offset >= 0.0:
				from_launch[stage] = times[stage] + launch_offset
			drop_stage = stage
	return {
		"reached_entry": true,
		"anchor_ts": anchor,
		"ended": end_ts != INF,
		"last_event": last_type,
		"reached": reached,
		"times": times,
		"times_from_launch": from_launch,
		"boot": boot,
		"session_seconds": (end_ts - anchor) if end_ts != INF else -1.0,
		"rejections": rejections,
		"drop_stage": drop_stage,
	}


# T-705: a logged payload arrives as a jsonb string from Postgres and as a Dictionary from a test
# stub — normalise both, and never let a malformed row raise (this is a reporting path).
static func _payload_of(event: Dictionary) -> Dictionary:
	var raw: Variant = event.get("payload", {})
	if raw is Dictionary:
		return raw
	if raw is String and str(raw) != "":
		# JSON.new().parse() RETURNS the error; JSON.parse_string() pushes an engine error on bad
		# input, which a reporting path must never do (same idiom as gateway_login.gd).
		var json := JSON.new()
		if json.parse(str(raw)) == OK and json.data is Dictionary:
			return json.data
	return {}


# T-705: the client reports milliseconds since ITS process start; launch is 0 by construction, so
# the two reported segments plus their sum are the whole pre-control window. Negatives are clamped
# away — a suspended process must not hand the cohort a negative phase.
static func _boot_seconds(payload: Dictionary) -> Dictionary:
	if payload.is_empty():
		return {}
	var to_login := maxf(0.0, float(payload.get("launch_to_login_ms", 0.0)) / 1000.0)
	var to_interactive := maxf(0.0, float(payload.get("login_to_interactive_ms", 0.0)) / 1000.0)
	return {
		"launch_to_login": to_login,
		"login_to_interactive": to_interactive,
		"launch_to_interactive": to_login + to_interactive,
	}


# Pure: roll all accounts' first sessions into the cohort funnel. events = every account's rows.
# Per stage: reached count, %-of-cohort, and median seconds-from-entry (of those who reached).
static func cohort_rollup(events: Array) -> Dictionary:
	var by_account := {}
	for e: Dictionary in events:
		var acct := str(e.get("account", ""))
		if not by_account.has(acct):
			by_account[acct] = []
		by_account[acct].append(e)
	var records: Array = []
	for acct: String in by_account:
		var rec := first_session(by_account[acct])
		if bool(rec.get("reached_entry", false)):
			records.append(rec)
	var cohort := records.size()
	var stage_rows: Array = []
	var prev_reached := cohort
	var biggest_drop := ""
	var biggest_drop_count := 0  # only a strictly-positive drop earns the flag (0 = nobody dropped)
	for stage: String in STAGES:
		var deltas: Array = []
		var launch_deltas: Array = []  # T-705: only accounts that reported boot timing land here
		for rec: Dictionary in records:
			if not bool(rec.get("reached", {}).get(stage, false)):
				continue
			deltas.append(float(rec.get("times", {}).get(stage, -1.0)))
			var from_launch := float(rec.get("times_from_launch", {}).get(stage, -1.0))
			if from_launch >= 0.0:
				launch_deltas.append(from_launch)
		var reached_n := deltas.size()
		var pct := (100.0 * float(reached_n) / float(cohort)) if cohort > 0 else 0.0
		var dropped := prev_reached - reached_n
		if stage != "world_entry" and dropped > biggest_drop_count:
			biggest_drop_count = dropped
			biggest_drop = stage
		(
			stage_rows
			. append(
				{
					"stage": stage,
					"label": STAGE_LABEL[stage],
					"reached": reached_n,
					"pct_reached": snappedf(pct, 0.1),
					"median_seconds": snappedf(_median(deltas), 0.1),
					"median_seconds_from_launch": snappedf(_median(launch_deltas), 0.1),
				}
			)
		)
		prev_reached = reached_n
	var last_events := {}
	for rec: Dictionary in records:
		var le := str(rec.get("last_event", ""))
		last_events[le] = int(last_events.get(le, 0)) + 1
	return {
		"cohort_size": cohort,
		"stages": stage_rows,
		"biggest_drop_stage": biggest_drop,
		"biggest_drop_label": STAGE_LABEL.get(biggest_drop, ""),
		"biggest_drop_count": biggest_drop_count,
		"last_event_counts": last_events,
		"boot": boot_rollup(records),  # T-705: pre-spawn dead air
		"session_length": session_length_rollup(records),  # T-705
		"rejections": rejection_rollup(records),  # T-705: the quit-risk moments, per character
		"d1_return": d1_return(events),  # T-705
	}


# Pure: median duration of each pre-spawn boot phase, over the accounts that reported one.
static func boot_rollup(records: Array) -> Dictionary:
	var by_phase := {}
	for spec: Dictionary in BOOT_PHASES:
		by_phase[str(spec["phase"])] = []
	var samples := 0
	for rec: Dictionary in records:
		var boot: Dictionary = rec.get("boot", {})
		if boot.is_empty():
			continue
		samples += 1
		for spec: Dictionary in BOOT_PHASES:
			by_phase[str(spec["phase"])].append(float(boot.get(str(spec["phase"]), 0.0)))
	var rows: Array = []
	for spec: Dictionary in BOOT_PHASES:
		(
			rows
			. append(
				{
					"phase": str(spec["phase"]),
					"label": str(spec["label"]),
					"median_seconds": snappedf(_median(by_phase[str(spec["phase"])]), 0.1),
				}
			)
		)
	return {"samples": samples, "phases": rows}


# Pure: how long the first session actually lasted. A session with no session_end is still OPEN
# (the player is playing, or the world died) — counted separately, never as a zero-length session.
static func session_length_rollup(records: Array) -> Dictionary:
	var lengths: Array = []
	var unfinished := 0
	for rec: Dictionary in records:
		var secs := float(rec.get("session_seconds", -1.0))
		if bool(rec.get("ended", false)) and secs >= 0.0:
			lengths.append(secs)
		else:
			unfinished += 1
	return {
		"samples": lengths.size(),
		"median_seconds": snappedf(_median(lengths), 0.1),
		"unfinished": unfinished,
	}


# Pure: every refusal the cohort hit in its first session, worst reason first. `characters` is what
# makes a reason actionable — it names WHO stalled on it, which is the per-character query the
# ticket asked for (still pseudonymous character names, still no per-player lever).
static func rejection_rollup(records: Array) -> Array:
	var by_reason := {}
	for rec: Dictionary in records:
		for row: Dictionary in rec.get("rejections", []):
			var reason := str(row.get("reason", "unknown"))
			if not by_reason.has(reason):
				by_reason[reason] = {"reason": reason, "count": 0, "intents": {}, "chars": {}}
			var bucket: Dictionary = by_reason[reason]
			bucket["count"] = int(bucket["count"]) + 1
			bucket["intents"][str(row.get("intent", ""))] = true
			var who := str(row.get("character", ""))
			if who != "":
				bucket["chars"][who] = true
	var out: Array = []
	for reason: String in by_reason:
		var bucket: Dictionary = by_reason[reason]
		var intents: Array = bucket["intents"].keys()
		intents.sort()
		var chars: Array = bucket["chars"].keys()
		chars.sort()
		(
			out
			. append(
				{
					"reason": reason,
					"count": int(bucket["count"]),
					"intents": intents,
					"characters": chars,
				}
			)
		)
	out.sort_custom(func(a, b): return int(a["count"]) > int(b["count"]))
	return out


# Pure: the D1-return join. Of the accounts whose day 2 has fully elapsed (relative to `now_ts`, or
# to the newest event in the set when omitted), how many logged in again 24–48 h after their first
# entry? An account whose day 2 has not finished is not counted either way.
static func d1_return(events: Array, now_ts: float = -1.0) -> Dictionary:
	var starts := {}
	var newest := 0.0
	for e: Dictionary in events:
		var ts := float(e.get("ts", 0.0))
		newest = maxf(newest, ts)
		if str(e.get("event_type", "")) != "session_start":
			continue
		var acct := str(e.get("account", ""))
		if not starts.has(acct):
			starts[acct] = []
		starts[acct].append(ts)
	var now := now_ts if now_ts >= 0.0 else newest
	var eligible := 0
	var returned := 0
	for acct: String in starts:
		var list: Array = starts[acct]
		list.sort()
		var first: float = float(list[0])
		if now - first < D1_WINDOW_END_S:
			continue  # day 2 is not over yet — neither a return nor a loss
		eligible += 1
		for ts: float in list:
			if ts - first >= D1_WINDOW_START_S and ts - first < D1_WINDOW_END_S:
				returned += 1
				break
	var pct := (100.0 * float(returned) / float(eligible)) if eligible > 0 else 0.0
	return {"eligible": eligible, "returned": returned, "pct": snappedf(pct, 0.1)}


# Median of a float array; -1.0 for empty (a stage nobody reached has no time).
static func _median(values: Array) -> float:
	if values.is_empty():
		return -1.0
	var s := values.duplicate()
	s.sort()
	var n := s.size()
	if n % 2 == 1:
		return float(s[n / 2])
	return (float(s[n / 2 - 1]) + float(s[n / 2])) / 2.0
