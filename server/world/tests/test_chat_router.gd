# T-361: the pure channel-routing matrix — range cutoff, party isolation, and (critically) the
# T-331 soft-instance boundary for local /say. No live server; every case is a positions snapshot.

extends GutTest

const _ROUTER = preload("res://scripts/chat_router.gd")


func _pos(x: float, y: float, instance_id: int = 0, username: String = "u") -> Dictionary:
	return {"username": username, "x": x, "y": y, "z": 0.0, "instance_id": instance_id}


func test_say_reaches_only_within_radius() -> void:
	var positions := {
		1: _pos(0.0, 0.0),  # sender
		2: _pos(10.0, 0.0),  # in range
		3: _pos(100.0, 0.0),  # far out of range
	}
	var got := _ROUTER.recipients("say", 1, positions)
	assert_true(got.has(1), "sender hears their own line")
	assert_true(got.has(2), "a nearby peer hears the say")
	assert_false(got.has(3), "a peer beyond SAY_RADIUS does not")


func test_say_radius_is_a_hard_cutoff() -> void:
	var r: float = _ROUTER.SAY_RADIUS
	var positions := {
		1: _pos(0.0, 0.0),
		2: _pos(r, 0.0),  # exactly on the boundary — inclusive
		3: _pos(r + 0.5, 0.0),  # just past
	}
	var got := _ROUTER.recipients("say", 1, positions)
	assert_true(got.has(2), "on the boundary is heard (<=)")
	assert_false(got.has(3), "just past the boundary is not")


func test_say_respects_instance_boundary() -> void:
	# A shout in a crypt instance (id 5) must never leak to a co-located open-world peer (id 0).
	var positions := {
		1: _pos(0.0, 0.0, 5),  # sender, in instance 5
		2: _pos(1.0, 0.0, 5),  # same instance, in range
		3: _pos(1.0, 0.0, 0),  # SAME coords, open world — must NOT hear
	}
	var got := _ROUTER.recipients("say", 1, positions)
	assert_true(got.has(2), "same-instance neighbour hears the say")
	assert_false(got.has(3), "identical position in another instance is deaf to it")


func test_party_reaches_members_regardless_of_range_or_instance() -> void:
	var positions := {
		1: _pos(0.0, 0.0, 0),
		2: _pos(999.0, 0.0, 7),  # far away AND in another instance
		3: _pos(5.0, 0.0, 0),  # nearby but NOT in the party
	}
	var party_of := {1: 100, 2: 100}
	var parties := {100: {"members": [1, 2], "leader": 1}}
	var got := _ROUTER.recipients("party", 1, positions, party_of, parties)
	assert_true(got.has(1) and got.has(2), "both party members hear it across range + instance")
	assert_false(got.has(3), "a non-member standing right there does not")


func test_party_empty_when_not_in_a_party() -> void:
	var got := _ROUTER.recipients("party", 1, {1: _pos(0, 0)}, {}, {})
	assert_eq(got.size(), 0, "no party -> no recipients (caller replies not_in_party)")


func test_world_reaches_everyone_online() -> void:
	var positions := {1: _pos(0, 0, 0), 2: _pos(999, 0, 3), 3: _pos(-50, 20, 0)}
	var got := _ROUTER.recipients("world", 1, positions)
	assert_eq(got.size(), 3, "world is a global fan-out to every online peer")


func test_unknown_channel_routes_nowhere() -> void:
	# T-626 shipped whisper; yell (also planned by T-361) is the piece that STILL never shipped —
	# it's the live stand-in for "a channel string the router doesn't recognise".
	assert_eq(_ROUTER.recipients("yell", 1, {1: _pos(0, 0)}).size(), 0)
	assert_false(_ROUTER.is_channel("yell"))
	assert_true(_ROUTER.is_channel("say"))


# T-362 guild channel: routes to every online peer sharing the sender's non-zero guild_id,
# regardless of range or instance (like party) — membership id lives in the world's guild_of cache.
func test_guild_reaches_guildmates_regardless_of_range_or_instance() -> void:
	var positions := {1: _pos(0, 0, 0), 2: _pos(999, 0, 7), 3: _pos(2, 0, 0)}
	var guild_of := {1: 42, 2: 42, 3: 99}  # 1+2 same guild; 3 in another guild
	var got := _ROUTER.recipients("guild", 1, positions, {}, {}, guild_of)
	assert_true(got.has(1) and got.has(2), "guildmates hear it across range + instance")
	assert_false(got.has(3), "a different guild never hears the line")
	assert_true(_ROUTER.is_channel("guild"))


func test_guildless_sender_has_no_guild_recipients() -> void:
	# guild_id 0 / absent = guildless — empty set (caller replies not_in_guild).
	assert_eq(_ROUTER.recipients("guild", 1, {1: _pos(0, 0)}, {}, {}, {1: 0}).size(), 0)
	assert_eq(_ROUTER.recipients("guild", 1, {1: _pos(0, 0)}, {}, {}, {}).size(), 0)


func test_help_reaches_only_server_subscribed_online_players() -> void:
	var positions := {1: _pos(0, 0), 2: _pos(500, 0), 3: _pos(-500, 0)}
	var got := _ROUTER.recipients("help", 1, positions, {}, {}, {}, {1: true, 2: true})
	assert_true(got.has(1) and got.has(2), "help crosses range for subscribed players")
	assert_false(got.has(3), "an opted-out player does not receive help")
	assert_true(_ROUTER.is_channel("help"))


# T-626: whisper is a targeted 1:1 — resolved by exact username match against the online snapshot,
# with no range/instance check (cross-zone by design). The sender always hears their own echo; a
# nearby non-target never does.
func test_whisper_reaches_only_the_named_target_regardless_of_range_or_instance() -> void:
	var positions := {
		1: _pos(0.0, 0.0, 0, "Alice"),
		2: _pos(999.0, 0.0, 7, "Bob"),  # far away AND in another instance
		3: _pos(1.0, 0.0, 0, "Carol"),  # nearby but NOT the whisper target
	}
	var got := _ROUTER.recipients("whisper", 1, positions, {}, {}, {}, {}, "Bob")
	assert_true(got.has(1), "the sender hears their own echo")
	assert_true(got.has(2), "the named target hears it across range + instance")
	assert_false(got.has(3), "a nearby non-target does not")
	assert_true(_ROUTER.is_channel("whisper"))


func test_whisper_unknown_name_routes_nowhere() -> void:
	var positions := {1: _pos(0.0, 0.0, 0, "Alice")}
	assert_eq(_ROUTER.recipients("whisper", 1, positions, {}, {}, {}, {}, "Ghost").size(), 0)


func test_whisper_offline_name_routes_nowhere() -> void:
	# "offline" simply means absent from the online positions snapshot — same empty-set outcome as
	# an unknown name; the caller (chat_service) replies "unknown_player" either way.
	var positions := {1: _pos(0.0, 0.0, 0, "Alice"), 2: _pos(5.0, 0.0, 0, "Bob")}
	assert_eq(_ROUTER.recipients("whisper", 1, positions, {}, {}, {}, {}, "Zed").size(), 0)
