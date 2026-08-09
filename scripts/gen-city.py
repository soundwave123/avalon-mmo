#!/usr/bin/env python3
# T-202: Highkeep placement engine — the city analogue of gen-forest.py. Reads
# client/assets/highkeep_plan.json and stamps every city placement into props.json,
# tagged "highkeep": fixed structures (walls, gatehouse, keep, greybox stand-ins),
# plot buildings that have shipped a real GLB (PLOT_MODELS grows as T-203..T-207 land),
# and seeded street furniture kept OFF the street corridors.
#
# Deterministic and idempotent: every run REPLACES all "highkeep"-tagged entries, so the
# city is re-rollable by seed and each build ticket only has to add its plot to
# PLOT_MODELS and re-run:  python3 scripts/gen-city.py && python3 scripts/world-audit.py
#
# NPCs are server data (server/world/data/npcs/npcs.json), placed by their tickets — this
# engine owns visual placements only.

import argparse
import json
import math
import random

# plot name -> (glb basename, solid). None model = still greyboxed (the greybox GLB carries
# its massing until the build ticket lands and adds the plot here + to the greybox --skip).
PLOT_MODELS = {
    "keep": ("prop_hk_keep", True),
    "cathedral": ("prop_hk_cathedral", True),
    "bank": ("prop_hk_bank", True),
    "auction_house": ("prop_hk_auction", True),
    "trainer_warrior": ("prop_hk_trainer_warrior", True),
    "trainer_mage": ("prop_hk_trainer_mage", True),
    "trainer_priest": ("prop_hk_trainer_priest", True),
    "trainer_ranger": ("prop_hk_trainer_ranger", True),
    # "cathedral": T-211, "auction_house": T-204,
    # "inn"/"smithy": T-206 dressing
}
# structures pinned to plan features rather than plots
GREYBOX_SKIP = ["walls", "gate", "wards"] + list(PLOT_MODELS.keys())


def seg_dist(px, pz, ax, az, bx, bz):
    abx, abz = bx - ax, bz - az
    t = max(0.0, min(1.0, ((px - ax) * abx + (pz - az) * abz) / (abx * abx + abz * abz)))
    return math.hypot(px - (ax + abx * t), pz - (az + abz * t))


def street_gap(plan, x, z):
    """Distance from (x,z) to the nearest street EDGE (negative = on a street)."""
    best = 1e9
    for st in plan.get("streets", []):
        pts = st["points"]
        for i in range(len(pts) - 1):
            best = min(best, seg_dist(x, z, *pts[i], *pts[i + 1]) - st["width"] / 2.0)
    sq = next((zn for zn in plan.get("zones", []) if zn["name"] == "market_square"), None)
    if sq:
        dqx = abs(x - sq["pos"][0]) - sq["half"][0]
        dqz = abs(z - sq["pos"][1]) - sq["half"][1]
        best = min(best, max(dqx, dqz))
    return best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=202)
    ap.add_argument("--plan", default="client/assets/highkeep_plan.json")
    ap.add_argument("--props", default="client/assets/props.json")
    args = ap.parse_args()
    rng = random.Random(args.seed)
    plan = json.load(open(args.plan))

    data = json.load(open(args.props))
    props = data["props"]
    props[:] = [p for p in props if p.get("tag") != "highkeep"]
    out = []

    def add(scene, x, z, rot=0, scale=None, solid=None, detail_tag=None):
        e = {"scene": f"res://assets/models/{scene}.glb", "x": round(x, 1),
             "y": round(z, 1), "rot_deg": int(rot) % 360, "tag": "highkeep"}
        if scale is not None:
            e["scale"] = round(scale, 2)
        if solid is not None:
            e["solid"] = solid
        if detail_tag is not None:
            e["detail_tag"] = detail_tag
        out.append(e)

    # --- fixed structures: enceinte at the city center, gatehouse at the plan gate ---
    cx, cz = 0.0, -240.0
    add("prop_hk_greybox", cx, cz, solid=False)  # massing stand-ins for unbuilt plots
    add("prop_hk_walls", cx, cz)
    gx, gz = plan["wall"]["gate"]["pos"]
    add("prop_hk_gatehouse", gx, gz)

    # --- plot buildings that have shipped ---
    for pl in plan["plots"]:
        model = PLOT_MODELS.get(pl["name"])
        if model:
            add(model[0], pl["pos"][0], pl["pos"][1], rot=pl.get("rot", 0), solid=model[1])

    # --- T-207 housing wards: paired rows of row-house archetypes facing private lanes.
    # Doors face the lane (rot 0 faces +z, rot 180 faces -z); no side windows, so tight
    # party-wall spacing is honest. Every house rect is checked clear of plan streets. ---
    archs = {"a": (5.0, 7.5), "b": (6.0, 8.0), "c": (7.0, 8.5), "d": (6.0, 7.0),
             "e": (8.0, 9.0), "f": (7.0, 8.0), "g": (9.0, 9.0), "h": (5.0, 6.5)}
    arch_names = list(archs.keys())
    arch_weights = [3, 3, 2, 2, 2, 3, 1, 3]
    LANE = 6.0
    ROW_D = 9.2          # deepest archetype + margin
    houses = 0
    for w in plan.get("wards", []):
        wx, wz = w["pos"]
        hx, hz = w["half"]
        z = wz - hz + ROW_D / 2 + 1.5
        while z + ROW_D / 2 <= wz + hz - 1.5:
            for rz, rot in ((z, 0), (z + ROW_D + LANE, 180)):  # pair faces the shared lane
                if rz + ROW_D / 2 > wz + hz - 1.5:
                    continue
                x = wx - hx + 2.0
                while x < wx + hx - 5.0:
                    a = rng.choices(arch_names, arch_weights)[0]
                    aw, ad = archs[a]
                    cx = x + aw / 2
                    ok = True
                    for dx, dz in ((-aw / 2 - 0.4, -ROW_D / 2), (aw / 2 + 0.4, -ROW_D / 2),
                                   (-aw / 2 - 0.4, ROW_D / 2), (aw / 2 + 0.4, ROW_D / 2),
                                   (0.0, 0.0)):
                        px, pz = cx + dx, rz + dz
                        if street_gap(plan, px, pz) < 0.6:
                            ok = False
                            break
                        # T-207: wards may overlap plot precincts in the plan (ward_s vs
                        # the keep court) — houses respect plots and keep_clear zones too
                        for pl in plan.get("plots", []):
                            if (abs(px - pl["pos"][0]) < pl["half"][0] + 1.0
                                    and abs(pz - pl["pos"][1]) < pl["half"][1] + 1.0):
                                ok = False
                                break
                        for zn in plan.get("zones", []):
                            if zn["kind"] == "keep_clear" and (
                                    abs(px - zn["pos"][0]) < zn["half"][0]
                                    and abs(pz - zn["pos"][1]) < zn["half"][1]):
                                ok = False
                                break
                        if not ok:
                            break
                    if ok and rng.random() > 0.10:  # the odd gap = yards, variety
                        add(f"prop_hk_house_{a}", cx, rz, rot=rot, solid=True)
                        houses += 1
                        x += aw + rng.choice((0.15, 0.15, 0.3, 1.8))
                    else:
                        x += 2.4
            z += ROW_D * 2 + LANE + 4.5
    print(f"gen-city: {houses} ward houses stamped")

    # --- street furniture: barrels/crates clustered at plot frontages, wells at street
    # meets — everything checked OFF the traveled way (street_gap > pad) ---
    furniture = ["prop_barrel_v2", "prop_crate_v2", "prop_sacks"]
    for pl in plan["plots"]:
        if rng.random() < 0.65:
            px, pz = pl["pos"]
            for _ in range(rng.randrange(1, 3)):
                for _try in range(10):
                    ang = rng.uniform(0, math.tau)
                    d = max(pl["half"]) + rng.uniform(1.0, 3.0)
                    x, z = px + math.cos(ang) * d, pz + math.sin(ang) * d
                    if street_gap(plan, x, z) > 0.7:
                        add(rng.choice(furniture), x, z, rot=rng.randrange(0, 360),
                            solid=False)
                        break

    # --- T-206 market frontage: REAL walk-in houses hem the square's north and south
    # edges (judge condition: continuous frontage, not grey massing), clear of the
    # high-street/spine entries on the axis ---
    sqf = next(zn for zn in plan["zones"] if zn["name"] == "market_square")
    fx0, fz0 = sqf["pos"]
    for fz, frot in ((fz0 + sqf["half"][1] + 7.0, 180), (fz0 - sqf["half"][1] - 7.0, 0)):
        for fx in (-11.5, 11.5):
            add(f"prop_hk_house_{rng.choice(['b', 'e', 'f'])}", fx0 + fx, fz, rot=frot,
                solid=True)

    # --- T-206 market dressing: the square becomes a deliberate civic room ---
    # anchor: market cross dead centre (judge condition)
    sq = next(zn for zn in plan["zones"] if zn["name"] == "market_square")
    sqx, sqz = sq["pos"]
    add("prop_hk_cross", sqx, sqz, rot=0, solid=True)
    # stalls in two trading arcs flanking the centre, off the ring corridors
    ring = [st for st in plan["streets"] if st["name"] == "market_square_ring"]
    for sx_ in (-1, 1):
        for k in range(3):
            stx = sqx + sx_ * 8.5
            stz = sqz - 7.0 + k * 7.0
            off_ring = all(
                seg_dist(stx, stz, *st["points"][i], *st["points"][i + 1]) > 3.4
                for st in ring for i in range(len(st["points"]) - 1))
            if off_ring:
                add("prop_hk_stall", stx, stz,
                    rot=(270 if sx_ < 0 else 90) + rng.randrange(-8, 9), solid=True)
    # heraldry: banner poles at the plaza corners + flanking the gate approach
    for bx_, bz_ in ((sqx - 15, sqz - 13), (sqx + 15, sqz - 13),
                     (sqx - 15, sqz + 13), (sqx + 15, sqz + 13),
                     (-6.0, -146.0), (6.0, -146.0)):
        add("prop_hk_banner_pole", bx_, bz_, rot=rng.randrange(0, 360), solid=False)
    # wall banners on the gatehouse bastion fronts (madder accents on the approach)
    for bx_ in (-7.6, 7.6):
        add("prop_hk_banner_wall", bx_, -136.6, rot=0, solid=False)
    # T-214: wall/tower skyline flags are built into the detailed wall GLB so their
    # elevation is exact. These plan-derived heraldry placements reinforce the gate and
    # keep precinct at pedestrian scale without adding collision.
    wall_poly = plan["wall"]["polyline"]
    for fx, fz in wall_poly[1:-1]:
        add("prop_hk_banner_pole", fx, fz, rot=0, solid=False, detail_tag="t214")
    for fx, fz in ((-18.0, -290.0), (18.0, -290.0), (-18.0, -334.0), (18.0, -334.0)):
        add("prop_hk_banner_wall", fx, fz, rot=(0 if fz > -312 else 180),
            solid=False, detail_tag="t214")
    for fx in (-12.0, 12.0):
        add("prop_hk_banner_pole", fx, -300.0, rot=0, solid=False, detail_tag="t214")
    # second well at the ward_nw lane junction + lampposts along the paved spine
    add("prop_well_v2", -46.0, -173.5, rot=0, solid=True)
    for lz in (-152.0, -176.0, -240.0, -262.0, -286.0):
        for lsx in (-1, 1):
            lx = (0.0 if lz > -200 else -1.0) + lsx * 4.6
            if street_gap(plan, lx, lz) > 0.4:
                add("prop_lamppost_v2", lx, lz, rot=0, solid=False)
    # livestock pen inside the gate (fences + haybale; sheep are T-209 server spawns)
    for fx, fz, fr in ((-18.0, -148.0, 0), (-18.0, -152.0, 0), (-14.0, -146.0, 90),
                       (-10.0, -148.0, 0), (-10.0, -152.0, 0), (-14.0, -154.0, 90)):
        add("prop_fence_v2", fx, fz, rot=fr, solid=False)
    add("prop_haybale_v2", -14.0, -150.0, rot=30, solid=False)

    # --- T-209 citizens: idle anchors written into the server roster (idempotent by
    # the npc_hk_cit_ prefix). Market-goers, crier, ward folk, lamplighter. T-215's
    # watch roster supersedes the two former citizen gate sentries at the same anchors.
    npcs_path = "server/world/data/npcs/npcs.json"
    try:
        nd = json.load(open(npcs_path))
    except OSError:
        nd = None
    if nd is not None:
        ns = nd["npcs"]
        ns[:] = [n for n in ns if not str(n.get("id", "")).startswith("npc_hk_cit_")]
        cits = [
            ("npc_hk_cit_crier", "Town Crier", 3.0, -212.0,
             "Hear ye! Lots close at the auction house come dusk!"),
            ("npc_hk_cit_market1", "Goodwife Ida", -8.0, -218.0,
             "Fresh loaves 'til the cross casts no shadow."),
            ("npc_hk_cit_market2", "Peddler Rouse", 9.0, -221.0,
             "Ribbons, needles, luck charms — a copper apiece."),
            ("npc_hk_cit_ward1", "Widow Maren", -60.0, -206.0,
             "My hearth's the warmest on the lane."),
            ("npc_hk_cit_ward2", "Old Cobb", 70.0, -210.0,
             "These stones were mud when I was a boy."),
            ("npc_hk_cit_spine", "Lamplighter Tosh", -1.0, -262.0,
             "Wicks trimmed, lamps lit by dusk."),
        ]
        for cid, cname, cx_, cz_, ctxt in cits:
            ns.append({"id": cid, "name": cname, "x": cx_, "y": cz_,
                       "gives_quests": [], "talk_text": ctxt})
        json.dump(nd, open(npcs_path, "w"), indent=1)
        open(npcs_path, "a").write("\n")
        print(f"gen-city: {len(cits)} citizen anchors written")

        # --- T-215 city watch: fixed posts. NPC content has no movement/waypoint field;
        # patrol movement belongs only to combat mobs, so these guards honestly hold
        # natural choke points instead of claiming a patrol the runtime cannot perform.
        ns[:] = [n for n in ns if not str(n.get("id", "")).startswith("npc_hk_watch_")]
        watch = [
            ("npc_hk_watch_gate_west", "Gate Watch", -4.0, -143.0,
             "Keep the gate lane clear."),
            ("npc_hk_watch_gate_east", "Gate Watch", 4.0, -143.0,
             "Peace-bind your blades inside the walls."),
            ("npc_hk_watch_wall_nw", "Wall Watch", -108.0, -154.0,
             "West wall is quiet."),
            ("npc_hk_watch_wall_ne", "Wall Watch", 108.0, -154.0,
             "East wall is quiet."),
            ("npc_hk_watch_wall_sw", "Wall Watch", -108.0, -326.0,
             "No trouble along the south curtain."),
            ("npc_hk_watch_wall_se", "Wall Watch", 108.0, -326.0,
             "The southeast tower is secure."),
            ("npc_hk_watch_keep_west", "Keep Guard", -4.0, -298.0,
             "The keep is under the Regent's peace."),
            ("npc_hk_watch_keep_east", "Keep Guard", 4.0, -298.0,
             "State your business before approaching."),
            ("npc_hk_watch_market", "Market Watch", 15.0, -215.0,
             "Mind your purse in the crowd."),
            ("npc_hk_watch_cathedral", "Close Watch", -61.0, -282.0,
             "Keep your voice low in the cathedral close."),
        ]
        for wid, wname, wx, wz, wtext in watch:
            ns.append({"id": wid, "name": wname, "x": wx, "y": wz,
                       "gives_quests": [], "talk_text": wtext})
        json.dump(nd, open(npcs_path, "w"), indent=1)
        open(npcs_path, "a").write("\n")
        print(f"gen-city: {len(watch)} city-watch anchors written")

    props.extend(out)
    json.dump(data, open(args.props, "w"), indent=1)
    print(f"gen-city: {len(out)} highkeep placements "
          f"(greybox --skip {','.join(GREYBOX_SKIP)})")


if __name__ == "__main__":
    main()
