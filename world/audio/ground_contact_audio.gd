extends RefCounted
## Query only reported contacts, after distance rejection. No frame-time scene or skeleton work.
const HOUSE := preload("res://world/buildings/house_interior.gd")
const WATER_MASK := 1 << 15
const FLOOR_MASK := 1 | (1 << 18)


static func material(source: Node3D, at: Vector3, weather: Node = null) -> String:
	if not is_instance_valid(source) or not source.is_inside_tree() or not at.is_finite(): return ""
	var space := source.get_world_3d().direct_space_state
	if space == null: return ""
	var excluded: Array[RID] = []
	if source is CollisionObject3D: excluded.append(source.get_rid())
	var ray := PhysicsRayQueryParameters3D.create(at + Vector3.UP * .25,
		at - Vector3.UP * .65, FLOOR_MASK | WATER_MASK, excluded)
	ray.hit_back_faces = true
	var hit: Dictionary = space.intersect_ray(ray)
	if hit.is_empty() or Vector3(hit.normal).y < .45: return ""
	var collider: Node = hit.collider as Node
	if collider == null: return ""
	if collider is CollisionObject3D and (collider.collision_layer & WATER_MASK) != 0: return "water"
	var owner: Node = collider
	for i in 4:
		if owner == null: break
		if owner.has_meta("audio_material"):
			var authored := str(owner.get_meta("audio_material"))
			if authored in ["grass", "stone", "wood", "dirt", "sand", "snow", "leaves", "mud", "gravel", "cloud", "cloth"]:
				return authored
		owner = owner.get_parent()
	var label := str(collider.name).to_lower()
	if (collider is CollisionObject3D and (collider.collision_layer & (1 << 18)) != 0) or "cloud" in label: return "cloud"
	var terrain := WorldTerrain.instance
	if is_instance_valid(terrain) and is_instance_valid(terrain.terrain) and (collider == terrain.terrain or "terrain" in label):
		var data: Object = terrain.terrain.data
		if data != null and data.has_method("get_texture_id"):
			var info: Vector3 = data.call("get_texture_id", Vector3(hit.position))
			if info.is_finite():
				var id := int(info.y if info.z >= .5 else info.x)
				var assets: Object = terrain.terrain.assets
				var texture: Object = assets.call("get_texture", id) if assets != null and assets.has_method("get_texture") else null
				if texture != null: label = str(texture.get("name")).to_lower()
		var kind := classify(label, "grass")
		if is_instance_valid(weather):
			if str(weather.get("season")) == "winter": return "snow"
			var params: Dictionary = weather.get("params")
			if kind == "dirt" and float(params.get("rain", 0.0)) > .22: return "mud"
		return kind
	if "terrain" in label: return classify(label, "grass")
	var known := classify(label, "")
	if not known.is_empty(): return known
	# Room contracts distinguish authored timber floors from town stone, regardless of collider names.
	return "wood" if HOUSE.at(source.get_tree(), Vector3(hit.position) + Vector3.UP * .02) != null else "stone"


static func classify(label: String, fallback: String = "stone") -> String:
	for pair: Array in [["snow", "snow"], ["gravel", "gravel"], ["sandstone", "stone"], ["sand", "sand"], ["mud", "mud"],
		["leaf", "leaves"], ["leaves", "leaves"], ["grass", "grass"], ["dirt", "dirt"],
		["wood", "wood"], ["plank", "wood"], ["bridge", "wood"], ["timber", "wood"],
		["rug", "cloth"], ["carpet", "cloth"], ["cushion", "cloth"], ["mattress", "cloth"],
		["rock", "stone"], ["stone", "stone"], ["cobble", "stone"], ["brick", "stone"], ["tile", "stone"], ["road", "stone"]]:
		if str(pair[0]) in label: return str(pair[1])
	return fallback
