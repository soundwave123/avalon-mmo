#!/usr/bin/env bash
# Playtest download server wrapper — start|stop|status (mirrors feedback-portal.sh).
# Serves dist/*.zip over HTTP with resume support. Requires AVALON_DIST_TOKEN.
set -uo pipefail
cd "$(dirname "$0")/.."
PIDFILE=/tmp/avalon-dist.pid
LOG=/tmp/avalon-dist.log
PORT="${AVALON_DIST_PORT:-8090}"

case "${1:-}" in
    start)
        [[ -n "${AVALON_DIST_TOKEN:-}" ]] || { echo "set AVALON_DIST_TOKEN"; exit 1; }
        if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
            echo "already running (pid $(cat "$PIDFILE"))"; exit 0
        fi
        nohup python3 infra/playtest/dist_server.py --port "$PORT" --dir dist \
            > "$LOG" 2>&1 &
        echo $! > "$PIDFILE"
        sleep 1
        kill -0 "$(cat "$PIDFILE")" 2>/dev/null || { echo "failed to start (see $LOG)"; exit 1; }
        echo "dist server started: pid $(cat "$PIDFILE") http://0.0.0.0:$PORT/?token=<your-token>"
        ;;
    stop)
        [[ -f "$PIDFILE" ]] && kill "$(cat "$PIDFILE")" 2>/dev/null && rm -f "$PIDFILE" \
            && echo "stopped" || echo "not running"
        ;;
    status)
        if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
            echo "running (pid $(cat "$PIDFILE"), port $PORT)"
        else
            echo "not running"
        fi
        ;;
    *) echo "usage: dist-server.sh start|stop|status"; exit 2 ;;
esac
