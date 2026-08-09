extends GutTest
# T-285: party frames — roster rows built from a party list, health bound per member, leader
# pip, and out-of-range dim. The row Controls hold their own state, so this tests headless.

const PartyFrames = preload("res://scripts/ui/party_frames.gd")


func _frames() -> PartyFrames:
	var f: PartyFrames = PartyFrames.new()
	add_child_autofree(f)
	return f


func _row(name: String, hp: int, max_hp: int, leader := false, in_range := true) -> Dictionary:
	return {
		"peer_id": hash(name) & 0xffff,
		"name": name,
		"hp": hp,
		"max_hp": max_hp,
		"char_class": "warrior",
		"leader": leader,
		"in_range": in_range,
	}


# T-334: role icons — each member's row shows its trinity role, derived from char_class.
func test_role_icon_per_class() -> void:
	var f := _frames()
	var tank := _row("Tank", 100, 100)
	var healer := _row("Healer", 100, 100)
	healer["char_class"] = "priest"
	var caster := _row("Caster", 100, 100)
	caster["char_class"] = "mage"
	var odd := _row("Odd", 100, 100)
	odd["char_class"] = "gnome_tinker"
	f.set_party([tank, healer, caster, odd])
	assert_eq(f.row_role(0), "tank", "warrior reads tank")
	assert_eq(f.row_role(1), "heal", "priest reads heal")
	assert_eq(f.row_role(2), "dps", "mage reads dps")
	assert_eq(f.row_role(3), "dps", "unknown class floors to dps (mirrors lfg_logic)")


# T-334: crypt-stair ready marker toggles per member and per rebind.
func test_ready_marker_toggles_per_member() -> void:
	var f := _frames()
	var ana := _row("Ana", 100, 100)
	ana["ready"] = true
	var bo := _row("Bo", 100, 100)
	f.set_party([ana, bo])
	assert_true(f.row_is_ready(0), "the member at the stair lights the marker")
	assert_false(f.row_is_ready(1), "the far member does not")
	ana["ready"] = false
	f.set_party([ana, bo])
	assert_false(f.row_is_ready(0), "walking off the stair clears it on the next broadcast")


func test_solo_hides_the_frames() -> void:
	var f := _frames()
	f.set_party([_row("Solo", 100, 100)])  # a party of one isn't a party
	assert_eq(f.visible_row_count(), 0, "fewer than 2 members -> no rows")
	assert_false(f.visible, "the container hides when not in a real party")


func test_builds_a_row_per_member() -> void:
	var f := _frames()
	f.set_party([_row("Ana", 50, 100, true), _row("Bo", 80, 100)])
	assert_eq(f.visible_row_count(), 2, "one visible row per member")
	assert_eq(f.row_name(0), "Ana")
	assert_eq(f.row_name(1), "Bo")


func test_health_binds_per_member() -> void:
	var f := _frames()
	f.set_party([_row("Ana", 25, 100), _row("Bo", 90, 100)])
	assert_almost_eq(f.row_hp_ratio(0), 0.25, 0.01, "Ana at 25%")
	assert_almost_eq(f.row_hp_ratio(1), 0.90, 0.01, "Bo at 90%")


func test_leader_pip_only_on_the_leader() -> void:
	var f := _frames()
	f.set_party([_row("Ana", 100, 100, true), _row("Bo", 100, 100, false)])
	assert_true(f.row_is_leader(0), "leader shows the pip")
	assert_false(f.row_is_leader(1), "non-leader does not")


func test_out_of_range_dims_the_row() -> void:
	var f := _frames()
	f.set_party([_row("Ana", 100, 100, false, true), _row("Bo", 100, 100, false, false)])
	assert_false(f.row_is_dimmed(0), "in-range member is lit")
	assert_true(f.row_is_dimmed(1), "out-of-range member is dimmed")


# T-472: a 10-man raid lays out as two columns of five, keyed by each row's subgroup.
func test_raid_lays_out_two_columns_by_subgroup() -> void:
	var f := _frames()
	var rows := []
	for i in range(10):
		var r := _row("M%d" % i, 100, 100, i == 0)
		r["subgroup"] = 0 if i < 5 else 1
		rows.append(r)
	f.set_party(rows)
	assert_eq(f.visible_row_count(), 10, "all ten raid members get a row")
	for i in range(5):
		assert_eq(f.row_column(i), 0, "subgroup 0 renders in the first column")
	for i in range(5, 10):
		assert_eq(f.row_column(i), 1, "subgroup 1 renders in the second column")


func test_plain_party_stays_single_column() -> void:
	var f := _frames()
	f.set_party([_row("Ana", 100, 100, true), _row("Bo", 100, 100)])  # no subgroup key
	assert_eq(f.row_column(0), 0)
	assert_eq(f.row_column(1), 0, "rows without a subgroup all sit in column 0")


func test_shrinking_then_growing_the_roster_reconciles() -> void:
	var f := _frames()
	f.set_party([_row("Ana", 100, 100), _row("Bo", 100, 100), _row("Cy", 100, 100)])
	assert_eq(f.visible_row_count(), 3)
	f.set_party([_row("Ana", 100, 100), _row("Bo", 100, 100)])  # Cy left
	assert_eq(f.visible_row_count(), 2, "extra pooled row is hidden, not shown")
	f.set_party([])  # party disbanded
	assert_eq(f.visible_row_count(), 0)
	assert_false(f.visible)
