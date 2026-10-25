extends SceneTree
## House C / D cleanup, September 25 (dev: "a massive hole where I can see the grass through
## the floor", "odds and ends sticking out all over the place", "a little line between the
## wing and the house that mares cannot walk over"). Offline, reproducible post-bake step for
## the browser-pack scenes; run it after tools/buildings/browser_pack.gd rebuilds C or D.
##
##   EQ_HOUSE_CD_BACKUP=<backup folder> python3 <private root>/tools/run_owned_godot.py --project . --timeout 600 \
##     --expect "HOUSE FIX PASS" --log /tmp/fix.log res://tools/houses_fix/house_c_d/fix_house.gd --arg house=c
##
## Input is the pristine browser-pack bake kept in backup_path (copied there on first run), so the
## script can be re-run and always starts from the same source. `--arg out=/abs/path.scn`
## writes a dry-run copy instead of the game's scenes. What it does:
##  1. Measures the real room air (the "region"): cells 2.5 cm apart, 15 cm above the floor,
##     reachable from the floor rects without crossing any visible surface, walled in all four
##     directions. Measured on a live copy with HouseInterior's runtime dressing applied (wing
##     opening cut, bed removed) and without the Exterior pieces step 4 deletes.
##  2. Replaces the rect FloorSlab boxes and the FloorSlabEdgeFill sheet (hidden at runtime,
##     which left grass showing through D's wing bay, along D's front and right walls and at the
##     foot of C's walls; C's slab also ran 58 cm out past its back wall) with one FittedFloor:
##     planks over exactly the region (collision boxes; D's sunken landing as a welded mesh) and
##     a stone apron down to the house base along every edge. FittedFloor's script
##     (world/buildings/house_c/fitted_floor.gd) gives it the per-house plank shade that
##     HouseInterior._dress_floor gives other houses. Nothing is named FloorSlab* any more, so
##     HouseInterior._fit_floor does not run for C and D: its sampled underlay and skirting
##     came out staggered on angled walls and loose beside posts, the door and D's bay.
##  3. Baseboard along the region's walls (simplified straight runs, 9 cm, following D's
##     sunken landing), with collision. It closes the slits at the foot of C's walls, where the
##     wall band stops 3-6 cm above the floor and the grass showed through.
##  4. Exterior: deletes flat source triangles at floor level inside the rooms (D's generated
##     interior base poked up to 12 cm through the planks along its left wall, a collision lip),
##     the house-specific boxes in EDITS (C's wall fin), and restores the stone plinth that the
##     shared split_door.trim_stoop cut away beside the entrance ramp (from the source model).
##  5. HouseInterior floor rects pulled inside the walls (C's main rect ran past its back wall;
##     the back-right alcove becomes a third rect so a bed can still stand there).
##  6. Door leaf: bottom edge raised to the sill (top fixed, 2-4 % shorter) so it clears C's
##     inner ramp and D's sunken landing instead of sweeping through them. D's steep inner ramp
##     is replaced by a sunken landing under the whole door swing (EDITS).
const SCALE := 10.0
const STEP := .0025
const VIS := 1 << 19
## The pristine bake's folder comes from EQ_HOUSE_CD_BACKUP: this script ships (town.tscn refers to it),
## so it carries no private folder names (dev 2026-10-23 anonymization pass).
var backup_path := OS.get_environment("EQ_HOUSE_CD_BACKUP").simplify_path() + "/"
const WOOD := preload("res://world/buildings/textures/wood_floor.res")
const FITTED_FLOOR := preload("res://world/buildings/house_c/fitted_floor.gd")
const TARGETS := {
	"c": ["res://world/buildings/house_c/house_c_automatic.scn", "res://world/buildings/house_c/house_c_structure.scn"],
	"d": ["res://world/buildings/house_d/house_d_structure.scn"],
}
const PRISTINE := {"c": "house_c_automatic.before_fix.scn", "d": "house_d_structure.before_fix.scn"}
## House-specific Exterior edits, in house-local units, found by inspection (renders and
## triangle probes under captures/houses_fix/house_c_d/):
##  C "drop": the left section's back wall runs on 86 cm past the stepped corner post
##    (x -0.05..0.02, z -0.258), a full-height fin standing in the room in front of the real
##    back wall at z -0.308, walling off a hidden pocket and catching loose skirting boards.
##    Removed up to 3.6 m; the top stays as a header, because it closes the seam between the two
##    roofs above (removing it opened a gap onto the thatch).
## Both: the stone plinth beside the entrance ramp is restored from the source model (below).
##    "plinth_sides": which side of the ramp. D's right side had only the source's old stoop
##    steps in the cut volume (its front plinth stands behind the landing line), so restoring it
##    put loose white steps back beside the ramp; only D's left (the wing's plinth) is restored.
const EDITS := {
	"c": {"drop": [AABB(Vector3(-.048, -.01, -.265), Vector3(.068, .37, .023))], "plinth_sides": ["left", "right"]},
	"d": {"landing": {"slope_deg": 17.0, "margin": .01}, "plinth_sides": ["left"]},
}
## D "landing": D's floor stands 24 cm above its door sill, and the pink leaf swung into the
##   inner ramp and floor (the ramp surface rose 24 cm above the leaf's bottom edge). The steep
##   ramp between grey trench walls is replaced by a sunken landing at sill height under the
##   whole swing of the leaf, with planks sloping up to the floor all round it (17 degrees).
const SKIP_VISUAL := ["FloorSlab", "FloorUnderlay", "Skirting", "InsideArtwork", "HandleGlow"]
var failures: Array[String] = []
var landing := {}
var floor_y := 0.0

## Floor height at a house-local xz point: the floor, or the sunken landing under the door swing.
func floor_height(p: Vector2) -> float:
	if landing.is_empty(): return floor_y
	var h: Vector2 = landing.hinge; var r: float = landing.radius; var m: float = landing.margin
	var q := Vector2(p.x, minf(p.y, h.y))
	var d := 0.0
	if q.x >= h.x - m: d = maxf(0.0, (q - h).length() - r)
	else: d = Vector2(q.x - (h.x - m), q.y - clampf(q.y, h.y - r, h.y)).length()
	return minf(floor_y, float(landing.sill) + float(landing.slope) * d)

func _initialize() -> void: run.call_deferred()
func arg(n: String, d := "") -> String:
	for a in OS.get_cmdline_user_args(): if a.begins_with(n + "="): return a.split("=", true, 1)[1]
	return d
func check(ok: bool, why: String) -> void:
	if not ok: failures.append(why); print("FAIL ", why)

func run() -> void:
	var id := arg("house", "c")
	if OS.get_environment("EQ_HOUSE_CD_BACKUP").is_empty():
		print("FAIL set EQ_HOUSE_CD_BACKUP to the pristine bake folder"); quit(1); return
	DirAccess.make_dir_recursive_absolute(backup_path)
	var pristine: String = backup_path + PRISTINE[id]
	# A scene without this script's stamp is a fresh browser_pack bake: it becomes the new
	# pristine input (the previous one is kept with a timestamp).
	var current: Node = (ResourceLoader.load(TARGETS[id][0], "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate()
	var fresh := not current.has_meta("houses_fix_cd")
	current.free()
	if fresh and FileAccess.file_exists(pristine):
		DirAccess.rename_absolute(pristine, pristine.get_basename() + "." + str(int(Time.get_unix_time_from_system())) + ".scn")
		print("new bake found: previous pristine kept with a timestamp")
	if not FileAccess.file_exists(pristine):
		# First run: keep the untouched bake (and every target) outside the project.
		for path: String in TARGETS[id]:
			var dest := backup_path + path.get_file()
			if not FileAccess.file_exists(dest): DirAccess.copy_absolute(ProjectSettings.globalize_path(path), dest)
		DirAccess.copy_absolute(ProjectSettings.globalize_path(TARGETS[id][0]), pristine)
		print("backed up pristine bake to ", pristine)
	var source_hash := FileAccess.get_sha256(pristine)
	# ---- 1. measure on a live, runtime-dressed copy
	var world := Node3D.new(); root.add_child(world)
	var live: Node3D = (ResourceLoader.load(pristine, "", ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene).instantiate()
	live.scale = Vector3.ONE * SCALE; world.add_child(live)
	for i in 40: await physics_frame
	for child in live.get_children():
		if str(child.scene_file_path).ends_with("pony_bed.scn"): child.free()
	var interior: Node3D = live.get_node("HouseInterior")
	var fy: float = interior.floor_y
	var floors: Array[Rect2] = interior.floors.duplicate()
	var doorway: Vector3 = interior.doorway
	var door_width: float = interior.door_width
	for mesh: MeshInstance3D in live.find_children("*", "MeshInstance3D", true, false):
		if not mesh.is_visible_in_tree() or mesh.mesh == null: continue
		if SKIP_VISUAL.any(func(w: String) -> bool: return str(mesh.name).begins_with(w)): continue
		var shape := mesh.mesh.create_trimesh_shape()
		if shape == null: continue
		if str(mesh.name).begins_with("Exterior") and EDITS.get(id, {}).has("drop"):
			# Measure the room as it will be: without the Exterior pieces this script deletes.
			var to_house := live.global_transform.affine_inverse() * mesh.global_transform
			var faces := shape.get_faces(); var kept := PackedVector3Array()
			for i in range(0, faces.size(), 3):
				var m := to_house * ((faces[i] + faces[i + 1] + faces[i + 2]) / 3.0)
				var drop := false
				for box: AABB in EDITS[id].drop:
					if box.has_point(m): drop = true
				if not drop: kept.append_array([faces[i], faces[i + 1], faces[i + 2]])
			shape = ConcavePolygonShape3D.new(); shape.set_faces(kept)
		shape.backface_collision = true
		var body := StaticBody3D.new(); body.collision_layer = VIS; body.collision_mask = 0
		var holder := CollisionShape3D.new(); holder.shape = shape; body.add_child(holder); mesh.add_child(body)
	for i in 4: await physics_frame
	var region := measure_region(live, fy, floors)
	var holes := fill_holes(region)
	print("region cells=", region.size(), " area_m2=", snappedf(region.size() * STEP * STEP * SCALE * SCALE, .01))
	check(region.size() > 1000, "room region measured")
	save_region_png(id, region, floors)
	# The inner threshold ramp: where it runs below the floor (D: sill under the floor), the planks
	# stop at its landing edge; where it climbs above the floor (C), planks run on underneath.
	var inner_ramp := live.get_node("InnerThresholdRamp/RampAndLanding") as CollisionShape3D
	var toe_y: float = (inner_ramp.shape as ConvexPolygonShape3D).points[3].y
	# One cell narrower than the ramp on each side, so the planks tuck under its side edges.
	var ramp := Rect2(doorway.x - door_width * .5 + STEP, doorway.z - .12, door_width - 2 * STEP, .2)
	if toe_y >= fy: ramp = Rect2(doorway.x - door_width * .5 + STEP, doorway.z, door_width - 2 * STEP, .2)   # only the doorway itself
	print("inner ramp toe_y=", toe_y, " floor=", fy, " exclusion=", ramp)
	var leaf_live: Node3D = live.get_node("FrontDoor")
	var leaf_size: Vector3 = (live.get_node("FrontDoor/LeafThickness") as MeshInstance3D).get_aabb().size
	landing = {}
	if EDITS.get(id, {}).has("landing"):
		var cfg: Dictionary = EDITS[id].landing
		landing = {"hinge": Vector2(leaf_live.position.x, doorway.z), "radius": leaf_size.x + cfg.margin, "margin": cfg.margin,
			"sill": toe_y, "slope": tan(deg_to_rad(cfg.slope_deg)), "fy": fy}
		ramp = Rect2()   # the landing replaces the inner ramp; planks cover the doorway too
	floor_y = fy
	var exterior_live: MeshInstance3D = null
	for m: MeshInstance3D in live.find_children("Exterior", "MeshInstance3D", true, false): exterior_live = m
	var ext_xf := live.global_transform.affine_inverse() * exterior_live.global_transform
	world.queue_free()
	for i in 4: await process_frame
	# ---- 2. edit a fresh copy (never added to the tree: HouseInterior must not run on it)
	var house: Node3D = (ResourceLoader.load(pristine, "", ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene).instantiate()
	var report := {"house": id, "pristine_sha256": source_hash, "region_cells": region.size(), "step": STEP}
	var removed := []
	for node: Node in house.get_children():
		if str(node.name).begins_with("FloorSlab"): removed.append(str(node.name))
	for n: String in removed:
		var node := house.get_node(n); house.remove_child(node); node.free()
	report["removed_nodes"] = removed
	var slab_material := StandardMaterial3D.new(); slab_material.albedo_color = Color("bba18a"); slab_material.roughness = 1.0
	var under := region.duplicate()
	for c: Vector2i in holes: under[c] = true   # planks run on under posts standing in the room
	# Notches: a cell with three or four room neighbours (a corner post's foot, a crack the
	# enclosure rays slipped through) gets planks too. Staircase steps along diagonal walls have
	# two and stay out, so nothing reaches past a wall.
	for pass_i in 3:
		var add: Array[Vector2i] = []
		for c: Vector2i in under:
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n := c + d
				if under.has(n): continue
				var k := 0
				for e: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					if under.has(n + e): k += 1
				if k >= 3: add.append(n)
		for n in add: under[n] = true
	var floor_node := build_floor(under, ramp, fy, slab_material)
	floor_node.set_meta("side_color", plinth_color(house, fy))
	house.add_child(floor_node, true); floor_node.owner = house
	for c in floor_node.get_children(): c.owner = house; for cc in c.get_children(): cc.owner = house
	var loops := boundary_loops(region)
	# No baseboard across the doorway (the closed leaf bounds the measured room there).
	# Starts just inside the leaf's plane, so the entrance recess's side walls keep their boards
	# (they cover the slit where D's recess walls stop above the sunken landing).
	var doorway_strip := Rect2(doorway.x - door_width * .5 - .004, doorway.z - .002, door_width + .008, .2)
	var board := build_baseboard(loops, [ramp, doorway_strip], fy)
	house.add_child(board.mesh, true); board.mesh.owner = house
	for c in board.mesh.get_children(): c.owner = house; for cc in c.get_children(): cc.owner = house
	report["baseboard_runs"] = board.runs; report["baseboard_length_m"] = snappedf(board.length * SCALE, .01)
	# ---- 3b. the inner threshold ramp. D: replaced by the sunken landing. C: kept, renamed so
	# HouseInterior._dress_floor does not pick it up (that would also start its sampled skirting,
	# which laid a loose board across the floor where its wall rays met the ramp's slope);
	# FittedFloor gives it the planks instead.
	var threshold: StaticBody3D = house.get_node("InnerThresholdRamp")
	if not landing.is_empty():
		house.remove_child(threshold); threshold.free()
		report["inner_ramp"] = "replaced by sunken landing"
	else:
		threshold.name = "ThresholdRamp"
		var extra_planks: Array[NodePath] = [NodePath("ThresholdRamp/StoneRamp")]
		floor_node.set("planks_too", extra_planks)
		report["inner_ramp"] = "kept as ThresholdRamp"
	floor_node.set("trim", NodePath("Baseboard"))
	# ---- 4. floor-level artifacts of the source model inside the rooms
	var exterior: MeshInstance3D = null
	for m: MeshInstance3D in house.find_children("Exterior", "MeshInstance3D", true, false): exterior = m
	var cleaned := clean_exterior(house, exterior, ext_xf, region, fy, EDITS.get(id, {}))
	report["exterior_edits"] = cleaned
	# ---- 4b. plinth beside the entrance ramp, cut away by the shared split_door.trim_stoop
	report["plinth_triangles_restored"] = restore_plinth(id, house, exterior)
	# ---- 5. floor rects inside the walls
	var hi: Node = house.get_node("HouseInterior")
	var rects := fit_rects(floors, region)
	hi.set("floors", rects)
	report["floors_before"] = str(floors); report["floors_after"] = str(rects)
	# ---- 6. door leaf: its bottom edge rises to the sill (top fixed, a few % shorter) so it clears
	# the inner ramp (C) / the sunken landing (D) instead of sweeping through them.
	var leaf: Node3D = house.get_node("FrontDoor")
	var bottom := leaf.position.y
	var top := bottom + leaf_size.y
	var new_bottom := toe_y + .0005
	if new_bottom > bottom:
		leaf.scale = Vector3(1, (top - new_bottom) / leaf_size.y, 1); leaf.position.y = new_bottom
	report["door_leaf"] = {"bottom_before": bottom, "bottom_after": leaf.position.y, "scale_y": leaf.scale.y, "sill": toe_y}
	house.set_meta("houses_fix_cd", {"date": "2026-09-25", "script": "res://tools/houses_fix/house_c_d/fix_house.gd", "pristine_sha256": source_hash})
	var packed := PackedScene.new()
	check(packed.pack(house) == OK, "pack")
	var outputs: Array = TARGETS[id]
	if arg("out") != "": outputs = [arg("out")]   # dry run: write elsewhere, leave the game's scenes alone
	for path: String in outputs:
		check(ResourceSaver.save(packed, path) == OK, "save " + path)
	house.free()
	# ---- verify the saved scene: door panel mapping key, nodes, rect sanity
	var replacements: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://world/buildings/door_panels/replacements.json"))
	var saved: Node3D = (ResourceLoader.load(outputs[0], "", ResourceLoader.CACHE_MODE_REPLACE_DEEP) as PackedScene).instantiate()
	var art := saved.get_node("FrontDoor/OriginalDoorArtwork") as MeshInstance3D
	var key: String = TARGETS[id][0] + "::" + art.mesh.resource_path.get_slice("::", 1)
	check(replacements.has(key), "door panel replacement key survives re-save: " + art.mesh.resource_path)
	check(saved.get_node_or_null("FittedFloor") != null and saved.find_children("FloorSlab*", "", false, false).is_empty(), "one fitted floor, no rect slabs")
	check(saved.get_node_or_null("InnerThresholdRamp") == null, "no node HouseInterior would dress")
	check(saved.get_node_or_null("Baseboard") != null, "baseboard present")
	saved.free()
	var f := FileAccess.open("res://captures/houses_fix/house_c_d/fix_%s.json" % id, FileAccess.WRITE)
	f.store_string(JSON.stringify(report, "\t")); f.close()
	print("FIX REPORT ", JSON.stringify(report))
	print("HOUSE FIX PASS" if failures.is_empty() else "HOUSE FIX FAIL " + str(failures))
	quit(0 if failures.is_empty() else 1)

# ------------------------------------------------------------------ region
func cell_centre(c: Vector2i) -> Vector2: return Vector2((c.x + .5) * STEP, (c.y + .5) * STEP)
func cell_of(p: Vector2) -> Vector2i: return Vector2i(floori(p.x / STEP), floori(p.y / STEP))

func measure_region(house: Node3D, fy: float, floors: Array[Rect2]) -> Dictionary:
	var space := house.get_world_3d().direct_space_state
	var h := fy + .015
	var region := {}
	var frontier: Array[Vector2i] = []
	for rect in floors:
		var seed := cell_of(rect.get_center())
		if not region.has(seed) and enclosed(space, house, cell_centre(seed), h):
			region[seed] = true; frontier.append(seed)
	var rejected := {}
	while not frontier.is_empty():
		var c: Vector2i = frontier.pop_back()
		for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n := c + d
			if region.has(n) or rejected.has(n): continue
			var a := house.to_global(Vector3(cell_centre(c).x, h, cell_centre(c).y))
			var b := house.to_global(Vector3(cell_centre(n).x, h, cell_centre(n).y))
			var q := PhysicsRayQueryParameters3D.create(a, b, VIS); q.hit_back_faces = true
			if not space.intersect_ray(q).is_empty(): continue   # a wall between: n may be reached another way
			if not enclosed(space, house, cell_centre(n), h): rejected[n] = true; continue
			region[n] = true; frontier.append(n)
	return region

## Walled in: all four horizontal rays meet a visible surface within 16 m. (No roof ray: the
## roof valley seam of D lets one through, which cut a sliver out of the middle of the room.)
func enclosed(space: PhysicsDirectSpaceState3D, house: Node3D, p: Vector2, h: float) -> bool:
	var from := house.to_global(Vector3(p.x, h, p.y))
	var hits := 0
	for d: Vector3 in [Vector3.RIGHT, Vector3.LEFT, Vector3.FORWARD, Vector3.BACK]:
		var q := PhysicsRayQueryParameters3D.create(from, from + house.global_basis * d * 1.6, VIS); q.hit_back_faces = true
		if not space.intersect_ray(q).is_empty(): hits += 1
	return hits == 4

## Cells walled in by the room on every side (posts, sampling specks). Specks under 50 cells
## (30 cm²) join the room; bigger ones (posts) stay out of it so the baseboard wraps them, and
## are returned so the planks still run on under them.
func fill_holes(region: Dictionary) -> Dictionary:
	var lo := Vector2i(1 << 30, 1 << 30); var hi := -lo
	for c: Vector2i in region: lo = Vector2i(mini(lo.x, c.x), mini(lo.y, c.y)); hi = Vector2i(maxi(hi.x, c.x), maxi(hi.y, c.y))
	lo -= Vector2i(2, 2); hi += Vector2i(2, 2)
	var seen := {}; var big := {}; var merged := 0
	for z in range(lo.y, hi.y + 1):
		for x in range(lo.x, hi.x + 1):
			var start := Vector2i(x, z)
			if region.has(start) or seen.has(start): continue
			var stack: Array[Vector2i] = [start]; seen[start] = true
			var members: Array[Vector2i] = []; var border := false
			while not stack.is_empty():
				var c: Vector2i = stack.pop_back(); members.append(c)
				if c.x == lo.x or c.y == lo.y or c.x == hi.x or c.y == hi.y: border = true
				for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var n := c + d
					if n.x < lo.x or n.y < lo.y or n.x > hi.x or n.y > hi.y or region.has(n) or seen.has(n): continue
					seen[n] = true; stack.append(n)
			if border: continue
			if members.size() < 50:
				for c: Vector2i in members: region[c] = true
				merged += members.size()
			else:
				for c: Vector2i in members: big[c] = true
	print("holes: merged ", merged, " speck cells, kept ", big.size(), " cells under posts")
	return big

# ------------------------------------------------------------------ floor
func build_floor(region: Dictionary, ramp: Rect2, fy: float, material: Material) -> MeshInstance3D:
	var covered := {}
	for c: Vector2i in region:
		if not ramp.has_point(cell_centre(c)): covered[c] = true
	var lo := Vector2i(1 << 30, 1 << 30); var hi := -lo
	for c: Vector2i in covered: lo = Vector2i(mini(lo.x, c.x), mini(lo.y, c.y)); hi = Vector2i(maxi(hi.x, c.x), maxi(hi.y, c.y))
	var corner := func(v: Vector2i) -> Vector3:
		var q := Vector2(v) * STEP
		return Vector3(q.x, floor_height(q), q.y)
	var flat := {}
	for c: Vector2i in covered:
		var level := true
		for o: Vector2i in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
			if absf((corner.call(c + o) as Vector3).y - fy) > 1e-6: level = false
		if level: flat[c] = true
	var top := SurfaceTool.new(); top.begin(Mesh.PRIMITIVE_TRIANGLES)
	var sloped_faces := PackedVector3Array()
	for z in range(lo.y, hi.y + 1):
		var x := lo.x
		while x <= hi.x:
			var c := Vector2i(x, z)
			if not covered.has(c): x += 1; continue
			if not flat.has(c):
				# one quad with its own corner heights (sunken landing)
				var q00: Vector3 = corner.call(c); var q10: Vector3 = corner.call(c + Vector2i(1, 0))
				var q11: Vector3 = corner.call(c + Vector2i(1, 1)); var q01: Vector3 = corner.call(c + Vector2i(0, 1))
				var n := (q01 - q00).cross(q10 - q00).normalized()
				if n.y < 0: n = -n
				# wound to face up: the pony's ground probe does not see back faces
				for p: Vector3 in [q00, q11, q10, q00, q01, q11]:
					top.set_normal(n); top.set_uv(Vector2(p.x, p.z) * 6.0); top.add_vertex(p); sloped_faces.append(p)
				x += 1; continue
			var start := x
			while flat.has(Vector2i(x, z)): x += 1
			var x0 := start * STEP; var x1 := x * STEP; var z0 := z * STEP; var z1 := (z + 1) * STEP
			for p: Vector3 in [Vector3(x0, fy, z0), Vector3(x1, fy, z0), Vector3(x1, fy, z1), Vector3(x0, fy, z0), Vector3(x1, fy, z1), Vector3(x0, fy, z1)]:
				top.set_normal(Vector3.UP); top.set_uv(Vector2(p.x, p.z) * 6.0); top.add_vertex(p)
	# Apron: every outer edge of the plank sheet drops to the house base as a stone side, so no
	# gap under a wall (or beside a sunken ramp) opens onto the ground.
	var sides := {Vector2i(1, 0): [Vector2i(1, 0), Vector2i(1, 1)], Vector2i(-1, 0): [Vector2i(0, 1), Vector2i(0, 0)], Vector2i(0, 1): [Vector2i(1, 1), Vector2i(0, 1)], Vector2i(0, -1): [Vector2i(0, 0), Vector2i(1, 0)]}
	for c: Vector2i in covered:
		for d: Vector2i in sides:
			if covered.has(c + d): continue
			var a: Vector3 = corner.call(c + sides[d][0]); var b: Vector3 = corner.call(c + sides[d][1])
			var n := Vector3(d.x, 0, d.y)
			for p: Vector3 in [a, b, Vector3(b.x, 0, b.z), a, Vector3(b.x, 0, b.z), Vector3(a.x, 0, a.z)]:
				top.set_normal(n); top.set_uv(Vector2(p.x + p.z, p.y) * 6.0); top.add_vertex(p)
	top.index()
	var mesh := top.commit()
	mesh.surface_set_material(0, material)
	var node := MeshInstance3D.new(); node.name = "FittedFloor"; node.mesh = mesh
	node.set_script(FITTED_FLOOR)
	node.layers = 1 << 16
	node.set_meta("houses_fix_cd", "fitted to the measured room; replaces the rect slabs and edge fill")
	# Collision: boxes (greedy rectangles of the level cells), top at the floor. Boxes, not a
	# triangle mesh: HouseInterior._clear_ramp deletes concave triangles reaching into the
	# entrance ramp's volume, and long plank rows next to the door would lose whole strips.
	# The sunken landing (inside the door, clear of the outside ramp) is a triangle mesh.
	var body := StaticBody3D.new(); body.name = "FittedFloorCollision"
	var used := {}
	var boxes := 0
	for z in range(lo.y, hi.y + 1):
		for x in range(lo.x, hi.x + 1):
			var c := Vector2i(x, z)
			if not flat.has(c) or used.has(c): continue
			var x1 := x
			while flat.has(Vector2i(x1 + 1, z)) and not used.has(Vector2i(x1 + 1, z)): x1 += 1
			var z1 := z
			while true:
				var ok := true
				for xx in range(x, x1 + 1):
					if not flat.has(Vector2i(xx, z1 + 1)) or used.has(Vector2i(xx, z1 + 1)): ok = false; break
				if not ok: break
				z1 += 1
			for zz in range(z, z1 + 1):
				for xx in range(x, x1 + 1): used[Vector2i(xx, zz)] = true
			# 2 mm overlap between neighbouring boxes: no seam for a ray (or a hoof) to slip through
			var shape := BoxShape3D.new(); shape.size = Vector3((x1 - x + 1) * STEP + .0004, .01, (z1 - z + 1) * STEP + .0004)
			var holder := CollisionShape3D.new(); holder.name = "Box%d" % boxes; holder.shape = shape
			holder.position = Vector3((x + x1 + 1) * .5 * STEP, fy - .005, (z + z1 + 1) * .5 * STEP)
			body.add_child(holder); boxes += 1
	if not sloped_faces.is_empty():
		# welded (indexed) like the visible mesh, so no ray slips along a shared cell edge
		var weld := SurfaceTool.new(); weld.begin(Mesh.PRIMITIVE_TRIANGLES)
		for p: Vector3 in sloped_faces: weld.add_vertex(p)
		weld.index()
		var shape := weld.commit().create_trimesh_shape() as ConcavePolygonShape3D; shape.backface_collision = true
		var holder := CollisionShape3D.new(); holder.name = "SunkenLanding"; holder.shape = shape
		body.add_child(holder)
	node.add_child(body)
	node.set_meta("collision_boxes", boxes)
	return node

# ------------------------------------------------------------------ baseboard
## Directed boundary edges (region on the left), linked into loops of grid vertices.
func boundary_loops(region: Dictionary) -> Array:
	var sides := {Vector2i(1, 0): [Vector2i(1, 0), Vector2i(1, 1)], Vector2i(-1, 0): [Vector2i(0, 1), Vector2i(0, 0)], Vector2i(0, 1): [Vector2i(1, 1), Vector2i(0, 1)], Vector2i(0, -1): [Vector2i(0, 0), Vector2i(1, 0)]}
	var out := {}   # start vertex -> Array of end vertices
	for c: Vector2i in region:
		for d: Vector2i in sides:
			if region.has(c + d): continue
			var a: Vector2i = c + sides[d][0]; var b: Vector2i = c + sides[d][1]
			if not out.has(a): out[a] = []
			out[a].append(b)
	var loops := []
	while not out.is_empty():
		var start: Vector2i = out.keys()[0]
		var loop: Array[Vector2i] = [start]
		var at := start
		while true:
			var nexts: Array = out[at]
			var nxt: Vector2i = nexts.pop_back()
			if nexts.is_empty(): out.erase(at)
			if nxt == start: break
			loop.append(nxt); at = nxt
			if not out.has(at): break
		if loop.size() >= 4: loops.append(loop)
	return loops

func simplify(points: Array, tol: float) -> Array:
	if points.size() < 3: return points
	var a: Vector2 = points[0]; var b: Vector2 = points[-1]
	var worst := -1.0; var at := -1
	for i in range(1, points.size() - 1):
		var d := Geometry2D.get_closest_point_to_segment(points[i], a, b).distance_to(points[i])
		if d > worst: worst = d; at = i
	if worst <= tol: return [a, b]
	var left := simplify(points.slice(0, at + 1), tol)
	var right := simplify(points.slice(at), tol)
	return left.slice(0, left.size() - 1) + right

func build_baseboard(loops: Array, keep_clear: Array, fy: float) -> Dictionary:
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var faces := PackedVector3Array()
	var depth := .0015
	var runs := 0; var length := 0.0
	for loop: Array in loops:
		# Start at a corner so the first and last runs are real wall runs.
		var pts: Array = []
		for v: Vector2i in loop: pts.append(Vector2(v) * STEP)
		var k0 := 0
		for i in pts.size():
			var p0: Vector2 = pts[(i - 1 + pts.size()) % pts.size()]; var p1: Vector2 = pts[i]; var p2: Vector2 = pts[(i + 1) % pts.size()]
			if absf((p1 - p0).normalized().dot((p2 - p1).normalized())) < .5: k0 = i; break
		var ring := pts.slice(k0) + pts.slice(0, k0 + 1)
		var simple := simplify(ring, STEP * 1.01)
		for i in simple.size() - 1:
			var a: Vector2 = simple[i]; var b: Vector2 = simple[i + 1]
			var along := b - a
			if along.length() < STEP * .5: continue
			var mid := (a + b) * .5
			var inward := Vector2(-along.y, along.x).normalized()   # region lies left of the directed edge
			# No board across the doorway or over the sunken inner ramp.
			var blocked := false
			for r: Rect2 in keep_clear:
				if r.size != Vector2.ZERO and (r.grow(.004).has_point(mid) or r.grow(.004).has_point(mid + inward * .01)): blocked = true
			if blocked: continue
			var pieces := maxi(1, ceili(along.length() / .01))
			for k in pieces:
				var pa := a.lerp(b, float(k) / pieces); var pb := a.lerp(b, float(k + 1) / pieces)
				var fa := pa + inward * depth; var fb := pb + inward * depth
				var ya := floor_height(fa); var yb := floor_height(fb)
				var a0 := ya - .004; var a1 := ya + .009; var b0 := yb - .004; var b1 := yb + .009
				var n3 := Vector3(inward.x, 0, inward.y)
				var quads := [
					[Vector3(fa.x, a0, fa.y), Vector3(fb.x, b0, fb.y), Vector3(fb.x, b1, fb.y), Vector3(fa.x, a1, fa.y), n3],
					[Vector3(fa.x, a1, fa.y), Vector3(fb.x, b1, fb.y), Vector3(pb.x, b1, pb.y), Vector3(pa.x, a1, pa.y), Vector3.UP],
				]
				if k == 0: quads.append([Vector3(pa.x, a0, pa.y), Vector3(fa.x, a0, fa.y), Vector3(fa.x, a1, fa.y), Vector3(pa.x, a1, pa.y), Vector3(-along.x, 0, -along.y).normalized()])
				if k == pieces - 1: quads.append([Vector3(fb.x, b0, fb.y), Vector3(pb.x, b0, pb.y), Vector3(pb.x, b1, pb.y), Vector3(fb.x, b1, fb.y), Vector3(along.x, 0, along.y).normalized()])
				for q: Array in quads:
					for j in [0, 1, 2, 0, 2, 3]:
						st.set_normal(q[4]); st.add_vertex(q[j])
				for j in [0, 1, 2, 0, 2, 3]: faces.append(quads[0][j])
				for j in [0, 1, 2, 0, 2, 3]: faces.append(quads[1][j])
			runs += 1; length += along.length()
	st.index()
	var trim := StandardMaterial3D.new(); trim.albedo_texture = WOOD; trim.uv1_triplanar = true; trim.uv1_world_triplanar = true
	trim.uv1_scale = Vector3.ONE / 3.5; trim.cull_mode = BaseMaterial3D.CULL_DISABLED; trim.roughness = .85
	trim.albedo_color = Color(.61, .49, .38)
	var node := MeshInstance3D.new(); node.name = "Baseboard"; node.mesh = st.commit(); node.material_override = trim
	node.layers = 1 << 16; node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.set_meta("houses_fix_cd", "baseboard along the measured room walls; closes the slit at the wall feet")
	var body := StaticBody3D.new(); body.name = "BaseboardCollision"
	var shape := ConcavePolygonShape3D.new(); shape.backface_collision = true; shape.set_faces(faces)
	var holder := CollisionShape3D.new(); holder.name = "CollisionShape3D"; holder.shape = shape
	body.add_child(holder); node.add_child(body)
	return {"mesh": node, "runs": runs, "length": length}

# ------------------------------------------------------------------ exterior cleanup
## Flat triangles at floor level inside the rooms belong to the generated model's own interior
## base, now under (or poking through) the fitted floor.
func clean_exterior(house: Node3D, exterior: MeshInstance3D, xf: Transform3D, region: Dictionary, fy: float, edits: Dictionary) -> Dictionary:
	var old := exterior.mesh
	var arrays := old.surface_get_arrays(0)
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var kept := PackedInt32Array(); var floor_bits := 0; var dropped_boxes := 0
	for t in range(0, idx.size(), 3):
		var a: Vector3 = xf * v[idx[t]]; var b: Vector3 = xf * v[idx[t + 1]]; var c: Vector3 = xf * v[idx[t + 2]]
		var n := (b - a).cross(c - a)
		var m := (a + b + c) / 3.0
		# Judged by the centroid: the generated interior base is a few huge triangles whose
		# corners sit inside the walls.
		var inside := region.has(cell_of(Vector2(m.x, m.z)))
		var flat := n.length_squared() > 0.0 and absf(n.normalized().y) > .9
		if inside and flat and m.y > fy - .03 and m.y < fy + .015:
			floor_bits += 1; continue
		# Any triangle lying wholly at floor level (within -30/+15 cm) with its centroid in the
		# room: walls rise far above that. D has a 10 m needle ribbon, 5 cm tall, across its main
		# room just under the planks; over the sunken landing it stood up as a dark line and lip.
		if inside and maxf(a.y, maxf(b.y, c.y)) < fy + .015 and minf(a.y, minf(b.y, c.y)) > fy - .03:
			floor_bits += 1; continue
		var drop := false
		for box: AABB in edits.get("drop", []):
			if box.has_point(m): drop = true
		if drop: dropped_boxes += 1; continue
		kept.append_array([idx[t], idx[t + 1], idx[t + 2]])
	if floor_bits + dropped_boxes == 0: return {}
	arrays[Mesh.ARRAY_INDEX] = kept
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, old.surface_get_material(0))
	mesh.resource_name = old.resource_name
	# Every node drawing the old mesh (the room-face copy too) draws the edited one.
	for other: MeshInstance3D in house.find_children("*", "MeshInstance3D", true, false):
		if other.mesh == old: other.mesh = mesh
	for holder: CollisionShape3D in exterior.find_children("*", "CollisionShape3D", true, false):
		if holder.shape is ConcavePolygonShape3D:
			var shape := ConcavePolygonShape3D.new(); shape.set_faces(mesh.get_faces()); holder.shape = shape
	return {"floor_level_triangles_removed": floor_bits, "box_triangles_removed": dropped_boxes}

# ------------------------------------------------------------------ rects
## Pull every rect side that is not the shared room edge inward until 90 % of the row just
## inside it is room. A strip given up this way that is itself room over a long run becomes
## an extra rect (C's back-right alcove), so beds and HOUSE membership still reach it.
func fit_rects(floors: Array[Rect2], region: Dictionary) -> Array[Rect2]:
	var shared := Rect2()
	if floors.size() >= 2: shared = floors[0].grow(.003).intersection(floors[1].grow(.003))
	var out: Array[Rect2] = []
	var extra: Array[Rect2] = []
	for rect: Rect2 in floors:
		var r := rect
		var original := rect
		var sides: Array[String] = []
		for side in ["x0", "x1", "z0", "z1"]:
			var edge_line: float = {"x0": r.position.x, "x1": r.end.x, "z0": r.position.y, "z1": r.end.y}[side]
			var on_shared: bool = shared.size != Vector2.ZERO and (absf(edge_line - (shared.get_center().y if shared.size.x > shared.size.y else shared.get_center().x)) < .004) \
				and ((side.begins_with("z") and shared.size.x > shared.size.y) or (side.begins_with("x") and shared.size.x <= shared.size.y))
			if not on_shared: sides.append(side)
		# Always pull in the worst side first: one bad corner must not eat a whole good side.
		for step in 400:
			var worst := ""; var worst_cov := .9
			for side in sides:
				var cov := coverage(r, side, region)
				if cov < worst_cov: worst_cov = cov; worst = side
			if worst == "": break
			r = shrink(r, worst, STEP)
		for side in sides:
			var edge_before: float = {"x0": original.position.x, "x1": original.end.x, "z0": original.position.y, "z1": original.end.y}[side]
			var edge_after: float = {"x0": r.position.x, "x1": r.end.x, "z0": r.position.y, "z1": r.end.y}[side]
			if absf(edge_after - edge_before) < STEP * .5: continue
			var before := original
			var strip := strip_of(before, r, side)
			# the strip only spans the kept rect along its length
			if side.begins_with("z"): strip = Rect2(r.position.x, strip.position.y, r.size.x, strip.size.y)
			else: strip = Rect2(strip.position.x, r.position.y, strip.size.x, r.size.y)
			var run := best_run(strip, side, region)
			if run.get_area() > 0.0: extra.append(run)
		out.append(r)
	out.append_array(extra)
	return out

func shrink(r: Rect2, side: String, d: float) -> Rect2:
	match side:
		"x0": return Rect2(r.position.x + d, r.position.y, r.size.x - d, r.size.y)
		"x1": return Rect2(r.position.x, r.position.y, r.size.x - d, r.size.y)
		"z0": return Rect2(r.position.x, r.position.y + d, r.size.x, r.size.y - d)
	return Rect2(r.position.x, r.position.y, r.size.x, r.size.y - d)

func coverage(r: Rect2, side: String, region: Dictionary) -> float:
	var n := 0; var hit := 0
	var along_x := side.begins_with("z")
	var line: float = {"x0": r.position.x + STEP * .5, "x1": r.end.x - STEP * .5, "z0": r.position.y + STEP * .5, "z1": r.end.y - STEP * .5}[side]
	var from := r.position.x if along_x else r.position.y
	var to := r.end.x if along_x else r.end.y
	var t := from + STEP * .5
	while t < to:
		var p := Vector2(t, line) if along_x else Vector2(line, t)
		n += 1; if region.has(cell_of(p)): hit += 1
		t += STEP
	return float(hit) / maxf(n, 1)

func strip_of(before: Rect2, after: Rect2, side: String) -> Rect2:
	match side:
		"x0": return Rect2(before.position.x, before.position.y, after.position.x - before.position.x, before.size.y)
		"x1": return Rect2(after.end.x, before.position.y, before.end.x - after.end.x, before.size.y)
		"z0": return Rect2(before.position.x, before.position.y, before.size.x, after.position.y - before.position.y)
	return Rect2(before.position.x, after.end.y, before.size.x, before.end.y - after.end.y)

## Longest run along the strip whose whole depth is room: at least 1 m long and 30 cm deep.
func best_run(strip: Rect2, side: String, region: Dictionary) -> Rect2:
	var along_x := side.begins_with("z")
	var depth := strip.size.y if along_x else strip.size.x
	if depth < .03: return Rect2()
	var from := strip.position.x if along_x else strip.position.y
	var to := strip.end.x if along_x else strip.end.y
	var best := Vector2(); var run_start := NAN
	var t := from + STEP * .5
	while t < to + STEP:
		var ok := t < to
		if ok:
			var hit := 0; var n := 0
			var s := (strip.position.y if along_x else strip.position.x) + STEP * .5
			var s_end := strip.end.y if along_x else strip.end.x
			while s < s_end:
				n += 1; if region.has(cell_of(Vector2(t, s) if along_x else Vector2(s, t))): hit += 1
				s += STEP
			ok = n > 0 and float(hit) / n >= .95
		if ok and is_nan(run_start): run_start = t - STEP * .5
		if not ok and not is_nan(run_start):
			if t - STEP * .5 - run_start > best.y - best.x: best = Vector2(run_start, t - STEP * .5)
			run_start = NAN
		t += STEP
	if best.y - best.x < .1: return Rect2()
	# 2 cm off both ends: the ends meet walls.
	best = Vector2(best.x + .002, best.y - .002)
	return Rect2(best.x, strip.position.y, best.y - best.x, strip.size.y) if along_x else Rect2(strip.position.x, best.x, strip.size.x, best.y - best.x)

func save_region_png(id: String, region: Dictionary, floors: Array[Rect2]) -> void:
	var lo := Vector2i(1 << 30, 1 << 30); var hi := -lo
	for c: Vector2i in region: lo = Vector2i(mini(lo.x, c.x), mini(lo.y, c.y)); hi = Vector2i(maxi(hi.x, c.x), maxi(hi.y, c.y))
	lo -= Vector2i(8, 8); hi += Vector2i(8, 8)
	var img := Image.create(hi.x - lo.x + 1, hi.y - lo.y + 1, false, Image.FORMAT_RGB8)
	img.fill(Color(.1, .1, .1))
	for c: Vector2i in region: img.set_pixel(c.x - lo.x, c.y - lo.y, Color(.75, .6, .4))
	for r: Rect2 in floors:
		for x in range(cell_of(r.position).x, cell_of(r.end).x + 1):
			for z in [cell_of(r.position).y, cell_of(r.end).y]:
				if x - lo.x >= 0 and x - lo.x < img.get_width() and z - lo.y >= 0 and z - lo.y < img.get_height(): img.set_pixel(x - lo.x, z - lo.y, Color(0, .6, 1))
		for z in range(cell_of(r.position).y, cell_of(r.end).y + 1):
			for x in [cell_of(r.position).x, cell_of(r.end).x]:
				if x - lo.x >= 0 and x - lo.x < img.get_width() and z - lo.y >= 0 and z - lo.y < img.get_height(): img.set_pixel(x - lo.x, z - lo.y, Color(0, .6, 1))
	img.resize(img.get_width() * 3, img.get_height() * 3, Image.INTERPOLATE_NEAREST)
	img.save_png("res://captures/houses_fix/house_c_d/region_%s.png" % id)

# ------------------------------------------------------------------ plinth restore
## tools/buildings/split_door.gd trim_stoop removes everything below the door sill (+8 mm) in
## front of the ramp's landing line across x = center +- width (the ramp's full width to each
## side, not half). That cut the stone plinth away on both sides of the entrance ramp: slits
## beside C's ramp, and along D's wing a 52 cm gap under a floating stone course where the
## floor's grey side showed. Put back the source model's own triangles from that volume beside
## the ramp (same clip planes, original UVs), and over the ramp's edges up to the door frame the
## plinth face only. Ported from tools/houses_fix/house_a_b/cleanup.gd (House B), plus the
## browser import scale (House D is imported at 1.45).
func restore_plinth(id: String, house: Node3D, exterior: MeshInstance3D) -> int:
	var sp := (house.get_node("StairBrush/RampAndLanding") as CollisionShape3D).shape as ConvexPolygonShape3D
	var pts := sp.points
	var cx := (pts[0].x + pts[5].x) * .5; var width := absf(pts[5].x - pts[0].x); var landing_z := pts[2].z
	var bottom := (house.get_node("FrontDoor") as Node3D).position.y   # opening.bottom (before the leaf is raised)
	var trim := [[Vector3.RIGHT, cx - width], [Vector3.LEFT, -cx - width], [Vector3.DOWN, -bottom - .008], [Vector3.BACK, landing_z]]
	var lo_x := cx - width * .5; var hi_x := cx + width * .5
	var specs: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tools/buildings/browser_houses.json"))
	var import_scale := float((specs[id] as Dictionary).get("import_scale", 1.0))
	var doc := GLTFDocument.new(); var state := GLTFState.new()
	check(doc.append_from_file(str(house.get_meta("browser_source")), state) == OK, "source model loads")
	var src := doc.generate_scene(state)
	var restored: Array = []
	for mi: MeshInstance3D in src.find_children("*", "MeshInstance3D", true, false):
		var xf := Transform3D.IDENTITY
		var n: Node = mi
		while n != src and n != null:
			if n is Node3D: xf = (n as Node3D).transform * xf
			n = n.get_parent()
		xf = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * import_scale), Vector3.ZERO) * xf
		var nb := xf.basis.inverse().transposed()
		for surf in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(surf)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]; var nrm: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
			var uv: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
			var idx = arr[Mesh.ARRAY_INDEX]
			if idx == null or (idx as PackedInt32Array).is_empty(): idx = PackedInt32Array(range(v.size()))
			for t in range(0, idx.size(), 3):
				var poly: Array = []
				for k in 3:
					var i: int = idx[t + k]
					poly.append({"p": xf * v[i], "n": (nb * nrm[i]).normalized(), "uv": uv[i]})
				for plane: Array in trim:
					if poly.size() < 3: break
					poly = _divide(poly, plane[0], plane[1])[0]
				if poly.size() < 3: continue
				var sides: Array = (EDITS.get(id, {}) as Dictionary).get("plinth_sides", ["left", "right"])
				if "left" in sides:
					var piece: Array = _divide(poly, Vector3.LEFT, -lo_x)[0]
					if piece.size() >= 3: restored.append(piece)
				if "right" in sides:
					var piece: Array = _divide(poly, Vector3.RIGHT, hi_x)[0]
					if piece.size() >= 3: restored.append(piece)
				# (House B's cleanup also restores the plinth face over the ramp's edges up to the
				# door frame, bounded by the frontmost restored point. With C's and D's wings that
				# bound lies far forward and brought the old stoop steps back, so not here.)
	src.free()
	return _append_polys(house, exterior, restored)

## Split a polygon (dicts p, n, uv) by the plane n.p >= d: [inside part, outside part].
static func _divide(poly: Array, n: Vector3, d: float) -> Array:
	var keep: Array = []; var rest: Array = []
	for i in poly.size():
		var a: Dictionary = poly[i]; var b: Dictionary = poly[(i + 1) % poly.size()]
		var da := n.dot(a.p) - d; var db := n.dot(b.p) - d
		if da >= 0: keep.append(a)
		else: rest.append(a)
		if (da >= 0) != (db >= 0):
			var t := da / (da - db)
			var v := {"p": (a.p as Vector3).lerp(b.p, t), "n": (a.n as Vector3).lerp(b.n, t).normalized(), "uv": (a.uv as Vector2).lerp(b.uv, t)}
			keep.append(v); rest.append(v)
	return [keep, rest]

## Append polygons to the Exterior's single surface (winding as interior_lighting.align_winding
## leaves it, tangents from UVs) and rebuild its collision.
func _append_polys(house: Node3D, exterior: MeshInstance3D, polys: Array) -> int:
	if polys.is_empty(): return 0
	var old := exterior.mesh
	var arrays := old.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var index: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var tangents = arrays[Mesh.ARRAY_TANGENT]
	for slot in [Mesh.ARRAY_TEX_UV2, Mesh.ARRAY_COLOR, Mesh.ARRAY_BONES, Mesh.ARRAY_WEIGHTS, Mesh.ARRAY_CUSTOM0]:
		check(arrays[slot] == null or arrays[slot].is_empty(), "Exterior has no extra vertex channel %d" % slot)
	var added := 0
	for poly: Array in polys:
		for j in range(1, poly.size() - 1):
			var tri: Array = [poly[0], poly[j], poly[j + 1]]
			var a: Vector3 = tri[0].p; var b: Vector3 = tri[1].p; var c: Vector3 = tri[2].p
			var n: Vector3 = (tri[0].n as Vector3) + (tri[1].n as Vector3) + (tri[2].n as Vector3)
			if (b - a).cross(c - a).length_squared() < 1e-14: continue
			if -(b - a).cross(c - a).dot(n) < 0: tri = [tri[0], tri[2], tri[1]]
			var p0: Vector3 = tri[0].p; var p1: Vector3 = tri[1].p; var p2: Vector3 = tri[2].p
			var t0: Vector2 = tri[0].uv; var t1: Vector2 = tri[1].uv; var t2: Vector2 = tri[2].uv
			var e1 := p1 - p0; var e2 := p2 - p0; var d1 := t1 - t0; var d2 := t2 - t0
			var det := d1.x * d2.y - d2.x * d1.y
			var tan_dir := (e1 * d2.y - e2 * d1.y) / det if absf(det) > 1e-12 else e1
			var bit_dir := (e2 * d1.x - e1 * d2.x) / det if absf(det) > 1e-12 else e2
			for vtx: Dictionary in tri:
				var vn: Vector3 = vtx.n
				var tt := (tan_dir - vn * vn.dot(tan_dir))
				tt = tt.normalized() if tt.length_squared() > 1e-16 else vn.cross(Vector3.UP if absf(vn.y) < .9 else Vector3.RIGHT).normalized()
				index.append(verts.size())
				verts.append(vtx.p); normals.append(vn); uvs.append(vtx.uv)
				if tangents != null and not tangents.is_empty():
					tangents.append_array(PackedFloat32Array([tt.x, tt.y, tt.z, -1.0 if vn.cross(tt).dot(bit_dir) < 0 else 1.0]))
			added += 1
	arrays[Mesh.ARRAY_VERTEX] = verts; arrays[Mesh.ARRAY_NORMAL] = normals; arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = index
	if tangents != null and not tangents.is_empty(): arrays[Mesh.ARRAY_TANGENT] = tangents
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, old.surface_get_material(0))
	mesh.resource_name = old.resource_name
	for other: MeshInstance3D in house.find_children("*", "MeshInstance3D", true, false):
		if other.mesh == old: other.mesh = mesh
	for holder: CollisionShape3D in exterior.find_children("*", "CollisionShape3D", true, false):
		if holder.shape is ConcavePolygonShape3D:
			var shape := ConcavePolygonShape3D.new(); shape.set_faces(mesh.get_faces()); holder.shape = shape
	return added

## Average colour of the plinth (upright Exterior faces below the floor) in the house's own
## texture: the stone the floor's side apron is painted, so where it shows outside it reads as
## foundation, not as a grey stripe.
func plinth_color(house: Node3D, fy: float) -> Color:
	var exterior: MeshInstance3D = null
	for m: MeshInstance3D in house.find_children("Exterior", "MeshInstance3D", true, false): exterior = m
	var mat := exterior.mesh.surface_get_material(0) as BaseMaterial3D
	if mat == null or mat.albedo_texture == null: return Color(.62, .58, .56)
	var img := mat.albedo_texture.get_image()
	if img.is_compressed(): img.decompress()
	var arr := exterior.mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]; var uv: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	var sum := Color(0, 0, 0, 0); var n := 0
	for t in range(0, idx.size(), 3):
		var a := v[idx[t]]; var b := v[idx[t + 1]]; var c := v[idx[t + 2]]
		var m := (a + b + c) / 3.0
		var nn := (b - a).cross(c - a)
		if nn.length_squared() == 0.0 or absf(nn.normalized().y) > .3 or m.y < .005 or m.y > fy - .005: continue
		var u := (uv[idx[t]] + uv[idx[t + 1]] + uv[idx[t + 2]]) / 3.0
		var px := Vector2i(clampi(int(fposmod(u.x, 1.0) * img.get_width()), 0, img.get_width() - 1), clampi(int(fposmod(u.y, 1.0) * img.get_height()), 0, img.get_height() - 1))
		sum += img.get_pixelv(px); n += 1
	if n == 0: return Color(.62, .58, .56)
	var col := sum / n; col.a = 1.0
	print("plinth colour from ", n, " faces: ", col)
	return col
