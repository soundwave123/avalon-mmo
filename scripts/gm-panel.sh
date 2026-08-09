#!/usr/bin/env bash
# T-511 localhost GM panel lifecycle. NEVER port-forward this admin surface.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PANEL="$PROJECT_DIR/infra/gm_panel.py"

if [[ -f "$PROJECT_DIR/.env" ]]; then
	set -a
	# shellcheck disable=SC1091
	source "$PROJECT_DIR/.env"
	set +a
fi

PID_FILE="${AVALON_ADMIN_PID:-/tmp/avalon-gm-panel.pid}"
LOG_FILE="${AVALON_ADMIN_LOG:-/tmp/avalon-gm-panel.log}"
HOST="${AVALON_ADMIN_BIND:-127.0.0.1}"
PORT="${AVALON_ADMIN_PORT:-8095}"

usage() {
	echo "Usage: scripts/gm-panel.sh start|stop|status"
}

is_running() {
	[[ -f "$PID_FILE" ]] && kill -0 "$(<"$PID_FILE")" >/dev/null 2>&1
}

case "${1:-}" in
	start)
		if [[ -z "${AVALON_ADMIN_TOKEN:-}" || -z "${AVALON_OPS_SECRET:-}" ]]; then
			echo "ERROR: AVALON_ADMIN_TOKEN and AVALON_OPS_SECRET are required" >&2
			exit 2
		fi
		if is_running; then
			echo "GM panel already running: pid $(<"$PID_FILE")"
			exit 0
		fi
		mkdir -p "$(dirname "$LOG_FILE")"
		nohup python3 "$PANEL" --host "$HOST" --port "$PORT" >>"$LOG_FILE" 2>&1 &
		pid="$!"
		echo "$pid" > "$PID_FILE"
		sleep 0.2
		if ! kill -0 "$pid" >/dev/null 2>&1; then
			rm -f "$PID_FILE"
			echo "ERROR: GM panel failed to start; see $LOG_FILE" >&2
			exit 1
		fi
		echo "WARNING: NEVER PORT-FORWARD $HOST:$PORT — local/LAN operations only."
		echo "GM panel started: pid $pid http://$HOST:$PORT/?token=<AVALON_ADMIN_TOKEN>"
		;;
	stop)
		if ! is_running; then
			rm -f "$PID_FILE"
			echo "GM panel stopped"
			exit 0
		fi
		pid="$(<"$PID_FILE")"
		kill "$pid" >/dev/null 2>&1 || true
		for _ in {1..50}; do
			if ! kill -0 "$pid" >/dev/null 2>&1; then
				rm -f "$PID_FILE"
				echo "GM panel stopped"
				exit 0
			fi
			sleep 0.1
		done
		kill -9 "$pid" >/dev/null 2>&1 || true
		rm -f "$PID_FILE"
		echo "GM panel stopped"
		;;
	status)
		if is_running; then
			echo "GM panel running: pid $(<"$PID_FILE") at $HOST:$PORT"
		else
			rm -f "$PID_FILE"
			echo "GM panel not running"
		fi
		;;
	*)
		usage >&2
		exit 2
		;;
esac
