class_name AbilityAffordance

# T-731: "can I afford this right now?" for one ability row of the class kit, plus the visual
# encoding the action bar paints with. Carved out of action_bar.gd (file-size budget) and kept
# PURE + static so the rule is unit-testable without building a Control.
#
# Cost is read from the ABILITY DATA the server already ships in `class_kit` (kit_helper.gd:
# resource_cost + mana_cost) — never from a class name. A future resource (energy/combo) needs no
# change here: whatever the ability declares as its cost is checked against whatever the snapshot
# says the character's class resource currently is.
#
# Why the SUM of the two cost fields: the server's commit path (ability_executor) spends BOTH
# `resource_cost` and `mana_cost` out of the class-resource pool (CombatResources.mana IS the class
# resource when kind="mana"), and priest defs mix the two fields. Real defs only ever fill one, so
# the sum matches the server's gate ability-for-ability while staying honest if one ever fills both.
#
# This is an AFFORDANCE, not a gate: the client still sends the cast and the server still decides
# (it also applies talent cost modifiers the client's kit rows don't carry). Worst case the button
# reads dim for an ability a talent made cheap — never the reverse for the costs we ship.

extends RefCounted

# The insufficient-resource look: mostly drained of colour and clearly darker. Distinct BY
# CONSTRUCTION from the cooldown sweep, which is an opaque dark wipe drawn OVER the art.
const DESATURATION_INSUFFICIENT := 0.85
const DIM_INSUFFICIENT := 0.42
const DESATURATION_READY := 0.0
const DIM_READY := 1.0

# Desaturate + dim the slot art in place. COLOR arrives as the vertex colour (node modulate) times
# the texture sample, so one shader serves both the icon TextureRect and the fallback text glyph.
const SHADER_CODE := """
shader_type canvas_item;
uniform float desaturation : hint_range(0.0, 1.0) = 0.0;
uniform float dim : hint_range(0.0, 1.0) = 1.0;
void fragment() {
	float luminance = dot(COLOR.rgb, vec3(0.2126, 0.7152, 0.0722));
	COLOR.rgb = mix(COLOR.rgb, vec3(luminance), desaturation) * dim;
}
"""

static var _shader: Shader = null


# The class-resource spend this ability costs right now, from its own declared data.
static func cost_of(ability: Dictionary) -> int:
	return maxi(0, int(ability.get("resource_cost", 0))) + maxi(0, int(ability.get("mana_cost", 0)))


# Can the character pay for `ability` out of `current` class resource? A free ability is always
# affordable, and a character with no class resource at all (kind "none", or a kit shown before the
# first vitals snapshot lands) never gets dimmed — we only claim a shortfall we can actually see.
static func is_affordable(ability: Dictionary, resource_kind: String, current: int) -> bool:
	var cost := cost_of(ability)
	if cost <= 0:
		return true
	if resource_kind == "" or resource_kind == "none":
		return true
	return current >= cost


# One Shader resource shared by every slot material (params stay per-slot).
static func shader() -> Shader:
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SHADER_CODE
	return _shader


static func make_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = shader()
	apply(mat, true)
	return mat


# Paint one slot's art for the affordability half of its state. The cooldown sweep composes on TOP
# of this independently (T-731: cooldown wins visually, the resource dim stays underneath).
static func apply(mat: ShaderMaterial, affordable: bool) -> void:
	if mat == null:
		return
	mat.set_shader_parameter(
		"desaturation", DESATURATION_READY if affordable else DESATURATION_INSUFFICIENT
	)
	mat.set_shader_parameter("dim", DIM_READY if affordable else DIM_INSUFFICIENT)
