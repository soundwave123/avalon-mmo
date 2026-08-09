#!/usr/bin/env python3
# Walk-in audit (owner mandate 2026-07-06): every enterable building must be enterable through
# its front door — teleports prove nothing about lips, lintels, beams, or blocked bays.
#
# TWO MODES (T-324):
#   * DEFAULT — NAVMESH BAKE (headless, no pilot, no dev stack). Bakes a NavigationMesh at the
#     real agent radius (0.4m) + step-climb (0.45m, LocalPlayer.STEP_HEIGHT) over each enterable
#     building + a door approach apron, then asks NavigationServer3D whether a walkable path runs
#     from the outside approach point into the interior. Deterministic geometry, ~20s for the whole
#     world — it replaces the 30+ min live walk loop that hung on dead clients and threw stoop/jamb
#     false negatives (T-323). Runner: client/scripts/dev/walkin_navmesh_probe.gd.
#   * --live <prop_substr> — the ORIGINAL pilot walk, for a single newly-shipped building as a
#     spot check. Needs a running pilot client (scripts/pilot-up.sh). Kept deliberately: the bake is
#     an approximation and a real capsule walk is the ground truth for a brand-new asset.
#
# Exit 1 if any building refuses entry (bake: a hard block that isn't a known bake-blind case).
#
# Movement note (live mode): the pilot spawns facing -z and we never turn it; keys map to world
# axes (W=-z, S=+z, A=-x, D=+x), so each door's approach picks the key matching its INWARD axis.

import argparse
import json
import math
import os
import struct
import subprocess
import sys
import time

PILOT = "scripts/pilot.py"
MODELS = "client/assets/models"
PROBE = "res://scripts/dev/walkin_navmesh_probe.gd"

# Buildings the headless bake cannot confirm because their walk-in depends on geometry that only
# exists at RUNTIME, not in the isolated GLB: an interior floor that is the TERRAIN itself (the GLB
# ships no interior floor mesh — cottage, farmhouse), a tall multi-step entry the flat-grade apron
# can't reconstruct (trainer_ranger, +1.16m stepped dais), or a walk-THROUGH passage where the
# far door's "interior point" test is the wrong shape (the gatehouse's second portal). These are
# reported as WARN, not a gate failure, and MUST be confirmed with `--live <name>` by the
# orchestrator (systems lane can't boot the pilot). Removing a name from here needs either a live
# PASS or a filed defect — never silence a NEW block by adding it.
BAKE_BLIND = {
    "prop_cottage_v2": "interior floor is terrain (no floor mesh in the GLB)",
    "prop_farmhouse": "interior floor is terrain (no floor mesh in the GLB)",
    "prop_hk_trainer_ranger": "tall stepped entry dais (+1.16m) not reconstructable at flat grade",
    "prop_hk_gatehouse": "walk-through passage; the far portal is not an interior-point test",
}


def glb_door_sockets(path):
    """T-210: read socket_door* node translations straight out of a GLB (JSON chunk parse —
    no engine needed). Returns local (x, z) pairs in GODOT space (glTF x, -z ... glTF z maps
    to Godot z directly; placements rotate about Y)."""
    try:
        with open(path, "rb") as f:
            magic, _ver, _total = struct.unpack("<III", f.read(12))
            if magic != 0x46546C67:
                return []
            clen, ctype = struct.unpack("<II", f.read(8))
            if ctype != 0x4E4F534A:
                return []
            doc = json.loads(f.read(clen))
        out = []
        for node in doc.get("nodes", []):
            name = str(node.get("name", ""))
            if name.startswith("socket_door"):
                t = node.get("translation", [0, 0, 0])
                # doors face a local +/-z face by convention; a name ending in "_xface"
                # (T-211 cathedral side door) marks a +/-x-facing door instead.
                out.append((float(t[0]), float(t[2]), name.endswith("_xface")))
        return out
    except Exception:
        return []

# name -> (door local s along the face, half-depth to the -Y door plane)
DOORS = {
    "prop_tavern_v2": (0.0, 4.0),
    "prop_cottage_v2": (-1.2, 2.2),
    "prop_church_v2": (0.0, 4.28),
    "prop_house_a_v2": (0.0, 3.48),
    "prop_house_b_v2": (0.0, 4.08),
    "prop_smithy_v2": (0.0, 4.18),  # open front bay
    "prop_windmill_v2": (0.0, 2.65),  # tower mill door at the base radius
    "prop_hk_gatehouse": (0.0, 0.0),  # T-200: the city gate passage itself (walk through)
}
KEY_FOR_INWARD = {(0, -1): "w", (0, 1): "s", (-1, 0): "a", (1, 0): "d"}


_DEAD_STREAK = [0]  # consecutive empty replies — a dead pilot client answers nothing forever


def pilot(*args):
    try:
        r = subprocess.run(["python3", PILOT, *args], capture_output=True, text=True,
                           timeout=60)
        out = json.loads(r.stdout)
        _DEAD_STREAK[0] = 0
        return out
    except Exception:
        # timeout/parse failure — callers re-verify via pos(). But a DEAD client (crash,
        # never booted) fails EVERY call at 60s each and turned a 30-min audit into a
        # 3-hour phantom hang (2026-07-10). Abort loudly instead of polling a corpse.
        _DEAD_STREAK[0] += 1
        if _DEAD_STREAK[0] >= 5:
            print("WALK-IN AUDIT: FATAL — pilot client unresponsive for 5 consecutive "
                  "calls (dead/never booted?). Boot it first: scripts/pilot-up.sh")
            sys.exit(2)
        return {}


def pos():
    st = pilot("state")
    p = st.get("state", {}).get("player_pos", [0, 0, 0])
    return p[0], p[2]


def live_main(filt):
    # ORIGINAL pilot walk (now --live only). --filter/filt walks only scenes containing the
    # substring; a single newly-shipped building is the intended spot check.
    data = json.load(open("client/assets/props.json"))
    props = data["props"] if isinstance(data, dict) and "props" in data else data
    # SPATIAL ORDER: snake through the world (band by z, then x) so consecutive doors are
    # near each other. Cross-map gotos are rate-limited multi-second walks; when one
    # overruns the ack window the pilot's command queue falls permanently behind and every
    # later walk measures against a stale goto (the -100m depths that killed round 2).
    props = sorted(
        [p for p in props if isinstance(p, dict)],
        key=lambda p: (round(float(p.get("y", 0)) / 25.0),
                       float(p.get("x", 0)) * (1 if round(float(p.get("y", 0)) / 25.0) % 2 == 0 else -1)))
    fails = []
    for p in props:
        if not isinstance(p, dict):
            continue
        name = p.get("scene", "").split("/")[-1].replace(".glb", "")
        if filt and filt not in name:
            continue
        # T-210: doors auto-derive from socket_door nodes in the GLB; the hand table is the
        # fallback for assets predating the socket convention. Every socket is walked.
        sockets = glb_door_sockets(os.path.join(MODELS, name + ".glb"))
        door_list = sockets if sockets else (
            [DOORS[name] + (False,)] if name in DOORS else [])
        for s, hd, xface in door_list:
            walk_one(p, name, s, hd, fails, xface)
    _finish(fails)


def walk_one(p, name, s, hd, fails, xface=False):
    x, z, rot = float(p["x"]), float(p["y"]), float(p.get("rot_deg", 0))
    th = math.radians(rot)
    c, sn = math.cos(th), math.sin(th)
    # door local (s, +hd) in Godot local (x, z); world = R(yaw) * local
    dwx = x + (s * c + hd * sn)
    dwz = z + (-s * sn + hd * c)
    # outward normal from the socket's dominant local axis: most doors sit on a +/-z local
    # face (normal = R(yaw)*(0, sign(hd))); an x-dominant socket (cathedral side door) sits
    # on a +/-x local face (normal = R(yaw)*(sign(s), 0)). Walking the wrong axis "passes"
    # by strolling along the wall — found on the T-211 side door.
    if xface:
        sgn = 1.0 if s >= 0 else -1.0
        nx, nz = c * sgn, -sn * sgn
    else:
        sgn = 1.0 if hd >= 0 else -1.0
        nx, nz = sn * sgn, c * sgn
    inward = (-round(nx), -round(nz))
    key = KEY_FOR_INWARD.get(inward)
    if key is None:  # diagonal placements need a smarter driver; flag for manual check
        fails.append(f"{name}: rotation {rot} not axis-aligned — walk it manually")
        return
    # 4m out, not 2m: T-301-style door stoops sit ~1-2m proud of the plane; a goto that lands
    # ON the stoop lip can wedge the capsule, while a real walk-up from flat ground enters fine
    # (verified live on prop_inn 2026-07-10: 2m start blocked at -0.09m, 4m run-up entered).
    ax, az = dwx + nx * 4.0, dwz + nz * 4.0
    # The world is LIVE: a wandering NPC or an aggroed mob can body-block a walk (the
    # village training dummy follows the pilot between doors). A mob moves between
    # attempts; geometry does not — retry a blocked door and only fail a repeatable block.
    depth_in = -1e9
    for attempt in range(3):
        # STAGED HOPS: a single long goto can outlive pilot.py's 30s ack window; the
        # abandoned command stays queued client-side and every later command lags one
        # behind (the stale-queue spiral). Short hops always ack fast.
        cx_now, cz_now = pos()
        hop = math.hypot(ax - cx_now, az - cz_now)
        while hop > 32.0:
            t = 30.0 / hop
            cx_now, cz_now = cx_now + (ax - cx_now) * t, cz_now + (az - cz_now) * t
            pilot("goto", str(round(cx_now, 2)), str(round(cz_now, 2)))
            hop = math.hypot(ax - cx_now, az - cz_now)
        pilot("goto", str(round(ax, 2)), str(round(az, 2)))
        # VERIFY ARRIVAL before walking: gotos are rate-limited multi-second walks and the
        # pilot queue can lag — measuring a walk that started elsewhere gave -100m depths.
        arrived = False
        for _ in range(25):
            px, pz = pos()
            if math.hypot(px - ax, pz - az) < 3.0:
                arrived = True
                break
            time.sleep(1.0)
        if not arrived:
            print(f"  {name}: goto never landed (queue lag?) — attempt {attempt + 1}")
            continue
        time.sleep(0.4)
        pilot("hold", key, "2.5")
        time.sleep(3.5)
        px, pz = pos()
        # entered = moved past the door plane along the inward axis by >= 0.8m
        depth_in = (px - dwx) * inward[0] + (pz - dwz) * inward[1]
        if depth_in >= 0.8:
            break
        if attempt < 2:
            print(f"  {name}: blocked at {depth_in:.2f}m — retrying (live-world traffic?)")
            if depth_in < -5.0:
                # walker nowhere near the door: a stale goto is still draining the pilot's
                # command queue — wait_frames only acks after everything before it ran
                pilot("wait", "5")
                time.sleep(3.0)
            time.sleep(2.0)
    status = "ENTERED" if depth_in >= 0.8 else "BLOCKED"
    print(f"  {name}: door ({dwx:.1f},{dwz:.1f}) walk '{key}' -> depth {depth_in:.2f}m {status}")
    if status == "BLOCKED":
        fails.append(f"{name}: entry blocked ({depth_in:.2f}m past the door plane, 3 attempts)")


def _finish(fails):
    if fails:
        print("WALK-IN AUDIT: FAIL")
        for f in fails:
            print("  -", f)
        sys.exit(1)
    print("WALK-IN AUDIT: PASS")


def _godot_bin():
    """T-346: absolute path to the single Godot resolver (scripts/godot-bin.sh)."""
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "godot-bin.sh")


def _godot_cmd(script, filt):
    """Headless Godot invocation for the bake probe — mirrors scripts/world-audit.py's call
    (client project, --headless, --script), passing the scene filter through the environment.
    T-346: routes through scripts/godot-bin.sh so the 4.6->4.7 cutover is a single pin flip."""
    root = os.path.abspath(".")
    env_filter = filt or ""
    return [
        _godot_bin(), "--env=AVALON_WALKIN_FILTER=" + env_filter,
        "--filesystem=" + root, "--headless",
        "--path", os.path.join(root, "client"), "--script", script,
    ]


def bake_main(filt):
    """DEFAULT mode: drive the headless navmesh-bake probe and classify its results. A hard block
    that is NOT a documented BAKE_BLIND case fails the gate; bake-blind cases warn + defer to a
    `--live` spot check (systems lane can't boot the pilot)."""
    result = subprocess.run(_godot_cmd(PROBE, filt), capture_output=True, text=True, timeout=300)
    summary = None
    for line in result.stdout.splitlines():
        if line.startswith("WALKIN_RESULT:"):
            rec = json.loads(line[len("WALKIN_RESULT:"):])
            print("  {name}: door {door} -> {depth}m past plane (need {need}m) {status}".format(**rec))
        elif line.startswith("WALKIN_DONE:"):
            summary = json.loads(line[len("WALKIN_DONE:"):])
        elif line.startswith("WALKIN_ERROR:"):
            print("  " + line)
    if summary is None:
        detail = (result.stderr or result.stdout).strip().splitlines()
        print("WALK-IN AUDIT: FATAL — bake probe produced no summary")
        print("  " + (detail[-1] if detail else "no output"))
        sys.exit(2)
    hard, warn = [], []
    for f in summary["fails"]:
        name = f.split(":", 1)[0]
        (warn if name in BAKE_BLIND else hard).append(f)
    print("WALK-IN BAKE: %d buildings / %d doors checked" % (summary["buildings"], summary["doors"]))
    for w in warn:
        name = w.split(":", 1)[0]
        print("  WARN (bake-blind, --live to confirm: %s): %s" % (BAKE_BLIND[name], w))
    if hard:
        print("WALK-IN AUDIT: FAIL")
        for f in hard:
            print("  -", f)
        sys.exit(1)
    print("WALK-IN AUDIT: PASS")


def main():
    ap = argparse.ArgumentParser(description="Walk-in audit — navmesh bake (default) or live walk.")
    ap.add_argument("--live", metavar="PROP_SUBSTR", default=None,
                    help="pilot-walk only buildings matching this substring (needs a booted pilot)")
    ap.add_argument("--filter", metavar="SUBSTR", default="",
                    help="restrict the bake to scenes containing SUBSTR (chunked runs)")
    args = ap.parse_args()
    if args.live is not None:
        live_main(args.live)
    else:
        bake_main(args.filter)


if __name__ == "__main__":
    main()
