#!/usr/bin/env python3
"""T-561: Server-log error watchdog — the deterministic FLOOR of autonomous bug testing.

Tails the Avalon server logs (world/master/gateway) for crash-class text that
every unit test happily ignores:

  * ``SCRIPT ERROR``   — GDScript runtime error (the class that masked player
                         damage when ``relay_mob_damage`` threw on every mob hit)
  * ``FATAL``          — engine/process fatal
  * ``Cannot convert`` — type-coercion failure (the exact relay_mob_damage text)
  * GDScript stack traces (``at: func (res://…gd:NN)`` frames)

Each DISTINCT error (deduped by a normalized signature) is recorded ONCE to
``docs/verification/qa/findings.jsonl`` AND filed as a portal report ("Bug",
tester "watchdog") in the feedback SQLite DB, mirroring the live portal schema.

The watchdog is strictly READ-ONLY with respect to the game: it never connects to
a server, never writes a log, only tails files and appends findings.

Usage:
  log_watchdog.py --once            # scan existing logs, file new findings, exit (cron)
  log_watchdog.py --follow          # scan existing, then tail live until Ctrl-C
  log_watchdog.py --once --log-dir DIR --findings FILE --db FILE   # overrides (tests)
"""

from __future__ import annotations

import argparse
import json
import re
import sqlite3
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parents[2]
DEFAULT_LOG_DIR = Path("/tmp/avalon-dev")
DEFAULT_LOG_NAMES = ("world", "master", "gateway")
DEFAULT_FINDINGS = PROJECT_DIR / "docs" / "verification" / "qa" / "findings.jsonl"
POLL_SECONDS = 1.0

# Import the live portal module so the DB path + schema stay a MIRROR, not a copy
# that can drift. Best-effort: if it can't be imported we still write findings.
sys.path.insert(0, str(PROJECT_DIR / "infra" / "feedback"))
try:
	import portal  # type: ignore
except Exception:  # pragma: no cover - portal is stdlib-only, import rarely fails
	portal = None

# --- Trigger patterns (ordered; first match wins for the primary category) ---
_PRIMARY_PATTERNS = (
	("script_error", re.compile(r"SCRIPT ERROR")),
	("fatal", re.compile(r"FATAL")),
	("cannot_convert", re.compile(r"Cannot convert")),
)
_SOURCE_RE = re.compile(r"(res://[^\s:()]+\.gd):(\d+)")
# A frame that touches game code (a GDScript source). Used to tell a real
# orphan stack trace from benign pure-engine C++ noise.
_GD_FRAME_RE = re.compile(r"res://[^\s:()]+\.gd")
_LEADING_TAG_RE = re.compile(r"^\s*\[[^\]]*\]\s*")
_HEX_RE = re.compile(r"0x[0-9a-fA-F]+")
_NUM_RE = re.compile(r"\d+")


def is_trace_line(line: str) -> bool:
	"""A GDScript stack-trace frame, e.g. ``   at: relay_mob_damage (res://…:214)``."""
	return line.lstrip().startswith("at:")


def classify_primary(line: str) -> str | None:
	"""Return the primary error category for a line, or None if it is not one."""
	for kind, pat in _PRIMARY_PATTERNS:
		if pat.search(line):
			return kind
	return None


def error_signature(category: str, text: str) -> str:
	"""Stable dedupe key: category + the message with volatile values masked.

	Line numbers, tick counters and pointer addresses are masked so genuine
	repeats of the SAME error collapse to one finding while distinct errors
	(different function/message text) stay distinct.
	"""
	core = _LEADING_TAG_RE.sub("", text.strip())
	core = _HEX_RE.sub("0xADDR", core)
	core = _NUM_RE.sub("N", core)
	return f"{category}:{core}"


def extract_source(text: str) -> tuple[str | None, int | None]:
	match = _SOURCE_RE.search(text)
	if match:
		return match.group(1), int(match.group(2))
	return None, None


@dataclass
class Finding:
	category: str
	message: str
	log_name: str
	log_line_no: int
	context: list[str] = field(default_factory=list)
	source_file: str | None = None
	source_line: int | None = None

	def signature(self) -> str:
		# Fold the discovered source into the signature so the same error at the
		# same site dedupes even if the message wording drifts slightly.
		anchor = self.source_file or ""
		return error_signature(self.category, self.message) + f"|{anchor}"

	def title(self) -> str:
		where = ""
		if self.source_file:
			where = " in %s:%s" % (Path(self.source_file).name, self.source_line)
		return "[watchdog] %s%s" % (self.category, where)


def scan_lines(lines: list[str], log_name: str) -> list[Finding]:
	"""Pure scan of a block of log lines -> grouped Findings.

	A primary error line opens a Finding; the immediately following stack-trace
	frames enrich it (and supply the source location). A run of orphan trace
	frames with no preceding primary becomes ONE ``stack_trace`` finding so we
	honor the trigger without emitting a finding per frame.
	"""
	findings: list[Finding] = []
	pending: Finding | None = None
	orphan: Finding | None = None

	def flush() -> None:
		nonlocal pending, orphan
		if pending is not None:
			findings.append(pending)
			pending = None
		if orphan is not None:
			# Drop orphan stack traces that never touch game code (no res://…​.gd
			# frame). A run of pure-engine C++ frames with no preceding primary is
			# benign engine noise — e.g. Godot's WebSocket module (wsl_peer.cpp)
			# rejecting a non-WS connection to the WS port (port scans / health
			# checks). Real GDScript errors always arrive with a primary line
			# (SCRIPT ERROR/FATAL/Cannot convert → kept as `pending`) or a .gd frame.
			if any(_GD_FRAME_RE.search(c) for c in orphan.context):
				findings.append(orphan)
			orphan = None

	for idx, raw in enumerate(lines):
		line = raw.rstrip("\n")
		if not line.strip():
			flush()
			continue
		category = classify_primary(line)
		if category is not None:
			flush()
			src_file, src_line = extract_source(line)
			pending = Finding(
				category=category,
				message=line.strip(),
				log_name=log_name,
				log_line_no=idx + 1,
				context=[line.strip()],
				source_file=src_file,
				source_line=src_line,
			)
			continue
		if is_trace_line(line):
			src_file, src_line = extract_source(line)
			if pending is not None:
				pending.context.append(line.strip())
				if pending.source_file is None and src_file is not None:
					pending.source_file = src_file
					pending.source_line = src_line
			else:
				if orphan is None:
					orphan = Finding(
						category="stack_trace",
						message=line.strip(),
						log_name=log_name,
						log_line_no=idx + 1,
						context=[line.strip()],
						source_file=src_file,
						source_line=src_line,
					)
				else:
					orphan.context.append(line.strip())
			continue
		# A non-trace, non-error line terminates any pending group.
		flush()

	flush()
	return findings


def finding_to_record(finding: Finding, report_id: int | None) -> dict:
	now = int(time.time())
	return {
		"ts": now,
		"iso": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(now)),
		"detector": "log_watchdog",
		"category": finding.category,
		"signature": finding.signature(),
		"log_file": "%s.log" % finding.log_name,
		"log_line_no": finding.log_line_no,
		"source_file": finding.source_file,
		"source_line": finding.source_line,
		"message": finding.message,
		"context": finding.context,
		"portal_report_id": report_id,
	}


class Watchdog:
	"""Stateful driver: owns the seen-signature set, findings file and DB path."""

	def __init__(self, findings_path: Path, db_path: Path | None):
		self.findings_path = findings_path
		self.db_path = db_path
		self.seen: set[str] = set()
		self._load_seen()

	def _load_seen(self) -> None:
		if not self.findings_path.exists():
			return
		with self.findings_path.open(encoding="utf-8") as fh:
			for line in fh:
				line = line.strip()
				if not line:
					continue
				try:
					sig = json.loads(line).get("signature")
				except json.JSONDecodeError:
					continue
				if sig:
					self.seen.add(sig)

	def process(self, findings: list[Finding]) -> list[dict]:
		"""File every NEW finding (dedupe by signature). Returns written records."""
		written: list[dict] = []
		self.findings_path.parent.mkdir(parents=True, exist_ok=True)
		for finding in findings:
			sig = finding.signature()
			if sig in self.seen:
				continue
			self.seen.add(sig)
			report_id = self._file_portal_report(finding)
			record = finding_to_record(finding, report_id)
			with self.findings_path.open("a", encoding="utf-8") as fh:
				fh.write(json.dumps(record) + "\n")
			written.append(record)
		return written

	def _file_portal_report(self, finding: Finding) -> int | None:
		db_path = self.db_path
		if db_path is None and portal is not None:
			db_path = portal.db_path()
		if db_path is None:
			return None
		try:
			conn = sqlite3.connect(db_path)
			conn.row_factory = sqlite3.Row
			try:
				if portal is not None:
					portal.init_db(conn)  # mirror the live schema + migrations exactly
				else:
					_init_reports_fallback(conn)
				body = "\n".join(finding.context)
				cur = conn.execute(
					"""
					INSERT INTO reports (
						created_at, tester, report_type, title, what_happened,
						expected, steps, where_text, screenshot_path, screenshot_original
					) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
					""",
					(
						int(time.time()),
						"watchdog",
						"Bug",
						finding.title(),
						body,
						"No SCRIPT ERROR / FATAL / type error in the server logs.",
						(
							"Auto-detected by scripts/qa/log_watchdog.py tailing "
							"/tmp/avalon-dev/*.log. signature=%s" % finding.signature()
						),
						"%s.log:%d" % (finding.log_name, finding.log_line_no),
						None,
						None,
					),
				)
				conn.commit()
				return int(cur.lastrowid)
			finally:
				conn.close()
		except sqlite3.Error as exc:  # pragma: no cover - DB errors are environmental
			print("[log_watchdog] portal insert failed: %s" % exc, file=sys.stderr)
			return None

	def run_once(self, log_paths: list[Path]) -> list[dict]:
		written: list[dict] = []
		for path in log_paths:
			if not path.exists():
				continue
			text = path.read_text(encoding="utf-8", errors="replace")
			findings = scan_lines(text.splitlines(), path.stem)
			written.extend(self.process(findings))
		return written

	def follow(self, log_paths: list[Path], poll: float = POLL_SECONDS) -> None:
		# Catch anything already logged, then tail from each file's current end.
		self.run_once(log_paths)
		offsets = {p: (p.stat().st_size if p.exists() else 0) for p in log_paths}
		print("[log_watchdog] following %s" % ", ".join(p.name for p in log_paths))
		while True:
			for path in log_paths:
				size = path.stat().st_size if path.exists() else 0
				start = offsets.get(path, 0)
				if size < start:  # rotated / truncated
					start = 0
				if size <= start:
					offsets[path] = size
					continue
				with path.open(encoding="utf-8", errors="replace") as fh:
					fh.seek(start)
					chunk = fh.read()
				offsets[path] = size
				findings = scan_lines(chunk.splitlines(), path.stem)
				for record in self.process(findings):
					print(
						"[log_watchdog] NEW %s (%s) report=%s"
						% (record["category"], record["signature"], record["portal_report_id"])
					)
			time.sleep(poll)


def _init_reports_fallback(conn: sqlite3.Connection) -> None:
	"""Minimal schema if the portal module is unavailable (keeps findings filing)."""
	conn.execute(
		"""
		CREATE TABLE IF NOT EXISTS reports (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			created_at INTEGER NOT NULL,
			tester TEXT NOT NULL,
			report_type TEXT NOT NULL,
			title TEXT NOT NULL,
			what_happened TEXT NOT NULL,
			expected TEXT NOT NULL,
			steps TEXT NOT NULL,
			where_text TEXT NOT NULL,
			screenshot_path TEXT,
			screenshot_original TEXT,
			status TEXT NOT NULL DEFAULT 'open',
			disposition TEXT,
			disposition_note TEXT,
			resolved_at INTEGER
		)
		"""
	)
	conn.commit()


def build_parser() -> argparse.ArgumentParser:
	parser = argparse.ArgumentParser(description="Avalon server-log error watchdog (T-561)")
	mode = parser.add_mutually_exclusive_group(required=True)
	mode.add_argument("--once", action="store_true", help="scan existing logs and exit")
	mode.add_argument("--follow", action="store_true", help="scan, then tail live")
	parser.add_argument("--log-dir", default=str(DEFAULT_LOG_DIR), help="server log directory")
	parser.add_argument(
		"--logs",
		default=",".join(DEFAULT_LOG_NAMES),
		help="comma-separated log basenames (default world,master,gateway)",
	)
	parser.add_argument("--findings", default=str(DEFAULT_FINDINGS), help="findings.jsonl path")
	parser.add_argument("--db", default=None, help="feedback DB path (default: portal DB)")
	return parser


def main(argv: list[str] | None = None) -> int:
	args = build_parser().parse_args(argv)
	log_dir = Path(args.log_dir)
	names = [n.strip() for n in args.logs.split(",") if n.strip()]
	log_paths = [log_dir / ("%s.log" % name) for name in names]
	db_path = Path(args.db) if args.db else None
	watchdog = Watchdog(Path(args.findings), db_path)
	if args.follow:
		try:
			watchdog.follow(log_paths)
		except KeyboardInterrupt:
			print("\n[log_watchdog] stopped")
		return 0
	written = watchdog.run_once(log_paths)
	print("[log_watchdog] filed %d new finding(s)" % len(written))
	for record in written:
		print("  - %s (%s)" % (record["category"], record["signature"]))
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
