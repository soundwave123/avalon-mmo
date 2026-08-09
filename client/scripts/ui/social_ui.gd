class_name SocialUi
extends RefCounted

# T-363/T-361: builds + routes the social panels (trade window, friends list) so client/main.gd —
# which sits at the gdlint file cap — wires the whole suite in three lines. Panels ride the shared
# T-308 theme and send only intents through the injected transport (main._send_to_server).

var trade_panel: TradePanel = null
var social_panel: SocialPanel = null
var guild_panel: GuildPanel = null  # T-362
var lfg_panel: LfgPanel = null  # T-625


func _init(hud: Node, theme_src: Control, send: Callable, is_typing: Callable = Callable()) -> void:
	trade_panel = TradePanel.new()
	trade_panel.name = "TradePanel"
	hud.add_child(trade_panel)
	trade_panel.setup(send)
	social_panel = SocialPanel.new()
	social_panel.name = "SocialPanel"
	hud.add_child(social_panel)
	social_panel.setup(send, is_typing)
	guild_panel = GuildPanel.new()  # T-362: guild roster + invite/accept flow (toggle G)
	guild_panel.name = "GuildPanel"
	hud.add_child(guild_panel)
	guild_panel.setup(send, is_typing)
	lfg_panel = LfgPanel.new()  # T-625: LFG-lite board (toggle U) — deferred client half of T-334
	lfg_panel.name = "LfgPanel"
	hud.add_child(lfg_panel)
	# The flag hint carries the player's real level; source it from the already-mounted XpBar node
	# (a $HUD child named "XpBar", built before this suite) so main.gd needs no extra wiring arg.
	var xp: Node = hud.get_node_or_null("XpBar")
	lfg_panel.setup(send, is_typing, func(): return xp.get_level() if xp != null else 1)
	if theme_src != null and theme_src.theme != null:
		trade_panel.theme = theme_src.theme
		social_panel.theme = theme_src.theme
		guild_panel.theme = theme_src.theme
		lfg_panel.theme = theme_src.theme


# client_net "trade" category: trade_update (session mirror / end) + trade_result (rejection).
func on_trade(data: Dictionary) -> void:
	if trade_panel != null:
		trade_panel.receive(data)


# client_net "social" category: friends/ignore (social_list/social_result) AND the T-362 guild
# messages (guild_roster/guild_invite/guild_disbanded/guild_result), which ride the same category so
# client/main.gd (at the gdlint cap) wires nothing new. Fan each to the panel that owns its type.
func on_social(data: Dictionary) -> void:
	var kind := str(data.get("type", ""))
	if kind.begins_with("guild_") or kind.begins_with("mentor_"):
		if guild_panel != null:
			guild_panel.receive(data)
		return
	if social_panel != null:
		social_panel.receive(data)


# T-625: the lfg_board reply (its own client_net category) feeds the LFG panel. Returns the board
# array so main.gd's handler can keep the `lfg_board` var alive for the pilot/E2E dump in one line.
func on_lfg(data: Dictionary) -> Array:
	if lfg_panel != null:
		lfg_panel.receive(data)
	return data.get("board", [])
