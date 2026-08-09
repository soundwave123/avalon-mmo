class_name WeaponSocket
# T-109: the ONE shared hand-socket contract for held gear on the master rig.
#
# Every hero shares the Quaternius UBC 65-bone skeleton (T-118); the right fist is bone
# "hand_r" (offhand "hand_l"), whose local +Y runs along the fingers (T-225 verified in
# game). Weapon GLBs (tools/assetgen/gen_weapons_starter.py) are authored to this frame:
# origin at the grip point, business end along the axis that lands on Godot +Y after the
# y-up glTF export — so ANY weapon parents under the socket with an IDENTITY transform.
# Swapping weapons is a mesh swap (equip), never a re-rig.
#
# Code-built only (no .tscn): EntityVisuals.apply_gear() creates sockets on demand from
# the networked gear dict, and pre-attach QA lives in unit tests against the real
# char_hero_warrior.glb rig (tests/test_weapon_socket.gd).
extends BoneAttachment3D

const RIGHT_HAND := "hand_r"
const LEFT_HAND := "hand_l"


# Create a socket on `skel` bound to `bone`, named for the gear slot so apply_gear's
# GearSlot_* sweep stays idempotent. Returns null (no node added) when the skeleton is
# missing or the bone doesn't resolve — callers fall through gracefully.
static func attach(skel: Skeleton3D, slot: String, bone: String = RIGHT_HAND) -> WeaponSocket:
	if skel == null or skel.find_bone(bone) < 0:
		return null
	var sock := WeaponSocket.new()
	sock.name = "GearSlot_%s" % slot
	sock.bone_name = bone
	skel.add_child(sock)
	return sock


# Show exactly one weapon in this socket: clears any previous mesh, then parents the new
# one at identity (the authored grip origin lands in the fist; no scale/offset fixups).
func equip(weapon: Node3D) -> void:
	for child in get_children():
		child.queue_free()
	if weapon != null:
		add_child(weapon)
