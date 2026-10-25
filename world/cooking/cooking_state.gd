extends RefCounted
## Cooking owns no second inventory: every portion remains one checked-out loan.
## All ownership changes pass the store's durable commit before visual changes.
const RECIPES := preload("res://world/cooking/cooking_recipes.gd")

static func valid_mark(mark: Variant) -> bool:
	if not mark is Dictionary or mark.size() != 3: return false
	if not mark.get("station") is String or mark.station.is_empty() or mark.station.length() > 160: return false
	if not mark.get("heat") is bool: return false
	var elapsed: Variant = mark.get("elapsed")
	return (elapsed is float or elapsed is int) and is_finite(float(elapsed)) and elapsed >= 0.0 and elapsed <= 25.0

static func valid_loans(loans: Dictionary) -> bool:
	var groups: Dictionary = {}
	for token: Variant in loans:
		var loan: Variant = loans[token]
		if not loan is Dictionary: return false
		if not loan.has("cooking"): continue
		if not valid_mark(loan.cooking) or not loan.has("world_transform") or loan.get("equipped", false) or loan.has("bites"): return false
		if not RECIPES.ingredient(str(loan.get("id", ""))): return false
		var key: String = loan.cooking.station
		if not groups.has(key): groups[key] = {"mark": loan.cooking, "ids": []}
		if groups[key].mark != loan.cooking: return false
		groups[key].ids.append(str(loan.id))
	for group: Dictionary in groups.values():
		var ids: Array[String] = []; ids.assign(group.ids)
		if RECIPES.candidates(ids).is_empty(): return false
		var recipe: Dictionary = RECIPES.complete(ids)
		if recipe.is_empty() and (group.mark.heat or group.mark.elapsed > 0.0): return false
		if not recipe.is_empty() and group.mark.elapsed > float(recipe.seconds): return false
	return true

static func tokens(store: RefCounted, station: String) -> Array[String]:
	var result: Array[String] = []
	for token: String in store.loans:
		var loan: Dictionary = store.loans[token]
		if loan.has("cooking") and str(loan.cooking.station) == station: result.append(token)
	result.sort()
	return result

static func ids(store: RefCounted, station: String) -> Array[String]:
	var result: Array[String] = []
	for token: String in tokens(store, station): result.append(str(store.loans[token].id))
	return result

static func mark(store: RefCounted, station: String) -> Dictionary:
	var active: Array[String] = tokens(store, station)
	return {} if active.is_empty() else store.loans[active[0]].cooking.duplicate()

static func can_deposit(store: RefCounted, token: String, station: String) -> bool:
	if station.is_empty() or station.length() > 160 or not store.loans.has(token): return false
	var loan: Dictionary = store.loans[token]
	if loan.has("cooking") or loan.has("bites") or not RECIPES.ingredient(str(loan.id)): return false
	var ingredients: Array[String] = ids(store, station)
	ingredients.append(str(loan.id))
	return not RECIPES.candidates(ingredients).is_empty()

static func deposit(store: RefCounted, token: String, station: String, pose: Transform3D) -> bool:
	if not pose.is_finite() or absf(pose.basis.determinant()) < .0001 or not can_deposit(store, token, station): return false
	var next: Array = store.slots.duplicate(true)
	var checked: Dictionary = store.loans.duplicate(true)
	if checked[token].get("equipped", false):
		store._remove_unit(next, int(checked[token].slot))
		checked[token].erase("equipped")
	checked[token].world_transform = store.encode_pose(pose)
	checked[token].cooking = {"station": station, "heat": false, "elapsed": 0.0}
	return store._commit(next, checked)

## A removed ingredient invalidates partial heat. Used by normal pickup/stow/consume paths.
static func detach(checked: Dictionary, token: String) -> void:
	if not checked.has(token) or not checked[token].has("cooking"): return
	var station: String = checked[token].cooking.station
	checked[token].erase("cooking")
	for loan: Dictionary in checked.values():
		if loan.has("cooking") and loan.cooking.station == station:
			loan.cooking.heat = false
			loan.cooking.elapsed = 0.0

static func save_heat(store: RefCounted, station: String, heat: bool, elapsed: float) -> bool:
	var active: Array[String] = tokens(store, station)
	var recipe: Dictionary = RECIPES.complete(ids(store, station))
	if active.is_empty() or recipe.is_empty() or not is_finite(elapsed) or elapsed < 0.0 or elapsed > float(recipe.seconds): return false
	var checked: Dictionary = store.loans.duplicate(true)
	for token: String in active: checked[token].cooking = {"station": station, "heat": heat, "elapsed": elapsed}
	return store._commit(store.slots, checked)

## The caller prepares the retained output body first; false leaves every input intact.
static func finish(store: RefCounted, station: String, output_token: String, pose: Transform3D) -> bool:
	var active: Array[String] = tokens(store, station)
	var recipe: Dictionary = RECIPES.complete(ids(store, station))
	var state: Dictionary = mark(store, station)
	if recipe.is_empty() or output_token not in active or not state.get("heat", false): return false
	if float(state.elapsed) < float(recipe.seconds) or not pose.is_finite() or absf(pose.basis.determinant()) < .0001: return false
	var checked: Dictionary = store.loans.duplicate(true)
	var retained: Dictionary = checked[output_token].duplicate(true)
	for token: String in active: checked.erase(token)
	retained.id = str(recipe.output)
	retained.erase("cooking")
	retained.world_transform = store.encode_pose(pose)
	checked[output_token] = retained
	return store._commit(store.slots, checked)
