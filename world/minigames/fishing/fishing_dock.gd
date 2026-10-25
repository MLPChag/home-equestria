extends Node3D
## Physical river pier. The authored placement follows measured dry bank and river depths.
## The activity owns input/companions; this node owns the actual deck, rods and landing spot.
signal fish_landed(rod: Node3D, at: Vector3)
const ROD := preload("res://world/minigames/fishing/fishing_rod.gd")
const SPEC := "res://world/minigames/fishing/dock_spec.json"
var rods: Array[Node3D] = []
var companion_spots: Array[Marker3D] = []
var bucket: Node3D
var approach: Marker3D
var ground_height: Callable
var _wood: StandardMaterial3D
var _dark: StandardMaterial3D
var _metal: StandardMaterial3D

func _ready() -> void:
	var spec: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(SPEC))
	var p: Array = spec.origin
	var z: Array = spec.bank_direction
	var toward_bank: Vector3 = Vector3(z[0],z[1],z[2]).normalized()
	global_transform = Transform3D(Basis(Vector3.UP.cross(toward_bank),Vector3.UP,toward_bank),Vector3(p[0],p[1],p[2]))
	set_meta("landmark_id",spec.id); set_meta("landmark_label","River Fishing Dock")
	set_meta("ai_id","landmark:"+str(spec.id));set_meta("ai_label","River Fishing Dock")
	add_to_group("ai_observable")
	add_to_group("fishing_docks")
	_wood = _material(Color("a97b48")); _dark = _material(Color("654831")); _metal = _material(Color("4d5150"))
	var width: float = spec.width; var length: float = spec.length
	# One collision slab, individually spaced visible planks; no cracks in walking collision.
	_box("Deck collision",Vector3(width,.16,length),Vector3(0,-.08,0),null,true)
	var count: int = int(ceil(length/.25))
	for i in count:
		_box("Plank_%02d" % i,Vector3(width,.15,length/count-.012),Vector3(0,-.075,-length*.5+(i+.5)*length/count),_wood,false)
	for side: float in [-1,1]:
		_box("Deck beam",Vector3(.16,.28,length+.12),Vector3(side*(width*.5-.24),-.26,0),_dark,false)
		for depth: float in [-3.6,0.0,3.6]:
			var at: Vector3 = Vector3(side*(width*.5-.12),0,depth)
			var world_at: Vector3 = to_global(at)
			var bed_y: float = ground_height.call(world_at) if ground_height.is_valid() else global_position.y-5
			var bottom: float = minf(-.45,bed_y-global_position.y-.2)
			var top: float = .9 if depth>0 else .20
			_box("Pier post",Vector3(.20,top-bottom,.20),Vector3(at.x,(top+bottom)*.5,at.z),_dark,true)
		# Entrance rail stops before the fishing end so casts are unobstructed.
		_box("Entrance rail",Vector3(.11,.12,3.1),Vector3(side*(width*.5-.12),.84,2.0),_dark,true)
	_build_ramp(length*.5,width)
	approach = Marker3D.new(); approach.name="Approach"; approach.position=Vector3(0,0,length*.5+2); add_child(approach)
	if ground_height.is_valid(): approach.global_position.y=ground_height.call(approach.global_position)
	for i in 3:
		var rod: Node3D = ROD.new(); rod.name="Rod_%d" % i
		rod.transform=Transform3D(Basis(Vector3.RIGHT,-.25),Vector3(-1.10+i*.48,.76,1.55))
		add_child(rod); rods.append(rod); rod.fish_landed.connect(_landed)
	_box("Rod rack",Vector3(1.60,.08,.18),Vector3(-.62,.73,1.57),_dark,true)
	for x: float in [-1.32,.08]: _box("Rack leg",Vector3(.08,.73,.12),Vector3(x,.365,1.57),_dark,true)
	# Leave a full turning corridor between the rack and bucket for native pony clearance.
	var bucket_z: float = -0.15
	bucket=(load("res://world/props/household/fishing-bucket.scn") as PackedScene).instantiate()
	bucket.name="CatchBucket"; bucket.position=Vector3(1.27,.01,bucket_z); add_child(bucket)
	_box("Bucket base collision",Vector3(.39,.045,.39),Vector3(1.27,.035,bucket_z),null,true)
	for edge: int in 8:
		var angle: float = TAU*edge/8.0
		var wall: Node3D = _box("Bucket wall",Vector3(.17,.37,.035),Vector3(1.27+sin(angle)*.20,.225,bucket_z+cos(angle)*.20),null,true)
		wall.rotation.y=angle
	for x: float in [-1.08,1.08]:
		var spot: Marker3D=Marker3D.new(); spot.position=Vector3(x,.01,-2.7); add_child(spot); companion_spots.append(spot)
	_sign()

func rod_near(point: Vector3) -> Node3D:
	var best: Node3D; var distance: float=.25
	for rod: Node3D in rods:
		if not is_instance_valid(rod) or not rod.holder.is_empty():continue
		var d: float=point.distance_to(rod.global_position)
		if d<distance:best=rod;distance=d
	return best

func water_direction() -> Vector3: return -global_basis.z
func landing_point() -> Vector3: return bucket.global_position+Vector3.UP*.45

func _material(colour: Color) -> StandardMaterial3D:
	var material: StandardMaterial3D=StandardMaterial3D.new();material.albedo_color=colour;material.roughness=.92
	return material

func _box(label: String,size: Vector3,at: Vector3,material: Material,solid: bool) -> Node3D:
	var node: Node3D=StaticBody3D.new() if solid else Node3D.new();node.name=label;node.position=at
	if solid:
		var shape: BoxShape3D=BoxShape3D.new();shape.size=size
		var collider: CollisionShape3D=CollisionShape3D.new();collider.shape=shape;node.add_child(collider)
	if material != null:
		var mesh: MeshInstance3D=MeshInstance3D.new();var box:BoxMesh=BoxMesh.new();box.size=size
		mesh.mesh=box;mesh.material_override=material;node.add_child(mesh)
	add_child(node);return node

func _build_ramp(edge: float,width: float) -> void:
	var end: Vector3=to_global(Vector3(0,0,edge+2))
	var y: float=ground_height.call(end)-global_position.y+.02 if ground_height.is_valid() else -.1
	var slope: float=atan2(y,2.0)
	var ramp: Node3D=_box("Bank ramp",Vector3(width,.14,sqrt(4+y*y)),Vector3(0,y*.5-.07,edge+1),_wood,true)
	ramp.rotation.x=-slope

func _sign() -> void:
	_box("Fishing sign post",Vector3(.10,1.25,.10),Vector3(1.24,.625,3.1),_dark,true)
	_box("Fishing sign",Vector3(1.6,.62,.075),Vector3(1.0,1.25,3.1),_wood,true)
	# The sign names the place; the rod's own prompts show how to fish (dev 2026-09-30).
	var words: Label3D=Label3D.new(); words.text="River Fishing"
	words.font=preload("res://world/ui/fonts/PonyvilleMedium.ttf")
	words.font_size=44;words.pixel_size=.0019;words.modulate=Color("372a22");words.outline_size=0
	words.position=Vector3(1.0,1.25,3.145);add_child(words)

func _landed(rod:Node3D,at:Vector3) -> void:fish_landed.emit(rod,at)
