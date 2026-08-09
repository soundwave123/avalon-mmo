extends Node
# Autoload singleton — accessible as ServerConfig from anywhere

const SERVER_NAME := "gateway"
const LISTEN_PORT_WS := 9001  # default; runtime override below (T-742)
const LISTEN_PORT_ENET := 0  # gateway uses WebSocket only
const MASTER_RPC_HOST := "127.0.0.1"
const MASTER_RPC_PORT := 9100

# T-742 (self-host wizard): env overrides, the world server_config's exact pattern.
# run-server.ps1 / dev-up load .env into the servers' environment, so the repo-root
# .env stays the one config source of truth.
#   AVALON_GATEWAY_PORT  WS listen port clients log in on (default: 9001)
#   AVALON_PORT          world port ANNOUNCED to clients at login (default: 9200) —
#                        the SAME env var the world server listens on, so one .env key
#                        keeps the world's listener and the gateway's announcement in
#                        step by construction.
const DEFAULT_WORLD_ANNOUNCE_PORT := 9200

static var _listen_port_ws: int = LISTEN_PORT_WS
static var _world_announce_port: int = DEFAULT_WORLD_ANNOUNCE_PORT

# JWT configuration (loaded from environment at runtime)
# AVALON_JWT_SECRET — 32+ byte signing secret (required)
# AVALON_JWT_TTL_SECONDS — token lifetime in seconds (default: 7200)


func _ready() -> void:
	_listen_port_ws = parse_port(OS.get_environment("AVALON_GATEWAY_PORT"), LISTEN_PORT_WS)
	_world_announce_port = parse_port(
		OS.get_environment("AVALON_PORT"), DEFAULT_WORLD_ANNOUNCE_PORT
	)


static func get_listen_port_ws() -> int:
	return _listen_port_ws


static func get_world_announce_port() -> int:
	return _world_announce_port


# T-742: pure so the fallback rules are testable — blank, garbage, or out-of-range
# values keep the default instead of taking the stack down.
static func parse_port(raw: String, fallback: int) -> int:
	var trimmed := raw.strip_edges()
	if trimmed == "" or not trimmed.is_valid_int():
		return fallback
	var port := int(trimmed)
	return port if port >= 1 and port <= 65535 else fallback
