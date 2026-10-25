extends RefCounted
## Compatibility names resolve at every item boundary. Keep aliases readable in old saves.
const ALIASES := {"food:red-apple": "apple", "food:carrot": "carrot"}

static func canonical(id: String) -> String:
	return str(ALIASES.get(id, id))

static func food_slug(id: String) -> String:
	match canonical(id):
		"apple": return "red-apple"
		"carrot": return "carrot"
	return id.get_slice(":", 1)
