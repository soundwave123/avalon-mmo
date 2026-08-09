class_name AuctionLogic
extends RefCounted

# T-208: PURE auction-house decisions. The escrow invariant: a live high bid's coins are
# ALREADY debited from that bidder; every transition returns the coin deltas the caller
# must apply atomically. No I/O here — character_manager/main.gd persist the outcomes.

const MIN_DURATION_S := 60
const MAX_DURATION_S := 172800  # 48h
const MAX_LIVE_PER_SELLER := 10


## Validate a new listing. Returns {ok, reason?} — the item leaves the seller's bag into
## listing escrow on success (caller removes it).
static func can_list(
	min_bid: int, buyout: int, duration_s: int, live_for_seller: int
) -> Dictionary:
	if min_bid < 1:
		return {"ok": false, "reason": "bad_min_bid"}
	if buyout != 0 and buyout < min_bid:
		return {"ok": false, "reason": "buyout_below_min"}
	if duration_s < MIN_DURATION_S or duration_s > MAX_DURATION_S:
		return {"ok": false, "reason": "bad_duration"}
	if live_for_seller >= MAX_LIVE_PER_SELLER:
		return {"ok": false, "reason": "too_many_listings"}
	return {"ok": true}


## T-412: the up-front LISTING FEE (a non-punitive coin sink the house keeps) — a flat base plus a
## proportional cut of the asking price in basis points. PURE; the caller debits it via
## adjust_coins reason "auction_fee". Both tunables at 0 → 0 fee (disabled).
static func listing_fee(min_bid: int, flat: int, bps: int) -> int:
	return maxi(0, flat) + (maxi(0, min_bid) * maxi(0, bps)) / 10000


## Apply a bid. Returns {ok, reason?, escrow_debit, refund_to, refund_amount, new_high}.
static func apply_bid(
	auction: Dictionary, bidder_id: int, amount: int, bidder_coins: int
) -> Dictionary:
	if str(auction.get("state", "")) != "live":
		return {"ok": false, "reason": "not_live"}
	if int(auction.get("seller_id", -1)) == bidder_id:
		return {"ok": false, "reason": "own_auction"}
	var floor_bid := int(auction.get("high_bid", 0))
	var min_next := maxi(int(auction.get("min_bid", 1)), floor_bid + 1)
	if amount < min_next:
		return {"ok": false, "reason": "bid_too_low"}
	if int(auction.get("high_bidder_id", -1)) == bidder_id:
		return {"ok": false, "reason": "already_high_bidder"}
	if bidder_coins < amount:
		return {"ok": false, "reason": "insufficient_coins"}
	return {
		"ok": true,
		"escrow_debit": amount,  # take from the new bidder now
		"refund_to": int(auction.get("high_bidder_id", 0)),  # 0/absent = nobody to refund
		"refund_amount": floor_bid,
		"new_high": amount,
	}


## Apply a buyout. Returns coin movements: buyer pays, prior bidder refunded, seller paid.
static func apply_buyout(auction: Dictionary, buyer_id: int, buyer_coins: int) -> Dictionary:
	if str(auction.get("state", "")) != "live":
		return {"ok": false, "reason": "not_live"}
	var buyout := int(auction.get("buyout", 0))
	if buyout <= 0:
		return {"ok": false, "reason": "no_buyout"}
	if int(auction.get("seller_id", -1)) == buyer_id:
		return {"ok": false, "reason": "own_auction"}
	if buyer_coins < buyout:
		return {"ok": false, "reason": "insufficient_coins"}
	return {
		"ok": true,
		"buyer_pays": buyout,
		"refund_to": int(auction.get("high_bidder_id", 0)),
		"refund_amount": int(auction.get("high_bid", 0)),
		"seller_gets": buyout,
	}


## Resolve an expired auction: sold to the high bidder (escrow already holds the coins)
## or returned to the seller. Caller moves the item + pays the seller accordingly.
static func resolve_expiry(auction: Dictionary) -> Dictionary:
	if int(auction.get("high_bid", 0)) > 0 and int(auction.get("high_bidder_id", 0)) > 0:
		return {
			"outcome": "sold",
			"winner_id": int(auction["high_bidder_id"]),
			"seller_gets": int(auction["high_bid"]),
		}
	return {"outcome": "returned"}
