extends Control
## AI context page (dev 2026-10-15: "a context section in the main menu to know whats going on"):
## per world, what the ponies remember and how big it is, what one request sends, and how the
## last requests went (world/ai/llm_client.gd status file). Read only. Same embedding as
## provider_settings.gd: `setup(surface)`, `open()`, `closed`, `controls`. 900×840; scrolls.
signal closed
const STORE := preload("res://world/ai/memory/story_store.gd")
const LLM := preload("res://world/ai/llm_client.gd")
const PROMPTS := preload("res://world/ai/director_prompts.gd")
const CATALOGUE := preload("res://world/saves/save_catalogue.gd")
const TEXT := Color("edd6a2")
const WARN := Color("ff9f6b")
## Pony rows shown per world, biggest memory first.
const PONY_ROWS := 30
var worlds_root := CATALOGUE.ROOT
var status_path := LLM.STATUS_PATH
var controls: Array[Control] = []
var panel: Node
var worlds: Array[String] = []
var world_index := 0
var _scroll: ScrollContainer
var _list: VBoxContainer
var _world_button: Button
var _back: Button
var _body: VBoxContainer


func setup(surface: Node) -> void:
	panel = surface; size = Vector2(900, 840); mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scroll = ScrollContainer.new(); _scroll.size = size; _scroll.follow_focus = true
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.get_v_scroll_bar().value_changed.connect(func(_value): _refresh_panel())
	add_child(_scroll)
	var margin := MarginContainer.new(); margin.custom_minimum_size.x = 880
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 66 if side == "left" else (46 if side == "right" else 40))
	_scroll.add_child(margin)
	_list = VBoxContainer.new(); _list.add_theme_constant_override("separation", 10); margin.add_child(_list)
	_label(_list, "AI CONTEXT", 30)
	_back = _button("Back"); _back.pressed.connect(func(): closed.emit())
	_world_button = _button(""); _world_button.pressed.connect(func(): world_index = posmod(world_index + 1, maxi(1, worlds.size())); _show())
	_body = VBoxContainer.new(); _body.add_theme_constant_override("separation", 8); _list.add_child(_body)
	controls = [_back, _world_button]
	hide()


func open() -> void:
	worlds = world_ids(worlds_root)
	world_index = clampi(world_index, 0, maxi(0, worlds.size() - 1))
	show(); _show(); _scroll.scroll_vertical = 0; _back.grab_focus()


## World folders, most recently changed first.
static func world_ids(root: String) -> Array[String]:
	var found: Array = []
	var dir := DirAccess.open(root)
	if dir == null: return []
	for id: String in dir.get_directories():
		var folder := root.path_join(id)
		if not FileAccess.file_exists(folder.path_join("context.json")) and not FileAccess.file_exists(folder.path_join("story.db")): continue
		var stamp := maxi(FileAccess.get_modified_time(folder.path_join("context.json")), FileAccess.get_modified_time(folder.path_join("story.db")))
		found.append({"id": id, "stamp": stamp})
	found.sort_custom(func(a, b): return a.stamp > b.stamp)
	var ids: Array[String] = []
	for row: Dictionary in found: ids.append(str(row.id))
	return ids


static func size_text(bytes: int) -> String:
	var tokens := int(ceil(bytes / 3.6))
	var amount := ("%.1f MB" % (bytes / 1048576.0)) if bytes >= 1048576 else ("%.1f KB" % (bytes / 1024.0))
	return "%s (~%s tokens)" % [amount, ("%.1fk" % (tokens / 1000.0)) if tokens >= 1000 else str(tokens)]


static func _file_size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return 0
	var length := int(file.get_length()); file.close()
	return length


static func _name(id: String) -> String:
	return "Anon" if id == "player" else id.replace("_", " ").capitalize()


## Everything the page shows for one world, as data (also checked by tools/ai/test_ai_context.gd).
static func world_report(root: String, id: String) -> Dictionary:
	var folder := root.path_join(id)
	var report := {"id": id, "name": CATALOGUE.world_name(id), "story_bytes": _file_size(folder.path_join("story.db")),
		"context_bytes": _file_size(folder.path_join("context.json")), "save_bytes": 0, "saves": 0, "lines": 0,
		"ponies": [], "usage": {}, "error": ""}
	var saves := DirAccess.open(folder.path_join("saves"))
	if saves != null:
		for file: String in saves.get_files():
			if file.ends_with(".json") or file.ends_with(".story.db"):
				report.save_bytes += _file_size(folder.path_join("saves").path_join(file))
				if file.ends_with(".json"): report.saves += 1
	if not FileAccess.file_exists(folder.path_join("story.db")):
		report.error = "No story journal yet." if STORE.available() else "Story journal needs the SQLite addon."
		return report
	var store := STORE.new()
	if not store.open(folder.path_join("story.db")):
		report.error = "Story journal could not be opened: " + store.error
		return report
	report.lines = store.line_count()
	report.usage = store.usage_totals()
	for row: Dictionary in store.pony_totals():
		var pony := str(row.pony)
		if pony == "player": continue
		var summary: Dictionary = store.summary("pony:" + pony)
		report.ponies.append({"id": pony, "name": _name(pony), "lines": int(row.lines),
			"bytes": int(row.chars if row.chars != null else 0), "summary": str(summary.text)})
	store.close()
	return report


## Recent request outcomes from the dialogue client's status file.
static func status_lines(path: String, limit := 8) -> PackedStringArray:
	var doc: Dictionary = LLM.read_status(path)
	var lines: PackedStringArray = []
	var totals: Dictionary = doc.get("totals", {}) if doc.get("totals") is Dictionary else {}
	if totals.is_empty():
		lines.append("No dialogue requests recorded yet.")
		return lines
	lines.append("Since the record began: %d answered, %d refused, %d gave up after retries, %d failed, %d needed a retry." % [
		int(totals.get("ok", 0)) + int(totals.get("output_limit", 0)), int(totals.get("refusal", 0)), int(totals.get("transient", 0)),
		int(totals.get("fail", 0)), int(totals.get("retried", 0))])
	var rows: Array = doc.get("requests", []) if doc.get("requests") is Array else []
	for i in range(rows.size() - 1, maxi(-1, rows.size() - 1 - limit), -1):
		var row: Dictionary = rows[i] if rows[i] is Dictionary else {}
		var when := str(row.get("at", "")).substr(11, 5)
		var outcome := str(row.get("outcome", "?"))
		var words := {"ok": "answered", "output_limit": "answered (cut short)", "refusal": "REFUSED by the model's safety filter",
			"transient": "server trouble, gave up", "fail": "FAILED"}
		var line := "%s  %s, sent %s, %d %s, %.1f s" % [when, words.get(outcome, outcome), size_text(int(row.get("input_bytes", 0))),
			int(row.get("attempts", 1)), "try" if int(row.get("attempts", 1)) == 1 else "tries", float(row.get("seconds", 0.0))]
		if str(row.get("error", "")) != "" and outcome != "ok": line += "\n      " + str(row.error).left(140)
		lines.append(line)
	return lines


func _show() -> void:
	for child in _body.get_children(): child.queue_free()
	_label(_body, "Ponies remember everything: each world's story journal keeps every line and event in full, with no size limit. A request sends only a small, summarised slice of it, because every token is paid in full on every call.", 21)
	_label(_body, "What one request sends", 27)
	_label(_body, "Talking with one pony: her persona and situation, up to %s of her memories and %s of world facts, and the last %s of your chat with her." % [size_text(4200), size_text(1200), size_text(LLM.HISTORY_BYTES)], 21)
	_label(_body, "A group: the shared rules plus a slice per pony that shrinks with more ponies, kept under %s. Ponies chatting among themselves: under %s." % [size_text(PROMPTS.GROUP_PROMPT_BYTES), size_text(PROMPTS.AMBIENT_PROMPT_BYTES)], 21)
	_label(_body, "Recent requests", 27)
	for line: String in status_lines(status_path):
		var row := _label(_body, line, 20)
		if "REFUSED" in line or "FAILED" in line or "gave up" in line: row.add_theme_color_override("font_color", WARN)
	if worlds.is_empty():
		_world_button.text = "No worlds yet"
		_refresh_panel(); return
	var report := world_report(worlds_root, worlds[world_index])
	_world_button.text = "World: %s (%d of %d, press for next)" % [report.name, world_index + 1, worlds.size()]
	_label(_body, "This world", 27)
	_label(_body, "Story journal %s, %d lines. Recent events file %s. %d saves, %s." % [size_text(int(report.story_bytes)), int(report.lines),
		size_text(int(report.context_bytes)), int(report.saves), size_text(int(report.save_bytes))], 21)
	var usage: Dictionary = report.usage.get("all", {}) if report.usage.get("all") is Dictionary else {}
	if not usage.is_empty():
		var cached := int(usage.get("cached", 0))
		_label(_body, "Model use in this world: %d calls, about %dk tokens sent and %dk received.%s" % [int(usage.get("calls", 0)), int(usage.get("input", 0)) / 1000, int(usage.get("output", 0)) / 1000,
			(" %dk of the sent tokens were cache reads (billed at a discount)." % (cached / 1000)) if cached > 0 else ""], 21)
		for line: String in usage_lines(report.usage): _label(_body, line, 20)
	if str(report.error) != "":
		_label(_body, str(report.error), 21).add_theme_color_override("font_color", WARN)
	var ponies: Array = report.ponies
	if not ponies.is_empty():
		_label(_body, "What each pony remembers (biggest first)", 27)
	for pony: Dictionary in ponies.slice(0, PONY_ROWS):
		var line := "%s: %d lines, %s" % [pony.name, int(pony.lines), size_text(int(pony.bytes))]
		if str(pony.summary) != "": line += "; story summary %s: %s" % [size_text(str(pony.summary).to_utf8_buffer().size()), str(pony.summary).replace("\n", " ").left(140)]
		_label(_body, line, 20)
	if ponies.size() > PONY_ROWS:
		_label(_body, "...and %d more ponies." % (ponies.size() - PONY_ROWS), 20)
	_refresh_panel()


## What each kind of request cost in this world, biggest first, in words a player can act on
## (Settings → AI → AI usage turns the background ones off).
const USAGE_NAMES := {"dialogue_player": "Answering you", "dialogue": "Answering you", "group": "Answering you in a group",
	"group_ambient": "Ponies chatting among themselves (background)", "greeting": "Ponies coming over to talk (background)",
	"lull": "Filling a silence (background)", "farewell": "Saying goodbye", "story_purpose": "Story moments",
	"summary": "Memory diaries", "feedback_classifier": "Your feedback notes", "variety_revision": "Rewording a repeat",
	"group_variety_revision": "Rewording a repeat"}
static func usage_lines(totals: Dictionary) -> PackedStringArray:
	var grouped := {}
	for kind: String in totals:
		if kind == "all" or not totals[kind] is Dictionary: continue
		var base := kind.trim_suffix("_recovery").trim_suffix("_repair")
		var name: String = USAGE_NAMES.get(base, "Touch reactions" if base.begins_with("contact_") else ("Re-asking a cut-off reply" if kind != base else base.replace("_", " ")))
		if kind != base: name = "Re-asking a cut-off or broken reply"
		var row: Dictionary = grouped.get(name, {"calls": 0, "input": 0})
		row.calls += int(totals[kind].get("calls", 0)); row.input += int(totals[kind].get("input", 0))
		grouped[name] = row
	var names := grouped.keys()
	names.sort_custom(func(a, b): return int(grouped[a].input) > int(grouped[b].input))
	var lines := PackedStringArray()
	for name: String in names: lines.append("  %s: %d calls, about %dk tokens sent" % [name, int(grouped[name].calls), int(grouped[name].input) / 1000])
	return lines

func _label(parent: Control, text: String, font := 30) -> Label:
	var node := Label.new(); node.text = text; node.custom_minimum_size.x = 768
	node.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	node.add_theme_font_size_override("font_size", font); node.add_theme_color_override("font_color", TEXT)
	parent.add_child(node); return node


func _button(text: String) -> Button:
	var node := Button.new(); node.text = text; node.custom_minimum_size = Vector2(768, 56)
	node.add_theme_font_size_override("font_size", 25)
	node.focus_entered.connect(_refresh_panel)
	node.mouse_entered.connect(_refresh_panel); node.mouse_exited.connect(_refresh_panel)
	_list.add_child(node); return node


func _refresh_panel() -> void:
	if panel != null and panel.has_method("refresh"): panel.refresh()
