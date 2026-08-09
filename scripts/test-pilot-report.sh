#!/usr/bin/env bash
# T-562 acceptance: the pilot `report` helper writes a play-agent finding into the feedback portal
# SQLite (the same store human testers use) and the row reads back with the 'playbot' byline.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PILOT="$SCRIPT_DIR/pilot.py"
WORK_DIR="$(mktemp -d /tmp/avalon-pilot-report-test.XXXXXX)"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

export AVALON_FEEDBACK_DB="$WORK_DIR/feedback.db"

echo "[test-pilot-report] writing a report via pilot.py ..."
out="$(python3 "$PILOT" report Bug "Wolf clips through fence" "The grey wolf walked through the north fence near the mill.")"
echo "$out"
echo "$out" | grep -q '"ok": true' || { echo "FAIL: report did not report ok"; exit 1; }
echo "$out" | grep -q '"tester": "playbot"' || { echo "FAIL: byline is not playbot"; exit 1; }

echo "[test-pilot-report] reading the row back out of SQLite ..."
python3 - "$AVALON_FEEDBACK_DB" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.row_factory = sqlite3.Row
rows = list(conn.execute("SELECT * FROM reports ORDER BY id DESC"))
assert len(rows) == 1, f"expected exactly one row, got {len(rows)}"
r = rows[0]
assert r["tester"] == "playbot", f"tester={r['tester']!r}"
assert r["report_type"] == "Bug", f"type={r['report_type']!r}"
assert r["title"] == "Wolf clips through fence", f"title={r['title']!r}"
assert r["what_happened"].startswith("The grey wolf"), f"body={r['what_happened']!r}"
assert r["status"] == "open", f"status={r['status']!r}"
print("[test-pilot-report] row verified: id=%d tester=%s type=%s status=%s"
      % (r["id"], r["tester"], r["report_type"], r["status"]))
PY

echo "[test-pilot-report] a second report appends (does not clobber) ..."
python3 "$PILOT" report Suggestion "Add a bridge" "A bridge over the north creek would save a detour." >/dev/null
count="$(python3 -c "import sqlite3,sys;print(sqlite3.connect(sys.argv[1]).execute('SELECT COUNT(*) FROM reports').fetchone()[0])" "$AVALON_FEEDBACK_DB")"
[[ "$count" == "2" ]] || { echo "FAIL: expected 2 rows, got $count"; exit 1; }

echo "[test-pilot-report] an unknown type is rejected (nonzero exit, no row) ..."
if python3 "$PILOT" report Nonsense "bad" "bad" >/dev/null 2>&1; then
	echo "FAIL: unknown report type should have failed"; exit 1
fi
count="$(python3 -c "import sqlite3,sys;print(sqlite3.connect(sys.argv[1]).execute('SELECT COUNT(*) FROM reports').fetchone()[0])" "$AVALON_FEEDBACK_DB")"
[[ "$count" == "2" ]] || { echo "FAIL: rejected report must not write a row (got $count)"; exit 1; }

echo "[test-pilot-report] PASS"
