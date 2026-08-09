extends Node
# Autoload singleton — accessible as ServerConfig from anywhere

const SERVER_NAME := "gateway"
const LISTEN_PORT_WS := 9001
const LISTEN_PORT_ENET := 0  # gateway uses WebSocket only
const MASTER_RPC_HOST := "127.0.0.1"
const MASTER_RPC_PORT := 9100

# JWT configuration (loaded from environment at runtime)
# AVALON_JWT_SECRET — 32+ byte signing secret (required)
# AVALON_JWT_TTL_SECONDS — token lifetime in seconds (default: 7200)
