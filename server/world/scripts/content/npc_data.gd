extends RefCounted

var id: String = ""
var name: String = ""
var x: float = 0.0
var y: float = 0.0
var gives_quests: Array = []
var talk_text: String = ""
var trainer: bool = false  # T-065: talking to a trainer opens the talent UI client-side
var service: String = ""  # T-145: bank|vendor|inn|flight service hub ("" = plain NPC)
var wares: Array = []  # T-430: item ids this specific vendor stocks (server content authority)
var wander: Dictionary = {}  # T-311: optional ambient-movement block ({} = rooted at post)
var idle: Dictionary = {}  # T-446: optional idle-life block (facing drift + role act pulses)
var appearance: Dictionary = {}  # T-302: optional look block (role/sex/body_scale/seed)
var _source_keys: Array = []
