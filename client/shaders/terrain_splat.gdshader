// T-132 terrain splat (blind-judge round 3, world fix #2): painted grass + dirt albedo
// blended in world space. The road is a soft-edged, wobbling dirt corridor painted INTO the
// terrain (no more hard-edged brown ribbon mesh), and a low-frequency value breakup kills
// the tiling read on the meadow.
shader_type spatial;

uniform sampler2D grass_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D dirt_tex : source_color, filter_linear_mipmap, repeat_enable;
// T-185 realism: scan-PBR ground (ambientCG Grass004/Ground025) — normals give the raking
// golden-hour light something to catch. Tiles sized to the scans' real-world coverage.
uniform sampler2D grass_nrm : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D dirt_nrm : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D breakup_tex : repeat_enable; // fbm noise (grayscale)
// T-406: real cobble scan for the Ashmoor High Street (Poly Haven cobblestone_floor_08, CC0,
// 1K JPG diff + GL normal) — the strip finally has per-sett relief instead of tinted dirt.
uniform sampler2D cobble_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D cobble_nrm : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float grass_tile = 2.6; // meters per texture repeat (scan covers ~2m)
uniform float dirt_tile = 3.0;
uniform float cobble_tile = 2.0; // the PH scan's real-world coverage (~2m)
// T-179: Crystal Lake shore ring — set from _build_ground so the terrain paints a wet-sand/mud
// band around the pond's waterline (so grass never meets open water directly).
uniform vec2 lake_center = vec2(18.0, 22.0);
uniform float lake_radius = 12.0;

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

// Owner mandate (forest buildout): dirt roads were never ruler-straight. The centerline
// WINDS through the forest stretch south of the village and straightens where it must:
// through the main street (buildings front x=0) and into the gatehouse (~z=-102).
// KEEP IN SYNC with WorldView.road_center_x() and scripts/world-audit.py road_center_x().
float road_center_x(float z) {
	float w = clamp((-z - 18.0) / 14.0, 0.0, 1.0) * clamp((z + 136.0) / 14.0, 0.0, 1.0);
	return w * (6.0 * sin(0.055 * (z + 18.0)) + 2.6 * sin(0.021 * (z + 18.0) + 1.7));
}

// The village->Highkeep road corridor (matches the clutter reroll zone): follows the winding
// centerline, z from the village edge (~z=6) to the gatehouse (~z=-102), with a noise wobble
// so the edge meanders like a walked trail instead of a ruler line.
float road_mask(vec3 p) {
	float wob = (texture(breakup_tex, vec2(p.z * 0.013, 0.37)).r - 0.5) * 2.0;
	float half_w = 2.6 + wob * 0.8;
	float d = abs(p.x - road_center_x(p.z) + wob * 1.4) - half_w;
	float m = 1.0 - smoothstep(0.0, 2.2, d);
	// T-190: the road runs THROUGH the village (main street, buildings both sides) and fades
	// out past the north entrance (house_a plot ends ~z=24).
	float zfade = smoothstep(-141.0, -136.0, p.z) * (1.0 - smoothstep(24.0, 30.0, p.z));
	return m * zfade;
}

// T-202: Highkeep street graph — trodden-earth streets painted into the terrain from the
// plan's polylines (client/assets/highkeep_plan.json streets + market_square zone). The
// segment constants are GENERATED from the plan (see the T-202 ticket); KEEP IN SYNC with
// WorldView.HK_STREET_SEGS and scripts/world-audit.py (those read the plan JSON directly).
// T-443 adds the three ward ROW lanes (segments 20-25: ward_nw_row_lane, ward_e_row_lane,
// ward_s_row_lane) so the townhouse rows front onto paved streets instead of open lawn.
const int HK_NSEG = 26;
const vec4 HK_SEG[26] = vec4[](
	vec4(72.0, -262.0, 83.0, -262.0),
	vec4(0.0, -140.0, -2.0, -168.0),
	vec4(-2.0, -168.0, 2.0, -197.0),
	vec4(-20.0, -215.0, 0.0, -197.0),
	vec4(0.0, -197.0, 20.0, -215.0),
	vec4(20.0, -215.0, 0.0, -233.0),
	vec4(0.0, -233.0, -20.0, -215.0),
	vec4(0.0, -233.0, -2.0, -262.0),
	vec4(-2.0, -262.0, 0.0, -292.0),
	vec4(-20.0, -215.0, -52.0, -222.0),
	vec4(-52.0, -222.0, -70.0, -252.0),
	vec4(20.0, -215.0, 52.0, -228.0),
	vec4(52.0, -228.0, 72.0, -262.0),
	vec4(72.0, -262.0, 76.0, -296.0),
	vec4(-1.0, -162.0, -56.0, -168.0),
	vec4(-56.0, -168.0, -92.0, -190.0),
	vec4(-1.0, -162.0, 54.0, -168.0),
	vec4(54.0, -168.0, 92.0, -190.0),
	vec4(0.0, -292.0, -44.0, -300.0),
	vec4(-44.0, -300.0, -60.0, -294.0),
	vec4(-52.0, -222.0, -48.0, -212.0),
	vec4(-48.0, -212.0, -104.0, -208.5),
	vec4(52.0, -228.0, 49.0, -212.3),
	vec4(49.0, -212.3, 106.0, -212.3),
	vec4(-44.0, -300.0, -38.0, -322.3),
	vec4(-38.0, -322.3, -76.0, -322.3));
const float HK_HW[26] = float[](
	2.25, 3.00, 3.00, 2.50, 2.50, 2.50, 2.50, 3.00, 3.00, 2.50,
	2.50, 2.50, 2.50, 2.50, 2.25, 2.25, 2.25, 2.25, 2.25, 2.25,
	2.25, 2.25, 2.25, 2.25, 2.25, 2.25);
// T-443: the market plaza rect (cx, cz, half_x, half_z) — split out as a named constant so
// the plaza can read as dressed FLAGSTONE, distinct from the cobbled avenues. Geometry is
// UNCHANGED from T-202 (matches highkeep_plan.json zones.market_square and
// WorldView.HK_PLAZA_POS/HK_PLAZA_HALF — the three-way splat sync holds).
const vec4 HK_PLAZA_RECT = vec4(0.0, -215.0, 18.0, 16.0);

// Signed distance to the street network edge (negative = on a street). The market square
// is a plaza rect so the whole civic room reads trodden, not just a ring outline.
float hk_street_d(vec2 p) {
	float best = 1e9;
	for (int i = 0; i < HK_NSEG; i++) {
		vec2 a = HK_SEG[i].xy;
		vec2 b = HK_SEG[i].zw;
		vec2 ab = b - a;
		float t = clamp(dot(p - a, ab) / dot(ab, ab), 0.0, 1.0);
		best = min(best, distance(p, a + ab * t) - HK_HW[i]);
	}
	vec2 dq = abs(p - HK_PLAZA_RECT.xy) - HK_PLAZA_RECT.zw;
	best = min(best, length(max(dq, vec2(0.0))) + min(max(dq.x, dq.y), 0.0));
	return best;
}

// T-443: the capital's floor is MADE, not mowed — the T-202 trodden-earth streets become
// cobbled avenues. Paving covers the traveled way plus a ~2.2m frontage apron, so townhouse
// rows front onto pavement instead of lawn. TREATMENT-ONLY: the street geometry (HK_SEG /
// HK_HW / plaza rect) is untouched, so the WorldView / world-audit three-way sync holds.
// Streets exist only inside the circuit (hard z clamp at the gate), same as before.
float hk_pave_mask(vec3 p) {
	if (p.z > -136.0 || abs(p.x) > 126.0 || p.z < -344.0) {
		return 0.0;
	}
	float wob = (texture(breakup_tex, p.xz * 0.011 + vec2(0.61, 0.13)).r - 0.5) * 2.0;
	float d = hk_street_d(p.xz) - 2.2 + wob * 1.1;
	return 1.0 - smoothstep(0.0, 1.6, d);
}

// Packed-earth verge past the paving edge: grass -> trodden shoulder -> cobble, so the
// pavement never hard-stamps onto the pocket greens (the T-406 fringe lesson, medieval grade).
float hk_verge_mask(vec3 p) {
	if (p.z > -136.0 || abs(p.x) > 126.0 || p.z < -344.0) {
		return 0.0;
	}
	float wob = (texture(breakup_tex, p.xz * 0.017 + vec2(1.9, 5.1)).r - 0.5) * 2.0;
	float d = hk_street_d(p.xz) - 2.2 + wob * 2.2;
	return 1.0 - smoothstep(-0.4, 3.4, d);
}

// The market plaza reads dressed FLAGSTONE — bigger slabs, lighter and warmer than the
// avenues — so the civic room is distinct from the circulation feeding it.
float hk_plaza_mask(vec3 p) {
	float wob = (texture(breakup_tex, p.xz * 0.031 + vec2(4.4, 2.6)).r - 0.5) * 2.0;
	vec2 dq = abs(p.xz - HK_PLAZA_RECT.xy) - HK_PLAZA_RECT.zw;
	float d = length(max(dq, vec2(0.0))) + min(max(dq.x, dq.y), 0.0) + wob * 0.9;
	return 1.0 - smoothstep(0.0, 1.5, d);
}

// T-179: a wet-sand/mud annulus hugging Crystal Lake's waterline. Same painterly idiom as the
// road: a noise-wobbled radius + a soft plateau, so the band meanders like a real shore instead of
// a compass-drawn ring. The plateau reaches from just inside the water (under the shallows) out
// onto the exposed bank, where grass takes over.
float shore_mask(vec3 p) {
	float dist = distance(p.xz, lake_center);
	float wob = (texture(breakup_tex, p.xz * 0.14 + vec2(4.2, 1.7)).r - 0.5) * 2.0;
	float d = dist + wob * 1.4;       // wobble the radius → an organic, non-circular shore
	float inner = lake_radius - 5.5;  // ~6.5 m: under the water, fades toward the bed
	// Outer fade pulled in (was +1.2) after the wall re-shoot: with the waterline at ~9.8 m mean,
	// +0.5 (= the grass-clear ring) keeps the exposed dry band ~1-3 m — a shore, not a crater.
	float outer = lake_radius + 0.5;  // ~12.5 m: onto the bank, fades into the grass
	float rise = smoothstep(inner - 1.5, inner + 0.5, d);
	float fall = 1.0 - smoothstep(outer - 1.5, outer + 0.6, d);
	return clamp(rise * fall, 0.0, 1.0);
}

// T-342: capital river banks — a wet-mud/gravel band hugging the river channel (RIV_SEG), same
// painterly wobbled-edge idiom as the lake shore_mask but along a polyline instead of a radius, so
// the flat-banked v1 river reads as a carved channel with damp banks. KEEP IN SYNC with
// WorldView.RIVER_PTS (world_view.gd) and scripts/world-audit.py RIVER (three-way splat sync).
const int RIV_NSEG = 12;
const vec4 RIV_SEG[12] = vec4[](
	vec4(57.0, -382.0, 54.0, -362.0),
	vec4(54.0, -362.0, 44.0, -300.0),
	vec4(44.0, -300.0, 34.0, -256.0),
	vec4(34.0, -256.0, 26.0, -218.0),
	vec4(26.0, -218.0, 23.0, -210.0),
	vec4(23.0, -210.0, 21.0, -175.0),
	vec4(21.0, -175.0, 19.0, -140.0),
	vec4(19.0, -140.0, 18.0, -112.0),
	vec4(18.0, -112.0, 5.2, -109.0),
	vec4(5.2, -109.0, -10.0, -107.0),
	vec4(-10.0, -107.0, -30.0, -100.0),
	vec4(-30.0, -100.0, -52.0, -92.0));
const float RIV_HALF = 3.6;

float riv_d(vec2 p) {
	float best = 1e9;
	for (int i = 0; i < RIV_NSEG; i++) {
		vec2 a = RIV_SEG[i].xy;
		vec2 b = RIV_SEG[i].zw;
		vec2 ab = b - a;
		float t = clamp(dot(p - a, ab) / dot(ab, ab), 0.0, 1.0);
		best = min(best, distance(p, a + ab * t));
	}
	return best;
}

// Wet band annulus along the channel: from just inside the waterline out onto the exposed bank
// (grass takes over past it), wobbled so the bank meanders like a real shore.
float river_mask(vec3 p) {
	float wob = (texture(breakup_tex, p.xz * 0.05 + vec2(3.7, 2.2)).r - 0.5) * 2.0;
	float d = riv_d(p.xz) + wob * 1.2;
	float inner = RIV_HALF * 0.72;  // ~2.6 m: under the water edge, fades toward the bed
	float outer = RIV_HALF + 1.7;   // ~5.3 m: onto the bank, fades into the grass
	float rise = smoothstep(inner - 1.2, inner + 0.4, d);
	float fall = 1.0 - smoothstep(outer - 1.4, outer + 0.6, d);
	return clamp(rise * fall, 0.0, 1.0);
}

// T-314: village branch paths — worn dirt spurs off the main N-S road to every off-spine
// building's threshold, plus the farm lane (village -> inn -> barn -> farmhouse) and the
// watch-tower spur. Same segment-SDF idiom as the Highkeep street graph (HK_SEG/HK_HW)
// above, but narrower (spurs ~1.2-1.9m wide, farm lane ~2m) and widened a touch on the last
// segment into each threshold so the wear reads as a worn doorstep, not a ruled line.
// KEEP IN SYNC with WorldView.VP_SEGS (client/scripts/world/world_view.gd) — that mirror
// keeps grass clutter from scattering tufts back over these paths.
const int VP_NSEG = 29;
const vec4 VP_SEG[29] = vec4[](
	// smithy spur (-8.8,-9)
	vec4(0.0, -9.5, -2.2, -9.8), vec4(-2.2, -9.8, -4.7, -9.0),
	// house_a spur (-8.8,13)
	vec4(0.0, 12.5, -2.8, 11.8), vec4(-2.8, 11.8, -5.6, 13.0),
	// house_b spur (-8.8,3)
	vec4(0.0, 3.3, -2.6, 3.8), vec4(-2.6, 3.8, -5.3, 3.0),
	// market spur (-10.2,24)
	vec4(0.0, 23.0, -3.0, 22.0), vec4(-3.0, 22.0, -6.0, 23.3), vec4(-6.0, 23.3, -9.0, 24.3),
	// desire-line: well apron -> market stall (2.5,8)
	vec4(2.0, 7.2, 2.6, 8.0),
	// cottage spur (8.8,9)
	vec4(0.0, 8.5, 2.6, 9.2), vec4(2.6, 9.2, 5.4, 9.0),
	// tavern spur (8.8,-3)
	vec4(0.0, -2.5, 2.3, -3.3), vec4(2.3, -3.3, 4.7, -3.0),
	// church spur (8.8,-16)
	vec4(0.0, -15.5, 2.6, -16.4), vec4(2.6, -16.4, 5.1, -16.0),
	// farm lane: village -> inn (34,4) -> barn (40,14) -> farmhouse (44,20)
	vec4(0.0, 4.0, 9.0, 2.2), vec4(9.0, 2.2, 18.0, 5.0), vec4(18.0, 5.0, 26.0, 3.0),
	vec4(26.0, 3.0, 31.0, 4.0), vec4(31.0, 4.0, 34.0, 4.2), vec4(34.0, 4.2, 37.0, 8.0),
	// the barn's rotated footprint reaches surprisingly far NE (rot 200 on an 8x11 hull) — the
	// lane threshold stops at the door (SW gable) then skirts SOUTH and EAST around the barn
	// before curving up into the farmhouse's door side, rather than cutting a chord through it.
	vec4(37.0, 8.0, 37.8, 8.6), vec4(37.8, 8.6, 44.0, 6.0), vec4(44.0, 6.0, 47.0, 12.0),
	vec4(47.0, 12.0, 46.0, 17.5),
	// watch-tower spur off the winding road (~x=-0.9 at z=-30) to (20,-30)
	vec4(-0.9, -30.0, 6.0, -29.0), vec4(6.0, -29.0, 13.0, -30.5), vec4(13.0, -30.5, 19.2, -30.0));
const float VP_HW[29] = float[](
	0.80, 0.95, 0.80, 0.95, 0.80, 0.95, 0.80, 0.90, 1.00, 0.60, 0.80, 0.95, 0.80, 0.95, 0.80, 0.95,
	1.00, 1.00, 1.00, 1.00, 1.10, 1.00, 1.15, 1.00, 1.00, 1.05, 0.90, 0.90, 1.00);

float vp_path_d(vec2 p) {
	float best = 1e9;
	for (int i = 0; i < VP_NSEG; i++) {
		vec2 a = VP_SEG[i].xy;
		vec2 b = VP_SEG[i].zw;
		vec2 ab = b - a;
		float t = clamp(dot(p - a, ab) / dot(ab, ab), 0.0, 1.0);
		best = min(best, distance(p, a + ab * t) - VP_HW[i]);
	}
	return best;
}

// Narrower soft edge than the road/street masks (1.2m vs 1.8-2.2m) so the spurs read as
// footpaths, plus a finer wobble frequency so a 1.5m-wide track still meanders visibly.
float vp_path_mask(vec3 p) {
	float wob = (texture(breakup_tex, p.xz * 0.02 + vec2(0.23, 0.77)).r - 0.5) * 2.0;
	float d = vp_path_d(p.xz) + wob * 0.6;
	return 1.0 - smoothstep(0.0, 1.2, d);
}

// T-313: eastern farmstead worked-land regions — axis-aligned box SDFs (cx, cz, half_x, half_z).
// KEEP IN SYNC with WorldView.FIELD_RECTS/PADDOCK_RECT (client/scripts/world/world_view.gd) —
// that mirror keeps grass clutter from scattering tufts back over plowed earth or the pen.
const int FIELD_NRECT = 2;
const vec4 FIELD_RECT[2] = vec4[](
	vec4(29.0, 15.0, 4.5, 3.0),  // planted wheat plot
	vec4(29.0, 9.0, 4.5, 3.0));  // fallow plot
const vec4 PADDOCK_RECT = vec4(26.0, 4.0, 5.0, 4.0);  // fenced sheep pasture
// a wide worn dirt "yard" tying the barn/haystack/field together — the farmer's own trodden
// ground, distinct from (but overlapping) T-314's narrow farm-lane footpath spur.
const vec4 FARMYARD_RECT = vec4(38.0, 12.0, 8.0, 7.0);
// T-347: ASHMOOR (era-2 first slice) ground splat — the distant flat OFFSET REGION at (-420, 0).
// A NEW era-2 splat set (not the medieval dirt family): a broad SOOT-DARK packed district ground,
// with a cooler COBBLE High Street strip painted on top (wet gaslight sheen = lower roughness).
// KEEP IN SYNC with WorldView.ASHMOOR_SOOT_RECT/ASHMOOR_COBBLE_RECT (grass-clutter suppression)
// — the three-way splat rule. axis-aligned box SDFs (cx, cz, half_x, half_z).
const vec4 ASHMOOR_SOOT_RECT = vec4(-420.0, -2.0, 40.0, 22.0);   // whole district, sooty ground
const vec4 ASHMOOR_COBBLE_RECT = vec4(-420.0, 0.0, 26.0, 6.0);   // the High Street cobble strip

float box_d(vec2 p, vec4 rect) {
	vec2 d = abs(p - rect.xy) - rect.zw;
	return length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0);
}

// Same painterly wobbled-edge idiom as the road/street masks: a plowed-earth patch, not a
// ruler-drawn rectangle.
float field_mask(vec3 p) {
	float wob = (texture(breakup_tex, p.xz * 0.05 + vec2(2.1, 0.4)).r - 0.5) * 2.0;
	float best = 1e9;
	for (int i = 0; i < FIELD_NRECT; i++) {
		best = min(best, box_d(p.xz, FIELD_RECT[i]));
	}
	float d = best + wob * 0.9;
	return 1.0 - smoothstep(0.0, 1.4, d);
}

float paddock_mask(vec3 p) {
	float wob = (texture(breakup_tex, p.xz * 0.05 + vec2(5.3, 1.1)).r - 0.5) * 2.0;
	float d = box_d(p.xz, PADDOCK_RECT) + wob * 0.9;
	return 1.0 - smoothstep(0.0, 1.4, d);
}

float farmyard_mask(vec3 p) {
	float wob = (texture(breakup_tex, p.xz * 0.03 + vec2(0.8, 3.6)).r - 0.5) * 2.0;
	float d = box_d(p.xz, FARMYARD_RECT) + wob * 1.6;
	return 1.0 - smoothstep(0.0, 2.4, d);
}

// T-347: ASHMOOR district ground — a broad soot-dark patch (same wobbled-edge idiom as the farm
// yard so it doesn't ruler-draw against the meadow at the region's fringe).
float ashmoor_soot_mask(vec3 p) {
	float wob = (texture(breakup_tex, p.xz * 0.03 + vec2(7.2, 4.9)).r - 0.5) * 2.0;
	float d = box_d(p.xz, ASHMOOR_SOOT_RECT) + wob * 1.8;
	return 1.0 - smoothstep(0.0, 2.6, d);
}

// T-406: a WIDE ash-trampled fringe outside the soot core — soot-killed, greyed grass in a
// meandering 4-9m band, so the district floor feathers into the meadow instead of the old
// green->black hard stamp (the "stamped onto a meadow" seam the ticket calls out).
float ashmoor_fringe_mask(vec3 p) {
	float wob = (texture(breakup_tex, p.xz * 0.021 + vec2(2.8, 6.3)).r - 0.5) * 2.0;
	float d = box_d(p.xz, ASHMOOR_SOOT_RECT) + wob * 3.2;
	return 1.0 - smoothstep(-1.0, 6.5, d);
}

// T-347: the High Street cobble strip — a tighter, harder-edged band on top of the soot ground.
float ashmoor_cobble_mask(vec3 p) {
	float wob = (texture(breakup_tex, p.xz * 0.06 + vec2(3.1, 8.4)).r - 0.5) * 2.0;
	float d = box_d(p.xz, ASHMOOR_COBBLE_RECT) + wob * 0.7;
	return 1.0 - smoothstep(0.0, 1.2, d);
}

// T-491: Highkeep ward yards — the non-street ground inside the poor housing wards was uniform
// manicured lawn (the "display homes on a golf course" read). The wards now floor as trodden
// PACKED EARTH (a cooler, greyer urban ground = packed dirt + gravel service yards), painted
// UNDER the T-443 cobble so the paved row lanes survive, and confined BOTH to the three ward
// rects and to the wall circuit. Small kitchen-garden BEDS of turned soil are kept where a
// household would keep one. These are non-street regions (like the T-313 farmstead rects), so
// world-audit reads the plan's plots/streets, not these; the WorldView.HK_WARD_RECT /
// HK_GARDEN_RECT mirror + the shader source pins hold the splat sync. axis-aligned box SDFs.
const int HK_NWARD = 3;
const vec4 HK_WARD_RECT[3] = vec4[](
	vec4(-72.0, -190.0, 38.0, 32.0),   // ward_nw
	vec4(74.0, -196.0, 36.0, 30.0),    // ward_e
	vec4(-34.0, -322.0, 46.0, 14.0));  // ward_s
const int HK_NGARDEN = 3;
const vec4 HK_GARDEN_RECT[3] = vec4[](
	vec4(-114.0, -200.0, 4.0, 8.0),    // ward_nw kitchen garden (west wall margin)
	vec4(114.0, -196.0, 4.0, 9.0),     // ward_e kitchen garden (east wall margin)
	vec4(-62.0, -336.0, 10.0, 2.6));   // ward_s kitchen garden (south wall margin)

float hk_ward_d(vec2 p) {
	float best = 1e9;
	for (int i = 0; i < HK_NWARD; i++) {
		best = min(best, box_d(p, HK_WARD_RECT[i]));
	}
	return best;
}

// Trodden packed-earth ward yards. Confined to the circuit (defensive clamp, same as the paving
// masks) and softly wobbled so the yard feathers into the pocket greens instead of ruler-drawing.
float hk_ward_mask(vec3 p) {
	if (p.z > -136.0 || abs(p.x) > 126.0 || p.z < -344.0) {
		return 0.0;
	}
	float wob = (texture(breakup_tex, p.xz * 0.03 + vec2(6.7, 2.3)).r - 0.5) * 2.0;
	float d = hk_ward_d(p.xz) + wob * 1.8;
	return 1.0 - smoothstep(0.0, 2.4, d);
}

// Kept kitchen-garden beds — small turned-soil plots against the wall margins where a household
// would keep one (the prop_yard_garden greens ride on top). A clear "worked, not trodden" read.
float hk_garden_mask(vec3 p) {
	float wob = (texture(breakup_tex, p.xz * 0.05 + vec2(3.9, 7.1)).r - 0.5) * 2.0;
	float best = 1e9;
	for (int i = 0; i < HK_NGARDEN; i++) {
		best = min(best, box_d(p.xz, HK_GARDEN_RECT[i]));
	}
	float d = best + wob * 0.7;
	return 1.0 - smoothstep(0.0, 1.2, d);
}

void fragment() {
	vec3 g = texture(grass_tex, wpos.xz / grass_tile).rgb;
	// T-185: second, macro-frequency sample keeps the meadow alive at distance (a single
	// 2.6m scan mip-averages to a flat green from the camera height) and breaks tiling.
	vec3 g2 = texture(grass_tex, wpos.xz / (grass_tile * 6.7) + vec2(0.37, 0.11)).rgb;
	g = mix(g, g2, 0.35);
	vec3 d = texture(dirt_tex, wpos.xz / dirt_tile).rgb;
	d *= vec3(0.82, 0.78, 0.72);  // pull the pale scan toward the palette's trodden earth
	// Large-scale painted value variation across the meadow (anti-tiling).
	float br = texture(breakup_tex, wpos.xz / 90.0).r;
	g *= mix(0.86, 1.10, br);
	d *= mix(0.92, 1.06, texture(breakup_tex, wpos.xz / 31.0).r);
	float m = road_mask(wpos);
	// T-443: the city street DIRT paint is now just the verge/shoulder band — packed urban
	// earth between the paving edge and the pocket greens (cobble rides on top below).
	float sm = hk_verge_mask(wpos);
	// T-314: village branch paths — same warm dirt family as the main road (worn by feet, not
	// cart wheels), narrower and softer-edged than either the road or the city streets.
	float vp = vp_path_mask(wpos);
	// Dither the blend border with fine noise: grass bites into the path edge painterly-style.
	float n = texture(breakup_tex, wpos.xz / 3.0).r;
	m = clamp(m + (n - 0.5) * 1.4 * m * (1.0 - m), 0.0, 1.0);
	sm = clamp(sm + (n - 0.5) * 1.2 * sm * (1.0 - sm), 0.0, 1.0);
	vp = clamp(vp + (n - 0.5) * 1.6 * vp * (1.0 - vp), 0.0, 1.0);
	// T-313: farmstead worked land -- trodden yard (same warm dirt family as the farm lane),
	// plowed field (darker, richer, redder-brown than any trodden path -- turned earth, not
	// packed feet-worn ground), and the pen (packed dirt, animals wear it bare).
	float fy = farmyard_mask(wpos);
	float fld = field_mask(wpos);
	float pdk = paddock_mask(wpos);
	fy = clamp(fy + (n - 0.5) * 1.2 * fy * (1.0 - fy), 0.0, 1.0);
	fld = clamp(fld + (n - 0.5) * 1.0 * fld * (1.0 - fld), 0.0, 1.0);
	pdk = clamp(pdk + (n - 0.5) * 1.3 * pdk * (1.0 - pdk), 0.0, 1.0);
	vec3 albedo = mix(g, d, m);
	vec3 st = texture(dirt_tex, wpos.xz / (dirt_tile * 0.9)).rgb * vec3(0.72, 0.70, 0.67);
	albedo = mix(albedo, st, sm);
	albedo = mix(albedo, d, vp);
	albedo = mix(albedo, d, fy);  // worn yard first (widest, lowest-priority patch)
	vec3 pen = d * vec3(0.80, 0.74, 0.66);
	albedo = mix(albedo, pen, pdk);
	// T-313 fix: the original (0.46,0.34,0.26) multiplier read near-black in-world (roughness
	// 0.95 + no specular leaves nothing to catch the light) — a burnt patch, not plowed earth.
	// Brightened ~1.4x on the same hue (still darker + a touch redder than the road's
	// (0.82,0.78,0.72) dirt tint) so it reads as a rich umber-brown turned-earth patch.
	vec3 tilled = texture(dirt_tex, wpos.xz / (dirt_tile * 0.55)).rgb * vec3(0.64, 0.48, 0.36);
	albedo = mix(albedo, tilled, fld);  // plowed earth painted on top -- reads darkest of all
	float rough = 1.0;
	rough = mix(rough, 0.95, fld);  // turned earth: matte, no sheen
	// T-491: Highkeep ward yards — trodden packed earth replaces the manicured lawn between the
	// ward cottages and the curtain wall. Painted UNDER the cobble below (so the paved row lanes
	// survive) and BEFORE it, so hk_pave/hk_plaza override the earth on the traveled way. A
	// cooler, greyer urban ground than the warm rural road dirt = packed dirt + gravel yards.
	float wyard = hk_ward_mask(wpos);
	wyard = clamp(wyard + (n - 0.5) * 1.2 * wyard * (1.0 - wyard), 0.0, 1.0);
	vec3 ward_earth = texture(dirt_tex, wpos.xz / (dirt_tile * 0.85)).rgb * vec3(0.66, 0.63, 0.60);
	ward_earth *= mix(0.86, 1.08, texture(breakup_tex, wpos.xz / 19.0).r);
	albedo = mix(albedo, ward_earth, wyard);
	rough = mix(rough, 0.93, wyard);  // packed earth: matte
	if (wyard > 0.001) {
		// Desire-path wear: darker, foot-polished trodden tracks webbing the yard door-to-lane
		// (reads as worn shortcuts from overhead), plus mud pooled at the wall base + thresholds.
		float worn = smoothstep(0.5, 0.92, texture(breakup_tex, wpos.xz / 6.0 + vec2(1.7, 0.4)).r);
		albedo *= mix(1.0, 0.74, worn * wyard);
		float mud = smoothstep(0.74, 0.9, texture(breakup_tex, wpos.xz / 8.0 + vec2(0.3, 2.1)).r);
		mud *= wyard;
		albedo = mix(albedo, ward_earth * vec3(0.55, 0.50, 0.44), mud * 0.7);
		rough = mix(rough, 0.82, mud);
	}
	// Kept kitchen-garden beds — turned soil (darker, redder umber), painted on top of the ward
	// earth where a household keeps a plot; the prop_yard_garden greens ride over this.
	float gard = hk_garden_mask(wpos);
	gard = clamp(gard + (n - 0.5) * 1.0 * gard * (1.0 - gard), 0.0, 1.0);
	vec3 bed = texture(dirt_tex, wpos.xz / (dirt_tile * 0.5)).rgb * vec3(0.60, 0.45, 0.34);
	albedo = mix(albedo, bed, gard);
	rough = mix(rough, 0.95, gard);
	// T-443: Highkeep paved streetscape — cobbled avenues + a flagstone market plaza painted
	// over the verge earth. Medieval warm-grey grade (the era-2 Ashmoor strip below stays
	// cooler + soot-desaturated). Same macro-sample + breakup value-mod anti-tiling as T-406.
	float hkc = hk_pave_mask(wpos);
	float hkp = hk_plaza_mask(wpos);
	hkc = clamp(hkc + (n - 0.5) * 1.1 * hkc * (1.0 - hkc), 0.0, 1.0);
	hkp = clamp(hkp + (n - 0.5) * 0.9 * hkp * (1.0 - hkp), 0.0, 1.0);
	vec3 hk_cob1 = texture(cobble_tex, wpos.xz / cobble_tile).rgb;
	vec3 hk_cob2 = texture(cobble_tex, wpos.xz / (cobble_tile * 6.7) + vec2(0.73, 0.19)).rgb;
	vec3 hk_cob = mix(hk_cob1, hk_cob2, 0.30) * vec3(0.78, 0.74, 0.68);
	hk_cob *= mix(0.86, 1.10, texture(breakup_tex, wpos.xz / 27.0).r);
	albedo = mix(albedo, hk_cob, hkc);
	rough = mix(rough, 0.74, hkc);
	// The plaza is dressed flagstone: larger slabs (bigger tile), lighter + warmer still.
	vec3 hk_flag = texture(cobble_tex, wpos.xz / (cobble_tile * 2.3)).rgb * vec3(0.88, 0.84, 0.76);
	hk_flag *= mix(0.90, 1.06, texture(breakup_tex, wpos.xz / 17.0).r);
	albedo = mix(albedo, hk_flag, hkp);
	rough = mix(rough, 0.70, hkp);
	if (hkc > 0.001) {
		// Traffic wear (T-192 rut idiom, city grade): darker, foot-polished setts on the busy
		// lines — strongest through the market and toward the gate, fading toward the keep
		// (wealth gradient: the keep's approach is swept, the gate approach is churned).
		float busy = smoothstep(-292.0, -215.0, wpos.z);
		float wear = smoothstep(0.45, 0.9, texture(breakup_tex, wpos.xz / 7.0).r) * busy;
		albedo *= mix(1.0, 0.78, wear * hkc);
		rough = mix(rough, 0.55, wear * hkc * 0.8);
		// Mud tracked in at the gate: the dirt road outside churns over the first cobbles.
		float gate_mud = smoothstep(-172.0, -146.0, wpos.z) * hkc;
		gate_mud *= mix(0.35, 1.0, texture(breakup_tex, wpos.xz / 5.0).r);
		vec3 mud = texture(dirt_tex, wpos.xz / (dirt_tile * 1.2)).rgb * vec3(0.46, 0.40, 0.33);
		albedo = mix(albedo, mud, gate_mud * 0.75);
		rough = mix(rough, 0.88, gate_mud);
	}
	// T-347: ASHMOOR era-2 ground — soot district first (broad, low priority), then the cobble
	// High Street on top. Reuses the dirt scan re-tinted (the PoC's caveat: the true era-2 cobble
	// scan is T-348); the fine-noise dithered border keeps grass biting the fringe painterly-style.
	float soot = ashmoor_soot_mask(wpos);
	float cob = ashmoor_cobble_mask(wpos);
	soot = clamp(soot + (n - 0.5) * 1.2 * soot * (1.0 - soot), 0.0, 1.0);
	cob = clamp(cob + (n - 0.5) * 1.0 * cob * (1.0 - cob), 0.0, 1.0);
	// T-406: feathered seam — an ash-trampled fringe kills the grass/soot hard border. The
	// meadow greys out and dies over ~4-9m (desaturate + ash tint) before the soot core lands.
	float fri = ashmoor_fringe_mask(wpos);
	fri = clamp(fri + (n - 0.5) * 1.4 * fri * (1.0 - fri), 0.0, 1.0);
	vec3 ashg = mix(albedo, vec3(dot(albedo, vec3(0.333))), 0.6) * vec3(0.60, 0.58, 0.55);
	albedo = mix(albedo, ashg, fri * 0.75);
	vec3 soot_c = texture(dirt_tex, wpos.xz / (dirt_tile * 0.9)).rgb * vec3(0.34, 0.32, 0.30);
	albedo = mix(albedo, soot_c, soot);
	rough = mix(rough, 0.9, soot);
	// T-406: REAL cobble (PH cobblestone_floor_08) — macro second sample + breakup value mod
	// kill the 2m tiling read across the ~52m strip; soot-desaturated grade keeps the palette.
	vec3 cob1 = texture(cobble_tex, wpos.xz / cobble_tile).rgb;
	vec3 cob2 = texture(cobble_tex, wpos.xz / (cobble_tile * 6.7) + vec2(0.21, 0.43)).rgb;
	vec3 cob_c = mix(cob1, cob2, 0.30) * vec3(0.56, 0.57, 0.61);
	cob_c *= mix(0.84, 1.08, texture(breakup_tex, wpos.xz / 23.0).r);
	albedo = mix(albedo, cob_c, cob);
	rough = mix(rough, 0.78, cob);
	// T-406: traffic wear down the carriageway (T-192 rut idiom rotated E-W): polished darker
	// setts in twin wheel-lines, oily puddles pooling in the worn line + gutter (gaslight sheen).
	if (cob > 0.001) {
		float lz = wpos.z + 1.0;  // traffic line: carriageway center, north of the pavement
		float rut_wob = (texture(breakup_tex, vec2(wpos.x / 7.0, 0.53)).r - 0.5) * 0.6;
		float groove = exp(-pow((abs(lz) - (0.9 + rut_wob)) / 0.38, 2.0));
		float wear = mix(0.45, 1.0, texture(breakup_tex, wpos.xz / 6.0).r);
		float rut = groove * wear * cob;
		albedo *= mix(1.0, 0.74, rut);       // grime-darkened, iron-polished wheel lines
		rough = mix(rough, 0.5, rut);
		float pud = smoothstep(0.70, 0.86, texture(breakup_tex, wpos.xz / 9.0 + vec2(0.8, 0.5)).r);
		pud *= cob * max(rut, 0.4);
		albedo = mix(albedo, albedo * vec3(0.45, 0.46, 0.52), pud);  // oily standing water
		rough = mix(rough, 0.16, pud);
	}
	// T-179: paint the lake shore ring ON TOP — a darkened, warm wet-mud tint (reuses dirt_tex),
	// with the same fine-noise dithered border so grass bites into the wet band painterly-style.
	float shore = shore_mask(wpos);
	float sn = texture(breakup_tex, wpos.xz / 2.5).r;
	shore = clamp(shore + (sn - 0.5) * 1.3 * shore * (1.0 - shore), 0.0, 1.0);
	vec3 wet = texture(dirt_tex, wpos.xz / (dirt_tile * 1.4)).rgb * vec3(0.42, 0.36, 0.30);
	albedo = mix(albedo, wet, shore);
	rough = mix(rough, 0.82, shore);  // damp the wet band's shine a touch vs the dry meadow
	// T-342: river banks — a cooler, wetter mud/gravel band along the channel (same dithered
	// border idiom as the lake shore so grass bites into the wet edge painterly-style).
	float riv = river_mask(wpos);
	float rn = texture(breakup_tex, wpos.xz / 2.5 + vec2(1.3, 0.7)).r;
	riv = clamp(riv + (rn - 0.5) * 1.3 * riv * (1.0 - riv), 0.0, 1.0);
	vec3 rwet = texture(dirt_tex, wpos.xz / (dirt_tile * 1.3)).rgb * vec3(0.40, 0.37, 0.34);
	albedo = mix(albedo, rwet, riv);
	rough = mix(rough, 0.80, riv);
	// T-192: cart-road wear — paired wheel ruts + compacted crown + sparse puddles, ALL confined
	// to the road mask (m) so non-road meadow is untouched. Road-local lateral = the signed
	// distance from the winding centerline, so ruts follow the road's direction automatically.
	if (m > 0.001) {
		float lx = wpos.x - road_center_x(wpos.z);  // road-local lateral offset (direction-aware)
		// two grooves at +/- the wheel gauge, wobbled along z so they never zebra-stripe.
		float rut_wob = (texture(breakup_tex, vec2(wpos.z / 6.5, 0.31)).r - 0.5) * 0.5;
		float rut_off = 0.95 + rut_wob;  // ~0.95 m cart gauge, irregular
		float groove = exp(-pow((abs(lx) - rut_off) / 0.16, 2.0));
		// worn unevenly ALONG the road (mid-freq), not a continuous painted line.
		float wear = mix(0.45, 1.0, texture(breakup_tex, wpos.xz / 5.0).r);
		float rut = groove * wear * m;
		albedo *= mix(1.0, 0.70, rut);  // pressed earth reads darker in the ruts
		rough = mix(rough, 0.97, rut);
		// compacted crown between the ruts: packed, a touch darker/smoother.
		float crown = exp(-pow(lx / 0.5, 2.0)) * m;
		albedo *= mix(1.0, 0.90, crown * 0.5);
		// sparse wet puddles: low-frequency patches sitting INSIDE the road edge, dark + shiny.
		float pud = smoothstep(0.72, 0.87, texture(breakup_tex, wpos.xz / 11.0 + vec2(0.6, 0.2)).r);
		pud *= m;
		albedo = mix(albedo, albedo * vec3(0.50, 0.50, 0.56), pud);  // cool, dark standing water
		rough = mix(rough, 0.22, pud);  // puddles are wet -> low roughness (specular sheen)
	}
	// scan normals, blended by the same masks (shore reuses the dirt normal)
	vec3 gn = texture(grass_nrm, wpos.xz / grass_tile).rgb;
	vec3 dn = texture(dirt_nrm, wpos.xz / dirt_tile).rgb;
	// T-406: the Ashmoor district ground rides the dirt normal (soot), and the High Street strip
	// gets the cobble scan's per-sett relief at a deeper normal depth — raking gaslight/sun
	// finally catches individual stones instead of a flat brown plane.
	float dirt_m = max(max(max(max(max(max(m, sm), shore), vp), fy), max(fld, pdk)), max(riv, soot));
	// T-491: the trodden ward yards + kitchen-garden beds ride the dirt scan's relief too.
	dirt_m = max(dirt_m, max(wyard, gard));
	vec3 cn = texture(cobble_nrm, wpos.xz / cobble_tile).rgb;
	// T-443: the Highkeep avenues ride the cobble scan's per-sett relief too; the plaza's
	// normal is sampled at the flagstone tile so slab edges match the albedo's larger stones.
	vec3 cnp = texture(cobble_nrm, wpos.xz / (cobble_tile * 2.3)).rgb;
	float paved = max(cob, max(hkc, hkp));
	NORMAL_MAP = mix(mix(gn, dn, dirt_m), mix(cn, cnp, hkp), paved);
	NORMAL_MAP_DEPTH = mix(0.8, 1.35, paved);
	ALBEDO = albedo;
	ROUGHNESS = rough;
	SPECULAR = 0.03;
}
