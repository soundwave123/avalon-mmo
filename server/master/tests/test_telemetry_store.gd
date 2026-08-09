extends GutTest
# T-186: the master telemetry store — batch record in test mode (no DB), the single-writer path.

const TelemetryStore = preload("res://scripts/telemetry_store.gd")


func before_each() -> void:
	TelemetryStore.reset_for_test()


func test_records_a_batch_of_events() -> void:
	var events := [
		{"event_type": "session_start", "account": "acc", "character": "hero", "payload": {}},
		{"event_type": "death", "account": "acc", "character": "hero", "payload": {"lvl": 3}},
	]
	var res := TelemetryStore.record_events(events)
	assert_eq(int(res["written"]), 2, "both events written")
	assert_eq(TelemetryStore.test_events().size(), 2, "store holds the batch")
	assert_eq(str(TelemetryStore.test_events()[1]["event_type"]), "death")


func test_empty_batch_writes_nothing() -> void:
	var res := TelemetryStore.record_events([])
	assert_eq(int(res["written"]), 0, "an empty flush is a no-op")
	assert_eq(TelemetryStore.test_events().size(), 0)


func test_appends_across_calls() -> void:
	TelemetryStore.record_events([{"event_type": "a", "account": null, "character": null}])
	TelemetryStore.record_events([{"event_type": "b", "account": null, "character": null}])
	assert_eq(TelemetryStore.test_events().size(), 2, "append-only across flushes")
