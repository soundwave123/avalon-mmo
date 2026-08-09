class_name WorldStateStore
extends RefCounted

# T-734: master-owned durable world-global scalars (the world.state KV table, migration 056).
# First consumer is the day/night clock: the WORLD server owns the live day_t and checkpoints it
# here every few seconds (world_clock.gd), so a world restart resumes the shared time of day.
# Master is the persistent side by construction — it owns Postgres, and every durable world write
# already flows through master_client; the world server stays stateless on disk.
#
# Same injectable-query discipline as OpsStore: `query` defaults to the live DB bridge and tests
# inject a fake. Keys are ALLOWLISTED — this is a scalar checkpoint seam, not a general dumping
# ground; add a key deliberately when a new world-global needs to survive a restart.

const CharacterManager = preload("res://scripts/character_manager.gd")
const KEYS := ["day_t"]


static func handle(params: Dictionary, query: Callable = Callable()) -> Dictionary:
	var op := str(params.get("op", ""))
	var key := str(params.get("key", ""))
	if not KEYS.has(key):
		return {"ok": false, "error": "unknown_key"}
	var run := query if query.is_valid() else Callable(CharacterManager, "db_query")
	if op == "get":
		var rows: Array = run.call("SELECT value FROM world.state WHERE key = $1", [key])
		if rows.is_empty():
			return {"ok": true, "found": false}
		return {"ok": true, "found": true, "value": float(rows[0].get("value", 0.0))}
	if op == "set":
		var value := float(params.get("value", 0.0))
		if not is_finite(value):
			return {"ok": false, "error": "invalid_value"}
		var rows: Array = run.call(
			(
				"INSERT INTO world.state (key, value, updated_at) VALUES ($1, $2, NOW()) "
				+ "ON CONFLICT (key) DO UPDATE SET value = $2, updated_at = NOW() RETURNING key"
			),
			[key, value]
		)
		return {"ok": not rows.is_empty()}
	return {"ok": false, "error": "unknown_op"}
