#!/usr/bin/env python3
"""Seed auth.session_tokens and auth.sessions for end-to-end RPC test."""
import hmac, hashlib, base64, json, time, subprocess, os

secret = os.environ.get('AVALON_JWT_SECRET', '')
if not secret:
    print("ERROR: AVALON_JWT_SECRET not set")
    exit(1)

def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode()

def make_jwt(sub, exp_offset=3600):
    header = {'alg': 'HS256', 'typ': 'JWT'}
    payload = {
        'sub': sub,
        'iat': int(time.time()),
        'exp': int(time.time()) + exp_offset,
        'iss': 'avalon'
    }
    h = b64url(json.dumps(header, separators=(',',':')).encode())
    p = b64url(json.dumps(payload, separators=(',',':')).encode())
    signing_input = f'{h}.{p}'
    sig = hmac.new(secret.encode(), signing_input.encode(), hashlib.sha256).digest()
    s = sig.hex()
    return f'{h}.{p}.{s}'

# Token 1: Valid token for "testuser" — NOT revoked
valid_token = make_jwt('testuser')
print(f"VALID_TOKEN={valid_token}")

# Token 2: Valid JWT for "revokeduser" — will be inserted into session_tokens as revoked
revoked_token = make_jwt('revokeduser')
print(f"REVOKED_TOKEN={revoked_token}")

# Token 3: Invalid token (just garbage)
invalid_token = "not_a_valid_jwt_token_at_all"
print(f"INVALID_TOKEN={invalid_token}")

# Write to a temp file for the shell to source
with open('/tmp/avalon-e2e-tokens.sh', 'w') as f:
    f.write(f'export VALID_TOKEN="{valid_token}"\n')
    f.write(f'export REVOKED_TOKEN="{revoked_token}"\n')
    f.write(f'export INVALID_TOKEN="{invalid_token}"\n')

print("Wrote /tmp/avalon-e2e-tokens.sh")

# Now seed the DB
# Insert valid token into sessions (username = testuser)
# Insert revoked token into session_tokens (revoked = true)
psql_cmd = "podman exec avalon-postgres psql -U avalon -d avalon -c"

# Insert valid session
valid_sql = (
    f"INSERT INTO auth.sessions (token, username, issued_at, expires_at, revoked) "
    f"VALUES ('{valid_token}', 'testuser', NOW(), NOW() + INTERVAL '1 hour', false) "
    f"ON CONFLICT (token) DO UPDATE SET username = 'testuser', revoked = false;"
)
subprocess.run(['bash', '-c', f'{psql_cmd} "{valid_sql}"'], check=True)
print("Inserted valid session for testuser")

# Insert revoked token into session_tokens
revoked_sql = (
    f"INSERT INTO auth.session_tokens (token, revoked, revoked_at) "
    f"VALUES ('{revoked_token}', true, NOW()) "
    f"ON CONFLICT (token) DO UPDATE SET revoked = true, revoked_at = NOW();"
)
subprocess.run(['bash', '-c', f'{psql_cmd} "{revoked_sql}"'], check=True)
print("Inserted revoked token for revokeduser")

# Verify
print("\n--- DB state ---")
subprocess.run(['bash', '-c', f'{psql_cmd} "SELECT token, username, revoked FROM auth.sessions LIMIT 5;"'], check=True)
subprocess.run(['bash', '-c', f'{psql_cmd} "SELECT token, revoked FROM auth.session_tokens LIMIT 5;"'], check=True)
print("\nDone. Tokens are ready.")
