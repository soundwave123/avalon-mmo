extends RefCounted
# T-186: the master is the single writer for the append-only telemetry.gameplay_events log.
# The world ships batches via the record_events RPC; this store writes them in ONE multi-row
# INSERT (a slow-master flush must be cheap). Test mode keeps events in memory so the pipeline
# unit-tests with no DB (mirrors ServicesStore/CharacterManager's reset_for_test discipline).

const _CM = preload("res://scripts/character_manager.gd")  # reuse its DB connection helpers

# T-705: the first-session funnel's event vocabulary, single-sourced HERE (the writer) so the
# reader (first_session_funnel._READ_TYPES) can never drift from what actually gets logged. The
# funnel measures from process launch now, so it spans the pre-spawn boot phases, the first
# quest/loot/equip/turn-in beats, and the failure reasons that mark a quit-risk moment.
const FUNNEL_EVENT_TYPES := [
	"session_start",
	"session_end",
	"client_boot_timing",
	"quest_accept",
	"kill",
	"loot",
	"level_up",
	"equip",
	"quest_turn_in",
	"tutorial_basics",
	"tutorial_kit",
	"tutorial_tactics",
	"intent_rejected",
]

static var _test_skip_db: bool = false
static var _test_events: Array = []


static func reset_for_test() -> void:
	_test_skip_db = true
	_test_events.clear()


# Append a batch of events. Returns {written:int}. Each event: {event_type, account, character,
# payload}. A single parameterized multi-row INSERT keeps a big flush to one round-trip.
static func record_events(events: Array) -> Dictionary:
	if events.is_empty():
		return {"written": 0}
	if _test_skip_db:
		for e: Dictionary in events:
			_test_events.append(e)
		return {"written": events.size()}
	var tuples: Array = []
	var params: Array = []
	var i := 0
	for e: Dictionary in events:
		params.append(e.get("account"))
		params.append(e.get("character"))
		params.append(str(e.get("event_type", "")))
		params.append(JSON.stringify(e.get("payload", {})))
		tuples.append("($%d,$%d,$%d,$%d::jsonb)" % [i + 1, i + 2, i + 3, i + 4])
		i += 4
	var sql := (
		"INSERT INTO telemetry.gameplay_events (account, character, event_type, payload) VALUES "
		+ ", ".join(tuples)
	)
	var ok: bool = _CM._execute(sql, params)
	return {"written": events.size() if ok else 0}


# T-427: typed discovery writer. Native Godot 4.7's subprocess bridge can reject a JSON string
# passed through psql -v; scalar parameters plus jsonb_build_object keep the live event reliable.
static func record_discovery(
	username: String, node_id: String, zone: String, xp: int, rested_bonus: int, coins: int
) -> Dictionary:
	var event := {
		"event_type": "discovery",
		"account": username,
		"character": username,
		"payload":
		{
			"node_id": node_id,
			"zone": zone,
			"xp": xp,
			"rested_bonus": rested_bonus,
			"coins": coins,
		},
	}
	if _test_skip_db:
		_test_events.append(event)
		return {"written": 1}
	var ok := _CM.db_execute(
		(
			"INSERT INTO telemetry.gameplay_events (account,character,event_type,payload) "
			+ "VALUES ($1,$1,'discovery',jsonb_build_object("
			+ "'node_id',$2,'zone',$3,'xp',$4::int,'rested_bonus',$5::int,'coins',$6::int))"
		),
		[username, node_id, zone, xp, rested_bonus, coins]
	)
	return {"written": 1 if ok else 0}


# T-528: first-session funnel signals the T-186 catalog lacked — a per-kill `kill` event and, when
# the kill dinged, a `level_up` event. Server-authoritative (called only from master _credit_kill,
# no client path) and fire-and-forget into the same append-only log. The funnel aggregator takes the
# FIRST of each per first session, so emitting on every kill/level is correct.
static func record_kill_funnel(
	username: String, mob_id: String, leveling: Dictionary
) -> Dictionary:
	if username == "":
		return {"written": 0}
	var events: Array = [
		{
			"event_type": "kill",
			"account": username,
			"character": username,
			"payload": {"mob": mob_id}
		}
	]
	if bool(leveling.get("leveled_up", false)):
		(
			events
			. append(
				{
					"event_type": "level_up",
					"account": username,
					"character": username,
					"payload": {"level": int(leveling.get("level", 0))},
				}
			)
		)
	return record_events(events)


# T-426: a skill-acquisition signal for the first-session funnel — server-observed proof a new
# player performed a taught skill (tutorial_basics/tutorial_kit on a tutorial turn-in;
# tutorial_tactics on a credited interrupt). Server-authoritative (called only from TutorialOps, no
# client path) and fire-and-forget into the same append-only log; the funnel takes the FIRST per
# session, so re-emitting on a later step is harmless.
static func record_tutorial_step(username: String, event_type: String) -> Dictionary:
	return record_funnel_event(username, event_type)


# T-705: ONE server-authoritative funnel signal, appended fire-and-forget like the emitters above.
# An event type outside FUNNEL_EVENT_TYPES is refused rather than written: a typo here would create
# a stream the funnel reader never selects, i.e. a measurement that silently reads as "nobody did
# this". Read-only product measurement of pseudonymous account data, same guardrail as the funnel.
static func record_funnel_event(
	username: String, event_type: String, payload: Dictionary = {}
) -> Dictionary:
	if username == "" or not FUNNEL_EVENT_TYPES.has(event_type):
		return {"written": 0}
	return record_events(
		[
			{
				"event_type": event_type,
				"account": username,
				"character": username,
				"payload": payload,
			}
		]
	)


static func test_events() -> Array:  # test accessor
	return _test_events
