extends RefCounted
## Stable, separated starting neighbourhoods. Final placement still needs physics.
## Region dimensions own the extent; no Ponyville coordinates or mesh-name rules.
static func plan(region: Dictionary, residents: Array) -> Dictionary:
	var result := {}
	if residents.is_empty() or region.is_empty(): return result
	var region_id := str(region.id)
	var center := WorldLayout.center(region_id)
	var size := WorldLayout.footprint(region).size
	var radius := clampf(float(region.get("population_radius", minf(size.x, size.y) * .25)), 12.0, 180.0)
	var ids := residents.duplicate(); ids.sort()
	var chosen: Array[Vector3] = []
	for id: String in ids:
		var rng := RandomNumberGenerator.new()
		rng.seed = hash(region_id + ":" + id)
		var selected := center
		var best := -1.0
		# Best candidate sampling spreads homes without making a visible grid/ring.
		for attempt in 16:
			var angle := rng.randf() * TAU
			var reach := pow(rng.randf(), .7) * radius
			var point := center + Vector3(cos(angle), 0, sin(angle)) * reach
			var separation := radius if chosen.is_empty() else INF
			for previous in chosen:
				separation = minf(separation, Vector2(point.x - previous.x, point.z - previous.z).length())
			if separation > best: selected = point; best = separation
		chosen.append(selected)
		result[id] = selected
	return result
