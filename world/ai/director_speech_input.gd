extends RefCounted
const CAPTURE := preload("res://world/ai/ai_capture.gd")
const VOCABULARY := preload("res://world/ai/speech_vocabulary.gd")
## Player speech input: microphone settings, speech-to-text requests and results, typed feedback notes, push-to-talk.
## Split out of conversation_director.gd (2026-10-13); the host keeps forwards for every name reachable
## from elsewhere, so callers did not change. `host` is the owning conversation_director node; shared state stays there.


var host: Node


func _init(owner_node: Node) -> void:
	host = owner_node


## Speech input fields from the stt section. Speech-to-text provider "off" keeps the mic
## closed (typed chat still works).
func _configure_speech(stt: Dictionary) -> void:
	host.speech.mode = "off" if str(stt.get("provider", "local")) == "off" else String(stt.get("mode", "ptt"))
	host.speech.push_to_talk_action = String(stt.get("push_to_talk_action", "voice_talk"))
	host.speech.vr_button = String(stt.get("vr_push_to_talk_button", "by_button"))
	host.speech.threshold = float(stt.get("vad_threshold", 0.012))
	host.speech.hangover = float(stt.get("vad_hangover", 0.75))
	host.speech.min_speech = float(stt.get("vad_min_speech", 0.35))
	host.speech.max_speech = float(stt.get("vad_max_speech", 18.0))
	host.speech.debug = host.debug
	host.speech.input_device = String(stt.get("input_device", ""))
	var xr_now := XRServer.primary_interface != null and XRServer.primary_interface.is_initialized()
	var source: Variant = stt.get("mic_source")
	host.speech.mic_source = String(source) if source is String else ("wivrn.source" if xr_now and OS.get_name()=="Linux" else "")


func _on_utterance(wav: PackedByteArray, seconds: float, is_feedback := false) -> void:
	if host.state != "idle": host.interrupt()
	host.state = "transcribing"
	host._transcribing_feedback = is_feedback
	host.speech.set_muted(true)
	host.hud.set_state("feedback" if is_feedback else "thinking", "" if is_feedback else "transcribing %.1f s..." % seconds)
	if host.debug:
		var dump := FileAccess.open("user://stt_last.wav", FileAccess.WRITE)
		if dump != null:
			dump.store_buffer(wav)
			dump.close()
	var stt: Dictionary = host.config.section("stt")
	_capture("request", {"provider": str(stt.get("provider", "local")), "model": str(stt.get("model", "")), "audio_bytes": wav.size(), "seconds": seconds})
	var err := OK
	# Names near Anon and the core cast, so the recognizer spells them (playtester: "Minuet").
	var vocabulary: String = VOCABULARY.prompt(host.characters, host.player_head, str(host.config.get_value("player_name", "")))
	if str(stt.get("provider", "local")) == "builtin":
		var generation: int = host._turn_id
		var heard := func(words: String, failure: String):
			if generation != host._turn_id or host.state != "transcribing": return
			if not failure.is_empty():
				_capture("error", {"error": failure})
				host._fail(failure)
				return
			_on_stt_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), JSON.stringify({"text": words}).to_utf8_buffer())
		var error: String = host._builtin_stt.transcribe(wav, heard, vocabulary)
		if not error.is_empty():
			_capture("error", {"error": error})
			host._fail(error)
		return
	if str(stt.get("provider", "local")) == "openai":
		var request := transcription_request(stt, wav, vocabulary)
		err = host._stt.request_raw(request.url, request.headers, HTTPClient.METHOD_POST, request.body)
	else:
		# tools/ai/stt_server.py reads the names as Whisper's initial prompt; other servers ignore the header.
		err = host._stt.request_raw(String(stt.get("url", "")),
			PackedStringArray(["Content-Type: audio/wav", "X-Stt-Prompt: " + vocabulary.uri_encode()]), HTTPClient.METHOD_POST, wav)
	if err != OK:
		_capture("error", {"error": "request error %d" % err})
		host._fail("stt request error %d" % err)


## OpenAI-compatible Whisper API: multipart/form-data POST to {base_url}/audio/transcriptions
## with the utterance as `file` and the `model`; the JSON reply carries `text`. A non-empty
## `prompt` goes as the API's `prompt` field: names the recognizer should spell.
static func transcription_request(stt: Dictionary, wav: PackedByteArray, prompt := "") -> Dictionary:
	var boundary := "----HomeEquestria%d" % Time.get_ticks_usec()
	var body := PackedByteArray()
	body.append_array(("--%s\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n%s\r\n" % [boundary, str(stt.get("model", "whisper-1"))]).to_utf8_buffer())
	if not prompt.is_empty():
		body.append_array(("--%s\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\n%s\r\n" % [boundary, prompt]).to_utf8_buffer())
	body.append_array(("--%s\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n" % boundary).to_utf8_buffer())
	body.append_array(("--%s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"utterance.wav\"\r\nContent-Type: audio/wav\r\n\r\n" % boundary).to_utf8_buffer())
	body.append_array(wav)
	body.append_array(("\r\n--%s--\r\n" % boundary).to_utf8_buffer())
	var headers := PackedStringArray(["Content-Type: multipart/form-data; boundary=" + boundary])
	var key := str(stt.get("api_key", ""))
	if key != "": headers.append("Authorization: Bearer " + key)
	return {"url": str(stt.get("base_url", "")).rstrip("/") + "/audio/transcriptions", "headers": headers, "body": body}


func _on_stt_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_capture("response", {"result": result, "http_status": code, "body": body.get_string_from_utf8()})
	if host.state != "transcribing":
		return
	host.state = "idle"
	var is_feedback: bool = host._transcribing_feedback
	host._transcribing_feedback = false
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		var hint := "check Settings → Dialogue & microphone" if str(host.config.get_value("stt/provider", "local")) == "openai" else "start tools/ai/stt_server.sh"
		host._fail("speech-to-text failed (%d/%d%s); %s" % [result, code, (": " + body.get_string_from_utf8().left(120)) if code >= 400 else "", hint])
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	var text := String(parsed.get("text", "")) if parsed is Dictionary else ""
	if host.debug: print("[ai] heard: ", text)
	if text.strip_edges() == "":
		host.speech.set_muted(false)
		host.hud.set_state(host.speech.state, "")
		return
	if is_feedback:
		handle_feedback(text)
	else:
		# "Minuet" -> "Minuette" before routing, so the right pony is addressed and nobody corrects his spelling.
		var respelled: String = VOCABULARY.correct(text)
		if respelled != text: print("[ai] respelled heard names: %s -> %s" % [text.left(80), respelled.left(80)])
		host.handle_text(respelled)


func handle_feedback(text: String) -> void:
	host.feedback_input.submit(text)

func _on_speech_state(value: String) -> void:
	if value == "hearing" and (host.state != "idle" or host.group.active()): host.interrupt()
	if host.state == "idle":
		host.hud.set_state("feedback" if value == "hearing" and host.speech.feedback_mode else value, host.hud.detail if value == "listening" else "")


## Button down takes the floor immediately, before any microphone samples arrive.
func _on_talk_pressed() -> void:
	host.interrupt()


func _capture(event: String, details: Dictionary) -> void:
	details["turn"] = host._turn_id
	CAPTURE.record("stt", event, details, str(host.config.get_value("stt/api_key", "")))
