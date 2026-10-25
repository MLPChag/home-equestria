extends RefCounted
## Food definitions share canonical identities with inventory, shops and world pickups.
## Retired foods (world/food/retired_definitions.json, dev 2026-10-14 "standardize food items":
## ingredients and odd one-offs nobody buys) stay valid ids so old saves load, but are never
## listed or sold; inventory_store.gd turns them into their pre-made replacement on load
## (world/items/retired_items.gd).
const IDENTITY := preload("res://world/inventory/item_identity.gd")
const VISUAL: Script = preload("res://world/food/food_item.gd")
const RETIRED_PATH := "res://world/food/retired_definitions.json"
static var _definitions: Dictionary = {}
static var _retired: Dictionary = {}
static var _scenes: Dictionary = {}
static var _icons: Dictionary = {}

static func definitions() -> Dictionary:
	if _definitions.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://world/food/definitions.json"))
		if parsed is Dictionary:
			_definitions = parsed
	return _definitions

static func retired_definitions() -> Dictionary:
	if _retired.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(RETIRED_PATH))
		if parsed is Dictionary and (parsed as Dictionary).get("items") is Dictionary:
			_retired = parsed.items
	return _retired

static func _entry(slug_name: String) -> Dictionary:
	var entry: Dictionary = definitions().get(slug_name, {})
	return entry if not entry.is_empty() else retired_definitions().get(slug_name, {})

## A retired food: loads from old saves, never sold or listed.
static func retired(id: String) -> bool:
	id = IDENTITY.canonical(id)
	return has(id) and not definitions().has(slug(id))

## The pre-made food a retired one becomes in an old save ("" for current foods).
static func replacement(id: String) -> String:
	if not retired(id): return ""
	var entry: Dictionary = retired_definitions()[slug(id)]
	return str(entry.get("empty_becomes" if is_empty_container(id) else "becomes", ""))

## Current foods only (retired ones are not listed).
static func ids() -> Array[String]:
	var result: Array[String] = []
	for slug: String in definitions():
		result.append(IDENTITY.canonical("food:" + slug))
	return result

static func slug(id: String) -> String:
	return IDENTITY.food_slug(id)

static func has(id: String) -> bool:
	id = IDENTITY.canonical(id)
	if id not in ["apple", "carrot"] and (id.count(":") != 1 or not id.get_slice(":", 0) in ["food", "food-empty"]):
		return false
	var entry: Dictionary = _entry(slug(id))
	return not entry.is_empty() and (not is_empty_container(id) or not str(entry.get("container", "")).is_empty())

static func is_empty_container(id: String) -> bool:
	return id.begins_with("food-empty:")

static func definition(id: String) -> Dictionary:
	if not has(id):
		return {}
	var entry: Dictionary = _entry(slug(id)).duplicate(true)
	entry.description = str(entry.get("description", "")).replace("hold right-click on desktop", "hold left-click on desktop")
	if IDENTITY.canonical(id) in ["apple", "carrot"]:
		entry.stack = 64 # Existing full legacy stacks remain valid.
	entry["food"] = true
	if is_empty_container(id):
		entry.name = entry.container
		entry.description = "An empty container. Keep it, set it down, or put it away."
		entry.consume = false
		entry.mass = 0.08
		entry.price_bits = 0
	return entry

static func price_bits(id: String) -> int:
	return int(definition(id).get("price_bits", 0))

static func scene(id: String) -> PackedScene:
	id = IDENTITY.canonical(id)
	if not has(id):
		return null
	if not _scenes.has(id):
		var visual: Node3D = VISUAL.new()
		visual.name = "FoodItem"
		visual.food_id = id
		# A food may reuse another food's model (buttered corn shows the corn cob).
		visual.model_slug = str(definition(id).get("model", ""))
		var packed: PackedScene = PackedScene.new()
		var result: Error = packed.pack(visual)
		visual.free()
		if result != OK:
			return null
		_scenes[id] = packed
	return _scenes[id]

static func can_consume(id: String) -> bool:
	return bool(definition(id).get("consume", false))

static func empty_id(id: String) -> String:
	return "food-empty:" + slug(id) if has(id) and not str(definition(id).get("container", "")).is_empty() else ""

static func icon(id: String) -> Texture2D:
	id = IDENTITY.canonical(id)
	if not has(id):
		return null
	if _icons.has(id):
		return _icons[id]
	var entry: Dictionary = definition(id)
	var colors: Dictionary = {"ingredients":"7ca954", "meals":"cf985a", "sweets":"d88bb4", "apple-family":"b95045", "regional":"87bbcd"}
	var color: String = str(colors.get(entry.category, "aab5a2"))
	var initials: String = ""
	for word: String in str(entry.name).split(" ", false):
		initials += word.left(1)
	initials = initials.left(3)
	# Only an existing inventory icon; no new food menu or world interface.
	var svg: String = '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><rect x="5" y="5" width="54" height="54" rx="15" fill="#%s"/><path d="M12 36 Q32 58 52 36Z" fill="#eee3ce"/><text x="32" y="28" text-anchor="middle" font-size="15" font-family="sans-serif" fill="#202720">%s</text></svg>' % [color, initials]
	var image: Image = Image.new()
	if image.load_svg_from_string(svg) != OK:
		return null
	var texture: ImageTexture = ImageTexture.create_from_image(image)
	_icons[id] = texture
	return texture
