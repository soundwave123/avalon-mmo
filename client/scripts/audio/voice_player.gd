class_name VoicePlayer
extends Node

# T-674: the client half of the pre-generated voiced-NPC-dialogue pipeline (prototype: Farmer Geld).
#
# A dedicated, signal-driven node — NOT edits scattered through the UI. It observes the quest-offer
# / service panel's `line_shown(npc_id, text)` signal (self-connected via the "voice_line_source"
# group), resolves the DISPLAYED line text to a static Ogg via the manifest, and plays it on an
# AudioStreamPlayer3D parented to the NPC's world node — the voice comes from the character in the
# world. The text subtitle already renders (the panel drew it); this only adds the audio layer.
#
# GRACEFUL SILENT CONTRACT (mirrors T-573's mount seam): every miss — no manifest, no matching line,
# an edited/stale line (sha1 drift), a manifest entry whose Ogg isn't shipped yet, or an NPC with no
# world body — resolves to a no-op. No audio, no error spam. The wire ships LIVE and SILENT before
# the asset: dropping the generated Oggs into client/assets/audio/voice/ lights it up with no code
# edits (the T-573 idiom exactly).
#
# KEYING: line_id = "{npc_id}:{sha1(text)[:10]}"; the manifest stores each line's FULL source-text
# sha1. Editing an authored line changes its hash → a new line_id the manifest doesn't hold → silent
# text-only fallback until re-voiced (edit-safe; see tools/voice/gen_voice.py check-stale).

const DEFAULT_MANIFEST := "res://assets/audio/voice_manifest.json"
const AUDIO_BASE := "res://assets/audio/"
const VOICE_NODE_NAME := "VoiceLine"  # the reused AudioStreamPlayer3D child under each NPC body
const SOURCE_GROUP := "voice_line_source"  # panels emitting line_shown(npc_id, text) join this
const VOICE_UNIT_DB := 0.0  # per-line level; a dedicated bus/user slider is a scaling follow-up

# T-752: NPC-speech spatialization, set EXPLICITLY. AudioStreamPlayer3D's engine defaults are wrong
# for a voice in three separate ways — unit_size 10 holds full level out to ~10 m, max_db +3 boosts
# it above every other source at close range, and max_distance 0 means "never culled", i.e. audible
# clean across the zone. Because the T-573 silent contract keeps this wire live and mute until the
# first Ogg ships, the defaults were dormant: the day a voice line landed, Farmer Geld would have
# been the loudest thing in the game at 100 m. These are near-field speech values, cribbed from
# LocomotionAudio's in-world-verified block (T-737) and pulled in a little: a voice carries less
# far than a footfall's crack, so it culls sooner than locomotion's 26 m.
const VOICE_UNIT_SIZE := 4.0  # ~full level inside a conversational radius, then rolloff
const VOICE_MAX_DISTANCE := 22.0  # culled past the range you could still make out words
const VOICE_MAX_DB := 0.0  # never boosted when you are standing on top of the speaker

var _lines: Dictionary = {}  # line_id -> {sha1, file, ...}
var _audio_base: String = AUDIO_BASE
var _npc_world: Node = null  # NpcWorldLayer (has body_for); defaults to get_parent()


func _ready() -> void:
	load_manifest()
	# The panels are built after this node (main.gd wiring order), so connect on the next idle frame
	# once the whole HUD subtree exists.
	_connect_sources.call_deferred()


# ── pure keying (headlessly testable; mirrors gen_voice.py) ───────────────────────────────────────
static func line_id(npc_id: String, text: String) -> String:
	return "%s:%s" % [npc_id, text.sha1_text().substr(0, 10)]


# ── manifest ──────────────────────────────────────────────────────────────────────────────────────
func load_manifest(res_path: String = DEFAULT_MANIFEST) -> void:
	_lines = {}
	_audio_base = AUDIO_BASE
	if not FileAccess.file_exists(res_path):
		return  # no manifest -> the whole feature is silent, by contract
	var txt := FileAccess.get_file_as_string(res_path)
	var data: Variant = JSON.parse_string(txt)
	if data is Dictionary:
		var lines: Variant = (data as Dictionary).get("lines", {})
		if lines is Dictionary:
			_lines = lines


# Test seam: inject an in-memory manifest + audio base dir (so a fixture Ogg drives the play path).
func set_manifest(lines: Dictionary, audio_base: String) -> void:
	_lines = lines
	_audio_base = audio_base


func set_npc_world(npc_world: Node) -> void:
	_npc_world = npc_world


func line_count() -> int:
	return _lines.size()


# ── resolve displayed text -> shipped file (or "" for the silent fallback) ────────────────────────
func resolve(npc_id: String, text: String) -> String:
	var lid := line_id(npc_id, text)
	if not _lines.has(lid):
		return ""  # no voiced line for this (or the text was edited -> new line_id) -> silent
	var entry: Dictionary = _lines[lid]
	if str(entry.get("sha1", "")) != text.sha1_text():
		return ""  # stale / truncated-hash collision guard -> silent text-only
	var path := _audio_base + str(entry.get("file", ""))
	if not ResourceLoader.exists(path):
		return ""  # T-573: manifest present, Ogg not shipped yet -> silent (wire live, waiting)
	return path


# ── playback ──────────────────────────────────────────────────────────────────────────────────────
# Play the voiced reading of `text` from the NPC. Returns the AudioStreamPlayer3D, or null on a miss
# (the graceful path). Reuses one "VoiceLine" child per NPC so re-opening a panel restarts cleanly.
func play_line(npc_id: String, text: String) -> AudioStreamPlayer3D:
	var path := resolve(npc_id, text)
	if path == "":
		return null
	var stream := load(path) as AudioStream
	if stream == null:
		return null  # unreadable asset -> silent, never a crash
	var body := _body_for(npc_id)
	if body == null:
		return null  # NPC not spawned in the world (out of range) -> silent
	var player := body.get_node_or_null(VOICE_NODE_NAME) as AudioStreamPlayer3D
	if player == null:
		player = AudioStreamPlayer3D.new()
		player.name = VOICE_NODE_NAME
		player.volume_db = VOICE_UNIT_DB
		# T-752: near-field speech, never the engine's infinite-range +3 dB defaults.
		player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		player.unit_size = VOICE_UNIT_SIZE
		player.max_distance = VOICE_MAX_DISTANCE
		player.max_db = VOICE_MAX_DB
		body.add_child(player)
	player.stream = stream
	player.play()
	return player


func _body_for(npc_id: String) -> Node3D:
	var nw: Node = _npc_world if _npc_world != null else get_parent()
	if nw != null and nw.has_method("body_for"):
		return nw.body_for(npc_id) as Node3D
	return null


# ── signal self-wiring ────────────────────────────────────────────────────────────────────────────
func _connect_sources() -> void:
	if not is_inside_tree():
		return
	for src in get_tree().get_nodes_in_group(SOURCE_GROUP):
		if src.has_signal("line_shown") and not src.line_shown.is_connected(_on_line_shown):
			src.line_shown.connect(_on_line_shown)


func _on_line_shown(npc_id: String, text: String) -> void:
	play_line(npc_id, text)
