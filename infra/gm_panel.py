#!/usr/bin/env python3
"""T-511 localhost GM panel. Stdlib-only; never expose this HTTP server to the internet."""

from __future__ import annotations

import argparse
import html
import json
import os
import secrets
import socket
import sys
from http import HTTPStatus
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import parse_qs, urlparse


DEFAULT_ADMIN_BIND = "127.0.0.1"
DEFAULT_ADMIN_PORT = 8095
DEFAULT_OPS_PORT = 9215
MAX_BODY = 64 * 1024
MAX_OPS_RESPONSE = 2 * 1024 * 1024
COOKIE_NAME = "avalon_admin"


def ops_request(secret: str, actor: str, verb: str, params: dict[str, object]) -> dict[str, object]:
	return {"secret": secret, "actor": actor, "verb": verb, "params": params}


class OpsClient:
	def __init__(self, secret: str, port: int, actor: str) -> None:
		self.secret = secret
		self.port = port
		self.actor = actor

	def request(self, verb: str, params: dict[str, object]) -> dict[str, object]:
		payload = json.dumps(ops_request(self.secret, self.actor, verb, params)) + "\n"
		try:
			with socket.create_connection(("127.0.0.1", self.port), timeout=3.0) as conn:
				conn.sendall(payload.encode())
				chunks: list[bytes] = []
				total = 0
				while True:
					chunk = conn.recv(65536)
					if not chunk:
						break
					chunks.append(chunk)
					total += len(chunk)
					if total > MAX_OPS_RESPONSE:
						raise RuntimeError("ops response too large")
					if b"\n" in chunk:
						break
			raw = b"".join(chunks).split(b"\n", 1)[0]
			parsed = json.loads(raw)
			if not isinstance(parsed, dict):
				raise RuntimeError("invalid ops response")
			return parsed
		except (OSError, ValueError, RuntimeError) as exc:
			return {"ok": False, "error": f"world offline: {exc}"}


class GmPanelHandler(BaseHTTPRequestHandler):
	server: "GmPanelServer"

	def do_GET(self) -> None:  # noqa: N802 - stdlib handler name
		parsed = urlparse(self.path)
		token = parse_qs(parsed.query).get("token", [""])[0]
		if not self._authorized(token):
			self._forbidden()
			return
		if parsed.path == "/data":
			self._render_data()
			return
		if parsed.path not in ("/", "/index.html"):
			self.send_error(HTTPStatus.NOT_FOUND)
			return
		self._render_page(set_cookie=bool(token))

	def do_POST(self) -> None:  # noqa: N802 - stdlib handler name
		if urlparse(self.path).path != "/action":
			self.send_error(HTTPStatus.NOT_FOUND)
			return
		length = int(self.headers.get("Content-Length", "0"))
		if length <= 0 or length > MAX_BODY:
			self.send_error(HTTPStatus.BAD_REQUEST)
			return
		form = {key: values[0] for key, values in parse_qs(self.rfile.read(length).decode()).items()}
		if not self._authorized(form.get("token", "")):
			self._forbidden()
			return
		verb, params = action_request(form)
		if verb == "":
			self._render_page(alert="Invalid panel action.")
			return
		result = self.server.ops.request(verb, params)
		alert = "Action accepted." if result.get("ok") else str(result.get("error", "Action failed"))
		self._render_page(alert=alert)

	def _authorized(self, supplied: str) -> bool:
		token = supplied or self._cookie_token()
		return bool(token) and secrets.compare_digest(token, self.server.admin_token)

	def _cookie_token(self) -> str:
		cookie = SimpleCookie(self.headers.get("Cookie", ""))
		return cookie[COOKIE_NAME].value if COOKIE_NAME in cookie else ""

	def _forbidden(self) -> None:
		body = b"GM panel token required.\n"
		self.send_response(HTTPStatus.FORBIDDEN)
		self.send_header("Content-Type", "text/plain; charset=utf-8")
		self.send_header("Content-Length", str(len(body)))
		self.end_headers()
		self.wfile.write(body)

	def _live_state(self) -> tuple[list, list, str]:
		who = self.server.ops.request("who", {})
		audit = self.server.ops.request("audit_tail", {"limit": 50})
		players = who.get("result", {}).get("players", []) if who.get("ok") else []
		rows = audit.get("result", {}).get("rows", []) if audit.get("ok") else []
		offline = "" if who.get("ok") else str(who.get("error", "world offline"))
		return players, rows, offline

	def _funnel(self) -> dict[str, Any]:
		# T-528: read-only first-session onramp funnel. Fetched on page render (not the 5s poll) since
		# it is a heavier rollup over the whole cohort, and it never changes second-to-second.
		reply = self.server.ops.request("first_session_funnel", {"days": 14})
		return reply.get("result", {}) if reply.get("ok") else {}

	def _render_data(self) -> None:
		# JSON feed the page polls so auto-refresh updates the roster/audit tables WITHOUT reloading
		# the page (which would wipe half-typed messages and dropdown selections).
		players, rows, offline = self._live_state()
		body = json.dumps({"players": players, "audit": rows, "offline": offline}).encode()
		self.send_response(HTTPStatus.OK)
		self.send_header("Content-Type", "application/json; charset=utf-8")
		self.send_header("Content-Length", str(len(body)))
		self.send_header("Cache-Control", "no-store")
		self.end_headers()
		self.wfile.write(body)

	def _render_page(self, alert: str = "", set_cookie: bool = False) -> None:
		players, rows, offline = self._live_state()
		body = render_page(
			players, rows, self.server.admin_token, alert, offline, self._funnel()
		).encode()
		self.send_response(HTTPStatus.OK)
		self.send_header("Content-Type", "text/html; charset=utf-8")
		self.send_header("Content-Length", str(len(body)))
		self.send_header("Cache-Control", "no-store")
		self.send_header("X-Frame-Options", "DENY")
		if set_cookie:
			self.send_header(
				"Set-Cookie", f"{COOKIE_NAME}={self.server.admin_token}; HttpOnly; SameSite=Strict; Path=/"
			)
		self.end_headers()
		self.wfile.write(body)

	def log_message(self, format: str, *args: Any) -> None:
		sys.stderr.write("[gm-panel] " + format % args + "\n")


class GmPanelServer(ThreadingHTTPServer):
	admin_token: str
	ops: Any


def build_server(host: str, port: int, admin_token: str, ops: Any) -> GmPanelServer:
	server = GmPanelServer((host, port), GmPanelHandler)
	server.admin_token = admin_token
	server.ops = ops
	return server


def action_request(form: dict[str, str]) -> tuple[str, dict[str, object]]:
	action = form.get("action", "")
	if action == "broadcast":
		return action, {"text": form.get("text", "")}
	if action == "whisper":
		return action, {"player": form.get("player", ""), "text": form.get("text", "")}
	if action == "msg_group":
		try:
			group_id = int(form.get("group_id", "0"))
		except ValueError:
			group_id = 0
		return action, {
			"kind": form.get("kind", ""),
			"id": group_id,
			"text": form.get("text", ""),
		}
	if action in ("kick", "ban"):
		return action, {"player": form.get("player", ""), "reason": form.get("reason", "")}
	if action == "announce":
		try:
			minutes = int(form.get("minutes", "0"))
		except ValueError:
			minutes = 0
		return action, {"minutes": minutes, "reason": form.get("reason", "")}
	return "", {}


# Client-side live refresh. Polls /data and swaps ONLY the roster + audit table bodies (and the
# player dropdowns, preserving the current selection) so typing/selecting in the forms is never
# clobbered. Pause/resume halts polling; the audit log has per-column Excel-style filters.
PANEL_JS = r"""
var paused = false;
function cell(t){ var td=document.createElement('td'); td.textContent = (t===null||t===undefined)?'':String(t); return td; }
function rebuildRoster(players){
  var tb=document.getElementById('roster'); if(!tb) return; tb.innerHTML='';
  players.forEach(function(p){
    var tr=document.createElement('tr');
    tr.appendChild(cell(p.name));
    tr.appendChild(cell((p.class||'')+' '+(p.level==null?1:p.level)));
    tr.appendChild(cell(p.zone));
    tr.appendChild(cell(JSON.stringify(p.pos||{})));
    tr.appendChild(cell((p.session_age_seconds||0)+'s'));
    tr.appendChild(cell(p.peer_id||0));
    tb.appendChild(tr);
  });
  var c=document.getElementById('online-count'); if(c) c.textContent=players.length;
  document.querySelectorAll('.player-select').forEach(function(sel){
    var cur=sel.value; sel.innerHTML='';
    players.forEach(function(p){ var o=document.createElement('option'); o.value=p.name||''; o.textContent=p.name||''; sel.appendChild(o); });
    for(var i=0;i<sel.options.length;i++){ if(sel.options[i].value===cur){ sel.value=cur; break; } }
  });
}
function rebuildAudit(rows){
  var tb=document.getElementById('auditbody'); if(!tb) return; tb.innerHTML='';
  rows.forEach(function(r){
    var tr=document.createElement('tr');
    tr.appendChild(cell(r.created_at));
    tr.appendChild(cell(r.actor));
    tr.appendChild(cell(r.action));
    tr.appendChild(cell(r.target));
    tr.appendChild(cell(r.reason));
    tb.appendChild(tr);
  });
  applyFilters();
}
function applyFilters(){
  var inputs=[].slice.call(document.querySelectorAll('#audit .filters input'));
  var terms=inputs.map(function(i){ return i.value.toLowerCase(); });
  document.querySelectorAll('#auditbody tr').forEach(function(tr){
    var cells=tr.children;
    var show=terms.every(function(t,idx){ return !t || (cells[idx] && cells[idx].textContent.toLowerCase().indexOf(t)>=0); });
    tr.style.display = show ? '' : 'none';
  });
}
function poll(){
  if(paused) return;
  fetch('/data?token='+encodeURIComponent(TOKEN)).then(function(r){ return r.json(); }).then(function(d){
    rebuildRoster(d.players||[]);
    rebuildAudit(d.audit||[]);
    var s=document.getElementById('world-status');
    if(s) s.textContent = d.offline ? ('WORLD OFFLINE — '+d.offline) : '';
  }).catch(function(){});
}
document.addEventListener('DOMContentLoaded', function(){
  var btn=document.getElementById('toggle');
  if(btn) btn.addEventListener('click', function(){
    paused=!paused;
    btn.textContent = paused ? 'Resume auto-refresh' : 'Pause auto-refresh';
    var st=document.getElementById('refresh-status');
    if(st){ st.textContent = paused ? 'auto-refresh PAUSED' : 'auto-refresh on'; }
    if(!paused) poll();
  });
  document.querySelectorAll('#audit .filters input').forEach(function(i){ i.addEventListener('input', applyFilters); });
  setInterval(poll, POLL_MS);
});
"""


def _fmt_seconds(value: object) -> str:
	# Funnel medians arrive as seconds-from-entry; -1 means "nobody reached this stage".
	try:
		secs = float(value)
	except (TypeError, ValueError):
		return "—"
	if secs < 0:
		return "—"
	if secs < 90:
		return f"{secs:.0f}s"
	return f"{secs / 60.0:.1f}m"


def render_boot_phases(funnel: dict[str, object]) -> str:
	# T-705: the pre-spawn dead air (launch → login → interactive). Reported by the client as two
	# durations; a cohort with no boot samples says so rather than drawing an empty table.
	e = html.escape
	boot = funnel.get("boot", {}) or {}
	phases = boot.get("phases", []) or []
	samples = int(boot.get("samples", 0) or 0)
	if not phases or samples == 0:
		return (
			'<p style="color:#9db4d0">Boot phases: no client boot-timing reports in this window '
			"(older clients do not send them).</p>"
		)
	rows = "".join(
		"<tr>"
		f"<td>{e(str(p.get('label', p.get('phase', ''))))}</td>"
		f"<td>{e(_fmt_seconds(p.get('median_seconds', -1)))}</td>"
		"</tr>"
		for p in phases
	)
	return (
		f'<p style="color:#9db4d0">Before spawn — {samples} client boot reports.</p>'
		"<table><thead><tr><th>Boot phase</th><th>Median</th></tr></thead>"
		f"<tbody>{rows}</tbody></table>"
	)


def render_rejections(funnel: dict[str, object]) -> str:
	# T-705: the failure reasons a first session actually hit, worst first. Each row names the
	# characters who hit it — informational only; there is no per-player action anywhere here.
	e = html.escape
	rejections = funnel.get("rejections", []) or []
	if not rejections:
		return '<p style="color:#9db4d0">No refusals recorded in this cohort.</p>'
	rows = "".join(
		"<tr>"
		f"<td>{e(str(r.get('reason', '')))}</td>"
		f"<td>{int(r.get('count', 0))}</td>"
		f"<td>{e(', '.join(str(i) for i in (r.get('intents') or [])))}</td>"
		f"<td>{e(', '.join(str(c) for c in (r.get('characters') or [])))}</td>"
		"</tr>"
		for r in rejections
	)
	return (
		"<table><thead><tr><th>Refusal</th><th>Players hit</th><th>While doing</th>"
		"<th>Characters</th></tr></thead>"
		f"<tbody>{rows}</tbody></table>"
	)


def render_funnel(funnel: dict[str, object]) -> str:
	# T-528: read-only first-session hook funnel. Purely informational (improve the onramp per §5) —
	# there is NO per-player action here, by design (the ticket's ethical guardrail).
	# T-705: measured from PROCESS LAUNCH — boot phases, a launch-anchored median per stage, session
	# length and the D1 return rate ride the same read-only rollup.
	e = html.escape
	stages = funnel.get("stages", []) or []
	if not stages:
		# cohort_rollup always returns every stage row, so an empty list only means no reply reached
		# the master (world offline / funnel RPC unavailable).
		return (
			'<section><h2>First-session funnel</h2>'
			'<p style="color:#9db4d0">Funnel unavailable — world offline.</p></section>'
		)
	cohort = int(funnel.get("cohort_size", 0) or 0)
	drop_label = str(funnel.get("biggest_drop_label", ""))
	window = int(funnel.get("window_days", 14) or 14)
	empty_note = " No first-session cohort in the window yet." if cohort == 0 else ""
	rows = "".join(
		"<tr>"
		f"<td>{e(str(s.get('label', s.get('stage', ''))))}</td>"
		f"<td>{int(s.get('reached', 0))}</td>"
		f"<td>{float(s.get('pct_reached', 0.0)):.0f}%</td>"
		f"<td>{e(_fmt_seconds(s.get('median_seconds', -1)))}</td>"
		f"<td>{e(_fmt_seconds(s.get('median_seconds_from_launch', -1)))}</td>"
		"</tr>"
		for s in stages
	)
	flag = (
		f'<p class="alert">Largest drop-off: <b>{e(drop_label)}</b> '
		f"({int(funnel.get('biggest_drop_count', 0))} of the cohort dropped before this stage).</p>"
		if drop_label
		else ""
	)
	length = funnel.get("session_length", {}) or {}
	d1 = funnel.get("d1_return", {}) or {}
	tail = (
		f'<p style="color:#9db4d0">First session lasted '
		f"<b>{e(_fmt_seconds(length.get('median_seconds', -1)))}</b> (median of "
		f"{int(length.get('samples', 0) or 0)} finished sessions; "
		f"{int(length.get('unfinished', 0) or 0)} still open). "
		f"Came back on day 2: <b>{int(d1.get('returned', 0) or 0)}</b> of "
		f"{int(d1.get('eligible', 0) or 0)} eligible "
		f"({float(d1.get('pct', 0.0) or 0.0):.0f}%).</p>"
	)
	return (
		'<section><h2>First-session funnel</h2>'
		f'<p style="color:#9db4d0">Newest cohort — {cohort} new players, last {window} days. '
		f"Stage times run from world entry (spawn) and, where the client reported its boot, from "
		f"process launch.{e(empty_note)}</p>"
		f"{render_boot_phases(funnel)}"
		f"{flag}"
		'<table><thead><tr><th>Stage</th><th>Reached</th><th>% of cohort</th>'
		"<th>From spawn</th><th>From launch</th></tr></thead>"
		f"<tbody>{rows}</tbody></table>"
		f"{tail}"
		"<h3>Refusals hit in the first session</h3>"
		f"{render_rejections(funnel)}</section>"
	)


def render_page(
	players: list[dict[str, object]],
	audit_rows: list[dict[str, object]],
	token: str,
	alert: str,
	offline: str,
	funnel: dict[str, object] | None = None,
) -> str:
	e = html.escape
	options = "".join(
		f'<option value="{e(str(player.get("name", "")))}">{e(str(player.get("name", "")))}</option>'
		for player in players
	)
	player_rows = "".join(
		"<tr>"
		f"<td>{e(str(p.get('name', '')))}</td><td>{e(str(p.get('class', '')))} {int(p.get('level', 1))}</td>"
		f"<td>{e(str(p.get('zone', '')))}</td><td>{e(str(p.get('pos', {})))}</td>"
		f"<td>{int(p.get('session_age_seconds', 0))}s</td><td>{int(p.get('peer_id', 0))}</td>"
		"</tr>"
		for p in players
	)
	audit_html = "".join(
		"<tr>"
		f"<td>{e(str(row.get('created_at', '')))}</td><td>{e(str(row.get('actor', '')))}</td>"
		f"<td>{e(str(row.get('action', '')))}</td><td>{e(str(row.get('target', '')))}</td>"
		f"<td>{e(str(row.get('reason', '')))}</td>"
		"</tr>"
		for row in audit_rows
	)
	hidden = f'<input type="hidden" name="token" value="{e(token)}">'
	token_js = json.dumps(token)  # safe JS string literal for the poll fetch
	status = f'WORLD OFFLINE — {e(offline)}' if offline else ""
	message = f'<p class="alert">{e(alert)}</p>' if alert else ""
	return f"""<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Avalon GM Panel</title>
<style>
body{{font:15px system-ui;background:#10131a;color:#e9dfc5;margin:24px}} h1,h2{{color:#e6b85c}}
.warning{{background:#6b1f16;color:white;padding:14px;font-weight:800}} .grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(310px,1fr));gap:16px}}
section{{border:1px solid #4b5363;padding:16px;background:#171c26}} table{{width:100%;border-collapse:collapse}} td,th{{border-bottom:1px solid #343b49;padding:6px;text-align:left}}
input,select,textarea,button{{margin:4px;padding:7px;background:#252c38;color:#f5ecd7;border:1px solid #596477}} button{{cursor:pointer}} .danger{{color:#ffaf8f}} .error{{color:#ff8d71}} .alert{{color:#9de0a5}}
.bar{{display:flex;align-items:center;gap:12px;margin:8px 0}} #toggle{{background:#3a4658}} #refresh-status{{color:#9db4d0;font-size:.9rem}}
.filters input{{width:92%;margin:2px 0;padding:4px;font-size:.85rem}} .filters th{{padding:2px 6px}}
</style></head><body>
<p class="warning">LOCAL/LAN OPERATIONS ONLY — NEVER PORT-FORWARD 8095 OR EXPOSE THIS PANEL TO THE INTERNET.</p>
<h1>Avalon GM Panel</h1><p class="error" id="world-status">{status}</p>{message}
<div class="bar"><button type="button" id="toggle">Pause auto-refresh</button><span id="refresh-status">auto-refresh on</span></div>
<section><h2>Online players (<span id="online-count">{len(players)}</span>)</h2><table><thead><tr><th>Name</th><th>Class / level</th><th>Zone</th><th>Position</th><th>Session</th><th>Peer</th></tr></thead><tbody id="roster">{player_rows}</tbody></table></section>
{render_funnel(funnel or {})}
<div class="grid">
<section><h2>Message console</h2>
<form method="post" action="/action">{hidden}<input type="hidden" name="action" value="broadcast"><textarea name="text" required placeholder="Message all players"></textarea><button>Broadcast all</button></form>
<form method="post" action="/action">{hidden}<input type="hidden" name="action" value="whisper"><select class="player-select" name="player">{options}</select><textarea name="text" required placeholder="Private GM message"></textarea><button>Whisper player</button></form>
<form method="post" action="/action">{hidden}<input type="hidden" name="action" value="msg_group"><select name="kind"><option>party</option><option>guild</option><option>raid</option></select><input name="group_id" type="number" min="1" required placeholder="Server group ID"><textarea name="text" required></textarea><button>Message group</button></form>
</section>
<section><h2>Player actions</h2>
<form method="post" action="/action" onsubmit="return confirm('Kick this player?')">{hidden}<input type="hidden" name="action" value="kick"><select class="player-select" name="player">{options}</select><input name="reason" required placeholder="Required reason"><button class="danger">Kick</button></form>
<form method="post" action="/action" onsubmit="return confirm('BAN and kick this account?')">{hidden}<input type="hidden" name="action" value="ban"><select class="player-select" name="player">{options}</select><input name="reason" required placeholder="Required reason"><button class="danger">Ban</button></form>
</section>
<section><h2>Restart countdown</h2><form method="post" action="/action" onsubmit="return confirm('Start the maintenance countdown?')">{hidden}<input type="hidden" name="action" value="announce"><input name="minutes" type="number" min="1" max="1440" value="10" required><input name="reason" required placeholder="Maintenance reason"><button>Announce countdown</button></form></section>
</div>
<section><h2>Audit log</h2><table id="audit"><thead><tr><th>When</th><th>Actor</th><th>Action</th><th>Target</th><th>Reason</th></tr>
<tr class="filters"><th><input placeholder="filter…" data-col="0"></th><th><input placeholder="filter…" data-col="1"></th><th><input placeholder="filter…" data-col="2"></th><th><input placeholder="filter…" data-col="3"></th><th><input placeholder="filter…" data-col="4"></th></tr></thead>
<tbody id="auditbody">{audit_html}</tbody></table></section>
<script>var TOKEN={token_js};var POLL_MS=5000;{PANEL_JS}</script>
</body></html>"""


def required_env(name: str) -> str:
	value = os.environ.get(name, "").strip()
	if not value:
		raise RuntimeError(f"{name} is required")
	return value


def main() -> int:
	parser = argparse.ArgumentParser(description="Avalon localhost GM panel — NEVER port-forward")
	parser.add_argument("--host", default=os.environ.get("AVALON_ADMIN_BIND", DEFAULT_ADMIN_BIND))
	parser.add_argument("--port", type=int, default=int(os.environ.get("AVALON_ADMIN_PORT", DEFAULT_ADMIN_PORT)))
	args = parser.parse_args()
	try:
		admin_token = required_env("AVALON_ADMIN_TOKEN")
		ops_secret = required_env("AVALON_OPS_SECRET")
	except RuntimeError as exc:
		print(f"FATAL: {exc}", file=sys.stderr)
		return 2
	ops_port = int(os.environ.get("AVALON_OPS_PORT", DEFAULT_OPS_PORT))
	actor = os.environ.get("AVALON_ADMIN_ACTOR", "web-admin").strip() or "web-admin"
	server = build_server(args.host, args.port, admin_token, OpsClient(ops_secret, ops_port, actor))
	print("WARNING: GM PANEL IS LOCAL/LAN ONLY. NEVER PORT-FORWARD THIS PORT.", file=sys.stderr)
	print(f"[gm-panel] http://{args.host}:{args.port}/?token=<AVALON_ADMIN_TOKEN>")
	try:
		server.serve_forever()
	except KeyboardInterrupt:
		pass
	finally:
		server.server_close()
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
