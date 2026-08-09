class_name ReplyRouter
extends RefCounted

# T-401: a routed-reply hub. client/main.gd + client_net.gd both sit at their gdlint / public-method
# caps, so a new server reply type can no longer earn its own handler line the old way. So
# client_net routes a NAMED SET of reply types (see its "pvp" category) into this one module, and
# panels self-register the types they care about here — register(type, callable) — so a new panel
# needs ZERO new main.gd handler lines. This mirrors how observe_probe was extracted from main.gd's
# growth at the cap: the transport wires ONE delegation, the feature owns its own routing table.
#
# The router is a pure dispatcher (no UI, no transport): register maps a reply `type` string to a
# Callable(data: Dictionary); route() looks the reply up by its own `type` field and calls it. An
# unregistered type is silently ignored (a newer server reply never crashes an older client),
# exactly like client_net's own unknown-type fallthrough.

var _routes: Dictionary = {}  # reply_type: String -> Callable(data: Dictionary)


# Panels call this themselves (from setup) so registration lives with the feature, not main.gd. A
# second register for the same type replaces the first (last panel wins — deterministic for tests).
func register(reply_type: String, handler: Callable) -> void:
	_routes[reply_type] = handler


# The single delegation target client_net's "pvp" category (and any future routed category) calls.
# Dispatches on the reply's own `type`; unknown/unregistered types no-op.
func route(data: Dictionary) -> void:
	var reply_type := str(data.get("type", ""))
	if _routes.has(reply_type) and (_routes[reply_type] as Callable).is_valid():
		_routes[reply_type].call(data)


func has_route(reply_type: String) -> bool:
	return _routes.has(reply_type)


# Test/introspection: the set of registered reply types.
func routes() -> Array:
	return _routes.keys()
