class_name ClassPanelGate
extends RefCounted

# T-320: pure decision for the class-selection panel's visibility, given a monotonic "locked"
# latch. class_locked only ever flips false -> true within one client session: reroll (T-065)
# deletes the whole character row and reconnects fresh (a brand-new session with its own fresh
# latch), it never un-locks a live session. So once we've latched locked=true, a LATER ack that
# claims class_locked=false (a stale/duplicate class_kit resend racing the lock, or a delayed
# retransmit) must be ignored rather than reopening the panel — that stale-reopen is exactly the
# T-320 bug (panel stuck open after three independent QA sessions hit it 2026-07-09).


# currently_locked: the latch's current value (false at session start).
# incoming_locked: the class_locked flag carried by the ack/broadcast just received.
# Returns {"locked": <new latch>, "visible": <panel visibility to apply>}.
static func next_visible(currently_locked: bool, incoming_locked: bool) -> Dictionary:
	var locked: bool = currently_locked or incoming_locked
	return {"locked": locked, "visible": not locked}
