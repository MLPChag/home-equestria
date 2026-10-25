extends RefCounted
## Offline metre-scale tower furnishing and connected stair geometry.
const KIT := preload("res://world/buildings/golden_oak/furniture_kit.gd")
const ARCH := preload("res://world/buildings/golden_oak/furniture_architecture.gd")
const SLAB_UNION := preload("res://world/buildings/sugarcube/stair_union.gd")
const FLOOR := 12.7
const HALF_WIDTH := .9
const ROOM_RIM := [Vector2(-2.208057,-1.414685),Vector2(-1.735912,-2.310021),Vector2(-1.029301,-2.908266),Vector2(-0.195791,-3.118341),Vector2(0.637717,-2.908266),Vector2(1.344328,-2.310021),Vector2(1.816472,-1.414685),Vector2(1.982268,-0.358564),Vector2(1.816471,0.697556),Vector2(1.344327,1.592891),Vector2(0.637714,2.191135),Vector2(-0.195791,2.401211),Vector2(-1.029298,2.191135),Vector2(-1.735912,1.592891),Vector2(-2.208055,0.697555),Vector2(-2.373850,-0.358565)]
static func stair_path() -> Array[Vector3]:
	var path: Array[Vector3] = [Vector3(2.3,.90,-2.29),Vector3(.54865,2.1,-2.29),Vector3(-.4,2.75,-2.29),Vector3(-1.3,2.75,-2.0)]
	var height := 2.75
	for flight in 6:
		var x := -1.3 if flight % 2 == 0 else .75
		var front_to_back := flight % 2 == 0
		path.append(Vector3(x,height,-1.1 if front_to_back else .9))
		height += 1.27
		var front := -3.0 if flight == 5 else -2.0
		path.append(Vector3(x,height,.9 if front_to_back else -1.1))
		path.append(Vector3(x,height,1.8 if front_to_back else front))
		if flight < 5: path.append(Vector3(.75 if front_to_back else -1.3,height,1.8 if front_to_back else -2.0))
	path.append_array([Vector3(-1.12,height,-3.0),Vector3(-1.12,height,-2.1),Vector3(-1.12,FLOOR,1.25),Vector3(-1.12,FLOOR,1.65),Vector3(.65,FLOOR,1.65)])
	return path
## Complete connected indoor route, shared by the packed adapter and physical probes.
static func indoor_path() -> Array[Vector3]:
	var path: Array[Vector3] = [Vector3(.12,.90,1.6),Vector3(.12,.90,.62),Vector3(4.13,.90,.62),Vector3(4.13,.90,-2.29)]
	path.append_array(stair_path())
	return path
static func build(parent: Node3D) -> Node3D:
	var room := Node3D.new(); room.name = "TowerRoom"; room.scale = Vector3.ONE/14.0; parent.add_child(room)
	var cream := KIT.material("f8e5bb"); var pink := KIT.material("e889b7"); var wood := KIT.material("9a6748")
	var path := stair_path(); room.set_meta("stair_path",indoor_path())
	var surface := SLAB_UNION.new()
	# Every incline is one plane. Flat landing boxes meet the ramp end planes,
	# so a turn never twists a quad or puts a platform over the incoming ramp.
	for i in range(path.size()-1):
		var a := path[i]; var b := path[i+1]
		if b.y-a.y < .001: continue
		var direction := b-a; direction.y = 0; direction = direction.normalized()
		var side := Vector3(-direction.z,0,direction.x)
		var width_a := .765 if i < 2 else HALF_WIDTH
		var width_b := .765 if i == 0 else HALF_WIDTH
		var corners: Array[Vector3] = [a-side*width_a,a+side*width_a,b+side*width_b,b-side*width_b]
		_slab(surface,corners,.18)
		var count := maxi(1,ceili((b.y-a.y)/.12))
		for step in count:
			var lo := float(step)/count; var hi := float(step+1)/count
			var aa := corners[0].lerp(corners[3],lo); var bb := corners[1].lerp(corners[2],lo)
			var cc := corners[1].lerp(corners[2],hi); var dd := corners[0].lerp(corners[3],hi)
			var footprint := PackedVector2Array([Vector2(aa.x,aa.z),Vector2(bb.x,bb.z),Vector2(cc.x,cc.z),Vector2(dd.x,dd.z)])
			if Geometry2D.is_polygon_clockwise(footprint): footprint.reverse()
			ARCH.prism(room,"TowerStairTread",footprint,cc.y,.12,wood,false)
			KIT.tube(room,"StairNosing",PackedVector3Array([Vector3(aa.x,cc.y,aa.z),Vector3(bb.x,cc.y,bb.z)]),.025,cream)
		if i == 0: continue # Existing counter/shelf bound the low staff stair.
		var margin := minf(.25,Vector2(b.x-a.x,b.z-a.z).length()*.2)
		var start := a+direction*margin; var finish := b-direction*margin
		var slope := (b.y-a.y)/Vector2(b.x-a.x,b.z-a.z).length()
		start.y += margin*slope; finish.y -= margin*slope
		ARCH.rail(room,PackedVector3Array([start-side*HALF_WIDTH,finish-side*HALF_WIDTH]),wood,"Flight%dLeft" % i)
		ARCH.rail(room,PackedVector3Array([start+side*HALF_WIDTH,finish+side*HALF_WIDTH]),wood,"Flight%dRight" % i)
	_landing(surface,Vector3(-1.3,2.75,-2.0),Vector2(1.8,1.8))
	for flight in 6:
		_landing(surface,Vector3(-.275,2.75+float(flight+1)*1.27,-2.5 if flight == 5 else (1.8 if flight % 2 == 0 else -2.0)),Vector2(3.85,2.8 if flight == 5 else 1.8))
	_landing(surface,Vector3(-.125,FLOOR,1.85),Vector2(3.55,1.2))
	var stairs := MeshInstance3D.new(); stairs.name = "ContinuousTowerStair"; stairs.mesh = surface.commit(wood); room.add_child(stairs); stairs.create_trimesh_collision()
	# A compact single bed occupies the right bay; the final flight remains open beside it.
	for polygon: PackedVector2Array in _floor_pieces(Vector3(.65,FLOOR,-.60),Vector2(1.80,2.94)):
		ARCH.prism(room,"TowerBedFloor",polygon,FLOOR,.18,cream,true)
	var bed: Node3D = load("res://world/props/ponyville/pony_bed.scn").instantiate()
	# The builder owns these edited children directly; do not also instantiate
	# the original subscene when this fully baked room is loaded.
	bed.scene_file_path = ""
	bed.name = "PinkieBed"; bed.position = Vector3(.65,FLOOR,-.60); bed.rotation.y = PI; bed.scale = Vector3(1.785/2.042466,1.7,2.89/2.1)
	bed.set_meta("bed_size",Vector3(2.05,1.1,2.1)); bed.set_meta("side_local",Vector3(0,0,-2.25/(2.89/2.1))); room.add_child(bed)
	bed.set_meta("rest_local",Vector3(.4845/bed.scale.x,float(bed.get_meta("mattress_top",.509)), -.34/bed.scale.z))
	var stylist := KIT.new()._stylist
	stylist.palette = {"fabric":"e889b7","linen":"fff0ce"}; stylist._dress_bed(bed)
	var light := OmniLight3D.new(); light.name = "TowerWarmLight"; light.position = Vector3(-.2,14.1,-.3); light.omni_range = 4.0; light.light_color = Color("ffe6bd"); light.light_energy = .8; room.add_child(light)
	_merge_static_finish(room)
	for mesh: GeometryInstance3D in room.find_children("*","GeometryInstance3D",true,false): mesh.visibility_range_end = 60.0
	return room

static func _landing(surface: RefCounted,at: Vector3,size: Vector2) -> void:
	if at.y >= FLOOR-.001:
		for polygon: PackedVector2Array in _floor_pieces(at,size): _polygon_slab(surface,polygon,at.y,.18)
		return
	var x := size.x*.5; var z := size.y*.5
	_slab(surface,[at+Vector3(-x,0,-z),at+Vector3(x,0,-z),at+Vector3(x,0,z),at+Vector3(-x,0,z)],.18)

static func _floor_pieces(at: Vector3,size: Vector2) -> Array[PackedVector2Array]:
	var x := size.x*.5; var z := size.y*.5
	var rectangle := PackedVector2Array([Vector2(at.x-x,at.z-z),Vector2(at.x+x,at.z-z),Vector2(at.x+x,at.z+z),Vector2(at.x-x,at.z+z)])
	var rim := PackedVector2Array(ROOM_RIM)
	if Geometry2D.is_polygon_clockwise(rim): rim.reverse()
	var inset := Geometry2D.offset_polygon(rim,-.01)
	return Geometry2D.intersect_polygons(rectangle,inset[0])

static func _polygon_slab(surface: RefCounted,polygon: PackedVector2Array,top: float,depth: float) -> void:
	var corners: Array[Vector3] = []
	for point in polygon: corners.append(Vector3(point.x,top,point.y))
	surface.add(corners,depth)

static func _slab(surface: RefCounted,corners: Array[Vector3],depth: float) -> void:
	surface.add(corners,depth)

## Enclosure-derived cuts and a measured tower-only widening preserve the source artwork.
static func open_shaft(house: Node3D) -> bool:
	var exterior: MeshInstance3D = house.get_node("Exterior")
	if not preload("res://world/buildings/sugarcube/tower_opening.gd").apply(exterior): return false
	var room: Node3D = house.get_node("BakeryRoom")
	room.get_node("CreamCeiling").free()
	room.get_node("CreamCeilingSolid").free()
	# Retain the authored beams outside the stair opening, without a visual beam
	# passing through the walking/head envelope inside the new shaft.
	for beam in room.get_children():
		if not beam is MeshInstance3D or not str(beam.name).begins_with("CeilingChocolateBeam"): continue
		var box: AABB = beam.transform * beam.mesh.get_aabb()
		var material: Material = beam.get_active_material(0)
		for span: Vector2 in [Vector2(box.position.x,-2.3),Vector2(1.75,box.end.x)]:
			KIT.box(room,"ShaftBeamEnd",Vector3(span.y-span.x,box.size.y,box.size.z),Vector3((span.x+span.y)*.5,box.get_center().y,box.get_center().z),material)
		beam.free()
	var finish := KIT.material("f4e9d2")
	for spec: Array in [[Vector3(4.1,.18,8),Vector3(-4.35,5.69,.05)],
		[Vector3(3.35,.18,8),Vector3(3.425,5.69,.05)],
		[Vector3(4.05,.18,1.0),Vector3(-.275,5.69,-3.45)],
		[Vector3(4.05,.18,1.3),Vector3(-.275,5.69,3.4)]]:
		KIT.box(room,"ShaftCeilingBorder",spec[0],spec[1],finish,true)
	return true

static func _merge_static_finish(room: Node3D) -> void:
	var groups: Dictionary = {}
	var originals: Array[Node] = []
	for child in room.get_children():
		if not child is MeshInstance3D or child.name == "ContinuousTowerStair": continue
		var visual := child as MeshInstance3D
		if visual.get_child_count() > 0: continue # Keep the clipped floor's owned collider.
		for surface in visual.mesh.get_surface_count():
			var material := visual.get_active_material(surface)
			if not groups.has(material):
				var tool := SurfaceTool.new(); tool.begin(Mesh.PRIMITIVE_TRIANGLES); tool.set_material(material); groups[material] = tool
			groups[material].append_from(visual.mesh,surface,visual.transform)
		originals.append(child)
	for material in groups:
		var tool: SurfaceTool = groups[material]; tool.index()
		var visual := MeshInstance3D.new(); visual.name = "TowerStaticFinish"; visual.mesh = tool.commit(); room.add_child(visual)
	for original in originals: original.free()
