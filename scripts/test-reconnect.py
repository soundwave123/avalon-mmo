#!/usr/bin/env python3
"""T-015 reconnect smoke test.
Reads token from /tmp/avalon_reconnect_token.txt (written by seed_jwt tool).
Expects dev-up.sh to be running."""
import subprocess
import os
import sys

proj = "/home/soundwave/avalon"
os.chdir(proj)

token_file = "/tmp/avalon_reconnect_token.txt"
if not os.path.exists(token_file):
    print("ERROR: no token file at %s — seed a JWT first" % token_file, file=sys.stderr)
    sys.exit(1)

with open(token_file) as f:
    token = f.read().strip()

if not token or len(token) < 50:
    print("ERROR: token file is empty or too short", file=sys.stderr)
    sys.exit(1)

print("[reconnect] Loaded JWT token (%d chars)" % len(token))

env = os.environ.copy()
env["AVALON_RECONNECT"] = "1"
env["AVALON_TOKEN"] = token
env["AVALON_MOVE_DURATION"] = "2"

result = subprocess.run(
    [
        "flatpak", "run", "org.godotengine.Godot",
        "--headless",
        "--path", "server/world",
        "--scene", "res://tests/test_client.tscn",
    ],
    capture_output=True,
    text=True,
    timeout=30,
    env=env,
    cwd=proj,
)

print(result.stdout)
if result.stderr:
    print(result.stderr, file=sys.stderr)

exit_code = result.returncode
print("\n=== T-015 Reconnect Test Exit Code: %d ===" % exit_code)
sys.exit(exit_code)
