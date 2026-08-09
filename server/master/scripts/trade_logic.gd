class_name TradeLogic
extends RefCounted

# T-363: PURE player-to-player trade state machine. Trading is THE classic dupe/scam vector, so
# every decision lives here where it unit-tests exhaustively — no DB, no OS time, no I/O.
#
# Flow (server-owned; the client only sends desires):
#   request -> accept -> both sides stage items/coins -> both confirm -> ATOMIC swap.
# Scam guards baked into the machine:
#   - ANY offer change (item staged/retracted, coins changed) clears BOTH confirms — the classic
#     "swap the offer after they confirmed" bait is structurally impossible.
#   - Staging validates against the SERVER-held inventory/balance snapshot the caller passes in;
#     the wire's claims are never the source of truth.
#   - build_commit() re-validates EVERYTHING against live state at commit time (an item that
#     vanished mid-trade aborts the whole trade) and returns an all-or-nothing plan: both final
#     slot sets + both coin deltas, or a rejection. The caller persists it in ONE transaction.
#
# Store shape (caller owns it, mirroring party_logic):
#   sessions:   sid -> {id, a, b, state: "pending"|"active",
#                       offers: {cid -> {items: [{slot_index, count}], coins: int}},
#                       confirmed: {cid -> bool}}
#   session_of: cid -> sid  (a character is in at most ONE trade at a time)
#   next_id:    monotonic

const _IL = preload("res://scripts/inventory_logic.gd")

const MAX_OFFER_ITEMS := 6  # staging grid size (both UX and an offer-payload bound)


static func new_store() -> Dictionary:
	return {"sessions": {}, "session_of": {}, "next_id": 1}


# from_cid asks to_cid to trade. Both must be free of any other session; no self-trade.
static func request(store: Dictionary, from_cid: int, to_cid: int) -> Dictionary:
	if from_cid == to_cid:
		return {"ok": false, "reason": "self_trade"}
	if store["session_of"].has(from_cid):
		return {"ok": false, "reason": "already_trading"}
	if store["session_of"].has(to_cid):
		return {"ok": false, "reason": "target_busy"}
	var sid: int = int(store["next_id"])
	store["next_id"] = sid + 1
	store["sessions"][sid] = {
		"id": sid,
		"a": from_cid,
		"b": to_cid,
		"state": "pending",
		"offers": {from_cid: _empty_offer(), to_cid: _empty_offer()},
		"confirmed": {from_cid: false, to_cid: false},
	}
	store["session_of"][from_cid] = sid
	store["session_of"][to_cid] = sid
	return {"ok": true, "reason": "", "session_id": sid}


# Only the INVITEE can accept, and only a pending session.
static func accept(store: Dictionary, cid: int) -> Dictionary:
	var s := _session(store, cid)
	if s.is_empty():
		return {"ok": false, "reason": "no_session"}
	if str(s["state"]) != "pending":
		return {"ok": false, "reason": "not_pending"}
	if int(s["b"]) != cid:
		return {"ok": false, "reason": "not_invitee"}
	s["state"] = "active"
	return {"ok": true, "reason": ""}


# Either party ends the trade at ANY point pre-commit (decline == cancel of a pending session).
# Nothing has moved yet by construction, so cancel never needs a rollback.
static func cancel(store: Dictionary, cid: int) -> Dictionary:
	var s := _session(store, cid)
	if s.is_empty():
		return {"ok": false, "reason": "no_session"}
	var other: int = int(s["b"]) if int(s["a"]) == cid else int(s["a"])
	close(store, int(s["id"]))
	return {"ok": true, "reason": "", "other": other}


# Stage one bag stack (or part of it). `inventory` is the SERVER-held slot list for cid — the
# offer is rejected unless the slot really holds >= count of something. Clears both confirms.
static func offer_item(
	store: Dictionary, cid: int, slot_index: int, count: int, inventory: Array
) -> Dictionary:
	var s := _active_session(store, cid)
	if s.is_empty():
		return {"ok": false, "reason": "no_active_session"}
	if count < 1:
		return {"ok": false, "reason": "bad_count"}
	var held := _bag_count(inventory, slot_index)
	if held <= 0:
		return {"ok": false, "reason": "not_owned"}
	if count > held:
		return {"ok": false, "reason": "insufficient_count"}
	var offer: Dictionary = s["offers"][cid]
	for entry: Dictionary in offer["items"]:
		if int(entry["slot_index"]) == slot_index:
			return {"ok": false, "reason": "already_offered"}
	if offer["items"].size() >= MAX_OFFER_ITEMS:
		return {"ok": false, "reason": "offer_full"}
	offer["items"].append({"slot_index": slot_index, "count": count})
	_clear_confirms(s)
	return {"ok": true, "reason": ""}


static func retract_item(store: Dictionary, cid: int, slot_index: int) -> Dictionary:
	var s := _active_session(store, cid)
	if s.is_empty():
		return {"ok": false, "reason": "no_active_session"}
	var offer: Dictionary = s["offers"][cid]
	for i in range(offer["items"].size()):
		if int(offer["items"][i]["slot_index"]) == slot_index:
			offer["items"].remove_at(i)
			_clear_confirms(s)
			return {"ok": true, "reason": ""}
	return {"ok": false, "reason": "not_offered"}


# Stage a coin amount (replaces the previous amount). Validated against the SERVER-held balance.
static func offer_coins(store: Dictionary, cid: int, amount: int, balance: int) -> Dictionary:
	var s := _active_session(store, cid)
	if s.is_empty():
		return {"ok": false, "reason": "no_active_session"}
	if amount < 0:
		return {"ok": false, "reason": "bad_amount"}
	if amount > balance:
		return {"ok": false, "reason": "insufficient_coins"}
	s["offers"][cid]["coins"] = amount
	_clear_confirms(s)
	return {"ok": true, "reason": ""}


# Returns {ok, both} — both=true means the caller must now run build_commit + persist + close.
static func confirm(store: Dictionary, cid: int) -> Dictionary:
	var s := _active_session(store, cid)
	if s.is_empty():
		return {"ok": false, "reason": "no_active_session", "both": false}
	s["confirmed"][cid] = true
	var both: bool = bool(s["confirmed"][int(s["a"])]) and bool(s["confirmed"][int(s["b"])])
	return {"ok": true, "reason": "", "both": both}


static func unconfirm(store: Dictionary, cid: int) -> Dictionary:
	var s := _active_session(store, cid)
	if s.is_empty():
		return {"ok": false, "reason": "no_active_session"}
	s["confirmed"][cid] = false
	return {"ok": true, "reason": ""}


# The commit plan — ALL-OR-NOTHING. Re-validates both offers against the LIVE inventories and
# balances (never the staging-time snapshots): an item that vanished or a balance that dropped
# since staging aborts the whole trade with nothing moved. On success returns both final slot
# sets + both coin deltas; the caller persists them in one atomic transaction and closes the
# session. Pure — deterministic function of its inputs.
static func build_commit(
	session: Dictionary,
	inv_a: Array,
	inv_b: Array,
	coins_a: int,
	coins_b: int,
	registry: Dictionary
) -> Dictionary:
	var a: int = int(session["a"])
	var b: int = int(session["b"])
	var offer_a: Dictionary = session["offers"][a]
	var offer_b: Dictionary = session["offers"][b]
	if int(offer_a["coins"]) > coins_a or int(offer_b["coins"]) > coins_b:
		return {"ok": false, "reason": "insufficient_coins"}
	var give_a := _resolve_offer(offer_a, inv_a)  # what A hands over, as {item_id, count}
	var give_b := _resolve_offer(offer_b, inv_b)
	if not bool(give_a["ok"]) or not bool(give_b["ok"]):
		return {"ok": false, "reason": "item_gone"}
	# Remove each side's staged items, then add the OTHER side's items (capacity re-checked by
	# the pure inventory model). Any failure rejects the entire trade.
	var out_a := _apply_side(inv_a, offer_a["items"], give_b["items"], registry)
	if not bool(out_a["ok"]):
		return {"ok": false, "reason": str(out_a["reason"])}
	var out_b := _apply_side(inv_b, offer_b["items"], give_a["items"], registry)
	if not bool(out_b["ok"]):
		return {"ok": false, "reason": str(out_b["reason"])}
	return {
		"ok": true,
		"reason": "",
		"slots_a": out_a["slots"],
		"slots_b": out_b["slots"],
		"coins_delta_a": int(offer_b["coins"]) - int(offer_a["coins"]),
		"coins_delta_b": int(offer_a["coins"]) - int(offer_b["coins"]),
	}


static func close(store: Dictionary, sid: int) -> void:
	var s: Dictionary = store["sessions"].get(sid, {})
	if s.is_empty():
		return
	store["session_of"].erase(int(s["a"]))
	store["session_of"].erase(int(s["b"]))
	store["sessions"].erase(sid)


static func session_for(store: Dictionary, cid: int) -> Dictionary:
	return _session(store, cid)


# Client-facing snapshot for ONE party: both offers resolved to item ids (from that side's
# server-held inventory), confirm flags, partner name, and the viewer's own bag (so the trade
# panel needs no second data source — everything it shows is server truth).
static func view_for(
	session: Dictionary, cid: int, names: Dictionary, inv_mine: Array, inv_theirs: Array
) -> Dictionary:
	var other: int = int(session["b"]) if int(session["a"]) == cid else int(session["a"])
	return {
		"state": str(session["state"]),
		"partner": str(names.get(other, "")),
		"mine": _offer_view(session["offers"][cid], inv_mine),
		"theirs": _offer_view(session["offers"][other], inv_theirs),
		"my_confirm": bool(session["confirmed"][cid]),
		"their_confirm": bool(session["confirmed"][other]),
		"my_bag": _bag_view(inv_mine),
	}


# ---- internals -----------------------------------------------------------


static func _empty_offer() -> Dictionary:
	return {"items": [], "coins": 0}


static func _session(store: Dictionary, cid: int) -> Dictionary:
	var sid: int = int(store["session_of"].get(cid, -1))
	if sid == -1:
		return {}
	return store["sessions"].get(sid, {})


static func _active_session(store: Dictionary, cid: int) -> Dictionary:
	var s := _session(store, cid)
	if s.is_empty() or str(s["state"]) != "active":
		return {}
	return s


static func _clear_confirms(session: Dictionary) -> void:
	session["confirmed"][int(session["a"])] = false
	session["confirmed"][int(session["b"])] = false


static func _bag_count(inventory: Array, slot_index: int) -> int:
	for entry: Dictionary in inventory:
		if str(entry["slot_type"]) == "bag" and int(entry["slot_index"]) == slot_index:
			return int(entry["item_count"])
	return 0


static func _bag_item(inventory: Array, slot_index: int) -> Dictionary:
	for entry: Dictionary in inventory:
		if str(entry["slot_type"]) == "bag" and int(entry["slot_index"]) == slot_index:
			return entry
	return {}


# Staged {slot_index, count} rows -> concrete {item_id, count} against a LIVE inventory.
# Fails if any staged slot no longer holds enough (the mid-trade-vanish guard).
static func _resolve_offer(offer: Dictionary, inventory: Array) -> Dictionary:
	var items: Array = []
	for staged: Dictionary in offer["items"]:
		var entry := _bag_item(inventory, int(staged["slot_index"]))
		if entry.is_empty() or int(entry["item_count"]) < int(staged["count"]):
			return {"ok": false, "items": []}
		items.append({"item_id": str(entry["item_id"]), "count": int(staged["count"])})
	return {"ok": true, "items": items}


# One side's final slots: remove what they staged, then add what the other side staged.
static func _apply_side(
	inventory: Array, staged_out: Array, incoming: Array, registry: Dictionary
) -> Dictionary:
	var slots := inventory.duplicate(true)
	for staged: Dictionary in staged_out:
		var removed := _IL.remove(slots, "bag", int(staged["slot_index"]), int(staged["count"]))
		if not bool(removed["ok"]):
			return {"ok": false, "reason": str(removed["reason"])}
		slots = removed["slots"]
	if not incoming.is_empty():
		var added := _IL.add_items(slots, incoming, registry)
		if not bool(added["ok"]):
			return {"ok": false, "reason": str(added["reason"])}
		slots = added["slots"]
	return {"ok": true, "reason": "", "slots": slots}


static func _offer_view(offer: Dictionary, inventory: Array) -> Dictionary:
	var items: Array = []
	for staged: Dictionary in offer["items"]:
		var entry := _bag_item(inventory, int(staged["slot_index"]))
		(
			items
			. append(
				{
					"slot_index": int(staged["slot_index"]),
					"item_id": str(entry.get("item_id", "?")),
					"count": int(staged["count"]),
				}
			)
		)
	return {"items": items, "coins": int(offer["coins"])}


static func _bag_view(inventory: Array) -> Array:
	var out: Array = []
	for entry: Dictionary in inventory:
		if str(entry["slot_type"]) == "bag":
			(
				out
				. append(
					{
						"slot_index": int(entry["slot_index"]),
						"item_id": str(entry["item_id"]),
						"item_count": int(entry["item_count"]),
					}
				)
			)
	out.sort_custom(func(x, y): return int(x["slot_index"]) < int(y["slot_index"]))
	return out
