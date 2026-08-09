extends RefCounted

# T-697 fix 8: threaded warm-up of the registered creature/character GLBs — extracted from
# entity_visuals.gd (which sits at the 1000-line gdlint cap; the river_view.gd precedent).
# First sight of a new kind used to pay a synchronous load() on the main thread (a measured
# 13-30 ms hitch, mid-combat, when a new mob kind walked into view). RemoteEntitiesLayer calls
# request_kinds() once at login/world build; EntityVisuals._try_glb_model then resolves every
# path through load_scene(), which collects the threaded result.

# Paths already handed to ResourceLoader.load_threaded_request (never re-requested).
static var _requested: Dictionary = {}


# Issue a background load request for every registered kind's GLB. `models` is the
# EntityVisuals.GLB_MODELS registry (kind -> {path, ...}). Idempotent.
# HEADLESS-SAFE: no-op under the dummy rendering server (tests/pilot). A GLB carries meshes with
# blend shapes; loading one on a background LOADER thread makes the dummy renderer touch mesh RIDs
# off the main thread ("Parameter m is null" / "wrong RID"), and the request outlives the caller,
# corrupting later tests. The warm-up is a pure render-hitch optimization with nothing to hide
# headless — load_scene() then just falls through to the plain load() every test already used.
static func request_kinds(models: Dictionary) -> void:
	if DisplayServer.get_name() == "headless":
		return
	for kind in models:
		var path := str((models[kind] as Dictionary).get("path", ""))
		if path == "" or _requested.has(path) or not ResourceLoader.exists(path):
			continue
		if ResourceLoader.load_threaded_request(path) == OK:
			_requested[path] = true


# Resolve a scene path, preferring the threaded warm-up: a finished request hands the resource
# over instantly; one still in flight blocks only for its remainder; anything else (never
# requested, a gendered sibling, a failed request) falls back to the plain load(), which hits
# the engine resource cache for anything loaded before.
static func load_scene(path: String) -> PackedScene:
	if _requested.has(path):
		var status := ResourceLoader.load_threaded_get_status(path)
		if (
			status == ResourceLoader.THREAD_LOAD_LOADED
			or status == ResourceLoader.THREAD_LOAD_IN_PROGRESS
		):
			return ResourceLoader.load_threaded_get(path) as PackedScene
		_requested.erase(path)  # already collected or failed — plain load from here on
	return load(path) as PackedScene
