extends GutTest

# T-401: the routed-reply hub that lets a new panel take server replies without a new main.gd or
# client_net handler line (both at their gdlint/public caps). A panel register()s the reply types it
# owns; route() fans the incoming reply to the registered callable by its `type`. Pure dispatcher —
# unknown types no-op (an older client must survive a newer server's reply), last register wins.

const ReplyRouter = preload("res://scripts/net/reply_router.gd")


func test_route_dispatches_to_the_registered_type() -> void:
	var router = ReplyRouter.new()
	var seen: Array = []
	router.register("pvp_rating", func(d): seen.append(d))
	router.route({"type": "pvp_rating", "honor": 42})
	assert_eq(seen.size(), 1, "the registered handler fires exactly once for its type")
	assert_eq(int(seen[0]["honor"]), 42, "the whole reply dict is passed through untouched")


func test_each_type_reaches_only_its_own_handler() -> void:
	var router = ReplyRouter.new()
	var rating: Array = []
	var board: Array = []
	router.register("pvp_rating", func(_d): rating.append(1))
	router.register("pvp_leaderboard", func(_d): board.append(1))
	router.route({"type": "pvp_leaderboard"})
	assert_eq(board.size(), 1, "leaderboard reply hits the leaderboard handler")
	assert_eq(rating.size(), 0, "and NOT the rating handler")


func test_unregistered_type_is_a_silent_noop() -> void:
	var router = ReplyRouter.new()
	router.register("pvp_rating", func(_d): assert_true(false, "must not fire"))
	# No handler for pvp_tracks — an older client seeing a newer reply must not crash.
	router.route({"type": "pvp_tracks"})
	router.route({})  # no type at all
	assert_false(router.has_route("pvp_tracks"), "an unseen type stays unregistered")


func test_register_is_the_only_growth_surface() -> void:
	var router = ReplyRouter.new()
	router.register("pvp_rating", func(_d): pass)
	router.register("pvp_tracks", func(_d): pass)
	assert_true(router.has_route("pvp_rating"), "registered types report present")
	assert_eq(router.routes().size(), 2, "the router's table grows only via register()")


func test_last_register_wins_for_a_type() -> void:
	var router = ReplyRouter.new()
	var hits: Array = []
	router.register("pvp_result", func(_d): hits.append("first"))
	router.register("pvp_result", func(_d): hits.append("second"))
	router.route({"type": "pvp_result"})
	assert_eq(
		hits, ["second"], "a re-register replaces the prior handler (deterministic for tests)"
	)
