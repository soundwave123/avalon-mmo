class_name ServerConnectionConfig
extends RefCounted

# T-500: portable playtest builds keep this file beside the executable. The same host is shared by
# the gateway login seam and the world ENet connection; ports remain owned by their callers.
const FILE_NAME := "server.cfg"
const SECTION := "server"
const HOST_KEY := "host"
const BUILD_KEY := "build"  # T-514: baked build stamp (ISO-8601 UTC) sent to the server at login
const PORT_KEY := "port"  # T-742: optional gateway login port (self-hosts on non-default ports)
const LOOPBACK_HOST := "127.0.0.1"
const DEFAULT_GATEWAY_PORT := 9001


static func config_path_for_executable(executable_path: String) -> String:
	return executable_path.get_base_dir().path_join(FILE_NAME)


static func resolve_runtime_host(
	override_host: String, executable_path: String, environment_host: String
) -> String:
	var override := override_host.strip_edges()
	return (
		override
		if override != ""
		else resolve_host(config_path_for_executable(executable_path), environment_host)
	)


static func resolve_host(config_path: String, environment_host: String) -> String:
	var configured_host := _load_host(config_path)
	if configured_host != "":
		return configured_host
	var env_host := environment_host.strip_edges()
	return env_host if env_host != "" else LOOPBACK_HOST


static func _load_host(config_path: String) -> String:
	if config_path == "":
		return ""
	var cfg := ConfigFile.new()
	if cfg.load(config_path) != OK:
		return ""
	return str(cfg.get_value(SECTION, HOST_KEY, "")).strip_edges()


# T-742: the gateway login port. Same precedence family as the host: env override
# (dev/harness), else the server.cfg beside the executable, else the 9001 default.
# Invalid or out-of-range values fall back rather than strand the client.
static func resolve_runtime_gateway_port(executable_path: String, environment_port: String) -> int:
	var env_port := _parse_port(environment_port)
	if env_port != 0:
		return env_port
	var cfg := ConfigFile.new()
	if cfg.load(config_path_for_executable(executable_path)) == OK:
		var cfg_port := _parse_port(str(cfg.get_value(SECTION, PORT_KEY, "")))
		if cfg_port != 0:
			return cfg_port
	return DEFAULT_GATEWAY_PORT


static func _parse_port(raw: String) -> int:
	var trimmed := raw.strip_edges()
	if trimmed == "" or not trimmed.is_valid_int():
		return 0
	var port := int(trimmed)
	return port if port >= 1 and port <= 65535 else 0


# T-514: the build stamp this client reports at login. AVALON_CLIENT_BUILD overrides (source/dev),
# else the value baked beside the executable by build-playtest.sh, else "" (dev/source => the server
# gate, when enabled, treats an empty build as outdated; when disabled it is ignored).
static func resolve_build(executable_path: String, environment_build: String) -> String:
	var env_build := environment_build.strip_edges()
	if env_build != "":
		return env_build
	var cfg := ConfigFile.new()
	if cfg.load(config_path_for_executable(executable_path)) != OK:
		return ""
	return str(cfg.get_value(SECTION, BUILD_KEY, "")).strip_edges()
