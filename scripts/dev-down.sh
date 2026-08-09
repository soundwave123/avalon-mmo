#!/usr/bin/env bash
# Stop all Avalon dev servers.
#
# Finds godot-bin processes listening on target ports (TCP+UDP) and kills them
# surgically. Checks both TCP (gateway:9001, master:9100) and UDP (world:9200).
# Only kills the exact PID holding the port — never blanket-pkills godot-bin,
# so unrelated Godot/editor instances are left alone.

set -euo pipefail

PORTS=(9001 9100 "${AVALON_PORT:-9200}")

# ── Surgical kill: find godot-bin PIDs owning each target port ─────
# Args: $1=port $2=signal_name (TERM or KILL)
kill_port_owner() {
    local port=$1
    local sig=$2
    local found_pids=""

    # TCP listeners
    local tcp_pids
    tcp_pids=$(ss -tnlp "sport = :$port" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | sort -u || true)
    # UDP listeners
    local udp_pids
    udp_pids=$(ss -ulnp "sport = :$port" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | sort -u || true)
    found_pids="$tcp_pids $udp_pids"
    found_pids=$(echo "$found_pids" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | xargs || true)

    if [[ -n "$found_pids" ]]; then
        for pid in $found_pids; do
            # Verify this is actually an Avalon dev server before killing (don't nuke editor
            # instances). T-346: the flatpak binary is named "godot-bin"; the native 4.7 binary
            # godot-bin.sh execs directly is plain "godot" — match on either, PLUS require a
            # --path server/{master,gateway,world} so a bare editor/game instance is never hit.
            local cmdline
            cmdline=$(ps -p "$pid" -o args= 2>/dev/null || echo "")
            if echo "$cmdline" | grep -qE "godot-bin|/godot( |$)" \
                && echo "$cmdline" | grep -qE "server/(master|gateway|world)"; then
                echo "[dev-down] SIG${sig} avalon server on port $port (PID $pid)"
                kill "-${sig}" "$pid" 2>/dev/null || true
            fi
        done
    fi
}

# First pass: SIGTERM (graceful)
echo "[dev-down] Sending SIGTERM to Avalon servers..."
for port in "${PORTS[@]}"; do
    kill_port_owner "$port" TERM
done

sleep 2

# Second pass: SIGKILL (force) for anything that didn't exit
for port in "${PORTS[@]}"; do
    kill_port_owner "$port" KILL
done

# T-701: stop the avalon-dbd DB sidecar (python, not godot — PID-file based, with
# a cmdline check so a recycled PID is never killed).
DBD_PID_FILE=/tmp/avalon-dev/dbd.pid
if [[ -f "$DBD_PID_FILE" ]]; then
    dbd_pid=$(cat "$DBD_PID_FILE")
    if ps -p "$dbd_pid" -o args= 2>/dev/null | grep -q "avalon_dbd"; then
        kill "$dbd_pid" 2>/dev/null || true
        echo "[dev-down] Stopped avalon-dbd sidecar (PID $dbd_pid)"
    fi
    rm -f "$DBD_PID_FILE"
fi

echo "[dev-down] All servers stopped"
exit 0
