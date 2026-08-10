class_name TradeOps
extends RefCounted
const _RI = preload("res://scripts/rpc_intake.gd")  # T-754 shape guards

# T-363: the master-side trade coordinator — MASTER owns the whole trade session (state authority
# lives here, per the server-authority rule). The world resolves BOTH identities from live sessions
# (never the wire) and forwards desires; this module drives the pure TradeLogic state machine
# against the persisted inventories/balances and commits the swap ATOMICALLY:
#   - test mode: both slot sets + both coin moves applied only after the whole plan validates.
#   - DB mode:  ONE BEGIN..COMMIT script covering both characters' inventories AND both coin
#     UPDATEs — a mid-persist failure rolls the entire trade back (no partial transfer).
# Every op returns {views: [{username, view}]} so the world can mirror the session to both
# parties, plus {ended/completed/reason} lifecycle flags.

const _TL := preload("res://scripts/trade_logic.gd")
const _CM := preload("res://scripts/character_manager.gd")
const _IP := preload("res://scripts/inventory_persist.gd")
const _CL := preload("res://scripts/coin_ledger.gd")  # T-366: coin sink/faucet ledger

var _store: Dictionary = _TL.new_store()


# Single entry point (master main dispatch). params:
#   username        actor (world-resolved from the SESSION — anti-spoof)
#   action          request|accept|decline|cancel|offer_item|retract_item|offer_coins|
#                   confirm|unconfirm
#   target_username (request only; world-resolved from a live peer)
#   slot_index/count/amount  staged desires — validated here against server state
#   item_registry   world-supplied item defs (stacking/capacity checks at commit)
func op(params: Dictionary) -> Dictionary:
	var character := _resolve(str(params.get("username", "")))
	if character.is_empty():
		return {"error": "unknown_character"}
	var cid := int(character["id"])
	var out: Dictionary
	match str(params.get("action", "")):
		"request":
			out = _request(cid, params)
		"accept":
			out = _mirror(_TL.accept(_store, cid), cid)
		"decline", "cancel":
			out = _cancel(cid)
		"offer_item":
			out = _mirror(
				_TL.offer_item(
					_store,
					cid,
					int(params.get("slot_index", -1)),
					int(params.get("count", 0)),
					_CM.get_inventory(cid)
				),
				cid
			)
		"retract_item":
			out = _mirror(_TL.retract_item(_store, cid, int(params.get("slot_index", -1))), cid)
		"offer_coins":
			out = _mirror(
				_TL.offer_coins(
					_store, cid, int(params.get("amount", -1)), ServicesStore.get_coins(cid)
				),
				cid
			)
		"confirm":
			out = _confirm(cid, params)
		"unconfirm":
			out = _mirror(_TL.unconfirm(_store, cid), cid)
		_:
			out = {"error": "unknown_action"}
	return out


# A state-machine decision -> the RPC reply: an error, or the refreshed both-party views.
func _mirror(r: Dictionary, cid: int) -> Dictionary:
	if not bool(r.get("ok", false)):
		return {"error": str(r.get("reason", "rejected"))}
	return _views_payload(_TL.session_for(_store, cid))


func _request(cid: int, params: Dictionary) -> Dictionary:
	var target := _CM.get_character(str(params.get("target_username", "")))
	if target.is_empty():
		return {"error": "unknown_target"}
	var r := _TL.request(_store, cid, int(target["id"]))
	if not bool(r.get("ok", false)):
		return {"error": str(r.get("reason", "rejected"))}
	return _views_payload(_TL.session_for(_store, cid))


func _cancel(cid: int) -> Dictionary:
	var session := _TL.session_for(_store, cid)
	var r := _TL.cancel(_store, cid)
	if not bool(r.get("ok", false)):
		return {"error": str(r.get("reason", "rejected"))}
	return {"ended": true, "reason": "cancelled", "views": _ended_views(session)}


func _confirm(cid: int, params: Dictionary) -> Dictionary:
	var r := _TL.confirm(_store, cid)
	if not bool(r.get("ok", false)):
		return {"error": str(r.get("reason", "rejected"))}
	var session := _TL.session_for(_store, cid)
	if not bool(r.get("both", false)):
		return _views_payload(session)
	# Both confirmed — commit. build_commit re-validates everything against LIVE state; the
	# session closes either way (completed, or aborted with nothing moved).
	var a := int(session["a"])
	var b := int(session["b"])
	var plan := _TL.build_commit(
		session,
		_CM.get_inventory(a),
		_CM.get_inventory(b),
		ServicesStore.get_coins(a),
		ServicesStore.get_coins(b),
		_RI.shaped(params, "item_registry", {})
	)
	_TL.close(_store, int(session["id"]))
	if not bool(plan.get("ok", false)):
		return {
			"ended": true,
			"reason": "aborted_" + str(plan.get("reason", "invalid")),
			"views": _ended_views(session),
		}
	if not _persist_swap(a, b, plan, _RI.shaped(params, "item_registry", {})):
		return {"ended": true, "reason": "aborted_persist_failed", "views": _ended_views(session)}
	return {"ended": true, "completed": true, "reason": "", "views": _ended_views(session)}


# The atomic swap. Validation is already done (plan is all-or-nothing); this is pure persistence.
func _persist_swap(a: int, b: int, plan: Dictionary, item_registry: Dictionary) -> bool:
	var unlocks_a := _IP.wearable_appearance_ids(plan["slots_a"], item_registry)
	var unlocks_b := _IP.wearable_appearance_ids(plan["slots_b"], item_registry)
	if _CM._test_skip_db:
		# In-memory path: nothing here can fail after a validated plan (single writer).
		_CM._persist_inventory(a, plan["slots_a"], unlocks_a)
		_CM._persist_inventory(b, plan["slots_b"], unlocks_b)
		ServicesStore.adjust_coins(a, int(plan["coins_delta_a"]), "trade")
		ServicesStore.adjust_coins(b, int(plan["coins_delta_b"]), "trade")
		return true
	# ONE transaction: both inventories + both coin moves. ON_ERROR_STOP (pg_query.sh) aborts
	# before COMMIT on any error, so Postgres rolls the whole trade back — no race dupe, no
	# partial transfer. The coins CHECK constraint (migration 013) makes an overdraft abort too.
	var stmts: Array = ["BEGIN;"]
	var sql_params: Array = []
	_IP.append_persist(a, plan["slots_a"], stmts, sql_params, unlocks_a)
	_IP.append_persist(b, plan["slots_b"], stmts, sql_params, unlocks_b)
	for move: Array in [[a, int(plan["coins_delta_a"])], [b, int(plan["coins_delta_b"])]]:
		sql_params.append_array([int(move[0]), int(move[1])])
		stmts.append(
			(
				"UPDATE chars.characters SET coins = coins + $%d WHERE id = $%d;"
				% [sql_params.size(), sql_params.size() - 1]
			)
		)
	stmts.append("COMMIT;")
	if not _CM.db_execute("\n".join(stmts), sql_params):
		return false
	# T-366: record both transfer legs after the swap commits (observability, best-effort — a
	# ledger miss never fails the trade). A trade is a zero-sum player<->player transfer.
	_CL.record(a, int(plan["coins_delta_a"]), "trade")
	_CL.record(b, int(plan["coins_delta_b"]), "trade")
	return true


# ---- view plumbing ---------------------------------------------------------


func _resolve(username: String) -> Dictionary:
	if username == "":
		return {}
	_CM.ensure_character(username)
	return _CM.get_character(username)


func _views_payload(session: Dictionary) -> Dictionary:
	if session.is_empty():
		return {"error": "no_session"}
	var a := int(session["a"])
	var b := int(session["b"])
	var names := {a: _name_of(a), b: _name_of(b)}
	var inv_a := _CM.get_inventory(a)
	var inv_b := _CM.get_inventory(b)
	return {
		"views":
		[
			{"username": names[a], "view": _TL.view_for(session, a, names, inv_a, inv_b)},
			{"username": names[b], "view": _TL.view_for(session, b, names, inv_b, inv_a)},
		]
	}


# After close() the session dict is gone from the store but the caller kept a reference; ended
# views only need the usernames so the world can notify both parties.
func _ended_views(session: Dictionary) -> Array:
	if session.is_empty():
		return []
	return [
		{"username": _name_of(int(session["a"])), "view": {}},
		{"username": _name_of(int(session["b"])), "view": {}},
	]


func _name_of(cid: int) -> String:
	return str(_CM.get_character_by_id(cid).get("username", ""))
