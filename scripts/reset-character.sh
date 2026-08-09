#!/usr/bin/env bash
# reset-character.sh — purge a character's quest + objective state for a clean play-test.
#
# Quests accepted/abandoned before a server fix can linger in the DB (e.g. old state='abandoned' rows).
# This wipes a character's quests so the next boot starts fresh: empty log, every quest-giver shows its
# ! again, all re-acceptable. Does NOT touch inventory or the account.
#
# Usage: scripts/reset-character.sh [username]   (default: player)
set -uo pipefail

USER_NAME="${1:-player}"
psql_exec() { podman exec -i avalon-postgres psql -U avalon -d avalon -c "$1"; }

if ! podman ps --format '{{.Names}}' 2>/dev/null | grep -q '^avalon-postgres$'; then
	echo "[reset] FATAL: avalon-postgres not running (start the stack first: scripts/dev-up.sh)"
	exit 1
fi

echo "[reset] purging quests + objectives for character '$USER_NAME'..."
psql_exec "DELETE FROM chars.character_quest_objectives WHERE character_id
	IN (SELECT id FROM chars.characters WHERE username='$USER_NAME');" >/dev/null
psql_exec "DELETE FROM chars.character_quests WHERE character_id
	IN (SELECT id FROM chars.characters WHERE username='$USER_NAME');" >/dev/null
REMAINING="$(podman exec -i avalon-postgres psql -U avalon -d avalon -tA -c \
	"SELECT count(*) FROM chars.character_quests cq JOIN chars.characters c
	 ON c.id=cq.character_id WHERE c.username='$USER_NAME';" 2>/dev/null | tr -d '[:space:]')"
echo "[reset] done — '$USER_NAME' now has ${REMAINING:-0} quests. Boot with scripts/play.sh for a fresh start."
