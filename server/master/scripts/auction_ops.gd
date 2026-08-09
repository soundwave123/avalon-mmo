class_name AuctionOps
extends RefCounted
# T-426 (carve): the auction-house RPC handlers, extracted verbatim from master/main.gd to keep that
# dispatcher under the 1000-line cap. Pure dispatch over the global stores (ServicesStore /
# AuctionLogic / CharacterManager / ServerConfig); no per-request state. main._dispatch routes the
# "auction" method to op(); behavior is identical to the former main._auction_* methods.

const CharacterManager := preload("res://scripts/character_manager.gd")


static func live_view() -> Array:
	var out: Array = []
	for a in ServicesStore.auction_rows(true):
		(
			out
			. append(
				{
					"id": int(a["id"]),
					"item_id": str(a["item_id"]),
					"item_count": int(a["item_count"]),
					"min_bid": int(a["min_bid"]),
					"buyout": int(a.get("buyout", 0)),
					"high_bid": int(a.get("high_bid", 0)),
					"seller_id": int(a["seller_id"]),
				}
			)
		)
	return out


static func sweep_expired(item_registry: Dictionary = {}) -> void:
	# Lazy expiry on every browse/list/bid/buyout — no timer needed at this scale.
	# T-609 fail-closed idiom (same shape as T-567's try_turn_in_with_rewards): a lot may only be
	# CLOSED (and, for a sale, only PAID) once its deliverable is durably granted. `due` covers both
	# freshly-expired lots AND lots stranded pending_sold/pending_expired from a prior failed grant
	# (bag full) — both are retried with the identical settlement math (resolve_expiry is pure and
	# reads only high_bid/high_bidder_id, which a pending row never mutates, so a retry recomputes
	# the same outcome). A lot that fails again simply stays pending for the next sweep; nothing is
	# destroyed and nothing is paid twice.
	var due := ServicesStore.auction_expired_live()
	due.append_array(ServicesStore.auction_pending_rows())
	for a in due:
		var res := AuctionLogic.resolve_expiry(a)
		if str(res["outcome"]) == "sold":
			# grant the item FIRST: only pay the seller and close the lot once delivery is durable.
			var granted := CharacterManager.try_add_items(
				int(res["winner_id"]),
				[{"item": str(a["item_id"]), "count": int(a["item_count"])}],
				item_registry
			)
			if not bool(granted.get("ok", false)):
				ServicesStore.auction_close(int(a["id"]), "pending_sold")
				continue
			ServicesStore.adjust_coins(int(a["seller_id"]), int(res["seller_gets"]), "auction_sale")
			ServicesStore.auction_close(int(a["id"]), "sold")
		else:
			var granted := CharacterManager.try_add_items(
				int(a["seller_id"]),
				[{"item": str(a["item_id"]), "count": int(a["item_count"])}],
				item_registry
			)
			if not bool(granted.get("ok", false)):
				ServicesStore.auction_close(int(a["id"]), "pending_expired")
				continue
			ServicesStore.auction_close(int(a["id"]), "expired")


static func op(params: Dictionary) -> Dictionary:
	var username := str(params.get("username", ""))
	CharacterManager.ensure_character(username)
	var character := CharacterManager.get_character(username)
	if character.is_empty():
		return {"error": "unknown_character"}
	var cid := int(character["id"])
	sweep_expired(params.get("item_registry", {}))
	match str(params.get("action", "browse")):
		"list":
			return list_item(cid, params)
		"bid":
			return bid(cid, params)
		"buyout":
			return buyout(cid, params)
		_:
			return {"auctions": live_view(), "coins": ServicesStore.get_coins(cid)}


static func list_item(cid: int, params: Dictionary) -> Dictionary:
	var live := 0
	for a in ServicesStore.auction_rows(true):
		if int(a["seller_id"]) == cid:
			live += 1
	var check := AuctionLogic.can_list(
		int(params.get("min_bid", 0)),
		int(params.get("buyout", 0)),
		int(params.get("duration_s", 3600)),
		live
	)
	if not bool(check.get("ok", false)):
		return {"error": str(check.get("reason", "bad_listing"))}
	# the listed stack leaves the seller's bag into escrow
	var from_index := int(params.get("from_index", -1))
	var stack := {}
	for entry in CharacterManager.get_inventory(cid):
		if str(entry["slot_type"]) == "bag" and int(entry["slot_index"]) == from_index:
			stack = entry
			break
	if stack.is_empty():
		return {"error": "empty_slot"}
	# T-412: charge the listing fee (a coin SINK). Affordability is checked BEFORE the item leaves the
	# bag so a broke seller never loses the stack; the debit ledgers reason "auction_fee".
	var fee := AuctionLogic.listing_fee(
		int(params.get("min_bid", 0)),
		ServerConfig.AUCTION_LISTING_FEE_FLAT,
		ServerConfig.AUCTION_LISTING_FEE_BPS
	)
	if fee > 0 and ServicesStore.get_coins(cid) < fee:
		return {"error": "insufficient_coins", "fee": fee}
	if not CharacterManager.remove_item(cid, "bag", from_index):
		return {"error": "persist_failed"}
	if fee > 0:
		ServicesStore.adjust_coins(cid, -fee, "auction_fee")
	var aid := ServicesStore.auction_insert(
		cid,
		str(stack["item_id"]),
		int(stack["item_count"]),
		int(params.get("min_bid", 0)),
		int(params.get("buyout", 0)),
		int(params.get("duration_s", 3600))
	)
	return {"listed": aid, "auctions": live_view(), "fee": fee}


static func bid(cid: int, params: Dictionary) -> Dictionary:
	var auction := ServicesStore.auction_get(int(params.get("auction_id", 0)))
	if auction.is_empty():
		return {"error": "no_such_auction"}
	var placed := AuctionLogic.apply_bid(
		auction, cid, int(params.get("amount", 0)), ServicesStore.get_coins(cid)
	)
	if not bool(placed.get("ok", false)):
		return {"error": str(placed.get("reason", "bad_bid"))}
	ServicesStore.adjust_coins(cid, -int(placed["escrow_debit"]), "auction_escrow")
	if int(placed["refund_to"]) > 0:
		ServicesStore.adjust_coins(
			int(placed["refund_to"]), int(placed["refund_amount"]), "auction_refund"
		)
	ServicesStore.auction_set_bid(int(auction["id"]), cid, int(placed["new_high"]))
	return {
		"bid_ok": true,
		"auctions": live_view(),
		"coins": ServicesStore.get_coins(cid),
	}


static func buyout(cid: int, params: Dictionary) -> Dictionary:
	var auction := ServicesStore.auction_get(int(params.get("auction_id", 0)))
	if auction.is_empty():
		return {"error": "no_such_auction"}
	var buy := AuctionLogic.apply_buyout(auction, cid, ServicesStore.get_coins(cid))
	if not bool(buy.get("ok", false)):
		return {"error": str(buy.get("reason", "bad_buyout"))}
	# grant FIRST: if the buyer's bag is full nothing has moved yet
	var granted := CharacterManager.try_add_items(
		cid,
		[{"item": str(auction["item_id"]), "count": int(auction["item_count"])}],
		params.get("item_registry", {})
	)
	if not bool(granted.get("ok", false)):
		return {"error": str(granted.get("reason", "bag_full"))}
	ServicesStore.adjust_coins(cid, -int(buy["buyer_pays"]), "auction_escrow")
	if int(buy["refund_to"]) > 0:
		ServicesStore.adjust_coins(
			int(buy["refund_to"]), int(buy["refund_amount"]), "auction_refund"
		)
	ServicesStore.adjust_coins(int(auction["seller_id"]), int(buy["seller_gets"]), "auction_sale")
	ServicesStore.auction_close(int(auction["id"]), "sold")
	return {
		"bought": true,
		"auctions": live_view(),
		"coins": ServicesStore.get_coins(cid),
	}
