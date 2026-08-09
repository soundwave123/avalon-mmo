#!/usr/bin/env python3
"""T-561: tests for the server-log error watchdog.

Feeds synthetic log lines (the real relay_mob_damage `Cannot convert` crash among
them) and asserts the watchdog flags it, dedupes repeats, writes a structured
finding, and files a portal "Bug" report as tester "watchdog".

Stdlib unittest only. Run: python3 scripts/qa/test_log_watchdog.py
"""

from __future__ import annotations

import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import log_watchdog as wd  # noqa: E402

RELAY_CRASH = (
	"[world] tick 12490\n"
	"SCRIPT ERROR: relay_mob_damage: Cannot convert argument 1 from Nil to float.\n"
	"   at: relay_mob_damage (res://scripts/world_rpc.gd:214)\n"
	"[world] tick 12491\n"
)

OTHER_ERROR = (
	"SCRIPT ERROR: Invalid get index 'name' on base 'Nil'.\n"
	"   at: _apply_effigy_tick (res://scripts/effigy.gd:88)\n"
)

FATAL = "FATAL: condition 'p_elem == nullptr' is true. Breaking.\n"

NORMAL = "[world] peer connected: peer_id=7\n[world] broadcast 32 frames\n"

# T-574: a non-WS connection to the WS port makes Godot's engine print a stack
# trace with NO SCRIPT ERROR primary and NO game-code (.gd) frame — benign
# network noise (port scans / health checks), not a bug. Report #32 was this.
WS_HANDSHAKE_NOISE = (
	"[gateway] ERROR: Missing or invalid header 'upgrade'. Expected value 'websocket'.\n"
	"   at: _parse_client_request (modules/websocket/wsl_peer.cpp:189)\n"
)

# An orphan trace (no primary line) that DOES touch game code must still be kept.
ORPHAN_GD_TRACE = (
	"   at: _apply_tick (res://scripts/mob_ai.gd:301)\n"
	"   at: _process (res://scripts/mob_ai.gd:88)\n"
)


class WatchdogTest(unittest.TestCase):
	def setUp(self) -> None:
		self.tmp = tempfile.TemporaryDirectory()
		self.root = Path(self.tmp.name)
		self.log_dir = self.root / "logs"
		self.log_dir.mkdir()
		self.findings = self.root / "findings.jsonl"
		self.db = self.root / "feedback.db"

	def tearDown(self) -> None:
		self.tmp.cleanup()

	def _write_log(self, name: str, content: str) -> None:
		(self.log_dir / ("%s.log" % name)).write_text(content, encoding="utf-8")

	def _run(self):
		watchdog = wd.Watchdog(self.findings, self.db)
		return watchdog.run_once([self.log_dir / "world.log"])

	def _findings(self) -> list[dict]:
		if not self.findings.exists():
			return []
		return [json.loads(line) for line in self.findings.read_text().splitlines() if line.strip()]

	def _reports(self) -> list[sqlite3.Row]:
		conn = sqlite3.connect(self.db)
		conn.row_factory = sqlite3.Row
		try:
			return list(conn.execute("SELECT * FROM reports"))
		finally:
			conn.close()

	# --- flags the relay_mob_damage Cannot convert error + writes a finding ---
	def test_flags_relay_crash_and_writes_finding(self) -> None:
		self._write_log("world", NORMAL + RELAY_CRASH)
		written = self._run()
		self.assertEqual(len(written), 1, "exactly one new finding")

		records = self._findings()
		self.assertEqual(len(records), 1)
		rec = records[0]
		self.assertEqual(rec["category"], "script_error")
		self.assertIn("Cannot convert", rec["message"])
		self.assertIn("relay_mob_damage", rec["message"])
		self.assertEqual(rec["source_file"], "res://scripts/world_rpc.gd")
		self.assertEqual(rec["source_line"], 214)
		self.assertIsNotNone(rec["portal_report_id"])
		# the stack frame was folded into context, not filed as its own finding
		self.assertTrue(any("at: relay_mob_damage" in c for c in rec["context"]))

	# --- files a portal Bug report as tester "watchdog" ---
	def test_files_portal_report(self) -> None:
		self._write_log("world", RELAY_CRASH)
		self._run()
		reports = self._reports()
		self.assertEqual(len(reports), 1)
		self.assertEqual(reports[0]["tester"], "watchdog")
		self.assertEqual(reports[0]["report_type"], "Bug")
		self.assertEqual(reports[0]["status"], "open")
		self.assertIn("relay_mob_damage", reports[0]["what_happened"])

	# --- dedupes repeats of the same error ---
	def test_dedupes_repeats(self) -> None:
		self._write_log("world", RELAY_CRASH * 3)
		written = self._run()
		self.assertEqual(len(written), 1, "three identical errors -> one finding")
		self.assertEqual(len(self._findings()), 1)
		self.assertEqual(len(self._reports()), 1, "three identical errors -> one report")

	# --- a genuinely distinct error is filed separately ---
	def test_distinct_errors_each_file(self) -> None:
		self._write_log("world", RELAY_CRASH + OTHER_ERROR + FATAL)
		written = self._run()
		cats = sorted(r["category"] for r in written)
		self.assertEqual(cats, ["fatal", "script_error", "script_error"])
		self.assertEqual(len(self._findings()), 3)
		self.assertEqual(len(self._reports()), 3)

	# --- dedupe is persistent across separate runs (cron-safe) ---
	def test_persistent_dedupe_across_runs(self) -> None:
		self._write_log("world", RELAY_CRASH)
		self.assertEqual(len(self._run()), 1)
		# same log, fresh watchdog: signature already in findings.jsonl -> nothing new
		self.assertEqual(len(self._run()), 0)
		self.assertEqual(len(self._findings()), 1)
		self.assertEqual(len(self._reports()), 1)

	# --- normal log traffic produces no findings ---
	def test_normal_lines_are_silent(self) -> None:
		self._write_log("world", NORMAL)
		self.assertEqual(len(self._run()), 0)
		self.assertEqual(self._findings(), [])

	# --- T-574: benign engine WS-handshake noise (no .gd frame) is NOT flagged ---
	def test_ws_handshake_noise_is_not_flagged(self) -> None:
		self._write_log("world", NORMAL + WS_HANDSHAKE_NOISE + NORMAL)
		self.assertEqual(len(self._run()), 0, "pure-engine trace, no game code -> no finding")
		self.assertEqual(self._findings(), [])  # no finding filed -> no portal report either

	# --- T-574: an orphan trace that DOES touch game code is still flagged ---
	def test_orphan_gd_trace_is_flagged(self) -> None:
		self._write_log("world", ORPHAN_GD_TRACE)
		written = self._run()
		self.assertEqual(len(written), 1, "orphan trace with a .gd frame is a real finding")
		self.assertEqual(written[0]["category"], "stack_trace")


class SignatureTest(unittest.TestCase):
	def test_volatile_numbers_masked(self) -> None:
		a = wd.error_signature("script_error", "SCRIPT ERROR: bad at tick 1200 addr 0xdeadbeef")
		b = wd.error_signature("script_error", "SCRIPT ERROR: bad at tick 9999 addr 0xcafef00d")
		self.assertEqual(a, b, "tick counters and addresses must not split the signature")

	def test_extract_source(self) -> None:
		f, ln = wd.extract_source("   at: foo (res://scripts/world_rpc.gd:214)")
		self.assertEqual(f, "res://scripts/world_rpc.gd")
		self.assertEqual(ln, 214)


if __name__ == "__main__":
	unittest.main(verbosity=2)
