extends RefCounted

# T-494 carve: the net-smoke handshake probe + harness result writer, lifted out of main.gd so the
# T-494 login-gate additions keep the client root under the 1000-line gdlint cap. These run only on
# the env-gated E2E/smoke paths (AVALON_NET_SMOKE / AVALON_RESULT_FILE); they operate on the client
# root ("main") they are handed and keep the exact behaviour that previously lived in main.gd.


# Smoke step 1 (T-603): accept_quest is giver-proximity gated server-side, so the smoke can no
# longer accept from wherever the login spawn/restore landed. On the first positions broadcast
# that carries our own entry, walk to the drillmaster's anchor (q_tut_01's giver, 12.5/9.0 — the
# T-707 q007 retirement moved the smoke fixture to the tutorial opener; delta rides the same
# reliable in-order channel as the accept, so the move lands first), then accept.
# Gated + once-latched HERE (via meta, not a main.gd var) so main.gd stays at its line cap.
static func move_to_giver_and_accept(main, data: Dictionary) -> void:
	if not main._smoke or bool(main.get_meta("smoke_accept_sent", false)):
		return
	for p: Dictionary in data.get("players", []):
		if int(p.get("peer_id", -1)) == main._my_peer_id:
			print("[client] net-smoke: move to giver + accept_quest q_tut_01")
			main.set_meta("smoke_accept_sent", true)
			main._net.request_move(12.5 - float(p.get("x", 0.0)), 9.0 - float(p.get("y", 0.0)))
			main._net.accept_quest("q_tut_01")
			return


# Smoke step 2: the accept reply landed → record it and ask for NPC indicators (proves the
# round-trip plus the marker layer). Every "result"-category reply lands here in smoke mode, and
# T-710's first-entry talk_result push (ok:true, pre-accept) now arrives unprompted — only the
# actual accept reply may grade the round-trip, or the smoke verdict lies.
static func on_accept(main, data: Dictionary) -> void:
	if str(data.get("type", "")) != "accept_quest_result":
		return
	main._accept_ok = bool(data.get("ok", false))
	print("[client] net-smoke accept reply: %s" % str(data))
	main._awaiting_indicators = true
	main._net.request_npc_indicators()


# Smoke step 3: markers populated from the real npc_indicators reply over ENet → write the result.
static func finish(main) -> void:
	main._awaiting = false
	main._awaiting_indicators = false
	var markers: int = main.npc_markers.marker_count()
	var ok: bool = main._accept_ok and markers > 0
	var summary := "[client] net-smoke done: accept_ok=%s marker_nodes=%d kit_size=%d"
	print(summary % [str(main._accept_ok), markers, main._kit.size()])
	write(
		main._result_file,
		{
			"handshake_ok": true,
			"accept_ok": main._accept_ok,
			"marker_nodes": markers,
			# T-072: the server offers the class kit right after handshake_ok — a routed router
			# populates _kit before the smoke finishes; 0 means class_kit was dropped.
			"kit_size": main._kit.size(),
		}
	)
	main.get_tree().quit(0 if ok else 1)


static func write(result_file: String, payload: Dictionary) -> void:
	if result_file != "":
		var f := FileAccess.open(result_file, FileAccess.WRITE)
		if f:
			f.store_string(JSON.stringify(payload))
			f.close()
