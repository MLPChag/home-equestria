extends RefCounted
## Offline fitting for sloped house plots. The regular prefab brush handles level
## ground; only plots below its toe need an additional approach down to terrain.
static func build(town: Node3D, ground: Node, specs: Dictionary) -> Node3D:
	var approaches := Node3D.new()
	approaches.name = "TerrainStairApproaches"
	for house: Node in town.get_children():
		if not house.has_meta("browser_source") and not house.has_meta("building_design"): continue
		var id := String(house.get_meta("building_design", ""))
		if id.is_empty(): id = String(house.get_meta("browser_source")).get_slice("house-",1).left(1)
		# Exterior-only landmarks can have separately fitted entrance approaches.
		if not specs.has(id) or not specs[id].has("stair_brush"): continue
		var spec: Dictionary = specs[id].stair_brush.duplicate()
		var needed := false
		for attempt in 40:
			var low := INF
			for offset: float in [-.5,0.0,.5]:
				var p: Vector3 = house.to_global(Vector3(spec.center_x+spec.width*offset,0,spec.toe_z))
				p.y = ground.height_at(p)
				assert(p.is_finite(), "Stair approach needs finite terrain")
				low = minf(low,house.to_local(p).y)
			spec.toe_y = low-.008
			if attempt==0 and spec.toe_y>=-.025: break
			needed = true
			if (float(spec.height)-float(spec.toe_y))/(float(spec.toe_z)-float(spec.landing_z))<=.65: break
			spec.toe_z+=.01
		if not needed: continue
		assert((float(spec.height)-float(spec.toe_y))/(float(spec.toe_z)-float(spec.landing_z))<=.65)
		var brush := preload("res://world/buildings/stair_brush.gd").build(spec)
		brush.name = house.name
		brush.transform = house.transform
		brush.set_meta("stair_spec",spec)
		approaches.add_child(brush)
		brush.owner = approaches
		for child in brush.get_children():child.owner=approaches
		print("TERRAIN STAIR ",house.name," toe=",spec.toe_z," y=",spec.toe_y)
	return approaches
