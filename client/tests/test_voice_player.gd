extends GutTest

# T-674: the pre-generated voiced-dialogue pipeline. These prove the CLIENT wiring headlessly —
# stable line-id keying, text->file resolution, the sha1 staleness guard, the T-573 silent fallback
# (missing/stale/unshipped -> no audio, no error), AudioStreamPlayer3D parenting onto the NPC, and
# the T-415 loop-OFF import discipline. They pass WHETHER OR NOT real TTS audio was generated: the
# play path is driven by a tiny committed test-fixture Ogg (res://tests/fixtures/voice_fixture.ogg),
# never Geld's (deferred) recording.

const VoicePlayer = preload("res://scripts/audio/voice_player.gd")
const FIXTURE_OGG := "res://tests/fixtures/voice_fixture.ogg"
const FIXTURE_BASE := "res://tests/fixtures/"
const SHIPPED_MANIFEST := "res://assets/audio/voice_manifest.json"
const GELD := "npc_farmer_geld"
const GELD_GREETING := "Those wolves will be the end of me, friend."


# A stand-in NpcWorldLayer exposing body_for(npc_id) -> the NPC's world node (the parenting target).
class FakeNpcWorld:
	extends Node
	var bodies: Dictionary = {}

	func spawn(npc_id: String) -> Node3D:
		var body := Node3D.new()
		body.name = "Npc_%s" % npc_id
		bodies[npc_id] = body
		add_child(body)
		return body

	func body_for(npc_id: String) -> Node3D:
		return bodies.get(npc_id, null)


func _vp() -> VoicePlayer:
	var vp := VoicePlayer.new()
	add_child_autofree(vp)
	return vp


# One fixture manifest entry keyed correctly for `text`, pointing at the committed fixture Ogg.
func _fixture_lines(npc_id: String, text: String) -> Dictionary:
	return {
		VoicePlayer.line_id(npc_id, text):
		{
			"npc_id": npc_id,
			"kind": "greeting",
			"text": text,
			"sha1": text.sha1_text(),
			"file": "voice_fixture.ogg",
		}
	}


# ── keying ────────────────────────────────────────────────────────────────────────────────────────
func test_line_id_is_stable_and_matches_the_gen_tool_scheme() -> void:
	var lid := VoicePlayer.line_id(GELD, GELD_GREETING)
	assert_eq(
		lid, "%s:%s" % [GELD, GELD_GREETING.sha1_text().substr(0, 10)], "line_id = npc:sha1[:10]"
	)
	assert_eq(
		lid, VoicePlayer.line_id(GELD, GELD_GREETING), "line_id is deterministic across calls"
	)
	# Locks the value the python gen_voice.py wrote for Geld's greeting (cross-language agreement).
	assert_eq(lid, "npc_farmer_geld:4d673ebd35", "matches the manifest key the generator produced")


# ── shipped manifest schema ───────────────────────────────────────────────────────────────────────
func test_shipped_manifest_schema_and_keys() -> void:
	assert_true(
		FileAccess.file_exists(SHIPPED_MANIFEST), "the voice manifest ships with the client"
	)
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(SHIPPED_MANIFEST))
	assert_true(data is Dictionary, "manifest parses to a Dictionary")
	var lines: Dictionary = (data as Dictionary).get("lines", {})
	assert_gt(lines.size(), 0, "manifest inventories at least one line")
	for lid: String in lines:
		var e: Dictionary = lines[lid]
		for key: String in ["npc_id", "kind", "text", "sha1", "file"]:
			assert_true(e.has(key), "line %s has %s" % [lid, key])
		assert_eq(str(e["sha1"]).length(), 40, "sha1 is a full 40-hex digest")
		assert_eq(
			lid, VoicePlayer.line_id(str(e["npc_id"]), str(e["text"])), "key == derived line_id"
		)
		assert_eq(str(e["sha1"]), str(e["text"]).sha1_text(), "recorded sha1 matches the text")


# ── resolve + staleness ───────────────────────────────────────────────────────────────────────────
func test_resolve_returns_the_file_when_text_matches() -> void:
	var vp := _vp()
	vp.set_manifest(_fixture_lines(GELD, GELD_GREETING), FIXTURE_BASE)
	assert_eq(vp.resolve(GELD, GELD_GREETING), FIXTURE_OGG, "matching text resolves to its Ogg")


func test_resolve_silent_when_authored_text_edited() -> void:
	var vp := _vp()
	vp.set_manifest(_fixture_lines(GELD, GELD_GREETING), FIXTURE_BASE)
	# An edited line hashes to a new line_id the manifest doesn't hold -> silent text-only fallback.
	assert_eq(vp.resolve(GELD, GELD_GREETING + " Truly."), "", "edited text flags stale -> silent")


func test_resolve_silent_on_sha1_drift_even_if_line_id_present() -> void:
	var vp := _vp()
	var lid := VoicePlayer.line_id(GELD, GELD_GREETING)
	# Same key, but a stored sha1 that no longer matches the text (belt-and-braces collision guard).
	vp.set_manifest({lid: {"sha1": "deadbeef", "file": "voice_fixture.ogg"}}, FIXTURE_BASE)
	assert_eq(vp.resolve(GELD, GELD_GREETING), "", "sha1 mismatch -> silent")


func test_resolve_silent_when_ogg_not_shipped_yet() -> void:
	var vp := _vp()
	# The manifest holds the line but the Ogg isn't present (the deferred/pre-asset state) -> T-573.
	var lines := _fixture_lines(GELD, GELD_GREETING)
	lines[VoicePlayer.line_id(GELD, GELD_GREETING)]["file"] = "not_generated_yet.ogg"
	vp.set_manifest(lines, FIXTURE_BASE)
	assert_eq(vp.resolve(GELD, GELD_GREETING), "", "manifest present, asset absent -> silent wire")


func test_no_manifest_is_wholly_silent() -> void:
	var vp := _vp()
	vp.load_manifest("res://assets/audio/does_not_exist.json")
	assert_eq(vp.line_count(), 0, "a missing manifest loads to zero lines")
	assert_eq(vp.resolve(GELD, GELD_GREETING), "", "no manifest -> silent")


# ── playback + parenting (T-573 contract) ─────────────────────────────────────────────────────────
func test_play_line_parents_audiostreamplayer3d_to_the_npc() -> void:
	var world := FakeNpcWorld.new()
	add_child_autofree(world)
	var body := world.spawn(GELD)
	var vp := _vp()
	vp.set_npc_world(world)
	vp.set_manifest(_fixture_lines(GELD, GELD_GREETING), FIXTURE_BASE)
	var player := vp.play_line(GELD, GELD_GREETING)
	assert_not_null(player, "a voiced line spawns a player")
	assert_true(
		player is AudioStreamPlayer3D, "the voice plays on an AudioStreamPlayer3D (positional)"
	)
	assert_eq(player.get_parent(), body, "the player is parented to the NPC world node")
	assert_true(
		player.stream is AudioStreamOggVorbis, "the NPC's Ogg line is assigned as the stream"
	)


func test_play_line_reuses_one_player_per_npc() -> void:
	var world := FakeNpcWorld.new()
	add_child_autofree(world)
	var body := world.spawn(GELD)
	var vp := _vp()
	vp.set_npc_world(world)
	vp.set_manifest(_fixture_lines(GELD, GELD_GREETING), FIXTURE_BASE)
	vp.play_line(GELD, GELD_GREETING)
	vp.play_line(GELD, GELD_GREETING)  # re-open the panel -> restart, not a second node
	var voice_children := 0
	for c in body.get_children():
		if c is AudioStreamPlayer3D:
			voice_children += 1
	assert_eq(voice_children, 1, "one reused VoiceLine player per NPC body")


func test_play_line_silent_when_no_voice_entry() -> void:
	var world := FakeNpcWorld.new()
	add_child_autofree(world)
	var body := world.spawn(GELD)
	var vp := _vp()
	vp.set_npc_world(world)
	vp.set_manifest(_fixture_lines(GELD, GELD_GREETING), FIXTURE_BASE)
	assert_null(
		vp.play_line(GELD, "an unvoiced line"), "unknown line -> no player (silent, no error)"
	)
	assert_eq(body.get_child_count(), 0, "no audio node was spawned on the NPC")


func test_play_line_silent_when_npc_not_in_world() -> void:
	var world := FakeNpcWorld.new()
	add_child_autofree(world)  # Geld is NOT spawned -> body_for returns null
	var vp := _vp()
	vp.set_npc_world(world)
	vp.set_manifest(_fixture_lines(GELD, GELD_GREETING), FIXTURE_BASE)
	assert_null(vp.play_line(GELD, GELD_GREETING), "no world body -> silent (out-of-range NPC)")


# ── T-415 loop-OFF import discipline (both directions) ────────────────────────────────────────────
func test_voice_ogg_imports_with_loop_off() -> void:
	var stream := load(FIXTURE_OGG) as AudioStreamOggVorbis
	assert_not_null(stream, "the fixture Ogg imports as AudioStreamOggVorbis")
	assert_false(stream.loop, "a voiced ONE-SHOT line must import with loop OFF (T-415)")


func test_loop_flag_is_a_meaningful_assertion() -> void:
	# The inverse direction: prove the guard isn't vacuous — a stream WITH loop on reads back true.
	var looped := AudioStreamOggVorbis.new()
	looped.loop = true
	assert_true(looped.loop, "loop=true is detectable, so the loop-OFF assertion has teeth")
