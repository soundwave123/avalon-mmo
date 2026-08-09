extends "res://addons/gut/test.gd"

const ServerConnectionConfig = preload("res://scripts/net/server_connection_config.gd")
const TMP_CFG := "user://t500-server.cfg"


func before_each() -> void:
	_remove_tmp_config()


func after_each() -> void:
	_remove_tmp_config()


# T-514: the build stamp the client reports at login.
func test_build_env_override_wins_and_is_trimmed() -> void:
	assert_eq(
		ServerConnectionConfig.resolve_build("user://ignored/Avalon", "  2026-07-16T19:38:00Z  "),
		"2026-07-16T19:38:00Z"
	)


func test_build_read_from_config_beside_executable() -> void:
	# resolve_build derives "<exe dir>/server.cfg", so the config must sit beside the fake executable.
	DirAccess.make_dir_recursive_absolute("user://t514")
	var cfg := ConfigFile.new()
	cfg.set_value("server", "build", "2026-07-16T19:38:00Z")
	assert_eq(cfg.save("user://t514/server.cfg"), OK)
	assert_eq(
		ServerConnectionConfig.resolve_build("user://t514/Avalon", ""), "2026-07-16T19:38:00Z"
	)
	DirAccess.remove_absolute("user://t514/server.cfg")


func test_build_is_empty_when_no_override_and_no_config() -> void:
	assert_eq(ServerConnectionConfig.resolve_build("user://missing/Avalon", ""), "")


func test_config_host_wins_over_environment_and_is_trimmed() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("server", "host", "  play.avalon.example  ")
	assert_eq(cfg.save(TMP_CFG), OK)

	assert_eq(ServerConnectionConfig.resolve_host(TMP_CFG, "192.168.1.50"), "play.avalon.example")


func test_environment_host_is_preserved_when_config_is_missing() -> void:
	assert_eq(ServerConnectionConfig.resolve_host(TMP_CFG, "  192.168.1.50  "), "192.168.1.50")


func test_loopback_is_the_final_fallback() -> void:
	assert_eq(ServerConnectionConfig.resolve_host(TMP_CFG, ""), "127.0.0.1")


func test_blank_config_value_falls_back_to_environment() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("server", "host", "   ")
	assert_eq(cfg.save(TMP_CFG), OK)

	assert_eq(ServerConnectionConfig.resolve_host(TMP_CFG, "10.20.30.40"), "10.20.30.40")


func test_config_path_is_beside_exported_executable() -> void:
	assert_eq(
		ServerConnectionConfig.config_path_for_executable("/opt/avalon/Avalon.x86_64"),
		"/opt/avalon/server.cfg"
	)


func test_runtime_override_keeps_gateway_route_host_for_world_connect() -> void:
	assert_eq(
		ServerConnectionConfig.resolve_runtime_host(
			" routed.example ", "/opt/avalon/Avalon.x86_64", "192.168.1.50"
		),
		"routed.example",
	)


func _remove_tmp_config() -> void:
	var path := ProjectSettings.globalize_path(TMP_CFG)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
