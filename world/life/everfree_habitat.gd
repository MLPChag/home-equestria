extends RefCounted
## Same painted Everfree biome as trees/lighting, not a second hard-coded forest map.
static func strength(at: Vector3) -> float:
	if is_instance_valid(WorldTerrain.instance) and WorldTerrain.instance.biomes != null:
		var field: WorldBiomeField = WorldTerrain.instance.biomes
		var weights: PackedFloat32Array = field.sample_weights(Vector2(at.x, at.z))
		var value := 0.0
		for i in weights.size():
			if str(field.presets[i].get("key", "")) == "dark_forest": value += weights[i]
		var ground: float = WorldTerrain.instance.height_at(at)
		if is_finite(ground): value *= 1.0 - smoothstep(15.0, 45.0, at.y - ground)
		return clampf(value, 0.0, 1.0)
	for id: String in ["everfree", "zecoras_hut", "castle_of_two_sisters"]:
		var region := WorldLayout.region(id)
		if not region.is_empty() and WorldLayout.footprint(region).has_point(Vector2(at.x, at.z)): return 1.0
	return 0.0
