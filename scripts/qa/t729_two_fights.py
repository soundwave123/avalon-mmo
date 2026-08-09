#!/usr/bin/env python3
"""T-729 two-fight driver: ONE auto-attack toggle press must cover both engagements.

Driven by scripts/test-t729-sticky-e2e.sh (which owns the isolated world + piloted client).
Swings are counted off the T-721 press ledger in observe().ability.counts: `result:1` is a
LANDED auto-swing (ability 1 = Strike) and `rejected:<reason>:1` is a refused one. Counting
sends-that-got-a-verdict (not client-side intent) keeps the proof server-anchored.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import pilot  # noqa: E402  (scripts/pilot.py — send() speaks the cmds.jsonl/ack protocol)

DUMMY = "Dummy"  # Training Dummy, 100 HP, spawn (10,10) — never fights back
EFFIGY = "Effigy"  # Straw Sparring Effigy, 200 HP, non_lethal — cannot kill a trainee


def swings(obs, kind="result"):
    counts = obs.get("ability", {}).get("counts", {})
    return sum(v for k, v in counts.items() if k.startswith(kind) and k.endswith(":1"))


def observe():
    r = pilot.send({"op": "observe"}, timeout=25.0)
    if not r.get("ok"):
        fail("observe failed: %s" % r)
    return r.get("observe", {})


def fail(msg):
    print("[t729] FAIL — %s" % msg)
    pilot.send({"op": "quit"}, timeout=5.0)
    sys.exit(1)


def step(cmd, timeout=30.0):
    r = pilot.send(cmd, timeout=timeout)
    print("[t729] %s -> %s" % (cmd.get("op"), r))
    return r


def main():
    probe = step({"op": "state"}, timeout=15.0)  # liveness: does the pilot ack at all?
    if not probe.get("ok"):
        fail("the pilot never acked a trivial state probe — driver/client protocol is broken")
    # Deliberately non-fatal: on a re-run the character already exists, so the creation modals
    # never appear and this op reports the handbook instead. The wait_until below is the real gate.
    step({"op": "create_character", "gender": "male", "class": "warrior", "name": "Sticky"})
    step({"op": "wait_until", "path": "player.hp", "value": ">0", "timeout": 20})

    # ---- fight 1: walk into melee of the dummy, select it, press ` ONCE ----------------------
    step({"op": "goto", "x": 11.5, "z": 10.0})
    t1 = step({"op": "target", "name": DUMMY})
    if not t1.get("ok"):
        fail("could not select the Training Dummy: %s" % t1)
    dummy_id = int(t1.get("target_id", -1))
    base = swings(observe())
    step({"op": "key", "key": "QuoteLeft"})  # THE ONLY TOGGLE PRESS IN THIS RUN
    time.sleep(5.0)
    if swings(observe()) <= base:
        fail("fight 1 never landed a swing after the single toggle press")
    print("[t729] fight 1 engaged (target_id=%d)" % dummy_id)

    # ---- the kill: swings must STOP dead, with no corpse hammering ---------------------------
    deadline = time.time() + 90.0
    killed = False
    while time.time() < deadline:
        obs = observe()
        if any("has died" in line for line in obs.get("recent_log", [])):
            killed = True
            break
        time.sleep(2.0)
    if not killed:
        fail("the dummy never died within 90 s (landed swings=%d)" % swings(observe()))
    time.sleep(3.0)  # let any corpse swings the OLD code would have fired go out
    at_kill = observe()
    landed_at_kill, dead_rejects = swings(at_kill), swings(at_kill, "rejected:target_is_dead")
    time.sleep(5.0)  # ~3 swing timer ticks against a corpse
    after = observe()
    if swings(after) > landed_at_kill:
        fail("swings continued after the kill (%d -> %d)" % (landed_at_kill, swings(after)))
    dead_after = swings(after, "rejected:target_is_dead")
    if dead_after > dead_rejects:
        fail("CORPSE HAMMERING: target_is_dead rejects grew %d -> %d" % (dead_rejects, dead_after))
    print("[t729] kill confirmed; swings idle at %d, target_is_dead rejects %d" %
          (landed_at_kill, dead_after))

    # ---- fight 2: select the effigy. NO second toggle press. ---------------------------------
    step({"op": "goto", "x": 14.5, "z": 10.0})
    t2 = step({"op": "target", "name": EFFIGY})
    if not t2.get("ok"):
        fail("could not select the Straw Sparring Effigy: %s" % t2)
    effigy_id = int(t2.get("target_id", -1))
    if effigy_id == dummy_id:
        fail("fight 2 re-selected the same entity (%d) — not a second engagement" % effigy_id)
    time.sleep(6.0)
    resumed = swings(observe())
    if resumed <= landed_at_kill:
        fail("swings did NOT resume on the new target without a re-toggle (%d -> %d)"
             % (landed_at_kill, resumed))
    print("[t729] fight 2 resumed on target_id=%d WITHOUT a re-toggle: swings %d -> %d"
          % (effigy_id, landed_at_kill, resumed))
    print("[t729] PASS — one toggle press covered both fights; the corpse was never hammered")
    pilot.send({"op": "quit"}, timeout=5.0)
    return 0


if __name__ == "__main__":
    sys.exit(main())
