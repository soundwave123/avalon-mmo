extends GutTest
# T-192: source-regression on the terrain shader's road-grime terms. A shader can't be
# unit-run headless, so we pin its SOURCE contract: the wheel ruts / puddles must be
# road-local (measured from the winding centerline, hence direction-aware) and fully
# confined to the road mask so the surrounding meadow is never modulated.

const SHADER_PATH := "res://shaders/terrain_splat.gdshader"


func _src() -> String:
	var f := FileAccess.open(SHADER_PATH, FileAccess.READ)
	assert_not_null(f, "terrain shader source is readable")
	return f.get_as_text() if f != null else ""


func test_road_wear_block_exists() -> void:
	assert_string_contains(_src(), "T-192", "the cart-road wear block is present in the shader")


func test_ruts_are_road_local_and_direction_aware() -> void:
	# The lateral offset is measured from road_center_x(z) — the winding centerline — so the
	# ruts follow the road's direction wherever it bends, not a fixed world axis.
	assert_string_contains(
		_src(), "wpos.x - road_center_x(wpos.z)", "ruts use the road-local lateral coordinate"
	)


func test_grime_is_confined_to_the_road_mask() -> void:
	var src := _src()
	assert_string_contains(src, "if (m > 0.001)", "the whole wear block is gated by the road mask")
	assert_string_contains(src, "groove * wear * m", "ruts scale by the road mask m")
	assert_string_contains(src, "pud *= m", "puddles scale by the road mask m")


func test_has_paired_grooves_and_puddles() -> void:
	var src := _src()
	assert_string_contains(src, "abs(lx) - rut_off", "paired grooves at +/- the cart wheel gauge")
	assert_string_contains(src, "smoothstep(0.72, 0.87", "low-frequency wet puddle patches")


# --- T-443: Highkeep paved streetscape source pins ---------------------------------------


func test_hk_paving_masks_exist() -> void:
	var src := _src()
	assert_string_contains(src, "float hk_pave_mask", "cobble paving mask present")
	assert_string_contains(src, "float hk_verge_mask", "packed-earth verge mask present")
	assert_string_contains(src, "float hk_plaza_mask", "flagstone plaza mask present")


func test_hk_paving_is_confined_to_the_city_circuit() -> void:
	# Both the paving and verge masks must keep the T-202 hard circuit clamp, so no cobble
	# ever paints outside the walls (the gate at z=-136 is the northern paint limit).
	var clamp_line := "p.z > -136.0 || abs(p.x) > 126.0 || p.z < -344.0"
	var src := _src()
	var first := src.find(clamp_line)
	assert_true(first >= 0, "the circuit clamp guards the paving masks")
	assert_true(src.find(clamp_line, first + 1) > first, "the verge mask keeps the clamp too")


func test_hk_plaza_rect_matches_worldview_mirror() -> void:
	# Three-way splat sync: the shader's plaza rect must equal WorldView.HK_PLAZA_POS/HALF
	# (world-audit.py reads the same geometry from highkeep_plan.json zones.market_square).
	var expected := (
		"const vec4 HK_PLAZA_RECT = vec4(%.1f, %.1f, %.1f, %.1f);"
		% [
			WorldView.HK_PLAZA_POS.x,
			WorldView.HK_PLAZA_POS.y,
			WorldView.HK_PLAZA_HALF.x,
			WorldView.HK_PLAZA_HALF.y,
		]
	)
	assert_string_contains(_src(), expected, "plaza rect mirrors WorldView constants")


func test_hk_street_segment_count_matches_worldview_mirror() -> void:
	# Three-way splat sync: the shader's segment count must equal the WorldView mirror's
	# (world-audit.py reads the same street polylines from highkeep_plan.json). T-443 adds
	# the three ward row lanes to BOTH, so a count drift here means one side was forgotten.
	var expected := "const int HK_NSEG = %d" % WorldView.HK_STREET_SEGS.size()
	var src := _src()
	assert_string_contains(src, expected, "shader segment count mirrors WorldView")
	assert_string_contains(src, "- HK_HW[i]", "street halfwidths still shape the SDF")


func test_hk_gate_mud_and_wear_are_confined_to_the_paving() -> void:
	var src := _src()
	assert_string_contains(src, "if (hkc > 0.001)", "the wear block is gated by the paving mask")
	assert_string_contains(src, "* hkc;", "gate mud scales by the paving mask")
	assert_string_contains(src, "wear * hkc", "traffic wear scales by the paving mask")


# --- T-491: Highkeep ward-yard trodden-earth source pins ---------------------------------


func test_hk_ward_masks_exist() -> void:
	var src := _src()
	assert_string_contains(src, "float hk_ward_mask", "ward trodden-earth mask present")
	assert_string_contains(src, "float hk_garden_mask", "kitchen-garden bed mask present")


func test_hk_ward_earth_is_confined_to_the_circuit() -> void:
	# The ward earth keeps the same hard circuit clamp as the paving, so no trodden earth ever
	# paints outside the walls — the clamp must appear inside the ward mask body.
	var src := _src()
	var mask := src.find("float hk_ward_mask")
	assert_true(mask >= 0, "ward mask present")
	var clamp_at := src.find("p.z > -136.0 || abs(p.x) > 126.0 || p.z < -344.0", mask)
	assert_true(clamp_at > mask, "the circuit clamp guards the ward mask body")


func test_hk_ward_wear_is_confined_to_the_ward_mask() -> void:
	var src := _src()
	assert_string_contains(
		src, "if (wyard > 0.001)", "the ward wear/mud block is gated by the ward mask"
	)
	assert_string_contains(src, "worn * wyard", "desire-path wear scales by the ward mask")


func test_hk_ward_rects_match_worldview_mirror() -> void:
	# Three-way splat sync (non-street region): the shader ward/garden rect counts must equal the
	# WorldView mirror, so a drift here means one side of the splat sync was forgotten.
	var src := _src()
	assert_string_contains(
		src,
		"const int HK_NWARD = %d" % WorldView.HK_WARD_RECT.size(),
		"ward rect count mirrors WorldView"
	)
	assert_string_contains(
		src,
		"const int HK_NGARDEN = %d" % WorldView.HK_GARDEN_RECT.size(),
		"garden rect count mirrors WorldView"
	)
