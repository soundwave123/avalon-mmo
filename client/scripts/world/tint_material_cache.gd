class_name TintMaterialCache
extends RefCounted

# T-758: memo-cache of tinted materials, keyed on (source material, tint, hair swap). Before this,
# entity_visuals._apply_body_tints duplicated a material PER SURFACE PER ENTITY, so two identical
# NPCs (same rig, same Era-2 tint) shared no material and the renderer could not batch them. Sharing
# ONE duplicate per distinct key restores batching. The key includes the EXACT tint, so two
# differently-tinted NPCs never collide onto one material; the hair atlas rides the key too, since a
# hair surface's result also depends on the swap texture. Static => alive for the session, bounded
# by NPC-type x tint x hair (materials are cheap Resources kept alive by the cache).
static var _cache: Dictionary = {}


# The tinted duplicate for (source, tint, slot, hair_swap) — a cache hit for anything seen before.
static func tinted(
	source: BaseMaterial3D, tint: Color, slot: String, hair_swap: Texture2D, hair_tex: String
) -> BaseMaterial3D:
	if source == null:
		return null
	var hair_key := hair_tex if (slot == "hair" and hair_swap != null) else ""
	# Source identity: path + resource_name + instance id. The id alone could be recycled after an
	# unload, but the path/name make a stale collision effectively impossible.
	var key := (
		"%s|%s|%d|%s|%s"
		% [
			source.resource_path,
			source.resource_name,
			source.get_instance_id(),
			hair_key,
			var_to_str(tint),
		]
	)
	var cached: Variant = _cache.get(key)
	if cached != null:
		return cached as BaseMaterial3D
	var dup := source.duplicate() as BaseMaterial3D
	if dup == null:
		return null
	dup.albedo_color = dup.albedo_color * tint
	if slot == "hair" and hair_swap != null:
		dup.albedo_texture = hair_swap
	_cache[key] = dup
	return dup


# Drop the cache. Production never calls this (the share is the whole point); tests use it so a
# leaked-RID exit check stays clean and material identities don't bleed across cases.
static func clear() -> void:
	_cache.clear()
