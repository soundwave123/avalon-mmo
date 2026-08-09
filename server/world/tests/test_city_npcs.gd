extends GutTest
# T-144: Highkeep city NPC population — the three class trainers + the regent are present,
# correctly flagged, and positioned in the northern city cluster (server y <= -100).

const _CR = preload("res://scripts/content/content_registry.gd")


# load_all returns npcs as a Dictionary keyed by id -> NpcData.
func _npcs() -> Dictionary:
	return _CR.load_all(ProjectSettings.globalize_path("res://data"))["npcs"]


func test_city_class_trainers_present_and_flagged() -> void:
	var npcs := _npcs()
	for id in [
		"npc_hk_warrior_trainer",
		"npc_hk_mage_trainer",
		"npc_hk_priest_trainer",
		"npc_hk_ranger_trainer",
	]:
		var n = npcs.get(id)
		assert_not_null(n, "%s present" % id)
		if n != null:
			assert_true(n.trainer, "%s is a trainer" % id)
			assert_true(n.y <= -100.0, "%s sits in the northern city (y<=-100)" % id)
			assert_ne(n.talk_text, "", "%s has talk_text" % id)


func test_city_regent_present() -> void:
	var regent = _npcs().get("npc_hk_regent")
	assert_not_null(regent, "Lord Regent present")
	if regent != null:
		assert_true(regent.y <= -140.0, "regent sits at the Keep (deep north)")


func test_city_has_full_trainer_and_service_roster() -> void:
	# 3 class trainers + 6 profession trainers + 3 services (T-144) + 2 vendors (T-145) + regent
	# + 2 guards + castellan + steward (T-201) + bank guard (T-203) + auctioneer + clerk (T-204) + ranger trainer (T-205) + archprelate (T-211) + 6 citizens + 10 watch (T-215)
	# + 2 throne guards (T-217) + 1 bounty board (T-293) = 42.
	var npcs := _npcs()
	var city_ids := []
	for id in npcs:
		if str(id).begins_with("npc_hk_"):
			city_ids.append(id)
	assert_eq(city_ids.size(), 42, "Highkeep NPC roster count")


func test_city_watch_covers_required_posts() -> void:
	var npcs := _npcs()
	var watch_ids := [
		"npc_hk_watch_gate_west",
		"npc_hk_watch_gate_east",
		"npc_hk_watch_wall_nw",
		"npc_hk_watch_wall_ne",
		"npc_hk_watch_wall_sw",
		"npc_hk_watch_wall_se",
		"npc_hk_watch_keep_west",
		"npc_hk_watch_keep_east",
		"npc_hk_watch_market",
		"npc_hk_watch_cathedral",
	]
	for id in watch_ids:
		var guard = npcs.get(id)
		assert_not_null(guard, "%s present" % id)
		if guard != null:
			assert_true(guard.y <= -130.0, "%s is posted inside Highkeep" % id)
			assert_ne(guard.talk_text, "", "%s has watch dialogue" % id)
	var actual_watch := 0
	for id in npcs:
		if str(id).begins_with("npc_hk_watch_"):
			actual_watch += 1
	assert_eq(actual_watch, watch_ids.size(), "watch roster contains exactly the required posts")


func test_city_service_hubs_tagged() -> void:
	# T-145: the five WoW-capital service hubs carry the right `service` tag, sit in the northern
	# city, and are plain (non-trainer) NPCs. banker/innkeeper/flightmaster were placed talk-only by
	# T-144 and are promoted here; the two vendors are new.
	var npcs := _npcs()
	var expected := {
		"npc_hk_banker": "bank",
		"npc_hk_vendor_general": "vendor",
		"npc_hk_vendor_weapon": "vendor",
		"npc_hk_innkeeper": "inn",
		"npc_hk_flightmaster": "flight",
	}
	for id in expected:
		var n = npcs.get(id)
		assert_not_null(n, "%s present" % id)
		if n != null:
			assert_eq(n.service, expected[id], "%s tagged %s" % [id, expected[id]])
			assert_true(n.y <= -100.0, "%s sits in the northern city (y<=-100)" % id)
			assert_ne(n.talk_text, "", "%s has talk_text" % id)
			assert_false(n.trainer, "%s is a service NPC, not a trainer" % id)


func test_plain_city_npc_has_no_service() -> void:
	# A non-service city NPC (the Lord Regent) defaults to an empty service tag.
	var regent = _npcs().get("npc_hk_regent")
	assert_not_null(regent, "regent present")
	if regent != null:
		assert_eq(regent.service, "", "a plain NPC has no service tag")


func test_each_vendor_has_a_distinct_server_validated_wares_list() -> void:
	var npcs := _npcs()
	var general: Array = npcs["npc_hk_vendor_general"].wares
	var weapon: Array = npcs["npc_hk_vendor_weapon"].wares
	assert_true(general.has("itm_potion_minor_healing"), "general vendor stocks healing potions")
	assert_true(general.has("itm_ration_travelers"), "general vendor stocks rations")
	assert_true(weapon.has("itm_smith_broadsword"), "weaponsmith stocks an authored weapon")
	assert_ne(general, weapon, "stock is per-vendor, not one global client list")


func test_travel_network_flight_roosts_cover_every_p1_hub() -> void:
	# T-596: the continent flight web (flight_nodes.json) adds the Kargrim Deep gate + Greyrise
	# transit roosts to the original three. Each P1 flight node must own a flight-service NPC.
	var npcs := _npcs()
	var roosts := [
		"npc_village_flightmaster",
		"npc_hk_flightmaster",
		"npc_ashmoor_flightmaster",
		"npc_kargrim_flightmaster",
		"npc_greyrise_flightmaster",
	]
	for id in roosts:
		assert_not_null(npcs.get(id), "%s exists" % id)
		assert_eq(str(npcs[id].service), "flight", "%s discovers a flight roost" % id)
