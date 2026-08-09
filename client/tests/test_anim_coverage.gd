extends GutTest
# T-397: unit coverage for the PURE animation-coverage logic (anim_coverage.gd) — the resolution /
# set logic the live anim-audit gate leans on, tested here without a warm client so a clip-rename
# regression (the 2026-07-12 possessed-float class) is caught by a fast headless test, not only by
# the live probe. Present-set passes; a missing OR misnamed clip fails; the required-set is data.

const AC = preload("res://scripts/world/anim_coverage.gd")

# A trimmed STATE_CLIPS fixture — the synonym shape the real EntityVisuals const carries. Kept
# local so the logic tests stay deterministic even if the production table gains synonyms.
const STATE_CLIPS := {
	"idle": ["idle", "Idle_Loop", "Idle"],
	"walk": ["walk", "Walk_Loop", "Walk"],
	"run": ["run", "Jog_Fwd_Loop", "Jog_Fwd"],
	"attack": ["attack", "Sword_Attack"],
}


func test_resolve_returns_first_present_synonym() -> void:
	# Prefers the first synonym in the list that the rig carries (mirrors play_state).
	var present := ["Walk", "Idle", "Sword_Attack"]
	assert_eq(AC.resolve_state("walk", present, STATE_CLIPS), "Walk", "walk -> Walk")
	assert_eq(AC.resolve_state("idle", present, STATE_CLIPS), "Idle", "idle -> Idle")
	assert_eq(AC.resolve_state("attack", present, STATE_CLIPS), "Sword_Attack", "attack synonym")


func test_resolve_unresolved_when_no_synonym_present() -> void:
	# Missing entirely: the rig carries nothing for the state.
	assert_eq(
		AC.resolve_state("run", ["Idle", "Walk"], STATE_CLIPS), "", "run absent -> unresolved"
	)
	# Unknown state (not in the table) also unresolved rather than crashing.
	assert_eq(AC.resolve_state("cast", ["Idle"], STATE_CLIPS), "", "unknown state -> unresolved")


func test_resolve_misnamed_clip_is_unresolved() -> void:
	# The exact possessed-float bug: the rig carries a clip, but under a name NOT in the synonym
	# list (importer renamed "Walk_Loop" -> "Walk", or an author typo "Wlak"). It plays fine and
	# moves nothing gameplay can reach, so coverage must report it UNRESOLVED, not present.
	assert_eq(AC.resolve_state("walk", ["Wlak", "WalkCycle"], STATE_CLIPS), "", "misnamed -> gap")


func test_audit_rig_full_present_set_passes() -> void:
	var required := ["idle", "walk", "run", "attack"]
	var present := ["Idle", "Walk", "Jog_Fwd", "Sword_Attack"]
	var r := AC.audit_rig(required, present, STATE_CLIPS)
	assert_true((r["unresolved"] as Array).is_empty(), "no gaps on a complete rig")
	assert_eq((r["resolved"] as Dictionary).size(), 4, "all four states resolved")
	assert_eq(r["resolved"]["run"], "Jog_Fwd", "run resolved to carried synonym")


func test_audit_rig_reports_missing_states_in_order() -> void:
	var required := ["idle", "walk", "run", "attack"]
	var present := ["Idle"]  # only idle carried
	var r := AC.audit_rig(required, present, STATE_CLIPS)
	assert_eq(r["unresolved"], ["walk", "run", "attack"], "gaps preserve required order")
	assert_eq((r["resolved"] as Dictionary).size(), 1, "only idle resolved")


func test_audit_registry_is_data_driven() -> void:
	# The required-set is DATA: adding a rig/action row is data, not code. Feed two rigs with
	# different required-sets (a "hero" needing four, a "creature" needing two).
	var rigs := {
		"hero.glb": ["idle", "walk", "run", "attack"],
		"critter.glb": ["idle", "walk"],
	}
	var present_by_rig := {
		"hero.glb": ["Idle", "Walk", "Jog_Fwd", "Sword_Attack"],
		"critter.glb": ["idle", "walk"],
	}
	var audit := AC.audit_registry(rigs, present_by_rig, STATE_CLIPS)
	assert_true(audit["pass"], "both rigs fully covered")
	assert_eq(audit["total_checks"], 6, "4 + 2 required states")
	assert_eq(audit["total_gaps"], 0, "no gaps")


func test_audit_registry_flags_missing_rig_and_gaps() -> void:
	var rigs := {
		"hero.glb": ["idle", "walk", "run", "attack"],
		"dropped.glb": ["idle", "walk"],
	}
	# hero carries a MISNAMED run; "dropped.glb" is absent from present_by_rig entirely.
	var present_by_rig := {"hero.glb": ["Idle", "Walk", "Sword_Attack"]}
	var audit := AC.audit_registry(rigs, present_by_rig, STATE_CLIPS)
	assert_false(audit["pass"], "gaps present -> fail")
	# hero: 1 gap (run). dropped: 2 gaps (whole rig missing). => 3 total.
	assert_eq(audit["total_gaps"], 3, "1 rename gap + 2 missing-rig gaps")
	assert_false(audit["rigs"]["dropped.glb"]["present"], "dropped rig marked absent")
	var flat := audit["gaps"] as Array
	assert_eq(flat.size(), 3, "flat worklist has one row per gap")
	assert_true({"rig": "hero.glb", "state": "run"} in flat, "hero/run in worklist")


func test_emote_authoring_gaps_lists_empty_clip_rows() -> void:
	# Mirrors the emotes.json shape: text-only rows have clip "", baked rows name a state.
	var catalog := {
		"_comment": "metadata, ignored",
		"wave": {"self": "You wave.", "clip": ""},
		"dance": {"self": "You dance.", "clip": "dance"},
		"bow": {"self": "You bow.", "clip": ""},
	}
	var pending := AC.emote_authoring_gaps(catalog)
	assert_eq(pending, ["bow", "wave"], "sorted, only empty-clip rows, metadata skipped")


func test_format_report_pass_and_fail_are_legible() -> void:
	var pass_audit := AC.audit_registry({"hero.glb": ["idle"]}, {"hero.glb": ["Idle"]}, STATE_CLIPS)
	assert_string_contains(AC.format_report(pass_audit), "COVERAGE: PASS")
	var fail_audit := AC.audit_registry(
		{"hero.glb": ["idle", "run"]}, {"hero.glb": ["Idle"]}, STATE_CLIPS
	)
	var report := AC.format_report(fail_audit)
	assert_string_contains(report, "COVERAGE: FAIL")
	assert_string_contains(report, "run", "names the unresolved state")


func test_real_state_clips_resolves_a_healthy_hero_set() -> void:
	# Guard against production STATE_CLIPS drifting away from the states the registry requires:
	# a canonical UAL-imported hero clip set must resolve the full required hero action list.
	var ev = load("res://scripts/world/entity_visuals.gd")
	var required := ["idle", "walk", "run", "jump", "attack", "cast", "hit", "death"]
	# Names as the 4.7 importer leaves them (the _Loop suffix stripped) for the UAL hero rigs.
	var present := [
		"Idle",
		"Walk",
		"Jog_Fwd",
		"Jump",
		"Sword_Attack",
		"Spell_Simple_Shoot",
		"Hit_Chest",
		"Death01"
	]
	var r := AC.audit_rig(required, present, ev.STATE_CLIPS)
	assert_true(
		(r["unresolved"] as Array).is_empty(),
		"real STATE_CLIPS resolves the healthy hero set; drift here = a possessed-float regression"
	)
