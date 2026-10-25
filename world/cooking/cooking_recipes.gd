extends RefCounted
## Portions use the same canonical identities as shops, held food and harvested produce.
const RECIPES: Array[Dictionary] = [
	{"id": "carrot_pancakes", "name": "Carrot pancakes", "inputs": ["food:flour", "food:egg", "food:butter", "carrot"], "output": "food:sweet-carrot-pancakes", "seconds": 20.0},
	{"id": "vegetable_noodles", "name": "Vegetable noodle soup", "inputs": ["food:flour", "carrot", "food:mushroom", "food:spices"], "output": "food:spicy-flat-noodle-soup", "seconds": 25.0},
]

static func candidates(ids: Array[String]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if ids.size() > 4: return result
	for recipe: Dictionary in RECIPES:
		var remaining: Array = recipe.inputs.duplicate()
		var fits := true
		for id: String in ids:
			var index := remaining.find(id)
			if index < 0:
				fits = false
				break
			remaining.remove_at(index)
		if fits: result.append(recipe)
	return result

static func complete(ids: Array[String]) -> Dictionary:
	for recipe: Dictionary in candidates(ids):
		if recipe.inputs.size() == ids.size(): return recipe
	return {}

static func ingredient(id: String) -> bool:
	for recipe: Dictionary in RECIPES:
		if id in recipe.inputs: return true
	return false
