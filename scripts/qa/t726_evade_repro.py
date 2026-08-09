#!/usr/bin/env python3
"""T-726 evade-reset repro driver for the Shallow Graves bosses.

Driven by scripts/test-t726-evade-e2e.sh (which owns the isolated world + piloted client).

The instrument is the INSTANCE BROADCAST itself (`positions` op -> `mobs[]`), which carries `hp`,
`max_hp`, `ai_state` and `target_id` per mob (broadcast_builder.mobs_array). That is server truth,
not a client guess, so the whole T-025 transition reads directly: MELEE(2) -> EVADING(3) -> IDLE(0)
with hp back at max and the mob back on its spawn.

Cases (argv[1]), all against Pallbearer Ost (spawn 427.5,-12.0; leash_radius 12.0):
  reset     A. LEASH-OUT — pull, damage, walk to TRIAL_ENTRANCE (15.16 m from spawn, past leash)
            B. WIPE      — pull, damage, debug_kill, respawn at the entrance, re-read
  safespot  C. Can he be damaged from OUTSIDE the leash, where _tick_idle refuses to aggro?
               Needs a caster (nukes reach 25-30 units). Includes an in-leash control so a null
               reading can never be vacuous.

Exit 0 = bosses reset / safe spot unreachable, 2 = the exploit is live, 1 = rig failure.
"""
import math
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import pilot  # noqa: E402  (scripts/pilot.py — send() speaks the cmds.jsonl/ack protocol)

OST = "Pallbearer"  # Pallbearer Ost — boss 1, retaliate_only, leash 12.0
HUSK = "Husk"  # Grave-Bound Husk — the gallery pack, cleared out of the way first
OST_SPAWN = (427.5, -12.0)
TRIAL_ENTRANCE = (418.5, 0.2)
MELEE_SPOT = (426.3, -11.0)  # ~1.6 m off Ost's anchor: inside melee_range AND inside the leash
PORCH = (14.0, -12.5)
STATE = {0: "IDLE", 1: "AGGROED", 2: "MELEE", 3: "EVADING"}  # mob_ai.MobAIState


def log(msg):
    print("[t726] %s" % msg, flush=True)


def fail(msg):
    log("RIG FAILURE — %s" % msg)
    pilot.send({"op": "quit"}, timeout=5.0)
    sys.exit(1)


def step(cmd, timeout=30.0):
    r = pilot.send(cmd, timeout=timeout)
    log("%s -> ok=%s" % (cmd.get("op"), r.get("ok")))
    return r


def mobs():
    r = pilot.send({"op": "positions"}, timeout=20.0)
    if not r.get("ok"):
        fail("positions op failed: %s" % r)
    return r.get("positions", {}).get("mobs", [])


def find(name, alive_only=True):
    """The first broadcast mob whose nameplate contains `name`."""
    for m in mobs():
        if name.lower() in str(m.get("name", "")).lower():
            if alive_only and int(m.get("hp", 0)) <= 0:
                continue
            return m
    return None


def reading(tag, m):
    """One instrument reading, in the ledger format the ticket records."""
    if m is None:
        log("%-22s MISSING from the instance broadcast" % tag)
        return None
    log(
        "%-22s hp=%d/%d  ai_state=%s  target_id=%s  pos=(%.2f,%.2f)  d_spawn=%.2f"
        % (
            tag,
            int(m["hp"]),
            int(m["max_hp"]),
            STATE.get(int(m.get("ai_state", -1)), m.get("ai_state")),
            m.get("target_id"),
            float(m["x"]),
            float(m["y"]),
            math.dist((float(m["x"]), float(m["y"])), OST_SPAWN),
        )
    )
    return m


def poll_until(pred, timeout, label, interval=1.0):
    """Poll-don't-sleep: run `pred(Ost)` every interval until true or timeout."""
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        last = find(OST)
        if last is not None and pred(last):
            return last
        time.sleep(interval)
    log("timeout (%ds) waiting for %s" % (timeout, label))
    return last


def nuke_rotation(seconds, full_hp):
    """Rotate hotkeys 1-4 until Ost takes damage or the budget runs out.

    Slot-agnostic on purpose (main.gd only casts KEY_1..KEY_4 — T-719 finding 6), so the run never
    depends on this class's default bar order.
    """
    deadline = time.time() + seconds
    while time.time() < deadline:
        for slot in (1, 2, 3, 4):
            pilot.send({"op": "key", "key": str(slot)}, timeout=10.0)
            time.sleep(1.6)  # past the 1.5 s GCD
        m = find(OST)
        if m is not None and int(m["hp"]) < full_hp:
            return


def clear_husks():
    """Kill the gallery pack so the Ost readings are not contaminated by pack aggro.

    respawn_ticks 6000 (300 s, the T-725 long dwell) keeps them dead for the whole run.
    """
    for i in range(2):
        h = find(HUSK)
        if h is None:
            break
        step({"op": "goto", "x": float(h["x"]) - 1.2, "z": float(h["y"])})
        if not step({"op": "target", "name": HUSK}).get("ok"):
            break
        if i == 0:
            step({"op": "key", "key": "QuoteLeft"})  # sticky auto-attack: one press covers both
        hid = int(h["mob_id"])
        poll_until(
            lambda _m, _h=hid: all(int(x["mob_id"]) != _h or int(x["hp"]) <= 0 for x in mobs()),
            60,
            "husk %d death" % hid,
        )
    step({"op": "key", "key": "QuoteLeft"})  # auto-attack OFF before any boss work


def pull_and_damage(target_frac, budget):
    """Pull Ost and auto-attack until he drops below `target_frac` of max hp, then disengage."""
    step({"op": "goto", "x": MELEE_SPOT[0], "z": MELEE_SPOT[1]})
    if not step({"op": "target", "name": OST}).get("ok"):
        fail("could not select Pallbearer Ost")
    step({"op": "key", "key": "QuoteLeft"})  # retaliate_only: THIS is what starts the fight
    hit = poll_until(
        lambda m: int(m["hp"]) <= target_frac * int(m["max_hp"]),
        budget,
        "Ost below %d%%" % int(target_frac * 100),
    )
    step({"op": "key", "key": "QuoteLeft"})  # auto-attack OFF — nothing damages him from here on
    return hit


def case_reset(full_hp):
    """CASES A + B: the ticket's own hypothesis — does leaving / wiping reset HP and threat?"""
    clear_husks()
    ok = {}

    log("--- CASE A: pull, damage to ~70%, walk out past the leash, wait, re-read ---")
    pull_and_damage(0.70, 120)
    damaged = reading("A1 damaged", find(OST))
    if damaged is None or int(damaged["hp"]) >= full_hp:
        fail("could not damage Ost — the pull/attack path never landed, so the case is vacuous")
    step({"op": "goto", "x": TRIAL_ENTRANCE[0], "z": TRIAL_ENTRANCE[1]})
    reading("A2 at entrance", find(OST))
    after = reading(
        "A3 after 25s",
        poll_until(
            lambda m: int(m.get("ai_state", -1)) == 0 and int(m["hp"]) == full_hp,
            25,
            "Ost back to IDLE at full hp",
        ),
    )
    ok["A_leash_out"] = (
        after is not None
        and int(after["hp"]) == full_hp
        and int(after.get("ai_state", -1)) == 0
        and math.dist((float(after["x"]), float(after["y"])), OST_SPAWN) < 0.5
    )
    log("CASE A: %d/%d -> %s" % (int(damaged["hp"]), full_hp, "RESET" if ok["A_leash_out"] else "NO RESET"))

    log("--- CASE B: pull, damage to ~70%, die, respawn at the entrance, re-read ---")
    pull_and_damage(0.70, 120)
    damaged_b = reading("B1 damaged", find(OST))
    step({"op": "intent", "payload": {"type": "debug_kill"}})
    time.sleep(2)
    reading("B2 just after death", find(OST))
    after_b = reading(
        "B3 after wipe+30s",
        poll_until(
            lambda m: int(m.get("ai_state", -1)) == 0 and int(m["hp"]) == full_hp,
            30,
            "Ost back to IDLE at full hp after the wipe",
        ),
    )
    ok["B_wipe"] = (
        after_b is not None
        and int(after_b["hp"]) == full_hp
        and int(after_b.get("ai_state", -1)) == 0
    )
    hp_b = int(damaged_b["hp"]) if damaged_b else -1
    log("CASE B: %d/%d -> %s" % (hp_b, full_hp, "RESET" if ok["B_wipe"] else "NO RESET"))
    return ok


def case_safespot(full_hp):
    """CASE C: can Ost be damaged from OUTSIDE his leash, where he refuses to aggro?

    mob_ai._tick_idle gates the threat-pull on `spawn.distance_to(top_pos) <= leash_radius`, so an
    attacker past that circle generates threat the boss will never act on. TRIAL_ENTRANCE is
    15.16 m from Ost's spawn and every caster nuke reaches 25-30 units — the geometry is live.
    """
    step({"op": "goto", "x": TRIAL_ENTRANCE[0], "z": TRIAL_ENTRANCE[1]})
    before = reading("C0 from entrance", find(OST))
    if not step({"op": "target", "name": OST}).get("ok"):
        fail("could not select Ost from the entrance (15.16 m)")
    nuke_rotation(45, full_hp)
    after = reading("C1 after 45s of ranged fire", find(OST))
    if after is None:
        fail("Ost vanished from the broadcast during the safe-spot probe")
    log(
        "CASE C: hp %d -> %d, ai_state=%s, target_id=%s"
        % (
            int(before["hp"]) if before else -1,
            int(after["hp"]),
            STATE.get(int(after.get("ai_state", -1))),
            after.get("target_id"),
        )
    )
    if int(after["hp"]) < full_hp:
        if int(after.get("ai_state", -1)) == 0 and int(after.get("target_id", -1)) == -1:
            log("CASE C: SAFE-SPOT EXPLOIT — Ost took damage out of leash and never engaged")
            return {"C_safespot": False}
        log("CASE C: Ost engaged (left IDLE) — the leash circle did not gate the pull")
        return {"C_safespot": True}

    # NON-VACUITY CONTROL. "Nothing landed" is only evidence if this same character, same bar, same
    # rotation CAN hurt him from inside the leash circle. Without it a mis-seeded level, an empty
    # action bar or a wedged pilot would read as a clean pass.
    log("CASE C: nothing landed from the safe spot — running the in-leash control")
    step({"op": "goto", "x": MELEE_SPOT[0], "z": MELEE_SPOT[1]})
    step({"op": "target", "name": OST})
    nuke_rotation(20, full_hp)
    ctl = reading("C2 in-leash control", find(OST))
    if ctl is None or int(ctl["hp"]) >= full_hp:
        fail("CONTROL FAILED: this character could not damage Ost from INSIDE the leash either — "
             "the safe-spot reading is vacuous, not a pass")
    log("CASE C: control OK (in-leash %d/%d) — the safe spot, and only it, is unreachable"
        % (int(ctl["hp"]), full_hp))
    return {"C_safespot": True}


def main():
    case = sys.argv[1] if len(sys.argv) > 1 else "reset"
    klass = sys.argv[2] if len(sys.argv) > 2 else "warrior"
    if not step({"op": "state"}, timeout=15.0).get("ok"):
        fail("the pilot never acked a state probe — driver/client protocol is broken")
    step({"op": "create_character", "gender": "male", "class": klass, "name": "Ostbane"})
    step({"op": "wait_until", "path": "player.hp", "value": ">0", "timeout": 20})

    # Descend: the porch-proximity gate is real (T-380), so walk there before entering.
    step({"op": "goto", "x": PORCH[0], "z": PORCH[1]})
    step({"op": "crypt", "action": "enter"})
    time.sleep(3)
    ost = find(OST)
    if ost is None:
        fail("Pallbearer Ost is not in the instance broadcast — routing/seed did not happen")
    log(
        "descended: %d mobs in the instance; entrance->Ost spawn = %.2f m (leash 12.0)"
        % (len(mobs()), math.dist(TRIAL_ENTRANCE, OST_SPAWN))
    )
    full_hp = int(reading("BASELINE", ost)["max_hp"])

    verdicts = case_safespot(full_hp) if case == "safespot" else case_reset(full_hp)
    step({"op": "quit"}, timeout=5.0)
    log("VERDICTS: %s" % verdicts)
    if all(verdicts.values()):
        log("RESULT: bosses reset and the out-of-leash safe spot is cold")
        return 0
    log("RESULT: a boss retained damage it should have shed — exploit live")
    return 2


if __name__ == "__main__":
    sys.exit(main())
