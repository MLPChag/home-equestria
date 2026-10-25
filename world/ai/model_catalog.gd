extends Node
## Explicit, cancellable model discovery using the draft connection, never a paid completion.
signal completed(models: PackedStringArray, error: String)
const CONFIG := preload("res://world/ai/ai_config.gd")
var _request: HTTPRequest
var _connection: Dictionary = {}
var _models := PackedStringArray()
var _pages := 0
var _cursors: Array[String] = []

static func request_info(connection: Dictionary, cursor := "") -> Dictionary:
	var endpoint := str(connection.get("base_url", "")).strip_edges().rstrip("/")
	var headers := PackedStringArray(["Accept: application/json"])
	var key := str(connection.get("api_key", "")).strip_edges()
	if str(connection.get("provider", "openai")) == "anthropic":
		if not endpoint.ends_with("/v1"): endpoint += "/v1"
		headers.append("x-api-key: " + key)
		headers.append("anthropic-version: 2023-06-01")
		endpoint += "/models?limit=100"
		if not cursor.is_empty(): endpoint += "&after_id=" + cursor.uri_encode()
	else:
		endpoint += "/models"
		if not key.is_empty(): headers.append("Authorization: Bearer " + key)
	return {"url": endpoint, "headers": headers}

func fetch(connection: Dictionary) -> void:
	cancel()
	_connection = connection.duplicate(true); _models.clear(); _pages = 0; _cursors.clear()
	if not CONFIG.valid_url(str(connection.get("base_url", "")).strip_edges().rstrip("/")):
		completed.emit(PackedStringArray(), "Enter the provider's HTTP or HTTPS base URL first."); return
	_request = HTTPRequest.new(); _request.timeout = 20.0
	_request.body_size_limit = 8 * 1024 * 1024; _request.max_redirects = 0
	add_child(_request); _request.request_completed.connect(_received)
	_send()

func _send(cursor := "") -> void:
	_pages += 1
	var info := request_info(_connection, cursor)
	if _request.request(info.url, info.headers, HTTPClient.METHOD_GET) != OK:
		_finish("Could not start model fetch. Check the provider address.")

func _received(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		_finish("Model fetch failed: connection, timeout or response-size error. You can enter a model ID manually."); return
	if code != 200:
		_finish("Model fetch returned HTTP %d. Check the address and key, or enter a model ID manually." % code); return
	var parser := JSON.new()
	if parser.parse(body.get_string_from_utf8()) != OK or not parser.data is Dictionary or not parser.data.get("data") is Array:
		_finish("The provider did not return a model list. You can enter a model ID manually."); return
	var data: Dictionary = parser.data
	for entry: Variant in data.data:
		if entry is Dictionary and entry.get("id") is String and not entry.id.is_empty() and not _models.has(entry.id):
			_models.append(entry.id)
	if str(_connection.get("provider", "")) == "anthropic" and data.get("has_more", false) == true:
		var cursor: Variant = data.get("last_id", "")
		if not cursor is String or cursor.is_empty() or cursor in _cursors or _pages >= 20:
			_finish("Model list pagination could not finish. You can enter a model ID manually."); return
		_cursors.append(cursor); _send(cursor); return
	_finish("" if not _models.is_empty() else "No models were returned. You can enter a model ID manually.")

func _finish(error: String) -> void:
	_models.sort()
	var models := _models.duplicate()
	cancel()
	completed.emit(models, error)

func cancel() -> void:
	if is_instance_valid(_request):
		_request.cancel_request(); _request.queue_free(); _request = null
	_connection.clear()

func _exit_tree() -> void:
	cancel()
