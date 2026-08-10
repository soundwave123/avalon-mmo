extends "res://addons/gut/test.gd"

# Smoke test for the Avalon master server.
# Pins the Phase B contract by asserting on ServerConfig constants
# AND by asserting that no PG_PASSWORD constant exists — passwords
# must come from environment, never from config (per D-008).

const CONFIG_PATH := "res://scripts/server_config.gd"
const ServerConfigScript = preload(CONFIG_PATH)


func test_master_config_constants() -> void:
	var cfg: GDScript = load(CONFIG_PATH)
	assert_not_null(cfg, "server_config.gd must load")

	assert_eq(ServerConfigScript.SERVER_NAME, "master", "SERVER_NAME must be 'master'")
	assert_eq(ServerConfigScript.RPC_LISTEN_PORT, 9100, "RPC listen port must be 9100")
	assert_eq(ServerConfigScript.PG_HOST, "127.0.0.1", "PG_HOST must be loopback")
	assert_eq(ServerConfigScript.PG_PORT, 5432, "PG_PORT must be 5432")
	assert_eq(ServerConfigScript.PG_DB, "avalon", "PG_DB must be 'avalon'")
	assert_eq(ServerConfigScript.PG_USER, "avalon", "PG_USER must be 'avalon'")


func test_master_config_has_no_password_constant() -> void:
	# Read raw source and assert PG_PASSWORD never appears as a const
	# declaration. Passwords must come from env at runtime only.
	var f := FileAccess.open(CONFIG_PATH, FileAccess.READ)
	assert_not_null(f, "must be able to read server_config.gd source")
	var source: String = f.get_as_text()
	f.close()

	var has_pg_password_const := source.contains("const PG_PASSWORD")
	assert_false(
		has_pg_password_const,
		(
			"server_config.gd must not declare a PG_PASSWORD constant — "
			+ "passwords come from AVALON_PG_PASSWORD env var only (D-008)"
		)
	)
