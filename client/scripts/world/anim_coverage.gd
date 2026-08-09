extends RefCounted
# T-397: the PURE animation-coverage logic, carved out of the live anim_probe so it can be
# unit-tested without a warm client / GLB import cache. It answers ONE question deterministically
# from data: given a rig's REQUIRED animation states (the anim_registry manifest) and the set of
# clip names the imported rig actually CARRIES, which required states RESOLVE through the real
# EntityVisuals.STATE_CLIPS synonym table — and which are missing or misnamed (the silent
# possessed-float class of bug: a state whose synonyms the rig no longer carries resolves to
# nothing, plays void, and every scene test still stays green).
#
# The live probe (tools/anim_probe.gd) supplies `present_clips` from the instantiated rig and the
# real STATE_CLIPS const, then adds the bone-motion check on top; THIS module owns the naming /
# set logic so a rename regression is caught by a fast headless unit test, not only by a live gate.
#
# Everything here is a pure static function over plain data — no Node, no ResourceLoader, no GLB.


# Resolve one animation STATE to the first synonym clip the rig actually carries.
# Mirrors EntityVisuals.play_state resolution exactly (first STATE_CLIPS[state] entry present).
# Returns "" when the state is UNRESOLVED — no synonym is present (missing OR misnamed clip).
static func resolve_state(state: String, present_clips: Array, state_clips: Dictionary) -> String:
	for clip: String in state_clips.get(state, []):
		if present_clips.has(clip):
			return clip
	return ""


# Audit ONE rig's required states against the clips it carries.
# Returns { "resolved": { state: clip }, "unresolved": [ state, ... ] } — unresolved preserves the
# required order so the worklist is stable/diffable.
static func audit_rig(
	required_states: Array, present_clips: Array, state_clips: Dictionary
) -> Dictionary:
	var resolved := {}
	var unresolved: Array[String] = []
	for state: String in required_states:
		var clip := resolve_state(state, present_clips, state_clips)
		if clip == "":
			unresolved.append(state)
		else:
			resolved[state] = clip
	return {"resolved": resolved, "unresolved": unresolved}


# Audit the whole registry. `rigs` = { rig_name: [required_state, ...] } (the manifest);
# `present_by_rig` = { rig_name: [carried_clip, ...] } (from the live rigs, or a fixture in tests).
# A rig named in the manifest but ABSENT from present_by_rig counts every required state as a gap
# (the "MISSING GLB" case) so a dropped rig can never silently pass.
# Returns:
#   { "rigs": { rig: {resolved, unresolved, present: bool} },
#     "total_checks": int, "total_gaps": int, "pass": bool,
#     "gaps": [ {rig, state}, ... ] }   # flat worklist for the deferred authoring pass
static func audit_registry(
	rigs: Dictionary, present_by_rig: Dictionary, state_clips: Dictionary
) -> Dictionary:
	var out_rigs := {}
	var total_checks := 0
	var total_gaps := 0
	var gaps: Array[Dictionary] = []
	for rig: String in rigs:
		var required: Array = rigs[rig]
		total_checks += required.size()
		if not present_by_rig.has(rig):
			var missing_all: Array[String] = []
			for state: String in required:
				missing_all.append(state)
				gaps.append({"rig": rig, "state": state})
			out_rigs[rig] = {"resolved": {}, "unresolved": missing_all, "present": false}
			total_gaps += required.size()
			continue
		var rig_result := audit_rig(required, present_by_rig[rig], state_clips)
		rig_result["present"] = true
		out_rigs[rig] = rig_result
		for state: String in rig_result["unresolved"]:
			gaps.append({"rig": rig, "state": state})
		total_gaps += (rig_result["unresolved"] as Array).size()
	return {
		"rigs": out_rigs,
		"total_checks": total_checks,
		"total_gaps": total_gaps,
		"pass": total_gaps == 0,
		"gaps": gaps,
	}


# Data-driven authoring worklist for the emote catalog (server/world/data/social/emotes.json):
# every emote row whose `clip` is empty has NO baked animation yet and stays text-only until one is
# authored. Keys starting with "_" (e.g. "_comment") are metadata, not emotes.
# Returns the sorted list of emote ids awaiting a clip — the deferred authoring pass's emote slice.
static func emote_authoring_gaps(catalog: Dictionary) -> Array:
	var pending: Array[String] = []
	for id: String in catalog:
		if id.begins_with("_"):
			continue
		var row: Variant = catalog[id]
		if row is Dictionary and str(row.get("clip", "")) == "":
			pending.append(id)
	pending.sort()
	return pending


# Render a readable coverage report from an audit_registry() result — the same text the live gate
# and the headless report generator print, so a gap is legible without re-deriving it.
static func format_report(audit: Dictionary) -> String:
	var lines: Array[String] = []
	var rigs: Dictionary = audit.get("rigs", {})
	for rig: String in rigs:
		var r: Dictionary = rigs[rig]
		if not bool(r.get("present", true)):
			lines.append("  %s: MISSING RIG — every required state is a gap" % rig)
			continue
		var unresolved: Array = r.get("unresolved", [])
		if unresolved.is_empty():
			continue
		lines.append("  %s: UNRESOLVED %s" % [rig, str(unresolved)])
	var verdict := (
		"COVERAGE: %s (%d state checks, %d gaps)"
		% [
			"PASS" if bool(audit.get("pass", false)) else "FAIL",
			int(audit.get("total_checks", 0)),
			int(audit.get("total_gaps", 0)),
		]
	)
	if lines.is_empty():
		return verdict
	return verdict + "\n" + "\n".join(lines)
