#!/usr/bin/env python3
"""
Issue a signed JWT for the Avalon auth.sessions table.
Usage: python3 scripts/issue-jwt.py [username]
Outputs the JWT token to stdout.
Requires: AVALON_JWT_SECRET in environment.
"""
import hmac
import hashlib
import base64
import json
import time
import os
import sys
import subprocess


def b64url_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def create_jwt(payload: dict, secret: str) -> str:
    """Create a JWT compatible with the GDScript jwt.gd implementation.

    GDScript jwt.gd uses base64url for header/payload but HEX for signature.
    """
    header = {"alg": "HS256", "typ": "JWT"}
    header_b64 = b64url_encode(json.dumps(header, separators=(",", ":")).encode())
    payload_b64 = b64url_encode(json.dumps(payload, separators=(",", ":")).encode())
    signing_input = f"{header_b64}.{payload_b64}"
    # GDScript jwt.gd uses hex-encoded signature (not base64url)
    sig = hmac.new(
        secret.encode(), signing_input.encode(), hashlib.sha256
    ).hexdigest()
    return f"{signing_input}.{sig}"


def main():
    secret = os.environ.get("AVALON_JWT_SECRET", "")
    if not secret:
        print("FATAL: AVALON_JWT_SECRET not set", file=sys.stderr)
        sys.exit(1)

    username = sys.argv[1] if len(sys.argv) > 1 else "latency_tester"
    now = int(time.time())
    ttl = 120

    access_token = create_jwt(
        {"sub": username, "iat": now, "exp": now + ttl, "iss": "avalon"}, secret
    )
    refresh_token = create_jwt(
        {"sub": username, "iat": now, "exp": now + 86400, "iss": "avalon", "type": "refresh"},
        secret,
    )

    # Seed into auth.sessions table in the podman container
    # Schema: token (PK), username, issued_at, expires_at, revoked, refresh_token_id
    sql = (
        f"INSERT INTO auth.sessions (token, username, expires_at, refresh_token_id) "
        f"VALUES ('{access_token}', '{username}', "
        f"NOW() + INTERVAL '{ttl} seconds', '{refresh_token}')"
    )

    result = subprocess.run(
        ["podman", "exec", "-i", "avalon-postgres", "psql", "-U", "avalon", "-d", "avalon", "-c", sql],
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        print(f"WARNING: Failed to seed auth.sessions: {result.stderr.strip()}", file=sys.stderr)
        # Still output the token — it may work if master validates via JWT signature

    print(access_token)


if __name__ == "__main__":
    main()
