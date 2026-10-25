extends SceneTree
## Reproducible, isolated RNL shell replacement. Writes a review asset first; town
## installation is a separate, tested promotion of this exact packed scene.
## The source model comes from EQ_SUGARCUBE_SOURCE (path to the converted model.glb): exports may
## carry this script, so it names no private folders (dev 2026-10-23 anonymization pass).
var source_path := OS.get_environment("EQ_SUGARCUBE_SOURCE")
const OUT := "res://tools/sugarcube/tower_candidate.scn"
const CUT := preload("res://tools/buildings/split_door.gd")
const ROOM := preload("res://world/buildings/sugarcube/bakery_room.gd")
const TOWER := preload("res://world/buildings/sugarcube/tower_room.gd")
const TOWER_HOME := preload("res://world/buildings/sugarcube/tower_home.gd")
const INTERIOR := preload("res://world/buildings/sugarcube/bakery_interior.gd")
const MODEL_SCALE := Vector3(1.15, 0.85, 1.8)
const TOWN_SCALE := 14.0
const STAIR := {"center_x": 0.12 / 14.0, "width": 2.75 / 14.0, "height": 0.90 / 14.0,
	"back_z": 4.03 / 14.0, "landing_z": 4.72 / 14.0, "toe_z": 7.52 / 14.0, "toe_y": -0.20 / 14.0}
var removed_stairs := 0
func _initialize() -> void: _run.call_deferred()
func _own(node: Node, top: Node) -> void:
	for child in node.get_children(): child.owner = top; _own(child, top)

func _geometry_metrics(node: Node) -> Dictionary:
	var result := {"mesh_instances": 0, "render_surfaces": 0, "triangles": 0, "collision_shapes": 0}
	for mesh: MeshInstance3D in node.find_children("*", "MeshInstance3D", true, false):
		if mesh.mesh == null: continue
		result.mesh_instances += 1
		result.render_surfaces += mesh.mesh.get_surface_count()
		for surface in mesh.mesh.get_surface_count():
			if mesh.mesh is ArrayMesh and mesh.mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES: continue
			var arrays: Array = mesh.mesh.surface_get_arrays(surface)
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var count := indices.size() if not indices.is_empty() else vertices.size()
			result.triangles += count / 3
	result.collision_shapes = node.find_children("*", "CollisionShape3D", true, false).size()
	return result

func _bake_shell(source: Node3D, house: Node3D) -> void:
	for original: MeshInstance3D in source.find_children("*", "MeshInstance3D", true, false):
		var mesh := ArrayMesh.new()
		for surface in original.mesh.get_surface_count():
			var arrays: Array = original.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
			var ids: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			if ids.is_empty():
				for i in vertices.size(): ids.append(i)
			var tool := SurfaceTool.new(); tool.begin(Mesh.PRIMITIVE_TRIANGLES)
			for triangle in range(0, ids.size(), 3):
				var bounds := AABB(vertices[ids[triangle]], Vector3.ZERO)
				for j in 3: bounds = bounds.expand(vertices[ids[triangle + j]])
				# The two source stoop blocks are 0.6-0.7 m tall. Remove their complete
				# triangles, including the backs beneath the doorway, before rebuilding.
				if bounds.end.y < 1.31 and bounds.position.z > 2.27 and bounds.end.z > 2.46:
					removed_stairs += 1; continue
				for j in 3:
					var i := ids[triangle + j]
					tool.set_normal((normals[i] / MODEL_SCALE).normalized()); tool.set_uv(uvs[i])
					tool.add_vertex(vertices[i] * MODEL_SCALE / TOWN_SCALE)
			var material: Material = original.mesh.surface_get_material(surface).duplicate()
			if material is BaseMaterial3D:
				material.roughness = 0.9; material.cull_mode = BaseMaterial3D.CULL_DISABLED
			tool.set_material(material); tool.index(); tool.commit(mesh)
		var visual := MeshInstance3D.new(); visual.name = "Exterior"; visual.mesh = mesh; house.add_child(visual)

func _run() -> void:
	for path: String in ["res://world/buildings/sugarcube/tower_home.gd","res://world/buildings/sugarcube/tower_room.gd","res://world/buildings/sugarcube/tower_opening.gd","res://tools/sugarcube/test_tower_home.gd","res://tools/sugarcube/test_connected_home_travel.gd","res://tools/sugarcube/test_tower_pony_route.gd","res://tools/sugarcube/test_tower_clearance.gd","res://tools/sugarcube/measure_bed_fit.gd","res://tools/sugarcube/measure_pony_profile.gd"]:
		if FileAccess.file_exists(path) and not FileAccess.file_exists(path+".uid"):
			FileAccess.open(path+".uid",FileAccess.WRITE).store_line(ResourceUID.id_to_text(ResourceUID.create_id()))
	var doc := GLTFDocument.new(); var state := GLTFState.new(); assert(doc.append_from_file(source_path, state) == OK)
	var source := doc.generate_scene(state)
	var house := Node3D.new(); house.name = "SugarcubeCorner"; root.add_child(house)
	_bake_shell(source, house); source.free()
	assert(removed_stairs > 10, "RNL source stair blocks must be removed")
	var left := -0.93 * MODEL_SCALE.x / TOWN_SCALE; var right := 1.13 * MODEL_SCALE.x / TOWN_SCALE
	var bottom := ROOM.FLOOR / TOWN_SCALE; var top := 4.64 * MODEL_SCALE.y / TOWN_SCALE
	var opening := {"center": (left + right) * 0.5, "width": right - left, "bottom": bottom, "top": top,
		"depth": 2.42 * MODEL_SCALE.z / TOWN_SCALE, "leaf_depth": 2.40 * MODEL_SCALE.z / TOWN_SCALE,
		"cut_back": 0.30 * MODEL_SCALE.z / TOWN_SCALE, "cut_front": 0.12 * MODEL_SCALE.z / TOWN_SCALE,
		"panel_depth": 0.055 * MODEL_SCALE.z / TOWN_SCALE,
		"contour": [[left, bottom], [right, bottom], [right, top], [left, top]]}
	CUT.apply(house, opening)
	# Keep the source artwork on the inside as well as the outward leaf.
	var leaf: Node3D = house.get_node("FrontDoor")
	var art: MeshInstance3D = leaf.get_node("OriginalDoorArtwork")
	var art_box := art.transform * art.mesh.get_aabb()
	var inside := MeshInstance3D.new(); inside.name = "InsideArtwork"; inside.mesh = art.mesh
	inside.transform = Transform3D(Basis.from_scale(Vector3(1, 1, -1)), Vector3(0, 0, art_box.position.z - 0.0045)) * art.transform
	inside.visibility_range_end = 60.0; leaf.add_child(inside)
	var exterior: MeshInstance3D = house.get_node("Exterior"); exterior.create_trimesh_collision()
	var stair: StaticBody3D = preload("res://world/buildings/stair_brush.gd").build(STAIR)
	house.add_child(stair)
	var pink := StandardMaterial3D.new(); pink.albedo_color = Color("bf76b3"); pink.roughness = 0.95
	(stair.get_node("StoneRamp") as MeshInstance3D).material_override = pink
	# Fine visible steps retain the source's pink stoop language. One welded ramp
	# owns capsule support; the thin risers never reintroduce the old solid block.
	var tread_frame := Node3D.new(); tread_frame.name = "PinkStairTreads"; tread_frame.scale = Vector3.ONE / TOWN_SCALE; house.add_child(tread_frame)
	for i in 8:
		var y := lerpf(-0.20, ROOM.FLOOR, float(i + 1) / 8.0)
		var z := lerpf(7.52, 4.72, (float(i) + 0.5) / 8.0)
		ROOM._box(tread_frame, "StoopTread", Vector3(2.75, 0.12, 0.35), Vector3(0.12, y - 0.06, z), pink)
	var room := ROOM.build(house)
	if not TOWER.open_shaft(house):
		push_error("Sugarcube tower source enclosure did not match; no candidate written")
		quit(1); return
	var tower_room := TOWER.build(house)
	var interior := INTERIOR.new(); interior.name = "HouseInterior"
	interior.floor_y = ROOM.FLOOR / TOWN_SCALE
	interior.doorway = Vector3(0.12, ROOM.FLOOR, 4.26) / TOWN_SCALE
	interior.door_width = right - left
	interior.approach = Vector3(0.12, -0.20, 7.80) / TOWN_SCALE
	interior.floors = [Rect2(Vector2(ROOM.LEFT, ROOM.BACK) / TOWN_SCALE, Vector2(ROOM.RIGHT - ROOM.LEFT, ROOM.FRONT - ROOM.BACK) / TOWN_SCALE)]
	interior.furnish = false; house.add_child(interior)
	var tower_home := TOWER_HOME.new(); tower_home.name = "TowerHome"; tower_home.scale = Vector3.ONE/TOWN_SCALE
	tower_home.floor_y = ROOM.FLOOR
	tower_home.room_floor = TOWER.FLOOR; tower_home.room_ceiling = 15.2
	tower_home.room_bounds = Rect2(-2.4,-3.15,4.45,5.6)
	# Guard faces bound the 1.8 m stair lanes; the staff passage is 1.78 m.
	tower_home.stair_width = 1.72
	tower_home.route_clearance = 2.2
	tower_home.stair_path = TOWER.indoor_path()
	tower_home.ground_path_count = 5
	house.add_child(tower_home)
	house.set_meta("building_design", "sugarcube"); house.set_meta("landmark", "Sugarcube Corner")
	house.set_meta("recommended_scale", TOWN_SCALE); house.set_meta("source_sha256", FileAccess.get_sha256(source_path))
	house.set_meta("rnl_source_steps_removed", removed_stairs)
	for mesh: MeshInstance3D in house.find_children("*", "MeshInstance3D", true, false):
		if mesh.visibility_range_end <= 0: mesh.visibility_range_end = 250.0
	# Save after deferred door pulls have settled, at the same scale as town gameplay.
	house.scale = Vector3.ONE * TOWN_SCALE
	await process_frame
	house.scale = Vector3.ONE
	interior._set_interior_range(true) # Never bake a user quality cap into authored ranges.
	# Runtime home metadata is restored by TowerHome._ready on scene instantiation.
	tower_room.get_node("PinkieBed").remove_meta("house")
	_own(house, house)
	var packed := PackedScene.new(); assert(packed.pack(house) == OK)
	assert(ResourceSaver.save(packed, OUT, ResourceSaver.FLAG_COMPRESS) == OK)
	print("SUGARCUBE_TOWER_METRICS ", JSON.stringify({"tower": _geometry_metrics(tower_room), "bakery": _geometry_metrics(room), "whole_building": _geometry_metrics(house)}))
	print("SUGARCUBE_RNL_BUILD_DONE removed_stair_triangles=%d room=%s" % [removed_stairs, Vector2(ROOM.RIGHT - ROOM.LEFT, ROOM.FRONT - ROOM.BACK)])
	house.free(); quit()
