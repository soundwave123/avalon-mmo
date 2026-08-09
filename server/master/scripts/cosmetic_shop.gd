class_name CosmeticShop
extends RefCounted

# T-476 + T-482: the cosmetic store's master-side authority — the SPEND half of the earn→spend loop,
# governed by docs/design/cosmetic-monetization-charter.md. The world resolves a priced catalog row
# from wardrobe.json (server-authoritative price) and hands it here; this module validates it by
# the charter, debits the persisted cosmetic_currency, and grants the unlock through the existing
# WardrobeOps.grant_unlock seam. The client never asserts a price, an id it doesn't own, or a stat.
#
# Charter guards enforced here (the seam cannot silently violate the ethics doc):
#   * Power is never for sale — a power-bearing appearance definition is rejected (_POWER_FIELDS).
#   * No loot boxes / randomness — purchase is deterministic: one known appearance_id in, one
#     grant_unlock(id, "store") out. There is no roll/bundle verb (see the seam-guard test).
#   * Bought never outranks earned — a store grant whose prestige_tier reaches the earned
#     MARQUEE_TIER is rejected; store rows live at/below STORE_CEILING.
#   * Idempotent — an already-owned look is refused WITHOUT a charge.

const _SS := preload("res://scripts/services_store.gd")
const _CO := preload("res://scripts/cosmetics.gd")
const _WO := preload("res://scripts/wardrobe_ops.gd")
const _CCL := preload("res://scripts/cosmetic_ledger.gd")
const _TEL := preload("res://scripts/telemetry_store.gd")

# Canonical prestige-tier rule — see the charter (that doc is the source of truth; mirrored in
# server/world/scripts/wardrobe_catalog.gd for the content lint). Earned marquee sets sit at
# MARQUEE_TIER; a store cosmetic may never be flagged at/above it, so bought can't outrank earned.
const MARQUEE_TIER := 4
const STORE_CEILING := 2


# Purchase a known catalog look for `cid`. `appearance` is the server-authored, priced catalog row
# the world resolved from wardrobe.json (NOT client data). Returns {ok, reason, balance,
# appearance_id}. Fails closed and never charges on any rejection.
static func purchase(cid: int, appearance: Dictionary, username: String = "") -> Dictionary:
	if cid <= 0:
		return _fail(cid, "unknown_character")
	var appearance_id := str(appearance.get("id", ""))
	if appearance_id == "":
		return _fail(cid, "bad_appearance")
	# Charter: power is never for sale — reject any power-bearing field defensively.
	for field: String in _CO._POWER_FIELDS:
		if appearance.has(field):
			return _fail(cid, "power_field")
	# Charter: only rows explicitly marked as store items are purchasable (earned looks are not sold).
	if not bool(appearance.get("store", false)):
		return _fail(cid, "not_for_sale")
	# Charter tier ceiling: a store cosmetic can never reach the earned marquee tier.
	if int(appearance.get("prestige_tier", 0)) >= MARQUEE_TIER:
		return _fail(cid, "exceeds_earned_tier")
	var price := int(appearance.get("price", 0))
	if price <= 0:
		return _fail(cid, "bad_price")
	# Idempotent: never double-charge for a look already owned.
	if appearance_id in _WO.unlocks_for(cid):
		return _fail(cid, "already_owned")
	if _SS.get_cosmetic_currency(cid) < price:
		return _fail(cid, "insufficient_currency")
	if not _SS.adjust_cosmetic_currency(cid, -price, _CCL.REASON_PURCHASE):
		return _fail(cid, "insufficient_currency")
	# Known-item, store-sourced grant — no roll, no bundle. This is the ONLY store→unlock path.
	_WO.grant_unlock(cid, appearance_id, "store")
	_emit(username, appearance_id, price)
	return {
		"ok": true,
		"reason": "",
		"balance": _SS.get_cosmetic_currency(cid),
		"appearance_id": appearance_id,
	}


static func _fail(cid: int, reason: String) -> Dictionary:
	return {
		"ok": false,
		"reason": reason,
		"balance": _SS.get_cosmetic_currency(cid) if cid > 0 else 0,
		"appearance_id": "",
	}


static func _emit(username: String, appearance_id: String, price: int) -> void:
	if username == "":
		return
	(
		_TEL
		. record_events(
			[
				{
					"event_type": "cosmetic_purchase",
					"account": username,
					"character": username,
					"payload": {"appearance_id": appearance_id, "price": price, "source": "store"},
				}
			]
		)
	)
