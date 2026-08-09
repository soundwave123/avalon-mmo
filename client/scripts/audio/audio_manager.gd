class_name AudioManager
extends Node

# T-111 Audio pass 1: the client's sound. A non-positional looping MEADOW AMBIENCE (so the world is
# no longer silent) + a small one-shot SFX pool driven by play_sfx(). All clips are procedurally
# synthesized (tools/assetgen/gen_audio.py) so they're inherently licence-free. Built in code (no
# .tscn) and headless-unit-testable like the rest of the client.

const AMBIENT := "res://assets/audio/ambient_meadow.wav"
const AMBIENT_BASE_DB := -17.0  # the ambience bed's design level (T-078 offsets ride on top of it)
const AMBIENT_INDOOR_MUFFLE_DB := -12.0  # T-187: walls dampen the outdoor bed while indoors
# T-305: a second, non-positional DAYTIME BIRDSONG bed layered UNDER the meadow so open ground isn't
# a dead flat drone. Sits below the meadow base, gated by the world day clock (silent at night) and
# muffled indoors like the meadow. (Positional treeline birdsong is separate, in ambient_fx_layer.)
const BIRDSONG_BED := "res://assets/audio/amb_birdsong.wav"
# T-733: pulled 3 dB down from the shipped -24 (owner: "too many birds tweeting") and, more
# importantly, DENSITY-GATED below. A bed can't be scheduled the way the T-733 treeline calls are —
# it is one looping player — so it rides the same BirdCalls.DENSITY_BY_DAY_T curve as an
# attenuation: full at the dawn chorus, deeply pulled back through the midday hours.
const BIRDSONG_BASE_DB := -27.0  # quieter than the meadow bed — a background layer, not foreground
const BIRDSONG_NIGHT_ATTEN_DB := -50.0  # faded to ~inaudible after dark
const BIRDSONG_DENSITY_DIM_DB := -11.0  # the dim at zero density (BirdCalls.bed_density_atten_db)
# T-409: the Era-2 ASHMOOR global bed — a low distant city hum that REPLACES the meadow/birdsong
# beds inside the 1920s district (the Era-1 counterpart to the meadow bed). Both sides era-gate in
# _process (mirroring the birdsong day-gate): the meadow+birdsong fade to silence inside Ashmoor
# and the hum fades outside it, so the eras never share ambience — no birdsong leaks in-district.
const ASHMOOR_HUM_BED := "res://assets/audio/amb_city_hum.wav"
const ASHMOOR_HUM_BASE_DB := -19.0  # a quiet urban bed, just under the meadow's -17 design level
# T-675: the NIGHT layer. Crickets are the birdsong bed's inverse — the same day clock, the gate
# flipped (full at night, faded to ~inaudible by day; the two are never simultaneously full since
# the paired attenuations always sum to the full dim). Era-1 only, muffled indoors like the rest.
const CRICKETS_BED := "res://assets/audio/amb_crickets.wav"
const CRICKETS_BASE_DB := -26.0  # under the birdsong bed — night is QUIETER than day
const CRICKETS_DAY_ATTEN_DB := -50.0  # faded to ~inaudible in daylight (the inverted gate)
# T-675: the night wind gains a lonely edge — a subtle pitch-down variant of the meadow/wind bed
# (same loop, re-tuned; reuse-over-new), lerped across dusk/dawn by the same day factor.
const NIGHT_WIND_PITCH := 0.90
# T-675: the RAIN bed — T-614 made rain visible; this is its sound. Gated on the weather state
# (WorldView._rain_wanted, the same outdoor truth that drives the particles) through a smoothed
# mix so showers fade in/out instead of snapping. Rain is weather, not era — it plays in BOTH
# eras; the T-187 indoor muffle still applies (rain on the roof, not in the room).
const RAIN_BED := "res://assets/audio/amb_rain.wav"
const RAIN_BASE_DB := -20.0  # audible under the meadow bed, never foreground
const RAIN_OFF_ATTEN_DB := -60.0  # ≈inaudible when the weather is dry
const RAIN_MIX_RATE := 0.6  # mix units/sec — a shower fades in over ~1.7s
const SFX := {
	"footstep": "res://assets/audio/footstep.wav",
	"ui_click": "res://assets/audio/ui_click.wav",
	"spell_cast": "res://assets/audio/spell_cast.wav",
	"hit": "res://assets/audio/hit.wav",
	"levelup": "res://assets/audio/levelup.wav",
	"defeat": "res://assets/audio/defeat.wav",
	# T-343 phase 2: frost-bolt cues voiced to the Sub-Zero lance (era-direction §11.5 sound bar) —
	# crystalline cast charge, icy flight whoosh, glass-shatter + deep-thump impact.
	"frost_cast": "res://assets/audio/frost_cast.wav",
	"frost_flight": "res://assets/audio/frost_flight.wav",
	"frost_impact": "res://assets/audio/frost_impact.wav",
	# T-350: Era-2 gunplay cues (ashmoor-direction §7 / era-direction §11.5 "sound weight") — a
	# deep revolver report, the heavier tommy-gun burst, and the mechanical action/hammer cue.
	"gun_shot": "res://assets/audio/gun_shot.wav",
	"tommy_burst": "res://assets/audio/tommy_burst.wav",
	"gun_action": "res://assets/audio/gun_action.wav",
	# T-343 phase 3: per-SCHOOL cues for the restyled non-frost kit (era-direction §11.5), mapped
	# per ability by AbilitySfx — fire/holy/shadow schools, the warrior swing whoosh, the heal
	# landing chime. One-shots: their WAV imports must keep loop OFF (T-415 discipline, inverted).
	"melee_swing": "res://assets/audio/melee_swing.wav",
	"fire_cast": "res://assets/audio/fire_cast.wav",
	"fire_impact": "res://assets/audio/fire_impact.wav",
	"holy_cast": "res://assets/audio/holy_cast.wav",
	"holy_impact": "res://assets/audio/holy_impact.wav",
	"heal_chime": "res://assets/audio/heal_chime.wav",
	"shadow_cast": "res://assets/audio/shadow_cast.wav",
}

# T-503: the frostbolt CHARGE-UP layer — a sustained, LOOPING menacing icy drone played under the
# cast bar while the mage winds up (its pitch is ramped up across the cast by set_charge_progress
# for the "power building" rise). A DEDICATED player (not the round-robin one-shot pool) so it can
# sustain for the whole cast and be stopped cleanly on impact / interrupt. Loop-import discipline
# per T-415 (edit/loop_mode=2 + non-empty region) — the game would silent-run the charge otherwise.
const FROST_CHARGE := "res://assets/audio/frost_charge.wav"
const CHARGE_PITCH_LO := 0.85  # cast start
const CHARGE_PITCH_HI := 1.35  # cast full (the rising telegraph)

# T-503: a brief MUSIC-BED duck on the heavy frost impact — a simple bus dB dip that recovers over
# ~0.5s so the score gets out of the way of the money hit (era-direction §11.5 "sound weight").
# Ducks the "Music" bus (MusicBedLayer, T-416) additively via the bus volume, which MusicBedLayer
# never touches (it drives per-player volume only) — so this never fights the crossfade. No-op when
# the bus is absent (headless / music not built).
const MUSIC_BUS := "Music"
const MUSIC_DUCK_DB := -12.0
const MUSIC_DUCK_RECOVER_DB_PER_SEC := 24.0  # ~0.5s back up from a full -12 dB dip

# T-697 fix 8: the global-bed dB derivation (birdsong/meadow/hum/crickets/rain + wind pitch) runs
# at ~10 Hz, not per frame — its gates (day clock, era, muffle, rain mix) move over seconds, and
# 100 ms volume steps are inaudible. The fast Music-bus duck recovery stays per-frame (a 10 Hz
# step there would be an audible 2.4 dB stair). Seeded so the FIRST tick applies immediately.
const _BED_TICK_S := 0.1

var ambient: AudioStreamPlayer = null
var birdsong: AudioStreamPlayer = null  # T-305: daytime birdsong bed layered under the meadow
var ashmoor_hum: AudioStreamPlayer = null  # T-409: Era-2 city-hum bed, gated to Ashmoor
var crickets: AudioStreamPlayer = null  # T-675: night crickets bed — birdsong's inverse gate
var rain: AudioStreamPlayer = null  # T-675: rain bed, gated on the T-614 weather state
var charge: AudioStreamPlayer = null  # T-503: the sustained frostbolt cast-charge layer
var _sfx_players: Array[AudioStreamPlayer] = []
var _sfx_idx := 0
var _cache := {}
var _last_step_ms := 0
var _sfx_volume_db := 0.0  # T-078: user SFX offset (dB) added to every one-shot; 0 = design level
var _ambient_volume_db := 0.0  # T-078: user ambience offset (dB) on top of AMBIENT_BASE_DB
var _indoor_muffle_db := 0.0  # T-187: extra attenuation while indoors, layered on the user offset
var _music_duck_db := 0.0  # T-503: current dip applied to the Music bus (<=0; 0 = no duck)
var _rain_mix := 0.0  # T-675: smoothed rain gate mix in [0,1] (0 = dry, 1 = full shower)
var _bed_accum := _BED_TICK_S  # T-697 fix 8: bed volume-tick accumulator (born due)


func _ready() -> void:
	ambient = AudioStreamPlayer.new()
	ambient.name = "Ambient"
	var s := load(AMBIENT) as AudioStream
	# the WAV is baked with a seamless loop crossfade; make the stream actually loop.
	if s is AudioStreamWAV:
		(s as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD
	ambient.stream = s
	ambient.volume_db = AMBIENT_BASE_DB + _ambient_volume_db  # a quiet bed, not a foreground drone
	ambient.autoplay = true
	add_child(ambient)
	ambient.play()
	# T-305: the daytime birdsong bed — a second looping layer under the meadow, day-gated in
	# _process (starts at night level; _process lifts it to daylight within a frame if it's day).
	birdsong = AudioStreamPlayer.new()
	birdsong.name = "BirdsongBed"
	var bs := load(BIRDSONG_BED) as AudioStream
	if bs is AudioStreamWAV:
		(bs as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD
	birdsong.stream = bs
	birdsong.volume_db = BIRDSONG_BASE_DB + BIRDSONG_NIGHT_ATTEN_DB
	birdsong.autoplay = true
	add_child(birdsong)
	birdsong.play()
	# T-409: the Era-2 Ashmoor city-hum bed — a global bed that plays only inside the district
	# (era-gated in _process). Born at the cross-era silence level so it's inaudible in the
	# medieval world; _process lifts it to base within a frame once the listener is in Ashmoor.
	ashmoor_hum = AudioStreamPlayer.new()
	ashmoor_hum.name = "AshmoorHumBed"
	var ah := load(ASHMOOR_HUM_BED) as AudioStream
	if ah is AudioStreamWAV:
		(ah as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD
	ashmoor_hum.stream = ah
	ashmoor_hum.volume_db = ASHMOOR_HUM_BASE_DB + AmbientFxLayer.ERA_MISMATCH_ATTEN_DB
	ashmoor_hum.autoplay = true
	add_child(ashmoor_hum)
	ashmoor_hum.play()
	# T-675: the night crickets bed — born at the daylight-silenced level (the headless/no-world
	# default is full daylight, so it starts inaudible; _process lifts it as night falls).
	crickets = _make_bed("CricketsBed", CRICKETS_BED, CRICKETS_BASE_DB + CRICKETS_DAY_ATTEN_DB)
	# T-675: the rain bed — born dry-silenced; _process fades it in when the weather turns.
	rain = _make_bed("RainBed", RAIN_BED, RAIN_BASE_DB + RAIN_OFF_ATTEN_DB)
	# one-shot pool so overlapping SFX don't cut each other off
	for i in range(6):
		var p := AudioStreamPlayer.new()
		p.name = "Sfx%d" % i
		add_child(p)
		_sfx_players.append(p)
	# T-503: the sustained frostbolt charge layer (own player; started/stopped by the cast bar).
	charge = AudioStreamPlayer.new()
	charge.name = "FrostCharge"
	var cs := load(FROST_CHARGE) as AudioStream
	if cs is AudioStreamWAV:
		(cs as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD  # belt-and-braces (import=2)
	charge.stream = cs
	add_child(charge)


# T-675: build one looping global ambience bed (the T-111/T-305 idiom, extracted for the new
# beds): loop-forced stream, born at `born_db` (a gated bed is born SILENT — no one-frame leak),
# autoplaying under this manager.
func _make_bed(bed_name: String, path: String, born_db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.name = bed_name
	var s := load(path) as AudioStream
	if s is AudioStreamWAV:
		(s as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD
	p.stream = s
	p.volume_db = born_db
	p.autoplay = true
	add_child(p)
	p.play()
	return p


# T-675 pure gate math (headlessly testable): the birdsong day gate and the crickets night gate
# are the SAME dim driven by complementary ends of the day factor — their attenuations always sum
# to the full dim, so the two beds are never simultaneously full.
static func day_gate_atten_db(day: float) -> float:
	return (1.0 - clampf(day, 0.0, 1.0)) * BIRDSONG_NIGHT_ATTEN_DB


static func night_gate_atten_db(day: float) -> float:
	return clampf(day, 0.0, 1.0) * CRICKETS_DAY_ATTEN_DB


# T-675: rain-bed attenuation off the smoothed mix — 0 dB in a full shower, RAIN_OFF_ATTEN_DB dry.
static func rain_gate_atten_db(mix: float) -> float:
	return (1.0 - clampf(mix, 0.0, 1.0)) * RAIN_OFF_ATTEN_DB


# T-675: the wind's lonely night edge — the meadow/wind bed pitched subtly down after dark
# (a re-tuned variant of the same loop, not a second asset).
static func night_wind_pitch(day: float) -> float:
	return lerpf(NIGHT_WIND_PITCH, 1.0, clampf(day, 0.0, 1.0))


# Play a named one-shot (round-robins the pool). Unknown names are ignored. T-343 p3: `pitch`
# lets one file serve several abilities as a re-tuned variant (reuse-over-new); it is set every
# call so a pitched play never leaks into the next default-pitch one on the shared pool player.
func play_sfx(sfx_name: String, volume_db := -9.0, pitch := 1.0) -> void:
	if not SFX.has(sfx_name):
		return
	var s = _cache.get(sfx_name)
	if s == null:
		s = load(SFX[sfx_name])
		_cache[sfx_name] = s
	var p: AudioStreamPlayer = _sfx_players[_sfx_idx]
	_sfx_idx = (_sfx_idx + 1) % _sfx_players.size()
	p.stream = s
	p.volume_db = volume_db + _sfx_volume_db  # T-078: respect the user's SFX volume
	p.pitch_scale = pitch
	p.play()


# T-503: start the sustained frost charge layer at the cast's start pitch (idempotent — a re-call
# while already charging just leaves it running, so the cast bar can call it every frame).
func start_charge(volume_db := -7.0) -> void:
	if charge == null:
		return
	charge.volume_db = volume_db + _sfx_volume_db  # T-078: honour the user's SFX slider
	if not charge.playing:
		charge.pitch_scale = CHARGE_PITCH_LO
		charge.play()


# T-503: ramp the charge pitch UP as the cast fills (ratio 0..1) — the rising "power building" read.
func set_charge_progress(ratio: float) -> void:
	if charge != null and charge.playing:
		charge.pitch_scale = lerpf(CHARGE_PITCH_LO, CHARGE_PITCH_HI, clampf(ratio, 0.0, 1.0))


# T-503: stop the charge layer (cast completed -> impact, or interrupted). Safe to call when idle.
func stop_charge() -> void:
	if charge != null and charge.playing:
		charge.stop()


func is_charging() -> bool:
	return charge != null and charge.playing


# T-503: duck the Music bus for the heavy impact (takes the deeper dip if already ducking). The
# recovery ramp lives in _process; no-op cleanly when the Music bus doesn't exist.
func duck_music(amount_db := MUSIC_DUCK_DB) -> void:
	_music_duck_db = minf(_music_duck_db, amount_db)
	_apply_music_duck()


func _apply_music_duck() -> void:
	var bus := AudioServer.get_bus_index(MUSIC_BUS)
	if bus != -1:
		AudioServer.set_bus_volume_db(bus, _music_duck_db)


# T-078: settings-menu volume setters. Both take a dB OFFSET (0.0 = the design level, negative =
# quieter). The SFX offset is stored so future play_sfx one-shots respect the chosen level.
func set_ambient_volume_db(offset_db: float) -> void:
	_ambient_volume_db = offset_db
	_apply_ambient_volume()


func set_sfx_volume_db(offset_db: float) -> void:
	_sfx_volume_db = offset_db


# T-187: indoor ambience gating — muffle the outdoor bed (wind/birds/crowd) while the player is
# inside a building, layered on top of (never overwriting) the user's ambience slider. Restores
# cleanly on exit since it's a separate term, not a re-derived absolute volume.
func set_indoor_muffle(indoors: bool) -> void:
	_indoor_muffle_db = AMBIENT_INDOOR_MUFFLE_DB if indoors else 0.0
	_apply_ambient_volume()
	# T-675 item 6: fan the muffle out to the positional zone beds (AmbientFxLayer) via the
	# ambience_layers group — no new call site in main.gd (it sits at the 1000-line cap).
	if is_inside_tree():
		get_tree().call_group("ambience_layers", "set_indoor_muffle", indoors)


func _apply_ambient_volume() -> void:
	if ambient != null:
		ambient.volume_db = AMBIENT_BASE_DB + _ambient_volume_db + _indoor_muffle_db


# Rate-limited footstep — call every frame while moving; it fires at a walking cadence.
func footstep_if_due(interval_ms := 340) -> void:
	var now := Time.get_ticks_msec()
	if now - _last_step_ms >= interval_ms:
		_last_step_ms = now
		play_sfx("footstep", -14.0)


# T-305: day-gate the birdsong bed — full daylight level by day, faded to ~silence at night. Reads
# the world day clock (WorldView._day_t) without editing the visual-lane world_view.gd; falls back
# to full daylight when there's no world (headless tests keep the bed at its base level).
func _process(delta: float) -> void:
	# T-503: recover the Music-bus duck back toward 0 dB after an impact dip.
	if _music_duck_db < 0.0:
		_music_duck_db = minf(0.0, _music_duck_db + MUSIC_DUCK_RECOVER_DB_PER_SEC * delta)
		_apply_music_duck()
	if birdsong == null:
		return
	# T-697 fix 8: throttle the bed derivation to ~10 Hz; dt carries the full elapsed time so the
	# rain-mix smoothing advances by exactly as much as the skipped frames did.
	_bed_accum += delta
	if _bed_accum < _BED_TICK_S:
		return
	var dt := _bed_accum
	_bed_accum = 0.0
	var day := _day_factor()
	# T-409: era-gate the global beds. The meadow + birdsong fade to silence inside Ashmoor; the
	# Ashmoor city hum fades to silence outside it — additive dB terms, mirroring the day-gate.
	var here := AmbientFxLayer.listener_era(self)
	var era1_atten := AmbientFxLayer.era_gate_atten(AmbientFxLayer.ERA_MEDIEVAL, here)
	var era2_atten := AmbientFxLayer.era_gate_atten(AmbientFxLayer.ERA_ASHMOOR, here)
	birdsong.volume_db = (
		BIRDSONG_BASE_DB
		+ _ambient_volume_db
		+ _indoor_muffle_db
		+ day_gate_atten_db(day)
		+ era1_atten
		# T-733: the bed follows the bird-density curve too — dawn chorus full, midday a whisper.
		+ BirdCalls.bed_density_atten_db(
			BirdCalls.density_at(_day_t_raw()), BIRDSONG_DENSITY_DIM_DB
		)
	)
	if ambient != null:
		ambient.volume_db = AMBIENT_BASE_DB + _ambient_volume_db + _indoor_muffle_db + era1_atten
		# T-675: the wind gains a lonely edge after dark — the same bed, pitched subtly down.
		ambient.pitch_scale = night_wind_pitch(day)
	if ashmoor_hum != null:
		ashmoor_hum.volume_db = (
			ASHMOOR_HUM_BASE_DB + _ambient_volume_db + _indoor_muffle_db + era2_atten
		)
	# T-675: crickets — birdsong's inverted gate (full at night, silent by day), Era-1 only.
	if crickets != null:
		crickets.volume_db = (
			CRICKETS_BASE_DB
			+ _ambient_volume_db
			+ _indoor_muffle_db
			+ night_gate_atten_db(day)
			+ era1_atten
		)
	# T-675: rain — follow the T-614 weather state through a smoothed mix (no snap on/off). Rain
	# is weather, not era: no era term; the indoor muffle still applies (rain on the roof).
	if rain != null:
		_rain_mix = move_toward(_rain_mix, 1.0 if _rain_want() else 0.0, RAIN_MIX_RATE * dt)
		rain.volume_db = (
			RAIN_BASE_DB + _ambient_volume_db + _indoor_muffle_db + rain_gate_atten_db(_rain_mix)
		)


func _day_factor() -> float:
	var wv := get_node_or_null("/root/Main/WorldView")
	if wv == null:
		return 1.0
	var dt = wv.get("_day_t")
	if dt == null:
		return 1.0
	# sun above the horizon when sin(day_t*TAU) > 0; smooth across dusk/dawn.
	return clampf(smoothstep(-0.05, 0.25, sin(float(dt) * TAU)), 0.0, 1.0)


# T-733: the RAW day clock (0..1, T-415 convention: noon = 0.25) — the bird-density curve needs the
# phase, not just "is the sun up". Fails OPEN with no world (headless): 0.0 = sunrise, full density.
func _day_t_raw() -> float:
	var wv := get_node_or_null("/root/Main/WorldView")
	if wv == null:
		return 0.0
	var dt = wv.get("_day_t")
	return 0.0 if dt == null else fposmod(float(dt), 1.0)


# T-675: the outdoor rain truth — WorldView._rain_wanted, the SAME state that drives the T-614
# rain particles (read without editing the visual-lane world_view.gd, the _day_t idiom). Falls
# back to dry with no world (headless tests: the rain bed stays silent).
func _rain_want() -> bool:
	var wv := get_node_or_null("/root/Main/WorldView")
	if wv == null:
		return false
	var rw = wv.get("_rain_wanted")
	return bool(rw) if rw != null else false
