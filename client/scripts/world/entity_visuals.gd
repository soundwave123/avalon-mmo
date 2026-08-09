class_name EntityVisuals
# T-076: procedural placeholder "models" — distinct silhouettes + palettes per entity kind.
# WoW/UO-inspired readability rule: you should know WHAT something is from across the field
# by shape + color alone (wolf = low gray quadruped, kobold = short miner with a pick,
# lasher = plant with a red blossom, dummy = wooden post, classes = tinted humanoids with a
# signature prop). All primitives, no external assets (final art is M7).

extends RefCounted

# Visual gear slots -> the UBC rig's bones. T-228 adds "head" (bone name is capitalized
# "Head" in the GLB, unlike the lowercase hand_l/hand_r — verified against the rig's node
# names). T-224 wires the armor cuts: chest->spine_02, legs->pelvis (bone names verified
# against char_hero_warrior.glb). "shoulders" (spine_03, a central upper-torso bone so a
# single pauldron-pair mesh sits symmetric) is FORWARD-wired: the server EQUIP_SLOTS today
# are only head/chest/legs/weapon/offhand (inventory_logic.gd), so the gear broadcast never
# carries "shoulders" and this entry stays dormant until a shoulders slot is added server-side.
const GEAR_BONES := {
	"weapon": "hand_r",
	"offhand": "hand_l",
	"head": "Head",
	"chest": "spine_02",
	"legs": "pelvis",
	"shoulders": "spine_03",
}

# T-224: non-held armor slots that route to the ARMOR_GLBS paperdoll meshes (vs. the held
# weapon/offhand builders).
const ARMOR_SLOTS := ["head", "chest", "legs", "shoulders"]

# T-224: item-FAMILY -> per-slot armor GLB set (owner ruling 2026-07-16 row M: the high-tier
# warrior PLATE set, generated via TRELLIS-2 at realistic-medieval tier — helm/cuirass/
# pauldrons/leg-harness, ~28-35k tris each, Draco-off). Keyed by family (id substring, see
# _armor_family) so a plate item lights the whole set while cloth/chain items keep their own
# look — the same "new items get visuals by family default" contract T-225 set for weapons.
const ARMOR_GLBS := {
	"plate":
	{
		"head": "res://assets/models/armor_warrior_plate_helm.glb",
		"chest": "res://assets/models/armor_warrior_plate_chest.glb",
		"legs": "res://assets/models/armor_warrior_plate_legs.glb",
		"shoulders": "res://assets/models/armor_warrior_plate_pauldrons.glb",
	},
	# T-224 (mage + priest sets): the cloth-caster armor-visual families, generated at the same
	# realistic-medieval TRELLIS-2 tier (tools/assetgen/gen_armor_caster_sets.sh). Keyed by their
	# OWN armor_type ("robe" for the mage set, "vestment" for the priest set) so the generic "cloth"
	# family — used by dungeon caster drops like itm_bonepriest_wraps — deliberately keeps its own
	# look (see _armor_family). No shoulders slot: cloth robes/vestments carry no pauldrons.
	"robe":
	{
		"head": "res://assets/models/armor_mage_robe_cowl.glb",
		"chest": "res://assets/models/armor_mage_robe_chest.glb",
		"legs": "res://assets/models/armor_mage_robe_legs.glb",
	},
	"vestment":
	{
		"head": "res://assets/models/armor_priest_vestment_cowl.glb",
		"chest": "res://assets/models/armor_priest_vestment_chest.glb",
		"legs": "res://assets/models/armor_priest_vestment_legs.glb",
	},
}

# T-224: per-slot fit of the raw TRELLIS piece (grounded at y=0, ~1m in its largest axis)
# onto the rig bone — uniform scale + local offset (metres, in the bone frame) + Y-rotation.
# Values started as first guesses from piece bounds; T-421/T-423/T-425 tuned them on-character.
const ARMOR_FIT := {
	"head": {"scale": 0.33, "offset": Vector3(0, 0.12, 0.02), "yaw_deg": 0.0},
	# T-423: cuirass dropped so it centers on the upper torso (spine_02..spine_03), not above the
	# clavicle — was 0.55/(0,0.02,0), which put the chest center at Y≈1.47 (above spine_03 1.31).
	"chest": {"scale": 0.55, "offset": Vector3(0, -0.22, 0.0), "yaw_deg": 0.0},
	# T-423: THE MIS-FIT FIX. The greaves are a ~1m mesh grounded at y=0 growing UP, so at the pelvis
	# bone (Y≈0.95) with only a -0.05 offset they rode to Y≈1.85 — legs "in the stomach". Drop them
	# a full pelvis-height (offset -0.91) and shrink to leg length (0.86) so they hang pelvis->ankle.
	"legs": {"scale": 0.86, "offset": Vector3(0, -0.91, 0.0), "yaw_deg": 0.0},
	# Warrior plate shoulders — T-423 re-seat onto the clavicle (spine_03 Y≈1.31); was 0.46/(0,0.08,0)
	# which floated the pauldron center to Y≈1.57, up on the neck.
	"shoulders": {"scale": 0.46, "offset": Vector3(0, -0.17, 0.0), "yaw_deg": 0.0},
	# T-224 (mage + priest sets): per-FAMILY slot fit overrides, keyed "<family>_<slot>".
	# _add_armor_glb prefers a family-qualified entry and falls back to the plain slot, so the plate
	# entries above are untouched. Robes/vestments drape longer + fuller than plate, so the chest
	# carries lower and the leg skirt hangs below the pelvis bone. T-421: TUNED on-character (mage +
	# priest hero rigs, EntityVisuals.apply_gear in a studio harness) — the tall grounded cowl mesh
	# needs a bigger scale + a low base offset to seat the hood ON the head (not perched above it);
	# the priest cowl's opening sits higher in its mesh, so vestment_head rides a touch higher.
	# T-425: RESEAT the caster cowls onto the skull. At 0.50/-0.09 the hood dome hovered above the
	# head, its front opening cutting across the skull crown (Head+HEAD_GEAR_LIFT ~1.82) so the bare
	# top of the head showed through (the collar draped low enough to fool the old Y-band check).
	# Scaled up + dropped so the front covering descends over the crown and the face-opening sits
	# below it: robe front opens at Y~1.70, AABB top ~1.88 (T-425 gear-fit SEATING check + in-world).
	"robe_head": {"scale": 0.60, "offset": Vector3(0, -0.32, -0.02), "yaw_deg": 0.0},
	# T-423: robe/vestment body dropped onto the torso (was 0.80/0.0 -> chest center Y≈1.58, above the
	# head); the long robe body now reads mid-thigh->shoulder. The leg SKIRT (was 1.05/-0.15 -> top
	# Y≈1.85, in the stomach — same class of bug as the plate greaves) now hangs from the waist to the
	# ankles/floor.
	"robe_chest": {"scale": 0.72, "offset": Vector3(0, -0.30, 0.0), "yaw_deg": 0.0},
	"robe_legs": {"scale": 0.94, "offset": Vector3(0, -0.94, 0.0), "yaw_deg": 0.0},
	# T-425: the priest cowl is a SHALLOW mantle-with-hood — raise it and its peak floats above the
	# head (gap); drop it and it collapses to a neck collar (bare head). This fit sits the mantle up
	# around the head so it caps the crown (AABB top ~1.84 >= crown) with the front opening just below
	# (Y~1.75) framing the face: covers the back/sides of the head, reads seated (no floating gap).
	"vestment_head": {"scale": 0.66, "offset": Vector3(0, -0.42, -0.02), "yaw_deg": 0.0},
	"vestment_chest": {"scale": 0.72, "offset": Vector3(0, -0.30, 0.0), "yaw_deg": 0.0},
	"vestment_legs": {"scale": 0.94, "offset": Vector3(0, -0.94, 0.0), "yaw_deg": 0.0},
}

# T-228: local +Y from the Head bone origin to skull-top height — the bone sits low in
# the neck, so head-family meshes need lift to land on top of the skull, not the chin.
const HEAD_GEAR_LIFT := 0.22

# T-109: item-id family -> starter weapon GLB (chunky WoW-starter-green set, authored to
# the WeaponSocket contract: origin at the grip, blade along the socket's +Y). Family
# inference by id substring keeps new items visual by default; the sword is the held-item
# fallback so unknown weapons still read as a blade.
const WEAPON_GLBS := {
	"sword": "res://assets/models/wpn_sword_starter.glb",
	"dagger": "res://assets/models/wpn_dagger_starter.glb",
	"axe": "res://assets/models/wpn_axe_starter.glb",
	"mace": "res://assets/models/wpn_mace_starter.glb",
	"staff": "res://assets/models/wpn_staff_starter.glb",
	"bow": "res://assets/models/wpn_bow_starter.glb",
	"shield": "res://assets/models/wpn_shield_starter.glb",
	# T-350: Era-2 (Ashmoor) firearms on the same WeaponSocket contract (grip at origin, barrel
	# forward = Godot -Z). The Gunsel carries "revolver", the Torpedo "tommy".
	"revolver": "res://assets/models/wpn_revolver.glb",
	"tommy": "res://assets/models/wpn_tommygun.glb",
	# T-351: Era-2 (Ashmoor) caster FOCUS items — the Occultist's sigil cane + the Medium's
	# reliquary, authored to the same WeaponSocket grip contract as the starter weapons.
	"cane": "res://assets/models/focus_sigil_cane.glb",
	"reliquary": "res://assets/models/focus_reliquary.glb",
}

# T-109: what an empty weapon hand shows per class — a client-side default so freshly
# made heroes read armed (warrior/sword, mage/staff, priest/mace). The server does not
# yet grant starter weapons at character creation; when a real weapon lands in the gear
# broadcast it replaces the default. Server-granted starter gear is T-319's job.
const CLASS_DEFAULT_WEAPONS := {
	"warrior": "default_sword",
	"mage": "default_staff",
	"priest": "default_mace",
	"player": "default_sword",
}

# T-351: the Era-2 (Ashmoor) presentation re-skin (era-direction §11.1 — same kit, era-costume).
# When `era` == 1, a caster carrying only the class DEFAULT weapon shows its era-2 focus instead:
# the mage's staff becomes the Occultist's sigil cane, the priest's mace the Medium's reliquary. A
# REAL equipped weapon (a focus item in the gear dict) always wins — this only re-skins the starter
# default. EraSkin flips `era` from the district; the whole existing world stays era 1.
const ERA_CASTER_FOCUS := {
	"mage": "itm_occult_sigil_cane",
	"priest": "itm_medium_reliquary",
}

const CLASS_COLORS := {
	"warrior": Color(0.72, 0.28, 0.22),  # rust red — front-line melee
	"mage": Color(0.25, 0.40, 0.88),  # arcane blue
	"priest": Color(0.92, 0.90, 0.78),  # ivory
}

# T-130: kind -> generated GLB model (text->image->3D pipeline). When a GLB is present it
# replaces the procedural silhouette below; the primitive builder stays as the graceful
# fallback for a missing/failed load. `yaw_deg` turns the mesh's baked-in facing to the
# game's forward (-Z); `scale` matches gameplay proportions. Tuned from pilot screenshots.
const GLB_MODELS := {
	"mob_wolf":
	{"path": "res://assets/models/mob_wolf.glb", "scale": 1.25, "yaw_deg": 0.0, "anim": "idle"},
	"mob_kobold_miner":
	{
		"path": "res://assets/models/mob_kobold_miner.glb",
		"scale": 1.3,
		"yaw_deg": 0.0,
		"anim": "idle"
	},
	"mob_bloodthorn_lasher":
	{
		"path": "res://assets/models/mob_bloodthorn_lasher.glb",
		"scale": 1.5,
		"yaw_deg": 0.0,
		"anim": "idle"
	},
	# T-551: the tutorial training figures. The straw sparring effigy (mob_training_effigy, the
	# q_tut_03 interrupt target) and the practice dummy (mob_dummy, the q_tut_01 kill target) both
	# render the lashed-strawman GLB instead of the red-cube / bare-post placeholder they fell back
	# to. Static props (no AnimationPlayer) — combat drives the procedural CombatMotion lunge/topple,
	# same as the other placeholder creatures. yaw_deg 0: the painted chest target faces the approach.
	"mob_training_effigy":
	{
		"path": "res://assets/models/prop_training_effigy.glb",
		"scale": 1.0,
		"yaw_deg": 0.0,
		"anim": ""
	},
	"mob_dummy":
	{
		"path": "res://assets/models/prop_training_effigy.glb",
		"scale": 1.0,
		"yaw_deg": 0.0,
		"anim": ""
	},
	# T-341: The Hollowed Crypt undead family (M6). These are the BASE silhouettes the T-332
	# crypt bosses reuse via render_kind, so they key on the mob_id directly. yaw_deg=0 +
	# rest-pose zero keeps them on the T-307 clipless-combat path (procedural lunge/recoil/topple).
	"mob_skeletal_warrior":
	{
		"path": "res://assets/models/mob_skeletal_warrior.glb",
		"scale": 1.15,
		"yaw_deg": 0.0,
		"anim": "idle"
	},
	"mob_crypt_ghoul":
	{
		"path": "res://assets/models/mob_crypt_ghoul.glb",
		"scale": 1.2,
		"yaw_deg": 0.0,
		"anim": "idle"
	},
	# The shade leans on a spectral material (translucent + cold emissive) rather than dense
	# geometry, so it reads as a drifting wraith distinct from the solid bone/flesh mobs.
	"mob_restless_shade":
	{
		"path": "res://assets/models/mob_restless_shade.glb",
		"scale": 1.25,
		"yaw_deg": 0.0,
		"anim": "idle",
		"spectral": true
	},
	# T-349: The Syndicate street tier (Ashmoor, Era-2). HUMANS on the existing T-118 hero rigs —
	# NO new mesh/rig (ashmoor-direction.md S4). Each reuses a hero GLB and applies a per-slot Era-2
	# `tints` palette (multiply on the clothing slots only; skin/hair/eyes left natural) so the mob
	# reads as a coated gangster / uniformed constable / occult warden distinct from the medieval
	# villager NPCs. The rigs carry the full T-118 clip set, so these fight on existing melee/cast
	# clips (no clipless combat_motion fallback). Keyed by mob_id (render_kind is empty in the JSON).
	"mob_syndicate_legbreaker":
	{
		"path": "res://assets/models/char_hero_warrior.glb",
		"scale": 1.0,
		"yaw_deg": 180.0,
		"anim": "Idle_Loop",
		"tints": {"body": Color(0.30, 0.30, 0.33), "trim": Color(0.22, 0.22, 0.24)}
	},
	"mob_constable_take":
	{
		"path": "res://assets/models/char_hero_warrior.glb",
		"scale": 1.0,
		"yaw_deg": 180.0,
		"anim": "Idle_Loop",
		"tints": {"body": Color(0.22, 0.26, 0.42), "trim": Color(0.16, 0.18, 0.30)}
	},
	"mob_seance_warden":
	{
		"path": "res://assets/models/char_hero_mage.glb",
		"scale": 1.0,
		"yaw_deg": 180.0,
		"anim": "Idle_Loop",
		"tints":
		{
			"robe": Color(0.26, 0.24, 0.34),
			"body": Color(0.24, 0.22, 0.30),
			"trim": Color(0.35, 0.60, 0.40)
		}
	},
	# T-350: the two gun mobs (T-349 stubs, live now). Same hero rig + Era-2 tint, but ARMED — the
	# "weapon" key routes make_visual through apply_gear so the revolver / tommy GLB rides hand_r.
	"mob_syndicate_gunsel":
	{
		"path": "res://assets/models/char_hero_warrior.glb",
		"scale": 1.0,
		"yaw_deg": 180.0,
		"anim": "Idle_Loop",
		"weapon": "default_revolver",
		"tints": {"body": Color(0.34, 0.30, 0.26), "trim": Color(0.20, 0.18, 0.16)}
	},
	"mob_syndicate_torpedo":
	{
		"path": "res://assets/models/char_hero_warrior.glb",
		"scale": 1.05,
		"yaw_deg": 180.0,
		"anim": "Idle_Loop",
		"weapon": "default_tommy",
		"tints": {"body": Color(0.24, 0.24, 0.28), "trim": Color(0.16, 0.16, 0.18)}
	},
	# T-166 (owner mandate): heroic-proportion Universal Base Characters (Quaternius, CC0) —
	# realistic ~1.84m rigged humans with UAL clips. KayKit chibi rigs are retired from
	# humanoid duty (they read as "Lego/Roblox" next to the WoW reference).
	"warrior":
	{
		"path": "res://assets/models/char_hero_warrior.glb",
		"scale": 1.0,
		"yaw_deg": 180.0,
		"anim": "Idle_Loop"
	},
	"mage":
	{
		"path": "res://assets/models/char_hero_mage.glb",
		"scale": 1.0,
		"yaw_deg": 180.0,
		"anim": "Idle_Loop"
	},
	"priest":
	{
		"path": "res://assets/models/char_hero_priest.glb",
		"scale": 1.0,
		"yaw_deg": 180.0,
		"anim": "Idle_Loop"
	},
	"player":
	{
		"path": "res://assets/models/char_hero_warrior.glb",
		"scale": 1.0,
		"yaw_deg": 180.0,
		"anim": "Idle_Loop"
	},
}

# T-118: the animation STATE -> clip-name preference map. A state resolves to the first clip
# the model actually carries, so it works across our different rig lineages (auto-rigged
# creatures use lowercase "idle"/"walk"; the UBC/UAL characters use "Idle_Loop"/"Walk_Loop"/
# "Jog_Fwd_Loop"/"Sword_Attack"/... — T-118 baked the full eight onto every hero). Extend a
# list to teach a new state a new clip synonym; the resolver is otherwise data-driven.
const STATE_CLIPS := {
	# NOTE: Godot's GLB importer STRIPS the "_Loop" suffix from clip names (and marks them
	# looping) — a rig baked with "Walk_Loop" imports as "Walk". Every *_Loop synonym below
	# needs its trimmed twin listed too, or the state silently resolves to nothing and the
	# character slides in its idle pose (owner bug 2026-07-12: "floats like a possessed
	# person" — the 4.7 reimport renamed the cached clips out from under the old list).
	"idle": ["idle", "Idle_Loop", "Idle", "Unarmed_Idle"],
	"walk": ["walk", "Walk_Loop", "Walk", "Walk_Fwd_Loop", "Walk_Fwd", "Walking_A"],
	"run":
	["run", "Jog_Fwd_Loop", "Jog_Fwd", "Sprint_Loop", "Sprint", "Running_A", "Walk_Loop", "Walk"],
	"jump": ["jump", "Jump_Loop", "Jump", "Jump_Start"],
	"attack": ["attack", "Sword_Attack", "Punch_Cross", "1H_Melee_Attack_Chop"],
	"cast": ["cast", "Spell_Simple_Shoot", "Spellcast_Raise"],
	"hit": ["hit", "Hit_Chest", "Hit_Head", "Hit_A"],
	"death": ["death", "Death01", "Death_A"],
	# T-728: the seated rider pose. UAL ships no ride/saddle clip, so T-728 baked its two honest
	# stand-ins onto the player rigs — Driving (upright, hands at rein height) ahead of Sitting_Idle
	# (chair sit); QA A/Bs by swapping them. Still no run/jog synonym: no run clip under a rider.
	# Both import _Loop-stripped, verified on all six player rigs (they resolve "Driving").
	"mounted": ["Ride_Seated", "Driving", "Sitting_Idle", "idle", "Idle_Loop", "Idle"],
	# T-397: social emotes retargeted from the UAL/Quaternius CC0 library onto the hero rigs.
	# The catalog's `clip` field (server/world/data/social/emotes.json) names one of these state
	# keys; only these three of the 12 emotes have an honest CC0 source clip. As one-shots (not in
	# LOOPING_STATES) they play once and hold the last pose. Dance imports as "Dance" (_Loop
	# stripped); Fixing_Kneeling/Interact carry no _Loop suffix so keep their names.
	"dance": ["Dance", "Dance_Loop"],
	"kneel": ["Fixing_Kneeling"],
	"point": ["Interact"],
}

# States that loop while active; everything else is a one-shot (plays once, holds last pose)
# so an attack/cast/hit/jump/death doesn't stutter-repeat. T-123/T-307 own returning to idle.
# T-573: "mounted" loops — the seated pose holds for the whole ride.
const LOOPING_STATES := ["idle", "walk", "run", "mounted"]

# T-341: the restless shade's spectral material tint/opacity (applied by _apply_spectral).
const _SHADE_TINT := Color(0.55, 0.72, 0.85)  # cold spectral blue-green
const _SHADE_ALPHA := 0.45

# T-697 fix 8: threaded GLB warm-up (RemoteEntitiesLayer requests it at login; see the module).
const VisualPreload = preload("res://scripts/world/visual_preload.gd")

# T-351: the Era-2 (Ashmoor) presentation re-skin flag (see ERA_CASTER_FOCUS). 0 = era 1 (default
# world), 1 = Ashmoor. main.gd/EraSkin flips it on the district crossing; apply_gear reads it.
static var era := 0


# The one entry point: a composed visual for an entity kind. Kinds: mob ids ("mob_wolf"...),
# class names ("warrior"...), "player" (classless fallback), anything else = generic mob.
# T-332: render_scale multiplies the GLB's own scale (e.g. the Hollow King boss towers at 1.6×). It
# is applied to the INNER model, never the root — the root is what CombatMotion (T-307) transforms
# each frame, so scaling it would be stomped. Defaults 1.0 (every normal entity is unchanged).
static func make_visual(kind: String, render_scale: float = 1.0, gender: String = "") -> Node3D:
	var root := Node3D.new()
	root.name = "Visual_%s" % kind
	root.set_meta("visual_kind", kind)  # T-109: apply_gear derives the class default weapon
	if _try_glb_model(root, kind, render_scale, gender):
		if CLASS_DEFAULT_WEAPONS.has(kind):
			apply_gear(root, {})  # T-109: armed at spawn, before any gear broadcast
		elif GLB_MODELS.get(kind, {}).has("weapon"):
			# T-350: a gun mob spawns armed with its firearm (revolver / tommy) in hand_r.
			apply_gear(root, {"weapon": str(GLB_MODELS[kind]["weapon"])})
		return root
	match kind:
		"mob_wolf":
			_wolf(root)
		"mob_kobold_miner":
			_kobold(root)
		"mob_bloodthorn_lasher":
			_lasher(root)
		"mob_dummy":
			_training_dummy(root)
		"warrior", "mage", "priest":
			_class_figure(root, kind)
		"player":
			_capsule(root, Vector3(0, 0.9, 0), 0.4, 1.8, Color(0.90, 0.50, 0.20))
		_:
			_box(root, Vector3(0, 0.8, 0), Vector3(1.0, 1.6, 1.0), Color(0.65, 0.25, 0.25))
	return root


# ---- generated GLB models (T-130) ----


# Instantiate the registered GLB for `kind` under `root`, applying its scale + facing offset.
# Returns false (leaving root untouched) when no GLB is registered or the load fails, so the
# caller falls through to the procedural silhouette.
static func _try_glb_model(
	root: Node3D, kind: String, render_scale: float = 1.0, gender: String = ""
) -> bool:
	var spec: Dictionary = GLB_MODELS.get(kind, {})
	if spec.is_empty():
		return false
	var path: String = _gendered_path(str(spec.get("path", "")), gender)
	if not ResourceLoader.exists(path):
		return false
	var packed := VisualPreload.load_scene(path)  # T-697 fix 8: threaded-warm-up aware
	if packed == null:
		return false
	var model := packed.instantiate() as Node3D
	if model == null:
		return false
	var s: float = float(spec.get("scale", 1.0)) * maxf(0.1, render_scale)  # T-332: boss render_scale
	model.scale = Vector3(s, s, s)
	model.rotation.y = deg_to_rad(float(spec.get("yaw_deg", 0.0)))
	if spec.has("gear"):
		trim_hand_gear(model, spec.get("gear"))
	if spec.get("spectral", false):
		_apply_spectral(model)
	if spec.has("tints"):
		_apply_body_tints(model, spec.get("tints"))
	_play_looping(model, spec.get("anim", ""))
	root.add_child(model)
	return true


# T-535: "female" swaps a hero GLB for its char_hero_<class>_female.glb sibling (same rig + clips +
# material slots — gen_hero_females.sh). Any other value, or no female file, keeps the default mesh.
static func _gendered_path(path: String, gender: String) -> String:
	if gender != "female" or not path.ends_with(".glb"):
		return path
	var female := path.substr(0, path.length() - 4) + "_female.glb"
	return female if ResourceLoader.exists(female) else path


# T-341: turn a solid GLB into a spectral wraith — every surface goes translucent with a cold
# emissive glow, so the restless shade reads as a drifting ghost distinct from the opaque
# bone/flesh mobs. Overrides the baked material per surface (a next_pass would still show the
# opaque bake underneath), keeping the mesh's own albedo tint via emission color.
static func _apply_spectral(model: Node) -> void:
	for mi: MeshInstance3D in _all_mesh_instances(model):
		var mesh: Mesh = mi.mesh
		var surf_count: int = mesh.get_surface_count() if mesh != null else 0
		for s in range(surf_count):
			var mat := StandardMaterial3D.new()
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.albedo_color = Color(_SHADE_TINT, _SHADE_ALPHA)
			mat.emission_enabled = true
			mat.emission = _SHADE_TINT
			mat.emission_energy_multiplier = 1.4
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			mat.cull_mode = BaseMaterial3D.CULL_DISABLED  # see the far side through the near
			mi.set_surface_override_material(s, mat)


# T-349: recolour a hero rig into an Era-2 Syndicate silhouette. Mirrors the T-302
# npc_world_layer._apply_tints idiom exactly — duplicate each surface's active material and MULTIPLY
# its albedo by the per-slot tint, set as a surface override (the shared source material is never
# mutated; skeletal animation is untouched). The material name -> semantic slot map is the shared
# AppearanceResolver contract, so only the named clothing slots (body/robe/trim) darken while
# skin/hair/eyes stay human. Unlike _apply_spectral this KEEPS the baked albedo texture (a multiply,
# not a replace), so the rig still reads as a person — just in a dark coat / navy / occult robe.
static func _apply_body_tints(model: Node, tints: Dictionary, hair_tex: String = "") -> void:
	if tints.is_empty():
		return
	# T-127: an optional recoloured hair atlas — a multiply alone can only darken the near-black
	# embedded hair, so a light/silver/ginger head needs a real texture swap (mirrors npc_world_layer).
	var hair_swap: Texture2D = null
	if hair_tex != "" and ResourceLoader.exists(hair_tex):
		hair_swap = load(hair_tex) as Texture2D
	for mi: MeshInstance3D in _all_mesh_instances(model):
		var mesh: Mesh = mi.mesh
		if mesh == null:
			continue
		for s in range(mesh.get_surface_count()):
			var mat := mi.get_active_material(s)
			if mat == null:
				continue
			var slot := AppearanceResolver.material_slot(str(mat.resource_name))
			if not tints.has(slot):
				continue
			var dup := mat.duplicate() as BaseMaterial3D
			if dup == null:
				continue
			dup.albedo_color = dup.albedo_color * (tints[slot] as Color)
			if slot == "hair" and hair_swap != null:
				dup.albedo_texture = hair_swap
			mi.set_surface_override_material(s, dup)


# T-127: apply a per-username player look (skin + hair tint, optional recoloured hair atlas) onto a
# character visual root. Duplicates each affected surface's material and sets it as an override, so
# the shared source material is never mutated and skeletal animation/gear are untouched. Body scale
# (build/height) is the CALLER's job — it rides the visual node itself, not a material.
static func apply_appearance(root: Node3D, tints: Dictionary, hair_tex: String = "") -> void:
	_apply_body_tints(root, tints, hair_tex)


static func _all_mesh_instances(node: Node) -> Array:
	var out: Array = []
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		out.append_array(_all_mesh_instances(child))
	return out


# KayKit rigs ship with EVERY weapon variant attached and visible (both crossbows, knives,
# all shields...) — in-game that reads as a floating pale capsule in each hand (the blind
# judge's "cyan capsule"). Keep only the named gear; hide the rest of both hand slots.
static func trim_hand_gear(model: Node, keep: Array = []) -> void:
	for slot_name in ["handslot_l", "handslot_r"]:
		var slot := model.find_child(slot_name, true, false)
		if slot == null:
			continue
		for child in slot.get_children():
			child.visible = str(child.name) in keep
	# Capes: the KayKit cape sheet doesn't follow the idle animation on our stripped rigs and
	# juts out as a rigid pale slab ("floating beam" tell). Hide unless explicitly kept.
	for cape_name in ["Rogue_Cape", "Knight_Cape", "Mage_Cape", "Barbarian_Cape"]:
		var cape := model.find_child(cape_name, true, false)
		if cape != null and cape is Node3D:
			(cape as Node3D).visible = cape_name in keep


# T-124/T-118: switch a visual to an animation STATE by movement/combat. Resolves the state to
# whichever clip the model actually has and crossfades to it. Unknown states resolve to idle.
static func play_state(root: Node, state: String) -> void:
	var ap := root.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if ap == null:
		return
	var candidates: Array = STATE_CLIPS.get(state, STATE_CLIPS["idle"])
	var looping := state in LOOPING_STATES
	for clip: String in candidates:
		if ap.has_animation(clip):
			if ap.current_animation != clip:
				var anim := ap.get_animation(clip)
				if anim != null:
					anim.loop_mode = Animation.LOOP_LINEAR if looping else Animation.LOOP_NONE
				ap.play(clip, 0.2)  # crossfade
			return


# T-307: does this entity's rig actually carry a clip for `state`? Combat callers use this to
# decide clip-vs-procedural: a hero resolves "attack"/"death" to a baked clip (play_state drives
# it), but the placeholder creatures carry only idle/walk, so their action states resolve to
# nothing here (false) and the caller drives a procedural CombatMotion stand-in instead. A rig with
# no AnimationPlayer at all (the generic-box mob) is also false — nothing to play, go procedural.
static func has_state_clip(root: Node, state: String) -> bool:
	var ap := root.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if ap == null:
		return false
	for clip: String in STATE_CLIPS.get(state, []):
		if ap.has_animation(clip):
			return true
	return false


# T-117/T-123: if the GLB carries an AnimationPlayer (auto-rigged creatures), loop-play a clip
# so the creature is alive at rest. Prefers the ticket's named clip, else "idle", else the first.
# Server-driven idle/walk switching lands in T-124; for now a single looping clip.
static func _play_looping(model: Node, preferred: String) -> void:
	var ap := model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if ap == null:
		return
	var clip := ""
	for candidate in [preferred, "idle", "Idle"]:
		if candidate != "" and ap.has_animation(candidate):
			clip = candidate
			break
	if clip == "":
		var list := ap.get_animation_list()
		if list.size() == 0:
			return
		clip = list[0]
	var anim := ap.get_animation(clip)
	if anim != null:
		anim.loop_mode = Animation.LOOP_LINEAR
	ap.play(clip)


# ---- creatures ----


static func _wolf(root: Node3D) -> void:
	var fur := Color(0.52, 0.52, 0.56)
	var dark := Color(0.35, 0.35, 0.40)
	_box(root, Vector3(0, 0.55, 0), Vector3(0.55, 0.5, 1.35), fur)  # torso (long, low)
	_box(root, Vector3(0, 0.75, -0.85), Vector3(0.4, 0.35, 0.45), fur)  # head
	_box(root, Vector3(0, 0.68, -1.15), Vector3(0.22, 0.18, 0.3), dark)  # snout
	_box(root, Vector3(-0.12, 1.0, -0.85), Vector3(0.08, 0.16, 0.08), dark)  # ears
	_box(root, Vector3(0.12, 1.0, -0.85), Vector3(0.08, 0.16, 0.08), dark)
	for leg_x in [-0.18, 0.18]:
		for leg_z in [-0.45, 0.45]:
			_box(root, Vector3(leg_x, 0.15, leg_z), Vector3(0.14, 0.3, 0.14), dark)
	var tail := _box(root, Vector3(0, 0.7, 0.85), Vector3(0.12, 0.12, 0.5), dark)
	tail.rotation.x = deg_to_rad(-25.0)


static func _kobold(root: Node3D) -> void:
	var hide := Color(0.62, 0.48, 0.30)  # tan hide
	var cloth := Color(0.45, 0.36, 0.22)
	_capsule(root, Vector3(0, 0.55, 0), 0.28, 1.1, hide)  # short body
	_sphere(root, Vector3(0, 1.25, 0), 0.22, hide)  # oversized head
	_box(root, Vector3(0, 1.42, 0), Vector3(0.34, 0.1, 0.34), cloth)  # miner's cap brim
	var pick := _box(root, Vector3(0.4, 0.9, 0), Vector3(0.06, 0.9, 0.06), Color(0.4, 0.3, 0.2))
	pick.rotation.z = deg_to_rad(-30.0)  # pick handle over the shoulder
	_box(root, Vector3(0.62, 1.28, 0), Vector3(0.3, 0.08, 0.08), Color(0.5, 0.5, 0.55))  # pick head


static func _lasher(root: Node3D) -> void:
	var stem := Color(0.20, 0.45, 0.22)
	var leaf := Color(0.28, 0.60, 0.25)
	_cylinder(root, Vector3(0, 0.6, 0), 0.16, 1.2, stem)  # trunk
	_sphere(root, Vector3(0, 1.35, 0), 0.3, Color(0.75, 0.15, 0.25))  # bloodthorn blossom
	for angle in [0.0, 120.0, 240.0]:
		var l := _box(root, Vector3(0, 0.55, 0), Vector3(0.1, 0.05, 0.8), leaf)
		l.rotation.y = deg_to_rad(angle)
		l.rotation.x = deg_to_rad(-20.0)
		l.position += Vector3(cos(deg_to_rad(angle)), 0, sin(deg_to_rad(angle))) * 0.35


static func _training_dummy(root: Node3D) -> void:
	var wood := Color(0.55, 0.42, 0.26)
	var straw := Color(0.80, 0.70, 0.40)
	_cylinder(root, Vector3(0, 0.08, 0), 0.5, 0.16, wood)  # base
	_cylinder(root, Vector3(0, 0.9, 0), 0.14, 1.6, wood)  # post
	_box(root, Vector3(0, 1.25, 0), Vector3(1.1, 0.12, 0.12), wood)  # crossbar arms
	_sphere(root, Vector3(0, 1.85, 0), 0.26, straw)  # straw head
	_box(root, Vector3(0, 1.0, 0.1), Vector3(0.5, 0.7, 0.15), straw)  # strapped torso pad


# ---- humanoids (players by class) ----


static func _class_figure(root: Node3D, cls: String) -> void:
	var color: Color = CLASS_COLORS.get(cls, Color(0.90, 0.50, 0.20))
	_capsule(root, Vector3(0, 0.9, 0), 0.4, 1.8, color)
	match cls:
		"warrior":  # steel pauldrons — bulk silhouette
			_box(root, Vector3(-0.45, 1.45, 0), Vector3(0.28, 0.18, 0.4), Color(0.6, 0.6, 0.65))
			_box(root, Vector3(0.45, 1.45, 0), Vector3(0.28, 0.18, 0.4), Color(0.6, 0.6, 0.65))
		"mage":  # pointed hat — the classic cone
			_cone(root, Vector3(0, 2.05, 0), 0.35, 0.6, Color(0.15, 0.22, 0.55))
		"priest":  # gold halo band
			_cylinder(root, Vector3(0, 2.0, 0), 0.3, 0.06, Color(0.95, 0.82, 0.35))


# ---- primitive helpers ----


static func _mat(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	return mat


static func _add(root: Node3D, mesh: Mesh, pos: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = _mat(color)
	root.add_child(mi)
	return mi


static func _box(root: Node3D, pos: Vector3, size: Vector3, color: Color) -> MeshInstance3D:
	var box := BoxMesh.new()
	box.size = size
	return _add(root, box, pos, color)


static func _capsule(
	root: Node3D, pos: Vector3, radius: float, height: float, color: Color
) -> MeshInstance3D:
	var cap := CapsuleMesh.new()
	cap.radius = radius
	cap.height = height
	return _add(root, cap, pos, color)


static func _sphere(root: Node3D, pos: Vector3, radius: float, color: Color) -> MeshInstance3D:
	var sph := SphereMesh.new()
	sph.radius = radius
	sph.height = radius * 2.0
	return _add(root, sph, pos, color)


static func _cylinder(
	root: Node3D, pos: Vector3, radius: float, height: float, color: Color
) -> MeshInstance3D:
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = height
	return _add(root, cyl, pos, color)


static func _cone(
	root: Node3D, pos: Vector3, radius: float, height: float, color: Color
) -> MeshInstance3D:
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = radius
	cone.height = height
	return _add(root, cone, pos, color)


# ---- T-225: equipment visuals (paper-doll phase 1: weapon + offhand) ----


# Apply the networked gear dict ({slot: item_id}) to a character visual: bone-attached
# meshes everyone sees. Idempotent — clears previous gear attachments first. T-109: held
# slots (weapon/offhand) go through the shared WeaponSocket contract; an empty weapon
# hand falls back to the class's default starter weapon (see CLASS_DEFAULT_WEAPONS).
static func apply_gear(root: Node3D, gear: Dictionary) -> void:
	var skel := root.find_child("Skeleton3D", true, false) as Skeleton3D
	if skel == null:
		return
	for child in skel.get_children():
		if str(child.name).begins_with("GearSlot_"):
			# Rename before queue_free: the doomed node lives until end-of-frame, and a
			# same-frame re-apply would otherwise force an auto-renamed (unsweepable)
			# replacement socket (T-109).
			child.name = "_freeing_%s" % child.name
			child.queue_free()
	var effective := gear.duplicate()
	var kind := str(root.get_meta("visual_kind", ""))
	if str(effective.get("weapon", "")) == "":
		# T-351: in Ashmoor a bare caster shows its era-2 focus; else the era-1 class default.
		if era == 1 and ERA_CASTER_FOCUS.has(kind):
			effective["weapon"] = ERA_CASTER_FOCUS[kind]
		elif CLASS_DEFAULT_WEAPONS.has(kind):
			effective["weapon"] = CLASS_DEFAULT_WEAPONS[kind]
	for slot: String in GEAR_BONES:
		var raw := str(effective.get(slot, ""))
		if raw == "":
			continue
		# T-428 extends T-420's server-authored token to
		# "<display_item>|<armor_type>|<dye_color>|<dye_mask>". The client only renders it; it never
		# chooses a display item or color. Empty trailing fields preserve the ordinary gear path.
		var parts := raw.split("|", true, 3)
		var item_id := parts[0]
		var armor_type := parts[1] if parts.size() > 1 else ""
		var dye_color := parts[2] if parts.size() > 2 else ""
		var dye_mask := parts[3] if parts.size() > 3 else ""
		var bone: String = GEAR_BONES[slot]
		var gear_node := _gear_mesh(item_id, slot, armor_type)
		_apply_wardrobe_dye(gear_node, dye_color, dye_mask)
		if slot in ["weapon", "offhand"]:
			var sock := WeaponSocket.attach(skel, slot, bone)
			if sock != null:
				sock.equip(gear_node)
			continue
		if skel.find_bone(bone) < 0:
			continue
		var att := BoneAttachment3D.new()
		att.name = "GearSlot_%s" % slot
		att.bone_name = bone
		att.add_child(gear_node)
		skel.add_child(att)


# Duplicate active materials before tinting so one character's dye can never recolor the imported
# resource or another player's instance. An authored `all` mask covers every surface; named masks
# use the same semantic material-slot resolver as character appearance tints.
static func _apply_wardrobe_dye(gear: Node3D, dye_color: String, dye_mask: String) -> void:
	if dye_color == "" or not dye_color.is_valid_html_color():
		return
	gear.set_meta("wardrobe_dye", dye_color)
	gear.set_meta("wardrobe_dye_mask", dye_mask)
	var tint := Color.html(dye_color)
	for mi: MeshInstance3D in _all_mesh_instances(gear):
		var mesh := mi.mesh
		if mesh == null:
			continue
		for surface in range(mesh.get_surface_count()):
			var source := mi.get_active_material(surface)
			if not source is BaseMaterial3D:
				continue
			var material_name := str(source.resource_name)
			if dye_mask != "all" and AppearanceResolver.material_slot(material_name) != dye_mask:
				continue
			var instance := source.duplicate() as BaseMaterial3D
			instance.albedo_color = instance.albedo_color * tint
			mi.set_surface_override_material(surface, instance)


# Item family -> visual mesh. Family inference by id substring keeps new items visual by
# default (a sword-family item reads as a sword without per-item art debt). `slot` routes
# head-slot items to the head-family builder instead of the held-weapon one.
static func _gear_mesh(item_id: String, slot: String = "weapon", armor_type: String = "") -> Node3D:
	if slot in ARMOR_SLOTS:
		return _armor_gear_mesh(item_id, slot, armor_type)
	var holder := Node3D.new()
	holder.name = "Gear_%s" % item_id
	# T-109: real starter weapon GLBs, authored on the WeaponSocket contract so they parent
	# at identity. The primitive builders below stay as the graceful load-failure fallback.
	if _add_weapon_glb(holder, item_id):
		return holder
	# The UBC hand bone: +Y runs along the fingers; blades point up out of the fist.
	if "staff" in item_id:
		_gear_part(
			holder,
			CylinderMesh.new(),
			Vector3(0.025, 1.5, 0.025),
			Vector3(0, 0.45, 0),
			Color(0.45, 0.32, 0.2),
			0.85
		)
		_gear_part(
			holder,
			SphereMesh.new(),
			Vector3(0.09, 0.09, 0.09),
			Vector3(0, 1.24, 0),
			Color(0.35, 0.55, 0.95),
			0.3
		)
	elif "shield" in item_id:
		_gear_part(
			holder,
			BoxMesh.new(),
			Vector3(0.45, 0.6, 0.06),
			Vector3(0, 0.1, 0.1),
			Color(0.4, 0.3, 0.22),
			0.8
		)
	else:  # sword family (itm_iron_sword, itm_starter_weapon, future blades)
		_gear_part(
			holder,
			BoxMesh.new(),
			Vector3(0.05, 0.72, 0.015),
			Vector3(0, 0.5, 0),
			Color(0.75, 0.77, 0.8),
			0.35
		)
		_gear_part(
			holder,
			BoxMesh.new(),
			Vector3(0.16, 0.03, 0.03),
			Vector3(0, 0.13, 0),
			Color(0.35, 0.3, 0.25),
			0.7
		)
		_gear_part(
			holder,
			BoxMesh.new(),
			Vector3(0.035, 0.12, 0.035),
			Vector3(0, 0.05, 0),
			Color(0.2, 0.15, 0.1),
			0.8
		)
	return holder


# T-109: resolve an item id to its weapon-family GLB and instance it under `holder`.
# Returns false on any load failure so the caller keeps the primitive fallback.
static func _add_weapon_glb(holder: Node3D, item_id: String) -> bool:
	var path: String = WEAPON_GLBS["sword"]
	for family: String in WEAPON_GLBS:
		if family in item_id:
			path = WEAPON_GLBS[family]
			break
	if not ResourceLoader.exists(path):
		return false
	var packed := load(path) as PackedScene
	if packed == null:
		return false
	var model := packed.instantiate() as Node3D
	if model == null:
		return false
	holder.add_child(model)
	return true


# T-224: armor-slot mesh. A plate-family item routes to its per-slot TRELLIS GLB, fitted
# onto the bone via ARMOR_FIT; any other item keeps the legacy look (head -> primitive
# cap/helm; chest/legs/shoulders have no primitive yet, so they render nothing until a
# family GLB exists). Mirrors the _add_weapon_glb graceful-fallback contract.
static func _armor_gear_mesh(item_id: String, slot: String, armor_type: String = "") -> Node3D:
	var holder := Node3D.new()
	holder.name = "Gear_%s" % item_id
	var fam := _armor_family(item_id, armor_type)
	if ARMOR_GLBS.has(fam) and (ARMOR_GLBS[fam] as Dictionary).has(slot):
		if _add_armor_glb(holder, str(ARMOR_GLBS[fam][slot]), slot, fam):
			return holder
	if slot == "head":
		holder.free()
		return _head_gear_mesh(item_id)
	return holder


# T-420: armor visual family from the SERVER-authored armor_type. An item lights a family only when
# a GLB set exists for that armor_type — today "plate" (warrior), "robe" (mage) and "vestment"
# (priest, T-224 caster sets). The generic "cloth"/"leather"/"mail" families keep their own look
# until their sets ship, so a cloth dungeon drop (itm_bonepriest_wraps) never borrows the mage robe.
# The id-substring branch is a legacy fallback for any pre-T-420 broadcast that carried a bare id (a
# plate item whose id contains "plate"); real routing is by armor_type, so items like
# itm_maldrath_hollow_crown now light up too.
static func _armor_family(item_id: String, armor_type: String = "") -> String:
	if ARMOR_GLBS.has(armor_type):
		return armor_type
	if "plate" in item_id:
		return "plate"
	return ""


# T-224: instance an armor-slot GLB under `holder`, scaled/offset onto the bone per ARMOR_FIT.
# `fam` selects a family-qualified fit ("<fam>_<slot>", e.g. robe_chest) when one exists, else the
# plain per-slot fit (the warrior plate path). Returns false on any load failure so the caller keeps
# its fallback.
static func _add_armor_glb(holder: Node3D, path: String, slot: String, fam: String = "") -> bool:
	if not ResourceLoader.exists(path):
		return false
	var packed := load(path) as PackedScene
	if packed == null:
		return false
	var model := packed.instantiate() as Node3D
	if model == null:
		return false
	var fit: Dictionary = ARMOR_FIT.get("%s_%s" % [fam, slot], ARMOR_FIT.get(slot, {}))
	var s: float = fit.get("scale", 1.0)
	model.scale = Vector3(s, s, s)
	model.position = fit.get("offset", Vector3.ZERO)
	model.rotation_degrees = Vector3(0, fit.get("yaw_deg", 0.0), 0)
	holder.add_child(model)
	return true


# T-228: head-family meshes. The "Head" bone's origin sits low in the neck (verified
# against a pilot screenshot), so both families ride on a local +Y offset to land the
# mesh on top of the skull rather than floating at/below the chin.
static func _head_gear_mesh(item_id: String) -> Node3D:
	var holder := Node3D.new()
	holder.name = "Gear_%s" % item_id
	if "cap" in item_id:  # itm_leather_cap: a low leather dome with a small brim
		_gear_part(
			holder,
			SphereMesh.new(),
			Vector3(0.125, 0.125, 0.125),
			Vector3(0, HEAD_GEAR_LIFT + 0.02, 0),
			Color(0.42, 0.28, 0.16),
			0.85
		)
		_gear_part(
			holder,
			CylinderMesh.new(),
			Vector3(0.15, 0.025, 0.15),
			Vector3(0, HEAD_GEAR_LIFT - 0.03, 0),
			Color(0.35, 0.22, 0.12),
			0.85
		)
	else:  # helm family default — a fuller metal dome for anything else head-slot
		_gear_part(
			holder,
			SphereMesh.new(),
			Vector3(0.17, 0.17, 0.17),
			Vector3(0, HEAD_GEAR_LIFT + 0.02, 0),
			Color(0.55, 0.56, 0.60),
			0.4
		)
		_gear_part(
			holder,
			CylinderMesh.new(),
			Vector3(0.19, 0.025, 0.19),
			Vector3(0, HEAD_GEAR_LIFT - 0.05, 0),
			Color(0.45, 0.46, 0.50),
			0.4
		)
	return holder


static func _gear_part(
	parent: Node3D, mesh: Mesh, size: Vector3, pos: Vector3, color: Color, rough: float
) -> void:
	var mi := MeshInstance3D.new()
	if mesh is BoxMesh:
		(mesh as BoxMesh).size = size
	elif mesh is CylinderMesh:
		(mesh as CylinderMesh).top_radius = size.x
		(mesh as CylinderMesh).bottom_radius = size.z
		(mesh as CylinderMesh).height = size.y
	elif mesh is SphereMesh:
		(mesh as SphereMesh).radius = size.x
		(mesh as SphereMesh).height = size.x * 2.0
	mi.mesh = mesh
	mi.position = pos
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = rough
	mat.metallic = 0.9 if rough < 0.4 else 0.0
	mi.material_override = mat
	parent.add_child(mi)
