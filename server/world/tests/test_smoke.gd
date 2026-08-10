extends "res://addons/gut/test.gd"

# Smoke test for the Avalon world server.
# Pins the Phase B contract by asserting on ServerConfig values.

const CONFIG_PATH := "res://scripts/server_config.gd"
const ServerConfigScript = preload(CONFIG_PATH)


func test_world_config_constants() -> void:
	var cfg: GDScript = load(CONFIG_PATH)
	assert_not_null(cfg, "server_config.gd must load")

	assert_eq(ServerConfigScript.SERVER_NAME, "world", "SERVER_NAME must be 'world'")
	assert_eq(ServerConfigScript.TICK_RATE_HZ, 20, "tick rate must be 20 Hz")
	assert_eq(ServerConfigScript.BROADCAST_RATE_HZ, 10, "broadcast rate must be 10 Hz")
	assert_eq(ServerConfigScript.DEFAULT_ENET_LISTEN_PORT, 9200, "default ENet port must be 9200")
	# T-374: 115 = 80% of the measured single-cell crowd knee (~145 peers at the 100 ms broadcast
	# budget, all four capacity levers on). Re-pin ONLY with a fresh load_probe measurement.
	assert_eq(
		ServerConfigScript.DEFAULT_MAX_PLAYERS,
		115,
		"default max players must be 115 (T-374 measured)"
	)
