class_name GenderPanelGate
extends RefCounted

# T-520: pure decision for the gender-selection panel's visibility + the gender→class creation
# ORDER, given a monotonic "gender chosen" latch. Mirrors ClassPanelGate (T-320): the latch only
# ever flips false -> true within one client session — a reroll deletes the character row and
# reconnects fresh (a new session with its own fresh latch), it never un-chooses a live session. So
# once we've latched chosen=true, a LATER class_kit resend that carries an empty gender (a stale /
# duplicate frame racing the persist) must be ignored rather than reopening the panel.


# currently_chosen: the latch's current value (false at session start).
# incoming_chosen: whether the class_kit just received carries a non-empty gender.
# Returns {"chosen": <new latch>, "visible": <gender-panel visibility to apply>}.
static func next_visible(currently_chosen: bool, incoming_chosen: bool) -> Dictionary:
	var chosen: bool = currently_chosen or incoming_chosen
	return {"chosen": chosen, "visible": not chosen}


# T-520: the class panel appears only AFTER gender is chosen — this enforces the creation ORDER
# (login → gender → class → world). `class_gate_visible` is the T-320 ClassPanelGate verdict
# (class not yet locked); it is gated behind `gender_chosen` so class never precedes gender.
static func class_visible(class_gate_visible: bool, gender_chosen: bool) -> bool:
	return class_gate_visible and gender_chosen
