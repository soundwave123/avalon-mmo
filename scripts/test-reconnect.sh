#!/bin/bash
# T-015 reconnect smoke test — runs after dev-up.sh
# Generates its own JWT token from .env, no manual token needed.

cd /home/soundwave/avalon

# Generate JWT token inline
TOKEN=$(python3 << 'PYEOF'
import hashlib, hmac, json, base64, time

secret = ""
with open(".env") as f:
    for line in f:
        line = line.strip()
        if line.startswith("AVALON_JWT_SECRET="):
            secret = line.split("=", 1)[1].strip()
            break

header_b64 = base64.urlsafe_b64encode(
    json.dumps({"alg": "HS256", "typ": "JWT"}).encode()
).rstrip(b"=").decode()

payload = json.dumps({
    "sub": "reconnect_test",
    "iat": int(time.time()),
    "exp": int(time.time()) + 3600,
    "iss": "avalon"
})
payload_b64 = base64.urlsafe_b64encode(payload.encode()).rstrip(b"=").decode()

sig = hmac.new(
    secret.encode(),
    (header_b64 + "." + payload_b64).encode(),
    hashlib.sha256
).digest()
sig_b64 = base64.urlsafe_b64encode(sig).rstrip(b"=").decode()

print(header_b64 + "." + payload_b64 + "." + sig_b64)
PYEOF
)

if [ -z "$TOKEN" ] || [ ${#TOKEN} -lt 10 ]; then
    echo "ERROR: failed to generate token"
    exit 1
fi

# Write token to temp file to avoid shell redaction issues
echo "$TOKEN" > /tmp/avalon_test_token.txt

# Run the reconnect test
AVALON_RECONNECT=1 \
AVALON_TOKEN=$(cat /tmp/avalon_test_token.txt) \
AVALON_MOVE_DURATION=2 \
flatpak run org.godotengine.Godot --headless --path server/world --scene res://tests/test_client.tscn 2>&1

EXIT_CODE=$?
echo ""
echo "=== T-015 Reconnect Test Exit Code: $EXIT_CODE ==="

rm -f /tmp/avalon_test_token.txt

exit $EXIT_CODE
