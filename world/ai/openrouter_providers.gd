extends Node
## Explicit, cancellable list of the OpenRouter providers (endpoints) serving the draft model, from
## {base_url}/models/<author>/<slug>/endpoints; never a paid completion. Each entry is
## {"tag": the routing slug sent as provider.order, "label": what the settings page shows}.
signal completed(endpoints: Array, error: String)
const CONFIG := preload("res://world/ai/ai_config.gd")
const MODEL_ID := "^[A-Za-z0-9._~-]+/[A-Za-z0-9._~:-]+$"
var _request: HTTPRequest

## {} when the model is not an OpenRouter "author/slug" ID (a ":free" style variant is part of the slug).
static func request_info(connection: Dictionary) -> Dictionary:
	var model := str(connection.get("model", "")).strip_edges()
	var pattern := RegEx.new(); pattern.compile(MODEL_ID)
	if pattern.search(model) == null: return {}
	for part in model.split("/"):
		if part in [".", ".."]: return {}
	var headers := PackedStringArray(["Accept: application/json"])
	var key := str(connection.get("api_key", "")).strip_edges()
	if not key.is_empty(): headers.append("Authorization: Bearer " + key)
	var endpoint := str(connection.get("base_url", "")).strip_edges().rstrip("/")
	return {"url": endpoint + "/models/" + model + "/endpoints", "headers": headers}

## "DeepInfra · fp8 · 131K context · $0.10 / $0.32 per M tokens  (deepinfra/turbo)"
static func describe(entry: Dictionary) -> String:
	var tag := str(entry.get("tag", ""))
	var provider_name: Variant = entry.get("provider_name")
	var parts := PackedStringArray([provider_name if provider_name is String and not provider_name.is_empty() else tag])
	var quantization: Variant = entry.get("quantization")
	if quantization is String and quantization not in ["", "unknown"]: parts.append(quantization)
	var context: Variant = entry.get("context_length")
	if (context is float or context is int) and float(context) > 0.0:
		var tokens := float(context)
		parts.append(("%dM context" % roundi(tokens / 1e6)) if tokens >= 1e6 else ("%dK context" % roundi(tokens / 1000.0)))
	var price := _price(entry.get("pricing"))
	if not price.is_empty(): parts.append(price)
	return " · ".join(parts) + "  (" + tag + ")"

static func _price(pricing: Variant) -> String:
	if not pricing is Dictionary: return ""
	var prompt := str(pricing.get("prompt", "")); var completion := str(pricing.get("completion", ""))
	if not prompt.is_valid_float() or not completion.is_valid_float() or float(prompt) < 0.0 or float(completion) < 0.0: return ""
	if float(prompt) == 0.0 and float(completion) == 0.0: return "free"
	return "$%.2f / $%.2f per M tokens" % [float(prompt) * 1e6, float(completion) * 1e6]

func fetch(connection: Dictionary) -> void:
	cancel()
	if not CONFIG.is_openrouter(str(connection.get("base_url", ""))) or not CONFIG.valid_url(str(connection.get("base_url", "")).strip_edges().rstrip("/")):
		completed.emit([], "Providers can be listed for OpenRouter's base URL only."); return
	var info := request_info(connection)
	if info.is_empty():
		completed.emit([], "Enter an OpenRouter model ID such as anthropic/claude-sonnet-4.5 first."); return
	_request = HTTPRequest.new(); _request.timeout = 20.0
	_request.body_size_limit = 8 * 1024 * 1024; _request.max_redirects = 0
	add_child(_request); _request.request_completed.connect(_received)
	if _request.request(info.url, info.headers, HTTPClient.METHOD_GET) != OK:
		_finish([], "Could not start the provider fetch. Check the provider address.")

func _received(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		_finish([], "Provider fetch failed: connection, timeout or response-size error. Automatic routing still works."); return
	if code == 404:
		_finish([], "OpenRouter does not know this model ID. Check the model, then fetch providers again."); return
	if code != 200:
		_finish([], "Provider fetch returned HTTP %d. Check the key and model; automatic routing still works." % code); return
	var parser := JSON.new()
	if parser.parse(body.get_string_from_utf8()) != OK or not parser.data is Dictionary or not parser.data.get("data") is Dictionary \
			or not parser.data.data.get("endpoints") is Array:
		_finish([], "OpenRouter did not return a provider list. Automatic routing still works."); return
	var endpoints: Array = []
	var seen: Dictionary = {}
	for entry: Variant in parser.data.data.endpoints:
		if entry is Dictionary and entry.get("tag") is String and not entry.tag.strip_edges().is_empty() and not seen.has(entry.tag):
			seen[entry.tag] = true
			endpoints.append({"tag": entry.tag, "label": describe(entry)})
	_finish(endpoints, "" if not endpoints.is_empty() else "OpenRouter listed no providers for this model.")

func _finish(endpoints: Array, error: String) -> void:
	cancel()
	completed.emit(endpoints, error)

func cancel() -> void:
	if is_instance_valid(_request):
		_request.cancel_request(); _request.queue_free(); _request = null

func _exit_tree() -> void:
	cancel()
