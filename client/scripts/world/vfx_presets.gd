class_name VfxPresets
extends RefCounted

# T-343: preset library for the frost-bolt VFX gallery (owner-directed candidate vote). The data
# lives in vfx_presets.json (BASE == the current shipped look, i.e. preset 0, plus candidate
# overrides). VfxManager builds its cast / projectile-core / trail / impact pools from the ACTIVE
# preset (AVALON_VFX_PRESET, default 0). NOTHING here changes the shipped default — preset 0
# reproduces the baseline exactly so it is the honest "before" in the vote.
#
# JSON stores colors as [r,g,b,a] and vectors as [x,y,z] arrays; resolve() deep-merges an entry's
# overrides onto BASE and converts those arrays to Color / Vector3 for VfxManager. A preset may
# reference a sourced (CC0/MIT/CC-BY) particle texture via "tex"; the builder loads it if present
# and falls back to the untextured additive quad when absent. Licenses are logged in T-343.md.

const _JSON_PATH := "res://scripts/world/vfx_presets.json"

# keys whose values are color arrays / vector arrays / ramps (pairs of colors), by section.
# T-343 r2: any "*_color" key is also a color (the lance sections' aura/creep/core/edge/freeze
# colors), and "aura_core" is the white-hot birth color. A scalar "spin" (lance roll rad/s)
# passes through untouched — only Array values are converted.
const _COLOR_KEYS := ["color", "albedo", "emission", "aura_core"]
const _VEC_KEYS := ["dir", "grav", "spin"]

static var _data: Dictionary = {}


static func _load() -> Dictionary:
	if _data.is_empty():
		var txt := FileAccess.get_file_as_string(_JSON_PATH)
		var parsed = JSON.parse_string(txt)
		_data = parsed if parsed is Dictionary else {"base": {}, "presets": []}
	return _data


static func count() -> int:
	return (_load().get("presets", []) as Array).size()


# The active preset index, from AVALON_VFX_PRESET (default 0 = shipped baseline). Out-of-range or
# junk clamps to 0 so a stray env value can never break a normal client boot.
static func active_index() -> int:
	var raw := OS.get_environment("AVALON_VFX_PRESET")
	if raw == "" or not raw.is_valid_int():
		return 0
	var i := int(raw)
	return i if (i >= 0 and i < count()) else 0


static func name_of(index: int) -> String:
	var presets: Array = _load().get("presets", [])
	if index < 0 or index >= presets.size():
		return "?"
	return str((presets[index] as Dictionary).get("name", "preset %d" % index))


# Resolve a full, typed preset: BASE deep-merged with presets[index]'s overrides, with every color/
# vector array converted to Color / Vector3. Every sub-dict is complete, so VfxManager never has to
# branch on a missing key.
static func resolve(index: int) -> Dictionary:
	var data := _load()
	var base: Dictionary = data.get("base", {})
	var presets: Array = data.get("presets", [])
	var over: Dictionary = presets[index] if (index >= 0 and index < presets.size()) else {}
	var out := {}
	for section in base:
		var merged: Dictionary = (base[section] as Dictionary).duplicate(true)
		if over.has(section):
			for k in over[section] as Dictionary:
				merged[k] = (over[section] as Dictionary)[k]
		out[section] = _typed(merged)
	out["name"] = str(over.get("name", "preset %d" % index))
	out["look"] = str(over.get("look", ""))
	out["mode"] = str(over.get("mode", "burst"))  # r2: "lance" routes to FrostLanceVfx
	return out


# Convert a merged sub-dict's array literals to Color / Vector3 in place.
static func _typed(d: Dictionary) -> Dictionary:
	for k in d:
		if d[k] is Array and (k in _COLOR_KEYS or str(k).ends_with("_color")):
			d[k] = _color(d[k])
	for k in _VEC_KEYS:
		if d.has(k) and d[k] is Array:
			d[k] = _vec(d[k])
	if d.has("ramp") and d["ramp"] is Array:
		d["ramp"] = [_color(d["ramp"][0]), _color(d["ramp"][1])]
	return d


static func _color(a: Array) -> Color:
	return Color(a[0], a[1], a[2], a[3] if a.size() > 3 else 1.0)


static func _vec(a: Array) -> Vector3:
	return Vector3(a[0], a[1], a[2])
