#!/usr/bin/env python3
# Forest buildout — T-312 rebuild: a real TEMPERATE-EUROPEAN LOWLAND WOOD flanking the winding
# dirt road between the village edge and the Highkeep approach. Deterministic (seeded): every run
# REPLACES all entries tagged "forest" in props.json, so the layout is re-rollable by seed.
#
# T-312 changes the biome and the shape of the wood:
#   * BROADLEAF-DOMINANT canopy (oak/ash/birch the majority; fir+pine a ~20% high-ground accent),
#     replacing the old near-pure conifer avenue (fir x20 + pine x7 + one oak).
#   * DEPTH, NOT A HAIRLINE: a lightly-wooded road VERGE (the edge you pass) PLUS clustered
#     interior STANDS reaching inland to ~38 m, with a soft outer EDGE of young trees + saplings
#     thinning back to meadow — so the treeline reads as a wood you enter, not a fence.
#   * HABITAT: weeping WILLOWS fringe the water (Crystal Lake shore + the mill-race), where
#     broadleaf water-lovers belong; conifers stay off the wet ground.
#
# Density is tuned for the T-120 impostor/cull budget (trees swap to billboards past 90 m): a
# clustered stand+glade layout, not blanket fill. Measure honestly with AVALON_LOD_STATS=1.
#
# Layout rules (medieval-engineer honest):
#   - trunks keep >= 3.4 m + pad off the winding road centerline (world-audit enforces too)
#   - the windmill keeps a 15 m clearing; the watchtower camp + wayshrine keep their glades;
#     the village (z > -26) and quest landmarks stay open
#   - canopy trees ~5-8 m apart (real forest spacing); saplings/young broadleaf/bushes/ferns as
#     understory + edge; stumps near the road verge; mossy rocks deep under the shade
#
# Usage: python3 scripts/gen-forest.py [--seed 11] [--props client/assets/props.json]

import argparse
import json
import math
import random

ROAD_HALF = 3.4
MILL = (-20.0, -16.0)
FOREST_Z = (-96.0, -26.0)
BAND_MAX = 38.0  # how far inland from the road center the wood reaches at its deepest
LAKE = (18.0, 22.0, 12.0)      # Crystal Lake x, z, radius (willows fringe the shore)
WATERMILL = (32.0, 28.0)       # mill-race outfall (willows, but keep off the building)

# Landmark clearings the wood must leave open: (x, z, radius). The road corridor + mill are
# handled separately. These are quest/nav landmarks that would be swallowed by a widened wood.
CLEARINGS = [
    (20.0, -30.0, 16.0),   # watchtower + palisade camp (a real glade around the outpost)
    (-5.2, -70.0, 9.0),    # wayshrine
    (3.6, -30.0, 6.0),     # roadside waystone
]


def road_center_x(z):
    """KEEP IN SYNC with terrain_splat.gdshader / WorldView / world-audit road_center_x()."""
    w = max(0.0, min(1.0, (-z - 18.0) / 14.0)) * max(0.0, min(1.0, (z + 136.0) / 14.0))
    return w * (6.0 * math.sin(0.055 * (z + 18.0)) + 2.6 * math.sin(0.021 * (z + 18.0) + 1.7))


# Canopy mix: BROADLEAF-DOMINANT (temperate lowland). weight, scale range, min spacing.
# Broadleaf weight = 25 (oaks 13 + ash 6 + birch 6); conifer = 6 -> conifers ~19% (high-ground
# accent). Conifers keep a name the T-120 impostor policy already covers (prop_tree/fir/pine),
# as do the new prop_tree_*_real broadleaves.
CANOPY = [
    ("prop_oak_real", 4, (0.85, 1.15), 7.0),
    ("prop_oak_real_b", 4, (0.85, 1.15), 7.0),
    ("prop_oak_petiolate", 3, (0.8, 1.1), 7.0),
    ("prop_oak2", 2, (0.85, 1.1), 6.5),
    ("prop_tree_ash_real", 6, (0.85, 1.15), 6.5),
    ("prop_tree_birch_real", 6, (0.9, 1.25), 5.5),
    ("prop_tree_fir_a", 1, (0.9, 1.3), 5.5),
    ("prop_tree_fir_b", 1, (0.9, 1.3), 5.5),
    ("prop_tree_fir_c", 1, (0.9, 1.3), 5.5),
    ("prop_tree_pine_a", 1, (0.9, 1.25), 5.5),
    ("prop_tree_pine_b", 1, (0.9, 1.25), 5.5),
    ("prop_tree_pine_c", 1, (0.9, 1.25), 5.5),
]
# Young broadleaves for the thinning outer EDGE (scaled-down real trees read as saplings).
YOUNG_BROADLEAF = ["prop_tree_birch_real", "prop_tree_ash_real"]
WILLOW = "prop_tree_willow_real"
SAPLINGS = ["prop_sapling_fir_a", "prop_sapling_fir_b", "prop_sapling_firmed_a",
            "prop_sapling_firmed_b", "prop_sapling_pinemed_a", "prop_sapling_pinemed_b",
            "prop_sapling_pinesml_a", "prop_sapling_pinesml_b"]
DEAD = ["prop_tree_dead_a", "prop_tree_dead_b"]
STUMPS = ["prop_stump_a", "prop_stump_b"]
BUSHES = ["prop_bush_real_a", "prop_bush_real_b", "prop_bush_real_c", "prop_bush_real_d",
          "prop_bush_real_f", "prop_bush_real_g"]
FERN = "prop_bush_real_g"
ROCKS = [("prop_rock_a", 0.9, 1.4), ("prop_rock_e", 0.9, 1.4), ("prop_rock_i", 0.9, 1.4),
         ("prop_rock_b", 2.0, 3.5), ("prop_rock_c", 2.5, 4.0), ("prop_rock_d", 2.5, 4.0),
         ("prop_rock_g", 1.5, 2.5), ("prop_rock_h", 0.8, 1.2), ("prop_rock_f", 0.45, 0.6)]
MOSS_ROCKS = ["prop_rock_moss_a", "prop_rock_moss_b"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=11)
    ap.add_argument("--props", default="client/assets/props.json")
    args = ap.parse_args()
    rng = random.Random(args.seed)

    data = json.load(open(args.props))
    props = data["props"]
    props[:] = [p for p in props if p.get("tag") != "forest"]

    placed = []  # (x, z, min_spacing) of canopy trees for spacing checks

    def off_limits(x, z, road_pad=2.2):
        if abs(x - road_center_x(z)) < ROAD_HALF + road_pad:
            return True
        if math.hypot(x - MILL[0], z - MILL[1]) < 15.0:
            return True
        for cx, cz, cr in CLEARINGS:
            if math.hypot(x - cx, z - cz) < cr:
                return True
        return False

    def clear_of(x, z, spacing, road_pad=2.2):
        if off_limits(x, z, road_pad):
            return False
        for px, pz, ps in placed:
            if math.hypot(x - px, z - pz) < max(spacing, ps):
                return False
        return True

    out = []

    def add(scene, x, z, scale, solid=None):
        e = {"scene": f"res://assets/models/{scene}.glb", "x": round(x, 1), "y": round(z, 1),
             "rot_deg": rng.randrange(0, 360), "scale": round(scale, 2), "tag": "forest"}
        if solid is not None:
            e["solid"] = solid
        out.append(e)

    names = [c[0] for c in CANOPY]
    weights = [c[1] for c in CANOPY]
    meta = {c[0]: (c[2], c[3]) for c in CANOPY}

    def place_canopy(x, z, tries=8):
        """Try to drop a weighted-random canopy tree near (x,z); returns True if placed."""
        for _ in range(tries):
            scene = rng.choices(names, weights)[0]
            (smin, smax), spacing = meta[scene]
            jx, jz = x + rng.uniform(-1.6, 1.6), z + rng.uniform(-1.6, 1.6)
            if clear_of(jx, jz, spacing):
                add(scene, jx, jz, rng.uniform(smin, smax))
                placed.append((jx, jz, spacing))
                return (jx, jz)
        return None

    def understory_around(px, pz, n_lo=0, n_hi=3):
        for _ in range(rng.randrange(n_lo, n_hi)):
            ang, d = rng.uniform(0, math.tau), rng.uniform(2.2, 4.8)
            x, zz = px + math.cos(ang) * d, pz + math.sin(ang) * d
            if not off_limits(x, zz):
                kind = rng.choice(SAPLINGS) if rng.random() < 0.4 else rng.choice(BUSHES)
                add(kind, x, zz, rng.uniform(0.9, 1.3), solid=False)
        if rng.random() < 0.4:
            ang, d = rng.uniform(0, math.tau), rng.uniform(1.2, 2.6)
            x, zz = px + math.cos(ang) * d, pz + math.sin(ang) * d
            if not off_limits(x, zz):
                add(FERN, x, zz, rng.uniform(0.9, 1.4), solid=False)

    # --- 1. road VERGE: the lightly-wooded edge you pass, both sides, jittered setbacks --------
    z = FOREST_Z[0]
    while z < FOREST_Z[1]:
        for side in (-1, 1):
            if rng.random() < 0.8:
                setback = rng.uniform(6.5, 15.0)
                x = road_center_x(z) + side * setback
                hit = place_canopy(x, z + rng.uniform(-2.0, 2.0))
                if hit:
                    understory_around(*hit)
        z += rng.uniform(4.4, 6.6)

    # --- 2. interior STANDS: clustered depth reaching inland, glades between them --------------
    # Stand centers march the band; each is a dense clump at real forest spacing. Gaps between
    # stands stay open (natural glades -> sightlines + clearings). Outer stands lean to the edge.
    n_stands = 0
    z = FOREST_Z[0] + 3.0
    while z < FOREST_Z[1] - 3.0:
        for side in (-1, 1):
            if rng.random() < 0.8:
                perp = rng.uniform(15.0, BAND_MAX - 5.0)
                cx = road_center_x(z) + side * perp
                cz = z
                radius = rng.uniform(7.5, 13.0)
                # edge factor: stands deep in the band are closed canopy; stands near the outer
                # meadow edge (perp -> BAND_MAX) thin out to young trees + saplings.
                edge = max(0.0, min(1.0, (perp - 22.0) / (BAND_MAX - 22.0)))
                n_trees = int(round((radius * radius) / 17.0 * (1.0 - 0.45 * edge)))
                planted = 0
                for _ in range(n_trees * 3):
                    if planted >= n_trees:
                        break
                    ang, d = rng.uniform(0, math.tau), radius * math.sqrt(rng.random())
                    x, zz = cx + math.cos(ang) * d, cz + math.sin(ang) * d
                    if not (FOREST_Z[0] < zz < FOREST_Z[1]):
                        continue
                    # near the outer rim of an edge-stand, prefer young trees / saplings
                    if edge > 0.4 and rng.random() < 0.4 + 0.4 * edge:
                        if not off_limits(x, zz):
                            if rng.random() < 0.5:
                                add(rng.choice(YOUNG_BROADLEAF), x, zz,
                                    rng.uniform(0.3, 0.5), solid=False)
                            else:
                                add(rng.choice(SAPLINGS), x, zz,
                                    rng.uniform(0.9, 1.4), solid=False)
                        continue
                    hit = place_canopy(x, zz, tries=4)
                    if hit:
                        planted += 1
                        understory_around(*hit, n_lo=0, n_hi=2)
                if planted:
                    n_stands += 1
        z += rng.uniform(7.0, 11.0)

    # --- 3. willows at the water: Crystal Lake shore ring + mill-race ---------------------------
    # World-audit keeps props out of the lake disc; sit the willow trunks just outside the shore.
    lx, lz, lr = LAKE
    n_willow = 0
    for k in range(22):
        ang = rng.uniform(0, math.tau)
        rr = lr + rng.uniform(3.5, 6.5)               # just off the waterline (shore grade < tol)
        x, zz = lx + math.cos(ang) * rr, lz + math.sin(ang) * rr
        # keep off the road, the watermill, and the reed beds' densest cluster
        if abs(x - road_center_x(zz)) < ROAD_HALF + 3.0:
            continue
        if math.hypot(x - WATERMILL[0], zz - WATERMILL[1]) < 6.0:
            continue
        if not clear_of(x, zz, 6.0, road_pad=2.0):
            continue
        add(WILLOW, x, zz, rng.uniform(0.85, 1.15))
        placed.append((x, zz, 6.0))
        n_willow += 1
        # NB: no understory scattered here — it would land on the graded shore bowl (world-audit
        # terrain float); the reed beds already fill the waterline.
    # a couple by the mill-race outfall
    for _ in range(4):
        ang, d = rng.uniform(0, math.tau), rng.uniform(6.5, 10.0)
        x, zz = WATERMILL[0] + math.cos(ang) * d, WATERMILL[1] + math.sin(ang) * d
        if clear_of(x, zz, 6.0, road_pad=2.0) and math.hypot(x - lx, zz - lz) > lr + 1.0:
            add(WILLOW, x, zz, rng.uniform(0.8, 1.05))
            placed.append((x, zz, 6.0))
            n_willow += 1

    # --- 4. road-verge dressing: stumps (cut close to the path) --------------------------------
    for z in range(-88, -30, 11):
        side = rng.choice((-1, 1))
        x = road_center_x(z) + side * rng.uniform(4.6, 6.5)
        if not off_limits(x, z, road_pad=1.0):
            add(rng.choice(STUMPS), x, z + rng.uniform(-3, 3), rng.uniform(0.9, 1.3))

    # --- 5. dead standing trunks: rare, deeper in ----------------------------------------------
    for _ in range(3):
        for _try in range(12):
            z = rng.uniform(*FOREST_Z)
            x = road_center_x(z) + rng.choice((-1, 1)) * rng.uniform(11.0, 22.0)
            if clear_of(x, z, 4.0):
                add(rng.choice(DEAD), x, z, rng.uniform(0.9, 1.2))
                placed.append((x, z, 4.0))
                break

    # --- 6. rocks: bare near the verges, mossy deep under the canopy shade ----------------------
    for i in range(16):
        for _try in range(14):
            z = rng.uniform(*FOREST_Z)
            deep = i % 2 == 0
            x = road_center_x(z) + rng.choice((-1, 1)) * (
                rng.uniform(14.0, 26.0) if deep else rng.uniform(6.0, 10.0))
            if not off_limits(x, z, road_pad=1.2):
                if deep:
                    add(rng.choice(MOSS_ROCKS), x, z, rng.uniform(0.55, 0.95))
                else:
                    name, smin, smax = rng.choice(ROCKS)
                    add(name, x, z, rng.uniform(smin, smax))
                break

    props.extend(out)
    json.dump(data, open(args.props, "w"), indent=1)  # match gen-city/gen-village-yards format
    with open(args.props, "a") as f:
        f.write("\n")

    # --- report: species tally, broadleaf vs conifer split -------------------------------------
    kinds = {}
    for e in out:
        k = e["scene"].split("/")[-1].replace(".glb", "")
        kinds[k] = kinds.get(k, 0) + 1
    canopy_set = set(names) | {WILLOW}
    broadleaf_keys = {"prop_oak_real", "prop_oak_real_b", "prop_oak_petiolate", "prop_oak2",
                      "prop_tree_ash_real", "prop_tree_birch_real", WILLOW}
    bl = sum(v for k, v in kinds.items() if k in broadleaf_keys)
    con = sum(v for k, v in kinds.items()
              if k in canopy_set and k not in broadleaf_keys)
    print(f"forest: {len(out)} placements (seed {args.seed}); {n_stands} interior stands, "
          f"{n_willow} willows at water")
    print(f"  canopy split: broadleaf {bl} vs conifer {con} "
          f"({100 * bl / max(1, bl + con):.0f}% broadleaf)")
    for k in sorted(kinds):
        print(f"  {kinds[k]:3d}  {k}")


if __name__ == "__main__":
    main()
