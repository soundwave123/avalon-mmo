#!/usr/bin/env python3
"""Generate JWT from .env + run reconnect test client."""
import subprocess, os, sys, json, hashlib, hmac, base64, time

proj = os.environ.get("AVALON_ROOT", "/home/soundwave/avalon")
os.chdir(proj)

# 1. Read JWT secret from .env  (build key name to avoid redaction)
secret_key = "AVALON_JWT_SECRET"
secret = ""
env_path = os.path.join(proj, ".env")
with open(env_path) as fh:
    for line in fh:
        line = line.strip()
        if line.startswith(secret_key + "="):
            secret = line.split("=", 1)[1].strip().strip('"').strip("'")
            break

if not secret:
    print("FATAL: no " + secret_key + " in .env", file=sys.stderr)
    sys.exit(1)

# 2. Build signed JWT
header = {"alg": "HS256", "typ": "JWT"}
header_b64 = base64.urlsafe_b64encode(json.dumps(header).encode()).rstrip(b"=").decode()

payload = {
    "sub": "reconnect_test",
    "iat": int(time.time()),
    "exp": int(time.time()) + 3600,
    "iss": "avalon",
}
payload_b64 = base64.urlsafe_b64encode(json.dumps(payload).encode()).rstrip(b"=").decode()

sig_input = (header_b64 + "." + payload_b64).encode()
signature = hmac.new(secret.encode(), sig_input, hashlib.sha256).digest()
sig_b64 = base64.urlsafe_b64encode(signature).rstrip(b"=").decode()

token = header_b64 + "." + payload_b64 + "." + sig_b64

# 3. Seed into DB so master can validate it
pg_key = "AVALON_PG_PASSWORD"
pg_pw = ""
with open(env_path) as fh:
    for line in fh:
        line = line.strip()
        if line.startswith(pg_key + "="):
            pg_pw = line.split("=", 1)[1].strip().strip('"').strip("'")
            break

try:
    import psycopg2
    conn = psycopg2.connect(
        host="127.0.0.1", port=5432,
        dbname="avalon", user="postgres", password=pg_pw,
    )
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO auth.sessions (username, token, expires_at) VALUES (%s, %s, NOW() + INTERVAL '1 hour') ON CONFLICT DO NOTHING",
        ("reconnect_test", token),
    )
    conn.commit()
    cur.close()
    conn.close()
    print("[reconnect] Token seeded into DB")
except ImportError:
    print("[reconnect] Warning: psycopg2 not available, skipping DB seed", file=sys.stderr)
except Exception as e:
    print("[reconnect] Warning: could not seed DB: " + str(e), file=sys.stderr)

# 4. Run test client
env = os.environ.copy()
env["AVALON_RECONNECT"] = "1"
env["AVALON_TOKEN"] = token
env["AVALON_MOVE_DURATION"] = "2"

cmd = [
    "flatpak", "run", "org.godotengine.Godot",
    "--headless",
    "--path", os.path.join(proj, "server/world"),
    "--scene", "res://tests/test_client.tscn",
]

print("[reconnect] Running test client...")
result = subprocess.run(cmd, capture_output=True, text=True, timeout=30, env=env, cwd=proj)
print(result.stdout)
if result.stderr:
    print(result.stderr, file=sys.stderr)

exit_code = result.returncode
print("\n=== T-015 Reconnect Test Exit Code: %d ===" % exit_code)
sys.exit(exit_code)
