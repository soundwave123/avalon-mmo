class_name PilotChecks
# T-623: pure math helpers shared by two "stop lying about success" fixes for the pilot:
#   - goto (#57): a blind ack ok:true after the hop sequence let a 50-hop retry loop walk a
#     character into an elite's aggro and get it killed. goto_arrival() is the honest check.
#   - look (session-12): the camera-rotation op ack'd ok:true even when it was inert.
#     look_verified() is the honest check.
# Kept in their own file (not pilot.gd) so the math is unit-tested headlessly
# (test_pilot_checks.gd) without a live scene, and to keep pilot.gd under the 1000-line house cap.

extends RefCounted


# Did the player actually arrive within `tolerance` of the (target_x,target_z) goto target? Ack
# shape matches T-623's spec: {ok:false, actual:[x,z], wanted:[x,z], dist:N} beyond tolerance.
static func goto_arrival(
	pos: Vector3, target_x: float, target_z: float, tolerance: float
) -> Dictionary:
	var dist := Vector2(pos.x, pos.z).distance_to(Vector2(target_x, target_z))
	if dist <= tolerance:
		return {"ok": true, "dist": dist}
	return {"ok": false, "actual": [pos.x, pos.z], "wanted": [target_x, target_z], "dist": dist}


# Did a look-drag with horizontal component `dx` actually turn the body (rotation.y)? A near-zero
# dx expects no turn (always passes) — only a real attempted turn producing no motion is flagged.
static func look_verified(before_yaw: float, after_yaw: float, dx: float) -> Dictionary:
	var yaw_delta := after_yaw - before_yaw
	if absf(dx) < 0.01 or absf(yaw_delta) > 0.0001:
		return {"ok": true, "yaw_delta": yaw_delta}
	return {
		"ok": false, "error": "no yaw change observed — look may be inert", "yaw_delta": yaw_delta
	}
