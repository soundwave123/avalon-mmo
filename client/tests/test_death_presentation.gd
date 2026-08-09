extends GutTest
# T-506: death is a client presentation of the authoritative player_death/player_respawn events.
# The timeline is pure and delta-injected; the Control only renders that state and writes the one
# durability consequence line to the existing combat log.

const DeathState = preload("res://scripts/ui/death_presentation_state.gd")
const DeathPresentation = preload("res://scripts/ui/death_presentation.gd")
const RecapPanel = preload("res://scripts/ui/performance_recap_panel.gd")
const CombatLog = preload("res://scripts/combat/combat_log.gd")
const MainScene = preload("res://scripts/main.gd")
const CombatFeedbackScene = preload("res://scripts/combat/combat_feedback.gd")
const RemoteEntitiesScene = preload("res://scripts/world/remote_entities_layer.gd")
const LocalPlayerScene = preload("res://scripts/world/local_player.gd")
const PlayerHudScene = preload("res://scripts/ui/player_hud.gd")
const CompassStripScene = preload("res://scripts/ui/compass_strip.gd")
const ActionBarScene = preload("res://scripts/ui/action_bar.gd")


class NetSpy:
	extends RefCounted
	var ability_calls: Array = []

	func request_use_ability(ability_id: int, target_id: int) -> void:
		ability_calls.append([ability_id, target_id])


func test_death_ramps_to_full_grayscale_in_one_second() -> void:
	var state: Dictionary = DeathState.begin_death(DeathState.new_state())
	assert_true(bool(state["input_disabled"]), "death immediately mirrors the server input lock")
	state = DeathState.advance(state, 0.5)
	assert_almost_eq(float(state["grayscale"]), 0.5, 0.01, "halfway through the 1s ramp")
	assert_almost_eq(float(state["death_text_alpha"]), 0.5, 0.01, "death copy eases in with it")
	state = DeathState.advance(state, 0.5)
	assert_eq(int(state["phase"]), DeathState.Phase.DEAD, "ramp settles into the dead hold")
	assert_almost_eq(float(state["grayscale"]), 1.0, 0.001, "world reaches full grayscale")


# T-515: a missed player_respawn (dropped ENet packet) must not strand the player on the death
# screen until relog. After FAILSAFE_DEAD_SECONDS the DEAD hold self-clears via the respawn fade.
func test_dead_hold_self_clears_after_failsafe_when_respawn_event_is_missed() -> void:
	var state: Dictionary = DeathState.begin_death(DeathState.new_state())
	state = DeathState.advance(state, DeathState.DEATH_RAMP_SECONDS)
	assert_eq(int(state["phase"]), DeathState.Phase.DEAD, "settles into the dead hold")
	# Hold well short of the failsafe: still dead (no premature clear on a normal 25 s respawn wait).
	state = DeathState.advance(state, DeathState.FAILSAFE_DEAD_SECONDS - 2.0)
	assert_eq(int(state["phase"]), DeathState.Phase.DEAD, "does not clear before the failsafe")
	# Cross the failsafe with no begin_respawn ever called → it starts the respawn fade itself.
	state = DeathState.advance(state, 3.0)
	assert_eq(int(state["phase"]), DeathState.Phase.RESPAWN_FADE, "failsafe kicks off the reveal")
	state = DeathState.advance(state, DeathState.RESPAWN_FADE_SECONDS)
	assert_eq(int(state["phase"]), DeathState.Phase.ALIVE, "screen clears without a relog")
	assert_false(bool(state["input_disabled"]), "control is returned")


# T-522: the Defeat recap (and any death-only surface) auto-dismisses on the LOCAL respawn — it must
# not linger until the player finds the R toggle (playtest #9). begin_respawn() clears the group.
func test_local_respawn_dismisses_the_hide_on_local_respawn_group() -> void:
	var recap := Control.new()
	recap.add_to_group("hide_on_local_respawn")
	recap.visible = true
	add_child_autofree(recap)
	var presentation = DeathPresentation.new()
	add_child_autofree(presentation)
	await get_tree().process_frame
	presentation.begin_respawn()
	assert_false(recap.visible, "a death-only panel hides when the local player respawns")


# T-533: on death both the "You died." headline and the auto-surfaced Performance Recap panel used
# to sit at screen centre and overlap. They must now read as one composed stack — the headline (and
# the durability toast) sit outside the recap's rect at the min supported resolution (1280x720).
func test_death_headline_and_recap_panel_do_not_share_the_same_rect() -> void:
	var root := Control.new()
	root.size = Vector2(1280, 720)
	add_child_autofree(root)
	var presentation = DeathPresentation.new()
	root.add_child(presentation)
	var recap = RecapPanel.new()
	recap.visible = true
	root.add_child(recap)
	await get_tree().process_frame
	await get_tree().process_frame
	var headline := (presentation.get_node("DeathLabel") as Control).get_global_rect()
	var toast := (presentation.get_node("DurabilityToast") as Control).get_global_rect()
	var recap_rect := recap.get_global_rect()
	assert_false(
		headline.intersects(recap_rect), "the 'You died.' headline never overlaps the recap panel"
	)
	assert_false(
		toast.intersects(recap_rect), "the durability toast never overlaps the recap panel"
	)
	assert_true(headline.end.y <= recap_rect.position.y, "headline is composed above the recap")
	assert_true(
		toast.position.y >= recap_rect.end.y, "durability toast is composed below the recap"
	)


# T-554: the "You died." banner used to sit at the very top edge, colliding with the compass "N /
# 0°" at the min supported 1280x720. The composed headline must clear the compass strip entirely.
func test_death_headline_does_not_intersect_the_compass() -> void:
	var root := Control.new()
	root.size = Vector2(1280, 720)
	add_child_autofree(root)
	var presentation = DeathPresentation.new()
	root.add_child(presentation)
	var compass = CompassStripScene.new()
	root.add_child(compass)
	await get_tree().process_frame
	await get_tree().process_frame
	var headline := (presentation.get_node("DeathLabel") as Control).get_global_rect()
	var compass_rect := compass.get_global_rect()
	assert_false(
		headline.intersects(compass_rect), "the 'You died.' banner never overlaps the compass strip"
	)
	assert_gt(headline.position.y, compass_rect.end.y, "the banner is composed below the compass")


# T-634: the durability toast + respawn cue (composed BELOW the recap) landed inside the ActionBar
# hotbar's y-band (580..632) — the old ±200 recap half-height + gaps left only 20px of clearance
# for two lines of text above the hotbar. Reserve the hotbar at its WIDEST case (MAX_SLOTS=9, the
# same worst-case HudSafeZone.ACTION_BAR_RECT reserves) so this never regresses as the kit grows.
func test_toast_and_cue_do_not_intersect_the_action_bar() -> void:
	var root := Control.new()
	root.size = Vector2(1280, 720)
	add_child_autofree(root)
	var presentation = DeathPresentation.new()
	root.add_child(presentation)
	var bar = ActionBarScene.new()
	root.add_child(bar)
	var kit: Array = []
	for i in range(9):  # MAX_SLOTS — the widest the hotbar ever gets
		kit.append({"id": "ability_%d" % i, "name": "Ability %d" % i, "icon": ""})
	bar.set_kit(kit)
	await get_tree().process_frame
	await get_tree().process_frame
	var toast := (presentation.get_node("DurabilityToast") as Control).get_global_rect()
	var cue := (presentation.get_node("RespawnCue") as Control).get_global_rect()
	var bar_rect := bar.get_global_rect()
	assert_false(toast.intersects(bar_rect), "the durability toast never overlaps the hotbar")
	assert_false(cue.intersects(bar_rect), "the respawn cue never overlaps the hotbar")
	assert_true(cue.end.y <= bar_rect.position.y, "both lines finish above the hotbar's top edge")


# T-554: death is a flash without a cue that a respawn is coming. A "Respawning…" affordance holds
# through the dead phase (rides the headline alpha) and clears the instant the respawn fade begins.
func test_respawn_cue_shows_during_death_and_clears_on_respawn() -> void:
	var presentation = DeathPresentation.new()
	add_child_autofree(presentation)
	await get_tree().process_frame
	var cue := presentation.get_node("RespawnCue") as Label
	assert_eq(cue.text, "Respawning…", "the death screen names the pending auto-respawn")
	presentation.begin_death()
	presentation._process(DeathState.DEATH_RAMP_SECONDS)
	assert_gt(cue.modulate.a, 0.9, "the respawn cue is legible through the dead hold")
	presentation.begin_respawn()
	presentation._render()
	assert_almost_eq(cue.modulate.a, 0.0, 0.01, "the cue clears once the respawn fade starts")


# T-554: the target frame must be cleared on death AND again on respawn — a late broadcast of the
# still-alive killer re-bound the frame during the dead hold, leaving a stale "Gray Wolf 80/80" up
# after the player respawned 38 m away in town.
func test_target_frame_clears_on_death_and_again_on_respawn() -> void:
	var main = MainScene.new()
	var feedback = CombatFeedbackScene.new()
	add_child_autofree(feedback)
	var presentation = DeathPresentation.new()
	add_child_autofree(presentation)
	presentation.setup(feedback.get_combat_log())
	var remotes = RemoteEntitiesScene.new()
	add_child_autofree(remotes)
	var hud = PlayerHudScene.new()
	add_child_autofree(hud)
	await get_tree().process_frame  # builds the target frame child
	var player = LocalPlayerScene.new()
	add_child_autofree(player)
	var attack_timer := Timer.new()
	add_child_autofree(attack_timer)
	main.combat_feedback = feedback
	main.death_presentation = presentation
	main.remote_entities = remotes
	main.player_hud = hud
	main.local_player = player
	main._attack_timer = attack_timer
	main._net = NetSpy.new()
	main._my_peer_id = 99
	main._target_id = 1001
	main._kit = [0]

	hud.target_frame.bind_target("Gray Wolf", 80, 80, Color.RED, 3)
	assert_true(hud.target_frame.is_bound(), "precondition: a live target frame")
	main._on_combat({"type": "player_death", "peer_id": 99, "player_id": 99})
	assert_eq(main._target_id, -1, "death clears the selected target id")
	assert_false(hud.target_frame.is_bound(), "death hides the target frame")

	# A late broadcast re-binds the still-alive killer during the dead hold (the reported stale frame).
	hud.target_frame.bind_target("Gray Wolf", 80, 80, Color.RED, 3)
	main._on_combat({"type": "player_respawn", "peer_id": 99, "player_id": 99})
	assert_eq(main._target_id, -1, "respawn clears the target id again")
	assert_false(hud.target_frame.is_bound(), "respawn hides the re-bound stale target frame")
	main.free()


func test_respawn_fades_in_and_releases_desaturation_and_input() -> void:
	var state: Dictionary = DeathState.begin_death(DeathState.new_state())
	state = DeathState.advance(state, DeathState.DEATH_RAMP_SECONDS)
	state = DeathState.begin_respawn(state)
	assert_almost_eq(float(state["fade"]), 1.0, 0.001, "respawn cut starts covered by black")
	assert_almost_eq(float(state["grayscale"]), 1.0, 0.001, "desaturation holds under the cover")
	state = DeathState.advance(state, DeathState.RESPAWN_FADE_SECONDS * 0.5)
	assert_almost_eq(float(state["fade"]), 0.5, 0.02, "short transition reveals the respawn")
	assert_true(bool(state["input_disabled"]), "input stays locked during the transition")
	state = DeathState.advance(state, DeathState.RESPAWN_FADE_SECONDS * 0.5)
	assert_eq(int(state["phase"]), DeathState.Phase.ALIVE)
	assert_almost_eq(float(state["grayscale"]), 0.0, 0.001, "respawn restores world colour")
	assert_false(bool(state["input_disabled"]), "movement/abilities release after the fade")


func test_death_surface_is_fullscreen_deboxed_and_uses_screen_grayscale_shader() -> void:
	var root := Control.new()
	root.size = Vector2(1920, 1080)
	add_child_autofree(root)
	var presentation = DeathPresentation.new()
	root.add_child(presentation)
	await get_tree().process_frame
	var grayscale := presentation.get_node("Grayscale") as ColorRect
	assert_eq(grayscale.size, Vector2(1920, 1080), "grayscale overlay covers the full viewport")
	var shader := (grayscale.material as ShaderMaterial).shader
	assert_true("hint_screen_texture" in shader.code, "shader samples the rendered full screen")
	assert_true("dot(" in shader.code, "shader computes luminance for grayscale")
	for child in presentation.get_children():
		assert_false(child is Panel, "death message follows the de-boxed HUD idiom")


func test_durability_cost_logs_and_toasts_once_per_death() -> void:
	var log = CombatLog.new()
	add_child_autofree(log)
	var presentation = DeathPresentation.new()
	add_child_autofree(presentation)
	presentation.setup(log)
	presentation.begin_death()
	presentation.begin_death()  # duplicate network delivery must not nag or double-log
	assert_eq(
		log.get_lines().count("Your gear was damaged."),
		1,
		"T-364 cost surfaces as exactly one quiet combat-log line"
	)
	assert_eq(presentation.toast_text(), "Your gear was damaged", "small toast uses the quiet copy")
	assert_gt(presentation.toast_alpha(), 0.0, "durability toast is visible on the death edge")


func test_server_shaped_death_respawn_round_trip_gates_abilities_and_logs_cost() -> void:
	var main = MainScene.new()
	var feedback = CombatFeedbackScene.new()
	add_child_autofree(feedback)
	await get_tree().process_frame
	var presentation = DeathPresentation.new()
	add_child_autofree(presentation)
	presentation.setup(feedback.get_combat_log())
	var remotes = RemoteEntitiesScene.new()
	add_child_autofree(remotes)
	var attack_timer := Timer.new()
	var spy := NetSpy.new()
	main.combat_feedback = feedback
	main.death_presentation = presentation
	main.remote_entities = remotes
	main._attack_timer = attack_timer
	main._net = spy
	main._my_peer_id = 99
	main._target_id = 1001
	main._kit = [0]

	main._on_combat({"type": "player_death", "peer_id": 99, "player_id": 99})
	assert_true(presentation.is_input_disabled(), "authoritative local death starts the input lock")
	assert_true(
		"Your gear was damaged." in feedback.get_combat_log().get_lines(),
		"server-shaped death reaches the durability combat-log seam"
	)
	main._cast_kit_slot(0)
	assert_eq(spy.ability_calls.size(), 0, "dead/fading client sends no ability intent")

	var player = LocalPlayerScene.new()
	add_child_autofree(player)
	main.local_player = player
	main._on_combat({"type": "player_respawn", "peer_id": 99, "player_id": 99})
	presentation._process(DeathState.RESPAWN_FADE_SECONDS)
	assert_false(presentation.is_input_disabled(), "respawn event releases after the fade")
	attack_timer.free()
	main.free()
