extends "res://addons/gut/test.gd"

# Smoke test for the Avalon gateway server.
# Pins the Phase B contract by asserting on ServerConfig constants.
# Loads the script directly rather than relying on the autoload
# being live in the test environment — see docs/testing.md.

const CONFIG_PATH := "res://scripts/server_config.gd"


func test_gateway_config_constants() -> void:
	var cfg: GDScript = load(CONFIG_PATH)
	assert_not_null(cfg, "server_config.gd must load")

	assert_eq(cfg.SERVER_NAME, "gateway", "SERVER_NAME must be 'gateway'")
	assert_eq(cfg.LISTEN_PORT_WS, 9001, "WS listen port must be 9001")
	assert_eq(cfg.LISTEN_PORT_ENET, 0, "gateway must not listen on ENet (0)")
	assert_eq(cfg.MASTER_RPC_HOST, "127.0.0.1", "master RPC host must be loopback")
	assert_eq(cfg.MASTER_RPC_PORT, 9100, "master RPC port must be 9100")
