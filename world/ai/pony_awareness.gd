extends RefCounted
## Bounded semantic perception from game state, never from guessed mesh names.
const LAYOUT := preload("res://world/world_layout.gd")
const VIEW_RANGE := 24.0
const HEARING_RANGE := 12.0
const MAX_PEERS := 12
const MAX_OBJECTS := 6
const EVENT_LIFETIME := 20.0
## Weather kinds (weather.gd) that reach dialogue; windy and cloudy stay out of it.
const NOTICED_WEATHER := ["mist", "fog", "drizzle", "sunshower", "rain", "storm", "hail", "snow", "gathering", "blizzard"]
const PLACES := preload("res://world/navigation/place_directory.gd")
## Pegasus-only cloud floors (the Cloudominium).
const CLOUD_LAYER := 1 << 18
var _observations: Dictionary = {}
var last_ray_count := 0
var held_items: Callable


func forget(id: String) -> void:
	_observations.erase(id)


static func point(node: Node3D) -> Vector3:
	return node.listen_point() if node.has_method("listen_point") else node.global_position


static func forward(node: Node3D) -> Vector3:
	if node.has_method("awareness_forward"): return node.awareness_forward()
	return -node.global_basis.z.normalized()


func clear_path(observer: Node3D, target: Vector3, target_node: Node = null) -> bool:
	var origin := point(observer)
	if origin.distance_squared_to(target) < 0.0001: return true
	var excluded: Array[RID] = []
	if observer is CollisionObject3D: excluded.append(observer.get_rid())
	var query := PhysicsRayQueryParameters3D.create(origin, target, 1, excluded)
	last_ray_count += 1
	var hit := observer.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty(): return true
	var collider: Node = hit.get("collider")
	return is_instance_valid(target_node) and (collider == target_node or target_node.is_ancestor_of(collider))


func can_hear(observer: Node3D, source: Node3D, distance: float) -> bool:
	return is_instance_valid(source) and source.is_inside_tree() and point(observer).distance_to(point(source)) <= distance \
		and clear_path(observer, point(source), source)


func visible(observer: Node3D, target: Node3D) -> bool:
	var direction := point(target) - point(observer)
	return target.is_visible_in_tree() and direction.length() <= VIEW_RANGE \
		and (direction.length() < 0.1 or forward(observer).dot(direction.normalized()) >= -0.25) \
		and clear_path(observer, point(target), target)


## Where something is from the observer's own facing: "ahead", "ahead-left", "left",
## "behind-left", "behind", "behind-right", "right", "ahead-right".
static func bearing(observer: Node3D, target: Vector3) -> String:
	var to := target - point(observer); to.y = 0.0
	if to.length() < 0.3: return "right here"
	var fwd := forward(observer); fwd.y = 0.0
	if fwd.length_squared() < 0.0001: fwd = Vector3.FORWARD
	var angle := rad_to_deg(fwd.normalized().signed_angle_to(to.normalized(), Vector3.UP))
	# Positive angle = counter-clockwise seen from above = to her left.
	var sectors := ["ahead", "ahead-left", "left", "behind-left", "behind", "behind-right", "right", "ahead-right"]
	return sectors[int(floor(fposmod(angle + 22.5, 360.0) / 45.0))]


## Distances as she would say them, not metres.
static func distance_words(metres: float) -> String:
	if metres < 1.6: return "right beside you"
	if metres < 5.0: return "a few steps away"
	if metres < 12.0: return "nearby"
	if metres < 24.0: return "across the way"
	return "far off"


## Height difference words when it matters (more than a body height).
static func height_words(delta: float) -> String:
	if delta > 1.5: return ", higher up"
	if delta < -1.5: return ", lower down"
	return ""


## What a facing direction points at among named things, if anything, within 25 degrees.
static func facing_target(origin: Vector3, direction: Vector3, named: Array) -> String:
	var best := ""
	var best_dot := cos(deg_to_rad(25.0))
	direction.y = 0.0
	if direction.length_squared() < 0.0001: return ""
	direction = direction.normalized()
	for entry: Dictionary in named:
		var to: Vector3 = Vector3(entry.position) - origin; to.y = 0.0
		if to.length() < 0.5: continue
		var dot := direction.dot(to.normalized())
		if dot > best_dot: best_dot = dot; best = str(entry.name)
	return best


static func place_at(position: Vector3) -> Dictionary:
	var best: Dictionary = {}
	var best_distance := INF
	var best_area := INF
	for region: Dictionary in LAYOUT.regions():
		if bool(region.get("future_island", false)): continue
		var distance := LAYOUT.distance_to(region, position)
		# Floating cities cannot claim the ground directly beneath them.
		if region.get("kind", "") == "sky_city" or region.get("id", "") == "cloudsdale":
			distance = maxf(distance, absf(position.y - float(region.get("elevation", region.center[1]))) - 100.0)
		var area := LAYOUT.footprint(region).get_area()
		if distance < best_distance or (is_equal_approx(distance, best_distance) and area < best_area):
			best_distance = distance
			best_area = area
			best = {"id": region.id, "name": region.name, "distance": distance,
				"inside": distance <= 0.0, "kind": region.get("kind", ""), "zone": region.get("zone", "")}
	return best


## Standing in a house door's passage (dev 2026-10-06: a pony blocking a doorway should
## know it, so the AI can move her aside).
static func in_doorway(observer: Node3D) -> bool:
	for door: Node in observer.get_tree().get_nodes_in_group("house_doors"):
		if not door is Node3D or not door.has_method("navigation_world_box"): continue
		if (door as Node3D).global_position.distance_squared_to(observer.global_position) > 9.0: continue
		var box: AABB = door.navigation_world_box()
		if box.size != Vector3.ZERO and box.grow(0.3).has_point(observer.global_position + Vector3.UP * .2): return true
	return false

func sample(id: String, observer: Node3D, characters: Dictionary, player: Node3D, now: float, hearing_range := HEARING_RANGE, include_present := false) -> Dictionary:
	last_ray_count = 0
	var position := observer.global_position
	var sample := {"place": place_at(position), "visible": [], "present": [], "audible": [], "objects": [],
		"held": observer.is_held() if observer.has_method("is_held") else false,
		"moving": observer.velocity.length() > 0.12 if observer is CharacterBody3D else false,
		"hoof_held": observer.is_hoof_held() if observer.has_method("is_hoof_held") else false,
		"hoofholds": observer.hoofhold_count() if observer.has_method("hoofhold_count") else 0,
		"boops": observer.boop_count() if observer.has_method("boop_count") else 0,
		"pets": observer.pet_count() if observer.has_method("pet_count") else 0,
		"kisses": observer.kiss_count() if observer.has_method("kiss_count") else 0,
		"player_distance": INF, "player_visible": false, "player_audible": false,
		"cover": "Indoor/outdoor status is unknown.", "events": [], "landmarks": [],
		"asleep": observer.get("sleeping") == true,
		"riding": observer.has_meta("balloon_passenger"),
		"aloft": observer.has_meta("balloon_passenger") and is_instance_valid(observer.get_meta("balloon_passenger")) and not bool(observer.get_meta("balloon_passenger").get("landed"))}
	var previous: Dictionary = _observations.get(id, {})
	var named: Array = []
	if is_instance_valid(player) and player.is_inside_tree():
		sample.player_distance = point(observer).distance_to(point(player))
		sample.player_visible = visible(observer, player)
		sample.player_audible = can_hear(observer, player, hearing_range)
		sample.player_bearing = bearing(observer, point(player))
		sample.player_height = point(player).y - point(observer).y
		# Player motion from the last sample: toward, away, still, and how fast.
		var last_position: Vector3 = previous.get("player_position", Vector3.INF)
		var last_time: float = float(previous.get("time", now))
		sample.player_position = point(player)
		sample.player_speed = 0.0
		sample.player_closing = 0.0
		if last_position.is_finite() and now - last_time > 0.05 and now - last_time < 30.0:
			var moved := point(player) - last_position; moved.y = 0.0
			sample.player_speed = moved.length() / (now - last_time)
			sample.player_closing = (float(previous.get("player_distance", sample.player_distance)) - sample.player_distance) / (now - last_time)
		# Where the player is looking: at her, at something named, or away.
		var to_her := point(observer) - point(player); to_her.y = 0.0
		var gaze := -player.global_basis.z; gaze.y = 0.0
		sample.player_looking_at_you = to_her.length() > 0.2 and gaze.length_squared() > 0.0001 and gaze.normalized().dot(to_her.normalized()) > 0.8
	# Read current hands for each observation. Never carry an earlier held item into
	# a later prompt, and never infer an unseen item merely from hearing the player.
	sample.player_items = []
	if sample.player_visible and held_items.is_valid():
		var current: Array = held_items.call()
		for entry: Dictionary in current:
			var item: Node3D = entry.get("node") as Node3D
			if is_instance_valid(item) and item.is_inside_tree() and not item.is_queued_for_deletion() and visible(observer, item):
				sample.player_items.append({"id":str(entry.get("id", "")), "name":str(entry.get("name", "an object")), "hand":str(entry.get("hand", ""))})
	sample.time = now
	var navigator := observer.get_node_or_null("Navigator")
	if navigator != null and navigator.has_method("awareness_places"):
		sample.landmarks = navigator.awareness_places()
		for landmark: Dictionary in sample.landmarks:
			if navigator.has_method("command_location"):
				var where: Vector3 = PLACES.resolve(observer.get_tree(), str(landmark.id))
				if not where.is_finite(): where = navigator.command_location(str(landmark.id))
				if where.is_finite():
					landmark.bearing = bearing(observer, where)
					named.append({"name": landmark.name, "position": where})
	# Ground under her hooves from the walk grid: water, a road or path, slope.
	sample.ground = ""
	var service: Variant = navigator.get("_service") if navigator != null else null
	if is_instance_valid(service) and "grid" in service:
		var data: Dictionary = service.grid.snapshot()
		var column: Vector2i = WalkGrid.column(position)
		for span in WalkGrid.SPANS:
			var cell: Dictionary = WalkGrid.sample(data, Vector3i(column.x, span, column.y))
			if cell.is_empty() or absf(float(cell.height) - position.y) > 1.0: continue
			var words: PackedStringArray = []
			if float(cell.get("water", 0.0)) > 0.05: words.append("standing in water")
			elif float(cell.get("trail", 0.0)) > 0.5: words.append("on a road or path")
			else: words.append("on open ground")
			if float(cell.get("slope", 0.0)) > 12.0: words.append("on a slope")
			sample.ground = ", ".join(words)
			break
	# Sky and light.
	var clock: Node = observer.get_node_or_null("/root/TimeOfDay")
	if clock != null and clock.has_method("daylight"):
		var daylight: float = clock.daylight()
		var golden: float = clock.golden_amount() if clock.has_method("golden_amount") else 0.0
		if daylight < 0.05:
			var moon: float = clock.moon_lit_fraction() if clock.has_method("moon_lit_fraction") else 0.5
			sample.sky = "night, " + ("bright moonlight" if moon > 0.6 else ("a thin moon" if moon > 0.15 else "dark, no moon"))
		elif daylight < 0.5: sample.sky = "twilight, the light is going" if float(clock.hours) > 12.0 else "dawn, the light is coming up"
		elif golden > 0.4: sample.sky = "golden low sun"
		else: sample.sky = "full daylight"
	var weather: Node = observer.get_tree().get_first_node_in_group("weather") if observer.is_inside_tree() else null
	# Only weather Anon plainly sees or feels: windy and cloudy spells made every chat about gusts.
	if weather != null and weather.kind in NOTICED_WEATHER:
		sample.sky = (str(sample.get("sky", "")) + ", " if sample.has("sky") else "") + weather.describe()
	if weather != null and weather.has_method("describe_season"):
		sample.season = weather.describe_season()
	var candidates: Array = []
	for other_id in characters:
		if other_id == id: continue
		var other: Variant = characters[other_id].node
		if not is_instance_valid(other) or not other.is_inside_tree(): continue
		var distance := point(observer).distance_to(point(other))
		if distance <= VIEW_RANGE:
			candidates.append({"id": other_id, "node": other, "distance": distance,
				"name": characters[other_id].profile.get("name", other_id)})
	candidates.sort_custom(func(a, b): return a.distance < b.distance)
	for candidate: Dictionary in candidates.slice(0, MAX_PEERS):
		var other: Node3D = candidate.node
		# Silent company still exists behind your shoulder. Ignore the view cone while
		# retaining acoustic obstruction and distance; do not infer company across walls.
		var seen := visible(observer, other)
		var nearby: bool = include_present and candidate.distance <= 5.0
		var heard: bool = candidate.distance <= hearing_range and (seen or ((nearby or (other.has_method("is_speaking") and other.is_speaking())) and can_hear(observer, other, hearing_range)))
		var near: bool = nearby and (seen or heard)
		if near: sample.present.append({"id": candidate.id, "name": candidate.name, "distance": candidate.distance, "bearing": bearing(observer, point(other))})
		if seen:
			sample.visible.append({"id": candidate.id, "name": candidate.name, "distance": candidate.distance, "bearing": bearing(observer, point(other))})
			named.append({"name": candidate.name, "position": point(other)})
		if other.has_method("is_speaking") and other.is_speaking() and heard:
			sample.audible.append(candidate.name)
	# Optional explicitly named objects: no mesh-name guessing, no tree traversal.
	var objects: Array = []
	for object in observer.get_tree().get_nodes_in_group("ai_observable"):
		if is_instance_valid(object) and object is Node3D and object.has_meta("ai_label"):
			var distance := point(observer).distance_to(point(object))
			if distance <= VIEW_RANGE: objects.append({"node": object, "distance": distance})
	objects.sort_custom(func(a, b): return a.distance < b.distance)
	for object in objects.slice(0, MAX_OBJECTS):
		if visible(observer, object.node):
			sample.objects.append({"id": str(object.node.get_meta("ai_id", "")), "name": str(object.node.get_meta("ai_label")).left(80), "distance": object.distance, "bearing": bearing(observer, point(object.node))})
			named.append({"name": str(object.node.get_meta("ai_label")).left(80), "position": point(object.node)})
	# What she faces, and what the player faces, among the named things around.
	sample.facing = facing_target(point(observer), forward(observer), named)
	sample.player_facing = ""
	if is_instance_valid(player) and player.is_inside_tree():
		sample.player_facing = facing_target(point(player), -player.global_basis.z, named)
	# Cover is a physical observation, not proof of being inside a building.
	var roof := PhysicsRayQueryParameters3D.create(point(observer) + Vector3.UP * .15, point(observer) + Vector3.UP * 8.0, 1)
	last_ray_count += 1
	if not observer.get_world_3d().direct_space_state.intersect_ray(roof).is_empty():
		sample.cover = "There is nearby cover overhead; this alone does not establish being indoors."
	sample.doorway = in_doorway(observer)
	var house:Node3D=preload("res://world/buildings/house_interior.gd").at(observer.get_tree(),position)
	sample["space_type"]="HOUSE" if house!=null else "LAND"
	if house!=null:
		sample["house_id"]=house.place_id()
		var house_name: Dictionary = PLACES.find(observer.get_tree(), house.place_id())
		sample.cover="HOUSE: inside "+str(house_name.get("label", house.label()))+". Use its doorway to enter or leave; walls are solid."
		sample.ground="on the house floor"
	else:
		sample.footing = footing(observer, position)
	var events: Array = previous.get("events", []).filter(func(event): return now - event.time < EVENT_LIFETIME)
	if not previous.is_empty():
		if sample.held != previous.held: events.append({"time": now, "text": "The player picked you up." if sample.held else "The player put you down."})
		if sample.hoofholds > previous.get("hoofholds",0): events.append({"time":now,"text":"The player took hold of your hoof."})
		if previous.get("hoof_held",false) and not sample.hoof_held: events.append({"time":now,"text":"The player released your hoof."})
		if sample.boops > previous.boops: events.append({"time": now, "text": "The player booped your nose."})
		if sample.pets > previous.get("pets", 0): events.append({"time": now, "text": "The player petted your %s." % (observer.pet_region() if observer.has_method("pet_region") and observer.pet_region() != "" else "coat")})
		if sample.kisses > previous.kisses: events.append({"time": now, "text": "The player kissed your face."})
		if sample.place.get("id") != previous.place.get("id") or sample.place.get("inside") != previous.place.get("inside"):
			events.append({"time": now, "text": "Your mapped surroundings changed; use the current place below."})
		var before: Array = previous.visible.map(func(peer): return peer.id)
		for peer: Dictionary in sample.visible:
			if peer.id not in before: events.append({"time": now, "text": "%s came into view." % peer.name})
		var after: Array = sample.visible.map(func(peer): return peer.id)
		for peer: Dictionary in previous.visible:
			if peer.id not in after: events.append({"time": now, "text": "%s went out of view (location unknown)." % peer.name})
	sample.events = events.slice(maxi(0, events.size() - 6))
	_observations[id] = sample
	return sample


## What she physically stands on when it is not the open ground: a roof, a bridge,
## a cloud house, a prop. Read from the collider under her hooves, never guessed.
func footing(observer: Node3D, position: Vector3) -> String:
	var excluded: Array[RID] = []
	if observer is CollisionObject3D: excluded.append(observer.get_rid())
	var query := PhysicsRayQueryParameters3D.create(position + Vector3.UP * .4, position - Vector3.UP * 1.5, 1 | CLOUD_LAYER, excluded)
	last_ray_count += 1
	var hit := observer.get_world_3d().direct_space_state.intersect_ray(query)
	var ground := NAN
	if is_instance_valid(WorldTerrain.instance): ground = WorldTerrain.instance.height_at(position)
	var height: float = position.y - ground if is_finite(ground) else 0.0
	if hit.is_empty():
		return "in mid-air, about %d m above the ground" % roundi(height) if height > 2.0 else ""
	var collider: Object = hit.collider
	if collider == null or collider.is_class("Terrain3D"): return ""
	var what := ""
	var node := collider as Node
	for i in 10:
		if node == null: break
		var interior := node.get_node_or_null("HouseInterior")
		if interior != null:
			what = "the roof of " + str(PLACES.find(observer.get_tree(), interior.place_id()).get("label", "a house"))
			break
		if node.has_meta("ai_label"):
			what = str(node.get_meta("ai_label")); break
		if str(node.name) in PLACES.TOWN_BUILDINGS:
			what = "the roof of " + str(PLACES.TOWN_BUILDINGS[str(node.name)]); break
		node = node.get_parent()
	if collider is CollisionObject3D and (collider as CollisionObject3D).collision_layer & CLOUD_LAYER:
		return "on the clouds of %s, high in the sky about %d m above the ground; only a pegasus can stand here" % [what if what != "" else "a cloud house", roundi(height)]
	if what.to_lower().contains("bridge"):
		return "on %s, %d m above the ground below" % [what, maxi(1, roundi(height))]
	if height < 1.2: return "on " + what if what != "" and not what.begins_with("the roof") else ""
	if what == "": what = "a structure"
	elif not what.begins_with("the roof"): what = "top of " + what
	return "ON %s, about %d m above the ground" % [what, roundi(height)]


func describe(sample: Dictionary, player_name: String, now: float) -> PackedStringArray:
	var lines := PackedStringArray()
	var place: Dictionary = sample.place
	if place.is_empty(): lines.append("- Place: unknown.")
	elif place.inside: lines.append("- Place: within the mapped %s region (%s)." % [place.name, place.kind])
	else: lines.append("- Place: between mapped regions, about %.0f m from the edge of %s; not at that destination." % [place.distance, place.name])
	# Landmarks appear once, with their bearing, in "Nearby places" below (they were listed twice).
	# An unknown cover carries no decision value and is left out.
	if str(sample.cover) != "Indoor/outdoor status is unknown.": lines.append("- " + sample.cover)
	if sample.get("doorway", false):
		lines.append("- You are standing in a doorway. If someone needs to get through, move out of the way with [step: aside].")
	if sample.get("riding", false):
		lines.append("- You are riding in Anon's hot-air balloon, in its basket with him. " + ("It is up in the air, drifting over Equestria; you step off once it lands with the gate open." if sample.get("aloft", false) else "It is resting on the ground with the gate open."))
	if sample.get("asleep", false):
		lines.append("- It is night and you were fast asleep, lying in bed with your eyes shut. A voice has half-woken you: you are drowsy, yawning, and would rather go back to sleep. If you decide to get up after all, use wake_up(); otherwise you stay in bed.")
	if str(sample.get("footing", "")) != "":
		lines.append("- Where you stand: %s. This is certain: never deny it, and do not invent a ladder, stairs or any way down that is not listed here." % sample.footing)
	var body := "being held in the player's arms right now" if sample.held else ("moving" if sample.moving else "at rest")
	if str(sample.get("ground", "")) != "": body += ", " + str(sample.ground)
	if str(sample.get("facing", "")) != "": body += ", facing " + str(sample.facing)
	lines.append("- Your body: %s." % body)
	if str(sample.get("sky", "")) != "": lines.append("- Light: %s." % sample.sky)
	if sample.player_visible or sample.player_audible:
		var motion := "standing still"
		var speed: float = float(sample.get("player_speed", 0.0))
		var closing: float = float(sample.get("player_closing", 0.0))
		if speed > 4.5: motion = "running " + ("toward you" if closing > 1.0 else ("away from you" if closing < -1.0 else "past you"))
		elif speed > 0.4: motion = "walking " + ("toward you" if closing > 0.3 else ("away from you" if closing < -0.3 else "past you"))
		var gaze := "looking at you" if sample.get("player_looking_at_you", false) else ("looking at " + str(sample.player_facing) if str(sample.get("player_facing", "")) != "" else "looking elsewhere")
		# Both flags true is the usual case and needs no words (2026-10-22 token diet).
		var reach := "" if sample.player_visible and sample.player_audible else (" Heard, not seen." if sample.player_audible else " Seen, but not within unobstructed speaking range.")
		lines.append("- The player (%s) is %s, %s%s, %s, %s.%s" % [player_name, sample.get("player_bearing", "nearby"), distance_words(sample.player_distance), height_words(float(sample.get("player_height", 0.0))), motion, gaze, reach])
	else: lines.append("- The player is not currently seen or within unobstructed speaking range; do not claim to know their position.")
	if sample.player_visible:
		var carried := PackedStringArray()
		for item: Dictionary in sample.get("player_items", []):
			var hand := str(item.get("hand", ""))
			var where := " in the " + hand + " hand" if hand in ["left", "right"] else ""
			carried.append(str(item.name) + where)
		if not carried.is_empty(): lines.append("- Items the player visibly holds now (seen, not stored inventory or proof of a gift): " + "; ".join(carried) + ".")
	var peers := PackedStringArray()
	for peer: Dictionary in sample.visible: peers.append("%s (%s, %s)" % [peer.name, peer.get("bearing", "nearby"), distance_words(peer.distance)])
	lines.append("- Other ponies currently visible: " + (", ".join(peers) if not peers.is_empty() else "none detected"))
	var present := PackedStringArray()
	var seen_ids: Array = sample.visible.map(func(peer): return peer.get("id", peer.name))
	for peer: Dictionary in sample.get("present", []):
		if peer.get("id", peer.name) in seen_ids: continue # already listed as visible: right here
		present.append("%s (%s, %s)" % [peer.name, peer.get("bearing", "nearby"), distance_words(peer.distance)])
	if not present.is_empty(): lines.append("- Also physically present beside you, including behind you: " + ", ".join(present) + ". Do not ask where one of these ponies is or describe her as absent.")
	if not sample.audible.is_empty(): lines.append("- Currently audible voices: " + ", ".join(sample.audible))
	for object: Dictionary in sample.objects: lines.append("- Visible object: %s (%s, %s)." % [object.name, object.get("bearing", "nearby"), distance_words(object.distance)])
	if not sample.get("landmarks", []).is_empty():
		var spots: PackedStringArray = []
		for landmark: Dictionary in sample.landmarks:
			spots.append("%s (%s, %s)" % [landmark.name, landmark.get("bearing", "somewhere"), distance_words(float(landmark.distance))])
		lines.append("- Nearby places: " + ", ".join(spots) + ". Directions are from where you face.")
	if sample.get("hoof_held",false): lines.append("- The player is holding one of your hooves; your other legs support you.")
	for event: Dictionary in sample.events: lines.append("- %.0f s ago: %s" % [maxf(0.0, now - event.time), event.text])
	return lines
