extends RefCounted

var id: String = ""
var title: String = ""
var giver_npc: String = ""
var turnin_npc: String = ""
var min_level: int = 1
var prerequisite_quest: String = ""
var description: String = ""
# T-713: the giver's spoken line on the TURN-IN card (the offer card keeps `description`). Empty on
# every quest that has nothing extra to say — the panel simply draws no flavour line then.
var turnin_text: String = ""
var objectives: Array = []
var rewards: Dictionary = {"xp": 0, "items": []}
var provided_items: Array = []  # T-058: granted on accept, removed on abandon/turn-in
# T-293: bounty-board metadata. `repeatable` lets a completed quest be re-accepted (the SM gate);
# `bounty` flags it for the board's list; `location_hint`/`recommended_players` are display copy.
var repeatable: bool = false
var bounty: bool = false
var location_hint: String = ""
var recommended_players: int = 1
# T-707: a retired quest stays loadable (mid-quest characters can finish/abandon/turn in) but is
# never offered and never accepts again — the content-side soft delete.
var retired: bool = false
var _source_keys: Array = []
