#!/usr/bin/env bash
# Owner-only tester credential provisioning. Plaintext exists only in this process and the final
# add output; Postgres receives sha256$<salt>$<digest> and list never selects password_hash.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PG_QUERY="$SCRIPT_DIR/infra/pg_query.sh"

if [[ -f "$PROJECT_DIR/.env" ]]; then
	set -a
	# shellcheck disable=SC1091
	source "$PROJECT_DIR/.env"
	set +a
fi

usage() {
	echo "Usage: scripts/tester-accounts.sh add <username> | list | disable <username>"
}

valid_username() {
	[[ "$1" =~ ^[a-z0-9_-]{3,20}$ ]]
}

require_username() {
	local username="${1:-}"
	if ! valid_username "$username"; then
		echo "ERROR: username must match ^[a-z0-9_-]{3,20}$" >&2
		exit 2
	fi
}

command="${1:-}"
case "$command" in
	add)
		username="${2:-}"
		require_username "$username"
		command -v openssl >/dev/null 2>&1 || { echo "ERROR: openssl is required" >&2; exit 2; }
		command -v sha256sum >/dev/null 2>&1 || { echo "ERROR: sha256sum is required" >&2; exit 2; }
		password="$(openssl rand -hex 18)"
		salt="$(openssl rand -hex 16)"
		digest="$(printf '%s' "${salt}:${password}" | sha256sum | awk '{print $1}')"
		password_hash="sha256\$${salt}\$${digest}"
		bash "$PG_QUERY" \
			-v "username=$username" \
			-v "password_hash=$password_hash" \
			"INSERT INTO auth.accounts (username, password_hash)
VALUES (:'username', :'password_hash') RETURNING username" >/dev/null
		printf 'username: %s\npassword: %s\n' "$username" "$password"
		;;
	list)
		bash "$PG_QUERY" \
			"SELECT username, created_at, is_active FROM auth.accounts ORDER BY username"
		;;
	disable)
		username="${2:-}"
		require_username "$username"
		result="$(bash "$PG_QUERY" \
			-v "username=$username" \
			"UPDATE auth.accounts SET is_active = false
WHERE username = :'username' AND is_active = true RETURNING username")"
		if ! tail -n +2 <<<"$result" | grep -qxF "$username"; then
			echo "ERROR: active account not found: $username" >&2
			exit 1
		fi
		echo "disabled: $username"
		;;
	*)
		usage >&2
		exit 2
		;;
esac

# Sync the feedback portal's tester dropdown (a plain file — the internet-facing portal must
# never read the game DB). Runs after every successful add/list/disable; re-read per request.
case "${1:-}" in
	add | disable)
		bash "$PG_QUERY" \
			"SELECT username FROM auth.accounts WHERE is_active = true ORDER BY username" \
			| tail -n +2 > infra/feedback/testers.txt \
			&& echo "portal dropdown synced ($(wc -l < infra/feedback/testers.txt) active testers)"
		;;
esac
