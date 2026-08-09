class_name TalentTheme
# T-508: the pure display layer behind the talent tree overhaul (playtest feedback #6).
#
# Two jobs, both static + Node-free so they unit-test without instancing a Control:
#   1. ROLE THEMING — a tree's `role` (tank/dps/healer/utility, authored in
#      server/world/data/talents/*.json `trees` block since T-474) maps to an era-palette accent
#      colour + emblem so each tab reads at a glance (tank = bronze shield, dps = ember, healer =
#      gold light, utility = arcane blue). The server reply does not yet carry the role, so
#      `role_for_tree` prefers an explicit `trees` meta entry if present and otherwise falls back
#      to TREE_ROLES — a DISPLAY MIRROR of the authored data (same idiom as `_POINTS_PER_TIER`).
#   2. LOCK MATH — `node_state` mirrors the server gate (talent_logic.validate_spend) so the panel
#      can darken/lock exactly what the server would reject. The server still validates every spend;
#      this is prediction for display only.
#
# Icon slugs reuse the T-422a convention (a curated slug -> res://assets/icons/talents/<slug>.png);
# a talent with no art file falls back to a role-tinted initials placeholder in the view.

extends RefCounted

const POINTS_PER_TIER := 5  # display mirror of talent_logic.POINTS_PER_TIER (server truth, T-523)

# Node display states (richer than the server's binary ok/reject so the UI can distinguish
# "unlocked but you're broke" from "tier/prereq gated"):
#   MAXED             — every rank bought (green, not clickable)
#   SPENDABLE         — the server would accept a point right now (lit + clickable)
#   AVAILABLE_NO_POINTS — tier + prereq satisfied but zero unspent points (lit, not clickable)
#   LOCKED            — tier gate or prereq gate unmet (darkened + lock glyph)
const MAXED := "maxed"
const SPENDABLE := "spendable"
const AVAILABLE_NO_POINTS := "available_no_points"
const LOCKED := "locked"

# Role -> era-palette accent. Values chosen to align with UiTheme (bronze/gold) and the caster
# blues while staying distinct enough to tell four tabs apart at a glance.
const ROLE_TANK := Color(0.62, 0.45, 0.23)  # bronze — shielded front line
const ROLE_DPS := Color(0.84, 0.36, 0.18)  # ember — burning offence
const ROLE_HEALER := Color(0.93, 0.80, 0.42)  # gold/light — restoration (UiTheme.GOLD_BRIGHT)
const ROLE_UTILITY := Color(0.56, 0.46, 0.86)  # arcane blue-violet — control/utility

# A one-word emblem tag per role (drawn as a small role-coloured glyph on the tab; no art files).
const ROLE_EMBLEM := {
	"tank": "shield",
	"dps": "flame",
	"healer": "light",
	"utility": "rune",
}

# DISPLAY MIRROR of the authored `trees` role metadata (server/world/data/talents/*.json). Kept
# here because the talents reply does not (yet) forward the per-tree role; `role_for_tree` prefers
# a live `trees` meta entry when one is supplied.
const TREE_ROLES := {
	"arms": "dps",
	"fury": "dps",
	"protection": "tank",
	"fire": "dps",
	"frost": "dps",
	"arcane": "utility",
	"holy": "healer",
	"discipline": "healer",
	"shadow": "dps",
}


# Resolve a tree id -> role. `trees_meta` is the optional `trees` array from the reply
# ([{id, role}, ...]); when it names the tree we trust it, else the display mirror, else "dps".
static func role_for_tree(tree: String, trees_meta: Array = []) -> String:
	for entry in trees_meta:
		if entry is Dictionary and str(entry.get("id", "")) == tree:
			var role := str(entry.get("role", ""))
			if role != "":
				return role
	return str(TREE_ROLES.get(tree, "dps"))


static func role_color(role: String) -> Color:
	match role:
		"tank":
			return ROLE_TANK
		"healer":
			return ROLE_HEALER
		"utility":
			return ROLE_UTILITY
		_:  # dps + any unknown role read as offence
			return ROLE_DPS


static func role_emblem(role: String) -> String:
	return str(ROLE_EMBLEM.get(role, "flame"))


# Icon slug for a talent: an explicit server `icon` wins (future T-422a authored art); otherwise
# derive a stable slug by stripping the `tal_<class>_` id prefix (tal_war_might -> "might"). The
# view tries res://assets/icons/talents/<slug>.png and falls back to an initials placeholder.
static func slug_for(tal: Dictionary) -> String:
	var explicit := str(tal.get("icon", ""))
	if explicit != "":
		return explicit
	var id := str(tal.get("id", ""))
	var parts := id.split("_", false)
	if parts.size() >= 3 and parts[0] == "tal":
		return "_".join(parts.slice(2))  # drop "tal" + class token
	return id


# Points spent inside one tree (mirror of talent_logic.points_in_tree, but keyed off the display
# defs array rather than a defs dict).
static func points_in_tree(spent: Dictionary, defs: Array, tree: String) -> int:
	var total := 0
	for tal in defs:
		var id := str((tal as Dictionary).get("id", ""))
		if str((tal as Dictionary).get("tree", "")) == tree:
			total += int(spent.get(id, 0))
	return total


# Is `tier` reachable given the points already spent in its tree? (tier-1)*POINTS_PER_TIER gate.
static func is_tier_unlocked(tree_points: int, tier: int) -> bool:
	return tree_points >= (tier - 1) * POINTS_PER_TIER


# Predict the display state of one talent node. Mirrors talent_logic.validate_spend EXACTLY,
# including the server rule that a prereq must be at MAX ranks (not merely > 0 — the old T-065
# panel got this wrong). `defs_by_id` maps talent id -> def (for prereq max_ranks lookup).
static func node_state(
	tal: Dictionary, spent: Dictionary, tree_points: int, points_left: int, defs_by_id: Dictionary
) -> String:
	var id := str(tal.get("id", ""))
	var ranks := int(spent.get(id, 0))
	if ranks >= int(tal.get("max_ranks", 1)):
		return MAXED
	# Tier gate — darkened + locked until enough points sit in this tree.
	if not is_tier_unlocked(tree_points, int(tal.get("tier", 1))):
		return LOCKED
	# Prereq gate — the required talent must be MAXED (server truth).
	var prereq = tal.get("prereq")
	if prereq != null and str(prereq) != "":
		var prereq_id := str(prereq)
		var prereq_max := int((defs_by_id.get(prereq_id, {}) as Dictionary).get("max_ranks", 1))
		if int(spent.get(prereq_id, 0)) < prereq_max:
			return LOCKED
	# Unlocked, but is a point actually available to spend?
	if points_left < 1:
		return AVAILABLE_NO_POINTS
	return SPENDABLE


# Build an id -> def lookup from the display defs array (convenience for node_state callers).
static func defs_by_id(defs: Array) -> Dictionary:
	var out := {}
	for tal in defs:
		out[str((tal as Dictionary).get("id", ""))] = tal
	return out


# The ordered list of unique tree ids in a defs array, preserving first-seen order (the reply is
# already sorted tree -> tier, so this yields a stable tab order).
static func tree_ids(defs: Array) -> Array:
	var seen := {}
	var out: Array = []
	for tal in defs:
		var tree := str((tal as Dictionary).get("tree", ""))
		if tree != "" and not seen.has(tree):
			seen[tree] = true
			out.append(tree)
	return out
