extends GutTest

# T-571 (report #28): _open_hud_panels() previously omitted the Spellbook/Wardrobe/cosmetics-store,
# so Esc fell through past them straight to opening Options on top. _panel_set (built once in
# _enter_world) now includes them; this drives main._handle_escape() directly — MainScene.new()
# without adding it to the tree, the established test_main_input_gate.gd idiom — with synthetic
# Control stand-ins to prove Esc closes each of them instead of skipping to Options.

const MainScene = preload("res://scripts/main.gd")
const PerformanceRecapPanel = preload("res://scripts/ui/performance_recap_panel.gd")

var _m = null


func before_each() -> void:
	_m = MainScene.new()


func after_each() -> void:
	if _m != null:
		_m.free()
		_m = null


func _visible_control() -> Control:
	var c := Control.new()
	c.visible = true
	return c


# Control.new() defaults to visible=true, so a genuinely-hidden stand-in needs this explicitly.
func _hidden_control() -> Control:
	var c := Control.new()
	c.visible = false
	return c


# _recap_panel is typed PerformanceRecapPanel (it needs the real watch_panels() method), so a plain
# Control stand-in fails that assignment — this is the real class, just never added to the tree
# (its _ready() — which would otherwise force visible=false — never fires off-tree).
func _visible_recap() -> PerformanceRecapPanel:
	var r := PerformanceRecapPanel.new()
	r.visible = true
	return r


func test_open_hud_panels_reads_from_panel_set() -> void:
	var spellbook := _visible_control()
	var hidden := _hidden_control()
	_m._panel_set = [spellbook, hidden]
	assert_eq(_m._open_hud_panels(), [spellbook], "only the visible candidate is reported open")
	spellbook.free()
	hidden.free()


func test_escape_closes_spellbook_before_opening_options() -> void:
	var spellbook := _visible_control()
	_m._panel_set = [spellbook]
	_m._target_id = -1
	_m._handle_escape()
	assert_false(spellbook.visible, "Esc closed the open Spellbook stand-in, not Options")
	spellbook.free()


func test_escape_closes_wardrobe_before_opening_options() -> void:
	var wardrobe := _visible_control()
	_m._panel_set = [wardrobe]
	_m._target_id = -1
	_m._handle_escape()
	assert_false(wardrobe.visible, "Esc closed the open Wardrobe stand-in, not Options")
	wardrobe.free()


func test_escape_closes_cosmetics_store_before_opening_options() -> void:
	var shop := _visible_control()
	_m._panel_set = [shop]
	_m._target_id = -1
	_m._handle_escape()
	assert_false(shop.visible, "Esc closed the open cosmetics-store stand-in, not Options")
	shop.free()


# T-653 (#74): GuildPanel had no _panel_set membership at all, so an Escape press that didn't land
# on one of its own focused LineEdits (guild_panel.gd's own local escape branch owns that case —
# see test_guild_panel.gd) left the window stacked open with Options opening on top of it.
func test_escape_closes_guild_panel_before_opening_options() -> void:
	var guild := _visible_control()
	_m._panel_set = [guild]
	_m._target_id = -1
	_m._handle_escape()
	assert_false(guild.visible, "Esc closed the open Guild-panel stand-in, not Options")
	guild.free()


func test_escape_closes_only_the_open_panel_leaving_others_untouched() -> void:
	var open_panel := _visible_control()
	var closed_panel := _hidden_control()
	_m._panel_set = [open_panel, closed_panel]
	_m._target_id = -1
	_m._handle_escape()
	assert_false(open_panel.visible)
	assert_false(closed_panel.visible, "already-closed panel stays closed, unaffected")
	open_panel.free()
	closed_panel.free()


# T-576 (report #34): the recap panel's own _input() only ever handled KEY_R, and it isn't a member
# of _panel_set (it's that set's #27 WATCHER — adding it there would make it observe its own
# visibility_changed and self-close the instant it opens), so Esc skipped it entirely and stacked
# Options on top of a still-open recap. _open_hud_panels() now appends _recap_panel directly, the
# same idiom already used for the onboarding handbook card.
func test_open_hud_panels_includes_recap_when_visible_though_not_in_panel_set() -> void:
	var recap := _visible_recap()
	_m._recap_panel = recap
	_m._panel_set = []
	assert_eq(
		_m._open_hud_panels(), [recap], "recap reported open despite living outside _panel_set"
	)
	recap.free()


func test_escape_closes_recap_before_opening_options() -> void:
	var recap := _visible_recap()
	_m._recap_panel = recap
	_m._panel_set = []
	_m._target_id = -1
	_m._handle_escape()
	assert_false(recap.visible, "Esc closed the open recap stand-in, not Options")
	recap.free()


# T-640: the character window is a _panel_set member (main.gd builds the set with it), so an open
# character sheet must be Esc-close-first — this drives the real class through the same seam.
func test_escape_closes_an_open_character_sheet_before_options() -> void:
	var sheet := CharacterSheetPanel.new()
	sheet.visible = true  # off-tree: _ready() (which starts hidden) never fires, same as stand-ins
	_m._panel_set = [sheet]
	_m._target_id = -1
	assert_eq(_m._open_hud_panels(), [sheet], "an open character sheet is reported open")
	_m._handle_escape()
	assert_false(sheet.visible, "Esc closed the character window, not Options")
	sheet.free()


# T-759: seven panels were outside the Esc sweep (pvp/recipe/weekly/social/trade/quest_offer/
# party_invite_dialog); quest_offer in particular trapped the player, stacking Options on top of an
# un-dismissable offer. main.gd now appends them to _panel_set. These drive the REAL panel classes
# (constructed off-tree, so _ready — which would start them hidden — never fires, same as the
# character-sheet case above) through _handle_escape to prove each closes rather than trapping.
const QuestOfferPanel = preload("res://scripts/ui/quest_offer_panel.gd")
const PartyInviteDialog = preload("res://scripts/ui/party_invite_dialog.gd")
const TradePanel = preload("res://scripts/ui/trade_panel.gd")


func _assert_escape_closes(panel: Control, label: String) -> void:
	panel.visible = true
	_m._panel_set = [panel]
	_m._target_id = -1
	assert_eq(_m._open_hud_panels(), [panel], "%s is reported open" % label)
	_m._handle_escape()
	assert_false(panel.visible, "Esc closed the %s, not Options" % label)
	panel.free()


func test_escape_closes_the_quest_offer_panel_instead_of_trapping() -> void:
	_assert_escape_closes(QuestOfferPanel.new(), "quest-offer prompt")


func test_escape_closes_the_party_invite_dialog() -> void:
	_assert_escape_closes(PartyInviteDialog.new(), "party-invite dialog")


func test_escape_closes_the_trade_window() -> void:
	_assert_escape_closes(TradePanel.new(), "trade window")


func test_escape_closes_recap_and_a_panel_set_member_together() -> void:
	var recap := _visible_recap()
	var quest_log := _visible_control()
	_m._recap_panel = recap
	_m._panel_set = [quest_log]
	_m._target_id = -1
	_m._handle_escape()
	assert_false(recap.visible, "recap closes on the same Esc press as an ordinary panel")
	assert_false(quest_log.visible)
	recap.free()
	quest_log.free()
