#!/usr/bin/env bash
# Start/stop/status wrapper for the T-502 playtest feedback portal.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PORTAL="$PROJECT_DIR/infra/feedback/portal.py"
PID_FILE="${AVALON_FEEDBACK_PID:-/tmp/avalon-feedback.pid}"
LOG_FILE="${AVALON_FEEDBACK_LOG:-/tmp/avalon-feedback.log}"
HOST="${AVALON_FEEDBACK_HOST:-0.0.0.0}"
PORT="${AVALON_FEEDBACK_PORT:-8088}"

usage() {
	echo "Usage: scripts/feedback-portal.sh start|stop|status"
}

is_running() {
	[[ -f "$PID_FILE" ]] && kill -0 "$(<"$PID_FILE")" >/dev/null 2>&1
}

case "${1:-}" in
	start)
		if [[ -z "${AVALON_FEEDBACK_TOKEN:-}" ]]; then
			echo "ERROR: set AVALON_FEEDBACK_TOKEN to the shared URL token before starting" >&2
			exit 2
		fi
		if is_running; then
			echo "feedback portal already running: pid $(<"$PID_FILE")"
			exit 0
		fi
		mkdir -p "$(dirname "$LOG_FILE")"
		nohup python3 "$PORTAL" --host "$HOST" --port "$PORT" >>"$LOG_FILE" 2>&1 &
		pid="$!"
		echo "$pid" > "$PID_FILE"
		sleep 0.2
		if ! kill -0 "$pid" >/dev/null 2>&1; then
			rm -f "$PID_FILE"
			echo "ERROR: feedback portal failed to start; see $LOG_FILE" >&2
			exit 1
		fi
		echo "feedback portal started: pid $pid http://$HOST:$PORT/?token=<shared-token>"
		;;
	stop)
		if ! is_running; then
			rm -f "$PID_FILE"
			echo "feedback portal stopped"
			exit 0
		fi
		pid="$(<"$PID_FILE")"
		kill "$pid" >/dev/null 2>&1 || true
		for _ in {1..50}; do
			if ! kill -0 "$pid" >/dev/null 2>&1; then
				rm -f "$PID_FILE"
				echo "feedback portal stopped"
				exit 0
			fi
			sleep 0.1
		done
		kill -9 "$pid" >/dev/null 2>&1 || true
		rm -f "$PID_FILE"
		echo "feedback portal stopped"
		;;
	status)
		if is_running; then
			echo "feedback portal running: pid $(<"$PID_FILE") port $PORT"
		else
			rm -f "$PID_FILE"
			echo "feedback portal not running"
		fi
		;;
	*)
		usage >&2
		exit 2
		;;
esac
