extends RefCounted

var id: String = ""
var name: String = ""
var rarity: String = "common"  # T-230: junk|common|uncommon|rare|epic|legendary
var slot: String = ""
var stackable: bool = false
var max_stack: int = 1
var stats: Dictionary = {}
var vendor_value: int = 0
var description: String = ""
var armor_type: String = "none"  # T-063: cloth|leather|mail|plate|robe|vestment|none (none=ungated)
# T-681: the gear ladder's level dimension (ADR 0011). `item_level` is the power budget the piece
# was balanced for (internal — the tools/item_ledger.py oracle and era-direction.md S4's
# carry-rescale read it); `required_level` is the player-facing equip/use gate. They are different
# numbers on purpose: the gate sits BELOW the budget. Default 1/1 = ungated, so an item a data
# migration has not reached behaves exactly as it did before the field existed.
var item_level: int = 1
var required_level: int = 1
# T-414: consumable use effect ({kind: heal|rested|repair, ...}). Empty for non-consumables. The
# master reads the effect from THIS item data on use_item — never a client-named effect.
var use_effect: Dictionary = {}
var _source_keys: Array = []
