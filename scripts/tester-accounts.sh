#!/usr/bin/env bash
# Owner-only tester credential provisioning. Plaintext exists only in this process and the final
# add/reset output; Postgres receives sha256$<salt>$<digest> and list never selects password_hash.
#
# T-740: what `add`/`reset` print is a ONE-TIME password — 12 readable characters, marked
# password_is_otp in the DB. The gateway refuses to open a session while that flag is set; the
# player's first login makes them choose their own password, which clears it. So this output is
# safe to read down a phone line and worthless to anyone who finds it later.

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

# T-740 readable alphabet: no 0/O, no 1/l/I — the four glyphs people mistype when a password is
# read aloud or copied off a screen. 55 symbols ^ 12 chars ~= 69 bits, plenty for a password that
# survives exactly one login (friends-and-family playtest, deliberately not gold-plated).
OTP_ALPHABET='23456789ABCDEFGHJKMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz'
OTP_LENGTH=12

usage() {
	echo "Usage: scripts/tester-accounts.sh add <username> | reset <username> | list | disable <username>"
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

require_tools() {
	command -v openssl >/dev/null 2>&1 || { echo "ERROR: openssl is required" >&2; exit 2; }
	command -v sha256sum >/dev/null 2>&1 || { echo "ERROR: sha256sum is required" >&2; exit 2; }
	command -v od >/dev/null 2>&1 || { echo "ERROR: od is required" >&2; exit 2; }
}

# Uniform draw from OTP_ALPHABET. Bytes at or above the rejection ceiling are DISCARDED rather
# than folded with %, because 256 is not a multiple of 55 — plain modulo would make the first
# 36 symbols measurably likelier than the rest.
generate_otp() {
	local size=${#OTP_ALPHABET}
	local limit=$(( 256 / size * size ))
	local out="" byte
	while (( ${#out} < OTP_LENGTH )); do
		for byte in $(openssl rand 64 | od -An -v -tu1); do
			if (( byte < limit )); then
				out+="${OTP_ALPHABET:byte % size:1}"
				if (( ${#out} >= OTP_LENGTH )); then
					break
				fi
			fi
		done
	done
	printf '%s' "$out"
}

hash_password() {
	local password="$1" salt digest
	salt="$(openssl rand -hex 16)"
	digest="$(printf '%s' "${salt}:${password}" | sha256sum | awk '{print $1}')"
	printf 'sha256$%s$%s' "$salt" "$digest"
}

# The one place the plaintext is shown. The trailing line is the whole point of T-740 — whoever
# hands this over must know it is not the password the player keeps.
print_credentials() {
	printf 'username: %s\npassword: %s\n' "$1" "$2"
	echo "one-time — they'll pick their own password (min 8 characters) on first login"
}

command="${1:-}"
case "$command" in
	add)
		username="${2:-}"
		require_username "$username"
		require_tools
		password="$(generate_otp)"
		bash "$PG_QUERY" \
			-v "username=$username" \
			-v "password_hash=$(hash_password "$password")" \
			"INSERT INTO auth.accounts (username, password_hash, password_is_otp)
VALUES (:'username', :'password_hash', true) RETURNING username" >/dev/null
		print_credentials "$username" "$password"
		;;
	reset)
		# Formalizes what the owner used to do with hand-rolled SQL. Same path as `add`, so a
		# reset friend goes through the same choose-your-own-password screen they saw on day one.
		username="${2:-}"
		require_username "$username"
		require_tools
		password="$(generate_otp)"
		result="$(bash "$PG_QUERY" \
			-v "username=$username" \
			-v "password_hash=$(hash_password "$password")" \
			"UPDATE auth.accounts SET password_hash = :'password_hash', password_is_otp = true
WHERE username = :'username' RETURNING username")"
		if ! tail -n +2 <<<"$result" | grep -qxF "$username"; then
			echo "ERROR: account not found: $username" >&2
			exit 1
		fi
		print_credentials "$username" "$password"
		;;
	list)
		bash "$PG_QUERY" \
			"SELECT username, created_at, is_active, password_is_otp FROM auth.accounts
ORDER BY username"
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
# (`reset` cannot change who is active, so it does not need a sync.)
case "${1:-}" in
	add | disable)
		bash "$PG_QUERY" \
			"SELECT username FROM auth.accounts WHERE is_active = true ORDER BY username" \
			| tail -n +2 > infra/feedback/testers.txt \
			&& echo "portal dropdown synced ($(wc -l < infra/feedback/testers.txt) active testers)"
		;;
esac
