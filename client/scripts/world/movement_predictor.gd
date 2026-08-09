class_name MovementPredictor
extends RefCounted

# T-054: client-side prediction + server reconciliation for the LOCAL player (Gambetta's pattern,
# adapted to Avalon's request_move intents — the server stays authoritative + anti-cheat).
#
# Predict each input locally for instant feel; reconcile to the server's authoritative position from
# the broadcast: a small gap (latency) is lerped away; a large gap means the server rejected/clamped
# the move (speed-hack/bounds/desync) and we snap. Pure + deterministic → unit-tested without nodes;
# the CharacterBody3D + input + camera live in local_player.gd.


# Apply an input delta the way the server will (clamped to the same max speed) → predicted position.
static func predict(pos: Vector3, delta: Vector3, max_speed: float) -> Vector3:
	return pos + delta.limit_length(max_speed)


# Correct toward the server's authoritative position. Within snap_threshold → lerp (hide latency);
# beyond it → snap (the server corrected us — stop mispredicting).
#
# T-327: the gap is measured on the PLANAR ground (x, z) only, and the predicted HEIGHT (y) is
# preserved. Height derives from the shared TerrainField on every client (never trusted from the
# packet), so a slope's height delta between our y=0 prediction and the server's terrain-height
# authority must NOT inflate the gap into a false snap (rubber-band). On flat ground both y's are 0,
# so planar == full distance and this is identical to the old behaviour.
static func reconcile(
	predicted: Vector3, authoritative: Vector3, snap_threshold: float, lerp_factor: float
) -> Vector3:
	var flat_pred := Vector3(predicted.x, 0.0, predicted.z)
	var flat_auth := Vector3(authoritative.x, 0.0, authoritative.z)
	if flat_pred.distance_to(flat_auth) > snap_threshold:
		return Vector3(authoritative.x, predicted.y, authoritative.z)
	var lerped := flat_pred.lerp(flat_auth, clampf(lerp_factor, 0.0, 1.0))
	return Vector3(lerped.x, predicted.y, lerped.z)
