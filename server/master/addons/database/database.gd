# addons/database/database.gd
# Subprocess wrapper for pg_query.sh — parameterized queries via psql -v.
#
# Parameter safety mechanism:
# - $N placeholders in SQL are replaced with :'paramN' references.
# - Params are passed to pg_query.sh as separate OS.execute() args-array
#   elements (never shell-interpolated strings): -v param1="value1" ...
# - pg_query.sh forwards each -v assignment to psql as a distinct argument.
# - psql expands :'paramN' with proper SQL quoting/escaping at the server
#   protocol level. Single quotes are doubled, backslashes escaped, etc.
#
# Safety boundary: args-array from GDScript → OS.execute() → pg_query.sh
# arg array → psql argv. No shell-string concatenation at any point.
#
# T-701: driver selection. AVALON_DB_DRIVER=sidecar routes through pg_pipe.gd
# (persistent avalon-dbd connection; params ride a JSON envelope, quoted server-
# side by psycopg2 — byte-identical output, proven by scripts/test-dbd-parity.sh).
# Any transport failure BEFORE the request is delivered falls back to the
# subprocess path below, so the sidecar being down means "slow", never "wrong".

class_name Database
extends RefCounted

const _PG_QUERY_SH := "res://scripts/infra/pg_query.sh"
const _PG_PIPE := preload("res://addons/database/pg_pipe.gd")
const _DEFAULT_DRIVER := "sidecar"

static var _fallback_warned: bool = false

var _has_result: bool = false
var _result_rows: Array = []


func open_db(_connection_string: String) -> int:
	# Store connection info; pg_query.sh reads AVALON_PG_PASSWORD from env.
	# For now, just verify the script exists.
	return OK


func execute_query(sql: String, params: Array = []) -> int:
	"""
	Execute SQL with bound parameters.

	Safety boundary: args-array from GDScript → OS.execute() → pg_query.sh
	arg array → psql argv. No shell-string concatenation at any point.
	"""
	if _sidecar_selected():
		var reply: Dictionary = _PG_PIPE.request(sql, params)
		if bool(reply.get("delivered", false)):
			if int(reply.get("status", 1)) != 0:
				push_error("[database] sidecar query failed: %s" % str(reply.get("error", "")))
				return FAILED
			_parse_tsv(str(reply.get("out", "")))
			return OK
		if not _fallback_warned:
			push_warning(
				(
					"[database] sidecar unavailable (%s) — using subprocess fallback"
					% str(reply.get("error", ""))
				)
			)
			_fallback_warned = true

	var args: PackedStringArray = []

	# Replace $N→:'paramN' in DESCENDING index order so $10 is replaced
	# before $1 (ascending would turn $10 into :'param1'0).
	for i in range(params.size() - 1, -1, -1):
		# T-399 live find: a GDScript null stringifies to "<null>" and lands as TEXT in the DB
		# (an INTEGER column then errors the whole statement — inventory persist was silently
		# broken for every row carrying a NULL era/cosmetic column). A null param becomes a SQL
		# NULL literal instead of a psql variable; booleans need TRUE/FALSE (str() gives
		# "true"/"false", which psql quotes as text).
		if params[i] == null:
			sql = sql.replace("$" + str(i + 1), "NULL")
			continue
		var param_name: String = "param" + str(i + 1)
		var value: String = str(params[i])
		# T-517: native Godot 4.7's OS.execute re-tokenizes argv elements — embedded double
		# quotes are stripped and the element is split on the spaces around them (a JSON value
		# like {"reason":"a b"} arrived at pg_query.sh as THREE mangled args, so every jsonb
		# audit param failed to parse and every mutating GM verb died with audit_write_failed).
		# Base64 (A-Za-z0-9+/=) contains no quotes or spaces, so it survives any tokenizer;
		# pg_query.sh decodes -w pairs back to psql -v pairs.
		args.append("-w")
		args.append(param_name + "=" + Marshalls.utf8_to_base64(value))

		# Replace $N placeholder with :'paramN' psql variable reference.
		# Descending loop ensures $10 replaced before $1.
		sql = sql.replace("$" + str(i + 1), ":'" + param_name + "'")

	# T-517: SQL rides the same base64 armor via -Q — an unambiguous flag, so a stray
	# positional can never be consumed as psql's database argument again.
	args.append("-Q")
	args.append(Marshalls.utf8_to_base64(sql))

	var output: Array[String] = []
	var script_path := ProjectSettings.globalize_path(_PG_QUERY_SH)
	var exit_code: int = OS.execute(script_path, args, output, false)

	if exit_code != 0:
		push_error(
			(
				"[database] query failed (exit=%d): %s"
				% [exit_code, output[0] if output.size() > 0 else ""]
			)
		)
		return exit_code

	# OS.execute() returns stdout as a single joined string in output[0]
	# (may contain embedded newlines from psql multi-line TSV).
	_parse_tsv("\n".join(output) if output.size() > 0 else "")
	return OK


static func _sidecar_selected() -> bool:
	var driver := OS.get_environment("AVALON_DB_DRIVER").strip_edges()
	if driver == "":
		driver = _DEFAULT_DRIVER
	return driver == "sidecar"


# Shared header+TSV parser — the sidecar emits psql-identical output so both
# drivers funnel through this one parser (parity is proven as a byte-diff).
func _parse_tsv(full_output: String) -> void:
	_result_rows.clear()
	_has_result = false
	var lines: PackedStringArray = full_output.split("\n")
	# Remove trailing empty line (psql appends final newline).
	while lines.size() > 0 and lines[lines.size() - 1].is_empty():
		lines.remove_at(lines.size() - 1)
	if lines.size() == 0:
		return
	var headers: PackedStringArray = lines[0].split("	")
	# Data rows start at index 1 (skip header).
	for row_idx in range(1, lines.size()):
		var raw: String = lines[row_idx]
		if raw.is_empty():
			continue
		_has_result = true
		var values: PackedStringArray = raw.split("	")
		var row_dict: Dictionary = {}
		for col in range(headers.size()):
			var key: String = headers[col].strip_edges()
			var val: String = values[col].strip_edges() if col < values.size() else ""
			row_dict[key] = val
		_result_rows.append(row_dict)


func query_result() -> Variant:
	return _result_rows.duplicate() if _has_result else null


func close_db() -> void:
	_result_rows.clear()
	_has_result = false
