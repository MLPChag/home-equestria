extends RefCounted
## Every place a pony can be asked to go to by name: houses (named after who lives
## there), labelled landmarks, town buildings, painted hot spots and world regions.
## Ids are stable strings the LLM can repeat; `resolve()` turns one into a point.
const HOUSE_KIND := "house"
const TOWN_BUILDINGS := {"town_hall": "Ponyville Town Hall", "sugarcube_corner": "Sugarcube Corner"}
## The river bridges. Their scenery label is the shared word "bridge", which the build step
## leaves out of ai_observable, so they are listed here by node name (tools/rnl_scenery/plan.py).
const BRIDGES := {"bridge_01": "South bridge", "bridge_02": "Market road bridge", "bridge_03": "East bridge"}
const MARKET_STALL := "Town/Market/kiosk_01_02"
static var _cache: Array = []
static var _stamp := -INF

static func _pretty(id: String) -> String:
	return id.replace("_", " ").capitalize()

## Cached scene anchors must still belong to this live tree. Regions have no anchor.
static func _live_entry(entry: Dictionary, tree: SceneTree) -> bool:
	if not entry.has("node"): return true
	var node: Node = entry.node if is_instance_valid(entry.node) else null
	return node != null and node.is_inside_tree() and node.get_tree() == tree and not node.is_queued_for_deletion()

## All known places, rebuilt at most every 10 s; unloaded anchors expire immediately.
static func entries(tree: SceneTree) -> Array:
	var now := Time.get_ticks_msec() * .001
	if now - _stamp < 10.0 and not _cache.is_empty():
		_cache = _cache.filter(func(e): return _live_entry(e, tree))
		return _cache
	_stamp = now
	var out: Array = []
	var population: Node = tree.get_first_node_in_group("pony_populations")
	for home: Node3D in tree.get_nodes_in_group("house_interiors"):
		if not home.is_inside_tree(): continue
		var names: Array = []
		if population != null and population.has_method("residents_of"):
			for id in population.residents_of(home.place_id()): names.append(_pretty(str(id)).split(" ")[0])
		# The player's own house (arrival_story.gd home, or a partner's he shares) is Anon's.
		var player_home := str(home.get_meta("reserved_for", "")) == "player" or bool(home.get_meta("shared_player_home", false))
		if player_home: names.push_front("Anon")
		var label: String = home.label() if names.is_empty() else " and ".join(names) + "'s house"
		# "alt" keeps the building's own name (Golden Oak Library) for free-form names.
		out.append({"id": home.place_id(), "label": label, "alt": home.label() + (" player home" if player_home else ""), "kind": HOUSE_KIND, "position": home.center(), "node": home, "player_home": player_home})
	var seen := {}
	for node: Node in tree.get_nodes_in_group("ai_observable"):
		if not node is Node3D or not node.is_inside_tree(): continue
		var id := str(node.get_meta("ai_id", ""))
		var label := str(node.get_meta("ai_label", ""))
		if id.is_empty() or label.is_empty(): continue
		seen[label] = int(seen.get(label, 0)) + 1
		out.append({"id": "landmark:" + id, "label": label, "kind": "landmark", "position": (node as Node3D).global_position, "node": node})
	# Generic repeated labels (benches, lamps, fair tents) are not destinations.
	out = out.filter(func(e): return e.kind != "landmark" or int(seen.get(e.label, 0)) <= 2)
	for town: Node in tree.get_nodes_in_group("town_roots"):
		for key in TOWN_BUILDINGS:
			var building := town.get_node_or_null(key) as Node3D
			if building != null:
				var interior: Node3D = building.get_node_or_null("HouseInterior") if key == "sugarcube_corner" else null
				var destination: Vector3 = interior.center() if interior != null else building.global_position
				var anchor := building.get_node_or_null("NavigationAnchor") as Node3D
				if interior == null and anchor != null: destination = anchor.global_position
				out.append({"id": "landmark:" + key, "label": TOWN_BUILDINGS[key], "kind": "landmark", "position": destination, "node": building,
					"interior_goal": interior != null, "town_destination": true})
		var scenery := town.get_node_or_null("RNLScenery")
		if scenery != null:
			var market := scenery.get_node_or_null(MARKET_STALL) as Node3D
			if market != null and not market.is_queued_for_deletion():
				# Meet in the customer aisle, not inside a counter or tent.
				out.append({"id":"landmark:ponyville_market", "label":"Ponyville Market", "kind":"landmark",
					"position":market.to_global(Vector3(0, 0, -4)), "node":market, "open_ground":true})
			for key in BRIDGES:
				var bridge := scenery.get_node_or_null("Bridges/" + key) as Node3D
				if bridge != null: out.append({"id": "landmark:" + key, "label": BRIDGES[key], "kind": "landmark", "position": bridge.global_position, "node": bridge})
	# The hot-air balloon (world/vehicles/balloon/balloon.gd) while it rests on the ground: meet in
	# front of its ramp. Aloft it is no destination (dev 2026-10-15: Dash proposed the balloon and
	# had no place to walk to).
	for balloon: Node in tree.get_nodes_in_group("hot_air_balloons"):
		if balloon is Node3D and balloon.is_inside_tree() and bool(balloon.get("landed")):
			out.append({"id": "landmark:balloon", "label": "Hot-air balloon", "kind": "landmark",
				"position": (balloon as Node3D).to_global(Vector3(0, 0, -3.6)), "node": balloon, "open_ground": true})
			break
	for r: Dictionary in WorldLayout.regions():
		if int(r.get("phase", 0)) >= 7: continue
		var spawn := WorldLayout.spawn(str(r.id))
		var at := Vector3(spawn.x, WorldLayout.center(str(r.id)).y, spawn.y)
		out.append({"id": "region:" + str(r.id), "label": str(r.get("name", r.id)), "kind": "region:" + str(r.get("kind", "")), "position": at})
	_cache = out.filter(func(e): return _live_entry(e, tree))
	return _cache

static func find(tree: SceneTree, id: String) -> Dictionary:
	for e: Dictionary in entries(tree):
		if e.id == id: return e
	return {}

## Words of a place name, lower case, without punctuation, possessives or filler words.
const NAME_FILLER := ["the", "a", "an", "to", "at", "of", "in", "on", "by", "near", "my", "your", "our", "her", "his", "s", "place", "landmark", "region"]
static func name_words(text: String) -> PackedStringArray:
	var clean := ""
	for c: String in text.to_lower().replace("'s", "").replace("’s", ""):
		clean += c if (c >= "a" and c <= "z") or (c >= "0" and c <= "9") else " "
	var words := PackedStringArray()
	for word: String in clean.split(" ", false):
		if word not in NAME_FILLER: words.append(word)
	return words

## The listed place id a free-form name means, or "" (dev 2026-10-15: models write
## [go_to: Sugarcube Corner] or [go_to: balloon] instead of the exact id, and the tag was dropped
## while she still said "let's go"). `labels` maps id -> label text. A word few places share
## ("balloon") outweighs a common one ("ponyville"); at least half the name's words must match
## unless the whole name matches run together ("sugar cube corner").
static func match_name(raw: String, ids: Array, labels: Dictionary) -> String:
	var wanted := raw.strip_edges()
	if wanted in ids: return wanted
	var lowered := wanted.to_lower().replace(" ", "_")
	for prefix: String in ["", "landmark:", "region:"]:
		if prefix + lowered in ids: return prefix + lowered
	var words := name_words(lowered.trim_prefix("landmark:").trim_prefix("region:").replace("_", " "))
	if words.is_empty(): return ""
	var compact := "".join(words)
	var bags := {}
	var shared := {}
	for id: Variant in ids:
		var key := str(id)
		var text := str(labels.get(key, ""))
		# House ids are coordinates; their words come from the label only.
		if not key.begins_with(HOUSE_KIND + ":"): text += " " + key.get_slice(":", key.get_slice_count(":") - 1).replace("_", " ")
		var bag := name_words(text)
		bags[key] = bag
		var seen := {}
		for word: String in bag:
			if seen.has(word): continue
			seen[word] = true
			shared[word] = int(shared.get(word, 0)) + 1
	var best := ""
	var best_score := 0.0
	for key: String in bags:
		var bag: PackedStringArray = bags[key]
		var score := 0.0
		var matched := 0
		for word: String in words:
			if bag.has(word):
				score += 1.0 / float(shared.get(word, 1)); matched += 1
		var label_compact := "".join(name_words(str(labels.get(key, ""))))
		if not label_compact.is_empty() and compact == label_compact: score += 10.0
		elif matched * 2 < words.size():
			if compact.length() < 5 or not (compact in "".join(bag)): continue
			score += .5
		if score <= 0.0: continue
		# Ties go to a landmark over a house named after its residents.
		if not key.begins_with(HOUSE_KIND + ":"): score += .01
		if score > best_score: best = key; best_score = score
	return best

## A standable point for the place. Houses go inside (house travel handles the door);
## landmarks and regions give their position, height from the terrain when unknown.
static func resolve(tree: SceneTree, id: String) -> Vector3:
	var e := find(tree, id)
	if e.is_empty(): return Vector3.INF
	if e.kind == HOUSE_KIND and is_instance_valid(e.get("node")): return e.node.center()
	var at: Vector3 = e.position
	if is_instance_valid(WorldTerrain.instance) and (e.kind.begins_with("region") or not e.has("node") or e.get("open_ground", false)):
		var h: float = WorldTerrain.instance.height_at(at)
		if is_finite(h): at.y = h
	return at

## Closest places first, plus every region; each line is "id = label (kind, ~N m)".
static func prompt_lines(tree: SceneTree, from: Vector3, local_limit := 30) -> Array:
	var local: Array = []
	var regions: Array = []
	var home_lines: Array = []
	for e: Dictionary in entries(tree):
		var distance := Vector2(e.position.x - from.x, e.position.z - from.z).length()
		var line := "%s = %s (%s, ~%d m)" % [e.id, e.label, e.kind, roundi(distance)]
		if e.kind.begins_with("region"): regions.append([distance, line])
		else: local.append([distance, line, bool(e.get("town_destination", false)) and distance <= 500.0])
		if bool(e.get("player_home", false)): home_lines.append(line)
	local.sort_custom(func(a, b): return a[0] < b[0])
	regions.sort_custom(func(a, b): return a[0] < b[0])
	var selected: Array = local.slice(0, maxi(0, local_limit))
	# A dense ring of houses must not hide a named town destination from a guide.
	# Reserve its place within the existing budget, replacing the farthest ordinary
	# entry; keep the final list in distance order and preserve actual home names.
	for entry: Array in local:
		if not entry[2] or entry in selected: continue
		for index in range(selected.size() - 1, -1, -1):
			if not selected[index][2]:
				selected[index] = entry
				break
	selected.sort_custom(func(a, b): return a[0] < b[0])
	var near: Array = selected.map(func(x): return x[1])
	# Anon's own house is always listed, however far: "go to Anon's house" must name a real place.
	for line: String in home_lines:
		if line not in near: near.append(line)
	return near + regions.slice(0, local_limit * 2).map(func(x): return x[1])
