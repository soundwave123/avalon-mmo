extends GutTest

# T-517 regression: native Godot 4.7's OS.execute re-tokenizes argv (embedded double quotes
# stripped, split on surrounding spaces), so a JSON `details` param reached psql as invalid
# jsonb and EVERY mutating GM ops verb failed with audit_write_failed. database.gd now base64-
# armors params (-w) and the SQL (-Q); these tests exercise the REAL database + pg_query.sh
# chain — the T-511 test mocked the DB, which is exactly why this shipped broken.
const OpsStore = preload("res://scripts/ops_store.gd")
const CharacterManager = preload("res://scripts/character_manager.gd")

# Dev-container password (POSTGRES_PASSWORD in avalon-postgres; dev-only by construction).
const _DEV_PG_PASSWORD := "avalon_dev_only_not_for_prod"


func _db_available() -> bool:
	if OS.get_environment("AVALON_PG_PASSWORD") == "":
		OS.set_environment("AVALON_PG_PASSWORD", _DEV_PG_PASSWORD)
	var rows: Array = CharacterManager.db_query("SELECT 1 AS one", [])
	return not rows.is_empty()


func test_json_param_with_spaces_and_quotes_survives_to_jsonb() -> void:
	if not _db_available():
		pending("Postgres not reachable — real-DB jsonb round-trip not exercised")
		return
	var details := {"minutes": 1.0, "reason": "stderr capture test"}
	var rows: Array = CharacterManager.db_query(
		"SELECT $1::jsonb AS details", [JSON.stringify(details)]
	)
	assert_eq(rows.size(), 1, "jsonb cast must not fail on a spacey JSON param")
	if rows.is_empty():
		return
	var parsed: Variant = JSON.parse_string(str(rows[0].get("details", "")))
	assert_true(parsed is Dictionary, "stored details must round-trip as JSON")
	if parsed is Dictionary:
		assert_eq(str(parsed.get("reason", "")), "stderr capture test")
		assert_eq(int(parsed.get("minutes", 0)), 1)


func test_ops_store_apply_writes_real_audit_row_with_spacey_reason() -> void:
	if not _db_available():
		pending("Postgres not reachable — real audit_log write not exercised")
		return
	# Simulate the exact master-side value: the world dict after the JSON RPC round-trip
	# (ints arrive as floats — must still be valid jsonb).
	var details: Variant = JSON.parse_string(
		JSON.stringify({"minutes": 1, "reason": "t517 space containing reason"})
	)
	var result := (
		OpsStore
		. apply(
			{
				"actor": "t517_test",
				"action": "kick",
				"target": "t517_dummy",
				"reason": "t517 space containing reason",
				"details": details,
			}
		)
	)
	assert_true(bool(result.get("ok", false)), "mutating verb audit insert must succeed")
	var audit_id := int(result.get("audit_id", 0))
	assert_gt(audit_id, 0, "audit row id returned")
	if audit_id <= 0:
		return
	var rows: Array = CharacterManager.db_query(
		"SELECT actor, reason, details FROM ops.audit_log WHERE id = $1", [audit_id]
	)
	assert_eq(rows.size(), 1, "audit row must exist")
	if not rows.is_empty():
		assert_eq(str(rows[0].get("reason", "")), "t517 space containing reason")
		var stored: Variant = JSON.parse_string(str(rows[0].get("details", "")))
		assert_true(stored is Dictionary, "details column must hold real jsonb")
		if stored is Dictionary:
			assert_eq(str(stored.get("reason", "")), "t517 space containing reason")
	# Append-only table, but test rows are ours to reap.
	CharacterManager.db_execute("DELETE FROM ops.audit_log WHERE id = $1", [audit_id])
