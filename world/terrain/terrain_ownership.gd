class_name TerrainOwnership
extends RefCounted
## Bake-time ownership of overlapping imported terrain footprints.
##
## A small terrain placed inside a larger imported zone owns its interior in the world
## generator.  The larger zone's static trees cannot be left at their original elevation
## where the two height fields differ substantially, so remove only those ordinary plant
## roots during ZoneProcessor baking.  Generated biome foliage remains available there.

const SCALE := preload("res://world/foliage/vegetation_scale.gd")
const BUILDER := preload("res://world/terrain_builder.gd")
const CONFLICT_METRES := 8.0


static func prune_foreign_owned_plants(root: Node3D, config: Dictionary) -> Dictionary:
	var data := _terrain_data(config)
	if data.own.is_empty() or data.foreign.is_empty():
		return {"removed": 0, "landmarks": 0, "candidates": 0}
	var removed := 0
	var landmarks := 0
	var candidates := 0
	var victims: Array[Node3D] = []
	for node in root.find_children("*", "Node3D", true, false):
		var plant := node as Node3D
		if not _is_plant_root(plant):
			continue
		var path := str(root.get_path_to(plant))
		if _is_landmark(path):
			landmarks += 1
			continue
		var bounds := SCALE.visual_bounds(plant)
		if bounds.size.y <= 0.001:
			continue
		# ZoneProcessor receives a detached GLB tree.  Convert its root-space bounds
		# into the registry world frame before comparing terrain ownership.
		var base: Vector3 = bounds.get_center() + (data.zone_origin as Vector3)
		var bottom: float = bounds.position.y + (data.zone_origin as Vector3).y
		var own := _containing(data.own, base.x, base.z)
		if own.is_empty():
			continue
		var foreign := _smaller_foreign(data.foreign, own.area, base.x, base.z)
		if foreign.is_empty():
			continue
		candidates += 1
		var own_y := _height(own, base.x, base.z)
		var foreign_y := _height(foreign, base.x, base.z)
		# Imported roots conventionally sit a few metres under their own terrain.  Do
		# not remove props with an unexplained/elevated base; only clear a root whose
		# source attachment is sound and whose foreign owner is materially different.
		if absf(bottom - own_y) <= 5.0 and absf(bottom - foreign_y) >= CONFLICT_METRES:
			victims.append(plant)
	for victim in victims:
		if is_instance_valid(victim) and victim.get_parent() != null:
			victim.get_parent().remove_child(victim)
			victim.queue_free()
			removed += 1
	return {"removed": removed, "landmarks": landmarks, "candidates": candidates}


static func _terrain_data(config: Dictionary) -> Dictionary:
	var registry: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://world/zones.json"))
	if not registry is Dictionary:
		return {"own": [], "foreign": [], "zone_origin": Vector3.ZERO}
	var own_id := ""
	var own_meta := ""
	for terrain in config.get("terrain", []):
		if str(terrain.get("mode", "")) == "terrain3d":
			own_meta = str(terrain.get("meta", ""))
			break
	for entry in registry.get("zones", []):
		var dir := str(entry.get("scene", "")).get_base_dir()
		var candidate: Variant = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("zone.json")))
		if candidate is Dictionary:
			for terrain in candidate.get("terrain", []):
				if str(terrain.get("meta", "")) == own_meta:
					own_id = str(entry.get("id", ""))
					break
		if not own_id.is_empty():
			break
	if own_id.is_empty():
		return {"own": [], "foreign": [], "zone_origin": Vector3.ZERO}
	var own: Array = []
	var foreign: Array = []
	for entry in registry.get("zones", []):
		var dir := str(entry.get("scene", "")).get_base_dir()
		var cfg: Variant = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("zone.json")))
		if not cfg is Dictionary:
			continue
		var origin := _vec3(entry.get("origin", []))
		for terrain in cfg.get("terrain", []):
			if str(terrain.get("mode", "")) != "terrain3d":
				continue
			var meta := BUILDER.load_meta(dir.path_join(str(terrain.get("meta", ""))))
			if meta.is_empty():
				continue
			var o := origin + _vec3(terrain.get("origin", []))
			var record := {"dir": dir, "meta": meta, "origin": o,
				"area": float(meta.get("size_x", 0.0)) * float(meta.get("size_z", 0.0)), "heights": PackedFloat32Array()}
			if str(entry.get("id", "")) == own_id:
				own.append(record)
			else:
				foreign.append(record)
	var zone_origin := Vector3.ZERO
	for entry in registry.get("zones", []):
		if str(entry.get("id", "")) == own_id:
			zone_origin = _vec3(entry.get("origin", []))
			break
	return {"own": own, "foreign": foreign, "zone_origin": zone_origin}


static func _containing(records: Array, x: float, z: float) -> Dictionary:
	for record in records:
		var origin: Vector3 = record.origin
		var u := (origin.x - x) / float(record.meta.get("size_x", 1.0))
		var v := (z - origin.z) / float(record.meta.get("size_z", 1.0))
		if u >= 0.0 and u <= 1.0 and v >= 0.0 and v <= 1.0:
			return record
	return {}


static func _smaller_foreign(records: Array, own_area: float, x: float, z: float) -> Dictionary:
	var best := {}
	for record in records:
		if float(record.area) >= own_area:
			continue
		if not _containing([record], x, z).is_empty() and (best.is_empty() or float(record.area) < float(best.area)):
			best = record
	return best


static func _height(record: Dictionary, x: float, z: float) -> float:
	var heights: PackedFloat32Array = record.heights
	if heights.is_empty():
		heights = BUILDER.load_heights(str(record.dir), record.meta)
		record.heights = heights
	var origin: Vector3 = record.origin
	var u := (origin.x - x) / float(record.meta.size_x)
	var v := (z - origin.z) / float(record.meta.size_z)
	return origin.y + BUILDER.sample_norm(heights, int(record.meta.resolution), u, v) * float(record.meta.height_scale)


static func _is_plant_root(node: Node3D) -> bool:
	var name := str(node.name).to_lower()
	if name.contains("_") or name.contains("lod"):
		return false
	var plant := name.begins_with("everfreetree") or name.begins_with("tree0") or name.begins_with("everfreebush") or name.begins_with("bush") or name.begins_with("fern") or name.begins_with("brambles") or name.contains("thorn")
	if not plant:
		return false
	var parent := node.get_parent()
	while parent != null:
		var ancestor := str(parent.name).to_lower()
		if ancestor.begins_with("everfreetree") or ancestor.begins_with("tree0") or ancestor.begins_with("everfreebush") or ancestor.begins_with("bush") or ancestor.begins_with("fern") or ancestor.begins_with("brambles") or ancestor.contains("thorn"):
			return false
		parent = parent.get_parent()
	return true


static func _is_landmark(path: String) -> bool:
	var lower := path.to_lower()
	return lower.contains("zecora") or lower.contains("hut") or lower.contains("bridge") or lower.contains("entrance")


static func _vec3(value: Variant) -> Vector3:
	if value is Array and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return Vector3.ZERO
