from __future__ import annotations

import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request

from infra import gm_panel


class FakeOps:
	def __init__(self) -> None:
		self.calls: list[tuple[str, dict[str, object]]] = []

	def request(self, verb: str, params: dict[str, object]) -> dict[str, object]:
		self.calls.append((verb, params))
		if verb == "who":
			return {
				"ok": True,
				"result": {
					"players": [
						{
							"name": "Alice",
							"class": "mage",
							"level": 7,
							"zone": "Starter Vale",
							"pos": {"x": 1, "y": 2, "z": 0},
							"session_age_seconds": 90,
							"peer_id": 11,
						}
					]
				},
			}
		if verb == "audit_tail":
			return {
				"ok": True,
				"result": {"rows": [{"actor": "web-admin", "action": "who", "target": ""}]},
			}
		if verb == "first_session_funnel":
			return {
				"ok": True,
				"result": {
					"cohort_size": 3,
					"window_days": 14,
					"biggest_drop_stage": "first_kill",
					"biggest_drop_label": "First kill",
					"biggest_drop_count": 1,
					"stages": [
						{"stage": "world_entry", "label": "World entry (spawn)", "reached": 3,
							"pct_reached": 100.0, "median_seconds": 0.0,
							"median_seconds_from_launch": 41.0},
						{"stage": "first_kill", "label": "First kill", "reached": 2,
							"pct_reached": 66.7, "median_seconds": 27.5,
							"median_seconds_from_launch": 68.5},
						{"stage": "first_level_up", "label": "First level-up", "reached": 1,
							"pct_reached": 33.3, "median_seconds": 185.0,
							"median_seconds_from_launch": 226.0},
					],
					"last_event_counts": {"session_end": 3},
					# T-705: pre-spawn phases, session length, D1 return, refusal reasons.
					"boot": {
						"samples": 3,
						"phases": [
							{"phase": "launch_to_login", "label": "Launch → login submit",
								"median_seconds": 12.0},
							{"phase": "login_to_interactive",
								"label": "Login submit → world interactive",
								"median_seconds": 29.0},
							{"phase": "launch_to_interactive",
								"label": "Launch → world interactive (total dead air)",
								"median_seconds": 41.0},
						],
					},
					"session_length": {
						"samples": 2, "median_seconds": 900.0, "unfinished": 1
					},
					"d1_return": {"eligible": 2, "returned": 1, "pct": 50.0},
					"rejections": [
						{"reason": "too_far", "count": 2, "intents": ["turn_in"],
							"characters": ["Alice", "Bram"]},
						{"reason": "insufficient_resource", "count": 1,
							"intents": ["use_ability"], "characters": ["Alice"]},
					],
				},
			}
		return {"ok": True, "result": {"audit_id": 5}}


class GmPanelTests(unittest.TestCase):
	def setUp(self) -> None:
		self.ops = FakeOps()
		self.server = gm_panel.build_server("127.0.0.1", 0, "admin-token", self.ops)
		self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
		self.thread.start()
		self.base = f"http://127.0.0.1:{self.server.server_port}"

	def tearDown(self) -> None:
		self.server.shutdown()
		self.server.server_close()
		self.thread.join(timeout=2)

	def test_admin_token_gate_rejects_missing_and_wrong_token(self) -> None:
		for suffix in ("/", "/?token=wrong"):
			with self.assertRaises(urllib.error.HTTPError) as caught:
				urllib.request.urlopen(self.base + suffix)
			self.assertEqual(caught.exception.code, 403)
			caught.exception.close()

	def test_authorized_view_has_online_console_actions_and_loud_network_warning(self) -> None:
		with urllib.request.urlopen(self.base + "/?token=admin-token") as response:
			body = response.read().decode()
			cookie = response.headers.get("Set-Cookie", "")
		self.assertIn("Alice", body)
		self.assertIn("Message console", body)
		self.assertIn("Kick", body)
		self.assertIn("Ban", body)
		self.assertIn("Restart countdown", body)
		self.assertIn("Audit log", body)
		self.assertIn("NEVER PORT-FORWARD", body)
		self.assertIn("HttpOnly", cookie)
		self.assertEqual([call[0] for call in self.ops.calls[:2]], ["who", "audit_tail"])

	def test_page_polls_instead_of_reloading_and_has_pause_and_audit_filters(self) -> None:
		# The full-page meta refresh wiped half-typed messages/selections; the page now polls /data
		# and swaps only the tables, with a pause/resume toggle and per-column audit filters.
		with urllib.request.urlopen(self.base + "/?token=admin-token") as response:
			body = response.read().decode()
		self.assertNotIn('http-equiv="refresh"', body, "no whole-page reload")
		self.assertIn('id="toggle"', body, "pause/resume control present")
		self.assertIn('id="roster"', body)
		self.assertIn('id="auditbody"', body)
		self.assertIn('class="filters"', body, "per-column audit filter row present")
		self.assertIn("/data?token=", body, "page polls the JSON feed")

	def test_data_endpoint_returns_live_json_for_polling(self) -> None:
		import json as _json

		with urllib.request.urlopen(self.base + "/data?token=admin-token") as response:
			self.assertEqual(response.headers.get("Content-Type"), "application/json; charset=utf-8")
			payload = _json.loads(response.read().decode())
		self.assertEqual(payload["players"][0]["name"], "Alice")
		self.assertEqual(payload["audit"][0]["actor"], "web-admin")
		self.assertEqual(payload["offline"], "")

	def test_data_endpoint_requires_token(self) -> None:
		with self.assertRaises(urllib.error.HTTPError) as caught:
			urllib.request.urlopen(self.base + "/data")
		self.assertEqual(caught.exception.code, 403)
		caught.exception.close()

	def test_post_action_maps_confirmed_ban_reason_to_ops_protocol(self) -> None:
		data = urllib.parse.urlencode(
			{
				"token": "admin-token",
				"action": "ban",
				"player": "Alice",
				"reason": "confirmed exploit",
			}
		).encode()
		request = urllib.request.Request(self.base + "/action", data=data, method="POST")
		with urllib.request.urlopen(request) as response:
			self.assertEqual(response.status, 200)
		self.assertIn(("ban", {"player": "Alice", "reason": "confirmed exploit"}), self.ops.calls)

	def test_first_session_funnel_section_renders_readonly_stage_table(self) -> None:
		with urllib.request.urlopen(self.base + "/?token=admin-token") as response:
			body = response.read().decode()
		self.assertIn("First-session funnel", body)
		self.assertIn("World entry (spawn)", body)
		self.assertIn("First kill", body)
		self.assertIn("67%", body, "%-reached rendered")
		self.assertIn("28s", body, "sub-90s median shown in seconds")
		self.assertIn("3.1m", body, "185s median shown in minutes")
		self.assertIn("Largest drop-off", body, "biggest drop-off flagged")
		# Read-only: the funnel section must expose NO player-action form (ethical guardrail).
		funnel = body.split("First-session funnel", 1)[1].split("</section>", 1)[0]
		self.assertNotIn("<form", funnel, "funnel section is measurement-only, no levers")
		self.assertIn(("first_session_funnel", {"days": 14}), self.ops.calls)

	def test_funnel_shows_boot_phases_session_length_d1_and_refusals(self) -> None:
		# T-705: the funnel is measured from PROCESS LAUNCH, so the panel must show the pre-spawn
		# dead air, a launch-anchored column per stage, how long the session lasted, whether they
		# came back on day 2, and which refusals they hit — all read-only.
		with urllib.request.urlopen(self.base + "/?token=admin-token") as response:
			body = response.read().decode()
		funnel = body.split("First-session funnel", 1)[1].split("</section>", 1)[0]
		self.assertIn("Launch → world interactive (total dead air)", funnel)
		self.assertIn("41s", funnel, "total pre-spawn dead air rendered")
		self.assertIn("From launch", funnel, "every stage carries a launch-anchored column")
		self.assertIn("3.8m", funnel, "a stage median from launch (226s) renders in minutes")
		self.assertIn("15.0m", funnel, "median session length rendered")
		self.assertIn("Came back on day 2", funnel)
		self.assertIn("too_far", funnel, "refusal reasons are listed")
		self.assertIn("Bram", funnel, "refusals are queryable per character")
		self.assertNotIn("<form", funnel, "still measurement-only — no per-player lever")

	def test_funnel_without_boot_reports_says_so_instead_of_faking_zero(self) -> None:
		# An older client sends no boot timing; the panel must not render 0s dead air as if measured.
		self.assertIn(
			"no client boot-timing reports",
			gm_panel.render_boot_phases({"boot": {"samples": 0, "phases": []}}),
		)

	def test_funnel_absent_when_world_offline(self) -> None:
		self.ops.request = lambda verb, params: {"ok": False, "error": "world offline"}
		with urllib.request.urlopen(self.base + "/?token=admin-token") as response:
			body = response.read().decode()
		self.assertIn("First-session funnel", body)
		self.assertIn("Funnel unavailable", body)

	def test_protocol_request_never_sends_admin_browser_token(self) -> None:
		payload = gm_panel.ops_request("ops-secret", "web-admin", "who", {})
		self.assertEqual(
			payload,
			{"secret": "ops-secret", "actor": "web-admin", "verb": "who", "params": {}},
		)
		self.assertNotIn("admin-token", str(payload))


if __name__ == "__main__":
	unittest.main()
