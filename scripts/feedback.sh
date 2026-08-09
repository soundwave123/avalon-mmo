#!/usr/bin/env bash
# Orchestrator triage wrapper for the T-502 playtest feedback queue.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

exec python3 "$PROJECT_DIR/infra/feedback/feedback_cli.py" "$@"
