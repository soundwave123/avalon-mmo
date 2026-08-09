# T-076: pure builders for the positions broadcast payload (extracted from main.gd).
# No side effects; main supplies the live stores each tick.

extends RefCounted

# T-225: the equipment slots that render on the character (paper-doll visual truth).
# T-420: "shoulders" joins the worn set so the T-224 pauldrons ride the gear broadcast.
const GEAR_SLOTS := ["weapon", "offhand", "head", "chest", "legs", "shoulders"]

# T-371: era regions are the DISTANT FLAT-OFFSET domains from instance_service.gd — era-1 at the
# origin, the Hollowed Crypt at +420 x, Ashmoor at -420 x (all z 0). A position belongs to the
# region whose anchor is nearest; the boundaries fall at ±210 m, comfortably outside the ±200 m
# village footprint (load_probe PLAY_X_MIN/MAX), so every open-world villager resolves to era-1 and
# only the distant crypt/Ashmoor pockets resolve to their own domain. Bucketing by region is the
# capacity lever (T-355 lever 2): cross-region peers — always ≥420 m apart — are separated BEFORE
# the AOI radius math runs, so each peer's interest scan is bounded by its own era's population, not
# global CCU, and mobs/townsfolk are region-scoped so an Ashmoor player never receives village
# entities that merely share instance_id 0. Kept as a const here (not imported) so this builder
# stays a pure, dependency-free RefCounted; mirror if the anchors ever move.
# T-593: Greyrise (era-3) appended as the 4th AOI bucket at its far origin (0,-1400) — kept LAST so
# the pre-existing indices (0=Wold, 1=crypt instance pocket, 2=Ashmoor) are untouched. Every
# terrain-region origin in regions.json must appear here (test_world_regions asserts it).
const REGION_ANCHORS := [
	Vector2(0.0, 0.0), Vector2(420.0, 0.0), Vector2(-420.0, 0.0), Vector2(0.0, -1400.0)
]


# T-225 (pure): equipped visual dict from a master inventory slots array.
# T-375: the APPEARANCE channel wins over the STATS channel. A slot's optional cosmetic
# `appearance_override` (a "shown as" visual id, set only via the unlock-gated
# cosmetics.apply_override) renders in place of the real `item_id`; absent an override the real item
# shows, so nothing changes visually until a transmog is set. Stats read `item_id` elsewhere (never
# this visual-only dict), so the override is cosmetic-only and can never touch a combat number. The
# gear value stays a plain string id, so the T-372 delta detects a transmog swap for free (the
# string differs → the entity is dirty).
static func equipped_from_slots(slots: Array) -> Dictionary:
	var gear := {}
	for s in slots:
		if s is Dictionary and str(s.get("slot_type", "")) in GEAR_SLOTS:
			if bool(s.get("appearance_hidden", false)):
				gear[str(s["slot_type"])] = ""
				continue
			var shown := str(s.get("appearance_override", ""))
			var family := str(s.get("appearance_armor_type", ""))
			if shown == "":
				shown = str(s.get("item_id", ""))
				family = str(s.get("armor_type", "none"))
			gear[str(s["slot_type"])] = _visual_token(
				shown, family, str(s.get("tint", "")), str(s.get("dye_mask", "all"))
			)
	return gear


# T-420: the client routes an armor item to its plate/robe GLB set by the SERVER-authored armor_type
# (content_query.enrich_inventory stamps it on each slot), never a client-trusted field or a fragile
# id substring. The visual gear value stays a plain STRING: item-id-only for weapons and armor_type
# "none"; for a real armor family it becomes "<item_id>|<armor_type>" (still a string, so the T-372
# delta and the transmog-swap detection keep working). A slot with no armor_type (tests / weapon /
# unenriched) yields the bare id, so nothing regresses. T-428's master-authored
# appearance_armor_type lets a cross-family override select its own visual family.
static func _visual_token(
	item_id: String, armor_type: String, dye_color: String = "", dye_mask: String = "all"
) -> String:
	if dye_color != "":
		return (
			"%s|%s|%s|%s"
			% [item_id, armor_type if armor_type != "" else "none", dye_color, dye_mask]
		)
	if armor_type == "" or armor_type == "none":
		return item_id
	return "%s|%s" % [item_id, armor_type]


# T-264 (pure): the cast dict a client needs to render a cast bar — {} when not casting.
# Seconds, not ticks: the server owns tick math so clients never need TICK_RATE_HZ.
static func cast_payload(combat_state, now_tick: int, tick_hz: int) -> Dictionary:
	if combat_state == null or int(combat_state.state) != 2:  # CombatStateEnum.CASTING
		return {}
	var total_ticks: int = combat_state.cast_end - combat_state.cast_start
	var remain_ticks: int = combat_state.cast_end - now_tick
	if total_ticks <= 0 or remain_ticks <= 0:
		return {}
	return {
		"ability_id": combat_state.cast_ability_id,
		"remaining_s": float(remain_ticks) / tick_hz,
		"total_s": float(total_ticks) / tick_hz,
	}


# T-264 (pure): all active casts — {peer_id: cast_payload()} with empty entries dropped.
static func casts_map(combat_states: Dictionary, now_tick: int, tick_hz: int) -> Dictionary:
	var out := {}
	for pid in combat_states:
		var cp := cast_payload(combat_states[pid], now_tick, tick_hz)
		if not cp.is_empty():
			out[pid] = cp
	return out


# players: {peer_id: {username,x,y,z}}; resources: {peer_id: CombatResources}; classes:
# {peer_id: String}; gear: {peer_id: {slot: item_id}} (T-225 — equipment everyone sees);
# casts: {peer_id: cast_payload()} (T-264 — cast bars for everyone, {} entries dropped).
# hp/resource fields are omitted until resources exist (TD-004 F2).
static func players_array(
	positions: Dictionary,
	resources: Dictionary,
	classes: Dictionary,
	gear: Dictionary = {},
	casts: Dictionary = {},
	party_of: Dictionary = {},
	titles: Dictionary = {},
	genders: Dictionary = {}
) -> Array:
	var out: Array = []
	for peer_id in positions:
		var p: Dictionary = positions[peer_id]
		var entry := {
			"peer_id": peer_id,
			"username": p.get("username", ""),
			"x": p.get("x", 0.0),
			"y": p.get("y", 0.0),
			"z": p.get("z", 0.0),
		}
		# T-076: class drives the player's visual (WoW-style: read a class at range).
		entry["char_class"] = classes.get(peer_id, "")
		# T-535: gender drives the player's BODY mesh (female hero sibling). Sent only when set — a
		# plain string that rides the T-372 delta for free (differs -> the entry is dirty), so remote
		# clients pick the right mesh at first sight. Absent/"" keeps the default (male) body.
		var gender := str(genders.get(peer_id, ""))
		if gender != "":
			entry["gender"] = gender
		# T-431: visual-only mount snapshot; movement power stays in MountService, not this payload.
		entry["mounted"] = bool(p.get("mounted", false))
		if entry["mounted"]:
			entry["mount_visual"] = str(p.get("mount_visual", ""))
		var g: Dictionary = gear.get(peer_id, {})
		if not g.is_empty():
			entry["gear"] = g
		var c: Dictionary = casts.get(peer_id, {})
		if not c.is_empty():
			entry["cast"] = c
		if party_of.has(peer_id):
			entry["party_id"] = int(party_of[peer_id])  # T-280: party membership everyone sees
		# T-401: worn display title (a plain string; other clients render it under the nameplate). A
		# plain field rides the T-372 delta for free — the string differs → the entry is dirty.
		var title := str(titles.get(peer_id, ""))
		if title != "":
			entry["title"] = title
		var cr = resources.get(peer_id, null)
		if cr != null:
			entry["hp"] = cr.hp
			entry["max_hp"] = cr.max_hp
			entry["resource_kind"] = cr.resource_kind  # T-062: class resource for the HUD
			entry["resource"] = cr.class_resource()
			entry["max_resource"] = cr.class_resource_max()
		out.append(entry)
	return out


# T-331: the distinct instance_ids present among connected peers (bucket keys for the broadcast).
# WORLD (0) is included whenever any open-world peer is connected; crypt ids appear only while a
# party is inside. positions carry `instance_id` from PlayerSessions.get_positions().
static func instances_present(positions: Dictionary) -> Array:
	var seen := {}
	for pid in positions:
		seen[int(positions[pid].get("instance_id", 0))] = true
	return seen.keys()


# T-331: positions of just the peers in `target` instance (a pre-filter for players_array).
static func positions_in_instance(positions: Dictionary, target: int) -> Dictionary:
	var out := {}
	for pid in positions:
		if int(positions[pid].get("instance_id", 0)) == target:
			out[pid] = positions[pid]
	return out


# T-331: the mobs whose spawn scope == `target` instance (a pre-filter for mobs_array). This is the
# ONE place the "everyone sees every mob" rule is narrowed — open-world mobs (instance_id 0) are
# unchanged.
static func mobs_in_instance(mobs: Dictionary, target: int) -> Dictionary:
	var out := {}
	for mob_id in mobs:
		if int(mobs[mob_id].instance_id) == target:
			out[mob_id] = mobs[mob_id]
	return out


# T-371 (pure): the region key (index into REGION_ANCHORS) for a planar XZ position — the nearest
# era anchor. y is height and never gates the domain (mirrors the AOI planar-distance rule).
static func region_of(x: float, z: float) -> int:
	var best := 0
	var best_d2: float = INF
	for i in REGION_ANCHORS.size():
		var a: Vector2 = REGION_ANCHORS[i]
		var dx: float = x - a.x
		var dz: float = z - a.y
		var d2: float = dx * dx + dz * dz
		if d2 < best_d2:
			best_d2 = d2
			best = i
	return best


# T-371: the distinct region keys present among a position set (bucket keys within one instance).
static func regions_present(positions: Dictionary) -> Array:
	var seen := {}
	for pid in positions:
		var p: Dictionary = positions[pid]
		seen[region_of(float(p.get("x", 0.0)), float(p.get("z", 0.0)))] = true
	return seen.keys()


# T-371: positions of just the peers in `region` — a pre-filter for the AOI loop so cross-region
# peers are dropped BEFORE any radius computation (the whole point of the lever).
static func positions_in_region(positions: Dictionary, region: int) -> Dictionary:
	var out := {}
	for pid in positions:
		var p: Dictionary = positions[pid]
		if region_of(float(p.get("x", 0.0)), float(p.get("z", 0.0))) == region:
			out[pid] = p
	return out


# T-371: the mobs whose position lies in `region`. Open-world mobs share instance_id 0 but split by
# era — an Ashmoor player must not receive village wolves. Instance mobs (crypt) are already the
# scoped subset and stay together (their positions are all in one region).
static func mobs_in_region(mobs: Dictionary, region: int) -> Dictionary:
	var out := {}
	for mob_id in mobs:
		var pos: Vector3 = mobs[mob_id].position
		if region_of(pos.x, pos.z) == region:
			out[mob_id] = mobs[mob_id]
	return out


# T-371: the ambient NPC dicts (x/z) in `region` — the village townsfolk crowd never rides an
# Ashmoor frame even though both are the open world (instance 0).
static func npcs_in_region(npcs: Array, region: int) -> Array:
	var out: Array = []
	for n in npcs:
		if region_of(float(n.get("x", 0.0)), float(n.get("z", 0.0))) == region:
			out.append(n)
	return out


static func mobs_array(mobs: Dictionary) -> Array:
	var out: Array = []
	for mob_id in mobs:
		var mob = mobs[mob_id]
		(
			out
			. append(
				{
					"mob_id": mob_id,
					# T-076: visual kind (e.g. mob_wolf). T-294: an elite reuses a base model via
					# render_kind while mob.mob_id stays a unique kill-credit alias.
					"kind": mob.render_kind if mob.render_kind != "" else mob.mob_id,
					"name": mob.name,  # T-294: nameplate label (elite name reads on the plate)
					"level": mob.mob_level,  # T-462: server-owned target-frame level
					"elite": mob.elite,  # T-294: drives the client's gold elite nameplate treatment
					"render_scale": mob.render_scale,  # T-332: boss models tower (Hollow King 1.6×)
					"x": mob.position.x,
					"y": mob.position.y,
					"z": mob.position.z,
					"ai_state": mob.ai_state,
					# T-665: server-owned relationship + AI target for name/target-of-target UI.
					"hostile": not (mob.is_dummy or mob.retaliate_only),
					"target_id": mob.current_target_id,
					"hp": mob.resources.hp,
					"max_hp": mob.resources.max_hp,
				}
			)
		)
	return out


# T-331: the per-instance positions broadcast, split into frames so a peer only receives players +
# mobs in its own instance. Returns [{peers:Array[peer_id], payload:Dictionary}, ...]; main.gd
# rpc_id's each payload to its peers. The open world (instance 0) frame is unchanged from the old
# single broadcast — same players_array/mobs_array over the world-scoped subset — and ambient NPCs
# ride only the world frame (crypt instances have no wandering townsfolk). This is the entire
# "narrow the everyone-sees-everyone rule" surface.
static func positions_frames(
	positions: Dictionary,
	resources: Dictionary,
	classes: Dictionary,
	gear: Dictionary,
	casts: Dictionary,
	party_of: Dictionary,
	mobs: Dictionary,
	npcs: Array
) -> Array:
	var frames: Array = []
	for iid in instances_present(positions):
		var scoped: Dictionary = positions_in_instance(positions, iid)
		var payload := {
			"type": "positions",
			"players": players_array(scoped, resources, classes, gear, casts, party_of),
			"mobs": mobs_array(mobs_in_instance(mobs, iid)),
			"npcs": npcs if iid == 0 else [],
		}
		frames.append({"peers": scoped.keys(), "payload": payload})
	return frames


# T-370: the AOI (area-of-interest) positions broadcast. This is the per-PEER evolution of
# positions_frames: instance bucketing is still the OUTER, hard isolation seam (peers in different
# instances — crypt parties, an Ashmoor group — never share a frame regardless of any distance
# math), and WITHIN each instance every peer receives only the players inside `radius` metres of it,
# capped to the nearest `max_peers` so a spawn-square crowd cannot blow the payload. The peer always
# receives itself (distance 0). Mobs/NPCs stay instance-scoped (a fixed ~19+12 set, not the O(N)
# driver the CCU ceiling is about) so their nameplates don't flicker as players roam.
#
# radius <= 0 disables the distance filter (every same-region peer stays visible) while the
# nearest-N cap still applies. Returns one frame PER PEER: [{peers:[pid], payload:{...}}, ...];
# main.gd rpc_id's each payload to its single peer exactly as it does the instance frames.
#
# T-371: the bucketing seam is now TWO deep — instance (crypt parties) OUTSIDE, era region
# (village / crypt-surface / Ashmoor) INSIDE. Cross-region peers are separated here, before
# peers_in_range ever runs, so the per-peer interest scan is bounded by same-era density (lever 2),
# and mobs/NPCs are region-scoped so a peer only ever receives its own era's entities.
static func positions_frames_aoi(
	positions: Dictionary,
	resources: Dictionary,
	classes: Dictionary,
	gear: Dictionary,
	casts: Dictionary,
	party_of: Dictionary,
	mobs: Dictionary,
	npcs: Array,
	radius: float,
	max_peers: int,
	titles: Dictionary = {},
	genders: Dictionary = {}
) -> Array:
	var frames: Array = []
	for iid in instances_present(positions):
		# Instance isolation FIRST (hard seam), then T-371 era-region domains within the instance.
		var scoped: Dictionary = positions_in_instance(positions, iid)
		var inst_mobs: Dictionary = mobs_in_instance(mobs, iid)
		for region in regions_present(scoped):
			var region_pos: Dictionary = positions_in_region(scoped, region)
			var mobs_payload: Array = mobs_array(mobs_in_region(inst_mobs, region))
			var npcs_payload: Array = npcs_in_region(npcs, region) if iid == 0 else []
			for pid in region_pos:
				var neighbours: Dictionary = peers_in_range(region_pos, pid, radius, max_peers)
				var payload := {
					"type": "positions",
					"players":
					players_array(
						neighbours, resources, classes, gear, casts, party_of, titles, genders
					),
					"mobs": mobs_payload,
					"npcs": npcs_payload,
				}
				frames.append({"peers": [pid], "payload": payload})
	return frames


# T-370 (pure): the players `self_pid` should receive — itself plus every same-scope peer within
# `radius` metres (planar XZ distance; y is height and never gates interest), capped to the nearest
# `max_peers` total. `positions` is assumed already instance-scoped by the caller. radius <= 0 keeps
# all peers (distance filter off); the nearest-N cap still bounds the result. Self is always kept.
static func peers_in_range(
	positions: Dictionary, self_pid, radius: float, max_peers: int
) -> Dictionary:
	var me: Dictionary = positions[self_pid]
	var cx: float = me.get("x", 0.0)
	var cz: float = me.get("z", 0.0)
	var r2: float = radius * radius
	var no_dist_filter := radius <= 0.0
	# Collect [dist2, pid] for every candidate in range (self at distance 0 sorts first).
	var ranked: Array = []
	for pid in positions:
		var dx: float = float(positions[pid].get("x", 0.0)) - cx
		var dz: float = float(positions[pid].get("z", 0.0)) - cz
		var d2: float = dx * dx + dz * dz
		if pid == self_pid or no_dist_filter or d2 <= r2:
			ranked.append([d2, pid])
	# Nearest-N: only sort/trim when the crowd exceeds the cap (self is always kept — d2 == 0).
	if max_peers > 0 and ranked.size() > max_peers:
		ranked.sort_custom(func(a, b): return a[0] < b[0])
		ranked.resize(max_peers)
	var out: Dictionary = {}
	for entry in ranked:
		out[entry[1]] = positions[entry[1]]
	return out


# T-699: the recipient set for a region-scoped combat/death/respawn event. Before T-699 these were
# all-peers reliable broadcasts (O(events × CCU), cross-region). The event now goes to every
# connected peer in the SAME instance + era region as `origin` — the exact bucketing the positions
# path uses (instance seam OUTSIDE, region_of INSIDE) — UNION the `involved` players and their whole
# party (so a cross-region party-mate or the event's own target still receives it). `origin` is
# {iid,x,z}; pass {} to derive it from the first `involved` player's live position (player
# death/respawn/combat always involve a positioned player). Only ids present in `positions` are ever
# returned, so a mob entity_id passed in `involved` (combat relays) drops out — never an rpc_id to a
# non-peer. `party_of` is peer→party_id; `parties` is party_id→{members}. Pure.
static func event_recipients(
	positions: Dictionary,
	involved: Array,
	party_of: Dictionary,
	parties: Dictionary,
	origin: Dictionary = {}
) -> Array:
	var out: Dictionary = {}
	var has_origin := not origin.is_empty()
	var ox := float(origin.get("x", 0.0))
	var oz := float(origin.get("z", 0.0))
	var oiid := int(origin.get("iid", 0))
	for pid in involved:
		var ip := int(pid)
		if not positions.has(ip):
			continue  # not a connected peer (e.g. a mob entity_id) — skip
		out[ip] = true
		if not has_origin:  # derive the region origin from the first positioned involved player
			var mp: Dictionary = positions[ip]
			has_origin = true
			ox = float(mp.get("x", 0.0))
			oz = float(mp.get("z", 0.0))
			oiid = int(mp.get("instance_id", 0))
		var party_id := int(party_of.get(ip, -1))
		if party_id != -1:
			for m in parties.get(party_id, {}).get("members", []):
				if positions.has(int(m)):
					out[int(m)] = true
	if has_origin:
		var region := region_of(ox, oz)
		for pid in positions:
			var p: Dictionary = positions[pid]
			if (
				int(p.get("instance_id", 0)) == oiid
				and region_of(float(p.get("x", 0.0)), float(p.get("z", 0.0))) == region
			):
				out[int(pid)] = true
	return out.keys()


# T-372: capacity lever 3 — per-peer DELTA broadcast on top of the T-370/T-371 AOI frames. Each AOI
# frame carries the FULL player row for every neighbour every 100 ms; most of that (username, class,
# gear, max_hp, resource_kind, max_resource, party_id) is STATIC and re-sent unchanged ~10×/s. This
# rewrites each per-peer frame to send only what CHANGED since that peer's last frame, with a full
# KEYFRAME every `keyframe_interval` frames (and always on the peer's first-ever frame) so a joining
# or re-entering peer never reconstructs the world from a partial payload. Client-relied semantics:
#   keyframe == true : `players` is the COMPLETE interest set — absence means "left interest" so the
#                      client reaps it (identical to the pre-T-372 all-in-one broadcast).
#   keyframe == false: `players` holds ONLY changed/new entries (a peer NEW to this interest carries
#                      its full row); `removed` lists peers that left. Absence == unchanged.
# T-699: MOBS ride the identical mechanism keyed by mob_id — on a keyframe `mobs` is the full set;
# on a delta `mobs` carries only changed/new mob rows (a new mob its full row) and `mobs_removed`
# lists mobs that left interest, so static kind/name/level/elite/render_scale/max_hp/hostile stop
# re-serialising 10×/s and only x/y/z/hp/ai_state/target ride the per-tick delta (lossless: the
# client reconstructs the identical full mob view). NPCs stay full-frame — their static kind/name is
# already delivered out-of-band (npc_indicators) so their per-tick row is already just x/y/f.
# `prev_state`: {pid -> {"entries": {entry_pid -> row}, "since_key": int}}. PURE: returns the new
# frames plus the new state; the caller (main._broadcast_positions) owns the state dict. A peer that
# stops receiving a frame (disconnect / left the world) drops out of the returned state, and a
# reconnecting peer (fresh pid) has no prev entry → its first frame is a keyframe. No cleanup.
# keyframe_interval <= 1 forces every frame to a keyframe (delta disabled) — the safe escape hatch.
static func positions_delta_frames(
	full_frames: Array, prev_state: Dictionary, keyframe_interval: int
) -> Dictionary:
	var out_frames: Array = []
	var new_state: Dictionary = {}
	for f in full_frames:
		var pid = f["peers"][0]
		var payload: Dictionary = f["payload"]
		var cur: Dictionary = {}
		for e in payload.get("players", []):
			cur[int(e["peer_id"])] = e
		var cur_mobs: Dictionary = _index_by(payload.get("mobs", []), "mob_id")  # T-699
		var prev = prev_state.get(pid, null)
		var since_key: int = (int(prev["since_key"]) + 1) if prev != null else 0
		var is_key: bool = prev == null or keyframe_interval <= 1 or since_key >= keyframe_interval
		var dp: Dictionary = payload.duplicate()  # keeps type/npcs; players+mobs overwritten on delta
		if is_key:
			dp["keyframe"] = true  # players + mobs stay the full set the AOI frame already built
			since_key = 0
		else:
			dp["keyframe"] = false
			var changed: Array = []
			for id in cur:
				var pe = prev["entries"].get(id, null)
				if pe == null:
					changed.append(cur[id])  # new to this peer's interest → the full row
				else:
					var d := _entry_delta(pe, cur[id])
					if d.size() > 1:  # more than the always-present peer_id → a field changed
						changed.append(d)
			var removed: Array = []
			for id in prev["entries"]:
				if not cur.has(id):
					removed.append(id)  # left interest → the client despawns it
			dp["players"] = changed
			dp["removed"] = removed
			# T-699: mobs ride the identical delta contract, keyed by mob_id (npcs stay full).
			var md: Dictionary = _collection_delta(prev.get("mobs", {}), cur_mobs, "mob_id")
			dp["mobs"] = md["changed"]
			dp["mobs_removed"] = md["removed"]
		out_frames.append({"peers": [pid], "payload": dp})
		new_state[pid] = {"entries": cur, "mobs": cur_mobs, "since_key": since_key}
	return {"frames": out_frames, "state": new_state}


# T-699 (pure): {id_key value -> row} index of a payload rows array (mobs keyed by mob_id).
static func _index_by(rows: Array, id_key: String) -> Dictionary:
	var out: Dictionary = {}
	for r in rows:
		out[r[id_key]] = r
	return out


# T-699 (pure): the per-entity delta of a keyed collection (mobs) — mirrors the player delta above.
# Returns {changed:Array, removed:Array}: an entity new to the peer carries its FULL row; existing
# one carries only changed fields + id_key (dropped optional fields cleared via _empty_like); an
# entity gone from `cur` is flagged in `removed` (departed, not silently omitted).
static func _collection_delta(
	prev_rows: Dictionary, cur_rows: Dictionary, id_key: String
) -> Dictionary:
	var changed: Array = []
	for id in cur_rows:
		var pe = prev_rows.get(id, null)
		if pe == null:
			changed.append(cur_rows[id])
		else:
			var d := _row_delta(pe, cur_rows[id], id_key)
			if d.size() > 1:
				changed.append(d)
	var removed: Array = []
	for id in prev_rows:
		if not cur_rows.has(id):
			removed.append(id)
	return {"changed": changed, "removed": removed}


# T-372 (pure): the fields of `new_entry` that differ from `prev_entry`, always including peer_id. A
# key present in prev but GONE from new (a cast ending, gear stripped, a party left) is emitted with
# its type's empty value so the client CLEARS it — the client merge is a field overwrite, not a key
# drop, so a dropped optional field must be sent explicitly rather than simply omitted.
static func _entry_delta(prev_entry: Dictionary, new_entry: Dictionary) -> Dictionary:
	return _row_delta(prev_entry, new_entry, "peer_id")  # T-699: shared with the mob delta


# T-699 (pure): the fields of `new_entry` differing from `prev_entry`, always including `id_key`. A
# key present in prev but GONE from new is emitted with its type's empty value so the client CLEARS
# it (the merge is a field overwrite, not a key drop). Generalises the player _entry_delta to any
# identity key so mobs (mob_id) reuse the exact same delta idiom.
static func _row_delta(prev_entry: Dictionary, new_entry: Dictionary, id_key: String) -> Dictionary:
	var d: Dictionary = {id_key: new_entry[id_key]}
	for k in new_entry:
		if k == id_key:
			continue
		if not prev_entry.has(k) or prev_entry[k] != new_entry[k]:
			d[k] = new_entry[k]
	for k in prev_entry:
		if k != id_key and not new_entry.has(k):
			d[k] = _empty_like(prev_entry[k])
	return d


# T-372 (pure): the empty value of v's type — used to clear a field the new entry dropped.
static func _empty_like(v):
	if v is Dictionary:
		return {}
	if v is Array:
		return []
	if v is String:
		return ""
	if v is float:
		return 0.0
	return 0
