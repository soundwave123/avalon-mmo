#!/usr/bin/env fish
# dev-up.fish — fish-shell entrypoint for the dev stack.
# Thin wrapper around the canonical bash implementation (scripts/dev-up.sh)
# so the M0 exit criterion's `./scripts/dev-up.fish` invocation works.
# All logic lives in dev-up.sh; this just delegates.
set script_dir (dirname (status --current-filename))
exec bash "$script_dir/dev-up.sh" $argv
