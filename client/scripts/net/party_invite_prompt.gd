class_name PartyInvitePrompt
extends RefCounted

# T-598 (bug #48): party invite had ZERO client-side surface — accept/decline only worked from the
# dev pilot harness, so a real player never saw an invite land. Mirrors the duel_request client
# surface (chat_panel.gd's "system" channel notice, T-381): unlike a duel offer — which the SERVER
# composes as ready-made chat text — a party_invite arrives as bare {from}, so the CLIENT composes
# the same kind of visible chat-line prompt here, naming the inviter and how to accept/decline. The
# line rides chat_panel's existing "system" channel, so it gets the same escaping (ChatFormatter)
# and presentation (fade/focus) as every other system notice — no new panel. main.gd owns ONE
# instance (like _reply_router/_recovery) and routes party_invite/party_update/party_result through
# it so the pending-invite state lives in one place with its clearing rules.

const ACCEPT_HINT := "type /party accept to join, /party decline to decline."

var pending_from: String = ""  # inviter username awaiting my accept/decline; "" = no live invite


static func offer_text(from: String) -> String:
	return "%s invites you to a party — %s" % [from, ACCEPT_HINT]


# A party_invite landed: push the visible prompt (no-op if chat_panel isn't wired yet) and record
# the inviter as pending.
func show(chat_panel, from: String) -> void:
	pending_from = from
	if chat_panel != null and from != "":
		chat_panel.receive(
			{"type": "chat", "channel": "system", "from": "", "text": offer_text(from)}
		)


# My own accept/decline ack: clears a stale prompt even when it lands with no party_update (a
# decline, or a rejected accept — e.g. "already_in_party").
func on_result(result: Dictionary) -> void:
	if str(result.get("intent", "")) in ["party_accept", "party_decline"]:
		pending_from = ""


func clear() -> void:
	pending_from = ""
