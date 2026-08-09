class_name AppearanceResolver
extends RefCounted

# T-302: pure NPC-appearance mapping (npc_wander.gd / critter_wander.gd style — no OS time, no
# globals, deterministic). Turns a per-NPC `appearance` block (role/sex/body_scale/seed) into a
# resolved look: which hero GLB to instance, a per-material-slot tint palette, and a scale. Same
# npc_id ALWAYS resolves to the same look; two NPCs with the same role still differ because every
# palette pick + jitter is keyed off the NPC's seed. `npc_world_layer.gd` consumes the result at
# spawn; this module renders nothing itself so it is unit-testable in isolation.
#
# SCOPE (2026-07-09, orchestrator split): this ships the data-driven SWAP MECHANISM + the variety
# reachable with the five EXISTING char_hero_*.glb rigs (villager peasant cloth / mage robe /
# warrior+trainer ranger armour) via rig-selection + albedo tint + scale. Brand-new body/face
# meshes (true female heads, child bodies, a smith's apron, a dedicated guard-tabard mesh with its
# own UV) are a visual-lane follow-up — see the ticket's deferral note. Guard livery is rendered as
# the realm palette (madder + steel/argent) tint here, NOT the tabard texture, because the tabard
# art (prop_hk_guard_tabard_col.png) is UV-authored for a tabard quad and would smear across the
# modular rig's packed body atlas.

const MODEL_DIR := "res://assets/models/"

# Role -> which existing rig gives the right silhouette.
#   villager = peasant tunic/cloth; mage = robe skirt; warrior/trainer = ranger armour (pauldron,
#   bracers, belt, hood); priest = plain cloth base we re-tint as clergy under-robe.
const ROLE_MESH := {
	"peasant": "char_hero_villager.glb",
	"child": "char_hero_villager.glb",
	"smith": "char_hero_villager.glb",
	"merchant": "char_hero_priest.glb",
	"noble": "char_hero_priest.glb",
	"priest": "char_hero_mage.glb",
	"mage": "char_hero_mage.glb",
	"guard": "char_hero_warrior.glb",
	"ranger": "char_hero_trainer.glb",
}

# Default full-body scale per role before per-NPC jitter (children read smaller; the rest ~adult).
const ROLE_SCALE := {
	"child": 0.75,
}

const SCALE_JITTER := 0.035  # +/- 3.5% deterministic per-NPC height variation (ticket ask)

# Per-role clothing palettes. Each present slot lists candidate base albedo MULTIPLIERS; the NPC's
# seed picks one, then each channel is nudged +/- so same-palette neighbours are not identical.
# Slots map from GLB material names via `material_slot()`: body = tunic/armour, robe = robe skirt,
# trim = belts/straps. Peasants read as undyed wool/linen; merchants/nobles as money-dyed cloth;
# clergy as off-white/indigo; guards as steel + madder livery.
const ROLE_PALETTE := {
	"peasant":
	{
		"body":
		[
			Color(0.58, 0.49, 0.37),  # wool brown
			Color(0.55, 0.55, 0.52),  # undyed grey
			Color(0.50, 0.52, 0.40),  # faded olive
			Color(0.66, 0.57, 0.44),  # tan linen
		],
	},
	"smith":
	{
		"body": [Color(0.34, 0.24, 0.16), Color(0.40, 0.28, 0.18)],  # leather browns (apron deferred)
	},
	"merchant":
	{
		"body":
		[
			Color(0.60, 0.20, 0.18),  # madder red
			Color(0.20, 0.29, 0.52),  # woad blue
			Color(0.18, 0.36, 0.24),  # dyed forest green
			Color(0.52, 0.34, 0.14),  # ochre
		],
	},
	"noble":
	{
		"body":
		[
			Color(0.36, 0.10, 0.18),  # burgundy
			Color(0.28, 0.15, 0.42),  # royal purple
			Color(0.12, 0.17, 0.36),  # midnight blue
		],
	},
	"priest":
	{
		"robe": [Color(0.86, 0.83, 0.75), Color(0.27, 0.29, 0.50)],  # off-white / indigo
		"body": [Color(0.62, 0.59, 0.53)],  # under-cloth
	},
	"mage":
	{
		"robe": [Color(0.24, 0.20, 0.46), Color(0.16, 0.32, 0.40), Color(0.30, 0.14, 0.30)],
		"body": [Color(0.40, 0.38, 0.44)],
	},
	"guard":
	{
		"body": [Color(0.56, 0.59, 0.64)],  # steel plate/mail
		"trim": [Color(0.58, 0.13, 0.15)],  # madder house livery (realm palette; tabard mesh deferred)
	},
	"ranger":
	{
		"body": [Color(0.30, 0.35, 0.23), Color(0.34, 0.31, 0.22)],  # greens / earth
		"trim": [Color(0.26, 0.18, 0.10)],  # leather straps
	},
	"child":
	{
		"body":
		[
			Color(0.72, 0.36, 0.30),  # bright simple smock
			Color(0.36, 0.54, 0.68),
			Color(0.72, 0.66, 0.34),
			Color(0.46, 0.62, 0.42),
		],
	},
}

# Individual head variation, picked by seed and applied as an albedo multiply on the shared skin +
# hair textures. Kept believable as MULTIPLIERS (they can only darken/shift, not brighten) — true
# recolouring from the extracted T_Hair_2 / skin variants is a visual-lane refinement.
const HAIR_PALETTE := [
	Color(0.18, 0.15, 0.13),  # near-black
	Color(0.45, 0.31, 0.19),  # brown
	Color(0.63, 0.52, 0.34),  # dark blonde
	Color(0.55, 0.30, 0.18),  # auburn
	Color(0.72, 0.72, 0.70),  # grey
]
const SKIN_PALETTE := [
	Color(1.00, 1.00, 1.00),  # as-authored
	Color(0.90, 0.82, 0.74),  # cool/fair
	Color(0.82, 0.68, 0.56),  # tan
	Color(0.68, 0.54, 0.42),  # dark
]

const CHANNEL_JITTER := 0.05  # per-channel nudge so same-palette-pick neighbours still differ

# T-127: per-username build (height) variation. Wider than the NPC crowd's SCALE_JITTER so two
# players in a starting-zone lineup read as different heights at a glance, but still within a
# believable human range (~+/-6% ≈ 1.73m-1.95m off the 1.84m UBC base).
const PLAYER_BUILD_JITTER := 0.06

# T-302b: real hair-COLOUR variety via a texture SWAP, not just a multiply. The embedded hair
# BaseColor is near-black, so the HAIR_PALETTE multipliers above can only ever darken it — a
# "grey" or "blonde" multiply still renders as dark hair. These are recoloured copies of the
# shared UBC hair atlas (gen'd from char_hero_villager_T_Hair_1_BaseColor via ImageMagick), so a
# genuinely light/silver/ginger head is reachable. "" = keep the embedded dark hair (weighted
# heavy so most folk stay dark-haired). Same UV atlas → valid on every rig's hair material.
const HAIR_TEX := [
	"",  # embedded dark brown/black (default)
	"",
	"",
	"res://assets/models/char_hair_grey.png",  # silver / elderly
	"res://assets/models/char_hair_blonde.png",
	"res://assets/models/char_hair_auburn.png",  # ginger
]


# Resolve a per-NPC appearance block into a concrete look. `appearance` may be empty ({}) — an
# unspecified NPC still gets a deterministic, individual peasant look from its id.
static func resolve(npc_id: String, appearance: Dictionary) -> Dictionary:
	var role := str(appearance.get("role", ""))
	if not ROLE_MESH.has(role):
		role = "peasant"
	var sex := str(appearance.get("sex", "m"))
	var seed_src := str(appearance.get("seed", ""))
	if seed_src == "":
		seed_src = npc_id
	var seed := hash_seed(seed_src)

	var mesh := MODEL_DIR + str(ROLE_MESH[role])
	var base_scale := float(appearance.get("body_scale", float(ROLE_SCALE.get(role, 1.0))))
	var scale := base_scale * (1.0 + _signed_unit(seed, 7) * SCALE_JITTER)

	var tints := _role_tints(role, seed)
	tints["hair"] = _pick(HAIR_PALETTE, seed, 11)
	tints["skin"] = _jitter(_pick(SKIN_PALETTE, seed, 13), seed, 17)
	var hair_tex := _hair_tex(role, seed)
	if hair_tex != "":
		# A recoloured hair atlas is already the final colour — don't also multiply it dark; let a
		# light jitter shade it so same-swap neighbours still differ a touch.
		tints["hair"] = _jitter(Color(0.92, 0.92, 0.92), seed, 31)
	return {
		"mesh": mesh,
		"role": role,
		"sex": sex,
		"scale": scale,
		"tints": tints,
		"hair_tex": hair_tex,
		"seed": seed,
	}


# T-127: deterministic PER-USERNAME player appearance, so two freshly made characters look distinct
# BEFORE any customization UI exists. Unlike resolve() (townsfolk), a PLAYER carries NO clothing
# tint — the T-224 re-scope makes the base body an armorless UBC rig whose class silhouette comes
# from EQUIPMENT, not a baked/dyed outfit — so this returns only the identity-bearing BODY traits:
# skin tint, hair colour (multiplier + optional recoloured-atlas swap), and a subtle build/height.
#
# The seed is a pure hash of the USERNAME (prefixed so it never collides with an npc_id of the same
# text), and the username is the SERVER's authenticated session identity (broadcast in the positions
# frame; the local client decodes it from its own JWT `sub`). So every viewer — the player themself
# and everyone who sees them — resolves the identical look with zero wire negotiation, and a client
# can NOT pick its own tint to spoof another identity: there is no client-supplied appearance field,
# the look is a deterministic function of an identity the client does not control. Precedent: WoW/UO
# seed a new character to a default face/skin/hair set rather than a blank slate; this is that,
# keyed to the account name so alts are visibly different on first login.
static func resolve_player(username: String) -> Dictionary:
	var seed := hash_seed("player:" + username)
	var tints := {
		"skin": _jitter(_pick(SKIN_PALETTE, seed, 13), seed, 17),
		"hair": _pick(HAIR_PALETTE, seed, 11),
	}
	var hair_tex := str(_pick(HAIR_TEX, seed, 19))
	if hair_tex != "":
		# A recoloured atlas is already the final colour — don't multiply it dark; a light jitter
		# just keeps same-swap neighbours from being pixel-identical (mirrors resolve()).
		tints["hair"] = _jitter(Color(0.92, 0.92, 0.92), seed, 31)
	var scale := 1.0 + _signed_unit(seed, 7) * PLAYER_BUILD_JITTER
	return {
		"tints": tints,
		"hair_tex": hair_tex,
		"scale": scale,
		"seed": seed,
		"username": username,
	}


# Pick a hair-colour texture swap by seed. Children never go silver/grey (salt-picked from the
# non-grey entries) so a kid doesn't read as elderly; everyone else draws the full set.
static func _hair_tex(role: String, seed: int) -> String:
	var choices: Array = HAIR_TEX
	if role == "child":
		choices = HAIR_TEX.filter(func(p: String): return not p.ends_with("grey.png"))
	return str(_pick(choices, seed, 19))


# Build the clothing-slot tints for a role: pick one base per slot by seed, then jitter it.
static func _role_tints(role: String, seed: int) -> Dictionary:
	var out: Dictionary = {}
	var palette: Dictionary = ROLE_PALETTE.get(role, {})
	var salt := 23
	for slot: String in palette.keys():
		var choices: Array = palette[slot]
		out[slot] = _jitter(_pick(choices, seed, salt), seed, salt + 100)
		salt += 7
	return out


# Map a GLB material name (its glTF `MI_*` name) to a semantic tint slot. Static + pure so the
# name->slot contract is unit-tested. Unknown materials fall to "body" (the clothing default).
static func material_slot(mat_name: String) -> String:
	var n := mat_name
	if n.begins_with("MI_Hair"):
		return "hair"
	if n == "MI_Eyes":
		return "eyes"
	# T-535: the female hero rig's body/head skin materials (Superhero_Female base + Regular_Female
	# exposed arms on the ranger outfit) map to the same "skin" slot, so the per-username skin tint
	# and every guard/NPC palette that names "skin" land on the female mesh exactly as on the male.
	if n == "MI_Regular_Male" or n == "MI_Superhero_Male":
		return "skin"
	if n == "MI_Regular_Female" or n == "MI_Superhero_Female":
		return "skin"
	if n == "MI_Robe":
		return "robe"
	if n.begins_with("MI_Ranger") and n.contains("."):
		return "trim"  # MI_Ranger.001 = belts/straps on the armour rigs
	return "body"


# A short, stable signature of a resolved look — mesh + quantized tints + scale bucket. Used by the
# distribution test to count DISTINCT appearances across the roster (ticket wants >= a threshold).
static func signature(resolved: Dictionary) -> String:
	var scale_bucket := int(round(float(resolved.get("scale", 1.0)) * 40.0))
	var hair_tex := str(resolved.get("hair_tex", ""))
	var hair_tag := hair_tex.get_file().get_basename() if hair_tex != "" else "dark"
	var parts: Array = [str(resolved.get("mesh", "")), "s%d" % scale_bucket, "h:%s" % hair_tag]
	var tints: Dictionary = resolved.get("tints", {})
	var keys: Array = tints.keys()
	keys.sort()
	for k: String in keys:
		var c: Color = tints[k]
		parts.append("%s=%d,%d,%d" % [k, int(c.r * 16), int(c.g * 16), int(c.b * 16)])
	return "|".join(parts)


# --- deterministic hashing (FNV-1a, 32-bit, platform-stable — not engine String.hash) ---


static func hash_seed(s: String) -> int:
	var h := 2166136261
	for i in s.length():
		h = (h ^ s.unicode_at(i)) & 0xFFFFFFFF
		h = (h * 16777619) & 0xFFFFFFFF
	return h


# A stable pseudo-random value in [0,1) from a seed + salt.
static func _unit(seed: int, salt: int) -> float:
	var h := hash_seed("%d:%d" % [seed, salt])
	return float(h % 100000) / 100000.0


# A stable value in [-1,1) from a seed + salt.
static func _signed_unit(seed: int, salt: int) -> float:
	return _unit(seed, salt) * 2.0 - 1.0


# Deterministically pick one element of `choices` by seed + salt.
static func _pick(choices: Array, seed: int, salt: int) -> Variant:
	if choices.is_empty():
		return Color.WHITE
	var idx := hash_seed("%d:%d" % [seed, salt]) % choices.size()
	return choices[idx]


# Nudge a colour's channels by +/- CHANNEL_JITTER, clamped to a sane albedo range.
static func _jitter(c: Color, seed: int, salt: int) -> Color:
	return Color(
		clampf(c.r + _signed_unit(seed, salt) * CHANNEL_JITTER, 0.03, 1.0),
		clampf(c.g + _signed_unit(seed, salt + 1) * CHANNEL_JITTER, 0.03, 1.0),
		clampf(c.b + _signed_unit(seed, salt + 2) * CHANNEL_JITTER, 0.03, 1.0)
	)
