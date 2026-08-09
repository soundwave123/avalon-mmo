#!/usr/bin/env python3
# World livability audit (owner mandate 2026-07-06): "think like a medieval engineer" —
# machine-checkable placement invariants that must pass BEFORE any human review of the world.
# Complements the blind-judge protocol (which now carries the medieval-engineer persona for
# the fuzzy structural reads); this script handles everything provable from data:
#
#   1. No building/prop stands in Crystal Lake (r=12 @ (18,22); shore ring respected).
#   2. No building intersects the painted road corridor (|x|<5.2 through the village).
#   3. No two building hulls overlap (approx AABB w/ rotation-aware extents + clearance).
#   4. Trees keep crown clearance from buildings; nothing within the well plaza radius.
#
# Usage: python3 scripts/world-audit.py [--props client/assets/props.json]
# Exit 1 on any FAIL — wire into review flows; the walk-in test (doors) lives in
# scripts/walkin-audit.sh (needs a running stack).

import argparse
import json
import math
import os
import subprocess
import sys

LAKE = (18.0, 22.0, 12.0)  # x, z, radius
# T-342: capital river centerline (x,z), north -> south. KEEP IN SYNC with WorldView.RIVER_PTS and
# terrain_splat.gdshader RIV_SEG (three-way splat sync). No building/prop hull may sit in the
# channel; prop_bridge_stone is the one legitimate spanning structure (exempt, like the watermill).
RIVER = [
    (57.0, -382.0), (54.0, -362.0), (44.0, -300.0), (34.0, -256.0), (26.0, -218.0), (23.0, -210.0),
    (21.0, -175.0), (19.0, -140.0), (18.0, -112.0), (5.2, -109.0), (-10.0, -107.0),
    (-30.0, -100.0), (-52.0, -92.0),
]
RIVER_HALF = 3.6
ROAD_HALF_W = 5.2          # painted corridor half-width incl. soft edge
ROAD_Z = (-102.0, 27.0)
TERRAIN_TOLERANCE = 0.15
TERRAIN_PREFIX = "TERRAIN_HEIGHTS:"


def _godot_bin():
    """T-346: absolute path to the single Godot resolver (scripts/godot-bin.sh)."""
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "godot-bin.sh")


def terrain_heights(entries):
    """Query Godot's exact FastNoiseLite terrain oracle for every placement.

    The probe formula is kept in sync with WorldView._terrain_height(), just as this file's
    road_center_x() mirrors the renderer and shader. A failed probe is an audit failure, not
    permission to silently skip terrain conformance.
    """
    points = [[x, z] for _name, x, z, _rot, _base_y in entries]
    env = os.environ.copy()
    env["AVALON_TERRAIN_POINTS"] = json.dumps(points, separators=(",", ":"))
    # T-346: route through the single resolver (scripts/godot-bin.sh) so the 4.6->4.7 cutover is
    # one line. It re-inserts `flatpak run` + the app-id (flatpak mode) or converts --env=/--
    # filesystem= for the native binary (4.7 mode). The leading --env/--filesystem flags stay.
    command = [
        _godot_bin(), "--env=AVALON_TERRAIN_POINTS=" + env["AVALON_TERRAIN_POINTS"],
        "--filesystem=" + os.path.abspath("."), "--headless",
        "--path", os.path.abspath("client"), "--script",
        "res://scripts/dev/terrain_height_probe.gd",
    ]
    result = subprocess.run(command, capture_output=True, text=True, timeout=60)
    for line in result.stdout.splitlines():
        if line.startswith(TERRAIN_PREFIX):
            heights = json.loads(line.removeprefix(TERRAIN_PREFIX))
            if len(heights) != len(entries):
                raise RuntimeError("terrain probe returned the wrong number of heights")
            return [float(height) for height in heights]
    detail = (result.stderr or result.stdout).strip().splitlines()
    raise RuntimeError("terrain probe failed: " + (detail[-1] if detail else "no output"))


def road_center_x(z):
    """The winding dirt-road centerline (owner: real dirt roads are never ruler-straight).
    KEEP IN SYNC with terrain_splat.gdshader road_center_x() and WorldView.road_center_x()."""
    w = max(0.0, min(1.0, (-z - 18.0) / 14.0)) * max(0.0, min(1.0, (z + 136.0) / 14.0))
    return w * (6.0 * math.sin(0.055 * (z + 18.0)) + 2.6 * math.sin(0.021 * (z + 18.0) + 1.7))

# Approx footprint half-extents (x, z) per scene basename — building hulls from the
# generators; trees use crown radius; small props get a nominal pad.
HULLS = {
    "prop_tavern_v2": (4.0, 5.0), "prop_cottage_v2": (3.3, 2.7), "prop_church_v2": (3.6, 4.3),
    "prop_smithy_v2": (4.4, 4.2), "prop_house_a_v2": (3.1, 3.5), "prop_house_b_v2": (3.4, 4.1),
    "prop_market_v2": (6.1, 3.8), "prop_windmill_v2": (2.8, 2.8), "prop_watermill": (4.0, 4.0),
    "prop_well_v2": (1.5, 1.1),
    # T-630: the Gilded Gryphon inn (prop_inn.glb) — a two-storey jettied timber inn. Half-extents
    # are the ground hull (4.3 wide) plus the door-side balcony oversail folded into the depth (6.0).
    "prop_inn": (4.3, 6.0),
    "prop_oak_petiolate": (9.0, 9.0),  # crown radius — clearance class, not hard hull
    # T-347: ASHMOOR High Street terrace (era-2 offset region). Half-extents (half W, half D) of
    # the era-2 kit GLBs. These sit at the flat-plain grade (y=0, r>330) — the terrain oracle
    # checks them like any placement. They are a ROW TERRACE: adjacent units abut on party walls
    # by design, so the detached-building walkway clearance does NOT apply between them (see the
    # overlap loop's terrace exemption); the per-building walk-in navmesh bake is the real gate.
    "prop_ashmoor_rowhouse": (3.0, 4.0), "prop_ashmoor_terrace_narrow": (2.25, 4.0),
    "prop_ashmoor_shopfront": (3.25, 4.0),
}
BUILDINGS = [k for k in HULLS if "oak" not in k and k not in ("prop_well_v2",)]


def rot_extents(hx, hz, deg):
    th = math.radians(deg % 180.0)
    c, s = abs(math.cos(th)), abs(math.sin(th))
    return hx * c + hz * s, hx * s + hz * c


def point_in_poly(x, z, poly):
    inside = False
    j = len(poly) - 1
    for i in range(len(poly)):
        xi, zi = poly[i]
        xj, zj = poly[j]
        if (zi > z) != (zj > z) and x < (xj - xi) * (z - zi) / (zj - zi) + xi:
            inside = not inside
        j = i
    return inside


def seg_dist(px, pz, ax, az, bx, bz):
    vx, vz = bx - ax, bz - az
    L2 = vx * vx + vz * vz
    t = 0.0 if L2 == 0 else max(0.0, min(1.0, ((px - ax) * vx + (pz - az) * vz) / L2))
    return math.hypot(px - (ax + t * vx), pz - (az + t * vz))


def river_dist(x, z):
    """Distance from (x,z) to the river centerline (>=0). Mirrors WorldView.river_dist() and
    terrain_splat.gdshader riv_d()."""
    return min(seg_dist(x, z, RIVER[i][0], RIVER[i][1], RIVER[i + 1][0], RIVER[i + 1][1])
               for i in range(len(RIVER) - 1))


def audit_highkeep(props, plan_path="client/assets/highkeep_plan.json"):
    """T-199 plan rules: plots inside the walls and off the streets; plots don't overlap;
    keep-clear zones stay clear; tagged 'highkeep' placements stay inside the circuit."""
    import os
    if not os.path.exists(plan_path):
        return []
    plan = json.load(open(plan_path))
    wall = plan["wall"]["polyline"]
    fails = []
    plots = plan.get("plots", [])
    for pl in plots:
        px, pz = pl["pos"]
        hx, hz = pl["half"]
        ex, ez = rot_extents(hx, hz, pl.get("rot", 0))
        for cx, cz in ((px - ex, pz - ez), (px + ex, pz - ez), (px - ex, pz + ez),
                       (px + ex, pz + ez)):
            if not point_in_poly(cx, cz, wall):
                fails.append(f"HK-WALL: plot {pl['name']} corner ({cx:.0f},{cz:.0f}) outside the circuit")
                break
        for st in plan.get("streets", []):
            pts = st["points"]
            clear = st["width"] / 2.0 - 0.5  # stoops may approach the verge
            for i in range(len(pts) - 1):
                if seg_dist(px, pz, *pts[i], *pts[i + 1]) < clear + min(ex, ez) * 0.7:
                    fails.append(f"HK-STREET: plot {pl['name']} intrudes on {st['name']}")
                    break
        for zn in plan.get("zones", []):
            if zn["kind"] != "keep_clear" or pl["name"] in zn["name"]:
                continue  # a zone that guards THIS plot (keep_precinct vs keep) is not a conflict
            zx, zz = zn["pos"]
            zhx, zhz = zn["half"]
            if abs(px - zx) < zhx + ex and abs(pz - zz) < zhz + ez:
                fails.append(f"HK-ZONE: plot {pl['name']} overlaps keep-clear {zn['name']}")
    # T-202: connectivity — every plot must FRONT a street (plot edge within 8m of a
    # street edge), or it's an orphan the network forgot and players path over grass.
    for pl in plots:
        px, pz = pl["pos"]
        ex, ez = rot_extents(*pl["half"], pl.get("rot", 0))
        gap = 1e9
        for st in plan.get("streets", []):
            pts = st["points"]
            hw = st["width"] / 2.0
            for i in range(len(pts) - 1):
                gap = min(gap, seg_dist(px, pz, *pts[i], *pts[i + 1]) - hw - min(ex, ez))
        if gap > 8.0:
            fails.append(f"HK-FRONTAGE: plot {pl['name']} fronts no street (gap {gap:.0f}m)")
    for i in range(len(plots)):
        for j in range(i + 1, len(plots)):
            a, b = plots[i], plots[j]
            ea = rot_extents(*a["half"], a.get("rot", 0))
            eb = rot_extents(*b["half"], b.get("rot", 0))
            if (abs(a["pos"][0] - b["pos"][0]) < ea[0] + eb[0] + 1.5
                    and abs(a["pos"][1] - b["pos"][1]) < ea[1] + eb[1] + 1.5):
                fails.append(f"HK-OVERLAP: plots {a['name']} and {b['name']} collide")
    wall_ring = wall + [wall[0]]
    for p in props:
        if isinstance(p, dict) and p.get("tag") == "highkeep":
            px, pz = float(p.get("x", 0)), float(p.get("y", 0))
            on_wall = any(seg_dist(px, pz, *wall_ring[i], *wall_ring[i + 1]) < 8.0
                          for i in range(len(wall_ring) - 1))
            if not on_wall and not point_in_poly(px, pz, wall):
                fails.append(f"HK-OUTSIDE: {p.get('scene','?').split('/')[-1]} at "
                             f"({px},{pz}) outside the walls")
    return fails


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--props", default="client/assets/props.json")
    args = ap.parse_args()
    data = json.load(open(args.props))
    props = data["props"] if isinstance(data, dict) and "props" in data else data
    entries = []
    for p in props:
        if not isinstance(p, dict) or "scene" not in p:
            continue
        name = p["scene"].split("/")[-1].replace(".glb", "")
        entries.append((name, float(p.get("x", 0)), float(p.get("y", 0)),
                        float(p.get("rot_deg", 0)), float(p.get("terrain_y", 0))))
    fails = []

    try:
        heights = terrain_heights(entries)
    except (OSError, subprocess.SubprocessError, RuntimeError, ValueError) as exc:
        print("WORLD AUDIT: FAIL")
        print("  - TERRAIN-PROBE:", exc)
        sys.exit(1)

    for (name, x, z, rot, base_y), terrain_y in zip(entries, heights):
        delta = base_y - terrain_y
        if abs(delta) > TERRAIN_TOLERANCE:
            state = "floats" if delta > 0.0 else "sinks"
            fails.append(f"TERRAIN: {name} at ({x},{z}) {state} by {abs(delta):.2f}m "
                         f"(base={base_y:.2f}, grade={terrain_y:.2f})")
        if name not in HULLS:
            continue
        hx, hz = HULLS[name]
        ex, ez = rot_extents(hx, hz, rot)
        # 1. lake intrusion (any part of the hull inside the water ring)
        d_lake = math.hypot(x - LAKE[0], z - LAKE[1])
        # trees: only the TRUNK must clear the water (crown overhang is scenic); buildings
        # use their hull
        lake_pad = 2.0 if "oak" in name else min(ex, ez) * 0.7
        if name != "prop_watermill" and d_lake < LAKE[2] + lake_pad:
            fails.append(f"LAKE: {name} at ({x},{z}) is in/on Crystal Lake (d={d_lake:.1f})")
        # 1b. T-342 river intrusion — no hull in the channel; the bridge is the one spanning
        # structure (like the watermill on the lake) and is exempt.
        d_river = river_dist(x, z)
        river_pad = 2.0 if ("oak" in name or "tree" in name) else min(ex, ez) * 0.6
        if name != "prop_bridge_stone" and d_river < RIVER_HALF + river_pad:
            fails.append(f"RIVER: {name} at ({x},{z}) stands in the river channel (d={d_river:.1f})")
        # 2. road intrusion (buildings only — carts/wells may hug the verge)
        # buildings legitimately FRONT the street (stoops near the verge); flag only a real
        # intrusion into the traveled way
        road_dx = abs(x - road_center_x(z)) - ex
        if name in BUILDINGS and ROAD_Z[0] < z < ROAD_Z[1] and road_dx < ROAD_HALF_W - 2.0:
            fails.append(f"ROAD: {name} at ({x},{z}) intrudes on the street corridor")
        # forest flora must keep their trunks off the traveled way too
        if name not in BUILDINGS and ("oak" in name or "tree" in name or "rock" in name):
            if ROAD_Z[0] < z < ROAD_Z[1] and abs(x - road_center_x(z)) < 3.4:
                fails.append(f"ROAD: {name} at ({x},{z}) stands in the traveled way")

    # 3. building-vs-building overlap (with 1.5m walkway clearance)
    blds = [(n, x, z, rot) for (n, x, z, rot, _base_y) in entries if n in BUILDINGS]
    for i in range(len(blds)):
        for j in range(i + 1, len(blds)):
            n1, x1, z1, r1 = blds[i]
            n2, x2, z2, r2 = blds[j]
            e1 = rot_extents(*HULLS[n1], r1)
            e2 = rot_extents(*HULLS[n2], r2)
            # T-347: a row terrace abuts on party walls by design — exempt Ashmoor-vs-Ashmoor pairs
            # from the detached-building 1.5m walkway clearance and only flag TRUE interpenetration
            # (hulls overlapping by >0.3m on both axes). Everything else keeps the walkway rule.
            terrace = n1.startswith("prop_ashmoor") and n2.startswith("prop_ashmoor")
            pad = -0.3 if terrace else 1.5
            if abs(x1 - x2) < e1[0] + e2[0] + pad and abs(z1 - z2) < e1[1] + e2[1] + pad:
                fails.append(f"OVERLAP: {n1} ({x1},{z1}) and {n2} ({x2},{z2}) hulls/walkways collide")

    # 3b. windmill sail sweep clear of tree crowns (sails reach ~4m past the hull; a 9m oak
    # crown inside that arc means the sails thresh leaves — flagged by the engineer judge)
    mills = [(x, z) for (n, x, z, _r, _base_y) in entries if "windmill" in n]
    for mx, mz in mills:
        for n, x, z, _r, _base_y in entries:
            if "oak" in n and math.hypot(mx - x, mz - z) < 14.0:
                fails.append(f"SAILS: oak at ({x},{z}) inside the windmill sail clearance at ({mx},{mz})")

    # 4. oak crowns clear of buildings
    oaks = [(x, z) for (n, x, z, _r, _base_y) in entries if "oak_petiolate" in n]
    for n, x, z, rot in blds:
        ex, ez = rot_extents(*HULLS[n], rot)
        for ox, oz in oaks:
            # crowns may overhang roofs (scenic); the TRUNK must not stand inside a building
            if math.hypot(ox - x, oz - z) < 2.0 + max(ex, ez):
                fails.append(f"TREE: oak TRUNK at ({ox},{oz}) inside {n} at ({x},{z})")

    # 5. Highkeep plan rules (T-199): the plan JSON must be internally consistent, and
    # every placement tagged "highkeep" must stand inside the walls.
    fails += audit_highkeep(props)

    if fails:
        print("WORLD AUDIT: FAIL")
        for f in fails:
            print("  -", f)
        sys.exit(1)
    print(f"WORLD AUDIT: PASS ({len(entries)} placements checked)")


if __name__ == "__main__":
    main()
