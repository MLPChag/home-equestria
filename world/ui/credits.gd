extends RefCounted
## Attribution verified against the authors' releases on 2026-10-13:
## https://ponysfm.com/rnl-ponyville-sfm-gmod
## https://steamcommunity.com/sharedfiles/filedetails/?id=3756728897
## Suroguner's schoolhouse contribution is listed on the Workshop release.
const RNL_PONYVILLE := [
	{"name": "Rhineeheart", "role": "Lead developer, concept and design\nModelling, textures and map logic"},
	{"name": "Snazzy_summary", "role": "Development consultant\nModelling, textures and map logic"},
	{"name": "LessMAN", "role": "Modelling, optimization and textures\nTools and production workflow"},
	{"name": "Suroguner", "role": "Schoolhouse model"},
]

const NOTICES := "res://world/ui/credits/notices.json"
static var _data: Dictionary = {}
static var _engine: Array[Dictionary] = []


## All notice text is local runtime data. Engine notices come from this actual binary.
static func entries(section: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if section == "engine":
		if _engine.is_empty():
			_engine.append({"title": "Godot Engine", "text": Engine.get_license_text()})
			for component: Dictionary in Engine.get_copyright_info():
				var lines := PackedStringArray()
				for part: Dictionary in component.get("parts", []):
					lines.append("\n".join(part.get("copyright", [])))
					lines.append("Licence: " + str(part.get("license", "")))
					lines.append("Files: " + ", ".join(part.get("files", [])))
				_engine.append({"title": str(component.get("name", "Component")), "text": "\n\n".join(lines)})
		return _engine
	if section == "terms":
		var licenses: Dictionary = Engine.get_license_info()
		var names: Array = licenses.keys(); names.sort()
		for name: String in names:
			result.append({"title": name, "text": str(licenses[name])})
		return result
	if _data.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(NOTICES))
		if parsed is Dictionary: _data = parsed
	if section == "assets":
		var names := PackedStringArray(["Original map and assets"])
		for entry: Dictionary in RNL_PONYVILLE:
			names.append(str(entry.name) + "\n" + str(entry.role))
		result.append({"title": "RnL Ponyville", "text": "\n\n".join(names)})
	for entry: Variant in _data.get(section, []):
		if entry is Dictionary and entry.get("title") is String and entry.get("text") is String:
			result.append(entry)
	if result.is_empty():
		result.append({"title": "Notices unavailable", "text": "The installed credits data could not be read."})
	return result
