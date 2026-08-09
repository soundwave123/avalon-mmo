extends GutTest

# T-734: the world.state KV seam behind world_state_op — the day/night clock's persistence.
# Injected-query discipline (the OpsStore test idiom): _query records SQL + params and fakes rows,
# so every path is proven headlessly without Postgres.

const WorldStateStore = preload("res://scripts/world_state_store.gd")

var _queries: Array = []
var _stored: Dictionary = {}  # key -> value, so a set/get round-trip is honest


func before_each() -> void:
	_queries.clear()
	_stored.clear()


func _query(sql: String, params: Array) -> Array:
	_queries.append([sql, params.duplicate(true)])
	if sql.begins_with("SELECT"):
		if _stored.has(params[0]):
			return [{"value": _stored[params[0]]}]
		return []
	if sql.begins_with("INSERT"):
		_stored[params[0]] = params[1]
		return [{"key": params[0]}]
	return []


func test_get_with_no_row_reports_found_false() -> void:
	var result := WorldStateStore.handle({"op": "get", "key": "day_t"}, _query)
	assert_true(result["ok"])
	assert_false(result["found"])
	assert_string_contains(_queries[0][0], "FROM world.state")


func test_set_upserts_and_get_round_trips() -> void:
	var set_result := WorldStateStore.handle({"op": "set", "key": "day_t", "value": 0.6125}, _query)
	assert_true(set_result["ok"])
	assert_string_contains(_queries[0][0], "ON CONFLICT (key) DO UPDATE")
	var get_result := WorldStateStore.handle({"op": "get", "key": "day_t"}, _query)
	assert_true(get_result["found"])
	assert_almost_eq(float(get_result["value"]), 0.6125, 0.000001)


func test_unknown_key_is_rejected_before_any_query() -> void:
	var result := WorldStateStore.handle({"op": "get", "key": "coins"}, _query)
	assert_false(result["ok"])
	assert_eq(result["error"], "unknown_key")
	assert_eq(_queries.size(), 0)


func test_unknown_op_is_rejected() -> void:
	var result := WorldStateStore.handle({"op": "drop", "key": "day_t"}, _query)
	assert_false(result["ok"])
	assert_eq(result["error"], "unknown_op")


func test_non_finite_value_is_rejected() -> void:
	var result := WorldStateStore.handle({"op": "set", "key": "day_t", "value": INF}, _query)
	assert_false(result["ok"])
	assert_eq(result["error"], "invalid_value")
	assert_eq(_queries.size(), 0)


func test_failed_upsert_reports_not_ok() -> void:
	var result := WorldStateStore.handle(
		{"op": "set", "key": "day_t", "value": 0.5}, func(_sql, _params): return []
	)
	assert_false(result["ok"])
