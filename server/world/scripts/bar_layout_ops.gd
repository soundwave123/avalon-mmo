class_name BarLayoutOps
extends RefCounted

# T-422c: PURE action-bar layout logic — validation + kit ordering. No scene tree, no master. A
# layout is an ordered list of ability ids naming which ability sits in which bar slot (slot i is
# always hotkey i, so the order IS the key binding). The world validates a client-supplied layout
# against the character's KNOWN kit before it is ever persisted, and applies a saved layout when it
# ships the class kit at spawn. Kept pure so both paths share one impl and unit-test cheap.


# The ability ids of a built kit, in kit order.
static func ids(kit: Array) -> Array:
	var out: Array = []
	for ab in kit:
		out.append(int((ab as Dictionary).get("id", -1)))
	return out


# Validate a client-supplied `layout` against the character's `known` ability ids. Returns a clean
# Array[int] permutation on success, or [] to REJECT (fail-closed) when the layout names ANY id the
# character doesn't know (a client can't place an unlearned/unowned ability) or ANY duplicate. A
# subset of the known ids is accepted (order_kit appends the rest) so a stale saved layout doesn't
# break when the character later learns a new ability — the security property is "no unknown/dup".
static func sanitize(layout: Array, known: Array) -> Array:
	var known_set := {}
	for k in known:
		known_set[int(k)] = true
	var seen := {}
	var out: Array = []
	for raw in layout:
		# T-754: entries come straight off the client packet. int() has no Dictionary/Array/
		# null constructor — it ABORTS the frame rather than returning 0 — so a junk entry
		# used to kill the handler before it could fail-closed. Reject the layout instead.
		if not (raw is int or raw is float or raw is String):
			return []
		var id := int(raw)
		if not known_set.has(id):
			return []  # unknown / not-owned ability id — reject the whole layout
		if seen.has(id):
			return []  # duplicate slot assignment — reject
		seen[id] = true
		out.append(id)
	return out


# Order a built `kit` by a saved `layout` (ids). Abilities named in the layout come first in that
# order; any known ability the layout didn't mention (e.g. just-learned) keeps its registry order,
# appended after. An empty/failed layout leaves the kit in its default order.
static func order_kit(kit: Array, layout: Array) -> Array:
	if layout.is_empty():
		return kit
	var by_id := {}
	for ab in kit:
		by_id[int((ab as Dictionary).get("id", -1))] = ab
	var used := {}
	var out: Array = []
	for raw in layout:
		var id := int(raw)
		if by_id.has(id) and not used.has(id):
			out.append(by_id[id])
			used[id] = true
	for ab in kit:
		var id := int((ab as Dictionary).get("id", -1))
		if not used.has(id):
			out.append(ab)
	return out
