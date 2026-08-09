#!/usr/bin/env python3
# T-213: stamp the Elmsvale yard dressing into props.json — each home's yard reflects its
# occupant (T-212 mapping: house_a=smith, house_b=family, cottage=elder). Idempotent: every
# placement carries tag "village_yard"; reruns replace the whole tag group and nothing else.
#
# Placement contract (keeps world-audit + walk-in green by construction):
#   - Village doors face the street (x=0); yards sit on the OUTER side of each row
#     (|x| >= 12.5, past every rear wall), so no yard prop can enter a door corridor.
#   - The kids' green cluster is the one exception: it sits east of the traveled way
#     (x > 5.5, outside the road corridor) on the open green by the well.
#   - Each placement must keep >= 1.0m from every pre-existing prop (bushes, boulders,
#     haybales drift over time — the script re-verifies instead of trusting old coords).
#
# Usage: python3 scripts/gen-village-yards.py [--props client/assets/props.json]
import argparse
import json
import math
import sys

TAG = "village_yard"

# scene basename, x, z, rot_deg — hand-placed, see contract above.
YARDS = [
    # Smith's home (house_a at -8.8,13): the work follows him home.
    ("prop_yard_woodpile", -13.8, 14.3, 100),
    ("prop_yard_quench", -13.3, 12.5, 0),
    ("prop_anvil_v2", -14.4, 13.3, 75),
    # Family home (house_b at -8.8,3): laundry on the line, a kitchen garden.
    ("prop_yard_laundry", -15.8, 4.8, 95),
    ("prop_yard_garden", -15.4, 2.0, 5),
    # Elder's cottage (8.8,9): a tended herb patch and a bench to work it from.
    ("prop_yard_herbs", 13.1, 8.9, 10),
    ("prop_bench_v2", 13.2, 7.3, 350),
    # The green by the well: where the kids actually play (NPCs anchor to this).
    ("prop_yard_toys", 6.8, 5.8, 20),
]

MIN_CLEARANCE = 1.0
VILLAGE_Z = (-30.0, 30.0)  # only village-area neighbours matter for clearance


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--props", default="client/assets/props.json")
    args = ap.parse_args()
    data = json.load(open(args.props))
    props = [p for p in data["props"] if p.get("tag") != TAG]

    fails = []
    for name, x, z, _rot in YARDS:
        if not (abs(x) >= 12.5 or x > 5.5):
            fails.append(f"{name} at ({x},{z}) violates the yard placement contract")
        for p in props:
            px, pz = float(p.get("x", 0)), float(p.get("y", 0))
            if p.get("tag") in ("forest", "highkeep") or not (
                VILLAGE_Z[0] < pz < VILLAGE_Z[1]
            ):
                continue
            scene = p.get("scene", "?").split("/")[-1]
            if "prop_" not in scene and "mob_" not in scene and "furn_" not in scene:
                continue
            d = math.hypot(x - px, z - pz)
            if d < MIN_CLEARANCE:
                fails.append(f"{name} at ({x},{z}) is {d:.2f}m from {scene} ({px},{pz})")
    if fails:
        print("VILLAGE YARDS: FAIL")
        for f in fails:
            print("  -", f)
        sys.exit(1)

    for name, x, z, rot in YARDS:
        props.append(
            {
                "scene": f"res://assets/models/{name}.glb",
                "x": x,
                "y": z,
                "rot_deg": rot,
                "tag": TAG,
            }
        )
    data["props"] = props
    with open(args.props, "w") as f:
        json.dump(data, f, indent=1)
        f.write("\n")
    print(f"VILLAGE YARDS: OK ({len(YARDS)} placements, tag={TAG})")


if __name__ == "__main__":
    main()
