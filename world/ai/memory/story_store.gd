extends RefCounted
## The story journal in one SQLite file per world (user://worlds/<id>/story.db): every line
## spoken, every event the game records, who witnessed each one, the running story summary,
## open threads on each pony's mind and the token ledger. Append-only rows; queries by pony,
## day and words. Uses the godot-sqlite addon (addons/godot-sqlite, no FTS5: word search is LIKE).
## available() is false when the addon is missing; callers then keep the old JSON memory.

const SCHEMA := [
	"CREATE TABLE IF NOT EXISTS lines (id INTEGER PRIMARY KEY, day INTEGER, minute INTEGER, place TEXT, kind TEXT, speaker TEXT, listener TEXT, text TEXT)",
	"CREATE TABLE IF NOT EXISTS witnesses (line INTEGER, pony TEXT)",
	"CREATE INDEX IF NOT EXISTS witnesses_pony ON witnesses (pony, line)",
	"CREATE INDEX IF NOT EXISTS lines_day ON lines (day)",
	"CREATE TABLE IF NOT EXISTS summary (key TEXT PRIMARY KEY, text TEXT, through INTEGER)",
	"CREATE TABLE IF NOT EXISTS threads (id INTEGER PRIMARY KEY, pony TEXT, text TEXT, opened INTEGER, closed INTEGER DEFAULT 0)",
	"CREATE INDEX IF NOT EXISTS threads_pony ON threads (pony, closed)",
	"CREATE TABLE IF NOT EXISTS usage (id INTEGER PRIMARY KEY, kind TEXT, input INTEGER, output INTEGER, day INTEGER, minute INTEGER)",
]

var db: Object
var path := ""
var error := ""

static func available() -> bool:
	return ClassDB.class_exists("SQLite")

func open(file_path: String) -> bool:
	close()
	if not available(): error = "SQLite addon missing"; return false
	path = file_path
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(file_path.get_base_dir()))
	db = ClassDB.instantiate("SQLite")
	db.path = file_path
	db.verbosity_level = 0
	if not db.open_db(): error = str(db.error_message); db = null; return false
	db.query("PRAGMA journal_mode=WAL;")
	db.query("PRAGMA synchronous=NORMAL;")
	for statement: String in SCHEMA:
		if not db.query(statement + ";"): error = str(db.error_message); close(); return false
	# Worlds from before 0.0.2 have no cached column in the token ledger (cache reads, 2026-10-25).
	var columns := _rows("PRAGMA table_info(usage);").map(func(row: Dictionary) -> String: return str(row.get("name", "")))
	if "cached" not in columns and not _run("ALTER TABLE usage ADD COLUMN cached INTEGER DEFAULT 0;"): close(); return false
	return true

func is_open() -> bool:
	return db != null

func close() -> void:
	if db != null: db.close_db()
	db = null

func _rows(sql: String, bindings: Array = []) -> Array:
	if db == null: return []
	if not db.query_with_bindings(sql, bindings): error = str(db.error_message); return []
	return (db.query_result as Array).duplicate(true)

func _run(sql: String, bindings: Array = []) -> bool:
	if db == null: return false
	if db.query_with_bindings(sql, bindings): return true
	error = str(db.error_message)
	return false

## One line of the story. kind: "say" (spoken), an event kind ("gift", "day", "outing"...) or
## "brain" (private direction notes; witnesses decide who may ever see it).
func add_line(day: int, minute: int, place: String, kind: String, speaker: String, listener: String, text: String, witnesses: Array) -> int:
	if db == null or text.strip_edges().is_empty(): return 0
	if not _run("INSERT INTO lines (day, minute, place, kind, speaker, listener, text) VALUES (?, ?, ?, ?, ?, ?, ?);",
			[day, minute, place.left(80), kind.left(40), speaker.left(80), listener.left(80), text.left(3000)]): return 0
	var id := int(db.last_insert_rowid)
	var seen := {}
	for who in witnesses:
		var pony := str(who)
		if pony.is_empty() or seen.has(pony): continue
		seen[pony] = true
		_run("INSERT INTO witnesses (line, pony) VALUES (?, ?);", [id, pony])
	return id

func last_line_id() -> int:
	var rows := _rows("SELECT MAX(id) AS id FROM lines;")
	return int(rows[0].id) if not rows.is_empty() and rows[0].id != null else 0

## Lines this pony witnessed, newest last. `before` limits to ids below it (0 = no limit).
func witnessed(pony: String, limit: int, before := 0, kinds: Array = []) -> Array:
	var sql := "SELECT lines.* FROM witnesses JOIN lines ON lines.id = witnesses.line WHERE witnesses.pony = ?"
	var bindings: Array = [pony]
	if before > 0: sql += " AND lines.id < ?"; bindings.append(before)
	if not kinds.is_empty():
		sql += " AND lines.kind IN (%s)" % ",".join(kinds.map(func(_k): return "?"))
		bindings.append_array(kinds)
	sql += " ORDER BY lines.id DESC LIMIT ?;"
	bindings.append(clampi(limit, 1, 400))
	var rows := _rows(sql, bindings)
	rows.reverse()
	return rows

## Lines this pony witnessed today that are not speech: her day so far.
func day_events(pony: String, day: int, limit := 12) -> Array:
	var rows := _rows("SELECT lines.* FROM witnesses JOIN lines ON lines.id = witnesses.line WHERE witnesses.pony = ? AND lines.day = ? AND lines.kind NOT IN ('say', 'brain') ORDER BY lines.id DESC LIMIT ?;", [pony, day, limit])
	rows.reverse()
	return rows

## Older witnessed lines mentioning any of `words`, best (most words matched) first.
func search(pony: String, words: Array, before: int, limit := 6) -> Array:
	var clauses: Array[String] = []
	var bindings: Array = []
	for word in words.slice(0, 8):
		clauses.append("(CASE WHEN lower(lines.text) LIKE ? OR lower(lines.speaker) = ? OR lower(lines.listener) = ? OR lower(lines.place) = ? THEN 1 ELSE 0 END)")
		var w := str(word).to_lower()
		bindings.append_array(["%" + w + "%", w, w, w])
	if clauses.is_empty(): return []
	var score := " + ".join(clauses)
	var sql := "SELECT lines.*, (%s) AS score FROM witnesses JOIN lines ON lines.id = witnesses.line WHERE witnesses.pony = ? AND lines.id < ? AND lines.kind != 'brain' AND (%s) > 0 ORDER BY score DESC, lines.id DESC LIMIT ?;" % [score, score]
	var all_bindings: Array = bindings.duplicate()
	all_bindings.append_array([pony, before])
	all_bindings.append_array(bindings)
	all_bindings.append(limit)
	var rows := _rows(sql, all_bindings)
	rows.sort_custom(func(a, b): return int(a.id) < int(b.id))
	return rows

func lines_after(id: int, limit := 2000) -> Array:
	return _rows("SELECT * FROM lines WHERE id > ? AND kind != 'brain' ORDER BY id LIMIT ?;", [id, limit])

func summary(key: String) -> Dictionary:
	var rows := _rows("SELECT text, through FROM summary WHERE key = ?;", [key])
	return {"text": str(rows[0].text), "through": int(rows[0].through)} if not rows.is_empty() else {"text": "", "through": 0}

func summary_keys() -> Array:
	return _rows("SELECT key FROM summary;").map(func(row): return str(row.key))

func set_summary(key: String, text: String, through: int) -> bool:
	return _run("INSERT INTO summary (key, text, through) VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE SET text = excluded.text, through = excluded.through;", [key, text.left(6000), through])

func open_threads(pony: String, limit := 4) -> Array:
	var rows := _rows("SELECT * FROM threads WHERE pony = ? AND closed = 0 ORDER BY id DESC LIMIT ?;", [pony, limit])
	rows.reverse()
	return rows

func add_thread(pony: String, text: String, opened: int) -> int:
	if not _run("INSERT INTO threads (pony, text, opened) VALUES (?, ?, ?);", [pony, text.left(400), opened]): return 0
	# Old threads fade: a pony keeps her six newest open.
	_run("UPDATE threads SET closed = 1 WHERE pony = ? AND closed = 0 AND id NOT IN (SELECT id FROM threads WHERE pony = ? AND closed = 0 ORDER BY id DESC LIMIT 6);", [pony, pony])
	return int(db.last_insert_rowid)

func close_thread(id: int) -> void:
	_run("UPDATE threads SET closed = 1 WHERE id = ?;", [id])

func add_usage(kind: String, input: int, output: int, day: int, minute: int, cached := 0) -> void:
	_run("INSERT INTO usage (kind, input, output, day, minute, cached) VALUES (?, ?, ?, ?, ?, ?);", [kind.left(40), input, output, day, minute, cached])

## Per pony, biggest first: witnessed lines and their characters (the Context page).
func pony_totals() -> Array:
	return _rows("SELECT witnesses.pony AS pony, COUNT(*) AS lines, SUM(LENGTH(lines.text)) AS chars FROM witnesses JOIN lines ON lines.id = witnesses.line GROUP BY witnesses.pony ORDER BY chars DESC;")

func line_count() -> int:
	var rows := _rows("SELECT COUNT(*) AS n FROM lines;")
	return int(rows[0].n) if not rows.is_empty() else 0

## {kind: {"calls", "input", "output", "cached"}} plus "all". "input" counts every prompt token sent,
## "cached" the part of it the provider billed as a cache read.
func usage_totals() -> Dictionary:
	var result := {"all": {"calls": 0, "input": 0, "output": 0, "cached": 0}}
	for row: Dictionary in _rows("SELECT kind, COUNT(*) AS calls, SUM(input) AS input, SUM(output) AS output, SUM(cached) AS cached FROM usage GROUP BY kind;"):
		var entry := {"calls": int(row.calls), "input": int(row.input if row.input != null else 0), "output": int(row.output if row.output != null else 0), "cached": int(row.cached if row.get("cached") != null else 0)}
		result[str(row.kind)] = entry
		for field in ["calls", "input", "output", "cached"]: result.all[field] += entry[field]
	return result

## A consistent copy for a save slot (SQLite's own VACUUM INTO; the live file stays open).
func copy_to(destination: String) -> bool:
	if db == null: return false
	var absolute := ProjectSettings.globalize_path(destination)
	DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	if FileAccess.file_exists(destination): DirAccess.rename_absolute(absolute, absolute + ".previous")
	return _run("VACUUM INTO ?;", [absolute])

## Replace the live journal with a save slot's copy (loading a save).
func restore_from(source: String) -> bool:
	if not FileAccess.file_exists(source): return false
	var live := path
	close()
	var absolute := ProjectSettings.globalize_path(live)
	for suffix in ["-wal", "-shm"]:
		if FileAccess.file_exists(live + suffix): DirAccess.rename_absolute(absolute + suffix, absolute + suffix + ".replaced")
	if FileAccess.file_exists(live): DirAccess.rename_absolute(absolute, absolute + ".replaced")
	if DirAccess.copy_absolute(ProjectSettings.globalize_path(source), absolute) != OK: return false
	return open(live)

## Loading an older save without its own journal copy: forget everything after `through`.
func rollback(through: int) -> void:
	if db == null or through < 0: return
	_run("DELETE FROM witnesses WHERE line > ?;", [through])
	_run("DELETE FROM lines WHERE id > ?;", [through])
	_run("DELETE FROM threads WHERE opened > ?;", [through])
	# A summary written later may know about the forgotten lines: rebuild it from the journal.
	# A pony summary may run ahead of the global mark (cut-off replies): when one is dropped,
	# reset the mark too, or her lines before it would never be summarized again.
	_run("DELETE FROM summary WHERE key = 'through' AND EXISTS (SELECT 1 FROM summary WHERE key LIKE 'pony:%' AND through > ?);", [through])
	_run("DELETE FROM summary WHERE through > ?;", [through])
