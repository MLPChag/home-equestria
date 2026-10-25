extends RefCounted
## Optional player overrides. Missing sampling keys are omitted from requests.
## Token/timeout overrides replace game defaults; per-action safety budgets still apply.
const SPECS := {
	"temperature": ["Temperature", 0.0, 2.0, 0.05, 0.8],
	"top_p": ["Top P", 0.0, 1.0, 0.01, 1.0],
	"top_k": ["Top K", 1, 1000, 1, 40],
	"min_p": ["Min P", 0.0, 1.0, 0.01, 0.05],
	"frequency_penalty": ["Frequency penalty", -2.0, 2.0, 0.05, 0.0],
	"presence_penalty": ["Presence penalty", -2.0, 2.0, 0.05, 0.0],
	"seed": ["Seed", 0, 2147483647, 1, 0],
	"max_tokens": ["Output tokens", 1, 131072, 1, 220],
	"timeout": ["Timeout (seconds)", 5, 120, 1, 90],
}

static func validate(value: Variant) -> String:
	if not value is Dictionary: return "Generation overrides must be an object."
	for key: Variant in value:
		if not SPECS.has(key): return "Unknown generation option."
		var number: Variant = value[key]
		var spec: Array = SPECS[key]
		if not (number is float or number is int) or not is_finite(float(number)):
			return "%s must be a number." % spec[0]
		if float(number) < float(spec[1]) or float(number) > float(spec[2]):
			return "%s must be between %s and %s." % [spec[0], spec[1], spec[2]]
		if spec[3] is int and float(number) != floor(float(number)):
			return "%s must be a whole number." % spec[0]
	return ""

static func selected(section: Dictionary) -> Dictionary:
	if section.has("generation_overrides"):
		var value: Variant = section.generation_overrides
		return value.duplicate() if validate(value).is_empty() else {}
	# Preserve old configurations and presets which explicitly specified temperature.
	return {"temperature": section.temperature} if section.has("temperature") else {}
