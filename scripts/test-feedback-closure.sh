#!/usr/bin/env bash
# T-510 acceptance: feedback portal closure loop.
# Covers submit -> ticketed -> fix-ready -> reporter confirm -> closed,
# the reopened (still-broken) path, objective auto-close, and status_events.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORTAL="$SCRIPT_DIR/feedback-portal.sh"
CLI="$SCRIPT_DIR/feedback.sh"
WORK_DIR="$(mktemp -d /tmp/avalon-feedback-closure.XXXXXX)"
LOG_FILE="$WORK_DIR/portal.log"
TOKEN="test-token-510"
PORT="${AVALON_FEEDBACK_TEST_PORT:-18090}"
BASE="http://127.0.0.1:$PORT"

cleanup() {
	AVALON_FEEDBACK_DB="$WORK_DIR/feedback.db" \
	AVALON_FEEDBACK_UPLOAD_DIR="$WORK_DIR/uploads" \
	AVALON_FEEDBACK_LOG="$LOG_FILE" \
	AVALON_FEEDBACK_PID="$WORK_DIR/portal.pid" \
	AVALON_FEEDBACK_PORT="$PORT" \
		bash "$PORTAL" stop >/dev/null 2>&1 || true
	rm -rf "$WORK_DIR"
}
trap cleanup EXIT

export AVALON_FEEDBACK_DB="$WORK_DIR/feedback.db"
export AVALON_FEEDBACK_UPLOAD_DIR="$WORK_DIR/uploads"
export AVALON_FEEDBACK_LOG="$LOG_FILE"
export AVALON_FEEDBACK_TOKEN="$TOKEN"
export AVALON_FEEDBACK_PID="$WORK_DIR/portal.pid"
export AVALON_FEEDBACK_PORT="$PORT"
# Isolate the tester allowlist from the live testers.txt (T-502) so this self-contained test
# doesn't depend on which real accounts exist.
export AVALON_FEEDBACK_TESTERS="Alex,Bea,Casey,Drew"

printf '\x89PNG\r\n\x1a\nfixture' > "$WORK_DIR/shot.png"

submit() {
	curl -fsS -X POST "$BASE/submit?token=$TOKEN" \
		-F "tester=$1" \
		-F "type=$2" \
		-F "title=$3" \
		-F "what_happened=$4" \
		-F "expected=expected text" \
		-F "steps=step one" \
		-F "where=Zone 1,2" \
		-F "screenshot=@$WORK_DIR/shot.png;type=image/png"
}

bash "$PORTAL" start
for _ in {1..50}; do
	if curl -fsS "$BASE/?token=$TOKEN" >/dev/null 2>&1; then break; fi
	sleep 0.1
done
curl -fsS "$BASE/?token=$TOKEN" >/dev/null

# --- Subjective happy path: submit -> ticketed -> fix-ready -> confirm -> closed ---
grep -q "Report #1 received" <<<"$(submit Alex Feels-wrong 'Cowl floats' 'The hood sits above the head.')"

grep -q "1 | Feels-wrong | open | Alex | Cowl floats" <<<"$(bash "$CLI" list)"

grep -q "resolved: 1 ticketed:T-425" \
	<<<"$(bash "$CLI" resolve 1 ticketed:T-425 'Filed as a seating regression.')"
grep -q "status: ticketed" <<<"$(bash "$CLI" show 1)"

grep -q "fix-ready: 1" \
	<<<"$(bash "$CLI" fixready 1 'Fixed in build 2026-07-17 — grab the new zip and check.')"
grep -q "status: fix-ready" <<<"$(bash "$CLI" show 1)"

# Reporter sees the note + the two action buttons on the portal.
index_html="$(curl -fsS "$BASE/?token=$TOKEN")"
grep -q "Fixed in build 2026-07-17" <<<"$index_html"
grep -q "Confirmed fixed" <<<"$index_html"
grep -q "Still broken" <<<"$index_html"

# Reporter clicks "Confirmed fixed".
confirm_out="$(curl -fsS -X POST "$BASE/confirm?token=$TOKEN" -d "report_id=1")"
grep -q "confirmed fixed and closed" <<<"$confirm_out"
show1="$(bash "$CLI" show 1)"
grep -q "status: closed" <<<"$show1"
grep -q "confirmed_by: Alex" <<<"$show1"

# Confirming again must fail (no longer fix-ready).
again="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE/confirm?token=$TOKEN" -d "report_id=1")"
[[ "$again" == "400" ]]

# --- Reopened path: submit -> ticketed -> fix-ready -> still broken -> reopened ---
grep -q "Report #2 received" <<<"$(submit Bea Feels-wrong 'Hood still floats' 'Gap remains.')"
bash "$CLI" resolve 2 ticketed:T-425 'Same regression.' >/dev/null
bash "$CLI" fixready 2 'Second pass reseat — please recheck.' >/dev/null

reopen_out="$(curl -fsS -X POST "$BASE/reopen?token=$TOKEN" \
	-d "report_id=2" --data-urlencode "what_wrong=Still a finger-width gap above the ears.")"
grep -q "reopened" <<<"$reopen_out"
show2="$(bash "$CLI" show 2)"
grep -q "status: reopened" <<<"$show2"
grep -q "finger-width gap" <<<"$show2"

# Empty what_wrong is rejected.
empty="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE/reopen?token=$TOKEN" \
	-d "report_id=2" --data-urlencode "what_wrong=")"
[[ "$empty" == "400" ]]

# --- Objective auto-close: close verb closes without reporter action ---
grep -q "Report #3 received" <<<"$(submit Casey Bug 'Server crash' 'Zoning crashes the client.')"
grep -q "closed: 3" <<<"$(bash "$CLI" close 3 'Auto-closed: fixed and covered by regression test T-3xx.')"
grep -q "status: closed" <<<"$(bash "$CLI" show 3)"

# --- status_events records every transition for the orchestrator to tail ---
events="$(bash "$CLI" events)"
grep -q "report 1 | open -> ticketed" <<<"$events"
grep -q "report 1 | ticketed -> fix-ready" <<<"$events"
grep -q "report 1 | fix-ready -> closed" <<<"$events"
grep -q "report 2 | fix-ready -> reopened" <<<"$events"
grep -q "report 3 | open -> closed" <<<"$events"

# --- Persistence across restart ---
bash "$PORTAL" stop
bash "$PORTAL" start
for _ in {1..50}; do
	if curl -fsS "$BASE/?token=$TOKEN" >/dev/null 2>&1; then break; fi
	sleep 0.1
done
grep -q "status: closed" <<<"$(bash "$CLI" show 1)"
grep -q "status: reopened" <<<"$(bash "$CLI" show 2)"

echo "PASS: feedback portal closure loop"
