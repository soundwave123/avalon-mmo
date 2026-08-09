#!/usr/bin/env bash
# scripts/signal/notify.sh
# Sends a Signal message via signal-cli.
#
# Usage:
#   ./scripts/signal/notify.sh "subject" "body"
#   ./scripts/signal/notify.sh --approval "subject" "body"

set -uo pipefail

RED=$'\e[31m'
GREEN=$'\e[32m'
RESET=$'\e[0m'

MODE="notify"
if [[ "${1:-}" == "--approval" ]]; then
    MODE="approval"
    shift
fi

if [[ $# -lt 2 ]]; then
    echo "Usage: notify.sh [--approval] <subject> <body>"
    exit 2
fi

subject="$1"
body="$2"

if [[ -z "${AVALON_SIGNAL_NUMBER:-}" || -z "${AVALON_SIGNAL_RECIPIENT:-}" ]]; then
    echo "${RED}[signal] AVALON_SIGNAL_NUMBER or AVALON_SIGNAL_RECIPIENT not set.${RESET}"
    echo "Set in ~/.config/avalon/secrets.env"
    exit 1
fi

if ! command -v signal-cli >/dev/null 2>&1; then
    echo "${RED}[signal] signal-cli not installed.${RESET}"
    exit 1
fi

message="[Avalon] $subject

$body"

if [[ "$MODE" == "approval" ]]; then
    message="$message

Reply 'approved' or 'rejected' within 30 minutes."
fi

if ! signal-cli -a "$AVALON_SIGNAL_NUMBER" send -m "$message" "$AVALON_SIGNAL_RECIPIENT"; then
    echo "${RED}[signal] send failed${RESET}"
    exit 1
fi

echo "${GREEN}[signal] sent${RESET}"

if [[ "$MODE" == "approval" ]]; then
    echo "[signal] waiting for reply (30 min timeout)..."
    deadline=$(( $(date +%s) + 1800 ))
    while [[ $(date +%s) -lt $deadline ]]; do
        replies=$(signal-cli -a "$AVALON_SIGNAL_NUMBER" receive --timeout 30 2>&1 | grep -i 'Body:' | tail -5 || true)
        if echo "$replies" | grep -qi 'approved'; then
            echo "${GREEN}[signal] APPROVED${RESET}"
            exit 0
        fi
        if echo "$replies" | grep -qi 'rejected'; then
            echo "${RED}[signal] REJECTED${RESET}"
            exit 1
        fi
        sleep 10
    done
    echo "${RED}[signal] timeout waiting for approval${RESET}"
    exit 124
fi

exit 0
