extends RefCounted
## Shared rolling active-hour ledger, outside world checkpoints so loading cannot refund
## requests. Reserve before dispatch: failed, cancelled and repaired requests all count.
const LIMIT := 30
const WINDOW := 3600.0
const MAX_INPUT_BYTES := 32768
## Visible script budget: the ambient prompt (director_prompts.gd) asks for at most ten lines of at
## most 200 characters, about 90 tokens each with speaker id and tags, so 1536 leaves headroom.
## Never lower it: saved ledger rows above it make the ledger unreadable.
const MAX_OUTPUT_TOKENS := 1536
## Extra generation room for models that count private reasoning inside max_tokens (OpenAI-compatible
## endpoints; low effort is requested for Gemini). Not offered to the visible reply.
const REASONING_TOKENS := 2048
var elapsed := 0.0
var entries: Array = []
var path := ""
var writable := true

func open(file_path: String) -> bool:
	path = file_path
	if path.is_empty() or not FileAccess.file_exists(path): return true
	var file := FileAccess.open(path,FileAccess.READ)
	if file == null or file.get_length() > 65536: writable = false; return false
	var doc: Variant = JSON.parse_string(file.get_as_text())
	if not doc is Dictionary or doc.get("version") != 1 or not _number(doc.get("elapsed")) or not doc.get("entries") is Array or doc.entries.size() > LIMIT:
		writable = false; return false
	for row in doc.entries:
		if not row is Dictionary or not _number(row.get("at")) or not _number(row.get("input_bytes")) or not _number(row.get("output_tokens")) \
			or row.at > doc.elapsed or row.input_bytes > MAX_INPUT_BYTES or row.output_tokens > MAX_OUTPUT_TOKENS:
			writable = false; return false
	elapsed = float(doc.elapsed); entries = doc.entries
	return true

static func _number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value)) and value >= 0

func advance(seconds: float) -> void:
	if is_finite(seconds) and seconds > 0: elapsed += seconds
	entries = entries.filter(func(row): return elapsed - float(row.at) < WINDOW)

func available() -> bool: return writable and entries.size() < LIMIT

func reserve(input_bytes: int) -> bool:
	if not available() or input_bytes < 0 or input_bytes > MAX_INPUT_BYTES: return false
	entries.append({"at":elapsed,"input_bytes":input_bytes,"output_tokens":MAX_OUTPUT_TOKENS})
	return flush()

func flush() -> bool:
	if not writable: return false
	if path.is_empty(): return true
	writable = preload("res://world/ai/world_context.gd")._write(path,{"version":1,"elapsed":elapsed,"entries":entries}) == OK
	return writable

func statistics() -> Dictionary:
	var bytes := 0; var tokens := 0
	for row in entries: bytes += int(row.input_bytes); tokens += int(row.output_tokens)
	return {"requests":entries.size(),"limit":LIMIT,"input_bytes":bytes,"reserved_output_tokens":tokens,
		"next_request_seconds":maxf(0,WINDOW-elapsed+float(entries[0].at)) if not available() and not entries.is_empty() else 0.0,"writable":writable}
