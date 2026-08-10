extends GutTest

# T-751: the freed-instance / post-await liveness gate (scripts/gates/09-freed-instance.py) is the
# only part of this ticket that has to keep working after everyone forgets the ticket exists — so
# it carries its own seeded violations and re-proves itself on EVERY invocation (a gate that
# silently stops catching things is worse than no gate). This test is what makes that self-proof
# run in the suite rather than only in pre-commit, and it is also the ticket's DoD item: "gate
# firing on a seeded violation".
#
# The gate's --selftest asserts, against temp files it writes itself:
#   * rule A flags a field the file queue_free()s without clearing, and does NOT flag one that is
#     freed and nulled in the same breath;
#   * rule B flags an `await` with a live statement after it and no is_instance_valid /
#     is_inside_tree within 5 lines, and does NOT flag an await that ends its function;
#   * rule C flags an immediate `.free()` in the panel layer;
#   * none of the three fires on the corrected version of the same code.
#
# What the gate deliberately does NOT enforce is the audit's original ask — swapping `== null` for
# is_instance_valid() on every freeable field. That trap is Godot 3's; on the pinned 4.7.1 a freed
# reference already compares equal to null (measured, see the script header). See T-751.

const _GATE := "scripts/gates/09-freed-instance.py"


func _repo_root() -> String:
	# res:// is <repo>/client/ — the gate lives one level up, next to the other gate scripts.
	return ProjectSettings.globalize_path("res://").path_join("..").simplify_path()


func _run(args: Array) -> Dictionary:
	var out: Array = []
	var argv: Array = [_repo_root().path_join(_GATE)]
	argv.append_array(args)
	var code := OS.execute("python3", argv, out, true)
	return {"code": code, "out": "\n".join(out)}


func test_the_gate_script_is_present_where_pre_commit_expects_it() -> void:
	assert_true(
		FileAccess.file_exists(_repo_root().path_join(_GATE)),
		"the pre-commit hook entry points at %s" % _GATE
	)


func test_the_gate_still_catches_its_own_seeded_violations() -> void:
	var r := _run(["--selftest"])
	assert_eq(int(r["code"]), 0, "seeded-violation selftest failed:\n%s" % str(r["out"]))
	assert_string_contains(str(r["out"]), "selftest ok")


func test_the_current_tree_passes_the_gate() -> void:
	var r := _run([])
	assert_eq(int(r["code"]), 0, "the tree has freed-instance/post-await hits:\n%s" % str(r["out"]))
