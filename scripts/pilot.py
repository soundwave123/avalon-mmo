#!/usr/bin/env python3
"""pilot.py — drive the in-client Pilot (T-075): screenshots, input, introspection.

Usage (client must be running with AVALON_PILOT=1, see scripts/pilot-up.sh):
  pilot.py screenshot [path]        capture the game viewport to PNG
  pilot.py record <secs> [out]      record a video clip (mp4/gif) — SEE motion + VFX live
  pilot.py audio <secs> [out.wav]   record the live game audio mix — HEAR it
  pilot.py key <K>                  press+release a key (W, N, 1, ESCAPE, ...)
  pilot.py hold <K> <secs>          hold a key (movement)
  pilot.py click <x> <y>            left-click viewport coordinates
  pilot.py clicknode <Name>         click the center of a named visible Control
  pilot.py look <dx> <dy>           WoW right-drag look (pixels)
  pilot.py drag <button> <dx> <dy> <secs>   hold <button> (left/right/middle), interpolate
                                     motion by (dx,dy) px over <secs>, release (T-339; e.g. a
                                     left-drag camera-only orbit test)
  pilot.py freecam <x> <y> <z> <yaw> <pitch>   place+enable the T-142 benchmark camera
  pilot.py freecam off              restore the pre-freecam game camera
  pilot.py goto <x> <z> [y]         teleport the player to (x,z) for distant-zone QA (T-180).
                                     T-623 (#57): ARRIVAL-VERIFIED — ok:false with actual/wanted/dist
                                     when the final position lands beyond tolerance; never a blind
                                     ok:true (the false-success that stranded/killed a pilot before).
  pilot.py wait_until <path> <value> [timeout]   T-623: poll-don't-sleep. Wait for a dot-path into
                                     state+player (e.g. class_panel_visible, player.hp, player_pos)
                                     to match <value> (">50"/"<50"/"x,z[,tol]"/true|false/a number/
                                     a string), default timeout 10s. ok:false on timeout.
  pilot.py create_character <gender> <class> [name]   T-623/T-716: the whole boot modal dance
                                     (dismiss the Handbook, pick gender, pick class, type the
                                     character NAME) as ONE op — clicks named Buttons + polls panel
                                     visibility instead of blind timed keypresses (kills the
                                     eaten-keypress class of boot flake).
                                     gender: male|female  class: warrior|mage|priest
                                     name (T-716, optional): 3-20 chars [a-z0-9_-]; must be unused.
                                     Omit it and the op stops at the name modal (name_pending:true)
                                     so the caller can drive the field itself.
  pilot.py intent '<json>'          send any typed intent dict to the server (T-334), e.g.
                                     intent '{"type":"lfg_flag","level":13}'
  pilot.py force_death              T-521: dev-only self-kill for death QA (world needs AVALON_DEBUG_INTENTS)
  pilot.py crypt <enter|leave>      Hollowed Crypt stair: enter_instance / leave_instance (T-334)
  pilot.py positions                last positions broadcast payload (instance-scope E2E truth)
  pilot.py ui                       dump visible UI controls (name/rect/text)
  pilot.py state                    dump game state (panels, target, player pos)
  pilot.py observe                  T-562: ONE semantic snapshot for an LLM play-agent — player
                                     vitals+hp_delta / active quest / inventory / nearby units /
                                     recent log / open panel (see docs/tickets/zone/T-562.md schema)
  pilot.py use_ability <slot>       T-562: press the action-bar hotkey for slot N (1-4)
  pilot.py accept_quest <quest_id>  T-562: accept a quest by id (existing accept_quest intent)
  pilot.py turn_in <quest_id>       T-562: turn a quest in by id (existing turn_in intent)
  pilot.py attack_nearest [name]    T-562: target the nearest mob (optional name filter) + engage
                                     auto-attack
  pilot.py report <type> <title> <body>   T-562: file a play-agent finding into the feedback portal
                                     DB (same store human testers use; tester 'playbot'). No client
                                     needed. <type> = Bug | Suggestion | Feels-wrong.
  pilot.py wait <frames>            let N frames pass
  pilot.py quit                     close the client
  pilot.py batch [ops.jsonl]        T-623: run N ops (one JSON object per line) in ONE combined ack
                                     ({"op":"batch",...} sent ONCE) instead of N separate pilot.py
                                     invocations — cuts per-op subprocess+file-round-trip overhead
                                     ~3x for scripted sequences. Reads stdin if no path given.
                                     Exit 0 only if EVERY op in the batch acked ok:true.

Protocol: appends to $AVALON_PILOT_DIR/cmds.jsonl, waits for ack_<line>.json.
"""
import glob
import json
import os
import shutil
import subprocess
import sys
import time

PILOT_DIR = os.environ.get("AVALON_PILOT_DIR", "/tmp/avalon-pilot")
CMDS = os.path.join(PILOT_DIR, "cmds.jsonl")
CAPTURE_FPS = 60  # the client captures one PNG per drawn frame; `every` samples it down


def assemble_video(frame_dir, out, play_fps):
    """Stitch frame_dir/f_####.png into out (.mp4 via ffmpeg, else .gif via PIL)."""
    frames = sorted(glob.glob(os.path.join(frame_dir, "f_*.png")))
    if not frames:
        return None
    out = os.path.abspath(out)
    want_gif = out.lower().endswith(".gif")
    if not want_gif and shutil.which("ffmpeg"):
        cp = subprocess.run(
            ["ffmpeg", "-y", "-framerate", str(play_fps),
             "-i", os.path.join(frame_dir, "f_%04d.png"),
             "-vf", "scale=960:-2:flags=bilinear", "-pix_fmt", "yuv420p", out],
            capture_output=True,
        )
        if cp.returncode == 0:
            return out
    # GIF fallback (downscaled so it isn't enormous)
    from PIL import Image
    gif = out if want_gif else os.path.splitext(out)[0] + ".gif"
    imgs = []
    for f in frames:
        im = Image.open(f).convert("RGB")
        im = im.resize((640, int(640 * im.height / im.width)))
        imgs.append(im)
    imgs[0].save(gif, save_all=True, append_images=imgs[1:],
                 duration=int(1000 / play_fps), loop=0, optimize=True)
    return gif


def send(cmd: dict, timeout: float = 20.0) -> dict:
    os.makedirs(PILOT_DIR, exist_ok=True)
    # The command id is the line index in cmds.jsonl.
    if os.path.exists(CMDS):
        with open(CMDS, "r", encoding="utf-8") as fh:
            cmd_id = sum(1 for line in fh if line.strip())
    else:
        cmd_id = 0
    with open(CMDS, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(cmd) + "\n")
    ack_path = os.path.join(PILOT_DIR, f"ack_{cmd_id}.json")
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(ack_path):
            with open(ack_path, "r", encoding="utf-8") as fh:
                return json.load(fh)
        time.sleep(0.05)
    return {"ok": False, "error": f"timeout waiting for ack_{cmd_id} (client running with AVALON_PILOT=1?)"}


PLAYBOT_TESTER = "playbot"  # T-562: the autonomous play-agent's byline in the feedback portal


def report_feedback(rtype: str, title: str, body: str) -> dict:
    """T-562: file a play-agent finding into the feedback portal SQLite — the SAME store human
    testers submit to — by mirroring infra/feedback/portal.py's DB write. A direct INSERT (not the
    web form) so the bot byline 'playbot' rides in WITHOUT being on the tester-dropdown whitelist.
    Reuses portal.connect()/init_db() so the schema + migrations stay identical. No client needed.
    """
    fb_dir = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "infra", "feedback"
    )
    if fb_dir not in sys.path:
        sys.path.insert(0, fb_dir)
    import portal  # stdlib-only feedback module (shares AVALON_FEEDBACK_DB with the live portal)

    if rtype not in portal.REPORT_TYPES:
        return {"ok": False, "error": "type must be one of %s" % (portal.REPORT_TYPES,)}
    with portal.connect() as conn:
        portal.init_db(conn)
        cursor = conn.execute(
            "INSERT INTO reports (created_at, tester, report_type, title, what_happened, "
            "expected, steps, where_text) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (int(time.time()), PLAYBOT_TESTER, rtype, title, body, "", "", PLAYBOT_TESTER),
        )
        conn.commit()
        report_id = int(cursor.lastrowid)
    return {"ok": True, "id": report_id, "tester": PLAYBOT_TESTER, "type": rtype, "title": title}


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 1
    op = args[0]
    if op == "report":  # T-562: DB write, no pilot protocol / running client involved
        if len(args) < 4:
            print("usage: pilot.py report <Bug|Suggestion|Feels-wrong> <title> <body>")
            return 1
        result = report_feedback(args[1], args[2], args[3])
        print(json.dumps(result, indent=1))
        return 0 if result.get("ok") else 1
    if op == "screenshot":
        path = args[1] if len(args) > 1 else os.path.join(PILOT_DIR, "shot.png")
        result = send({"op": "screenshot", "path": os.path.abspath(path)})
    elif op == "key":
        result = send({"op": "key", "key": args[1]})
    elif op == "hold":
        result = send({"op": "key_hold", "key": args[1], "secs": float(args[2])},
                      timeout=float(args[2]) + 10.0)
    elif op == "click":
        result = send({"op": "click", "x": float(args[1]), "y": float(args[2])})
    elif op == "clicknode":
        result = send({"op": "click_node", "name": args[1]})
    elif op == "look":
        result = send({"op": "look", "dx": float(args[1]), "dy": float(args[2])})
    elif op == "drag":
        secs = float(args[4]) if len(args) > 4 else 0.3
        result = send({"op": "drag", "button": args[1], "dx": float(args[2]),
                       "dy": float(args[3]), "secs": secs}, timeout=secs + 10.0)
    elif op == "wheel":
        result = send({"op": "wheel", "steps": int(args[1])})
    elif op == "freecam":
        if len(args) > 1 and args[1] == "off":
            result = send({"op": "freecam", "off": True})
        else:
            result = send({"op": "freecam", "x": float(args[1]), "y": float(args[2]),
                           "z": float(args[3]), "yaw_deg": float(args[4]),
                           "pitch_deg": float(args[5])})
    elif op == "goto":
        # T-180: distant-zone teleport. The move is server-authoritative + rate-limited, so the
        # client op walks the player there in legal hops (~1 s per 100 units) — allow generous time.
        cmd = {"op": "goto", "x": float(args[1]), "z": float(args[2])}
        if len(args) > 3:
            cmd["y"] = float(args[3])
        result = send(cmd, timeout=30.0)
    elif op == "wait_until":  # T-623: poll-don't-sleep — wait for a state-path to match a value
        if len(args) < 3:
            print("usage: pilot.py wait_until <path> <value> [timeout]")
            return 1
        timeout = float(args[3]) if len(args) > 3 else 10.0
        result = send(
            {"op": "wait_until", "path": args[1], "value": args[2], "timeout": timeout},
            timeout=timeout + 10.0,
        )
    elif op == "create_character":  # T-623/T-716: gender+class+name modal dance as ONE op
        if len(args) < 3:
            print("usage: pilot.py create_character <gender> <class> [name]")
            return 1
        cmd = {"op": "create_character", "gender": args[1], "class": args[2]}
        if len(args) > 3:  # T-716: the creation NAME step (optional — see the usage note above)
            cmd["name"] = args[3]
        result = send(cmd, timeout=30.0)
    elif op == "intent":  # T-334: generic typed intent -> server (drives dungeon/LFG E2Es)
        result = send({"op": "intent", "payload": json.loads(args[1])})
    elif op == "force_death":  # T-521: dev-only self-kill for death-screen QA (world needs AVALON_DEBUG_INTENTS)
        result = send({"op": "intent", "payload": {"type": "debug_kill"}})
    elif op == "say":  # T-361: chat E2E — say <text> [channel]  (channel defaults to "say")
        cmd = {"op": "say", "text": args[1]}
        if len(args) > 2:
            cmd["channel"] = args[2]
        result = send(cmd)
    elif op == "emote":  # T-361: emote E2E — emote <id>  (server validates the id)
        result = send({"op": "emote", "id": args[1]})
    elif op == "crypt":  # T-334: enter_instance / leave_instance shorthand
        result = send({"op": "crypt", "action": args[1]})
    elif op == "positions":  # T-334: last positions payload (instance-scoped broadcast truth)
        result = send({"op": "positions"})
    elif op == "target":  # T-326: nearest mob (optional nameplate substring filter)
        cmd = {"op": "target"}
        if len(args) > 1:
            cmd["name"] = args[1]
        result = send(cmd)
    elif op == "pvp":  # T-401: open + dump the PvP panel body
        result = send({"op": "pvp"})
    elif op == "ui":
        result = send({"op": "ui"})
    elif op == "gear":
        result = send({"op": "gear"})
    elif op == "casts":
        result = send({"op": "casts"})
    elif op == "nameplates":
        result = send({"op": "nameplates", "visible": args[1].lower() in ("on", "true", "1")})
    elif op == "party":
        result = send({"op": "party", "action": args[1], "target": args[2] if len(args) > 2 else ""})
    elif op == "partystate":
        result = send({"op": "partystate"})
    elif op == "rclick":  # T-736: right-click a named entity via the real input path
        result = send({"op": "rclick", "name": args[1]})
    elif op == "state":
        result = send({"op": "state"})
    elif op == "observe":  # T-562: one consolidated semantic snapshot for a play-agent
        result = send({"op": "observe"})
    elif op == "use_ability":  # T-562: fire action-bar slot N via its hotkey (thin over `key`)
        result = send({"op": "key", "key": str(int(args[1]))})
    elif op == "accept_quest":  # T-562: existing accept_quest intent, thin over `intent`
        result = send({"op": "intent", "payload": {"type": "accept_quest", "quest_id": args[1]}})
    elif op == "turn_in":  # T-562: existing turn_in intent, thin over `intent`
        result = send({"op": "intent", "payload": {"type": "turn_in", "quest_id": args[1]}})
    elif op == "attack_nearest":  # T-562: target nearest mob (opt. name filter) + auto-attack toggle
        cmd = {"op": "target"}
        if len(args) > 1:
            cmd["name"] = args[1]
        result = send(cmd)
        if result.get("ok"):  # engage the "`" auto-attack toggle once a target is set
            result["autoattack"] = send({"op": "key", "key": "QuoteLeft"})
    elif op == "fps":  # T-210: frame probe for the city benchmark
        result = send({"op": "fps"})
    elif op == "scene":
        result = send({"op": "scene"}, timeout=30.0)
    elif op == "pick":
        result = send({"op": "pick", "x": float(args[1]), "y": float(args[2])})
    elif op == "setvis":
        result = send({"op": "setvis", "path": args[1],
                       "visible": args[2].lower() != "false" if len(args) > 2 else True})
    elif op == "wait":
        result = send({"op": "wait_frames", "frames": int(args[1])})
    elif op == "quit":
        result = send({"op": "quit"})
    elif op == "record":
        secs = float(args[1]) if len(args) > 1 else 3.0
        out = args[2] if len(args) > 2 else os.path.join(PILOT_DIR, "clip.mp4")
        # NOTE: the windowed client throttles rendering to ~1fps while UNFOCUSED, so each captured
        # frame costs ~1-3s. We therefore cap the saved frames (bounded wait) and the clip reads as a
        # time-lapse of the live world (ambient motion, day/night, weather, NPC wander). For a focused
        # window it runs much faster. every=1 = save every throttled frame we get.
        every = 1
        frames = min(int(secs * CAPTURE_FPS), 24)  # cap ~24 captures -> bounded wait
        frame_dir = os.path.join(PILOT_DIR, "rec")
        result = send({"op": "record", "frames": frames, "dir": frame_dir, "every": every},
                      timeout=frames * 4.0 + 30.0)
        if result.get("ok"):
            result["video"] = assemble_video(frame_dir, out, 8)  # play the time-lapse at 8fps
    elif op == "audio":
        secs = float(args[1]) if len(args) > 1 else 6.0
        out = os.path.abspath(args[2]) if len(args) > 2 else os.path.join(PILOT_DIR, "audio.wav")
        result = send({"op": "audio_record", "secs": secs, "path": out}, timeout=secs + 25.0)
    elif op == "batch":
        # T-623: ONE combined round-trip for N ops (was N separate send() calls even within this
        # same process — each paying its own file-append + poll-until-ack latency). The client-side
        # "batch" op runs every sub-op through the SAME dispatch as a solo invocation and replies
        # with one ack carrying all N results, in order.
        if len(args) > 1:
            with open(args[1], "r", encoding="utf-8") as fh:
                raw_lines = fh.readlines()
        else:
            raw_lines = sys.stdin.readlines()
        ops = [json.loads(line) for line in raw_lines if line.strip()]
        result = send({"op": "batch", "ops": ops}, timeout=max(60.0, len(ops) * 15.0))
        print(json.dumps(result, indent=1))
        sub_results = result.get("results", [])
        return 0 if result.get("ok") and all(r.get("ok") for r in sub_results) else 1
    else:
        print(__doc__)
        return 1
    print(json.dumps(result, indent=1))
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
