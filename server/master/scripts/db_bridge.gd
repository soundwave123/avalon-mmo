# T-701: the master's ONE Postgres bridge — the connection idiom moved verbatim out of
# character_manager.gd (AT the 1000-line cap). Every store still reaches the DB through
# CharacterManager.db_execute/db_query (the T-208 seam), which delegates here; this stays the
# one place to swap the driver (addons/database/database.gd selects subprocess vs sidecar).
extends RefCounted

const DB_HOST := "localhost"
const DB_PORT := 5432
const DB_NAME := "avalon"
const DB_USER := "avalon"
const DB_PASS := ""


static func execute(sql: String, parameters: Array) -> bool:
	var db := _get_db()
	if db == null:
		return false
	var err: int = db.execute_query(sql, parameters)
	db.close_db()
	if err != OK:
		printerr("[character_manager] database query failed: %d" % err)
		return false
	return true


static func query(sql: String, parameters: Array) -> Array:
	var db := _get_db()
	if db == null:
		return []
	var err: int = db.execute_query(sql, parameters)
	if err != OK:
		printerr("[character_manager] database query failed: %d" % err)
		db.close_db()
		return []
	var result: Variant = db.query_result()
	db.close_db()
	return result if result is Array else []


static func _get_db() -> Object:
	var db := _create_db()
	if db == null:
		return null
	var err: int = (
		db
		. open_db(
			(
				"host={h} port={p} dbname={d} user={u} password={pw}"
				. format(
					{
						"h": DB_HOST,
						"p": DB_PORT,
						"d": DB_NAME,
						"u": DB_USER,
						"pw": DB_PASS,
					}
				)
			)
		)
	)
	if err != OK:
		printerr("[character_manager] failed to connect to Postgres (err=%d)" % err)
		return null
	return db


static func _create_db() -> Object:
	var Database := load("res://addons/database/database.gd")
	return Database.new() if Database != null else null
