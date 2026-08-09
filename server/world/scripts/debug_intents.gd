extends RefCounted

# T-521: dev-only pilot "force death" intent. OFF unless AVALON_DEBUG_INTENTS is set in the world's
# environment (never enabled in production). SELF-ONLY — it applies lethal damage to the CALLING
# peer, so a client can only kill ITSELF (harmless: you can already die in normal play). It drives
# the REAL server death→respawn cycle (not a fake client-side screen) so pilot QA can validate the
# death presentation deterministically across classes. Static helper; world/main.gd passes itself in
# via the unknown-message seam, so this adds no lines to the 1000-capped main.gd.

const _SC = preload("res://scripts/server_config.gd")

const LETHAL := 1_000_000  # far past any max HP → CombatResources.is_dead() on the next check


# Returns true if `msg_type` is a recognized debug intent (whether it fired or was gated off), so
# main.gd does NOT log it as an "unknown message". Returns false for genuinely unknown messages.
static func handle(world, msg_type: String, peer_id: int) -> bool:
	if msg_type != "debug_kill":
		return false
	if not _enabled():
		return true  # recognized but gated off — swallow silently, no death
	if not world._combat_resources.has(peer_id):
		return true
	# Apply lethal self-damage, then run the normal death check → player_death broadcast + the
	# PLAYER_RESPAWN_TICKS auto-respawn timer, exactly as a mob kill would.
	world._combat_resources[peer_id] = world._combat_resources[peer_id].apply_damage(LETHAL)
	var now: int = Time.get_ticks_msec() / (1000 / _SC.TICK_RATE_HZ)
	world._check_death_player(peer_id, now)
	print("[world] debug_kill: peer_id=%d killed (AVALON_DEBUG_INTENTS)" % peer_id)
	return true


static func _enabled() -> bool:
	return OS.get_environment("AVALON_DEBUG_INTENTS").strip_edges() != ""
