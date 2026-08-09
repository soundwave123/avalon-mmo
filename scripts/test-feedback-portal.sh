#!/usr/bin/env bash
# T-502 acceptance: feedback portal submit/upload/triage/restart loop.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PORTAL="$SCRIPT_DIR/feedback-portal.sh"
CLI="$SCRIPT_DIR/feedback.sh"
WORK_DIR="$(mktemp -d /tmp/avalon-feedback-test.XXXXXX)"
LOG_FILE="$WORK_DIR/portal.log"
TOKEN="test-token-502"
PORT="${AVALON_FEEDBACK_TEST_PORT:-18088}"

cleanup() {
	AVALON_FEEDBACK_DB="$WORK_DIR/feedback.db" \
	AVALON_FEEDBACK_UPLOAD_DIR="$WORK_DIR/uploads" \
	AVALON_FEEDBACK_LOG="$LOG_FILE" \
	AVALON_FEEDBACK_PORT="$PORT" \
		bash "$PORTAL" stop >/dev/null 2>&1 || true
	rm -rf "$WORK_DIR"
}
trap cleanup EXIT

export AVALON_FEEDBACK_DB="$WORK_DIR/feedback.db"
export AVALON_FEEDBACK_UPLOAD_DIR="$WORK_DIR/uploads"
export AVALON_FEEDBACK_LOG="$LOG_FILE"
export AVALON_FEEDBACK_TOKEN="$TOKEN"
export AVALON_FEEDBACK_PORT="$PORT"

printf '\x89PNG\r\n\x1a\nfixture' > "$WORK_DIR/shot.png"
printf 'not an image' > "$WORK_DIR/not-image.txt"

bash "$PORTAL" start
for _ in {1..50}; do
	if curl -fsS "http://127.0.0.1:$PORT/?token=$TOKEN" >/dev/null; then
		break
	fi
	sleep 0.1
done
curl -fsS "http://127.0.0.1:$PORT/?token=$TOKEN" >/dev/null

submit_body="$(
	curl -fsS -X POST "http://127.0.0.1:$PORT/submit?token=$TOKEN" \
		-F "tester=Alex" \
		-F "type=Bug" \
		-F "title=Wolf stuck" \
		-F "what_happened=The wolf stopped moving near the fence." \
		-F "expected=The wolf should path around the fence." \
		-F "steps=Walk north, pull wolf, step behind fence." \
		-F "where=North field 10,20" \
		-F "screenshot=@$WORK_DIR/shot.png;type=image/png"
)"
grep -q "Report #1 received" <<<"$submit_body"

bad_status="$(
	curl -sS -o "$WORK_DIR/bad-upload.out" -w '%{http_code}' \
		-X POST "http://127.0.0.1:$PORT/submit?token=$TOKEN" \
		-F "tester=Bea" \
		-F "type=Bug" \
		-F "title=Fake image" \
		-F "what_happened=x" \
		-F "expected=y" \
		-F "steps=z" \
		-F "where=nowhere" \
		-F "screenshot=@$WORK_DIR/not-image.txt;type=image/png"
)"
[[ "$bad_status" == "400" ]]

list_out="$(bash "$CLI" list)"
grep -q "1 | Bug | open | Alex | Wolf stuck" <<<"$list_out"

show_out="$(bash "$CLI" show 1)"
grep -q "The wolf stopped moving" <<<"$show_out"
grep -q "screenshot:" <<<"$show_out"

resolve_out="$(bash "$CLI" resolve 1 ticketed:T-999 "Filed as a pathing regression.")"
grep -q "resolved: 1 ticketed:T-999" <<<"$resolve_out"

portal_out="$(curl -fsS "http://127.0.0.1:$PORT/?token=$TOKEN")"
grep -q "ticketed:T-999" <<<"$portal_out"
grep -q "Filed as a pathing regression." <<<"$portal_out"

bash "$PORTAL" stop
bash "$PORTAL" start
for _ in {1..50}; do
	if curl -fsS "http://127.0.0.1:$PORT/?token=$TOKEN" >/dev/null; then
		break
	fi
	sleep 0.1
done
restart_out="$(bash "$CLI" show 1)"
grep -q "ticketed:T-999" <<<"$restart_out"

echo "PASS: feedback portal acceptance loop"
