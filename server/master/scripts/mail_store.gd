class_name MailStore
extends RefCounted

# T-613: persistence for the mail system (migration 049, schema `mail`). Mirrors the
# ServicesStore/CharacterManager idiom — one real-DB path + one in-memory _test_skip_db path so the
# ops layer (mail_ops.gd) unit-tests with no DB. This module owns exactly the mail table + the
# per-character send-rate window (in-memory only by design — a "modest" abuse guard, not an
# accounting ledger); mail_ops.gd owns validation/orchestration.
#
# Attachments are ESCROW: they live in the row (coins/item_id/item_count columns) from send until
# taken. claim_take()/reopen_take() implement the same claim-first, reopen-on-grant-failure shape
# as T-567's turn-in fix — a bag-full take reopens the claim so the attachment stays retryable,
# never lost.

const _CM := preload("res://scripts/character_manager.gd")
const _IP := preload("res://scripts/inventory_persist.gd")
const _CL := preload("res://scripts/coin_ledger.gd")

const REASON_MAIL_SEND := "mail_send"  # transfer (not faucet/sink — econ.coin_flow default bucket)
const REASON_MAIL_TAKE := "mail_take"

const MAX_SENDS := 5  # modest per-character rate limit: at most 5 sends per...
const SEND_WINDOW_S := 60.0  # ...rolling 60-second window.

const _SELECT_COLS := (
	"id, from_cid, to_cid, subject, body, coins, item_id, item_count, "
	+ "EXTRACT(EPOCH FROM sent_at)::bigint AS sent_at, "
	+ "(read_at IS NOT NULL) AS is_read, (taken_at IS NOT NULL) AS is_taken"
)

static var _test_skip_db: bool = false
static var _test_rows: Array = []  # {id, from_cid, to_cid, subject, body, coins, item_id,
# item_count, sent_at, is_read, is_taken}
static var _test_seq: int = 0
static var _send_log: Dictionary = {}  # character_id -> Array[float] recent send unix-times


static func reset_for_test() -> void:
	_test_skip_db = true
	_test_rows.clear()
	_test_seq = 0
	_send_log.clear()


# ---- rate limit (modest, in-memory; resets on master restart — that's fine for an abuse guard) --


static func try_consume_send_slot(character_id: int, now: float) -> bool:
	var recent: Array = []
	for t in _send_log.get(character_id, []):
		if now - float(t) < SEND_WINDOW_S:
			recent.append(t)
	if recent.size() >= MAX_SENDS:
		_send_log[character_id] = recent
		return false
	recent.append(now)
	_send_log[character_id] = recent
	return true


# ---- inbox reads ------------------------------------------------------------------------------


static func inbox(to_cid: int) -> Array:
	if _test_skip_db:
		var out: Array = []
		for row: Dictionary in _test_rows:
			if int(row["to_cid"]) == to_cid:
				out.append(row.duplicate())
		out.sort_custom(func(a, b): return int(a["id"]) > int(b["id"]))
		return out
	return _hydrate(
		_CM.db_query(
			(
				"SELECT %s FROM mail.messages WHERE to_cid = $1 ORDER BY sent_at DESC, id DESC"
				% _SELECT_COLS
			),
			[to_cid]
		)
	)


# One message, only if it belongs to `to_cid` (ownership is part of the query, not a post-check).
# Named get_message, not get() — RefCounted/Object already define get(StringName) -> Variant and a
# same-named override with a different signature is a parse error ("doesn't match the parent").
static func get_message(message_id: int, to_cid: int) -> Dictionary:
	if _test_skip_db:
		for row: Dictionary in _test_rows:
			if int(row["id"]) == message_id and int(row["to_cid"]) == to_cid:
				return row.duplicate()
		return {}
	var rows := _CM.db_query(
		"SELECT %s FROM mail.messages WHERE id = $1 AND to_cid = $2" % _SELECT_COLS,
		[message_id, to_cid]
	)
	var hydrated := _hydrate(rows)
	return hydrated[0] if not hydrated.is_empty() else {}


static func _hydrate(rows: Array) -> Array:
	var out: Array = []
	for row: Dictionary in rows:
		var sent_raw := str(row.get("sent_at", ""))
		(
			out
			. append(
				{
					"id": int(row.get("id", 0)),
					"from_cid": int(row.get("from_cid", 0)),
					"to_cid": int(row.get("to_cid", 0)),
					"subject": str(row.get("subject", "")),
					"body": str(row.get("body", "")),
					"coins": int(row.get("coins", 0)),
					"item_id": str(row.get("item_id", "")),
					"item_count": int(row.get("item_count", 0)),
					"sent_at": int(float(sent_raw)) if sent_raw != "" else 0,
					"is_read": _truthy(row.get("is_read", false)),
					"is_taken": _truthy(row.get("is_taken", false)),
				}
			)
		)
	return out


static func _truthy(v: Variant) -> bool:
	if v is bool:
		return v
	return str(v).to_lower() in ["t", "true", "1"]


# ---- mutations ---------------------------------------------------------------------------------


static func mark_read(message_id: int, to_cid: int) -> bool:
	if _test_skip_db:
		for row: Dictionary in _test_rows:
			if int(row["id"]) == message_id and int(row["to_cid"]) == to_cid:
				row["is_read"] = true
				return true
		return false
	# COALESCE keeps the FIRST read timestamp; RETURNING id is how a $1/$2 mismatch (wrong owner or
	# no such row) is told apart from a genuine already-read no-op (both would otherwise look like a
	# successful zero-effect UPDATE — _execute() has no affected-row count, only db_query()'s
	# RETURNING result does).
	var rows := _CM.db_query(
		(
			"UPDATE mail.messages SET read_at = COALESCE(read_at, now()) "
			+ "WHERE id = $1 AND to_cid = $2 RETURNING id"
		),
		[message_id, to_cid]
	)
	return not rows.is_empty()


# Idempotent claim: only the FIRST caller for a given message gets true. This is the "claim-first"
# half of the T-567 shape — take() calls this before granting anything, so a retry after a bag-full
# reopen (or a concurrent double-click) can never double-grant.
static func claim_take(message_id: int, to_cid: int) -> bool:
	if _test_skip_db:
		for row: Dictionary in _test_rows:
			if int(row["id"]) == message_id and int(row["to_cid"]) == to_cid:
				if bool(row.get("is_taken", false)):
					return false
				row["is_taken"] = true
				return true
		return false
	var rows := _CM.db_query(
		(
			"UPDATE mail.messages SET taken_at = now() "
			+ "WHERE id = $1 AND to_cid = $2 AND taken_at IS NULL RETURNING id"
		),
		[message_id, to_cid]
	)
	return not rows.is_empty()


# The reopen half: a claimed take whose item grant failed (bag full) un-claims so the attachment
# stays retryable instead of vanishing. Never called after coins have already been credited (see
# mail_ops.gd's ordering note) — reopening post-credit would double-pay on a retry.
static func reopen_take(message_id: int) -> void:
	if _test_skip_db:
		for row: Dictionary in _test_rows:
			if int(row["id"]) == message_id:
				row["is_taken"] = false
		return
	_CM.db_execute("UPDATE mail.messages SET taken_at = NULL WHERE id = $1", [message_id])


# Only deletable once nothing is left to lose: no attachments at all, or attachments already taken.
static func delete(message_id: int, to_cid: int) -> bool:
	if _test_skip_db:
		for i in range(_test_rows.size()):
			var row: Dictionary = _test_rows[i]
			if int(row["id"]) == message_id and int(row["to_cid"]) == to_cid:
				var has_attachments := (
					int(row.get("coins", 0)) > 0
					or (str(row.get("item_id", "")) != "" and int(row.get("item_count", 0)) > 0)
				)
				if has_attachments and not bool(row.get("is_taken", false)):
					return false
				_test_rows.remove_at(i)
				return true
		return false
	var rows := _CM.db_query(
		(
			"DELETE FROM mail.messages WHERE id = $1 AND to_cid = $2 AND "
			+ "((coins = 0 AND item_count = 0) OR taken_at IS NOT NULL) RETURNING id"
		),
		[message_id, to_cid]
	)
	return not rows.is_empty()


# T-567 idiom: the sender's coin debit + item removal + the new escrow row commit in ONE
# transaction (BEGIN..COMMIT; a mid-write failure rolls the whole send back — no coins-gone-
# item-kept or item-gone-coins-kept split). `slots` is the sender's inventory AFTER the attached
# item (if any) was removed by the pure InventoryLogic.remove() call in mail_ops.gd — persisting it
# unconditionally is a harmless no-op rewrite when no item was attached. coin_delta is 0 for a
# coinless mail (commit_inventory_coins can't be reused here — it hard-rejects delta == 0, which is
# a normal case for mail: item-only, or a plain text message with nothing attached).
static func commit_send(
	from_cid: int,
	slots: Array,
	coin_delta: int,
	to_cid: int,
	subject: String,
	body: String,
	coins: int,
	item_id: String,
	item_count: int
) -> bool:
	if _test_skip_db:
		if (
			coin_delta != 0
			and not ServicesStore.adjust_coins(from_cid, coin_delta, REASON_MAIL_SEND)
		):
			return false
		if item_id != "":
			_CM._persist_inventory(from_cid, slots)
		_test_seq += 1
		(
			_test_rows
			. append(
				{
					"id": _test_seq,
					"from_cid": from_cid,
					"to_cid": to_cid,
					"subject": subject,
					"body": body,
					"coins": coins,
					"item_id": item_id,
					"item_count": item_count,
					"sent_at": int(Time.get_unix_time_from_system()),
					"is_read": false,
					"is_taken": false,
				}
			)
		)
		return true

	var stmts: Array = ["BEGIN;"]
	var params: Array = []
	if item_id != "":
		_IP.append_persist(from_cid, slots, stmts, params)
	if coin_delta != 0:
		params.append_array([from_cid, coin_delta])
		stmts.append(
			(
				(
					"UPDATE chars.characters SET coins = coins + $%d "
					+ "WHERE id = $%d AND coins + $%d >= 0;"
				)
				% [params.size(), params.size() - 1, params.size()]
			)
		)
	var base: int = params.size()
	params.append_array([from_cid, to_cid, subject, body, coins, item_id, item_count])
	stmts.append(
		(
			(
				"INSERT INTO mail.messages (from_cid, to_cid, subject, body, coins, item_id, "
				+ "item_count) VALUES ($%d,$%d,$%d,$%d,$%d,$%d,$%d);"
			)
			% [base + 1, base + 2, base + 3, base + 4, base + 5, base + 6, base + 7]
		)
	)
	stmts.append("COMMIT;")
	var ok := _CM.db_execute("\n".join(stmts), params)
	if ok and coin_delta != 0:
		_CL.record(from_cid, coin_delta, REASON_MAIL_SEND)  # T-366: best-effort, mirrors trade_ops
	return ok
