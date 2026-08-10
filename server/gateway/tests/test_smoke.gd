extends "res://addons/gut/test.gd"

# Smoke test for the Avalon gateway server.
# Pins the Phase B contract by asserting on ServerConfig constants.
# Loads the script directly rather than relying on the autoload
# being live in the test environment — see docs/testing.md.

const CONFIG_PATH := "res://scripts/server_config.gd"
const ServerConfigScript = preload(CONFIG_PATH)


func test_gateway_config_constants() -> void:
	var cfg: GDScript = load(CONFIG_PATH)
	assert_not_null(cfg, "server_config.gd must load")

	assert_eq(ServerConfigScript.SERVER_NAME, "gateway", "SERVER_NAME must be 'gateway'")
	assert_eq(ServerConfigScript.LISTEN_PORT_WS, 9001, "default WS listen port must be 9001")
	assert_eq(ServerConfigScript.LISTEN_PORT_ENET, 0, "gateway must not listen on ENet (0)")
	assert_eq(ServerConfigScript.MASTER_RPC_HOST, "127.0.0.1", "master RPC host must be loopback")
	assert_eq(ServerConfigScript.MASTER_RPC_PORT, 9100, "master RPC port must be 9100")
	assert_eq(
		ServerConfigScript.DEFAULT_WORLD_ANNOUNCE_PORT,
		9200,
		"default announced world port must be 9200"
	)


# T-742: env-overridable ports (the wizard writes AVALON_GATEWAY_PORT / AVALON_PORT to
# .env; run scripts load .env into the server environment). parse_port is the pure rule.
func test_port_env_parsing_rules() -> void:
	assert_eq(ServerConfigScript.parse_port("9010", 9001), 9010, "valid override wins")
	assert_eq(ServerConfigScript.parse_port(" 9010 ", 9001), 9010, "whitespace tolerated")
	assert_eq(ServerConfigScript.parse_port("", 9001), 9001, "unset keeps default")
	assert_eq(ServerConfigScript.parse_port("banana", 9001), 9001, "garbage keeps default")
	assert_eq(ServerConfigScript.parse_port("0", 9001), 9001, "out of range keeps default")
	assert_eq(ServerConfigScript.parse_port("70000", 9001), 9001, "out of range keeps default")
