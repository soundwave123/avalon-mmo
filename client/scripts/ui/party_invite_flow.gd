class_name PartyInviteFlow
extends RefCounted

# T-736: the party-invite orchestrator, carved out of capped main.gd (the AutoAttackMode /
# CreationFlow idiom — main passes itself and this module reads its live members). Owns the
# whole player-facing invite surface:
#   * right-click RELEASE without drag (LocalPlayer.right_clicked, T-739 deadzone) -> ray-pick
#     via TargetSelection -> select the player AND open the context menu if FRIENDLY;
#   * right-click on the T-283 target frame -> same menu for the current selection;
#   * "Invite to Party" -> the T-280 party_invite intent (server re-validates everything);
#   * the invitee's Accept/Decline dialog on a party_invite push (T-598's chat line is kept
#     as the text fallback — /party accept|decline still works);
#   * inviter-facing refusal reasons as system chat lines (party_result ok=false). The
#     DECLINING player is deliberately never messaged — anti-grief silence is server policy;
#   * the one-line first-time discoverability hint when a FRIENDLY player is targeted.
#
# Relationship gating is client-side COURTESY only (don't offer an invite that must fail);
# party_logic/mentorship_service re-validate every intent server-side.

const TargetSelection = preload("res://scripts/world/target_selection.gd")

# Inviter-visible plain-English refusals (party_result {intent, ok:false, reason}). Reasons
# absent here stay log/chat-silent. invite_cooldown wording is deliberately vague: the server
# never tells the inviter HOW the throttle works, only that asking again is pointless.
const REASON_TEXT := {
	"party_invite":
	{
		"player_not_found": "Player not found.",
		"target_in_party": "They are already in a party.",
		"party_full": "Your party is full.",
		"not_leader": "Only the party leader can invite.",
		"invite_pending": "They are already considering an invite.",
		"invite_cooldown": "They aren't taking invites from you right now.",
		"cannot_invite_self": "You can't invite yourself.",
	},
	"party_accept":
	{
		"invite_expired": "That party invite has expired.",
		"already_in_party": "You are already in a party.",
		"party_gone": "That party no longer exists.",
		"party_full": "That party is now full.",
	},
}

var menu: TargetContextMenu = null
var dialog: PartyInviteDialog = null
var _main = null


# Build + wire both surfaces under $HUD. player_hud exists by _wire_hud_once (mount time);
# local_player spawns later — main calls bind_player() from _spawn_local_player.
static func mount(main) -> PartyInviteFlow:
	var flow := PartyInviteFlow.new()
	flow._main = main
	flow.menu = TargetContextMenu.new()
	flow.menu.name = "TargetContextMenu"
	flow.dialog = PartyInviteDialog.new()
	flow.dialog.name = "PartyInviteDialog"
	var hud = main.get_node_or_null("HUD")
	if hud != null:
		hud.add_child(flow.menu)
		hud.add_child(flow.dialog)
	flow.menu.action_selected.connect(flow._on_menu_action)
	flow.dialog.answered.connect(flow._on_answer)
	flow.dialog.lapsed.connect(flow._on_lapse)
	if main.player_hud != null and main.player_hud.target_frame != null:
		main.player_hud.target_frame.right_clicked.connect(flow._on_frame_right_click)
	return flow


func bind_player(local_player) -> void:
	local_player.right_clicked.connect(_on_world_right_click)


# A still right-click in the world: re-use the LEFT-click ray. Only a broadcast PLAYER both
# selects and offers the menu; ground/NPC/mob right-clicks change nothing (a right-click is
# never a deselect — that stays left-click/Esc behavior).
func _on_world_right_click(pos: Vector2) -> void:
	var cam = _main.get_viewport().get_camera_3d()
	if cam == null or _main.remote_entities == null:
		return
	var entities: Dictionary = _main.remote_entities.get("_entities")
	var picked: int = TargetSelection.target_id_for_click(cam, pos, entities, _main.npc_world)
	if picked == TargetSelection.NPC_CLICK or picked == -1 or _row_for(picked).is_empty():
		return
	_main._on_entity_clicked(picked)
	_try_open(picked, pos)


func _on_frame_right_click(pos: Vector2) -> void:
	if _main._target_id != -1:
		_try_open(_main._target_id, pos)


func _try_open(target_id: int, pos: Vector2) -> void:
	var row := _row_for(target_id)
	if row.is_empty() or _relationship(row) != Relationship.Rel.FRIENDLY:
		return  # SELF/PARTY/PvP-hostile/mob: nothing to offer (server would refuse anyway)
	menu.open_for(str(row.get("username", "")), pos)


# main._on_entity_clicked seam, both fire-once teach moments (moved here whole — main.gd is at
# its cap): the T-557 slot-aware target hint on ANY selection, and the T-736 discoverability
# one-liner the first time the selection is a FRIENDLY player.
func on_target_selected(target_id: int) -> void:
	var slots: int = _main.player_hud.action_bar.slot_count() if _main.player_hud != null else 5
	_main._onboarding.hint("target", HintReference.target_hint(slots))
	var row := _row_for(target_id)
	if not row.is_empty() and _relationship(row) == Relationship.Rel.FRIENDLY:
		_main._onboarding.hint("party_invite")


func _on_menu_action(meta: String) -> void:
	var parts := meta.split("|")
	if parts[0] == "party_invite" and parts.size() > 1 and parts[1] != "":
		print("[party] invite sent to %s" % parts[1])
		_main._send_to_server({"type": "party_invite", "target": parts[1]})


# ---- invitee side ------------------------------------------------------------------------


# handlers["party_invite"]: keep the T-598 chat line (text fallback + pilot partystate truth),
# and raise the dialog with the server's countdown.
func on_invite(d: Dictionary) -> void:
	_main._party_prompt.show(_main.chat_panel, str(d.get("from", "")))
	dialog.open(str(d.get("from", "")), int(d.get("ttl_ms", 45000)))


func _on_answer(accepted: bool) -> void:
	_main._send_to_server({"type": "party_accept" if accepted else "party_decline"})


func _on_lapse() -> void:
	_main._party_prompt.clear()  # nothing sent: the server prunes its side lazily (no decline)


# handlers["party_result"]: T-598 pending bookkeeping, close the dialog once our own answer
# (or a /party command) round-tripped, and voice any refusal to the ACTOR in plain English.
func on_result(d: Dictionary) -> void:
	_main._party_prompt.on_result(d)
	if str(d.get("intent", "")) in ["party_accept", "party_decline"] and dialog.is_open():
		dialog.close_dialog()
	if bool(d.get("ok", false)):
		return
	var text := reason_text(str(d.get("intent", "")), str(d.get("reason", "")))
	if text == "":
		return
	print("[party] refused: %s (%s)" % [str(d.get("reason", "")), str(d.get("intent", ""))])
	if _main.chat_panel != null:
		_main.chat_panel.receive({"type": "chat", "channel": "system", "from": "", "text": text})


static func reason_text(intent: String, reason: String) -> String:
	return str(REASON_TEXT.get(intent, {}).get(reason, ""))


# ---- broadcast joins ---------------------------------------------------------------------


# The last positions snapshot row for a PLAYER peer id; {} for mobs/unknown ids.
func _row_for(target_id: int) -> Dictionary:
	for p: Dictionary in _main.last_positions.get("players", []):
		if int(p.get("peer_id", -1)) == target_id:
			return p
	return {}


func _relationship(row: Dictionary) -> Relationship.Rel:
	var viewer := {"peer_id": int(_main._my_peer_id)}
	var own := _row_for(int(_main._my_peer_id))
	viewer["party_id"] = int(own.get("party_id", 0))
	viewer["pvp_flag"] = bool(own.get("pvp_flag", false))
	var unit := {
		"peer_id": int(row.get("peer_id", -1)),
		"party_id": int(row.get("party_id", 0)),
		"pvp_flag": bool(row.get("pvp_flag", false)),
	}
	return Relationship.of(viewer, unit)
