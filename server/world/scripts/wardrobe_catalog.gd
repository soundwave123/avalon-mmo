class_name WardrobeCatalog
extends RefCounted

# T-428: pure data catalog. Wearable item definitions automatically become learnable appearances;
# store-only rows and every dye come from wardrobe.json. Only presentation keys survive loading.

const _SLOTS := ["weapon", "offhand", "head", "chest", "legs", "shoulders"]
const _LOOK_KEYS := [
	"id",
	"name",
	"display_item",
	"slot",
	"armor_type",
	"rarity",
	"dye_mask",
	"store",
	"price",
	"prestige_tier"
]
const _DYE_KEYS := ["id", "name", "color"]
# T-482 charter tier ceiling (docs/design/cosmetic-monetization-charter.md is canonical; mirrored in
# server/master/scripts/cosmetic_shop.gd). A store row can never be flagged at/above the earned
# MARQUEE_TIER, so bought cosmetics can never outrank earned ones.
const MARQUEE_TIER := 4
const STORE_CEILING := 2
const _POWER_FIELDS := ["stats", "attack", "armor", "damage", "power", "bonuses", "effects"]

var _appearances: Dictionary = {}
var _dyes: Dictionary = {}


func setup(path: String, item_registry: Dictionary) -> String:
	_appearances.clear()
	_dyes.clear()
	for item_id: String in item_registry:
		var definition: Variant = item_registry[item_id]
		var slot := str(_value(definition, "slot", "none"))
		if not slot in _SLOTS:
			continue
		_appearances[item_id] = {
			"id": item_id,
			"name": str(_value(definition, "name", item_id)),
			"display_item": item_id,
			"slot": slot,
			"armor_type": str(_value(definition, "armor_type", "none")),
			"rarity": str(_value(definition, "rarity", "common")),
			"dye_mask": "all",
		}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return "wardrobe catalog missing: %s" % path
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		return "wardrobe catalog invalid JSON: %s" % path
	for raw: Variant in parsed.get("appearances", []):
		if not raw is Dictionary:
			return "wardrobe appearance must be an object"
		var look := _pick(raw, _LOOK_KEYS)
		var err := _validate_look(look, item_registry)
		if err != "":
			return err
		var store_err := _validate_store(look)
		if store_err != "":
			return store_err
		_normalize_store_fields(look)
		_appearances[str(look["id"])] = look
	return _load_dyes(parsed.get("dyes", []))


func _load_dyes(rows: Array) -> String:
	for raw: Variant in rows:
		if not raw is Dictionary:
			return "wardrobe dye must be an object"
		var dye := _pick(raw, _DYE_KEYS)
		var dye_id := str(dye.get("id", ""))
		var color := str(dye.get("color", ""))
		if dye_id == "" or color == "" or not color.is_valid_html_color():
			return "wardrobe dye invalid: %s" % dye_id
		_dyes[dye_id] = dye
	return ""


func appearance(appearance_id: String) -> Dictionary:
	return (_appearances.get(appearance_id, {}) as Dictionary).duplicate(true)


# T-476: resolve a purchasable STORE row (store:true + positive price) for the purchase path. A
# non-store / unpriced / unknown id returns {} so the store can never sell an earned-only look.
func store_appearance(appearance_id: String) -> Dictionary:
	var look: Dictionary = _appearances.get(appearance_id, {})
	if look.is_empty() or not bool(look.get("store", false)) or int(look.get("price", 0)) <= 0:
		return {}
	return look.duplicate(true)


# T-476: the store browse board — every buyable look, name-sorted, with its price + prestige tier.
func store_appearances() -> Array:
	var out: Array = []
	for look: Dictionary in all_appearances():
		if bool(look.get("store", false)) and int(look.get("price", 0)) > 0:
			out.append(look)
	return out


func dye(dye_id: String) -> Dictionary:
	if dye_id == "":
		return {}
	return (_dyes.get(dye_id, {}) as Dictionary).duplicate(true)


func all_appearances() -> Array:
	var out: Array = []
	for key: String in _appearances:
		out.append((_appearances[key] as Dictionary).duplicate(true))
	out.sort_custom(func(a: Dictionary, b: Dictionary): return str(a["name"]) < str(b["name"]))
	return out


func unlocked_appearances(unlocks: Array) -> Array:
	var out: Array = []
	for look: Dictionary in all_appearances():
		if str(look.get("id", "")) in unlocks:
			out.append(look)
	return out


func all_dyes() -> Array:
	var out: Array = []
	for key: String in _dyes:
		out.append((_dyes[key] as Dictionary).duplicate(true))
	out.sort_custom(func(a: Dictionary, b: Dictionary): return str(a["name"]) < str(b["name"]))
	return out


static func _pick(source: Dictionary, keys: Array) -> Dictionary:
	var out: Dictionary = {}
	for key: String in keys:
		if source.has(key):
			out[key] = source[key]
	return out


static func _validate_look(look: Dictionary, item_registry: Dictionary) -> String:
	var appearance_id := str(look.get("id", ""))
	var display_item := str(look.get("display_item", ""))
	var slot := str(look.get("slot", ""))
	if appearance_id == "" or display_item == "" or not slot in _SLOTS:
		return "wardrobe appearance invalid: %s" % appearance_id
	# An empty registry is allowed by pure data tests; live setup always supplies the item registry.
	if not item_registry.is_empty() and not item_registry.has(display_item):
		return "wardrobe appearance %s displays unknown item %s" % [appearance_id, display_item]
	return ""


# T-482 charter, enforced at content-load: a store row must be power-neutral, positively priced, and
# held BELOW the earned marquee tier (store rows at/above MARQUEE_TIER are a charter violation and
# fail content load loudly). A non-store row must not carry a price (nothing sells an earned look).
static func _validate_store(look: Dictionary) -> String:
	var appearance_id := str(look.get("id", ""))
	for field: String in _POWER_FIELDS:
		if look.has(field):
			return "wardrobe appearance %s carries power field %s" % [appearance_id, field]
	var tier := int(look.get("prestige_tier", 0))
	if bool(look.get("store", false)):
		if int(look.get("price", 0)) <= 0:
			return "store appearance %s needs a positive price" % appearance_id
		if tier >= MARQUEE_TIER:
			return (
				"store appearance %s at prestige_tier %d reaches the earned marquee"
				% [appearance_id, tier]
			)
		if tier > STORE_CEILING:
			return "store appearance %s exceeds STORE_CEILING" % appearance_id
	elif int(look.get("price", 0)) != 0:
		return "non-store appearance %s must not be priced" % appearance_id
	return ""


static func _normalize_store_fields(look: Dictionary) -> void:
	look["store"] = bool(look.get("store", false))
	look["price"] = int(look.get("price", 0))
	look["prestige_tier"] = int(look.get("prestige_tier", 0))


static func _value(definition: Variant, key: String, fallback: Variant) -> Variant:
	if definition is Dictionary:
		return definition.get(key, fallback)
	return definition.get(key) if definition != null and definition.get(key) != null else fallback
