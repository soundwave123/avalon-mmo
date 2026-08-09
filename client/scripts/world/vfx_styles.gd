class_name VfxStyles
extends RefCounted

# T-343 (owner ruling 2026-07-16): a CANDIDATE STYLE gallery for the core ability-VFX hit types —
# impact, cast, heal and (optional) projectile. Distinct from the frost-bolt preset BANK
# (vfx_presets.json): those are variants of ONE ability; THESE are competing house-language
# DIRECTIONS for each hit type, so the owner can pick a look async before phase 3 finalizes the kit.
#
# Pure data + resolver (no scene tree) so it is headlessly unit-testable. The dev harness
# (vfx_style_gallery.gd, AVALON_VFX_STYLE_GALLERY=1) renders one style at a time to a contact sheet;
# NOTHING here touches the shipped VfxManager path — these are candidates for selection, not the
# live look. A follow-up ticket wires the chosen direction into VfxManager.
#
# JSON stores colours as [r,g,b(,a)] and vectors as [x,y,z]; resolve() converts a style's emitter
# cfgs (+ optional ring/column/light/core extras) to Color / Vector3 in place.

const _JSON_PATH := "res://scripts/world/vfx_styles.json"
# Ordered so the harness + contact sheets iterate deterministically.
const HIT_TYPES := ["impact", "cast", "heal", "projectile"]
const _COLOR_KEYS := ["color"]
const _VEC_KEYS := ["dir", "grav"]

static var _data: Dictionary = {}


static func _load() -> Dictionary:
	if _data.is_empty():
		var txt := FileAccess.get_file_as_string(_JSON_PATH)
		var parsed = JSON.parse_string(txt)
		_data = parsed if parsed is Dictionary else {}
	return _data


static func hit_types() -> Array:
	var out: Array = []
	for t in HIT_TYPES:
		if _load().has(t):
			out.append(t)
	return out


static func count(hit_type: String) -> int:
	return (_load().get(hit_type, []) as Array).size()


static func name_of(hit_type: String, index: int) -> String:
	var s := _raw(hit_type, index)
	return str(s.get("name", "?"))


static func blurb_of(hit_type: String, index: int) -> String:
	return str(_raw(hit_type, index).get("blurb", ""))


static func style_id(hit_type: String, index: int) -> String:
	return str(_raw(hit_type, index).get("id", "?"))


# T-343 phase 3: the CANONICAL live house selection. The JSON "default" block names the owner-chosen
# winner id per hit type (impact grounded, cast handglow, heal motes, projectile comet). VfxManager
# builds its live non-frost pools from resolve_default(), so retargeting the house look is a data
# edit — no code change. A missing/unknown id falls back to the first candidate so a boot never
# crashes on a typo'd default.
static func default_id(hit_type: String) -> String:
	var d: Dictionary = _load().get("default", {})
	if d.has(hit_type):
		return str(d[hit_type])
	return style_id(hit_type, 0) if count(hit_type) > 0 else ""


static func index_of(hit_type: String, id: String) -> int:
	for i in range(count(hit_type)):
		if style_id(hit_type, i) == id:
			return i
	return -1


static func default_index(hit_type: String) -> int:
	var i := index_of(hit_type, default_id(hit_type))
	return i if i >= 0 else 0


static func resolve_default(hit_type: String) -> Dictionary:
	return resolve(hit_type, default_index(hit_type))


# The active hit type + index from env (harness selection). A junk/out-of-range value clamps to the
# first valid entry so a stray env var can never crash a boot.
static func active_type() -> String:
	var raw := OS.get_environment("AVALON_VFX_STYLE_TYPE")
	return raw if _load().has(raw) else str(hit_types()[0]) if not hit_types().is_empty() else ""


static func active_index() -> int:
	var raw := OS.get_environment("AVALON_VFX_STYLE_INDEX")
	if raw == "" or not raw.is_valid_int():
		return 0
	var i := int(raw)
	var n := count(active_type())
	return i if (i >= 0 and i < n) else 0


# A fully-typed copy of one style: every emitter cfg + ring/column/light/core extra converted to
# Color / Vector3. Returns {} for an out-of-range request (harness guards on it).
static func resolve(hit_type: String, index: int) -> Dictionary:
	var raw := _raw(hit_type, index)
	if raw.is_empty():
		return {}
	var out := raw.duplicate(true)
	var emitters: Array = []
	for e in out.get("emitters", []):
		emitters.append(_typed(e))
	out["emitters"] = emitters
	for extra in ["ring", "column", "light", "core"]:
		if out.has(extra):
			out[extra] = _typed_extra(out[extra])
	return out


static func _raw(hit_type: String, index: int) -> Dictionary:
	var arr: Array = _load().get(hit_type, [])
	if index < 0 or index >= arr.size():
		return {}
	return arr[index]


static func _typed(d: Dictionary) -> Dictionary:
	for k in d:
		if d[k] is Array and k in _COLOR_KEYS:
			d[k] = _color(d[k])
	for k in _VEC_KEYS:
		if d.has(k) and d[k] is Array:
			d[k] = _vec(d[k])
	if d.has("ramp") and d["ramp"] is Array:
		d["ramp"] = [_color(d["ramp"][0]), _color(d["ramp"][1])]
	return d


static func _typed_extra(d: Dictionary) -> Dictionary:
	if d.has("color") and d["color"] is Array:
		d["color"] = _color(d["color"])
	return d


static func _color(a: Array) -> Color:
	return Color(a[0], a[1], a[2], a[3] if a.size() > 3 else 1.0)


static func _vec(a: Array) -> Vector3:
	return Vector3(a[0], a[1], a[2])
