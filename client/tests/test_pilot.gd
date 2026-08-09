extends GutTest

# T-180: the pilot `goto` op walks the player to a distant target in rate-legal hops so distant-zone
# QA (Highkeep service NPCs, Crystal Lake) stops costing ~15 pilot walk round-trips. Headless: no
# server/net, so these prove the op is registered, resolves the player, and MOVES the LocalPlayer
# node to the target at the safe height. The server-side proximity acceptance (goto -> click NPC ->
# service panel) is a live orchestrator demo (talk is proximity-gated on the SERVER position).

const Pilot = preload("res://scripts/dev/pilot.gd")
const LocalPlayer = preload("res://scripts/world/local_player.gd")

# T-346: isolate the pilot command dir. The Pilot node polls AVALON_PILOT_DIR/cmds.jsonl every
# _process frame and executes EVERY line it hasn't seen (line index = command id). Under GUT the
# default dir (/tmp/avalon-pilot) is the SAME one a live pilot/dev session writes to — so a stale
# backlog there (ending in {"op":"quit"}) made the test's Pilot call get_tree().quit() mid-suite,
# killing the whole client run before later test files ran. Latent on 4.6 (autofree freed the
# Pilot before its _process fired); deterministic on 4.7 (changed node-free/process timing lets the
# _process frame land during the awaited goto). Point every Pilot at a private empty dir so the
# test can never read live command state. Root cause of the T-337 "intermittent PagedAllocator
# crash" blocker.
var _pilot_dir := ""


func before_all() -> void:
	_pilot_dir = OS.get_user_data_dir().path_join("pilot_test_%d" % OS.get_process_id())
	OS.set_environment("AVALON_PILOT_DIR", _pilot_dir)


func before_each() -> void:
	# Start each test from an empty command dir (no cross-test or stale-session leakage).
	DirAccess.make_dir_recursive_absolute(_pilot_dir)
	var d := DirAccess.open(_pilot_dir)
	if d != null:
		for f in d.get_files():
			d.remove(f)


func _pilot_with_player(start: Vector3) -> Array:
	var player: LocalPlayer = LocalPlayer.new()
	player.name = "LocalPlayer"
	add_child_autofree(player)  # _ready builds the body + camera rig
	player.global_position = start
	var pilot = Pilot.new()
	add_child_autofree(pilot)  # _ready just makes the pilot command dir
	return [pilot, player]


func test_local_player_resolves_by_name_without_main() -> void:
	var pair := _pilot_with_player(Vector3(1, 0, 2))
	assert_eq(pair[0]._local_player(), pair[1], "resolves the LocalPlayer with no scripted Main")


func test_goto_moves_local_player_to_target() -> void:
	var pair := _pilot_with_player(Vector3.ZERO)
	# Single-hop target (5 u < the per-hop cap) so no rate-window wait is needed here.
	await pair[0]._op_goto(0, 3.0, 1.0, 4.0)
	var pos: Vector3 = pair[1].global_position
	assert_almost_eq(pos.x, 3.0, 0.5, "player reached target x")
	assert_almost_eq(pos.z, 4.0, 0.5, "player reached target z")
	assert_almost_eq(pos.y, 1.0, 0.01, "player placed at the safe height")


func test_goto_with_no_player_is_a_safe_noop() -> void:
	var pilot = Pilot.new()
	add_child_autofree(pilot)  # no LocalPlayer in the tree
	pilot._op_goto(0, 9.0, 1.0, -116.0)  # must ack an error, not crash
	assert_null(pilot._local_player(), "no player to resolve -> null (op acks ok:false)")


# T-623 (#57): the goto ack must be ARRIVAL-VERIFIED, not a blind ok:true — this proves the wiring
# between _op_goto and PilotChecks.goto_arrival (the pass/fail MATH itself is unit-tested directly
# in test_pilot_checks.gd; hitting the real _GOTO_MAX_HOPS failure path needs a live server that can
# reject a hop, so that half is live-pilot-verified only, per this ticket's own note).
func test_goto_ack_reports_arrival_verified_fields_on_success() -> void:
	var pair := _pilot_with_player(Vector3.ZERO)
	await pair[0]._op_goto(6, 3.0, 1.0, 4.0)  # 5u target, well inside one hop
	var ack := _read_ack(6)
	assert_true(bool(ack["ok"]), "reached the target within tolerance -> ok:true")
	assert_has(ack, "dist", "arrival distance always reported, even on success")
	assert_almost_eq(float(ack["dist"]), 0.0, 0.5, "landed essentially on target")
	assert_eq(int(ack["hops"]), 1, "a 5u target resolves in a single hop")


# T-623 (session-12 "look sometimes inert"): pure verification math lives in test_pilot_checks.gd;
# this proves _op_look's ack actually carries the verification result when no player exists to
# turn at all (the one live-reachable failure path without real input-pipeline routing, which GUT's
# headless tree doesn't reliably deliver to _unhandled_input — see test_local_player.gd's own
# precedent of calling _unhandled_input directly rather than through Input.parse_input_event).
func test_look_acks_false_with_no_player_to_verify() -> void:
	var pilot = Pilot.new()
	add_child_autofree(pilot)  # no LocalPlayer in the tree
	await pilot._op_look(7, 50.0, 0.0)
	var ack := _read_ack(7)
	assert_false(
		bool(ack["ok"]), "nothing to verify rotation against -> ok:false, not a lied ok:true"
	)
	assert_true(str(ack["error"]).contains("LocalPlayer"), "reason names the missing player")


# ---- wait_until (T-623) --------------------------------------------------------------------------
# Pure path-resolve/comparator grammar is unit-tested directly in test_pilot_wait.gd; these prove
# the live poll loop actually resolves immediately vs. actually times out.


func test_wait_until_matches_immediately_without_waiting_out_the_timeout() -> void:
	var pilot = Pilot.new()
	add_child_autofree(pilot)  # no Main in the tree -> _dump_state() == {"error": "no Main"}
	await pilot._op_wait_until(8, "error", "no Main", 5.0)
	var ack := _read_ack(8)
	assert_true(bool(ack["ok"]), "already-true condition resolves without waiting out a 5s timeout")


func test_wait_until_times_out_and_reports_the_reason() -> void:
	var pilot = Pilot.new()
	add_child_autofree(pilot)
	await pilot._op_wait_until(9, "nonexistent_key", "true", 0.1)
	var ack := _read_ack(9)
	assert_false(bool(ack["ok"]), "condition never true -> ok:false")
	assert_eq(str(ack["error"]), "timeout", "explicit timeout reason, not a silent hang")


# ---- batch (T-623) --------------------------------------------------------------------------
# One combined ack for N sub-ops, run through the SAME dispatch (_run) a solo invocation uses.


func test_batch_runs_ops_in_order_and_collects_one_ack_per_op() -> void:
	var pilot = Pilot.new()
	add_child_autofree(pilot)
	await pilot._op_batch(10, [{"op": "wait_frames", "frames": 1}, {"op": "ui"}])
	var ack := _read_ack(10)
	assert_true(bool(ack["ok"]), "both sub-ops succeeded -> batch ok:true")
	var results: Array = ack["results"]
	assert_eq(results.size(), 2, "two ops -> two results")
	assert_true(bool(results[0]["ok"]), "wait_frames sub-op ok")
	assert_true(bool(results[1]["ok"]), "ui sub-op ok")
	assert_has(results[1], "controls", "the ui op's real payload rides through unmodified")


func test_batch_partial_failure_continues_and_reports_every_result() -> void:
	var pilot = Pilot.new()
	add_child_autofree(pilot)
	await pilot._op_batch(11, [{"op": "ui"}, {"op": "not_a_real_op"}, {"op": "ui"}])
	var ack := _read_ack(11)
	assert_false(bool(ack["ok"]), "one failing sub-op -> overall batch ok:false")
	var results: Array = ack["results"]
	assert_eq(results.size(), 3, "the batch did NOT stop at the failing op")
	assert_true(bool(results[0]["ok"]), "op 0 (ui) ok")
	assert_false(bool(results[1]["ok"]), "op 1 (unknown op) failed")
	assert_true(str(results[1]["error"]).contains("unknown op"), "failure reason preserved")
	assert_true(bool(results[2]["ok"]), "op 2 (ui) still ran after the earlier failure")


func test_batch_rejects_a_non_array_ops_payload() -> void:
	var pilot = Pilot.new()
	add_child_autofree(pilot)
	await pilot._op_batch(12, "not an array")
	var ack := _read_ack(12)
	assert_false(bool(ack["ok"]), "malformed ops payload -> ok:false, not a crash")


func test_batch_reports_non_dict_items_without_derailing_the_rest() -> void:
	var pilot = Pilot.new()
	add_child_autofree(pilot)
	await pilot._op_batch(13, [{"op": "ui"}, "oops", {"op": "ui"}])
	var results: Array = _read_ack(13)["results"]
	assert_eq(results.size(), 3, "still one result per item, including the malformed one")
	assert_false(bool(results[1]["ok"]), "the non-dict item is reported, not crashed on")
	assert_true(bool(results[2]["ok"]), "the item after it still ran")


func _read_ack(id: int) -> Dictionary:
	var f := FileAccess.open(_pilot_dir.path_join("ack_%d.json" % id), FileAccess.READ)
	assert_not_null(f, "ack file for id %d was written" % id)
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed
